import Foundation
import SwiftUI
import LumaContentCore

/// 体检阈值：与 UI 状态无关，放在文件级便于在后台任务里直接使用。
enum LibraryHealthTuning {
    /// 超过这个大小视为「过大视频」。
    static let largeVideoBytes: Int64 = 300 * 1024 * 1024
    /// 相似连拍分组的余弦相似度门槛（特征向量已归一化，点积即相似度）。
    static let similarGroupThreshold: Float = 0.90
    /// 同一组的拍摄时间差上限（秒），避免把同场景不同时段的照片归为一组。
    static let similarGroupWindow: TimeInterval = 600
    /// 「值得重看」：拍摄距今至少这么久，且最近查看距今至少一年（或从未查看）。
    static let revisitCaptureAge: TimeInterval = 2 * 365 * 24 * 3600
    static let revisitViewAge: TimeInterval = 365 * 24 * 3600
}

/// 图库体检：模糊照片、相似连拍备选、过大视频，以及「值得重看」范围。
/// `scanLibraryHealth` 处理本地图库与系统图库；网盘目录由 `scanCloudHealth` 用缩略图在内存里完成同样的检查。
extension LibraryStore {
    var canScanHealth: Bool {
        !isCloudScope && !needsLibrarySetup
    }

    /// 系统图库当前已载入的照片（索引模式只包含当前窗口）。
    /// 「图库体检」等非网格范围不会再加载窗口，因此回退到上一次的窗口内容。
    var systemLoadedPhotos: [PhotoItem] {
        if isSystemPagedScope { return systemWindowPhotos }
        if !systemPhotos.isEmpty { return systemPhotos }
        return systemWindowPhotos
    }

    /// 体检结果是否属于当前范围（系统 / 本地互不混用）。
    var healthReportMatchesCurrentScope: Bool {
        if isSystemScope { return healthReportScopeTag == "system" }
        return healthReportScopeTag == nil
    }

    // MARK: - 扫描

    /// 扫描当前图库：逐张计算清晰度，并用端侧特征向量归并相似连拍。
    /// 本地图库读缩略图文件；系统图库读官方 derivative / 缓存缩略图，结果落 `derived_reports`。
    func scanLibraryHealth() {
        guard canScanHealth else {
            showToast("图库体检仅支持拾光本地图库与系统图库")
            return
        }
        guard !isScanningHealth else { return }
        let systemScope = isSystemScope
        let source = systemScope ? systemLoadedPhotos : photos
        let targets = source.filter { $0.deletedAt == nil && !$0.isHidden }
        guard !targets.isEmpty else {
            showToast("图库里还没有可检查的项目")
            return
        }

        isScanningHealth = true
        isFinalizingHealth = false
        healthScanProgress = 0
        // 边检查边展示：先放一张空报告，把可以立刻确定的「过大视频」显示出来，
        // 之后每检查一小批就刷新模糊照片与已检查数量，不必等全部结束。
        let largeVideos = targets
            .filter { $0.isVideo && $0.fileSize >= LibraryHealthTuning.largeVideoBytes }
            .sorted { $0.fileSize > $1.fileSize }
        healthReport = LibraryHealthReport(blurry: [],
                                           similarGroups: [],
                                           largeVideos: largeVideos,
                                           scannedAt: Date(),
                                           scannedCount: 0)
        healthReportScopeTag = systemScope ? "system" : nil
        let photosByName = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        let photosOnly = targets.filter { !$0.isVideo }
        let token = UUID()
        healthScanToken = token
        // 体检可能要跑几分钟：进统一任务中心，切走页面也能看到进度并暂停。
        let sourcePath = systemScope
            ? (systemLibraryPath ?? "")
            : (LibraryPaths.containerLibraryURL ?? LibraryPaths.root).standardizedFileURL.path
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(sourcePath),
                      kind: .healthCheck,
                      title: systemScope ? "系统图库体检" : "图库体检"),
            cancel: { [weak self] in
                Task { @MainActor in self?.cancelHealthScan() }
            }
        )

        healthTask = Task { [weak self] in
            guard let self else { return }
            var scores: [(UUID, Double)] = []
            var featureEntries: [(id: UUID, feature: Data)] = []
            scores.reserveCapacity(photosOnly.count)
            var lastPublish = Date.distantPast

            // 清晰度：按小块并发，避免为每张照片创建独立任务。
            let chunkSize = 16
            var index = 0
            while index < photosOnly.count {
                if Task.isCancelled { break }
                let end = min(index + chunkSize, photosOnly.count)
                let slice = Array(photosOnly[index..<end])
                let part = await Task.detached(priority: .utility) {
                    slice.compactMap { photo -> (id: UUID, score: Double, feature: Data?)? in
                        if let sharpness = PhotoQuality.sharpness(for: photo) {
                            return (photo.id, sharpness, nil)
                        }
                        guard !photo.isVideo,
                              let image = ImageLoader.thumbnail(for: photo),
                              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              let sharpness = PhotoQuality.sharpness(cgImage: cgImage) else { return nil }
                        return (photo.id, sharpness, PhotoIntelligence.feature(cgImage: cgImage))
                    }
                }.value
                if Task.isCancelled { break }
                guard self.healthScanToken == token else {
                    self.cancelSourceJob(jobID)
                    return
                }
                for entry in part {
                    scores.append((entry.id, entry.score))
                    if let feature = entry.feature {
                        featureEntries.append((entry.id, feature))
                    }
                }
                index = end
                self.healthScanProgress = Double(index) / Double(max(1, photosOnly.count))
                self.updateSourceJob(jobID,
                                     completed: index,
                                     total: photosOnly.count,
                                     message: "已检查 \(index.formatted()) / \(photosOnly.count.formatted()) 张")
                // 最多每秒 5 次刷新，避免大图库扫描时频繁重绘整页。
                if end == photosOnly.count || Date().timeIntervalSince(lastPublish) >= 0.2 {
                    lastPublish = Date()
                    self.publishHealthProgress(scores: scores,
                                               photos: photosByName,
                                               largeVideos: largeVideos,
                                               scannedCount: index)
                }
            }
            guard self.healthScanToken == token else { return }
            let paused = Task.isCancelled

            if systemScope, !featureEntries.isEmpty {
                var features = self.systemFeatures
                for entry in featureEntries { features[entry.id] = entry.feature }
                self.systemFeatures = features
                self.persistSystemFeatures(featureEntries)
            }

            // 相似连拍：用归一化特征向量做近邻归并，每组只保留最佳一张。
            // 暂停时也在这里补齐一次，已识别的结果可以继续查看与处理。
            var features: [(id: UUID, feature: Data)] = featureEntries
            if !systemScope {
                features = self.metadataStore?.allFeatures() ?? []
            }
            let groups = await Task.detached(priority: .utility) {
                Self.buildSimilarGroups(features: features,
                                        photos: photosByName,
                                        scores: Dictionary(uniqueKeysWithValues: scores))
            }.value
            guard self.healthScanToken == token else {
                self.cancelSourceJob(jobID)
                return
            }

            let report = LibraryHealthReport(
                blurry: scores
                    .filter { $0.1 < PhotoQuality.blurryThreshold }
                    .compactMap { entry in
                        photosByName[entry.0].map { LibraryHealthReport.Finding(photo: $0, score: entry.1) }
                    }
                    .sorted { $0.score < $1.score },
                similarGroups: groups,
                largeVideos: largeVideos,
                scannedAt: Date(),
                scannedCount: paused ? scores.count : photosOnly.count
            )

            self.healthReport = report
            self.healthReportScopeTag = systemScope ? "system" : nil
            self.persistHealthReport(report)
            self.isScanningHealth = false
            self.isFinalizingHealth = false
            self.healthScanProgress = 0
            self.healthTask = nil
            if paused {
                self.cancelSourceJob(jobID)
                self.showToast("已暂停，保留已检查的 \(scores.count.formatted()) 张结果")
            } else {
                let duplicates = report.similarDuplicatePhotos.count
                let blurry = report.blurry.count
                self.finishSourceJob(jobID,
                                     message: "完成 · \(blurry) 张模糊 · \(duplicates) 张相似备选")
                self.showToast("体检完成：\(blurry) 张可能模糊，\(duplicates) 张相似备选")
            }
        }
    }

    /// 扫描中刷新部分结果：只更新清晰度与已检查数量，相似连拍仍在最后统一归并。
    private func publishHealthProgress(scores: [(UUID, Double)],
                                       photos: [UUID: PhotoItem],
                                       largeVideos: [PhotoItem],
                                       scannedCount: Int) {
        let blurry = scores
            .filter { $0.1 < PhotoQuality.blurryThreshold }
            .compactMap { entry in
                photos[entry.0].map { LibraryHealthReport.Finding(photo: $0, score: entry.1) }
            }
            .sorted { $0.score < $1.score }
        healthReport = LibraryHealthReport(blurry: blurry,
                                           similarGroups: [],
                                           largeVideos: largeVideos,
                                           scannedAt: Date(),
                                           scannedCount: scannedCount)
    }

    func cancelHealthScan() {
        guard isScanningHealth else { return }
        healthTask?.cancel()
        // 让已检查的部分结果立即可用；后台任务会补齐相似连拍并落盘。
        isScanningHealth = false
        isFinalizingHealth = true
        healthScanProgress = 0
        showToast("已暂停，正在整理已检查的结果…")
    }

    /// 换库 / 断开连接时直接作废旧任务：不写回部分结果，避免落到新图库。
    func abortHealthScan() {
        healthScanToken = UUID()
        healthTask?.cancel()
        healthTask = nil
        isScanningHealth = false
        isFinalizingHealth = false
        healthScanProgress = 0
    }

    /// 纯计算：把特征向量按「与已有组代表的相似度 ≥ 门槛且拍摄时间相近」归组。
    /// 网盘体检在内存里复用同一套归并规则。
    nonisolated static func buildSimilarGroups(
        features: [(id: UUID, feature: Data)],
        photos: [UUID: PhotoItem],
        scores: [UUID: Double]
    ) -> [LibraryHealthReport.SimilarGroup] {
        // 先按拍摄时间排序，再滑动时间窗口归并：
        // 只有窗口内的组才需要做 2048 维点积，十万级图库不会退化成 O(n²) 卡死。
        let ordered = features
            .compactMap { entry -> (id: UUID, feature: Data, time: TimeInterval)? in
                guard let photo = photos[entry.id], !photo.isVideo else { return nil }
                return (entry.id, entry.feature, photo.capturedAt.timeIntervalSinceReferenceDate)
            }
            .sorted { $0.time < $1.time }

        var members: [[UUID]] = []
        var vectors: [[Float]] = []
        var anchorTimes: [TimeInterval] = []
        var scoresByGroup: [Float] = []
        var firstActive = 0

        for entry in ordered {
            let vector = entry.feature.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard !vector.isEmpty else { continue }
            while firstActive < anchorTimes.count,
                  entry.time - anchorTimes[firstActive] > LibraryHealthTuning.similarGroupWindow {
                firstActive += 1
            }

            var bestIndex = -1
            var bestScore: Float = 0
            var groupIndex = firstActive
            while groupIndex < vectors.count {
                let representative = vectors[groupIndex]
                if representative.count == vector.count {
                    var dot: Float = 0
                    for i in 0..<vector.count { dot += vector[i] * representative[i] }
                    if dot >= LibraryHealthTuning.similarGroupThreshold, dot > bestScore {
                        bestScore = dot
                        bestIndex = groupIndex
                    }
                }
                groupIndex += 1
            }

            if bestIndex >= 0 {
                members[bestIndex].append(entry.id)
                scoresByGroup[bestIndex] += bestScore
            } else {
                members.append([entry.id])
                vectors.append(vector)
                anchorTimes.append(entry.time)
                scoresByGroup.append(0)
            }
        }

        var result: [LibraryHealthReport.SimilarGroup] = []
        for (groupIndex, ids) in members.enumerated() where ids.count > 1 {
            let groupPhotos = ids.compactMap { photos[$0] }
            guard groupPhotos.count > 1 else { continue }
            // 保留清晰度最高的一张；同分时优先像素更高、文件更大。
            let best = groupPhotos.max { lhs, rhs in
                let left = scores[lhs.id] ?? 0
                let right = scores[rhs.id] ?? 0
                if left == right {
                    let leftPixels = lhs.pixelWidth * lhs.pixelHeight
                    let rightPixels = rhs.pixelWidth * rhs.pixelHeight
                    if leftPixels == rightPixels { return lhs.fileSize < rhs.fileSize }
                    return leftPixels < rightPixels
                }
                return left < right
            } ?? groupPhotos[0]
            let duplicates = groupPhotos
                .filter { $0.id != best.id }
                .sorted { (scores[$0.id] ?? 0) < (scores[$1.id] ?? 0) }
            let similarity = Double(scoresByGroup[groupIndex]) / Double(max(1, ids.count - 1))
            result.append(LibraryHealthReport.SimilarGroup(best: best,
                                                           duplicates: duplicates,
                                                           similarity: similarity))
        }
        return result.sorted { $0.duplicates.count > $1.duplicates.count }
    }

    // MARK: - 系统图库相似检索（内存特征 + 落库缓存）

    /// 系统图库相似检索：对当前范围最多 80 张缩略图现算特征，结果只存内存，特征写入图库缓存。
    func findSimilarSystemPhotos(to id: UUID) {
        guard isSystemScope else { return }
        let source = systemLoadedPhotos
        guard let photo = source.first(where: { $0.id == id }) ?? systemPhotoIndex[id] else { return }
        guard !photo.isVideo else {
            showToast("暂不支持视频相似检索")
            return
        }
        let targets = Array(source.filter { !$0.isVideo }.prefix(80))
        guard targets.count > 1 else {
            showToast("当前范围没有足够的照片用于比较")
            return
        }
        showToast("正在提取特征并查找相似照片…")
        Task { [weak self] in
            guard let self else { return }
            let missing = targets.filter { self.systemFeatures[$0.id] == nil }
            if !missing.isEmpty {
                let part = await Task.detached(priority: .userInitiated) { () -> [(UUID, Data)] in
                    missing.compactMap { item in
                        guard let image = ImageLoader.thumbnail(for: item),
                              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              let feature = PhotoIntelligence.feature(cgImage: cgImage) else { return nil }
                        return (item.id, feature)
                    }
                }.value
                var features = self.systemFeatures
                for entry in part { features[entry.0] = entry.1 }
                self.systemFeatures = features
                self.persistSystemFeatures(part.map { (id: $0.0, feature: $0.1) })
            }
            guard let sourceFeature = self.systemFeatures[photo.id] else {
                self.showToast("无法读取这张照片的特征")
                return
            }
            let features = targets.compactMap { item in
                self.systemFeatures[item.id].map { (item.id, $0) }
            }
            let ids = await Task.detached(priority: .userInitiated) {
                Self.rankSimilar(features: features, source: sourceFeature, excluding: id)
            }.value
            guard !ids.isEmpty else {
                self.showToast("没有找到足够相似的照片")
                return
            }
            self.similarScope = SimilarityScope(sourceID: id, title: photo.displayTitle, ids: Set(ids))
            self.showToast("找到 \(ids.count) 张相似照片")
        }
    }

    // MARK: - 系统图库真实清理（PhotoKit）

    /// 只有当前图库就是官方「照片」图库时，才允许通过 PhotoKit 真实清理。
    var canDeleteSystemPhotos: Bool {
        isSystemScope && isNativeContainer
    }

    /// 把相似备选移入「照片」的最近删除（30 天内可在「照片」中恢复）。
    func deleteSystemDuplicatesViaPhotoKit() async {
        guard canDeleteSystemPhotos else {
            showToast("只有官方「照片」图库作为当前图库时才能直接清理")
            return
        }
        let ids = similarDuplicatePhotos.map(\.id)
        guard !ids.isEmpty else { return }
        guard await PhotoKitBridge.ensureAuthorized() else {
            showToast("需要相册读写权限，请在系统设置中允许拾光访问照片")
            return
        }
        do {
            try await PhotoKitBridge.delete(assetIDs: ids)
        } catch {
            showToast("移入最近删除失败：\(error.localizedDescription)")
            return
        }
        removeSystemPhotosFromMemory(Set(ids))
        healthReport = nil
        healthReportScopeTag = nil
        showToast("已把 \(ids.count) 张移入「照片」的最近删除")
        scanLibraryHealth()
    }

    /// 删除成功后同步内存，避免网格与计数继续显示已经从「照片」移走的项目。
    /// 连拍处理（`LibraryStore+Burst`）也复用这一份同步逻辑。
    func removeSystemPhotosFromMemory(_ ids: Set<UUID>) {
        let removedVideos = systemWindowPhotos.lazy.filter { ids.contains($0.id) && $0.isVideo }.count
        systemPhotos.removeAll { ids.contains($0.id) }
        systemWindowPhotos.removeAll { ids.contains($0.id) }
        for id in ids { systemPhotoIndex.removeValue(forKey: id) }
        systemWindowTotal = max(0, systemWindowTotal - ids.count)
        systemWindowVideos = max(0, systemWindowVideos - removedVideos)
        systemTotalAssetCount = max(0, systemTotalAssetCount - ids.count)
        systemCountsCache = nil
        systemCountsCacheRevision = -1
        mediaTypeSummaryCacheKey = nil
        invalidateSystemDuplicateGroups()
        contentRevision &+= 1
    }

    // MARK: - 报告缓存（落库）

    /// 当前范围的体检报告缓存键；网盘在 `scanCloudHealth` 里按「挂载 + 目录」单独处理。
    var healthReportCacheKey: String? {
        if isCloudScope { return nil }
        if isSystemScope {
            guard let path = systemLibraryPath else { return nil }
            return DerivedReportKey.system(path, "health")
        }
        return DerivedReportKey.local("health")
    }

    /// 缓存签名：系统图库随图库替换失效；本地只做占位（结果按当前照片实时过滤）。
    var healthReportSignature: String {
        isSystemScope ? systemCacheSignature : "local"
    }

    func persistHealthReport(_ report: LibraryHealthReport) {
        guard let key = healthReportCacheKey,
              let store = metadataStore,
              let data = try? JSONEncoder().encode(report) else { return }
        store.saveDerivedReport(key: key, signature: healthReportSignature, payload: data)
    }

    /// 打开体检页时回填上次结果；系统图库的签名变了就丢弃旧缓存。
    func restoreCachedHealthReportIfNeeded() {
        guard !isCloudScope else { return }
        if healthReport != nil, healthReportMatchesCurrentScope { return }
        guard let key = healthReportCacheKey,
              let store = metadataStore,
              let cached = store.loadDerivedReport(key: key),
              let report = try? JSONDecoder().decode(LibraryHealthReport.self, from: cached.payload) else {
            return
        }
        if let signature = cached.signature, signature != healthReportSignature {
            store.removeDerivedReport(key: key)
            return
        }
        healthReport = report
        healthReportScopeTag = isSystemScope ? "system" : nil
    }

    // MARK: - 体检范围

    /// 模糊照片（按可能程度从高到低）。
    var blurryPhotos: [PhotoItem] {
        guard let report = healthReport, healthReportMatchesCurrentScope else { return [] }
        let source = isSystemScope ? systemLoadedPhotos : photos
        let live = Dictionary(uniqueKeysWithValues: source.lazy
            .filter { $0.deletedAt == nil && !$0.isHidden }
            .map { ($0.id, $0) })
        return report.blurry.compactMap { live[$0.photo.id] }
    }

    /// 相似连拍里被判定为备选的照片。
    var similarDuplicatePhotos: [PhotoItem] {
        guard let report = healthReport, healthReportMatchesCurrentScope else { return [] }
        let source = isSystemScope ? systemLoadedPhotos : photos
        let live = Dictionary(uniqueKeysWithValues: source.lazy
            .filter { $0.deletedAt == nil && !$0.isHidden }
            .map { ($0.id, $0) })
        return report.similarDuplicatePhotos.compactMap { live[$0.id] }
    }

    /// 体积过大的视频。
    var largeVideoPhotos: [PhotoItem] {
        guard let report = healthReport, healthReportMatchesCurrentScope else { return [] }
        let source = isSystemScope ? systemLoadedPhotos : photos
        let live = Dictionary(uniqueKeysWithValues: source.lazy
            .filter { $0.deletedAt == nil && !$0.isHidden }
            .map { ($0.id, $0) })
        return report.largeVideos.compactMap { live[$0.id] }
    }

    /// 值得重看：至少两年没拍到的旧照片，且一年以上（或从未）没有打开过。
    var revisitPhotos: [PhotoItem] {
        let now = Date()
        let captureCutoff = now.addingTimeInterval(-LibraryHealthTuning.revisitCaptureAge)
        let viewCutoff = now.addingTimeInterval(-LibraryHealthTuning.revisitViewAge)
        return photos.filter { photo in
            guard photo.deletedAt == nil, !photo.isHidden, !photo.isCloud, !photo.isSystem else { return false }
            guard photo.capturedAt < captureCutoff else { return false }
            guard let viewedAt = photo.viewedAt else { return true }
            return viewedAt < viewCutoff
        }
    }

    /// 记录一次查看，供「值得重看」判断新鲜度；只更新单行并跳过一小时内重复写入。
    func recordView(_ id: UUID) {
        // 网盘照片的查看记录只在本机内存里，不写网盘。
        if let index = cloudPhotos.firstIndex(where: { $0.id == id }) {
            let now = Date()
            if let last = cloudPhotos[index].viewedAt, now.timeIntervalSince(last) < 3600 { return }
            cloudPhotos[index].viewedAt = now
            cloudModel.viewedAt[id] = now
            updateCachedCloudPhoto(cloudPhotos[index])
            if let mountID = cloudPhotos[index].cloudMountID, let path = cloudPhotos[index].cloudPath {
                metadataStore?.saveCloudViewedAt(mountID: mountID, path: path, viewedAt: now)
            }
            cloudScopeCountsCacheKey = nil
            return
        }
        // 官方「照片」图库：查看记录写进拾光数据库，不写 Photos.sqlite。
        if canEditNativeOverlay, isSystemPhotoID(id) {
            recordSystemView(id)
            return
        }
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        guard !photos[index].isCloud, !photos[index].isSystem else { return }
        let now = Date()
        if let last = photos[index].viewedAt, now.timeIntervalSince(last) < 3600 { return }
        // 只写数据库，不改内存里的 photos：它的 didSet 会推进 contentRevision，
        // 大图库开图那一刻会把窗口 / 分段 / 日期索引 / 总览全部重算，表现为卡一下。
        metadataStore?.setViewedAt(id, date: now)
    }
}
