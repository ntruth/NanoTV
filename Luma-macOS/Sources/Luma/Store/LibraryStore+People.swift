import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore

/// 经常同框的两位人物。
struct PeoplePair: Identifiable, Hashable {
    let a: UUID
    let b: UUID
    let count: Int

    var id: String {
        a.uuidString < b.uuidString
            ? "\(a.uuidString)|\(b.uuidString)"
            : "\(b.uuidString)|\(a.uuidString)"
    }
}

/// 查看器画面上的人物名标签（只带名字，头像不参与画面标注）。
struct PhotoPersonName: Identifiable, Hashable {
    let id: String
    let name: String
}

extension LibraryStore {
    // MARK: - Places

    /// 每批处理的查询格数量。分批只是为了及时把结果刷到界面上，
    /// 解析会一直推进到没有缺失坐标为止，不再「跑一批就收工」。
    static let placeResolveBatchLimit = 40

    /// 逆地理编码的查询网格：0.01° 约 1.1 km。
    /// 之前直接用照片原始坐标（0.001°，约 110 m）当查询点，一趟旅行就能切出上千个点，
    /// 请求量远超系统限流额度；吸附到 1 km 网格后请求数通常只剩几百个，同格照片共用一次结果。
    static let placeResolveCellSize = 0.01

    static func placeResolveKey(latitude: Double, longitude: Double) -> String {
        let cell = placeResolveCellSize
        let latitudeCenter = (latitude / cell).rounded(.down) * cell + cell / 2
        let longitudeCenter = (longitude / cell).rounded(.down) * cell + cell / 2
        return String(format: "%.3f,%.3f", latitudeCenter, longitudeCenter)
    }

    /// 按当前聚合层级（省 / 市 / 区县 / 街道）聚合的地点统计。按内容版本缓存：地图页会多次读取它，
    /// 每次 body 求值都重扫整库会让大图库打开地图时明显卡顿。
    var placeClusters: [PlaceCluster] {
        if isCloudScope {
            let key = "\(cloudModel.revision)-\(cloudModel.metadataRevision)"
            if cloudModel.placeClusterCacheKey == key { return cloudModel.placeClusterCacheValue }
            let clusters = PlaceClusterBuilder.clusters(from: cloudGeoPhotos,
                                                        granularity: placeGranularity)
            cloudModel.placeClusterCacheKey = key
            cloudModel.placeClusterCacheValue = clusters
            return clusters
        }
        if placeClustersCacheKey == "\(contentRevision)" {
            return placeClustersCacheValue
        }
        let clusters = PlaceClusterBuilder.clusters(from: geoPhotos,
                                                    granularity: placeGranularity)
        placeClustersCacheKey = "\(contentRevision)"
        placeClustersCacheValue = clusters
        return clusters
    }

    /// 地图标注版本：聚类结果只随这些状态变化，供地图按版本重建标注。
    var placeClusterVersion: String {
        if isCloudScope {
            return "\(cloudModel.revision)-\(cloudModel.metadataRevision)-\(placeGranularity.rawValue)"
        }
        return "\(contentRevision)-\(systemIndexSignature)-\(placeGranularity.rawValue)"
    }

    /// 按国家/地区分组，中国大陆优先。
    var placeGroups: [(title: String, clusters: [PlaceCluster])] {
        if isCloudScope {
            let key = "\(cloudModel.revision)-\(cloudModel.metadataRevision)"
            if cloudModel.placeGroupCacheKey == key { return cloudModel.placeGroupCacheValue }
            let groups = makePlaceGroups(from: cloudModel.placeClusterCacheKey == key
                                         ? cloudModel.placeClusterCacheValue
                                         : placeClusters)
            cloudModel.placeGroupCacheKey = key
            cloudModel.placeGroupCacheValue = groups
            return groups
        }
        if placeGroupsCacheKey == "\(contentRevision)" {
            return placeGroupsCacheValue
        }
        let groups = makePlaceGroups(from: placeClusters)
        placeGroupsCacheKey = "\(contentRevision)"
        placeGroupsCacheValue = groups
        return groups
    }

    private func makePlaceGroups(from clusters: [PlaceCluster]) -> [(title: String, clusters: [PlaceCluster])] {
        var buckets: [String: [PlaceCluster]] = [:]
        for cluster in clusters {
            buckets[cluster.group, default: []].append(cluster)
        }
        let titles = buckets.keys.sorted { lhs, rhs in
            if lhs == "中国大陆" { return true }
            if rhs == "中国大陆" { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return titles.compactMap { title in
            guard let clusters = buckets[title] else { return nil }
            return (title, clusters)
        }
    }

    /// 换库 / 重扫时清掉地图派生缓存。
    func resetPlaceCaches() {
        geoPhotosCacheKey = -1
        geoPhotosCacheValue = []
        // 新图库要允许重新补齐地名。
        placeResolveFailedKeys.removeAll()
        resetPlaceClusterCaches()
    }

    /// 只清聚类与分组缓存：切换聚合层级时带定位照片的列表不需要重算。
    func resetPlaceClusterCaches() {
        placeClustersCacheKey = ""
        placeClustersCacheValue = []
        placeGroupsCacheKey = ""
        placeGroupsCacheValue = []
        cloudModel.placeClusterCacheKey = ""
        cloudModel.placeClusterCacheValue = []
        cloudModel.placeGroupCacheKey = ""
        cloudModel.placeGroupCacheValue = []
    }

    func openPlace(_ cluster: PlaceCluster) {
        selectedPlace = cluster
        selection.removeAll()
        viewerID = nil
    }

    func closePlace() {
        selectedPlace = nil
        selection.removeAll()
    }

    /// 地点摘要：到访轨迹、四季、时段、地标与同行人物。
    func placeInsight(for place: PlaceCluster) -> PlaceInsight {
        let photos = place.photos.filter { $0.deletedAt == nil && !$0.isHidden }
        return PlaceInsight.make(place: place, photos: photos, companions: placeCompanions(for: photos))
    }

    /// 地点详情在后台生成摘要：热门地点的照片可能上千张，逐张排序与四季 / 时段统计
    /// 放在主线程会让打开卡片明显掉帧，这里只把纯计算挪到后台。
    func placeInsightAsync(for place: PlaceCluster) async -> PlaceInsight {
        let photos = place.photos.filter { $0.deletedAt == nil && !$0.isHidden }
        let companions = placeCompanions(for: photos)
        return await Task.detached(priority: .userInitiated) {
            PlaceInsight.make(place: place, photos: photos, companions: companions)
        }.value
    }

    /// 地点里经常同框的人物：直连模式按照片取样统计，索引模式用现成的人物↔照片映射求交集。
    private func placeCompanions(for photos: [PhotoItem]) -> [PhotoCompanion] {
        let ids = Set(photos.map(\.id))
        guard !ids.isEmpty else { return [] }
        if isSystemScope {
            if let index = systemIndex, index.direct != nil {
                // 直连模式没有常驻的人物↔照片映射，按地点里的照片取样统计。
                return index.directCompanions(for: photos.map(\.id), limit: 3)
            }
            return systemPeople
                .compactMap { person -> PhotoCompanion? in
                    let shared = ids.intersection(person.assetIDs).count
                    guard shared >= 2 else { return nil }
                    return PhotoCompanion(id: "system-\(person.id)",
                                          name: person.name,
                                          count: shared,
                                          coverPhotoID: person.keyAssetID ?? person.assetIDs.first,
                                          coverData: person.cropData)
                }
                .sorted { $0.count > $1.count }
                .prefix(3)
                .map { $0 }
        }
        loadFaceDataIfNeeded()
        return localPeople
            .compactMap { person -> PhotoCompanion? in
                let shared = ids.intersection(person.assetIDs).count
                guard shared >= 2 else { return nil }
                return PhotoCompanion(id: person.id.uuidString,
                                      name: person.name,
                                      count: shared,
                                      coverPhotoID: person.assetIDs.first,
                                      coverData: person.coverImageData)
            }
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { $0 }
    }

    // MARK: - People

    func openPerson(_ person: SystemPersonInfo) {
        selectedPerson = person
        selection.removeAll()
        viewerID = nil
    }

    func closePerson() {
        selectedPerson = nil
        selection.removeAll()
    }

    // MARK: - 画面人物名

    /// 这张照片里已命名的人（按当前范围：拾光 / 系统图库 / 网盘）。
    /// 结果按「人物名单」缓存，查看器重绘（缩放、悬停、翻页）不会反复扫聚类。
    func personNames(for photoID: UUID) -> [PhotoPersonName] {
        let key = photoPersonNamesKey
        if photoPersonNamesIndexKey != key {
            photoPersonNamesIndex = buildPhotoPersonNamesIndex()
            photoPersonNamesIndexKey = key
        }
        return photoPersonNamesIndex[photoID] ?? []
    }

    private var photoPersonNamesKey: String {
        if isCloudScope {
            let people = cloudPeople
            return "cloud|\(people.count)|\(people.reduce(0) { $0 + $1.assetIDs.count })|"
                + people.map(\.name).joined(separator: "\u{1}")
        }
        if isSystemScope {
            return "system|\(systemPeople.count)|\(systemPeople.reduce(0) { $0 + $1.assetIDs.count })|"
                + systemPeople.map(\.name).joined(separator: "\u{1}")
        }
        return "local|\(localPeople.count)|\(localPeople.reduce(0) { $0 + $1.assetIDs.count })|"
            + localPeople.map(\.name).joined(separator: "\u{1}")
    }

    private func buildPhotoPersonNamesIndex() -> [UUID: [PhotoPersonName]] {
        var index: [UUID: [PhotoPersonName]] = [:]
        func add(id: String, name: String, assetIDs: [UUID]) {
            guard let display = Self.displayablePersonName(name) else { return }
            let tag = PhotoPersonName(id: id, name: display)
            for assetID in assetIDs {
                var list = index[assetID, default: []]
                guard !list.contains(where: { $0.name == display }) else { continue }
                list.append(tag)
                index[assetID] = list
            }
        }
        if isCloudScope {
            for person in cloudPeople {
                add(id: "cloud-\(person.id)", name: person.name, assetIDs: person.assetIDs)
            }
        } else if isSystemScope {
            for person in systemPeople where !person.isPet {
                add(id: "system-\(person.id)", name: person.name, assetIDs: person.assetIDs)
            }
        } else {
            for person in localPeople {
                add(id: "local-\(person.id)", name: person.name, assetIDs: person.assetIDs)
            }
        }
        return index
    }

    /// 系统图库未命名的聚类叫「未命名」，本地聚类默认叫「人物 1」这类占位名；都别打到照片上。
    private static func displayablePersonName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "未命名" else { return nil }
        if trimmed.hasPrefix("人物 "), Int(trimmed.dropFirst(3)) != nil { return nil }
        return trimmed
    }

    // MARK: - 端侧人物聚类（本地图库）

    /// 懒加载已保存的人物聚类结果，避免启动时读取大量数据。
    func loadFaceDataIfNeeded() {
        guard !faceDataLoaded else { return }
        faceDataLoaded = true
        let stored = metadataStore?.loadPeople() ?? []
        // 照片被永久删除后，聚类里可能残留已不存在的关系；载入时就地清理，人物没有照片则移除。
        let known = Set(photos.map(\.id))
        let pruned = stored.compactMap { person -> LocalPerson? in
            var person = person
            person.assetIDs = person.assetIDs.filter { known.contains($0) }
            return person.assetIDs.isEmpty ? nil : person
        }
        localPeople = pruned
        if pruned != stored {
            metadataStore?.savePeople(pruned)
        }
        scannedFaceIDs = metadataStore?.loadScannedFaceIDs() ?? []
    }

    /// 还没做过人脸分析的照片数：增量识别的入口用它显示「剩余 N 张」。
    /// 按内容版本 + 已扫描数量缓存，避免侧边栏 / 工具栏重绘时反复遍历整库。
    var pendingFacePhotoCount: Int {
        let key = "\(contentRevision)|\(scannedFaceIDs.count)|\(photos.count)"
        if facePendingCacheKey != key {
            var count = 0
            for photo in photos where !photo.isVideo && photo.deletedAt == nil
                && !scannedFaceIDs.contains(photo.id) {
                count += 1
            }
            facePendingCacheValue = count
            facePendingCacheKey = key
        }
        return facePendingCacheValue
    }

    func startFaceClustering() {
        guard !isReadOnlyScope else {
            showToast("系统图库与网盘不支持人物分析")
            return
        }
        guard !isClusteringFaces else { return }
        loadFaceDataIfNeeded()

        let pending = photos.filter {
            !$0.isVideo && $0.deletedAt == nil && !scannedFaceIDs.contains($0.id)
        }
        guard !pending.isEmpty else {
            showToast("所有照片都已完成人物分析")
            return
        }

        let token = UUID()
        faceClusterToken = token
        isClusteringFaces = true
        faceClusterProgress = FaceClusterProgress(processed: 0,
                                                  total: pending.count,
                                                  faces: 0,
                                                  people: localPeople.count)
        let libraryPath = (LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
            .standardizedFileURL.path
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(libraryPath), kind: .cluster, title: "人脸聚类"),
            cancel: { [weak self] in
                Task { @MainActor in self?.cancelFaceClustering() }
            }
        )

        faceClusterTask = Task { [weak self] in
            guard let self else { return }
            var people = self.localPeople
            var scanned = self.scannedFaceIDs
            var faces = 0
            var processed = 0

            for photo in pending {
                if Task.isCancelled { break }
                let samples = await Task.detached(priority: .utility) {
                    FaceClusterEngine.analyze(photo: photo)
                }.value
                // 期间点了「重新识别」：旧任务不再写回。
                guard self.faceClusterToken == token else {
                    self.cancelSourceJob(jobID)
                    return
                }
                for sample in samples {
                    FaceClusterEngine.assign(sample, to: &people)
                    faces += 1
                }
                scanned.insert(photo.id)
                processed += 1

                if processed % 5 == 0 || processed == pending.count {
                    let refined = FaceClusterEngine.refined(people)
                    self.faceClusterProgress = FaceClusterProgress(processed: processed,
                                                                   total: pending.count,
                                                                   faces: faces,
                                                                   people: refined.count)
                    self.updateSourceJob(jobID,
                                         completed: processed,
                                         total: pending.count,
                                         message: "已分析 \(processed) / \(pending.count) 张 · \(refined.count) 位人物")
                }
                // 定期落盘，长时间分析中途退出也不会丢结果。
                if processed % 200 == 0 {
                    let refined = FaceClusterEngine.refined(people)
                    self.localPeople = refined
                    self.scannedFaceIDs = scanned
                    self.metadataStore?.savePeople(refined)
                    self.metadataStore?.saveScannedFaceIDs(scanned)
                }
            }

            guard self.faceClusterToken == token else {
                self.cancelSourceJob(jobID)
                return
            }
            let refined = FaceClusterEngine.refined(people)
            self.localPeople = refined
            self.scannedFaceIDs = scanned
            self.metadataStore?.savePeople(refined)
            self.metadataStore?.saveScannedFaceIDs(scanned)
            self.isClusteringFaces = false
            self.faceClusterProgress = nil
            self.faceClusterTask = nil

            if Task.isCancelled {
                self.cancelSourceJob(jobID)
                self.showToast("已停止人物分析")
            } else if refined.isEmpty {
                self.finishSourceJob(jobID, message: "分析完成 · 未发现人物")
                self.showToast("分析完成，未发现可聚类的人物")
            } else {
                self.finishSourceJob(jobID, message: "分析完成 · \(refined.count) 位人物")
                self.showToast("人物分析完成，共 \(refined.count) 位")
            }
        }
    }

    /// 清空已扫描记录与聚类结果，从头重新识别当前图库的全部照片。
    /// 人物命名也在聚类结果里，会被一并清除（界面上先做二次确认）。
    func resetFaceAnalysis() {
        guard !isReadOnlyScope else {
            showToast("系统图库与网盘不支持人物分析")
            return
        }
        loadFaceDataIfNeeded()
        // 换标识让正在跑的任务直接作废，避免它把旧结果写回来。
        faceClusterToken = UUID()
        faceClusterTask?.cancel()
        faceClusterTask = nil
        isClusteringFaces = false
        faceClusterProgress = nil
        scannedFaceIDs = []
        localPeople = []
        facePendingCacheKey = ""
        metadataStore?.savePeople([])
        metadataStore?.saveScannedFaceIDs([])
        startFaceClustering()
    }

    func cancelFaceClustering() {
        faceClusterTask?.cancel()
    }

    func closeLocalPerson() {
        selectedLocalPersonID = nil
    }

    /// 当前有可见照片的人物：照片全部移入最近删除或被隐藏后不再展示，恢复后自动回来。
    var visibleLocalPeople: [LocalPerson] {
        guard faceDataLoaded, !localPeople.isEmpty else { return localPeople }
        let alive = Set(photos.lazy.filter { $0.deletedAt == nil && !$0.isHidden }.map(\.id))
        guard !alive.isEmpty else { return [] }
        return localPeople.filter { person in
            person.assetIDs.contains { alive.contains($0) }
        }
    }

    /// 永久删除照片后清理人物聚类里的引用；人物一张照片都不剩时一并移除。
    func removeAssetsFromLocalPeople(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        loadFaceDataIfNeeded()
        guard !localPeople.isEmpty else { return }

        var pruned: [LocalPerson] = []
        pruned.reserveCapacity(localPeople.count)
        var changed = false
        for person in localPeople {
            var person = person
            let remaining = person.assetIDs.filter { !ids.contains($0) }
            if remaining.count != person.assetIDs.count {
                person.assetIDs = remaining
                changed = true
            }
            guard !remaining.isEmpty else {
                changed = true
                continue
            }
            pruned.append(person)
        }
        guard changed else { return }

        localPeople = pruned
        if let selected = selectedLocalPersonID, !pruned.contains(where: { $0.id == selected }) {
            selectedLocalPersonID = nil
        }
        metadataStore?.savePeople(pruned)
    }

    func photos(for person: LocalPerson) -> [PhotoItem] {
        let ids = Set(person.assetIDs)
        return photos
            .filter { ids.contains($0.id) && $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// 本地人物的「摘要」：年度轨迹、时段偏好、地点、同框人物与高光照片。
    func localPersonInsight(for person: LocalPerson) -> PersonInsight {
        var insight = PersonInsight.make(photos: photos(for: person))
        let mine = Set(person.assetIDs)
        insight.companions = visibleLocalPeople
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

    /// 系统图库人物的「摘要」：索引可用时由 SQLite 聚合，否则在内存快照上派生。
    func systemPersonInsight(for person: SystemPersonInfo) -> PersonInsight {
        if let index = systemIndex {
            return index.personInsight(personInsightQuery(for: person))
        }

        let ids = Set(person.assetIDs)
        var insight = PersonInsight.make(photos: systemPhotos
            .filter { ids.contains($0.id) && $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt > $1.capturedAt })
        insight.companions = systemPeople
            .filter { $0.id != person.id }
            .compactMap { other -> PersonInsight.Companion? in
                let shared = ids.intersection(other.assetIDs).count
                guard shared >= 2 else { return nil }
                return PersonInsight.Companion(id: "system-\(other.id)",
                                               name: other.name,
                                               count: shared,
                                               coverPhotoID: other.keyAssetID ?? other.assetIDs.first,
                                               coverData: other.cropData)
            }
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { $0 }
        return insight
    }

    /// 人物摘要只看这个人本身，不继承当前的筛选 / 搜索 / 排序。
    private func personInsightQuery(for person: SystemPersonInfo) -> SystemQuery {
        var query = buildSystemQuery(scope: .person(person.id))
        query.filter = .all
        query.sortKey = .capturedAt
        query.ascending = false
        query.startDate = nil
        query.endDate = nil
        query.onlyFavorites = false
        query.onlyVideos = false
        query.onlyPhotos = false
        query.onlyScreenshots = false
        query.onlyLivePhotos = false
        query.onlyEdited = false
        query.tokens = []
        query.overlayKeywordIDs = nil
        query.includeIDs = nil
        return query
    }

    /// 直连模式下人物摘要是若干次大库聚合，放到后台执行，避免切人物时卡住主线程。
    func systemPersonInsightAsync(for person: SystemPersonInfo) async -> PersonInsight {
        guard let index = systemIndex, index.direct != nil else {
            return systemPersonInsight(for: person)
        }
        let query = personInsightQuery(for: person)
        return await Task.detached(priority: .userInitiated) {
            index.personInsight(query)
        }.value
    }

    // MARK: - 人物地图

    /// 本地人物的「地图」：只看这个人带有效定位的照片。
    func personMapPhotos(local person: LocalPerson) -> [PhotoItem] {
        photos(for: person).filter { $0.hasLocation }
    }

    /// 系统图库人物的「地图」：索引直接在 SQL 里裁掉没有定位的照片；
    /// 不走分页窗口，保证地图上是这个人的全量足迹。
    func personMapPhotos(system person: SystemPersonInfo) async -> [PhotoItem] {
        guard let index = systemIndex else {
            // 扫描快照模式：人物成员 ID 已在内存里，直接过滤。
            let ids = Set(person.assetIDs)
            return systemPhotos
                .filter { ids.contains($0.id) && $0.deletedAt == nil && !$0.isHidden && $0.hasLocation }
                .sorted { $0.capturedAt > $1.capturedAt }
        }
        var query = personInsightQuery(for: person)
        query.onlyLocated = true
        let located = await Task.detached(priority: .userInitiated) {
            index.page(query, offset: 0, limit: 60_000)
        }.value
        return located.filter { $0.hasLocation }
    }

    /// 统计经常同框的人物对（同一张照片里同时出现）。
    func peoplePairs(limit: Int = 8) -> [PeoplePair] {
        var assetPeople: [UUID: [UUID]] = [:]
        for person in visibleLocalPeople {
            for asset in person.assetIDs {
                assetPeople[asset, default: []].append(person.id)
            }
        }

        var counts: [String: Int] = [:]
        var lookup: [String: PeoplePair] = [:]
        for ids in assetPeople.values where ids.count >= 2 {
            let unique = Set(ids).sorted { $0.uuidString < $1.uuidString }
            guard unique.count >= 2 else { continue }
            for i in 0..<unique.count {
                for j in (i + 1)..<unique.count {
                    let pair = PeoplePair(a: unique[i], b: unique[j], count: 0)
                    lookup[pair.id] = pair
                    counts[pair.id, default: 0] += 1
                }
            }
        }

        return counts.filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { entry in
                guard let pair = lookup[entry.key] else { return nil }
                return PeoplePair(a: pair.a, b: pair.b, count: entry.value)
            }
    }

    /// 两位人物同时出现的照片。
    func photos(for pair: PeoplePair) -> [PhotoItem] {
        guard let first = localPeople.first(where: { $0.id == pair.a }),
              let second = localPeople.first(where: { $0.id == pair.b }) else { return [] }
        let shared = Set(first.assetIDs).intersection(second.assetIDs)
        guard !shared.isEmpty else { return [] }
        return photos
            .filter { shared.contains($0.id) && $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    func renameLocalPerson(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = localPeople.firstIndex(where: { $0.id == id }) else { return }
        localPeople[index].name = trimmed
        metadataStore?.savePeople(localPeople)
    }

    func deleteLocalPerson(_ id: UUID) {
        localPeople.removeAll { $0.id == id }
        if selectedLocalPersonID == id {
            selectedLocalPersonID = nil
        }
        metadataStore?.savePeople(localPeople)
    }

    func resetFaceClusterState() {
        faceClusterTask?.cancel()
        faceClusterTask = nil
        localPeople = []
        selectedLocalPersonID = nil
        faceClusterProgress = nil
        isClusteringFaces = false
        scannedFaceIDs = []
        faceDataLoaded = false
    }

    // MARK: - Duplicates

    /// 本地图库中按「文件大小 + 像素尺寸」聚合的重复组（含建议保留项与理由）。
    /// 结果按内容版本缓存，避免侧边栏与重复页反复遍历、排序整库。
    var duplicateGroups: [DuplicateGroup] {
        let key = "\(contentRevision)"
        if duplicateGroupsCacheKey == key { return duplicateGroupsCache }
        var membership: [UUID: Int] = [:]
        for album in albums {
            for id in album.photoIDs {
                membership[id, default: 0] += 1
            }
        }
        let groups = DuplicateDetector.groups(from: photos, albumMembership: membership)
        duplicateGroupsCacheKey = key
        duplicateGroupsCache = groups
        return groups
    }

    /// 多余的副本张数（每个重复组只保留一张）。
    var duplicateCount: Int {
        duplicateGroups.reduce(0) { $0 + $1.photos.count - 1 }
    }

    /// 合并一组重复项目：保留 `keepID`，把其余副本的收藏、关键词、标题、地点与相簿关系汇总过来，
    /// 再将这些副本移入最近删除（30 天内可恢复）。返回被移入最近删除的张数。
    @discardableResult
    func mergeDuplicateGroup(_ group: DuplicateGroup, keeping keepID: UUID) -> Int {
        let beforePhotos = photoSnapshot(Set(group.photos.map(\.id)))
        let beforeAlbums = albums
        let removed = applyDuplicateMerge(group.photos, keeping: keepID)
        guard removed > 0 else { return 0 }
        save()
        recordUndo("合并重复项目", beforePhotos: beforePhotos, beforeAlbums: beforeAlbums)
        showToast("已合并 \(removed + 1) 个项目，保留 1 个版本")
        return removed
    }

    /// 一键合并全部重复组：每组保留推荐版本，只落盘一次。返回（组数，移入最近删除的张数）。
    @discardableResult
    func mergeAllDuplicateGroups() -> (groups: Int, removed: Int) {
        guard !isReadOnlyScope else { return (0, 0) }
        let beforePhotos = photoSnapshot(Set(duplicateGroups.flatMap { $0.photos.map(\.id) }))
        let beforeAlbums = albums
        var mergedGroups = 0
        var removed = 0
        for group in duplicateGroups {
            let count = applyDuplicateMerge(group.photos, keeping: group.keepID)
            if count > 0 {
                mergedGroups += 1
                removed += count
            }
        }
        guard removed > 0 else { return (0, 0) }
        save()
        recordUndo("合并全部重复项目", beforePhotos: beforePhotos, beforeAlbums: beforeAlbums)
        showToast("已合并 \(mergedGroups) 组重复项目，\(removed) 个副本移入最近删除")
        return (mergedGroups, removed)
    }

    /// 在内存中完成合并（不落盘），供单组与批量合并共用。
    private func applyDuplicateMerge(_ members: [PhotoItem], keeping keepID: UUID) -> Int {
        guard !isReadOnlyScope,
              let keepIndex = photos.firstIndex(where: { $0.id == keepID }) else { return 0 }
        let removeIDs = Set(members.map(\.id)).subtracting([keepID])
        guard !removeIDs.isEmpty else { return 0 }

        var kept = photos[keepIndex]
        var keywords = Set(kept.keywords ?? [])
        for other in members where removeIDs.contains(other.id) {
            kept.isFavorite = kept.isFavorite || other.isFavorite
            if other.starRating > kept.starRating { kept.rating = other.rating }
            if kept.pickFlag == .none, other.pickFlag != .none { kept.flag = other.flag }
            if kept.labelColor == .none, other.labelColor != .none { kept.colorLabel = other.colorLabel }
            if kept.contentHash == nil { kept.contentHash = other.contentHash }
            if kept.perceptualHash == nil { kept.perceptualHash = other.perceptualHash }
            keywords.formUnion(other.keywords ?? [])
            if (kept.title ?? "").isEmpty, let title = other.title, !title.isEmpty {
                kept.title = title
            }
            if kept.capturedAt > other.capturedAt {
                kept.capturedAt = other.capturedAt
            }
            if let viewed = other.viewedAt, viewed > (kept.viewedAt ?? .distantPast) {
                kept.viewedAt = viewed
            }
            if kept.latitude == nil, let latitude = other.latitude, let longitude = other.longitude {
                kept.latitude = latitude
                kept.longitude = longitude
            }
            if kept.placeCountry == nil { kept.placeCountry = other.placeCountry }
            if kept.placeProvince == nil { kept.placeProvince = other.placeProvince }
            if kept.placeCity == nil { kept.placeCity = other.placeCity }
            if kept.placeDistrict == nil { kept.placeDistrict = other.placeDistrict }
            if kept.placePOI == nil { kept.placePOI = other.placePOI }
        }
        if !keywords.isEmpty {
            kept.keywords = Array(keywords).sorted()
        }
        photos[keepIndex] = kept

        let now = Date()
        for index in photos.indices where removeIDs.contains(photos[index].id) {
            photos[index].deletedAt = now
        }

        // 相簿关系汇总：保留项补进副本所在的相簿，并修正被删副本占用的封面。
        for index in albums.indices {
            let containedRemoved = albums[index].photoIDs.contains { removeIDs.contains($0) }
            albums[index].photoIDs.removeAll { removeIDs.contains($0) }
            if containedRemoved, !albums[index].photoIDs.contains(keepID) {
                albums[index].photoIDs.insert(keepID, at: 0)
            }
            if let cover = albums[index].coverPhotoID, removeIDs.contains(cover) {
                albums[index].coverPhotoID = keepID
            }
        }

        if let viewerID, removeIDs.contains(viewerID) {
            self.viewerID = nil
        }
        selection.removeAll()
        duplicateGroupsCacheKey = nil
        return removeIDs.count
    }

    /// 「位置」页首次打开时等后台地图样本就绪，避免在只取到最近几张的旧样本上做逆地理编码。
    func awaitDirectGeoIfNeeded() async {
        guard let index = systemIndex, index.direct != nil else { return }
        if let task = index.directGeoWarmupTask { await task.value }
    }

    /// 照片缺少地名时，用系统逆地理编码补齐（结果写入本地缓存）。
    /// 官方图库只补内存，不回写数据库。
    /// 解析会按网格分批推进，直到没有缺失坐标为止；中途失败（系统限流）会再补两轮。
    func resolveMissingPlacesIfNeeded() {
        if isCloudScope {
            resolveMissingCloudPlacesIfNeeded()
            return
        }
        guard !isResolvingPlaces else { return }
        // 系统图库索引模式用地图的全量带位置照片补齐地名，不遍历整库。
        let source: [PhotoItem]
        if isSystemScope {
            source = systemIndex != nil ? geoPhotos : systemPhotos
        } else {
            source = photos
        }
        let missing = source.filter {
            $0.deletedAt == nil
                && $0.hasLocation
                && $0.placeCity == nil && $0.placeDistrict == nil && $0.placeProvince == nil
        }
        guard !missing.isEmpty else { return }
        loadPlaceCacheIfNeeded()

        var grouped: [String: (latitude: Double, longitude: Double, ids: [UUID])] = [:]
        for photo in missing {
            guard let latitude = photo.latitude, let longitude = photo.longitude else { continue }
            let key = Self.placeResolveKey(latitude: latitude, longitude: longitude)
            // 本次会话已经失败的格子不再反复请求；重启应用后会重新尝试。
            guard !placeResolveFailedKeys.contains(key) else { continue }
            if var entry = grouped[key] {
                entry.ids.append(photo.id)
                grouped[key] = entry
            } else {
                grouped[key] = (latitude, longitude, [photo.id])
            }
        }
        // 同格照片越多越优先：先补大块，「其他地点」能最快缩下去。
        let entries = grouped.values.sorted { $0.ids.count > $1.ids.count }
        guard !entries.isEmpty else { return }

        let scopedToSystemLibrary = isSystemScope
        let usesDirectGeo = systemIndex?.direct != nil
        isResolvingPlaces = true
        placeResolveTotal = entries.count
        placeResolveDone = 0
        let placesPath = scopedToSystemLibrary
            ? (systemLibraryPath ?? "")
            : (LibraryPaths.containerLibraryURL ?? LibraryPaths.root).standardizedFileURL.path
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(placesPath),
                      kind: .places,
                      title: "补齐照片地点",
                      isCancellable: false)
        )

        Task { [weak self] in
            guard let self else { return }
            // 先建一次 id → 下标索引：逐条地理编码时再扫整库会是大图库的主要卡顿来源。
            var mediaIndices: [UUID: Int] = [:]
            var geoIndices: [UUID: Int] = [:]
            // 直连模式的地图数据在 directGeoPhotos 里，不是 systemGeoCache：
            // 之前往 systemGeoCache 写，地名永远落不进去，missing 不减就等于无限循环。
            var directGeoWorking: [PhotoItem] = []
            if scopedToSystemLibrary {
                if usesDirectGeo, let directGeo = self.systemIndex?.directGeoPhotos {
                    directGeoWorking = directGeo
                    for (index, photo) in directGeo.enumerated() { geoIndices[photo.id] = index }
                } else if self.systemIndex != nil {
                    for (index, photo) in self.systemGeoCache.enumerated() { geoIndices[photo.id] = index }
                } else {
                    for (index, photo) in self.systemPhotos.enumerated() { mediaIndices[photo.id] = index }
                }
            } else {
                for (index, photo) in self.photos.enumerated() { mediaIndices[photo.id] = index }
            }

            var pending = entries
            var attempt = 0
            while !pending.isEmpty, attempt < 3 {
                if attempt > 0 {
                    // 系统逆地理编码会限流：失败的坐标隔几秒再补一轮，仍失败就记下来不再空转。
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                attempt += 1
                var failed: [(latitude: Double, longitude: Double, ids: [UUID])] = []
                while !pending.isEmpty {
                    let chunk = Array(pending.prefix(Self.placeResolveBatchLimit))
                    pending.removeFirst(chunk.count)
                    for entry in chunk {
                        let cacheKey = Self.placeResolveKey(latitude: entry.latitude,
                                                           longitude: entry.longitude)
                        var info: PlaceInfo?
                        if let cached = self.placeCache[cacheKey], !cached.isEmpty {
                            info = cached
                        } else {
                            info = await self.reverseGeocode(latitude: entry.latitude,
                                                             longitude: entry.longitude)
                            if info == nil { failed.append(entry) }
                        }
                        if let info {
                            if scopedToSystemLibrary {
                                if usesDirectGeo {
                                    for id in entry.ids {
                                        guard let index = geoIndices[id], index < directGeoWorking.count,
                                              directGeoWorking[index].id == id else { continue }
                                        self.applyPlace(info, to: &directGeoWorking[index])
                                    }
                                } else if self.systemIndex != nil {
                                    for id in entry.ids {
                                        // 后台样本 / 地图缓存随时可能整体替换，越界或错位就跳过。
                                        guard let index = geoIndices[id], index < self.systemGeoCache.count,
                                              self.systemGeoCache[index].id == id else { continue }
                                        self.applyPlace(info, to: &self.systemGeoCache[index])
                                    }
                                } else {
                                    for id in entry.ids {
                                        guard let index = mediaIndices[id], index < self.systemPhotos.count,
                                              self.systemPhotos[index].id == id else { continue }
                                        self.applyPlace(info, to: &self.systemPhotos[index])
                                    }
                                }
                            } else {
                                for id in entry.ids {
                                    guard let index = mediaIndices[id], index < self.photos.count,
                                          self.photos[index].id == id else { continue }
                                    self.applyPlace(info, to: &self.photos[index])
                                }
                            }
                        }
                        if attempt == 1 {
                            self.placeResolveDone += 1
                            self.updateSourceJob(jobID,
                                                 completed: self.placeResolveDone,
                                                 total: entries.count,
                                                 message: "已补齐 \(self.placeResolveDone) / \(entries.count) 个地点")
                        }
                        if info == nil {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                    }
                    // 每批结束就把结果递给界面：几百个坐标解析下来不必等全部结束才更新。
                    if usesDirectGeo, !directGeoWorking.isEmpty {
                        self.systemIndex?.directGeoPhotos = directGeoWorking
                        // geoPhotos 按 systemIndexSignature 缓存，地名是内存里补的，必须让它重新取样。
                        self.systemGeoCacheKey = nil
                    }
                    self.resetPlaceClusterCaches()
                    self.contentRevision &+= 1
                    self.objectWillChange.send()
                    self.savePlaceCache()
                }
                pending = failed
            }
            for entry in pending {
                self.placeResolveFailedKeys.insert(Self.placeResolveKey(latitude: entry.latitude,
                                                                       longitude: entry.longitude))
            }
            if !scopedToSystemLibrary {
                self.save()
            }
            // 新解析出的地名要让地点聚类重新计算，并通知界面刷新。
            self.resetPlaceClusterCaches()
            self.contentRevision &+= 1
            self.objectWillChange.send()
            self.savePlaceCache()
            self.isResolvingPlaces = false
            self.finishSourceJob(jobID, message: "已补齐 \(self.placeResolveDone) 个地点")
        }
    }

    func applyPlace(_ info: PlaceInfo, to photo: inout PhotoItem) {
        photo.placeCountry = info.country
        photo.placeProvince = info.province
        photo.placeCity = info.city
        photo.placeDistrict = info.district
        photo.placePOI = info.poi
    }

    func reverseGeocode(latitude: Double, longitude: Double) async -> PlaceInfo? {
        let key = Self.placeResolveKey(latitude: latitude, longitude: longitude)
        if let cached = placeCache[key], !cached.isEmpty { return cached }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        if let placemarks = try? await geocoder.reverseGeocodeLocation(
            location, preferredLocale: Locale(identifier: "zh_CN")
        ), let placemark = placemarks.first {
            var info = PlaceInfo(country: placemark.country,
                                 province: placemark.administrativeArea,
                                 city: placemark.locality ?? placemark.subAdministrativeArea,
                                 district: placemark.subLocality,
                                 poi: placemark.thoroughfare)
            // 海上 / 景区坐标常常只有 name，没有行政区字段；用它兜底，至少别退回坐标卡片。
            if info.isEmpty { info.poi = placemark.name }
            if !info.isEmpty {
                placeCache[key] = info
                return info
            }
        }
        // 系统逆地理编码在境外坐标上会直接返回空结果，这里用内置城市库补到城市级。
        if let fallback = await WorldCityIndex.shared.place(latitude: latitude,
                                                            longitude: longitude) {
            placeCache[key] = fallback
            return fallback
        }
        // 空结果不写缓存：限流或网络失败时下次还能重试。
        return nil
    }

    func loadPlaceCacheIfNeeded() {
        guard !placeCacheLoaded else { return }
        placeCacheLoaded = true
        guard let data = try? Data(contentsOf: Self.placeCacheURL),
              let decoded = try? JSONDecoder().decode([String: PlaceInfo].self, from: data) else { return }
        placeCache = decoded
    }

    func savePlaceCache() {
        guard let data = try? JSONEncoder().encode(placeCache) else { return }
        try? data.write(to: Self.placeCacheURL, options: .atomic)
    }

    static var placeCacheURL: URL {
        LibraryPaths.applicationRoot.appendingPathComponent("PlaceCache.json")
    }

    var shareURLs: [URL] {
        let ids: [UUID]
        if !selection.isEmpty {
            ids = Array(selection)
        } else if let viewerID {
            ids = [viewerID]
        } else {
            ids = []
        }
        return ids.compactMap { anyPhoto(id: $0) }
            .filter { !$0.isCloud }
            .prefix(10)
            .map { LibraryPaths.sourceURL(for: $0) }
    }

    var currentIsFavorite: Bool {
        if let viewerID, let photo = anyPhoto(id: viewerID) {
            return photo.isFavorite
        }
        let selected = selection.compactMap { anyPhoto(id: $0) }
        return !selected.isEmpty && selected.allSatisfy { $0.isFavorite }
    }

    func containsInCurrentView(_ id: UUID) -> Bool {
        visiblePhotos.contains(where: { $0.id == id })
    }
}
