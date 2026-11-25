import Foundation
import LumaContentCore

/// 五个来源的检索器：只负责「把关键词变成 SearchSection」，
/// 不关心界面、不关心当前页面，因此全局搜索或模块内搜索都能复用。
@MainActor
enum SearchProviders {
    static func makeAll(store: LibraryStore,
                        catalog: CatalogBrowserModel,
                        tv: IPTVBrowserModel) -> [any SearchProviding] {
        [
            LibrarySearchProvider(store: store),
            CloudSearchProvider(store: store),
            CinemaSearchProvider(store: store),
            NetworkCinemaSearchProvider(catalog: catalog),
            TelevisionSearchProvider(tv: tv),
            CatalogSearchProvider(catalog: catalog)
        ]
    }
}

// MARK: - 图库

@MainActor
private final class LibrarySearchProvider: SearchProviding {
    let source: SearchSourceKind = .library
    private weak var store: LibraryStore?

    init(store: LibraryStore) { self.store = store }

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !keyword.isEmpty else { return empty }

        let targets = LibrarySearchCrossLibrary.targets(store: store)
        let currentTarget = targets.first(where: \.isCurrent)
        // 浏览网络影院 / 网络电视 / 网络资源这些模块时，store 里没有图库内容
        // （`sidebarItem` 不在系统图库范围、photos 为空）。这时不能拿 store 当「当前图库」，
        // 否则图库来源永远 0；当前图库也改走只读直连。
        let storeServesLibrary = store.isSystemScope || !store.isNativeContainer

        var hits: [SearchHit] = []
        var kindCounts: [SearchHitKind: Int] = [:]
        var total = 0

        if storeServesLibrary {
            // 系统图库的分页窗口是异步装填的：搜索词一变，窗口先清空再跑 SQL。
            // 不等它落地就统计，大库上会瞬间得到「图库 0」并被搜索会话缓存住。
            await waitForSystemWindow(store: store)

            let media = mediaHits(store: store, keyword: keyword)
            hits = media.hits
            if media.imageTotal > 0 { kindCounts[.photo] = media.imageTotal }
            if media.videoTotal > 0 { kindCounts[.video] = media.videoTotal }

            let albums = albumHits(store: store, keyword: keyword)
            hits += albums.map(\.hit)
            kindCounts[.album] = albums.count

            let folders = folderHits(store: store, keyword: keyword)
            hits += folders.map(\.hit)
            kindCounts[.folder] = folders.count

            let people = personHits(store: store, keyword: keyword)
            hits += people.map(\.hit)
            kindCounts[.person] = people.count

            // 场景是「分类数据」：按场景标题与识别标签匹配（搜「猫」能找到动物 / 宠物场景）。
            let scenes = sceneHits(store: store, keyword: keyword)
            hits += scenes.map(\.hit)
            kindCounts[.scene] = scenes.count

            let places = placeHits(store: store, keyword: keyword)
            hits += places.map(\.hit)
            kindCounts[.place] = places.count

            total = media.imageTotal + media.videoTotal + albums.count + folders.count
                + people.count + scenes.count + places.count

            // 当前图库的命中补上来源名：跨库结果会按图库名出现「源」筛选。
            if let currentTarget {
                hits = hits.map { hit in
                    var copy = hit
                    copy.origin = hit.origin ?? currentTarget.name
                    copy.libraryPath = currentTarget.path
                    return copy
                }
            }
        }

        // 其它已接入的图库（以及不在图库页面时的当前图库）：并发只读直连。
        let others = targets.filter { !$0.isCurrent || !storeServesLibrary }
        if !others.isEmpty {
            var extras: [(index: Int, hits: [SearchHit])] = []
            await withTaskGroup(of: (Int, [SearchHit]).self) { group in
                for (index, target) in others.enumerated() {
                    group.addTask {
                        // 命中多少返回多少，不做条数截断。
                        let hits = LibrarySearchCrossLibrary.search(target: target,
                                                                    keyword: keyword)
                        return (index, hits)
                    }
                }
                for await (index, extra) in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    guard !extra.isEmpty else { continue }
                    extras.append((index, extra))
                }
            }
            for entry in extras.sorted(by: { $0.index < $1.index }) {
                total += entry.hits.count
                for hit in entry.hits { kindCounts[hit.kind, default: 0] += 1 }
                hits += entry.hits
            }
        }

        // 不再整段截断：每类已各自 prefix(limit)、其它图库也已按 12 条配额取过。
        // 再按固定上限截断会把排在后面的类型砍掉，出现「胶囊有 16、列表却是空」。
        return SearchSection(source: source,
                             hits: hits,
                             total: total,
                             kindCounts: kindCounts)
    }

    private var empty: SearchSection {
        SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
    }

    /// 等系统图库的分页窗口装填完成（最多 2.5 秒），避免把「还没查完」当成 0 命中。
    private func waitForSystemWindow(store: LibraryStore) async {
        guard store.isSystemPagedScope, !store.hasLoadedSystemWindow else { return }
        let deadline = Date().addingTimeInterval(2.5)
        while !store.hasLoadedSystemWindow, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    /// 图库里的图片与视频分开计数：结果页可以按「图片 / 视频」筛选。
    /// 不做条数限制：系统图库直接从索引取「整库命中」，本地图库用内存全集。
    private func mediaHits(store: LibraryStore, keyword: String)
        -> (hits: [SearchHit], imageTotal: Int, videoTotal: Int) {
        // 全局 / 模块内搜索时 store 已经按关键词算好全库结果；窗口内搜索只过滤当前可见集合。
        let isWholeLibrary = store.searchScope != .currentView
            && store.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == keyword
        let items: [PhotoItem]
        if isWholeLibrary, let index = store.systemIndex, let query = store.systemQuery {
            // 分页窗口只装前 600 张，搜索不能被窗口截断：
            // 用同一套查询条件把整库命中的 ID 全部取出。
            items = index.photos(ids: index.allIDs(query))
                .sorted { $0.capturedAt > $1.capturedAt }
        } else if isWholeLibrary {
            items = store.visiblePhotos
        } else {
            items = store.visiblePhotos.filter { matches($0, keyword: keyword) }
        }
        let images = items.filter { !$0.isVideo }
        let videos = items.filter { $0.isVideo }
        func hit(_ photo: PhotoItem, kind: SearchHitKind) -> SearchHit {
            SearchHit(id: "library|\(kind.rawValue)|\(photo.id.uuidString)",
                      source: .library,
                      kind: kind,
                      title: photo.title ?? photo.originalName,
                      subtitle: subtitle(for: photo),
                      badge: kind == .video ? "视频" : nil,
                      visual: .photo(photo),
                      payload: .photo(photo.id))
        }
        let hits = images.map { hit($0, kind: .photo) } + videos.map { hit($0, kind: .video) }
        return (hits, images.count, videos.count)
    }

    private func matches(_ photo: PhotoItem, keyword: String) -> Bool {
        if SearchFuzzyText.matchesAny([photo.originalName, photo.title], keyword: keyword) {
            return true
        }
        if let keywords = photo.keywords,
           keywords.contains(where: { SearchFuzzyText.matches($0, keyword: keyword) }) {
            return true
        }
        return SearchFuzzyText.matchesAny([photo.placeCity, photo.placeProvince, photo.placePOI],
                                          keyword: keyword)
    }

    private func subtitle(for photo: PhotoItem) -> String {
        var parts: [String] = []
        if let city = photo.placeCity, !city.isEmpty { parts.append(city) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        parts.append(formatter.string(from: photo.capturedAt))
        return parts.joined(separator: " · ")
    }

    private struct MappedHit {
        var hit: SearchHit
    }

    private func albumHits(store: LibraryStore, keyword: String) -> [MappedHit] {
        if store.isSystemScope {
            return store.systemAlbums
                .filter { SearchFuzzyText.matches($0.name, keyword: keyword) }
                .map { album in
                    MappedHit(hit: SearchHit(id: "library|system-album|\(album.id)",
                                             source: .library,
                                             kind: .album,
                                             title: album.name,
                                             subtitle: "相簿 · \(store.systemAlbumPhotoCount(album.id)) 张",
                                             badge: nil,
                                             visual: .albumCover(store.systemAlbumPreviewPhotos(album.id,
                                                                                               limit: 1).first,
                                                                 .album),
                                             payload: .systemAlbum(album.id)))
                }
        }
        return store.albums
            .filter { SearchFuzzyText.matches($0.name, keyword: keyword) }
            .map { album in
                let cover = (album.coverPhotoID ?? album.photoIDs.first)
                    .flatMap { store.anyPhoto(id: $0) }
                return MappedHit(hit: SearchHit(id: "library|album|\(album.id.uuidString)",
                                                source: .library,
                                                kind: .album,
                                                title: album.name,
                                                subtitle: "相簿 · \(album.photoIDs.count) 张",
                                                badge: nil,
                                                visual: .albumCover(cover, .album),
                                                payload: .localAlbum(album.id)))
            }
    }

    private func folderHits(store: LibraryStore, keyword: String) -> [MappedHit] {
        if store.isSystemScope {
            return store.systemFolders
                .filter { SearchFuzzyText.matches($0.name, keyword: keyword) }
                .map { folder in
                    MappedHit(hit: SearchHit(id: "library|system-folder|\(folder.id)",
                                             source: .library,
                                             kind: .folder,
                                             title: folder.name,
                                             subtitle: "文件夹",
                                             badge: nil,
                                             visual: .albumCover(nil, .folder),
                                             payload: .systemFolder(folder.id)))
                }
        }
        return store.folders
            .filter { SearchFuzzyText.matches($0.name, keyword: keyword) }
            .map { folder in
                MappedHit(hit: SearchHit(id: "library|folder|\(folder.id.uuidString)",
                                         source: .library,
                                         kind: .folder,
                                         title: folder.name,
                                         subtitle: "文件夹",
                                         badge: nil,
                                         visual: .albumCover(nil, .folder),
                                         payload: .localFolder(folder.id)))
            }
    }

    private func personHits(store: LibraryStore, keyword: String) -> [MappedHit] {
        if store.isSystemScope {
            return store.systemPeople
                .filter { !$0.isUnnamed && SearchFuzzyText.matches($0.name, keyword: keyword) }
                .map { person in
                    let count = person.assetIDs.isEmpty ? person.faceCount : person.assetIDs.count
                    return MappedHit(hit: SearchHit(id: "library|system-person|\(person.id)",
                                                    source: .library,
                                                    kind: .person,
                                                    title: person.name,
                                                    subtitle: "人物 · \(count) 张",
                                                    badge: nil,
                                                    visual: .avatar(person.cropData, isPet: person.isPet),
                                                    payload: .systemPerson(person)))
                }
        }
        return store.localPeople
            .filter { !$0.isUnnamed && SearchFuzzyText.matches($0.name, keyword: keyword) }
            .map { person in
                MappedHit(hit: SearchHit(id: "library|person|\(person.id.uuidString)",
                                         source: .library,
                                         kind: .person,
                                         title: person.name,
                                         subtitle: "人物 · \(person.assetIDs.count) 张",
                                         badge: nil,
                                         visual: .avatar(person.coverImageData, isPet: false),
                                         payload: .localPerson(person.id)))
            }
    }

    /// 场景分类：按分类标题与识别标签匹配，搜「猫」也能找到「动物」「宠物」这类场景。
    private func sceneHits(store: LibraryStore, keyword: String) -> [MappedHit] {
        let counts = store.sceneCounts
        guard !counts.isEmpty else { return [] }
        return SceneCatalog.categories.compactMap { category in
            let count = counts[category.id] ?? 0
            guard count > 0 else { return nil }
            let matchesTitle = SearchFuzzyText.matches(category.title, keyword: keyword)
            let matchesTag = category.tags.contains {
                SearchFuzzyText.matches($0, keyword: keyword)
            }
            guard matchesTitle || matchesTag else { return nil }
            return MappedHit(hit: SearchHit(id: "library|scene|\(category.id)",
                                            source: .library,
                                            kind: .scene,
                                            title: category.title,
                                            subtitle: "场景 · \(count) 张",
                                            badge: nil,
                                            visual: .scene,
                                            payload: .scene(category.id)))
        }
    }

    private func placeHits(store: LibraryStore, keyword: String) -> [MappedHit] {
        // 位置不能因为「还没打开过地图」就永远 0：这里按需算一次聚类，结果本身有缓存。
        return store.placeClusters
            .filter { cluster in
                SearchFuzzyText.matchesAny([cluster.title, cluster.subtitle, cluster.group],
                                           keyword: keyword)
            }
            .map { cluster in
                MappedHit(hit: SearchHit(id: "library|place|\(cluster.id)",
                                         source: .library,
                                         kind: .place,
                                         title: cluster.title,
                                         subtitle: cluster.subtitle ?? cluster.group,
                                         badge: nil,
                                         visual: .place,
                                         payload: .place(cluster)))
            }
    }
}

// MARK: - 网盘

@MainActor
private final class CloudSearchProvider: SearchProviding {
    let source: SearchSourceKind = .cloud
    private weak var store: LibraryStore?

    init(store: LibraryStore) { self.store = store }

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, AppModules.isEnabled(AppModule.cloud),
              let metadata = store.metadataStore, keyword.count >= 2 else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }

        async let assetTask = Task.detached(priority: .userInitiated) {
            metadata.searchCloudIndexAssets(keyword: keyword, limit: 0)
        }.value
        async let folderTask = Task.detached(priority: .userInitiated) {
            metadata.searchCloudIndexFolders(keyword: keyword, limit: 0)
        }.value
        let (assets, folders) = await (assetTask, folderTask)
        guard !Task.isCancelled else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }

        var hits: [SearchHit] = []
        var photoCount = 0
        var videoCount = 0
        for item in assets {
            guard let mount = store.cloudMount(for: item.mountID) else { continue }
            let record = item.record
            let subtitle = record.folderPath.map { "\(mount.name) · \($0)" } ?? mount.name
            if record.isVideo { videoCount += 1 } else { photoCount += 1 }
            hits.append(SearchHit(id: "cloud|file|\(item.mountID.uuidString)|\(record.path)",
                                  source: source,
                                  kind: record.isVideo ? .cloudVideo : .cloudPhoto,
                                  title: record.name,
                                  subtitle: subtitle,
                                  badge: record.isVideo ? "视频" : "图片",
                                  visual: .cloudFile(isVideo: record.isVideo),
                                  payload: .cloudFile(mountID: item.mountID,
                                                      folderPath: record.folderPath,
                                                      path: record.path),
                                  origin: mount.name,
                                  category: record.folderPath.map { ($0 as NSString).lastPathComponent }))
        }
        for item in folders {
            guard let mount = store.cloudMount(for: item.mountID) else { continue }
            hits.append(SearchHit(id: "cloud|folder|\(item.mountID.uuidString)|\(item.path)",
                                  source: source,
                                  kind: .cloudFolder,
                                  title: item.name,
                                  subtitle: "\(mount.name) · \(item.mediaCount) 个文件",
                                  badge: nil,
                                  visual: .cloudFolder,
                                  payload: .cloudFolder(mountID: item.mountID,
                                                        path: item.path),
                                  origin: mount.name))
        }
        return SearchSection(source: source,
                             hits: hits,
                             total: hits.count,
                             kindCounts: [.cloudPhoto: photoCount,
                                          .cloudVideo: videoCount,
                                          .cloudFolder: folders.count])
    }
}

// MARK: - 影院

@MainActor
private final class CinemaSearchProvider: SearchProviding {
    let source: SearchSourceKind = .cinema
    private weak var store: LibraryStore?

    init(store: LibraryStore) { self.store = store }

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !keyword.isEmpty else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }

        var hits: [SearchHit] = []
        var movies = 0
        var series = 0

        for (scope, entries) in store.cinemaIndexes {
            let scopeKey = Self.scopeKey(scope)
            let scopeName = Self.scopeName(scope, store: store)
            var grouped: [String: [CinemaEntry]] = [:]
            for entry in entries.values {
                let haystack = [entry.title,
                                entry.originalTitle ?? "",
                                entry.folderHint ?? ""].joined(separator: " ")
                guard haystack.localizedCaseInsensitiveContains(keyword) else { continue }
                let key = entry.kind == .tv ? "tv|\(entry.title)" : "movie|\(entry.id.uuidString)"
                grouped[key, default: []].append(entry)
            }
            for (key, list) in grouped {
                guard let first = list.min(by: {
                    ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
                }) else { continue }
                if first.kind == .movie { movies += 1 } else { series += 1 }

                var subtitle: [String] = [scopeName]
                if let year = first.year { subtitle.append(String(year)) }
                if first.kind == .tv, list.count > 1 { subtitle.append("\(list.count) 集") }
                if !first.matched { subtitle.append("未刮削") }

                hits.append(SearchHit(id: "cinema|\(scopeKey)|\(key)",
                                      source: source,
                                      kind: first.kind == .movie ? .movie : .series,
                                      title: first.title,
                                      subtitle: subtitle.joined(separator: " · "),
                                      badge: first.kind.title,
                                      visual: .cinemaPoster(first.posterURL, first.kind),
                                      payload: .cinema(scopeKey: scopeKey,
                                                       queueTitle: first.title,
                                                       entry: first),
                                      origin: scopeName))
            }
        }

        hits.sort {
            ($0.title.localizedStandardCompare($1.title) == .orderedAscending)
        }
        return SearchSection(source: source,
                             hits: hits,
                             total: hits.count,
                             kindCounts: [.movie: movies, .series: series])
    }

    private static func scopeKey(_ scope: CinemaScope) -> String {
        switch scope {
        case .local: return "local"
        case .mount(let id): return "mount-\(id.uuidString)"
        }
    }

    private static func scopeName(_ scope: CinemaScope, store: LibraryStore) -> String {
        switch scope {
        case .local: return "本地影院"
        case .mount(let id):
            return "\(store.cloudMount(for: id)?.name ?? "网盘") 影院"
        }
    }
}

// MARK: - 电视

@MainActor
private final class TelevisionSearchProvider: SearchProviding {
    let source: SearchSourceKind = .television
    private weak var tv: IPTVBrowserModel?

    init(tv: IPTVBrowserModel) { self.tv = tv }

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tv, tv.enabled, AppModules.isEnabled(AppModule.television), !keyword.isEmpty else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }
        // 检索词归一：「上海电视台」「上海频道」都按「上海」找，避免把台名后缀当成必须命中的字样。
        let tokens = TVSearchQuery.tokens(keyword)
        // 节目单可能还没从磁盘垫进内存：搜索时顺手补一次，不阻塞频道结果。
        tv.hydrateEPGFromCache()
        // 磁盘里也没有节目单：顺带排一次网络更新，节目结果下一轮搜索才能命中。
        // 上一次更新失败时不再自动重试，避免每敲一个字就重新下载一遍。
        if tv.epgPrograms.isEmpty, tv.epgError == nil {
            tv.loadEPGIfNeeded()
        }

        /// 命中优先级：频道名 > 分组 > 省份归属 > 源名称。
        /// 省份归属让「上海」也能找到东方卫视、哈哈炫动这类不带省名的本地台。
        func matchRank(_ channel: TVChannel) -> Int? {
            if tokens.contains(where: { channel.name.localizedCaseInsensitiveContains($0) }) {
                return 0
            }
            if TVSearchQuery.matchesChannelIdentity(channel, tokens: tokens) {
                return 1
            }
            let playlist = tv.playlistName(for: channel.playlistID)
            if tokens.contains(where: { playlist.localizedCaseInsensitiveContains($0) }) {
                return 2
            }
            return nil
        }

        let matched = tv.channels.compactMap { channel -> (channel: TVChannel, rank: Int)? in
            guard let rank = matchRank(channel) else { return nil }
            return (channel, rank)
        }
        let sorted = matched.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            let leftOK = tv.probeState(for: left.channel.id) == .available
            let rightOK = tv.probeState(for: right.channel.id) == .available
            if leftOK != rightOK { return leftOK }
            return left.channel.name.localizedStandardCompare(right.channel.name) == .orderedAscending
        }
        // 节目单同样参与检索：一档节目占一条结果，点开按直播 / 回看处理。
        // 不做条数截断：频道与节目都返回全部命中。
        let programEntries = tv.searchPrograms(keyword: keyword, limit: 0)
        let channelHits = sorted.map { entry -> SearchHit in
            let channel = entry.channel
            var subtitle = [tv.playlistName(for: channel.playlistID), channel.group]
            if let quality = channel.qualityLabel, !quality.isEmpty { subtitle.append(quality) }
            return SearchHit(id: "tv|\(channel.id)",
                             source: source,
                             kind: .channel,
                             title: channel.name,
                             subtitle: subtitle.joined(separator: " · "),
                             badge: channel.qualityLabel,
                             visual: .channelLogo(channel.logoURL),
                             payload: .channel(channel),
                             origin: tv.playlistName(for: channel.playlistID),
                             category: channel.group)
        }
        let programHits = programEntries.map { entry -> SearchHit in
            let channel = entry.channel
            let program = entry.program
            let subtitle = "\(channel.name) · \(Self.programDayLabel(program.start)) "
                + Self.programTimeRange(program)
            return SearchHit(id: "tvp|\(channel.id)|\(program.id)",
                             source: source,
                             kind: .program,
                             title: program.title,
                             subtitle: subtitle,
                             badge: Self.programBadge(program, channel: channel),
                             visual: .channelLogo(channel.logoURL),
                             payload: .program(channel: channel, program: program),
                             origin: tv.playlistName(for: channel.playlistID),
                             category: channel.group)
        }
        var kindCounts: [SearchHitKind: Int] = [.channel: matched.count]
        if !programEntries.isEmpty { kindCounts[.program] = programEntries.count }
        return SearchSection(source: source,
                             hits: channelHits + programHits,
                             total: matched.count + programEntries.count,
                             kindCounts: kindCounts)
    }

    private static func programTimeRange(_ program: TVEPGProgram) -> String {
        let start = program.start.formatted(date: .omitted, time: .shortened)
        let end = program.end.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    /// 今天 / 明天 / 昨天，其余用「几月几日」：节目单跨好几天，只给时间会分不清哪天。
    private static func programDayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }

    private static func programBadge(_ program: TVEPGProgram,
                                     channel: TVChannel) -> String? {
        let now = Date()
        if program.start <= now && program.end > now { return "正在播" }
        if program.start > now { return "待播" }
        return (channel.catchUpSource ?? "").isEmpty ? nil : "可回看"
    }
}

// MARK: - 网络影院

/// 网络影院：只检索启用的网络影视源（苹果CMS / FoFo / 爱看片片 / 爱壹帆），
/// 结果单独成区，点开直达网络影院的详情页。
@MainActor
private final class NetworkCinemaSearchProvider: SearchProviding {
    let source: SearchSourceKind = .networkCinema
    private weak var catalog: CatalogBrowserModel?

    init(catalog: CatalogBrowserModel) { self.catalog = catalog }

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, AppModules.isEnabled(AppModule.cinema), !keyword.isEmpty else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }
        let sources = catalog.enabledCinemaSources
        guard !sources.isEmpty else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }

        // 所有影视源并发检索：单个源超时 / 报错直接跳过，不影响其它源。
        var collected: [(index: Int, source: CatalogSource, items: [CatalogItem])] = []
        await withTaskGroup(of: (Int, [CatalogItem]).self) { group in
            for (index, catalogSource) in sources.enumerated() {
                group.addTask {
                    let items = await CatalogSearchSupport.search(catalogSource, keyword: keyword)
                    return (index, items)
                }
            }
            for await (index, items) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                guard !items.isEmpty else { continue }
                collected.append((index, sources[index], items))
            }
        }

        var hits: [SearchHit] = []
        var total = 0
        var movies = 0
        var series = 0
        for entry in collected.sorted(by: { $0.index < $1.index }) {
            let catalogSource = entry.source
            total += entry.items.count
            for item in entry.items {
                let isTV = NetworkCinemaModel.guessIsTV(item)
                if isTV { series += 1 } else { movies += 1 }
                let subtitle = item.remark.isEmpty
                    ? catalogSource.name
                    : "\(catalogSource.name) · \(item.remark)"
                hits.append(SearchHit(id: "networkCinema|\(catalogSource.id.uuidString)|\(item.id)",
                                      source: source,
                                      kind: isTV ? .series : .movie,
                                      title: item.title,
                                      subtitle: subtitle,
                                      badge: nil,
                                      visual: .catalogCover(sourceID: catalogSource.id,
                                                            url: item.coverURL),
                                      payload: .networkCinemaItem(sourceID: catalogSource.id,
                                                                  item: item,
                                                                  isTV: isTV),
                                      origin: catalogSource.name))
            }
        }
        var kindCounts: [SearchHitKind: Int] = [:]
        if movies > 0 { kindCounts[.movie] = movies }
        if series > 0 { kindCounts[.series] = series }
        return SearchSection(source: source,
                             hits: hits,
                             total: total,
                             kindCounts: kindCounts)
    }
}

// MARK: - 网络资源

@MainActor
private final class CatalogSearchProvider: SearchProviding {
    let source: SearchSourceKind = .catalog
    private weak var catalog: CatalogBrowserModel?

    init(catalog: CatalogBrowserModel) { self.catalog = catalog }

    func search(query: String, limit: Int) async -> SearchSection {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog, AppModules.isEnabled(AppModule.catalog),
              !keyword.isEmpty else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }
        let groups = await catalog.searchUnified(keyword: keyword, updatesUI: false)
        guard !Task.isCancelled else {
            return SearchSection(source: source, hits: [], total: 0, kindCounts: [:])
        }

        var hits: [SearchHit] = []
        var total = 0
        for group in groups {
            total += group.items.count
            for item in group.items {
                let subtitle = item.remark.isEmpty
                    ? group.sourceName
                    : "\(group.sourceName) · \(item.remark)"
                hits.append(SearchHit(id: "catalog|\(group.sourceID.uuidString)|\(item.id)",
                                      source: source,
                                      kind: .catalogItem,
                                      title: item.title,
                                      subtitle: subtitle,
                                      badge: nil,
                                      visual: .catalogCover(sourceID: group.sourceID,
                                                            url: item.coverURL),
                                      payload: .catalogItem(sourceID: group.sourceID,
                                                            item: item),
                                      origin: group.sourceName,
                                      category: item.categoryID.flatMap {
                                          catalog.category(withID: $0)?.title
                                      }))
            }
        }
        return SearchSection(source: source,
                             hits: hits,
                             total: total,
                             kindCounts: [.catalogItem: total])
    }
}
