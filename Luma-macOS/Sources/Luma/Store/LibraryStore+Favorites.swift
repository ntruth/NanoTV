import Foundation

/// 「个人收藏」汇总：一次性载入完整收藏列表，再在内存里生成分类卡片与下钻过滤。
/// 系统图库索引模式不会把整库照片读进内存，这里只取收藏范围。
extension LibraryStore {
    /// 汇总最多统计的收藏数量，避免超大系统图库一次性解码过多。
    static let favoritesDigestLimit = 30_000

    /// 影响汇总内容的状态指纹：收藏变化、系统索引变化、人物数据到达都会刷新。
    /// 系统图库只看收藏叠加的版本，不跟着 `contentRevision`（后台计数 / 识别回填也会改它）：
    /// 上万条收藏的汇总重建一次要几秒，启动阶段被连续触发就会一直卡在加载态。
    var favoritesDigestToken: String {
        var parts = [
            systemIndexSignature,
            String(isSystemScope),
            String(systemFavoritesRevision),
            String(systemOverlays.count),
            String(systemPhotos.count),
            String(localPeople.count),
            String(systemPeople.count)
        ]
        if !isSystemScope { parts.append(String(contentRevision)) }
        return parts.joined(separator: "\u{1F}")
    }

    func loadFavoritesDigestIfNeeded(force: Bool = false) {
        guard isFavoritesScope, !needsLibrarySetup else { return }
        // 系统图库还在读取、索引尚未就绪时先保持加载态，等 token 变化自动重试。
        if isSystemScope, systemIndex == nil, isLoadingSystemLibrary { return }
        let token = favoritesDigestToken
        if !force, favoritesDigest != nil, favoritesDigestLoadedToken == token { return }
        favoritesDigestTask?.cancel()
        // 合并连续触发（启动阶段计数 / 识别回填会连续改动状态），避免上万条收藏反复重建。
        let debounce: UInt64 = force ? 0 : 350_000_000

        // 系统图库索引模式：收藏范围下推到索引，只取这一批照片。
        // 计数、分页与分组全部在后台完成：收藏可能上万条，放在主线程会直接卡住界面。
        if isSystemScope, systemPhotos.isEmpty, let index = systemIndex {
            isLoadingFavoritesDigest = true
            var query = buildSystemQuery(scope: .favorites)
            query.filter = .all
            query.sortKey = .capturedAt
            query.ascending = false
            query.startDate = nil
            query.endDate = nil
            query.tokens = []
            query.onlyFavorites = false
            query.onlyVideos = false
            query.onlyPhotos = false
            query.onlyScreenshots = false
            query.onlyLivePhotos = false
            query.onlyEdited = false
            query.overlayKeywordIDs = nil
            query.includeIDs = nil
            // 补充元数据先快照一份，后台线程用它叠加，不再回主线程逐条取。
            let overlays = systemOverlays
            let nativeKeywords = systemNativeKeywordIDMap
            let isNative = isNativeContainer
            let people = favoritesPeopleSources()
            let cap = Self.favoritesDigestLimit
            favoritesDigestTask = Task.detached(priority: .utility) { [weak self] in
                if debounce > 0 {
                    try? await Task.sleep(nanoseconds: debounce)
                    if Task.isCancelled { return }
                }
                let total = index.summary(query).total
                let limit = min(total, cap)
                var photos: [PhotoItem] = []
                photos.reserveCapacity(limit)
                // 按 2000 张一批取：既能尽早响应取消，也不会让单次查询占满内存带宽。
                while photos.count < limit {
                    if Task.isCancelled { return }
                    let chunk = min(2_000, limit - photos.count)
                    let page = index.page(query, offset: photos.count, limit: chunk)
                    if page.isEmpty { break }
                    photos.append(contentsOf: page.map {
                        LibraryStore.applyingOverlays($0,
                                                      overlays: overlays,
                                                      nativeKeywords: nativeKeywords,
                                                      isNative: isNative)
                    })
                }
                if Task.isCancelled { return }
                let digest = FavoritesDigestBuilder.make(photos: photos,
                                                         people: people,
                                                         isLimited: total > photos.count)
                await MainActor.run {
                    guard let self,
                          self.favoritesDigestToken == token,
                          self.isFavoritesScope else { return }
                    self.applyFavoritesDigest(photos, digest: digest, token: token)
                }
            }
            return
        }

        let source: [PhotoItem]
        if isSystemScope {
            source = systemPhotos.filter { $0.deletedAt == nil && !$0.isHidden && $0.isFavorite }
        } else {
            loadFaceDataIfNeeded()
            source = photos(for: .favorites)
        }
        let people = favoritesPeopleSources()
        isLoadingFavoritesDigest = true
        favoritesDigestTask = Task.detached(priority: .utility) { [weak self] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: debounce)
                if Task.isCancelled { return }
            }
            let digest = FavoritesDigestBuilder.make(photos: source, people: people, isLimited: false)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.favoritesDigestToken == token else { return }
                self.applyFavoritesDigest(source, digest: digest, token: token)
            }
        }
    }

    /// 收藏按年份的快速总览：直接来自后台计数快照的月度收藏数（ZMOMENT 同源的收藏部分索引），
    /// 不读任何照片行就能立刻画出「按年份」卡片墙的准确数量，作为正式汇总到达前的骨架。
    var favoritesQuickYearBuckets: [(year: String, count: Int)] {
        guard isSystemScope,
              let months = systemIndex?.directCounts?.monthFavorites,
              !months.isEmpty else { return [] }
        var byYear: [String: Int] = [:]
        for (period, count) in months {
            guard let year = period.split(separator: "-").first else { continue }
            byYear[String(year), default: 0] += count
        }
        return byYear.sorted { $0.key > $1.key }.map { (year: $0.key, count: $0.value) }
    }

    /// 快速总览的收藏总数（后台计数快照），没有快照时为 nil。
    var favoritesQuickTotal: Int? {
        guard isSystemScope, let index = systemIndex, let counts = index.directCounts else { return nil }
        return counts.favorites ?? counts.active
    }

    /// 骨架阶段的年份封面：每年各取最多 `limit` 张收藏。
    /// 走收藏部分索引的日期范围查询，只读几行，汇总算完之前就能先填上真实照片。
    func favoritesQuickYearCovers(years: [String],
                                  limit: Int = 4) async -> [String: [PhotoItem]] {
        guard isSystemScope, let index = systemIndex else { return [:] }
        var result: [String: [PhotoItem]] = [:]
        for key in years.prefix(8) {
            guard let year = Int(key) else { continue }
            let photos = await Task.detached(priority: .utility) {
                index.favoriteCovers(year: year, limit: limit)
            }.value
            guard !photos.isEmpty else { continue }
            result[key] = photos.map { applySystemOverlay($0) }
        }
        return result
    }

    /// 打开汇总卡片：网格只显示这一类收藏，顶栏提供返回汇总。
    func selectFavoritesBucket(_ bucket: FavoritesBucketSelection) {
        selectedFavoriteBucket = bucket
        selection.removeAll()
        viewerID = nil
    }

    func clearFavoritesBucket() {
        selectedFavoriteBucket = nil
        selection.removeAll()
        viewerID = nil
    }

    private func applyFavoritesDigest(_ photos: [PhotoItem],
                                      digest: FavoritesDigest,
                                      token: String) {
        favoritesDigestTask = nil
        isLoadingFavoritesDigest = false
        favoritesDigestSource = photos
        favoritesDigest = digest
        favoritesDigestLoadedToken = token
    }

    /// 人物维度只汇总已命名的人物；本地聚类与官方识别结果分别取用。
    private func favoritesPeopleSources() -> [FavoritesPersonSource] {
        if isSystemScope {
            return systemPeople.map {
                FavoritesPersonSource(id: "system-\($0.id)",
                                      name: $0.name,
                                      isPet: $0.isPet,
                                      isUnnamed: $0.isUnnamed,
                                      assetIDs: $0.assetIDs)
            }
        }
        return localPeople.map {
            FavoritesPersonSource(id: "local-\($0.id.uuidString)",
                                  name: $0.name,
                                  isPet: false,
                                  isUnnamed: $0.isUnnamed,
                                  assetIDs: $0.assetIDs)
        }
    }
}
