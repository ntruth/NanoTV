import Foundation

/// 视频页的数据编排：只从 Store 派生，视图不持有任何照片数组。
/// 首次进入先用分页窗口画一屏，同时在后台把整库视频元数据聚合一次；
/// 之后统计、筛选与分组都在完整列表上完成，不再出现「只统计已载入」的说法。
@MainActor
extension LibraryStore {
    /// 顶栏统计胶囊：段数 + 总时长；汇总过程中明确提示，而不是暴露分页细节。
    var videoHubStatsText: String {
        let data = videoHubData
        if videoHubFilter.isActive {
            return "\(data.videos.count.formatted()) 段 · \(videoHubTotalDurationText(data.videos))"
        }
        if isVideoHubLoading, videoHubFullVideos.isEmpty {
            let total = max(visibleCount, data.videos.count)
            return "\(total.formatted()) 段 · 正在汇总…"
        }
        let total = max(visibleCount, data.videos.count)
        return "\(total.formatted()) 段 · \(videoHubTotalDurationText(data.videos))"
    }

    /// 缓存指纹变化时才重算：完整列表、筛选条件、人物数据任一变化都会触发。
    func refreshVideoHubIfNeeded(force: Bool = false) {
        let fullToken = videoHubFullTokenKey
        let token = [
            fullToken,
            videoHubFilter.summary,
            String(videoHubFullVideos.count),
            String(localPeople.count),
            String(systemPeople.count)
        ].joined(separator: "\u{1F}")
        guard force || token != videoHubCacheToken else { return }
        videoHubCacheToken = token

        if videoHubFullToken == fullToken {
            rebuildVideoHubData(from: videoHubFullVideos)
        } else {
            // 先用当前分页窗口画一屏，避免整页空白；完整聚合在后台继续。
            rebuildVideoHubData(from: quickVideoSnapshot())
            startFullVideoHubLoad(token: fullToken)
        }
    }

    private var videoHubFullTokenKey: String {
        [systemIndexSignature,
         String(contentRevision),
         String(isSystemScope),
         sidebarItem.videoHubScopeKey].joined(separator: "\u{1F}")
    }

    private func quickVideoSnapshot() -> [PhotoItem] {
        visiblePhotos
            .filter { $0.isVideo && $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// 后台读取整库视频：本地库直接取内存，系统图库按索引分页直到取完。
    private func startFullVideoHubLoad(token: String) {
        guard videoHubLoadingToken != token else { return }
        videoHubLoadingToken = token
        videoHubLoadTask?.cancel()
        isVideoHubLoading = true

        if !isNativeContainer {
            let all = photos(for: .videos)
                .filter { $0.isVideo && $0.deletedAt == nil && !$0.isHidden }
                .sorted { $0.capturedAt > $1.capturedAt }
            videoHubFullVideos = all
            videoHubFullToken = token
            isVideoHubLoading = false
            videoHubCacheToken = ""
            rebuildVideoHubData(from: all)
            return
        }

        guard let index = systemIndex else {
            // 索引还没就绪：窗口数据先用着，等索引签名变化后再重试。
            isVideoHubLoading = false
            videoHubLoadingToken = ""
            return
        }

        var query = buildSystemQuery(scope: .videos)
        // 视频页有自己的筛选，不继承其它页面的照片筛选 / 搜索。
        query.filter = .all
        query.sortKey = .capturedAt
        query.ascending = false
        query.manualOrder = false
        query.startDate = nil
        query.endDate = nil
        query.onlyFavorites = false
        query.onlyVideos = false
        query.onlyPhotos = false
        query.onlyScreenshots = false
        query.onlyLivePhotos = false
        query.onlyEdited = false
        query.onlyLocated = false
        query.tokens = []
        query.tokenPlaceIDs = nil
        query.overlayKeywordIDs = nil
        query.includeIDs = nil
        query.savedCutoff = nil
        query.viewedCutoff = nil

        let pageSize = 2000
        videoHubLoadTask = Task { [weak self] in
            let raw = await Task.detached(priority: .utility) {
                var items: [PhotoItem] = []
                var offset = 0
                while true {
                    let page = index.page(query, offset: offset, limit: pageSize)
                    if page.isEmpty { break }
                    items.append(contentsOf: page)
                    offset += page.count
                    if page.count < pageSize { break }
                    if items.count >= 100_000 { break }
                }
                return items
            }.value
            guard let self, !Task.isCancelled else { return }
            let all = raw
                .map { self.applySystemOverlay($0) }
                .filter { $0.isVideo && $0.deletedAt == nil && !$0.isHidden }
                .sorted { $0.capturedAt > $1.capturedAt }
            self.videoHubFullVideos = all
            self.videoHubFullToken = token
            self.videoHubLoadingToken = ""
            self.isVideoHubLoading = false
            self.videoHubCacheToken = ""
            self.rebuildVideoHubData(from: all)
        }
    }

    private func rebuildVideoHubData(from all: [PhotoItem]) {
        let calendar = Calendar.current
        var next = VideoHubData()
        next.availableYears = Array(Set(all.map {
            calendar.component(.year, from: $0.capturedAt)
        })).sorted(by: >)

        let filtered = all.filter { photo in
            if let year = videoHubFilter.year,
               calendar.component(.year, from: photo.capturedAt) != year {
                return false
            }
            if let duration = videoHubFilter.duration,
               !duration.contains(photo.duration) {
                return false
            }
            return true
        }

        next.videos = filtered
        next.recent = Array(filtered.sorted { $0.addedAt > $1.addedAt }.prefix(8))
        next.long = Array(filtered.filter { ($0.duration ?? 0) >= 180 }.prefix(8))
        next.situations = Array(filtered.filter(videoHubIsSituation).prefix(8))
        next.years = makeVideoYearGroups(filtered)
        next.durations = makeVideoDurationGroups(filtered)
        next.places = makeVideoPlaceGroups(filtered)
        next.people = makeVideoPeopleGroups(filtered)
        next.totalDuration = filtered.compactMap(\.duration).reduce(0, +)
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        next.recentCount = filtered.lazy.filter { $0.addedAt >= cutoff }.count
        next.longest = filtered.max { ($0.duration ?? 0) < ($1.duration ?? 0) }
        videoHubData = next
    }

    private func makeVideoYearGroups(_ videos: [PhotoItem]) -> [VideoGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: videos) {
            calendar.component(.year, from: $0.capturedAt)
        }
        return grouped.keys.sorted(by: >).map { year in
            let items = (grouped[year] ?? []).sorted { $0.capturedAt > $1.capturedAt }
            return VideoGroup(id: "year-\(year)",
                              title: "\(year)",
                              detail: videoHubTotalDurationText(items),
                              videos: items)
        }
    }

    private func makeVideoDurationGroups(_ videos: [PhotoItem]) -> [VideoGroup] {
        VideoDurationBand.allCases.compactMap { band in
            let items = videos.filter { band.contains($0.duration) }
            guard !items.isEmpty else { return nil }
            return VideoGroup(id: "duration-\(band.rawValue)",
                              title: band.title,
                              detail: band.detail,
                              videos: items)
        }
    }

    private func makeVideoPlaceGroups(_ videos: [PhotoItem]) -> [VideoGroup] {
        let grouped = Dictionary(grouping: videos) { videoHubPlaceName($0) ?? "未标注地点" }
        return grouped.map { key, items in
            VideoGroup(id: "place-\(key)",
                       title: key,
                       detail: videoHubTotalDurationText(items),
                       videos: items.sorted { $0.capturedAt > $1.capturedAt })
        }
        .sorted { lhs, rhs in
            if lhs.title == "未标注地点" { return false }
            if rhs.title == "未标注地点" { return true }
            return lhs.videos.count > rhs.videos.count
        }
    }

    private func makeVideoPeopleGroups(_ videos: [PhotoItem]) -> [VideoGroup] {
        guard !videos.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
        let entries: [(String, [UUID])]
        if isSystemScope {
            entries = systemPeople.map {
                ($0.isUnnamed ? "未命名人物" : $0.name, $0.assetIDs)
            }
        } else {
            entries = visibleLocalPeople.map {
                ($0.isUnnamed ? "未命名人物" : $0.name, $0.assetIDs)
            }
        }
        var groups: [VideoGroup] = []
        for (index, entry) in entries.enumerated() {
            let items = entry.1.compactMap { byID[$0] }
                .sorted { $0.capturedAt > $1.capturedAt }
            guard !items.isEmpty else { continue }
            groups.append(VideoGroup(id: "person-\(index)-\(entry.0)",
                                     title: entry.0,
                                     detail: videoHubTotalDurationText(items),
                                     videos: items))
        }
        return groups.sorted { $0.videos.count > $1.videos.count }
    }
}

private extension SidebarItem {
    /// 视频页的缓存身份：本地视频与系统视频各自独立。
    var videoHubScopeKey: String {
        switch self {
        case .systemVideos: return "systemVideos"
        default: return "videos"
        }
    }
}
