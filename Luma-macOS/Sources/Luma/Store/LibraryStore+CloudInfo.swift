import Foundation
import AppKit
import CoreGraphics
import LumaContentCore

/// 网盘的 EXIF 元数据读取与派生范围（地图 / 位置 / 人物 / 值得重看 / 重复项目）。
///
/// 网盘文件本身带有 EXIF，只是需要按需读取文件头部（WebDAV / 官方网盘用 Range，
/// SMB 直接读挂载文件）。结果回填当前网盘列表，并写入当前图库的 `cloud_assets` 缓存
/// （按挂载 + 路径，远端文件大小变化即作废），不写网盘、也不写 Apple 的数据库。
extension LibraryStore {
    // MARK: - EXIF 扫描

    static let cloudMetadataPageSize = 200
    static let cloudPeoplePageSize = 300

    /// 当前目录中还没有读取过 EXIF 的照片（视频不扫描）。
    var cloudMetadataPendingCount: Int {
        cloudPhotos.lazy.filter {
            !$0.isVideo && !self.cloudModel.metadataScanned.contains($0.id)
        }.count
    }

    var cloudMetadataScannedCount: Int {
        cloudPhotos.lazy.filter { !$0.isVideo && self.cloudModel.metadataScanned.contains($0.id) }.count
    }

    /// 目录载入后自动读取前 200 张的 EXIF；剩余的手动「继续读取」。
    func scanCloudMetadataIfNeeded() {
        guard isCloudScope,
              !cloudModel.isScanningMetadata,
              !cloudModel.scanPhase.isScanning,
              cloudMetadataPendingCount > 0 else { return }
        scanCloudMetadata()
    }

    func scanCloudMetadata() {
        guard isCloudScope, !cloudModel.isScanningMetadata else { return }
        let targets = Array(cloudPhotos
            .filter { !$0.isVideo && !self.cloudModel.metadataScanned.contains($0.id) }
            .prefix(Self.cloudMetadataPageSize))
        guard !targets.isEmpty else { return }

        cloudModel.isScanningMetadata = true
        cloudModel.metadataProgress = 0
        let total = Double(targets.count)
        let mountID = currentCloudMountID
        let jobID = mountID.map { id in
            beginSourceJob(
                SourceJob(sourceID: .cloud(id), kind: .metadata, title: "读取网盘 EXIF"),
                cancel: { [weak self] in
                    Task { @MainActor in self?.cancelCloudMetadataScan() }
                }
            )
        }
        cloudModel.metadataTask = Task { [weak self] in
            guard let self else { return }
            var done = 0
            for photo in targets {
                if Task.isCancelled { break }
                let exif = await self.loadCloudEXIF(for: photo)
                self.applyCloudEXIF(exif, photoID: photo.id)
                done += 1
                // 界面合并刷新：每 40 张才重排一次网格 / 重算一次计数，进度条每 10 张更新一次。
                if done % 40 == 0 { self.flushCloudMetadata() }
                if done % 10 == 0 {
                    self.cloudModel.metadataProgress = Double(done) / total
                    if let jobID {
                        self.updateSourceJob(jobID,
                                             completed: done,
                                             total: targets.count,
                                             message: "已读取 \(done) / \(targets.count) 张")
                    }
                }
                await Task.yield()
            }
            self.flushCloudMetadata()
            self.cloudModel.isScanningMetadata = false
            self.cloudModel.metadataProgress = 0
            self.cloudModel.metadataTask = nil
            self.cloudModel.metadataRevision += 1
            self.cloudScopeCountsCacheKey = nil
            self.cloudVisibleCacheKey = nil
            if let jobID {
                if Task.isCancelled {
                    self.cancelSourceJob(jobID)
                } else {
                    self.finishSourceJob(jobID, message: "已读取 \(done) 张")
                }
            }
        }
    }

    func cancelCloudMetadataScan() {
        cloudModel.metadataTask?.cancel()
    }

    /// 按挂载类型读取文件头部的 EXIF（不下载整张原图）。
    private func loadCloudEXIF(for photo: PhotoItem) async -> CloudPhotoEXIF? {
        guard let mount = cloudMount(for: photo.cloudMountID),
              let path = photo.cloudPath else { return nil }

        if mount.kind == .smb,
           let client = SMBClient(mount: mount, password: cloudPassword(for: mount.id)) {
            _ = try? await client.ensureMounted()
            guard let url = client.fileURL(path: path) else { return nil }
            return await Task.detached(priority: .utility) {
                CloudEXIF.metadata(fromFile: url)
            }.value
        }

        if mount.kind == .webdav, let client = CloudService.webdavClient(mount) {
            // 与缩略图生成共享同一段 256KB 探测数据：同一次浏览里只下一次 Range。
            let key = "\(mount.id.uuidString)|\(path)"
            let data: Data?
            if let cached = await CloudProbeCache.shared.probe(for: key) {
                data = cached.data
            } else if let probe = try? await client.data(path: path, byteRange: CloudEXIF.probeRange) {
                await CloudProbeCache.shared.store(.init(data: probe.data, partial: probe.partial),
                                                   for: key)
                data = probe.data
            } else {
                data = nil
            }
            guard let data else { return nil }
            return await Task.detached(priority: .utility) {
                CloudEXIF.metadata(from: data)
            }.value
        }

        // 官方网盘：用直链 + Range 只取文件头部。
        guard let resource = try? await CloudService.stream(mount: mount, photo: photo) else { return nil }
        var request = URLRequest(url: resource.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.setValue("bytes=\(CloudEXIF.probeRange.lowerBound)-\(CloudEXIF.probeRange.upperBound)",
                         forHTTPHeaderField: "Range")
        for (key, value) in resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request), !data.isEmpty else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            CloudEXIF.metadata(from: data)
        }.value
    }

    /// 把 EXIF 写回当前列表与目录缓存；即使没有 EXIF 也记为已扫描，避免反复请求。
    /// 同时把结果写进当前图库数据库（`cloud_assets`）与网盘索引（`cloud_index_assets`）。
    func applyCloudEXIF(_ exif: CloudPhotoEXIF?, photoID: UUID) {
        defer { cloudModel.metadataScanned.insert(photoID) }
        guard let index = cloudPhotos.firstIndex(where: { $0.id == photoID }) else { return }
        var photo = cloudPhotos[index]
        if let exif {
            Self.applyCloudEXIFFields(exif, to: &photo)
        }
        // 合并刷新由批量扫描循环控制；单张触发时 `enqueue` 自己会安排一次。
        enqueueCloudPhotoUpdate(photo)
        if let mountID = photo.cloudMountID, let path = photo.cloudPath {
            metadataStore?.saveCloudEXIF(mountID: mountID,
                                         path: path,
                                         size: photo.fileSize,
                                         modified: nil,
                                         exif: exif)
            metadataStore?.updateCloudIndexAsset(mountID: mountID,
                                                 path: path,
                                                 capturedAt: exif?.capturedAt,
                                                 width: exif?.pixelWidth.flatMap { $0 > 0 ? $0 : nil },
                                                 height: exif?.pixelHeight.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    /// EXIF 字段叠加规则（列表回填与实时探测共用）。
    static func applyCloudEXIFFields(_ exif: CloudPhotoEXIF, to photo: inout PhotoItem) {
        if let date = exif.capturedAt { photo.capturedAt = date }
        photo.make = exif.make ?? photo.make
        photo.model = exif.model ?? photo.model
        photo.lens = exif.lens ?? photo.lens
        photo.iso = exif.iso ?? photo.iso
        photo.aperture = exif.aperture ?? photo.aperture
        photo.shutterSpeed = exif.shutterSpeed ?? photo.shutterSpeed
        photo.focalLength = exif.focalLength ?? photo.focalLength
        if let latitude = exif.latitude, let longitude = exif.longitude {
            photo.latitude = latitude
            photo.longitude = longitude
        }
        if let width = exif.pixelWidth, width > 0 { photo.pixelWidth = width }
        if let height = exif.pixelHeight, height > 0 { photo.pixelHeight = height }
    }

    // MARK: - 派生范围：地图 / 位置

    /// 网盘里带 GPS 的照片（地图与位置页共用）。
    var cloudGeoPhotos: [PhotoItem] {
        let key = "\(cloudModel.revision)-\(cloudModel.metadataRevision)"
        if cloudModel.geoCacheKey == key { return cloudModel.geoCacheValue }
        let result = cloudPhotos.filter { !$0.isVideo && $0.deletedAt == nil && $0.hasLocation }
        cloudModel.geoCacheKey = key
        cloudModel.geoCacheValue = result
        return result
    }

    var cloudLocatedCount: Int { cloudGeoPhotos.count }

    /// 网盘照片只有 GPS、没有地名时，用系统逆地理编码补齐（结果写入本地地点缓存，不写网盘）。
    func resolveMissingCloudPlacesIfNeeded() {
        guard !isResolvingPlaces else { return }
        let missing = cloudGeoPhotos.filter {
            $0.placeCity == nil && $0.placeDistrict == nil && $0.placeProvince == nil
        }
        guard !missing.isEmpty else { return }
        loadPlaceCacheIfNeeded()

        var grouped: [String: (latitude: Double, longitude: Double, ids: [UUID])] = [:]
        for photo in missing {
            guard let latitude = photo.latitude, let longitude = photo.longitude else { continue }
            let key = Self.placeResolveKey(latitude: latitude, longitude: longitude)
            guard !placeResolveFailedKeys.contains(key) else { continue }
            if var entry = grouped[key] {
                entry.ids.append(photo.id)
                grouped[key] = entry
            } else {
                grouped[key] = (latitude, longitude, [photo.id])
            }
        }
        let entries = grouped.values.sorted { $0.ids.count > $1.ids.count }
        guard !entries.isEmpty else { return }

        isResolvingPlaces = true
        placeResolveTotal = entries.count
        placeResolveDone = 0
        let placesMountID = currentCloudMountID
        let jobID = placesMountID.map { id in
            beginSourceJob(
                SourceJob(sourceID: .cloud(id), kind: .places, title: "补齐网盘照片地点", isCancellable: false)
            )
        }

        Task { [weak self] in
            guard let self else { return }
            var indices: [UUID: Int] = [:]
            for (index, photo) in self.cloudPhotos.enumerated() { indices[photo.id] = index }
            for entry in entries {
                let cacheKey = Self.placeResolveKey(latitude: entry.latitude, longitude: entry.longitude)
                var info: PlaceInfo?
                if let cached = self.placeCache[cacheKey], !cached.isEmpty {
                    info = cached
                } else {
                    info = await self.reverseGeocode(latitude: entry.latitude, longitude: entry.longitude)
                    if info == nil { self.placeResolveFailedKeys.insert(cacheKey) }
                }
                if let info {
                    for id in entry.ids {
                        guard let index = indices[id] else { continue }
                        self.applyPlace(info, to: &self.cloudPhotos[index])
                        self.updateCachedCloudPhoto(self.cloudPhotos[index])
                    }
                }
                self.placeResolveDone += 1
                if let jobID {
                    self.updateSourceJob(jobID,
                                         completed: self.placeResolveDone,
                                         total: entries.count,
                                         message: "已补齐 \(self.placeResolveDone) / \(entries.count) 个地点")
                }
                if info == nil {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            self.cloudModel.metadataRevision += 1
            self.cloudScopeCountsCacheKey = nil
            self.cloudVisibleCacheKey = nil
            self.savePlaceCache()
            self.isResolvingPlaces = false
            if let jobID {
                self.finishSourceJob(jobID, message: "已补齐 \(self.placeResolveDone) 个地点")
            }
        }
    }

    // MARK: - 值得重看

    var cloudRevisitPhotos: [PhotoItem] {
        let now = Date()
        let captureCutoff = now.addingTimeInterval(-LibraryHealthTuning.revisitCaptureAge)
        let viewCutoff = now.addingTimeInterval(-LibraryHealthTuning.revisitViewAge)
        return cloudPhotos.filter { photo in
            guard photo.deletedAt == nil, !photo.isHidden else { return false }
            guard photo.capturedAt < captureCutoff else { return false }
            guard let viewedAt = cloudModel.viewedAt[photo.id] else { return true }
            return viewedAt < viewCutoff
        }
    }

    // MARK: - 相似检索（端侧特征，内存）

    /// 取一张云照片的特征向量：优先用内容识别时缓存的，没有再从缩略图现算。
    func cloudFeature(for photo: PhotoItem) async -> Data? {
        if let cached = cloudModel.features[photo.id] { return cached }
        guard let image = await cloudThumbnail(for: photo),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let feature = await Task.detached(priority: .userInitiated) {
            PhotoIntelligence.feature(cgImage: cgImage)
        }.value
        if let feature {
            cloudModel.features[photo.id] = feature
            if let mountID = photo.cloudMountID, let path = photo.cloudPath {
                metadataStore?.saveCloudFeature(mountID: mountID, path: path, feature: feature)
            }
        }
        return feature
    }

    /// 网盘相似检索：对当前目录的照片现算特征，按余弦相似度排序后进入相似范围。
    func findSimilarCloudPhotos(to id: UUID) {
        guard isCloudScope else { return }
        guard let photo = cloudPhotos.first(where: { $0.id == id }) else { return }
        guard !photo.isVideo else {
            showToast("暂不支持视频相似检索")
            return
        }
        let targets = Array(cloudPhotos.filter { !$0.isVideo }.prefix(80))
        guard targets.count > 1 else {
            showToast("当前目录没有足够的照片用于比较")
            return
        }
        showToast("正在提取特征并查找相似照片…")
        Task { [weak self] in
            guard let self else { return }
            guard let source = await self.cloudFeature(for: photo) else {
                self.showToast("无法读取这张照片的特征")
                return
            }
            var features: [(id: UUID, feature: Data)] = [(photo.id, source)]
            for target in targets where target.id != id {
                if let feature = await self.cloudFeature(for: target) {
                    features.append((target.id, feature))
                }
            }
            let ids = await Task.detached(priority: .userInitiated) {
                Self.rankSimilar(features: features, source: source, excluding: id)
            }.value
            guard !ids.isEmpty else {
                self.showToast("没有找到足够相似的照片")
                return
            }
            self.similarScope = SimilarityScope(sourceID: id, title: photo.displayTitle, ids: Set(ids))
            self.cloudVisibleCacheKey = nil
            self.showToast("找到 \(ids.count) 张相似照片")
        }
    }

    nonisolated static func rankSimilar(features: [(id: UUID, feature: Data)],
                                                source: Data,
                                                excluding id: UUID) -> [UUID] {
        let sourceVector = source.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !sourceVector.isEmpty else { return [] }
        var scored: [(UUID, Float)] = []
        for entry in features where entry.id != id {
            let vector = entry.feature.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard vector.count == sourceVector.count else { continue }
            var score: Float = 0
            for index in 0..<vector.count { score += sourceVector[index] * vector[index] }
            if score >= 0.72 { scored.append((entry.id, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(80).map(\.0)
    }

    // MARK: - 图库体检（只读，内存）

    var canScanCloudHealth: Bool { isCloudScope }

    /// 对当前网盘目录逐张取缩略图：计算清晰度、顺带补特征向量，并归并相似连拍。
    func scanCloudHealth() {
        guard isCloudScope, !cloudModel.isScanningHealth else { return }
        let targets = Array(cloudPhotos.filter { !$0.isVideo && !$0.isHidden }.prefix(500))
        guard !targets.isEmpty else {
            showToast("当前目录没有可检查的照片")
            return
        }

        cloudModel.isScanningHealth = true
        cloudModel.healthScanProgress = 0
        let total = Double(targets.count)
        let healthMountID = currentCloudMountID
        let jobID = healthMountID.map { id in
            beginSourceJob(
                SourceJob(sourceID: .cloud(id), kind: .healthCheck, title: "网盘体检"),
                cancel: { [weak self] in
                    Task { @MainActor in self?.cancelCloudHealthScan() }
                }
            )
        }
        cloudModel.healthTask = Task { [weak self] in
            guard let self else { return }
            var scores: [(UUID, Double)] = []
            var features: [(id: UUID, feature: Data)] = []
            var done = 0
            for photo in targets {
                if Task.isCancelled { break }
                if let image = await self.cloudThumbnail(for: photo),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let result = await Task.detached(priority: .utility) {
                        (PhotoQuality.sharpness(cgImage: cgImage),
                         PhotoIntelligence.feature(cgImage: cgImage))
                    }.value
                    if let sharpness = result.0 {
                        scores.append((photo.id, sharpness))
                    }
                    if let feature = result.1 ?? self.cloudModel.features[photo.id] {
                        self.cloudModel.features[photo.id] = feature
                        features.append((photo.id, feature))
                        if let mountID = photo.cloudMountID, let path = photo.cloudPath {
                            self.metadataStore?.saveCloudFeature(mountID: mountID, path: path, feature: feature)
                        }
                    }
                }
                done += 1
                self.cloudModel.healthScanProgress = Double(done) / total
                if let jobID {
                    self.updateSourceJob(jobID,
                                         completed: done,
                                         total: targets.count,
                                         message: "已检查 \(done) / \(targets.count) 张")
                }
                await Task.yield()
            }

            if Task.isCancelled {
                self.cloudModel.isScanningHealth = false
                self.cloudModel.healthScanProgress = 0
                self.cloudModel.healthTask = nil
                if let jobID { self.cancelSourceJob(jobID) }
                return
            }

            let photosByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
            let scoreMap = Dictionary(uniqueKeysWithValues: scores)
            let groups = await Task.detached(priority: .utility) {
                Self.buildSimilarGroups(features: features, photos: photosByID, scores: scoreMap)
            }.value

            let report = LibraryHealthReport(
                blurry: scores
                    .filter { $0.1 < PhotoQuality.blurryThreshold }
                    .compactMap { entry in
                        photosByID[entry.0].map { LibraryHealthReport.Finding(photo: $0, score: entry.1) }
                    }
                    .sorted { $0.score < $1.score },
                similarGroups: groups,
                largeVideos: cloudPhotos
                    .filter { $0.isVideo && $0.fileSize >= LibraryHealthTuning.largeVideoBytes }
                    .sorted { $0.fileSize > $1.fileSize },
                scannedAt: Date(),
                scannedCount: targets.count
            )
            self.cloudModel.healthReport = report
            self.persistCloudHealthReport(report)
            self.cloudModel.isScanningHealth = false
            self.cloudModel.healthScanProgress = 0
            self.cloudModel.healthTask = nil
            if let jobID {
                self.finishSourceJob(jobID,
                                     message: "完成 · \(report.blurry.count) 张模糊 · \(report.similarDuplicatePhotos.count) 张相似备选")
            }
            self.showToast("体检完成：\(report.blurry.count) 张可能模糊，\(report.similarDuplicatePhotos.count) 张相似备选")
        }
    }

    func cancelCloudHealthScan() {
        cloudModel.healthTask?.cancel()
        cloudModel.healthTask = nil
        cloudModel.isScanningHealth = false
        cloudModel.healthScanProgress = 0
    }

    // MARK: - 重复项目（只读）

    /// 按「文件大小 + 像素尺寸」分组的网盘重复项目；网盘只读，不提供合并。
    var cloudDuplicateGroups: [DuplicateGroup] {
        let key = "\(cloudModel.revision)-\(cloudModel.metadataRevision)"
        if cloudModel.duplicateCacheKey == key { return cloudModel.duplicateCacheValue }
        let groups = DuplicateDetector.groups(from: cloudPhotos)
        cloudModel.duplicateCacheKey = key
        cloudModel.duplicateCacheValue = groups
        return groups
    }

    var cloudDuplicatePhotoIDs: Set<UUID> {
        Set(cloudDuplicateGroups.flatMap { $0.photos.map(\.id) })
    }

    // MARK: - 人物（端侧聚类，仅内存）

    /// 过滤样本过少的聚类，降低误识别；与本地人物页同一套规则。
    var cloudPeople: [LocalPerson] {
        FaceClusterEngine.refined(cloudModel.people, minimumFaces: 2)
    }

    var cloudPeoplePendingCount: Int {
        cloudPhotos.lazy.filter {
            !$0.isVideo && !self.cloudModel.peopleScanned.contains($0.id)
        }.count
    }

    func scanCloudPeopleIfNeeded() {
        guard isCloudScope, !cloudModel.isClusteringPeople, cloudPeoplePendingCount > 0 else { return }
        scanCloudPeople()
    }

    func scanCloudPeople() {
        guard isCloudScope, !cloudModel.isClusteringPeople else { return }
        let targets = Array(cloudPhotos
            .filter { !$0.isVideo && !self.cloudModel.peopleScanned.contains($0.id) }
            .prefix(Self.cloudPeoplePageSize))
        guard !targets.isEmpty else { return }

        cloudModel.isClusteringPeople = true
        cloudModel.peopleProgress = 0
        let total = Double(targets.count)
        let mountID = cloudModel.insightMountID ?? currentCloudMountID
        let jobID = mountID.map { id in
            beginSourceJob(
                SourceJob(sourceID: .cloud(id), kind: .cluster, title: "网盘人物聚类"),
                cancel: { [weak self] in
                    Task { @MainActor in self?.cancelCloudPeopleScan() }
                }
            )
        }
        cloudModel.peopleTask = Task { [weak self] in
            guard let self else { return }
            var done = 0
            for photo in targets {
                if Task.isCancelled { break }
                if let image = await self.cloudThumbnail(for: photo),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let samples = await Task.detached(priority: .utility) {
                        FaceClusterEngine.analyze(cgImage: cgImage, assetID: photo.id)
                    }.value
                    for sample in samples {
                        FaceClusterEngine.assign(sample, to: &self.cloudModel.people)
                    }
                }
                self.cloudModel.peopleScanned.insert(photo.id)
                done += 1
                self.cloudModel.peopleProgress = Double(done) / total
                if let jobID {
                    self.updateSourceJob(jobID,
                                         completed: done,
                                         total: targets.count,
                                         message: "已分析 \(done) / \(targets.count) 张 · \(self.cloudPeople.count) 位人物")
                }
                await Task.yield()
            }
            self.cloudModel.isClusteringPeople = false
            self.cloudModel.peopleProgress = 0
            self.cloudModel.peopleTask = nil
            // 聚类结果与已扫描标记写入当前图库数据库，重开网盘不必重新跑一遍。
            if let mountID {
                let paths = targets.compactMap(\.cloudPath)
                self.metadataStore?.markCloudPeopleScanned(mountID: mountID, paths: paths)
                self.metadataStore?.saveCloudPeople(mountID: mountID, people: self.cloudModel.people)
            }
            self.cloudScopeCountsCacheKey = nil
            self.cloudVisibleCacheKey = nil
            if let jobID {
                if Task.isCancelled {
                    self.cancelSourceJob(jobID)
                } else {
                    self.finishSourceJob(jobID, message: "分析完成 · \(self.cloudPeople.count) 位人物")
                }
            }
        }
    }

    func cancelCloudPeopleScan() {
        cloudModel.peopleTask?.cancel()
    }

    /// 某位人物在当前网盘列表里的照片。
    func cloudPhotos(for person: LocalPerson) -> [PhotoItem] {
        let ids = Set(person.assetIDs)
        return cloudPhotos.filter { ids.contains($0.id) }
    }

    /// 网盘人物的摘要：与拾光 / 系统图库使用同一个 `PersonInsight` 与展示组件。
    func cloudPersonInsight(for person: LocalPerson) -> PersonInsight {
        var insight = PersonInsight.make(photos: cloudPhotos(for: person))
        let mine = Set(person.assetIDs)
        insight.companions = cloudPeople
            .filter { $0.id != person.id }
            .compactMap { other -> PersonInsight.Companion? in
                let shared = mine.intersection(other.assetIDs).count
                guard shared >= 2 else { return nil }
                return PersonInsight.Companion(id: other.id.uuidString,
                                               name: other.name,
                                               count: shared,
                                               coverPhotoID: other.assetIDs.first,
                                               coverData: other.coverImageData)
            }
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { $0 }
        return insight
    }

    /// 网盘人物的「地图」：只看这个人在当前列表里带有效定位的照片。
    func personMapPhotos(cloud person: LocalPerson) -> [PhotoItem] {
        cloudPhotos(for: person).filter { $0.hasLocation }
    }

    /// 换挂载 / 换库 / 换目录时清空 EXIF、人物与派生缓存（内存），数据库缓存保留以便回填。
    func resetCloudDerivedData() {
        cloudModel.metadataTask?.cancel()
        cloudModel.metadataTask = nil
        cloudModel.isScanningMetadata = false
        cloudModel.metadataProgress = 0
        cloudModel.metadataScanned = []
        cloudModel.metadataRevision += 1

        cloudModel.peopleTask?.cancel()
        cloudModel.peopleTask = nil
        cloudModel.isClusteringPeople = false
        cloudModel.peopleProgress = 0
        cloudModel.people = []
        cloudModel.peopleScanned = []
        cloudModel.viewedAt = [:]

        cloudModel.healthTask?.cancel()
        cloudModel.healthTask = nil
        cloudModel.isScanningHealth = false
        cloudModel.healthScanProgress = 0
        cloudModel.healthReport = nil
        cloudModel.features = [:]
        cloudModel.featuresLoadedMountID = nil
        cloudModel.isLoadingCloudFeatures = false
        similarScope = nil
        if cloudModel.beautyReportIsCloud {
            beautyTask?.cancel()
            beautyTask = nil
            beautyReport = nil
            isScanningBeauty = false
            beautyScanProgress = 0
            isApplyingBeauty = false
            beautyApplyProgress = 0
        }
        cloudModel.beautyReportIsCloud = false

        cloudModel.geoCacheKey = ""
        cloudModel.geoCacheValue = []
        cloudModel.placeClusterCacheKey = ""
        cloudModel.placeClusterCacheValue = []
        cloudModel.placeGroupCacheKey = ""
        cloudModel.placeGroupCacheValue = []
        cloudModel.duplicateCacheKey = ""
        cloudModel.duplicateCacheValue = []
        cloudScopeCountsCacheKey = nil
        cloudVisibleCacheKey = nil
    }
}
