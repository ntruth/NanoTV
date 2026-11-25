import Foundation

/// 一个可以参与全局搜索的图库。
struct LibrarySearchTarget {
    let path: String
    let name: String
    /// 官方「照片」图库：只读 `Photos.sqlite`，可以只连接、不切 App 容器。
    let isNative: Bool
    /// 当前正在浏览的图库：内容由 `LibrarySearchProvider` 的现有逻辑负责。
    let isCurrent: Bool
}

/// 跨图库搜索命中的条目：点击后等目标图库加载完成再打开。
enum LibraryPendingOpen {
    case photo(UUID)
    case album(UUID)
    case folder(UUID)
    case person(UUID)
    case systemAlbum(Int64)
    case systemFolder(Int64)
    case systemPerson(SystemPersonInfo)
}

/// 跨图库搜索：对非当前图库做只读检索，结果带上图库标识。
/// 当前图库由 `LibrarySearchProvider` 直接读内存 / 当前索引，不走这里。
enum LibrarySearchCrossLibrary {
    /// 参与搜索的图库：当前图库 + 已连接的系统图库 + 打开过的全部图库，按路径去重。
    @MainActor
    static func targets(store: LibraryStore) -> [LibrarySearchTarget] {
        var list: [LibrarySearchTarget] = []
        let containerPath = LibraryPaths.containerLibraryURL?.standardizedFileURL.path
        let activeSystemPath = store.systemLibraryPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }

        func append(path: String, name: String) {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard !standardized.isEmpty,
                  !list.contains(where: { $0.path == standardized }),
                  FileManager.default.fileExists(atPath: standardized) else { return }
            let url = URL(fileURLWithPath: standardized)
            let isNative = LibraryPaths.isNativeLibrary(url)
            let fallbackName = url.deletingPathExtension().lastPathComponent
            list.append(LibrarySearchTarget(
                path: standardized,
                name: name.isEmpty ? (fallbackName.isEmpty ? "图库" : fallbackName) : name,
                isNative: isNative,
                isCurrent: standardized == containerPath
                    || (isNative && standardized == activeSystemPath)
            ))
        }

        if let url = LibraryPaths.containerLibraryURL {
            append(path: url.path,
                   name: url.deletingPathExtension().lastPathComponent)
        }
        for ref in store.systemLibraries {
            append(path: ref.path, name: ref.name)
        }
        for ref in store.knownLibraries {
            append(path: ref.path, name: ref.name)
        }
        return list
    }

    /// 只读检索一个非当前图库；失败（外置盘未连接 / 结构不认识）时返回空。
    /// 不做条数截断：命中多少就返回多少。
    nonisolated static func search(target: LibrarySearchTarget,
                                   keyword: String) -> [SearchHit] {
        guard !keyword.isEmpty,
              FileManager.default.fileExists(atPath: target.path) else { return [] }
        return target.isNative
            ? nativeHits(target: target, keyword: keyword)
            : appLibraryHits(target: target, keyword: keyword)
    }

    // MARK: - 官方「照片」图库

    private nonisolated static func nativeHits(target: LibrarySearchTarget,
                                               keyword: String) -> [SearchHit] {
        let url = URL(fileURLWithPath: target.path)
        guard let index = SystemIndex.openDirect(libraryURL: url) else { return [] }
        var hits: [SearchHit] = []
        var seen = Set<String>()

        // 官方关键词（Photos 里的标签）往往是唯一能搜到的文字信息，必须参与匹配。
        let keywordIDs = SystemIndex.nativeKeywordAssetIDs(libraryURL: url,
                                                          keyword: keyword,
                                                          limit: 0)
        if !keywordIDs.isEmpty {
            for photo in index.photos(ids: keywordIDs)
            where seen.insert(photo.id.uuidString).inserted {
                hits.append(makeHit(target: target,
                                    kind: photo.isVideo ? .video : .photo,
                                    rawID: photo.id.uuidString,
                                    title: photo.title ?? photo.originalName,
                                    subtitle: subtitle(for: photo),
                                    visual: .photo(photo),
                                    payload: .photo(photo.id),
                                    isVideo: photo.isVideo))
            }
        }

        // 相簿 / 文件夹是元数据表，比全库文件名扫描便宜得多，先查。
        let meta = SystemIndex.albumMetadata(libraryURL: url)
        for album in meta.albums
        where SearchFuzzyText.matches(album.name, keyword: keyword) {
            hits.append(makeHit(target: target,
                                kind: .album,
                                rawID: "\(album.id)",
                                title: album.name,
                                subtitle: "相簿",
                                visual: .albumCover(nil, .album),
                                payload: .systemAlbum(album.id),
                                isVideo: false))
        }
        for folder in meta.folders
        where SearchFuzzyText.matches(folder.name, keyword: keyword) {
            hits.append(makeHit(target: target,
                                kind: .folder,
                                rawID: "\(folder.id)",
                                title: folder.name,
                                subtitle: "文件夹",
                                visual: .albumCover(nil, .folder),
                                payload: .systemFolder(folder.id),
                                isVideo: false))
        }

        // 文件名 / 标题 / 相机 / 地名：整库命中全部取出，不受分页窗口限制。
        // 百万级图库上这是一次全表扫描，宁可慢也不漏结果。
        var query = SystemQuery()
        query.tokens = [keyword]
        let matched = index.photos(ids: index.allIDs(query))
            .sorted { $0.capturedAt > $1.capturedAt }
        for photo in matched
        where seen.insert(photo.id.uuidString).inserted {
            hits.append(makeHit(target: target,
                                kind: photo.isVideo ? .video : .photo,
                                rawID: photo.id.uuidString,
                                title: photo.title ?? photo.originalName,
                                subtitle: subtitle(for: photo),
                                visual: .photo(photo),
                                payload: .photo(photo.id),
                                isVideo: photo.isVideo))
        }
        for person in SystemIndex.peopleMetadata(libraryURL: url)
        where !person.isUnnamed && SearchFuzzyText.matches(person.name, keyword: keyword) {
            hits.append(makeHit(target: target,
                                kind: .person,
                                rawID: "\(person.id)",
                                title: person.name,
                                subtitle: "人物 · \(person.faceCount) 张",
                                visual: .avatar(person.cropData, isPet: person.isPet),
                                payload: .systemPerson(person),
                                isVideo: false))
        }
        return hits
    }

    // MARK: - 拾光自建图库

    private nonisolated static func appLibraryHits(target: LibrarySearchTarget,
                                                   keyword: String) -> [SearchHit] {
        let url = URL(fileURLWithPath: target.path)
        guard let dbURL = LibraryPaths.existingMetadataFile(in: url) else { return [] }
        guard let db = try? SQLiteDatabase(path: dbURL.path, readonly: true) else { return [] }
        let pattern = likePattern(keyword)

        let assetRows = (try? db.query("""
            SELECT * FROM assets
            WHERE deleted_at IS NULL AND is_hidden = 0
              AND (original_name LIKE ? ESCAPE '\\'
                   OR filename LIKE ? ESCAPE '\\'
                   OR IFNULL(title, '') LIKE ? ESCAPE '\\'
                   OR IFNULL(keywords, '') LIKE ? ESCAPE '\\')
            ORDER BY captured_at DESC
            """, [pattern, pattern, pattern, pattern])) ?? []
        var hits = assetRows.compactMap { row -> SearchHit? in
            guard let photo = MetadataStore.photo(from: row) else { return nil }
            let isVideo = photo.kind == .video
            return makeHit(target: target,
                           kind: isVideo ? .video : .photo,
                           rawID: photo.id.uuidString,
                           title: photo.title ?? photo.originalName,
                           subtitle: subtitle(for: photo),
                           // 其它 App 图库的缩略图路径基于它自己的根目录，
                           // 这里用类型色块，避免误读成当前图库的同名缩略图。
                           visual: .cloudFile(isVideo: isVideo),
                           payload: .photo(photo.id),
                           isVideo: isVideo)
        }

        let albumRows = ((try? db.query("SELECT id, name FROM albums")) ?? [])
            .filter { SearchFuzzyText.matches($0["name"]?.string, keyword: keyword) }
        for row in albumRows {
            guard let idString = row["id"]?.string,
                  let id = UUID(uuidString: idString) else { continue }
            hits.append(makeHit(target: target,
                                kind: .album,
                                rawID: id.uuidString,
                                title: row["name"]?.string ?? "未命名相簿",
                                subtitle: "相簿",
                                visual: .albumCover(nil, .album),
                                payload: .localAlbum(id),
                                isVideo: false))
        }

        let folderRows = ((try? db.query("SELECT id, name FROM folders")) ?? [])
            .filter { SearchFuzzyText.matches($0["name"]?.string, keyword: keyword) }
        for row in folderRows {
            guard let idString = row["id"]?.string,
                  let id = UUID(uuidString: idString) else { continue }
            hits.append(makeHit(target: target,
                                kind: .folder,
                                rawID: id.uuidString,
                                title: row["name"]?.string ?? "未命名文件夹",
                                subtitle: "文件夹",
                                visual: .albumCover(nil, .folder),
                                payload: .localFolder(id),
                                isVideo: false))
        }

        let peopleRows = ((try? db.query("SELECT id, name FROM people")) ?? [])
            .filter { SearchFuzzyText.matches($0["name"]?.string, keyword: keyword) }
        for row in peopleRows {
            guard let idString = row["id"]?.string,
                  let id = UUID(uuidString: idString),
                  let name = row["name"]?.string, !name.isEmpty else { continue }
            hits.append(makeHit(target: target,
                                kind: .person,
                                rawID: id.uuidString,
                                title: name,
                                subtitle: "人物",
                                visual: .avatar(nil, isPet: false),
                                payload: .localPerson(id),
                                isVideo: false))
        }
        return hits
    }

    // MARK: - 工具

    private nonisolated static func makeHit(target: LibrarySearchTarget,
                                            kind: SearchHitKind,
                                            rawID: String,
                                            title: String,
                                            subtitle: String,
                                            visual: SearchVisual,
                                            payload: SearchPayload,
                                            isVideo: Bool) -> SearchHit {
        var hit = SearchHit(id: "library|\(target.path)|\(kind.rawValue)|\(rawID)",
                            source: .library,
                            kind: kind,
                            title: title,
                            subtitle: subtitle,
                            badge: target.name,
                            visual: visual,
                            payload: payload,
                            origin: target.name)
        hit.libraryPath = target.path
        hit.isOtherLibrary = true
        return hit
    }

    /// SQLite `LIKE` 的通配符转义：关键词里的 % _ \ 按字面匹配。
    private nonisolated static func likePattern(_ keyword: String) -> String {
        let escaped = keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private nonisolated static func subtitle(for photo: PhotoItem) -> String {
        var parts: [String] = []
        if let city = photo.placeCity, !city.isEmpty { parts.append(city) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        parts.append(formatter.string(from: photo.capturedAt))
        return parts.joined(separator: " · ")
    }
}
