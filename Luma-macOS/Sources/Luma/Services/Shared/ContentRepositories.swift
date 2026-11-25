import Foundation
import LumaContentCore

/// 网盘只读内容仓库：直接调用 `CloudService`，不依赖当前 UI 是否已经加载过目录。
/// 这是 `ContentRepository` 的第一个真实实现，后续资源 / 影院 / 电视按同一形状接入。
@MainActor
struct CloudContentRepository: ContentRepository {
    let mount: CloudMount
    let rootPath: String
    /// 把云盘路径还原成父目录。WebDAV 用路径；网盘 fileID 由调用方覆盖。
    var parentPath: (String) -> String = { ($0 as NSString).deletingLastPathComponent }

    func containers(_ query: ContentQuery) async throws -> [ContentContainer] {
        let entries = try await list(query.containerID ?? rootPath)
        return entries
            .filter(\.isDirectory)
            .map { entry in
                ContentContainer(id: entry.path,
                                 title: entry.name,
                                 kind: .folder,
                                 subtitle: entry.modifiedAt.map(Self.dateText))
            }
    }

    func page(_ query: ContentQuery) async throws -> ContentPage {
        let path = query.containerID ?? rootPath
        let entries = try await list(path)
        var folders = entries.filter(\.isDirectory)
        var media = entries.filter { !$0.isDirectory && $0.isMedia }
        if let search = query.search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            folders = folders.filter { $0.name.localizedCaseInsensitiveContains(search) }
            media = media.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        media.sort { lhs, rhs in
            switch query.sort?.key ?? .latest {
            case .title:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .oldest:
                return (lhs.modifiedAt ?? .distantPast) < (rhs.modifiedAt ?? .distantPast)
            default:
                return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }
        }

        let limit = max(1, query.limit)
        let page = max(1, query.cursor?.page ?? 1)
        let start = min(media.count, (page - 1) * limit)
        let end = min(media.count, start + limit)
        let slice = start < end ? Array(media[start..<end]) : []

        return ContentPage(
            items: slice.map(card(for:)),
            containers: folders.map { entry in
                ContentContainer(id: entry.path,
                                 title: entry.name,
                                 kind: .folder,
                                 subtitle: entry.modifiedAt.map(Self.dateText))
            },
            next: end < media.count ? PageCursor(page: page + 1) : nil,
            totalHint: media.count
        )
    }

    func detail(_ ref: ContentRef) async throws -> ContentDetail {
        let path = parentPath(ref.itemID)
        let entries = try await list(path)
        guard let entry = entries.first(where: { $0.path == ref.itemID }) else {
            throw SourceError.unavailable("找不到该云盘项目，可能已被移动或删除。")
        }
        let target = PlaybackTarget(
            storage: .provider(sourceID: .cloud(mount.id), itemID: entry.path, episodeID: nil),
            mode: .vod,
            title: entry.name,
            artworkURL: entry.thumbnailURL
        )
        return ContentDetail(
            card: card(for: entry),
            facts: facts(for: entry),
            playbackOptions: [
                ContentPlaybackOption(id: entry.path, title: "云盘原片", target: target)
            ]
        )
    }

    func search(_ query: ContentQuery) async throws -> ContentPage {
        var scoped = query
        scoped.cursor = nil
        return try await page(scoped)
    }

    private func list(_ path: String) async throws -> [CloudEntry] {
        do {
            return try await CloudService.list(mount: mount, containerID: path)
        } catch {
            throw SourceErrorMapper.map(error)
        }
    }

    private func card(for entry: CloudEntry) -> ContentCard {
        ContentCard(
            ref: ContentRef(sourceID: .cloud(mount.id), itemID: entry.path),
            title: entry.name,
            subtitle: entry.modifiedAt.map(Self.dateText),
            artworkURL: entry.thumbnailURL,
            badges: entry.isVideo ? ["视频"] : [],
            isPlayable: entry.isMedia && !entry.isRestricted,
            asset: ContentAssetFacts(updatedAt: entry.modifiedAt,
                                     byteCount: entry.size > 0 ? entry.size : nil,
                                     duration: entry.duration,
                                     pixelWidth: entry.pixelWidth,
                                     pixelHeight: entry.pixelHeight,
                                     remoteID: entry.remoteID,
                                     videoCodec: entry.codecName,
                                     isRestricted: entry.isRestricted)
        )
    }

    private func facts(for entry: CloudEntry) -> [ContentFact] {
        var facts: [ContentFact] = []
        if let modifiedAt = entry.modifiedAt {
            facts.append(ContentFact(label: "修改时间", value: Self.dateText(modifiedAt)))
        }
        if entry.size > 0 {
            facts.append(ContentFact(label: "大小", value: ByteCountFormatter.string(fromByteCount: entry.size,
                                                                                 countStyle: .file)))
        }
        if let width = entry.pixelWidth, let height = entry.pixelHeight, width > 0, height > 0 {
            facts.append(ContentFact(label: "尺寸", value: "\(width) × \(height)"))
        }
        if let duration = entry.duration, duration > 0 {
            facts.append(ContentFact(label: "时长", value: Self.durationText(duration)))
        }
        if entry.isRestricted {
            facts.append(ContentFact(label: "状态", value: "云端标记为受限内容，无法播放"))
        }
        return facts
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// 网络资源只读内容仓库：直接复用 `CatalogProvider`，不经过 `CatalogBrowserModel` 的页面状态。
/// 电视 / 在线影院后续只需要实现同一组 `ContentRepository` 方法。
@MainActor
struct CatalogContentRepository: ContentRepository {
    let source: CatalogSource

    func containers(_ query: ContentQuery) async throws -> [ContentContainer] {
        source.categories.map { category in
            ContentContainer(id: category.id,
                             title: category.title,
                             kind: .category,
                             childCountHint: category.children?.count)
        }
    }

    func page(_ query: ContentQuery) async throws -> ContentPage {
        let provider = try provider()
        let page = max(1, query.cursor?.page ?? 1)
        let sort = catalogSort(query.sort)
        do {
            let result: CatalogPage
            if let categoryID = query.containerID,
               let category = categoryIndex[categoryID] {
                result = try await provider.category(source: source,
                                                     category: category,
                                                     sort: sort,
                                                     page: page)
            } else {
                result = try await provider.home(source: source, page: page)
            }
            return map(result)
        } catch {
            throw SourceErrorMapper.map(error)
        }
    }

    func detail(_ ref: ContentRef) async throws -> ContentDetail {
        let provider = try provider()
        do {
            let detail = try await provider.detail(source: source, itemID: ref.itemID)
            let card = ContentCard(
                ref: ContentRef(sourceID: .catalog(source.id), itemID: detail.item.id),
                title: detail.item.title,
                subtitle: detail.item.remark,
                artworkURL: detail.item.coverURL,
                aspectRatio: source.posterRatio
            )
            let episodes = detail.episodes.map { episode in
                ContentEpisode(
                    id: String(episode.index),
                    index: episode.index,
                    title: episode.title,
                    subtitle: episode.duration,
                    target: PlaybackTarget(
                        storage: .provider(sourceID: .catalog(source.id),
                                           itemID: detail.item.id,
                                           episodeID: String(episode.index)),
                        mode: .vod,
                        title: "\(detail.item.title) · \(episode.title)",
                        artworkURL: episode.coverURL.isEmpty ? detail.item.coverURL : episode.coverURL
                    )
                )
            }
            return ContentDetail(
                card: card,
                overview: detail.blocks.compactMap { block in
                    block.kind == .paragraph ? block.text : nil
                }.joined(separator: "\n"),
                facts: detail.facts.map { ContentFact(label: $0.label, value: $0.value) },
                episodes: episodes
            )
        } catch {
            throw SourceErrorMapper.map(error)
        }
    }

    func search(_ query: ContentQuery) async throws -> ContentPage {
        let keyword = query.search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !keyword.isEmpty else { return try await page(query) }
        do {
            let result = try await provider().search(source: source,
                                                     keyword: keyword,
                                                     page: max(1, query.cursor?.page ?? 1))
            return map(result)
        } catch {
            throw SourceErrorMapper.map(error)
        }
    }

    private func provider() throws -> CatalogProvider {
        guard let provider = CatalogProviders.provider(for: source.kind) else {
            throw SourceError.unsupported("该资源类型还没有对应的解析器。")
        }
        return provider
    }

    private func map(_ page: CatalogPage) -> ContentPage {
        ContentPage(
            items: page.items.map { item in
                ContentCard(
                    ref: ContentRef(sourceID: .catalog(source.id), itemID: item.id),
                    title: item.title,
                    subtitle: item.remark,
                    artworkURL: item.coverURL,
                    aspectRatio: source.posterRatio
                )
            },
            next: page.hasMore ? PageCursor(page: page.page + 1) : nil
        )
    }

    private func catalogSort(_ sort: ContentSort?) -> CatalogSort {
        switch sort?.key {
        case .rating, .duration:
            return .hot
        case .title:
            return .latest
        case .oldest, .latest, .custom, .none:
            return .latest
        }
    }

    private var categoryIndex: [String: CatalogCategory] {
        var result: [String: CatalogCategory] = [:]
        func insert(_ category: CatalogCategory) {
            result[category.id] = category
            category.children?.forEach(insert)
        }
        source.categories.forEach(insert)
        return result
    }
}

/// 影院只读内容仓库：直接读已刮削的索引，不发网络请求。
/// 扫库 / 刮削仍由 `SourceJobCenter` 驱动，仓库只负责“看”。
@MainActor
struct CinemaContentRepository: ContentRepository {
    let store: LibraryStore
    let scope: CinemaScope

    private var sourceID: SourceID {
        switch scope {
        case .local: return .localCinema
        case .mount(let id): return .mountCinema(id)
        }
    }

    func containers(_ query: ContentQuery) async throws -> [ContentContainer] { [] }

    func page(_ query: ContentQuery) async throws -> ContentPage {
        var entries = Array(store.cinemaEntries(for: scope).values)
        if let search = query.search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            entries = entries.filter {
                $0.title.localizedCaseInsensitiveContains(search)
                    || ($0.originalTitle?.localizedCaseInsensitiveContains(search) ?? false)
            }
        }
        entries.sort { lhs, rhs in
            if lhs.matched != rhs.matched { return lhs.matched }
            switch query.sort?.key ?? .latest {
            case .title:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .oldest:
                return lhs.scrapedAt < rhs.scrapedAt
            default:
                return lhs.scrapedAt > rhs.scrapedAt
            }
        }
        let limit = max(1, query.limit)
        let page = max(1, query.cursor?.page ?? 1)
        let start = min(entries.count, (page - 1) * limit)
        let end = min(entries.count, start + limit)
        let slice = start < end ? Array(entries[start..<end]) : []
        return ContentPage(items: slice.map(card),
                           next: end < entries.count ? PageCursor(page: page + 1) : nil,
                           totalHint: entries.count)
    }

    func detail(_ ref: ContentRef) async throws -> ContentDetail {
        guard let id = UUID(uuidString: ref.itemID),
              let entry = store.cinemaEntries(for: scope)[id] else {
            throw SourceError.unavailable("找不到该影院条目，可能已被移动或删除。")
        }
        return ContentDetail(card: card(entry),
                             overview: entry.overview,
                             facts: facts(entry),
                             playbackOptions: [
                                ContentPlaybackOption(id: entry.id.uuidString,
                                                      title: "影院原片",
                                                      target: target(entry))
                             ])
    }

    func search(_ query: ContentQuery) async throws -> ContentPage {
        try await page(query)
    }

    // MARK: - 映射

    private func card(_ entry: CinemaEntry) -> ContentCard {
        var badges: [String] = []
        if let year = entry.year { badges.append(String(year)) }
        if entry.matched { badges.append(entry.kind.title) }
        return ContentCard(ref: ContentRef(sourceID: sourceID, itemID: entry.id.uuidString),
                           title: entry.title,
                           subtitle: entry.originalTitle,
                           artworkURL: entry.gridArtworkURL,
                           badges: badges,
                           progress: store.cinemaProgress[entry.id]?.fraction,
                           isPlayable: true)
    }

    private func facts(_ entry: CinemaEntry) -> [ContentFact] {
        var facts: [ContentFact?] = []
        facts.append(entry.year.map { ContentFact(label: "年份", value: String($0)) })
        facts.append(ContentFact(label: "类型", value: entry.kind.title))
        facts.append(entry.rating.map { ContentFact(label: "评分", value: String(format: "%.1f", $0)) })
        facts.append(entry.runtime.map { ContentFact(label: "片长", value: "\($0) 分钟") })
        if let genres = entry.genres, !genres.isEmpty {
            facts.append(ContentFact(label: "题材", value: genres.joined(separator: " / ")))
        }
        return facts.compactMap { $0 }
    }

    private func target(_ entry: CinemaEntry) -> PlaybackTarget {
        PlaybackTarget(storage: .provider(sourceID: sourceID,
                                          itemID: entry.id.uuidString,
                                          episodeID: nil),
                       mode: .vod,
                       title: entry.title,
                       artworkURL: entry.gridArtworkURL)
    }
}

/// 图库只读内容仓库：把现有内存索引映射成统一内容模型，供统一搜索 / 跨源列表消费。
/// 不替换照片网格的查询路径，也不触发扫描、缩略图生成或额外 IO。
@MainActor
struct LibraryContentRepository: ContentRepository {
    let store: LibraryStore
    let sourceID: SourceID

    func containers(_ query: ContentQuery) async throws -> [ContentContainer] {
        if let folderID = Self.folderID(from: query.containerID) {
            return containerList(folders: store.folders.filter { $0.parentID == folderID },
                                 albums: store.albums.filter { $0.folderID == folderID })
        }
        guard query.containerID == nil else { return [] }
        return containerList(folders: store.folders.filter { $0.parentID == nil },
                             albums: store.albums.filter { $0.folderID == nil })
    }

    func page(_ query: ContentQuery) async throws -> ContentPage {
        var photos = photos(in: query.containerID)
        if let search = query.search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            photos = photos.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(search)
                    || $0.filename.localizedCaseInsensitiveContains(search)
                    || $0.originalName.localizedCaseInsensitiveContains(search)
            }
        }
        photos = sorted(photos, by: query.sort)

        let limit = max(1, query.limit)
        let page = max(1, query.cursor?.page ?? 1)
        let start = min(photos.count, (page - 1) * limit)
        let end = min(photos.count, start + limit)
        let slice = start < end ? Array(photos[start..<end]) : []
        // 容器只在根列表首屏返回，翻页与搜索结果里不重复给。
        let showsContainers = query.containerID == nil
            && (query.search?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && page == 1
        return ContentPage(items: slice.map(card),
                           containers: showsContainers
                               ? containerList(folders: store.folders.filter { $0.parentID == nil },
                                               albums: store.albums.filter { $0.folderID == nil })
                               : [],
                           next: end < photos.count ? PageCursor(page: page + 1) : nil,
                           totalHint: photos.count)
    }

    func detail(_ ref: ContentRef) async throws -> ContentDetail {
        guard let id = UUID(uuidString: ref.itemID),
              let photo = store.photo(id: id) ?? store.photos(for: .library).first(where: { $0.id == id }) else {
            throw SourceError.unavailable("找不到这个图库条目，可能已被删除。")
        }
        var options: [ContentPlaybackOption] = []
        if photo.isVideo {
            options.append(ContentPlaybackOption(id: photo.id.uuidString,
                                                 title: "图库原片",
                                                 target: playbackTarget(photo)))
        }
        return ContentDetail(card: card(photo), facts: facts(photo), playbackOptions: options)
    }

    func search(_ query: ContentQuery) async throws -> ContentPage {
        var scoped = query
        scoped.containerID = nil
        scoped.cursor = nil
        return try await page(scoped)
    }

    // MARK: - 数据来源

    /// 相簿 / 文件夹都复用现有 `photos(for:)` 范围，不新建索引。
    private func photos(in containerID: String?) -> [PhotoItem] {
        if let albumID = Self.albumID(from: containerID) {
            return store.photos(for: .album(albumID))
        }
        if let folderID = Self.folderID(from: containerID) {
            return store.photos(for: .folder(folderID))
        }
        return store.photos(for: .library)
    }

    private func sorted(_ photos: [PhotoItem], by sort: ContentSort?) -> [PhotoItem] {
        switch sort?.key ?? .latest {
        case .title:
            return photos.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .oldest:
            return photos.sorted { $0.capturedAt < $1.capturedAt }
        default:
            return photos.sorted { $0.capturedAt > $1.capturedAt }
        }
    }

    private func containerList(folders: [AlbumFolder], albums: [Album]) -> [ContentContainer] {
        let folderItems = folders.map { folder in
            ContentContainer(id: "folder:\(folder.id.uuidString)",
                             title: folder.name,
                             kind: .folder,
                             childCountHint: albums.filter { $0.folderID == folder.id }.count)
        }
        let albumItems = albums.map { album in
            ContentContainer(id: "album:\(album.id.uuidString)",
                             title: album.name,
                             kind: .album,
                             childCountHint: album.photoIDs.count)
        }
        return folderItems + albumItems
    }

    // MARK: - 映射

    private func card(_ photo: PhotoItem) -> ContentCard {
        var badges: [String] = []
        if photo.isVideo { badges.append("视频") }
        if photo.isFavorite { badges.append("收藏") }
        return ContentCard(ref: ContentRef(sourceID: sourceID, itemID: photo.id.uuidString),
                           title: photo.displayTitle,
                           subtitle: Self.dateText(photo.capturedAt),
                           artworkURL: artworkURL(photo),
                           badges: badges,
                           aspectRatio: aspectRatio(photo),
                           isPlayable: true)
    }

    private func facts(_ photo: PhotoItem) -> [ContentFact] {
        var facts: [ContentFact] = [ContentFact(label: "拍摄时间", value: Self.dateText(photo.capturedAt))]
        if photo.pixelWidth > 0, photo.pixelHeight > 0 {
            facts.append(ContentFact(label: "尺寸", value: "\(photo.pixelWidth) × \(photo.pixelHeight)"))
        }
        if photo.fileSize > 0 {
            facts.append(ContentFact(label: "大小",
                                     value: ByteCountFormatter.string(fromByteCount: photo.fileSize,
                                                                      countStyle: .file)))
        }
        let camera = [photo.make, photo.model]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !camera.isEmpty {
            facts.append(ContentFact(label: "相机", value: camera))
        }
        if let duration = photo.duration, duration > 0 {
            facts.append(ContentFact(label: "时长", value: Self.durationText(duration)))
        }
        if photo.hasLocation {
            let place = [photo.placeCountry, photo.placeProvince, photo.placeCity, photo.placeDistrict]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !place.isEmpty { facts.append(ContentFact(label: "地点", value: place)) }
        }
        return facts
    }

    private func playbackTarget(_ photo: PhotoItem) -> PlaybackTarget {
        PlaybackTarget(storage: .provider(sourceID: sourceID,
                                          itemID: photo.id.uuidString,
                                          episodeID: nil),
                       mode: .vod,
                       title: photo.displayTitle)
    }

    private func artworkURL(_ photo: PhotoItem) -> String? {
        let url = LibraryPaths.thumbnailURL(for: photo)
        return FileManager.default.fileExists(atPath: url.path) ? url.absoluteString : nil
    }

    private func aspectRatio(_ photo: PhotoItem) -> Double? {
        guard photo.pixelWidth > 0, photo.pixelHeight > 0 else { return nil }
        return Double(photo.pixelWidth) / Double(photo.pixelHeight)
    }

    // MARK: - 容器 ID

    private static func albumID(from containerID: String?) -> UUID? {
        guard let containerID, containerID.hasPrefix("album:") else { return nil }
        return UUID(uuidString: String(containerID.dropFirst("album:".count)))
    }

    private static func folderID(from containerID: String?) -> UUID? {
        guard let containerID, containerID.hasPrefix("folder:") else { return nil }
        return UUID(uuidString: String(containerID.dropFirst("folder:".count)))
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
