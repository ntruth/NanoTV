import Foundation
import AppKit
import Combine
import LumaContentCore

/// 影院的文件侧逻辑：目录监听、文件夹、配置、刮削与手动匹配。

extension LibraryStore {
    // MARK: 文件夹

    /// 把一个影院下的视频按真实目录组织成树：首层展示顶层文件夹，点进去看下一层，
    /// 可以一直钻到某一季 / 某个电影目录；尚未刮削的视频也会出现在这里。
    func cinemaFolders(for scope: CinemaScope) -> [CinemaFolder] {
        let entries = cinemaIndexes[scope] ?? [:]
        let scopeMountID: UUID?
        switch scope {
        case .local: scopeMountID = nil
        case .mount(let mountID): scopeMountID = mountID
        }

        // 目录图谱：路径 -> 名称 / 父路径。夸克的路径是目录 ID，靠这张表还原层级。
        var names: [String: String] = [:]
        var parents: [String: String] = [:]
        var rootPath = "/local"
        var rootName = "本地图库"
        var mountName = "本地图库"
        switch scope {
        case .local:
            names[rootPath] = rootName
        case .mount(let mountID):
            guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return [] }
            rootPath = cloudRootPath(for: mount)
            rootName = "根目录"
            mountName = mount.name
            if let folders = cloudAlbumSnapshot(mountID: mountID)?.folders {
                for folder in folders where !folder.path.isEmpty {
                    names[folder.path] = folder.name
                    parents[folder.path] = folder.parentPath
                }
            }
            if cloudModel.scanMountID == mountID {
                for folder in cloudModel.scanFolders where !folder.path.isEmpty {
                    names[folder.path] = folder.name
                    parents[folder.path] = folder.parentPath
                }
            }
        }

        let rootKey = "root"
        // 每个目录节点只收直属视频，子树在构建时递归汇总。
        var meta: [String: (name: String, parent: String?, hint: String?)] = [:]
        var directPhotos: [String: [PhotoItem]] = [:]

        func ensure(_ key: String, name: String, parent: String?, hint: String?) {
            if var existing = meta[key] {
                if existing.parent == nil { existing.parent = parent }
                if existing.hint == nil { existing.hint = hint }
                meta[key] = existing
            } else {
                meta[key] = (name: name, parent: parent, hint: hint)
            }
        }

        /// 从盘根到当前目录的完整可读目录链。
        func chain(of path: String) -> String? {
            var parts: [String] = []
            var cursor: String? = path
            while let current = cursor, !current.isEmpty, current != rootPath,
                  let name = names[current], !name.isEmpty {
                parts.append(name)
                cursor = parents[current]
                if parts.count >= 16 { break }
            }
            return parts.isEmpty ? nil : parts.reversed().joined(separator: "/")
        }

        /// 补齐从盘根到该目录的所有祖先节点，保证任意深度都能逐层进入。
        @discardableResult
        func registerReal(_ path: String) -> String? {
            guard !path.isEmpty, path != rootPath, names[path] != nil else { return nil }
            var chainPaths: [String] = []
            var cursor: String? = path
            while let current = cursor, !current.isEmpty, current != rootPath,
                  names[current] != nil {
                chainPaths.append(current)
                cursor = parents[current]
                if chainPaths.count >= 24 { break }
            }
            guard !chainPaths.isEmpty else { return nil }
            var parent: String?
            for key in chainPaths.reversed() {
                ensure(key,
                       name: names[key] ?? Self.cinemaFolderName(of: key),
                       parent: parent,
                       hint: chain(of: key))
                parent = key
            }
            return path
        }

        /// 没有目录图谱（快照缺失等）时，按可读目录链合成层级。
        func registerHint(_ hint: String) -> String {
            let parts = hint.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else {
                ensure(rootKey, name: rootName, parent: nil, hint: mountName)
                return rootKey
            }
            var parent: String?
            var accumulated: [String] = []
            var last = rootKey
            for part in parts {
                accumulated.append(part)
                let key = "hint:" + accumulated.joined(separator: "/")
                ensure(key, name: part, parent: parent, hint: accumulated.joined(separator: "/"))
                parent = key
                last = key
            }
            return last
        }

        var seen: Set<UUID> = []
        for candidate in cinemaCandidates(for: scope) {
            let photo = candidate.photo
            let key: String
            if scopeMountID == nil {
                ensure(rootKey, name: rootName, parent: nil, hint: nil)
                key = rootKey
            } else if let path = candidate.folderPath, let real = registerReal(path) {
                key = real
            } else if let raw = photo.cloudPath,
                      !Self.cinemaPathLooksLikeID(raw),
                      let parentPath = Self.cinemaParentFolder(of: raw),
                      let real = registerReal(parentPath) {
                key = real
            } else if let hint = candidate.folderHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !hint.isEmpty {
                key = registerHint(hint)
            } else {
                ensure(rootKey, name: rootName, parent: nil, hint: mountName)
                key = rootKey
            }
            directPhotos[key, default: []].append(photo)
            seen.insert(photo.id)
        }

        // 已刮削但扫描清单里没有的视频也补进来，避免清空扫描结果后文件夹空掉。
        for entry in entries.values where !seen.contains(entry.id) {
            let hint = entry.folderHint?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let hint, !hint.isEmpty {
                directPhotos[registerHint(hint), default: []].append(entry.file.photoItem)
            } else if let raw = entry.file.cloudPath,
                      !Self.cinemaPathLooksLikeID(raw),
                      let parentPath = Self.cinemaParentFolder(of: raw),
                      let real = registerReal(parentPath) {
                directPhotos[real, default: []].append(entry.file.photoItem)
            } else {
                ensure(rootKey, name: rootName, parent: nil, hint: mountName)
                directPhotos[rootKey, default: []].append(entry.file.photoItem)
            }
        }

        var childrenByParent: [String: [String]] = [:]
        for (key, node) in meta {
            childrenByParent[node.parent ?? "", default: []].append(key)
        }

        func sortedKeys(_ keys: [String]) -> [String] {
            keys.sorted { lhs, rhs in
                let left = meta[lhs]?.name ?? lhs
                let right = meta[rhs]?.name ?? rhs
                return left.localizedStandardCompare(right) == .orderedAscending
            }
        }

        func build(_ key: String) -> CinemaFolder? {
            guard let node = meta[key] else { return nil }
            let photos = (directPhotos[key] ?? []).filter { photo in
                guard let entry = entries[photo.id] else { return true }
                return !cinemaIsRestricted(entry)
            }
            let children = sortedKeys(childrenByParent[key] ?? [])
                .compactMap { build($0) }
                .sorted { lhs, rhs in
                    if lhs.isMatched != rhs.isMatched { return lhs.isMatched }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            guard !photos.isEmpty || !children.isEmpty else { return nil }

            var subtree = photos
            for child in children { subtree.append(contentsOf: child.subtreePhotos) }
            let subtreeEntries = subtree.compactMap { entries[$0.id] }
            let matched = subtreeEntries.filter { $0.matched }
            let distinctTitles = Set(matched.map(\.title))
            // 只有整个文件夹都指向同一部影片 / 剧集时才用片名做标题；混合目录保留文件夹名。
            let dominantTitle = distinctTitles.count == 1 ? matched.first?.title : nil
            let sample = matched.first(where: { $0.posterURL != nil })
                ?? matched.first(where: { $0.backdropURL != nil })
                ?? matched.first
            return CinemaFolder(path: key,
                                name: node.name,
                                parentPath: node.parent,
                                hint: node.hint,
                                mountID: scopeMountID,
                                photos: photos,
                                entries: subtreeEntries,
                                children: children,
                                subtreePhotos: subtree,
                                matchedCount: matched.count,
                                title: dominantTitle,
                                kind: dominantTitle == nil ? nil : sample?.kind,
                                posterURL: sample?.posterURL ?? matched.compactMap(\.posterURL).first,
                                backdropURL: sample?.backdropURL ?? matched.compactMap(\.backdropURL).first,
                                year: dominantTitle == nil ? nil : sample?.year,
                                episodeCount: dominantTitle == nil ? 0 : matched.filter { $0.kind == .tv }.count)
        }

        return sortedKeys(childrenByParent[""] ?? [])
            .compactMap { build($0) }
            .sorted { lhs, rhs in
                if lhs.isMatched != rhs.isMatched { return lhs.isMatched }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// 在整棵文件夹树里按路径取一个节点（详情面板钻取时用）。
    func cinemaFolder(path: String, scope: CinemaScope) -> CinemaFolder? {
        var stack = cinemaFolders(for: scope)
        while let folder = stack.popLast() {
            if folder.path == path { return folder }
            stack.append(contentsOf: folder.children)
        }
        return nil
    }

    /// 只刮削一个文件夹：连同子目录一起识别，适合「先把这部剧的整个目录处理掉」。
    func scrapeCinemaFolder(_ folder: CinemaFolder, scope: CinemaScope) async {
        let sources = metadataSources()
        guard !sources.isEmpty else {
            showToast("没有可用的刮削源，请检查设置 › 影院")
            return
        }
        let targets = folder.subtreePhotos
        guard !targets.isEmpty else {
            showToast("这个文件夹里没有可刮削的视频")
            return
        }

        let taskID = beginCinemaTask(for: scope, total: targets.count)
        let cache = CinemaSearchCache()
        let detailsCache = CinemaDetailsCache()
        var matched = 0

        for photo in targets {
            if Task.isCancelled { break }
            let hint = cinemaIndexes[scope]?[photo.id]?.folderHint ?? folder.hint
            let outcome = await CinemaScraper.scrape(photo: photo,
                                                     folderHint: hint,
                                                     sources: sources,
                                                     cache: cache,
                                                     detailsCache: detailsCache)
            if let entry = outcome.entry {
                cinemaIndexes[scope, default: [:]][entry.id] = entry
                if entry.matched { matched += 1 }
            }
        }

        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        let scopeMatched = (cinemaIndexes[scope] ?? [:]).values.filter { $0.matched }.count
        finishCinemaTask(taskID,
                         matched: scopeMatched,
                         succeeded: true,
                         message: "文件夹「\(folder.displayTitle)」：识别 \(matched)/\(targets.count)")
        showToast("「\(folder.displayTitle)」刮削完成：识别 \(matched)/\(targets.count)")
    }

    static func cinemaParentFolder(of path: String) -> String? {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parent = (trimmed as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/", parent != "." else { return nil }
        return parent
    }

    static func cinemaFolderName(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "根目录" : name
    }

    static func cinemaFolderHint(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init).suffix(3)
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// 夸克等网盘的 `cloudPath` 实际是文件 / 目录 ID（32 位十六进制），不是可读路径。
    static func cinemaPathLooksLikeID(_ path: String) -> Bool {
        guard !path.contains("/"), path.count >= 16 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return path.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: 配置

    /// 两个源同时工作：按优先级排序，TMDB 没填 Key 时自动跳过，只剩豆瓣。
    var cinemaNeedsConfiguration: Bool {
        metadataSources().isEmpty
    }

    func metadataSources() -> [any CinemaMetadataSource] {
        AppSettings.shared.cinemaSourceOrder.compactMap { metadataSource(for: $0) }
    }

    /// 单个源：没填 Key 的 TMDB / TVDB 返回 nil（自动跳过）。
    func metadataSource(for provider: CinemaProvider) -> (any CinemaMetadataSource)? {
        let settings = AppSettings.shared
        switch provider {
        case .tmdb:
            let key = settings.cinemaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return TMDBClient(apiKey: key,
                              apiBase: settings.cinemaAPIBase,
                              imageBase: settings.cinemaImageBase,
                              language: settings.cinemaLanguage)
        case .douban:
            return DoubanClient(apiBase: settings.cinemaDoubanBase,
                                cookie: settings.cinemaDoubanCookie)
        case .tvdb:
            let key = settings.cinemaTVDBKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return TVDBClient(apiKey: key,
                              pin: settings.cinemaTVDBPin,
                              language: settings.cinemaLanguage)
        }
    }

    /// 人物页作品悬停：按需补一次 TMDB 详情（简介 / 评分 / 类型 / 片长）。
    /// 未入库的作品没有本地档案，只能靠这一步把悬停信息补丰富。
    func cinemaCreditDetails(for credit: CinemaPersonCredit) async -> CinemaDetails? {
        guard let tmdb = metadataSource(for: .tmdb) as? TMDBClient else { return nil }
        return try? await tmdb.details(id: credit.tmdbID, isTV: credit.isTV)
    }

    /// 设置页单源连通性测试：只测这一行，不影响其它源的结果。
    func testCinemaProvider(_ provider: CinemaProvider) async -> CinemaConnectionResult {
        guard let source = metadataSource(for: provider) else {
            return CinemaConnectionResult(ok: false, message: "还没填 API Key")
        }
        do {
            let results = try await source.search(query: "流浪地球", isTV: false, year: nil)
            if let first = results.first {
                let year = first.year.map { "（\($0)）" } ?? ""
                return CinemaConnectionResult(ok: true, message: "连通 · \(first.title)\(year)")
            }
            return CinemaConnectionResult(ok: true, message: "连通 · 搜索无结果")
        } catch {
            return CinemaConnectionResult(ok: false, message: error.localizedDescription)
        }
    }

    /// 设置面板里的「测试连接」：用固定片名把每个在用数据源都搜一次，验证凭据与网络。
    func testCinemaConnection() async {
        guard !cinemaConnectionTesting else { return }
        let sources = metadataSources()
        guard !sources.isEmpty else {
            cinemaConnectionResult = CinemaConnectionResult(ok: false, message: "没有可用的刮削源")
            return
        }
        cinemaConnectionTesting = true
        cinemaConnectionResult = nil

        var succeeded: [String] = []
        var failures: [String] = []
        for source in sources {
            let name = source.provider.title
            do {
                let results = try await source.search(query: "流浪地球", isTV: false, year: nil)
                if let first = results.first {
                    let year = first.year.map { "（\($0)）" } ?? ""
                    succeeded.append("\(name)：\(first.title)\(year)")
                } else {
                    succeeded.append("\(name)：可用（搜索无结果）")
                }
            } catch {
                failures.append("\(name)：\(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            cinemaConnectionResult = CinemaConnectionResult(ok: true,
                                                            message: "连接正常 · " + succeeded.joined(separator: "；"))
        } else {
            var message = failures.joined(separator: "；")
            if !succeeded.isEmpty {
                message += "（" + succeeded.map { String($0.split(separator: "：")[0]) }.joined(separator: "、") + " 正常）"
            }
            cinemaConnectionResult = CinemaConnectionResult(ok: false, message: message)
        }
        cinemaConnectionTesting = false
    }

    // MARK: 刮削

    /// 从 UI 启动刮削：任务被保存下来，用户可以在进度条上取消。
    func startCinemaScrape(for scope: CinemaScope, force: Bool = false) {
        guard !cinemaScrapeRunning else { return }
        cinemaScrapeTask?.cancel()
        cinemaScrapeTask = Task { [weak self] in
            guard let self else { return }
            await self.scrapeCinema(for: scope, force: force)
            self.cinemaScrapeTask = nil
        }
    }

    /// 取消正在进行的刮削：中断网络请求，并保留已经完成的结果。
    func cancelCinemaScrape() {
        cinemaScrapeTask?.cancel()
        cinemaScrapeTask = nil
        guard cinemaScrapeRunning else { return }
        cinemaScrapeRunning = false
        cinemaScrapeScope = nil
        cinemaScrapeMessage = "已取消刮削，已完成的结果会保留"
        showToast("已取消刮削")
    }

    /// 刮削某一个影院（本地图库或某个网盘）。`force` 为 true 时连已刮削过的也重新匹配。
    func scrapeCinema(for scope: CinemaScope, force: Bool = false) async {
        guard !cinemaScrapeRunning else { return }
        let sources = metadataSources()
        guard !sources.isEmpty else {
            cinemaScrapeMessage = "没有可用的刮削源，请检查设置 › 影院"
            cinemaSourceError = SourceError(kind: .unsupported,
                                            message: cinemaScrapeMessage ?? "没有可用的刮削源",
                                            recovery: [.reconfigureSource])
            return
        }
        var skippedCount = 0
        let all = cinemaCandidates(for: scope, skipped: &skippedCount)
        let existing = cinemaIndexes[scope] ?? [:]
        // 没识别成功的条目留在「未识别」里；再次点刮削时重试它们，而不是直接说「都已刮削」。
        let pending = force ? all : all.filter { existing[$0.photo.id]?.matched != true }
        guard !pending.isEmpty else {
            cinemaScrapeMessage = all.isEmpty
                ? "这个链接下还没有可刮削的视频清单，先在「相簿」里重新扫描网盘"
                : "这个链接的视频都已识别，没有新的可刮削"
            return
        }

        cinemaScrapeRunning = true
        cinemaScrapeScope = scope
        cinemaScrapeDone = 0
        cinemaScrapeTotal = pending.count
        cinemaScrapeMessage = nil
        cinemaSourceError = nil
        let taskID = beginCinemaTask(for: scope, total: pending.count)
        showToast("开始刮削这个链接下的 \(pending.count) 个视频…")

        // 同一部剧的多集共用同名搜索结果，避免几十集重复请求；
        // 详情（合集 / 演职员 / 预告 / 分级）同样按 tmdbID 只拉一次。
        let cache = CinemaSearchCache()
        let detailsCache = CinemaDetailsCache()
        // 同一目录的 NFO 只读一次；没有 NFO 的目录也记下来，避免每集重复列目录。
        cinemaNFOByFolder = [:]
        cinemaNFOEmptyFolders = []
        var failures = 0
        /// 当前还能用的源：某个源连续失败会被摘掉，其它源继续，不整批停。
        var activeSources = sources
        var providerStreak: [CinemaProvider: Int] = [:]
        var degradedProviders: [CinemaProvider: String] = [:]
        var firstError: String?
        var processed = 0
        // 结果先写进本地草稿，再按 0.3s 批量发布：几千条时不会每写一条就整库重算。
        var working = existing
        var lastPersistAt = Date.distantPast
        var lastPublishAt = Date.distantPast

        func publish(force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastPublishAt) >= 0.3 {
                cinemaIndexes[scope] = working
                cinemaScrapeDone = processed
                updateSourceJob(taskID,
                                completed: processed,
                                total: pending.count,
                                message: "已刮削 \(processed) / \(pending.count)")
                lastPublishAt = now
            }
            if force || now.timeIntervalSince(lastPersistAt) >= 2 {
                persistCinemaIndex(for: scope)
                lastPersistAt = now
            }
        }

        func advance(_ count: Int) {
            processed += count
        }

        // 所有源都被降级才整批停：单个源 403 / 限流只摘掉它，其它源继续。
        func stopIfAllSourcesDown() -> Bool {
            guard activeSources.isEmpty else { return false }
            publish(force: true)
            cinemaScrapeRunning = false
            cinemaScrapeScope = nil
            let detail = degradedProviders
                .map { "\($0.key.title)：\(Self.cinemaNetworkHint(for: $0.value))" }
                .joined(separator: "；")
            cinemaScrapeMessage = "刮削中断：所有刮削源都请求失败。\(detail)"
            cinemaSourceError = SourceError(kind: .unavailable,
                                            message: cinemaScrapeMessage ?? "刮削中断",
                                            recovery: [.retry, .reconfigureSource])
            finishCinemaTask(taskID,
                             matched: working.values.filter { $0.matched }.count,
                             succeeded: false,
                             skipped: skippedCount,
                             message: cinemaScrapeMessage ?? "刮削中断")
            showToast("刮削中断：刮削源都不可用")
            postCinemaToast(.failure,
                            title: "刮削中断 · 刮削源不可达",
                            detail: detail.isEmpty
                                ? Self.cinemaNetworkHint(for: firstError ?? "网络异常")
                                : detail,
                            actionTitle: "重试") { [weak self] in
                self?.startCinemaScrape(for: scope, force: true)
            }
            return true
        }

        // NFO 读取要复用目录缓存，先顺序处理；剩下需要联网的再按并发批量刮削。
        var webQueue: [CinemaCandidate] = []
        for candidate in pending {
            if Task.isCancelled { break }
            if let nfoEntry = await cinemaNFOEntry(for: candidate, scope: scope) {
                working[nfoEntry.id] = nfoEntry
            } else {
                webQueue.append(candidate)
            }
            advance(1)
            if processed % 5 == 0 { await Task.yield() }
            publish()
        }

        let concurrency = max(1, min(6, AppSettings.shared.cinemaScrapeConcurrency))
        var cursor = 0
        while cursor < webQueue.count {
            if Task.isCancelled { break }
            let end = min(webQueue.count, cursor + concurrency)
            let batch = Array(webQueue[cursor..<end])
            // 每批用当下的可用源快照：已被降级的源不会再发请求。
            let batchSources = activeSources
            let outcomes = await withTaskGroup(of: CinemaScrapeOutcome.self) { group in
                for candidate in batch {
                    group.addTask {
                        await CinemaScraper.scrape(photo: candidate.photo,
                                                   folderHint: candidate.folderHint,
                                                   sources: batchSources,
                                                   cache: cache,
                                                   detailsCache: detailsCache)
                    }
                }
                var collected: [CinemaScrapeOutcome] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            for outcome in outcomes {
                if let entry = outcome.entry {
                    var merged = entry
                    // 用户手动挑过的封面不被重新刮削覆盖。
                    if let old = working[entry.id], old.artworkLocked == true {
                        merged.posterURL = old.posterURL
                        merged.backdropURL = old.backdropURL
                        merged.artworkLocked = true
                    }
                    working[merged.id] = merged
                    // 有源正常返回，视为这一轮网络恢复，失败计数清零。
                    providerStreak = [:]
                }
                // 按源降级：同一源连续失败 2 次就只跳过它，其它源继续。
                for (provider, message) in outcome.failedProviders {
                    let streak = (providerStreak[provider] ?? 0) + 1
                    providerStreak[provider] = streak
                    if streak >= 2, degradedProviders[provider] == nil {
                        degradedProviders[provider] = message
                        activeSources.removeAll { $0.provider == provider }
                        postCinemaToast(.failure,
                                        title: "\(provider.title) 暂不可用",
                                        detail: "已跳过这个源，继续用其它源刮削")
                    }
                }
                if let error = outcome.error {
                    failures += 1
                    if firstError == nil { firstError = error }
                }
            }
            cursor = end
            advance(batch.count)
            publish()
            if stopIfAllSourcesDown() { return }
            await Task.yield()
        }
        publish(force: true)

        if Task.isCancelled {
            persistCinemaIndex(for: scope)
            cinemaScrapeRunning = false
            cinemaScrapeScope = nil
            cinemaScrapeMessage = "已取消刮削，已完成的结果会保留"
            cinemaSourceError = nil
            cinemaFolderRefreshToken &+= 1
            let matched = (cinemaIndexes[scope] ?? [:]).values.filter { $0.matched }.count
            updateSourceJob(taskID, completed: matched, message: "已取消")
            cancelSourceJob(taskID)
            return
        }

        persistCinemaIndex(for: scope)
        cinemaScrapeRunning = false
        cinemaScrapeScope = nil
        let scopeEntries = cinemaIndexes[scope] ?? [:]
        let matched = scopeEntries.values.filter { $0.matched }.count
        let unmatched = scopeEntries.count - matched
        var message = "刮削完成：共 \(scopeEntries.count) 个视频，识别 \(matched) 个，未识别 \(unmatched) 个"
        if skippedCount > 0 {
            message += "；跳过 \(skippedCount) 个（录屏 / 极短 / 已忽略）"
        }
        if failures > 0 {
            message += "；\(failures) 条失败：" + Self.cinemaNetworkHint(for: firstError ?? "网络或接口异常")
        }
        cinemaScrapeMessage = message
        cinemaFolderRefreshToken &+= 1
        // 在线片头片尾放到完成之后补，不拖慢刮削进度；已有设置 / 查过的剧集不重复请求。
        Task { await self.autoFillCinemaIntros(for: scope) }
        finishCinemaTask(taskID,
                         matched: matched,
                         succeeded: failures == 0,
                         skipped: skippedCount,
                         message: message)
        postCinemaToast(failures == 0 ? .success : .failure,
                        title: failures == 0
                            ? "刮削完成 · \(matched) 部已识别"
                            : "刮削完成 · \(unmatched) 个未识别",
                        detail: "\(cinemaScopeName(scope)) · \(scopeEntries.count) 个视频",
                        actionTitle: "查看") { [weak self] in
            self?.cinemaNotificationsVisible = true
        }
        // 设置里打开「导出 NFO」后，刮削完成把结果写到本地视频同目录。
        exportCinemaNFOIfEnabled(for: scope)
    }

    /// 把常见网络错误翻译成能直接照做的提示。
    static func cinemaNetworkHint(for message: String) -> String {
        let lower = message.lowercased()
        let networkLike = ["timed out", "timeout", "超时", "offline", "internet", "connect",
                           "network", "networkconnection", "连接", "无法访问"]
        if networkLike.contains(where: { lower.contains($0) }) {
            return "当前网络无法连接刮削源（TMDB / 豆瓣），请检查代理或网络后重试。"
        }
        return "刮削源返回：\(message)"
    }

    /// 单条重新刮削（右键菜单），结果写回条目所属的影院。
    func rescrapeCinema(_ entry: CinemaEntry) async {
        let sources = metadataSources()
        guard !sources.isEmpty else {
            cinemaScrapeMessage = "没有可用的刮削源，请检查设置 › 影院"
            return
        }
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        let outcome = await CinemaScraper.scrape(photo: photo,
                                                 folderHint: entry.folderHint,
                                                 sources: sources,
                                                 detailsCache: CinemaDetailsCache())
        if let error = outcome.error {
            cinemaScrapeMessage = "重新刮削失败：\(error)"
            cinemaSourceError = SourceError(kind: .unavailable,
                                            message: cinemaScrapeMessage ?? "重新刮削失败",
                                            recovery: [.retry, .reconfigureSource])
            showToast("重新刮削失败")
            return
        }
        guard let updated = outcome.entry else { return }
        var merged = updated
        if let old = cinemaIndexes[scope]?[entry.id], old.artworkLocked == true {
            merged.posterURL = old.posterURL
            merged.backdropURL = old.backdropURL
            merged.artworkLocked = true
        }
        cinemaIndexes[scope, default: [:]][merged.id] = merged
        persistCinemaIndex(for: scope)
        showToast(updated.matched ? "已匹配「\(updated.title)」" : "仍未找到匹配结果")
    }

    // MARK: 手动匹配

    /// 用户输入片名后的候选搜索；只读，不写回索引。
    /// `providers` 为空表示查全部可用源，`combineAll` 为 true 时不再「第一个有结果就停」。
    func cinemaSearchCandidates(query: String,
                                isTV: Bool,
                                year: Int?,
                                providers: [CinemaProvider]? = nil,
                                combineAll: Bool = false) async -> (matches: [CinemaMatch], error: String?) {
        var sources = metadataSources()
        if let providers, !providers.isEmpty {
            sources = sources.filter { providers.contains($0.provider) }
        }
        guard !sources.isEmpty else {
            let names = (providers ?? []).map(\.title).joined(separator: " / ")
            return ([], names.isEmpty
                    ? "没有可用的刮削源，请检查设置 › 影院"
                    : "\(names) 还没配置，请到设置 › 影院填写 Key")
        }
        return await CinemaScraper.searchCandidates(query: query,
                                                    isTV: isTV,
                                                    year: year,
                                                    sources: sources,
                                                    combineAllSources: combineAll)
    }

    /// 应用手动匹配：只替换这一条，不重扫全库。
    @discardableResult
    func applyCinemaMatch(_ match: CinemaMatch, to entry: CinemaEntry) -> CinemaEntry? {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        let parsed = CinemaScraper.parse(filename: entry.file.filename,
                                         folderHint: entry.folderHint)
        let updated = CinemaScraper.manualEntry(photo: photo,
                                                parsed: parsed,
                                                folderHint: entry.folderHint,
                                                match: match)
        cinemaIndexes[scope, default: [:]][updated.id] = updated
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("已匹配「\(updated.title)」")
        return updated
    }

    // MARK: 播放

    /// 从影院直接进入查看器；不依赖该网盘目录当前是否加载。
    /// `queue` 传入当前列表或整季剧集，用于播完自动连播与顶栏「下一集」。
    func openCinema(_ entry: CinemaEntry, queue: [CinemaEntry]? = nil) {
        if let queue {
            cinemaQueue = queue
        }
        if !cinemaQueue.contains(where: { $0.id == entry.id }) {
            cinemaQueue = [entry]
        }
        // 切换影片前先把上一条的进度落盘，避免连续点两部片时丢掉前一部的位置。
        finishCinemaPlayback()
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        cinemaPlaybackPhoto = photo
        cinemaPlaybackEntry = entry
        // 换片瞬间播放器里还挂着上一个视频：先停掉，避免旧片的进度回调写进新条目。
        if viewerID != photo.id {
            viewerModel.videoPlayer.stop()
        }
        // 打开别的片子时丢掉不匹配的预热流，避免残留 ffmpeg；匹配的留给播放页接管。
        if cinemaPrewarmedStream?.photoID != entry.id {
            discardPrewarmedCinemaStream()
        }
        openViewer(photo.id)
        viewerModel.videoPlaybackUI.subtitleQuery = CinemaSubtitleQuery(title: entry.title,
                                                                        season: entry.season,
                                                                        episode: entry.episode)
        // 在线查这一集的真实片头；拿到时还在片头区间就跳过去（只查一次）。
        if entry.kind == .tv {
            Task { await self.refineCinemaIntroOnPlayback(for: entry) }
        }
    }

    /// 从头播放：清掉这一条的观看进度后再打开播放器（电影详情的「从头播放」）。
    func openCinemaFromStart(_ entry: CinemaEntry) {
        if cinemaProgress[entry.id] != nil {
            cinemaProgress[entry.id] = nil
            persistCinemaProgress()
        }
        openCinema(entry)
    }

    /// 队列里当前条目的前 / 后一条（按打开时的列表顺序）。
    func cinemaQueueNeighbor(of id: UUID, delta: Int) -> CinemaEntry? {
        guard let current = cinemaQueue.firstIndex(where: { $0.id == id }) else { return nil }
        let index = current + delta
        guard cinemaQueue.indices.contains(index) else { return nil }
        return cinemaQueue[index]
    }

    /// 播放器「上一集 / 下一集」与播完自动连播统一走这里。
    @discardableResult
    func stepCinemaQueue(_ delta: Int) -> Bool {
        guard let current = cinemaPlaybackEntry,
              let next = cinemaQueueNeighbor(of: current.id, delta: delta) else { return false }
        openCinema(next)
        return true
    }

    // MARK: 忽略 / 删除

    func isCinemaIgnored(_ entry: CinemaEntry) -> Bool {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        return cinemaIgnoredIDs[scope]?.contains(entry.file.photoID) == true
    }

    /// 相似推荐点击时回本库找同 tmdbID 的条目；找不到就由调用方给出提示。
    func cinemaEntry(tmdbID: Int, kind: CinemaMediaKind) -> CinemaEntry? {
        for entries in cinemaIndexes.values {
            if let found = entries.values.first(where: {
                $0.matched && $0.tmdbID == tmdbID && $0.kind == kind
            }) {
                return found
            }
        }
        return nil
    }

    /// 影院里点「在网络影院搜索」：切到网络影院，带着关键词直接搜。
    /// 推荐位、演职员作品、演员页都走这里，两个模块从此打通。
    @discardableResult
    func searchOnlineCinema(_ keyword: String) -> Bool {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        networkCinemaSourceID = nil
        // 搜索只在电影 / 电视剧分页生效：停在管理、榜单等分页时先回到能搜的一页。
        if !networkCinemaTab.browsesContent {
            networkCinemaTab = .movies
        }
        networkCinemaSearchSeed = trimmed
        navigate(to: .networkCinema)
        return true
    }

    /// 拉 TMDB 图片候选：详情页「换封面」用，结果不落盘，选中的那张才写回索引。
    func cinemaArtworkCandidates(for entry: CinemaEntry) async
        -> (posters: [CinemaArtworkCandidate], backdrops: [CinemaArtworkCandidate]) {
        guard entry.matched, entry.provider == .tmdb, let tmdbID = entry.tmdbID else {
            return ([], [])
        }
        for source in metadataSources() {
            guard let tmdb = source as? TMDBClient else { continue }
            if let result = try? await tmdb.artworkCandidates(id: tmdbID, isTV: entry.kind == .tv) {
                return result
            }
        }
        return ([], [])
    }

    /// 写回手动挑选的海报 / 背景；剧集同步整部剧，避免卡片与详情各用一张图。
    func applyCinemaArtwork(_ entry: CinemaEntry,
                            posterURL: String?,
                            backdropURL: String?) {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        guard var current = cinemaIndexes[scope]?[entry.id] else { return }

        func stamp(_ item: inout CinemaEntry) {
            if let posterURL { item.posterURL = posterURL }
            if let backdropURL { item.backdropURL = backdropURL }
            item.artworkLocked = true
        }

        stamp(&current)
        cinemaIndexes[scope, default: [:]][current.id] = current

        if current.kind == .tv {
            let key = cinemaSeriesKey(for: current)
            for (id, var item) in cinemaIndexes[scope] ?? [:]
            where id != current.id && item.kind == .tv && cinemaSeriesKey(for: item) == key {
                stamp(&item)
                cinemaIndexes[scope]?[id] = item
            }
        }
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("封面已更新")
    }

    /// 忽略一个视频：从影院里移除，以后刮削也不会再处理它（原文件不动）。
    func ignoreCinemaEntry(_ entry: CinemaEntry) {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        var ignored = cinemaIgnoredIDs[scope] ?? []
        ignored.insert(entry.file.photoID)
        cinemaIgnoredIDs[scope] = ignored
        persistCinemaIgnored(for: scope)
        cinemaIndexes[scope]?[entry.id] = nil
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("已忽略「\(entry.title)」，以后不再刮削")
    }

    /// 剧集整部忽略：一次性把这条聚合里的全部分集标记为忽略。
    func ignoreCinemaSeries(_ series: CinemaSeries) {
        guard let scope = series.episodes.first.map({
            $0.file.cloudMountID.map { CinemaScope.mount($0) } ?? .local
        }) else { return }
        var ignored = cinemaIgnoredIDs[scope] ?? []
        for episode in series.episodes {
            ignored.insert(episode.file.photoID)
            cinemaIndexes[scope]?[episode.id] = nil
        }
        cinemaIgnoredIDs[scope] = ignored
        persistCinemaIgnored(for: scope)
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("已忽略「\(series.title)」的 \(series.episodes.count) 个文件，以后不再刮削")
    }

    /// 恢复被忽略的视频：清空忽略清单，下次刮削会重新处理它们。
    func restoreCinemaIgnored(for scope: CinemaScope) {
        let count = cinemaIgnoredIDs[scope]?.count ?? 0
        guard count > 0 else { return }
        cinemaIgnoredIDs[scope] = []
        persistCinemaIgnored(for: scope)
        cinemaFolderRefreshToken &+= 1
        showToast("已恢复 \(count) 个视频，下次刮削会重新处理")
    }

    func persistCinemaIgnored(for scope: CinemaScope) {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(Array(cinemaIgnoredIDs[scope] ?? [])),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaIgnoredSettingKey(for: scope), json)
    }

    /// 删除确认：真删原文件，刮削索引 / 进度 / 清单引用一并清理。
    func confirmDeleteCinemaEntries(_ entries: [CinemaEntry], title: String? = nil) {
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        let cloud = entries.contains { $0.file.isCloud }
        alert.messageText = "永久删除\(title.map { "「\($0)」" } ?? "")的 \(entries.count) 个视频文件？"
        alert.informativeText = "会从\(cloud ? "网盘 / 共享" : "本机磁盘")直接删除原文件，无法恢复；"
            + "影院索引、观看记录与清单引用会一起清理。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "永久删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await deleteCinemaEntries(entries) }
    }

    /// 逐个删除原文件，成功的条目才从影院移除；失败的给出可读原因。
    func deleteCinemaEntries(_ entries: [CinemaEntry]) async {
        var removed = 0
        var failure: String?
        for entry in entries {
            if entry.file.isCloud {
                if let reason = await deleteCinemaCloudFile(entry) {
                    failure = reason
                    continue
                }
            } else if let reason = deleteCinemaLocalFile(entry) {
                failure = reason
                continue
            }
            removeCinemaEntryAssets(entry)
            removed += 1
        }
        if let failure {
            showToast("删除失败：\(failure)")
            postCinemaToast(.failure, title: "删除失败", detail: failure)
        } else if removed > 0 {
            showToast(removed == 1 ? "已永久删除" : "已永久删除 \(removed) 个文件")
        }
    }

    /// 本地文件：直接删原图，再清掉照片索引与派生数据。
    func deleteCinemaLocalFile(_ entry: CinemaEntry) -> String? {
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        let url = LibraryPaths.originalURL(for: photo)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                return "\(entry.file.filename)：\(error.localizedDescription)"
            }
        }
        purgeAssetArtifacts(photo)
        purgeAssetMetadata([photo.id])
        photos.removeAll { $0.id == photo.id }
        save()
        return nil
    }

    /// 网盘 / 共享文件：按来源类型走各自的删除通道。
    func deleteCinemaCloudFile(_ entry: CinemaEntry) async -> String? {
        guard let mountID = entry.file.cloudMountID,
              let mount = cloudMounts.first(where: { $0.id == mountID }) else {
            return "找不到这个网盘连接，请先在侧边栏重新连接"
        }
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        do {
            try await CloudService.delete(mount: mount, photo: photo)
        } catch {
            return "\(entry.file.filename)：\(error.localizedDescription)"
        }
        if let path = photo.cloudPath {
            try? FileManager.default.removeItem(
                at: CloudPaths.thumbnailURL(mountID: mountID, path: path))
        }
        cloudPhotos.removeAll { $0.id == photo.id }
        cloudModel.scanPhotos.removeAll { $0.id == photo.id }
        if cloudModel.scanMountID == mountID {
            refreshCloudDirectory()
        }
        return nil
    }

    /// 删除成功后的索引清理：条目 / 进度 / 收藏 / 清单引用一次清干净。
    func removeCinemaEntryAssets(_ entry: CinemaEntry) {
        let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
        cinemaIndexes[scope]?[entry.id] = nil
        persistCinemaIndex(for: scope)
        cinemaIgnoredIDs[scope]?.remove(entry.file.photoID)
        persistCinemaIgnored(for: scope)
        cinemaProgress[entry.id] = nil
        persistCinemaProgress()
        cinemaUserStates[entry.id] = nil
        persistCinemaUserState()
        cinemaLists = cinemaLists.map { list in
            var copy = list
            copy.itemIDs.removeAll { $0 == entry.id }
            return copy
        }
        persistCinemaLists()
        cinemaFolderRefreshToken &+= 1
        if viewerID == entry.file.photoID {
            closeViewer()
        }
    }

    // MARK: 缓存到图库

    /// 把影院里的网盘视频缓存进当前图库：下载 → 统一入库，和资源站保存走同一入口。
    /// 本地图库里的视频本身就在库里，不重复缓存。
    func cacheCinemaEntryToLibrary(_ entry: CinemaEntry) async {
        guard let mountID = entry.file.cloudMountID else {
            showToast("这个视频已经在图库里，无需缓存")
            return
        }
        let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
        let name = entry.title ?? entry.file.filename
        let jobID = beginSourceJob(
            SourceJob(sourceID: .cloud(mountID),
                      kind: .download,
                      title: "缓存《\(name)》")
        )
        updateSourceJob(jobID, message: "下载中…")
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-cinema-\(UUID().uuidString)-\(entry.file.filename)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await downloadCloudItem(photo, to: temp)
            updateSourceJob(jobID, message: "导入图库…")
            let result = try await ingestService.ingest(
                IngestRequest(payload: .localFile(temp), title: name))
            finishSourceJob(jobID, message: "已缓存：\(result.title)")
            showToast("已缓存到图库：\(result.title)")
        } catch {
            failSourceJob(jobID, message: error.localizedDescription)
            showToast("缓存失败：\(error.localizedDescription)")
        }
    }
}
