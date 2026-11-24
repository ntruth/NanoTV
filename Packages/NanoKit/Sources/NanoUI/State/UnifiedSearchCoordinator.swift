import Foundation
import NanoCore
import NanoLiveTV
import NanoRemoteHub
import NanoSync
import NanoVFS
import Observation

/// 全局异步流式统一搜索协调器（快源秒出结果，慢源异步流式追加并展示「正在检索...」状态）
@Observable
public final class UnifiedSearchCoordinator: @unchecked Sendable {
    public var query: String = ""
    public var activeScope: UnifiedSearchScope = .all
    public private(set) var searchingScopes: Set<UnifiedSearchScope> = []
    public private(set) var results: [UnifiedSearchResultItem] = []
    public var recentQueries: [String] = ["上海", "走马上任", "4K", "渡口", "央视"]

    private var runningSearchTask: Task<Void, Never>?

    public init() {}

    /// 统计某个分类胶囊的实时命中数量
    public func count(for scope: UnifiedSearchScope) -> Int {
        if scope == .all {
            return results.count
        }
        return results.filter { $0.scope == scope }.count
    }

    /// 按当前选中的分类胶囊过滤结果
    public var filteredResults: [UnifiedSearchResultItem] {
        if activeScope == .all {
            return results
        }
        return results.filter { $0.scope == activeScope }
    }

    /// 按分区分组展示（在「全部」胶囊下按 影院 -> 电视 -> 网盘 -> 网络影院 -> 资源 -> 音乐 分块渲染）
    public var groupedSections: [(scope: UnifiedSearchScope, items: [UnifiedSearchResultItem])] {
        let targetOrder: [UnifiedSearchScope] = [.liveTV, .cinema, .cloudDrive, .networkCinema, .remoteResource, .music]
        if activeScope != .all {
            let sub = results.filter { $0.scope == activeScope }
            return sub.isEmpty ? [] : [(activeScope, sub)]
        }
        return targetOrder.compactMap { scope in
            let sub = results.filter { $0.scope == scope }
            return sub.isEmpty ? nil : (scope, sub)
        }
    }

    /// 触发全渠道并发流式搜索
    @MainActor
    public func performUnifiedSearch(keyword: String, in appVM: NanoAppViewModel) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            runningSearchTask?.cancel()
            searchingScopes.removeAll()
            results.removeAll()
            return
        }

        self.query = trimmed
        if !recentQueries.contains(trimmed) {
            recentQueries.insert(trimmed, at: 0)
            if recentQueries.count > 10 { recentQueries.removeLast() }
        }

        runningSearchTask?.cancel()
        results.removeAll()
        let activeChannels: [UnifiedSearchScope] = [.liveTV, .cinema, .music, .cloudDrive, .networkCinema, .remoteResource]
        searchingScopes = Set(activeChannels)

        let visibleSources = appVM.visibleStorageSources
        let visibleMedia = appVM.visibleMediaItems
        let channels = appVM.liveChannels
        let subMap = Dictionary(uniqueKeysWithValues: appVM.iptvSubscriptions.map { ($0.id, $0.name) })
        let visibleSites = appVM.visibleRemoteSites
        let tracks = appVM.musicTracks

        runningSearchTask = Task {
            await withTaskGroup(of: (UnifiedSearchScope, [UnifiedSearchResultItem]).self) { group in
                // 1. 电视直播与回看（支持智能省份映射，如「上海」-> 东方卫视 / 东方卫视4K）
                group.addTask {
                    var tvHits: [UnifiedSearchResultItem] = []
                    for ch in channels where IPTVLiveEngine.matchesSearch(channel: ch, keyword: trimmed) {
                        for (lineIdx, line) in ch.lines.enumerated() {
                            let subName = subMap[line.subscriptionID] ?? "我的 IPTV"
                            let catchupTag = (line.catchupMode != .none) ? "直播 + 回看 (直连)" : "实时直播 (直连)"
                            let resSuffix = (line.resolutionTag == "4K") ? " · 2160p" : ""
                            let subtitle = "\(subName) · \(catchupTag) · \(ch.category)\(resSuffix)"
                            tvHits.append(
                                UnifiedSearchResultItem(
                                    id: "tv_\(ch.id.uuidString)_\(lineIdx)",
                                    scope: .liveTV,
                                    title: ch.displayName,
                                    subtitle: subtitle,
                                    badgeText: line.resolutionTag,
                                    artworkURL: ch.logoURL,
                                    action: .playLiveChannel(channelID: ch.id, lineIndex: lineIdx)
                                )
                            )
                        }
                    }
                    return (.liveTV, tvHits)
                }

                // 2. 本地已刮削影院海报墙（匹配标题、演员、简介、题材、国家地区）
                group.addTask {
                    let hits = visibleMedia.filter { item in
                        item.title.localizedCaseInsensitiveContains(trimmed)
                            || (item.originalTitle?.localizedCaseInsensitiveContains(trimmed) == true)
                            || item.overview.localizedCaseInsensitiveContains(trimmed)
                            || item.country.localizedCaseInsensitiveContains(trimmed)
                            || item.genres.contains(where: { $0.localizedCaseInsensitiveContains(trimmed) })
                            || item.cast.contains(where: { $0.name.localizedCaseInsensitiveContains(trimmed) })
                    }.map { item in
                        UnifiedSearchResultItem(
                            id: "cinema_\(item.id.uuidString)",
                            scope: .cinema,
                            title: item.title,
                            subtitle: "\(item.year.map(String.init) ?? "") · \(item.genres.joined(separator: "/")) · \(item.spec.resolution) \(item.spec.dynamicRange)",
                            badgeText: String(format: "★ %.1f", item.rating),
                            artworkURL: item.posterURL,
                            action: .openCinemaMedia(item.id)
                        )
                    }
                    return (.cinema, hits)
                }

                // 3. Hi-Fi 音乐中心（匹配歌名、歌手、专辑、LRC歌词）
                group.addTask {
                    let hits = tracks.filter { t in
                        t.title.localizedCaseInsensitiveContains(trimmed)
                            || t.artist.localizedCaseInsensitiveContains(trimmed)
                            || t.album.localizedCaseInsensitiveContains(trimmed)
                            || (t.lrcContent?.localizedCaseInsensitiveContains(trimmed) == true)
                    }.map { t in
                        UnifiedSearchResultItem(
                            id: "music_\(t.id.uuidString)",
                            scope: .music,
                            title: t.title,
                            subtitle: "\(t.artist) · 《\(t.album)》 · \(t.formatTag)",
                            badgeText: "Hi-Fi",
                            artworkURL: t.coverURL,
                            action: .playVFSNode(sourceID: t.sourceID, path: t.vfsPath, fileID: t.vfsPath, isAudio: true)
                        )
                    }
                    return (.music, hits)
                }

                // 4. 网盘与本地 NAS 存储目录检索（115 / 夸克 / 百度 / SMB / WebDAV）
                group.addTask {
                    let driveSources = visibleSources.filter {
                        $0.type != .xiaoyaOpenList && $0.type != .emby && $0.type != .jellyfin
                    }
                    var driveHits: [UnifiedSearchResultItem] = []
                    for src in driveSources {
                        let openToken = iCloudKeychainVault.shared.readSecret(forKey: "\(src.keychainCredentialID)_openapi")
                        let secret = iCloudKeychainVault.shared.readSecret(forKey: "\(src.keychainCredentialID)_secret") ?? ""
                        let user = iCloudKeychainVault.shared.readSecret(forKey: "\(src.keychainCredentialID)_user") ?? ""
                        let coord = VFSDriverRegistry.makeDualTrackCoordinator(
                            for: src,
                            openAPIToken: openToken,
                            cookieHeader: secret,
                            basicUsername: user
                        )
                        if let nodes = try? await coord.listDirectory(at: src.rootPath, parentFileID: nil) {
                            for n in nodes where (n.kind == .video || n.kind == .audio) && n.name.localizedCaseInsensitiveContains(trimmed) {
                                driveHits.append(
                                    UnifiedSearchResultItem(
                                        id: "drive_\(src.id.uuidString)_\(n.path)",
                                        scope: .cloudDrive,
                                        title: n.name,
                                        subtitle: "\(src.name) · \(n.path)",
                                        badgeText: src.type.displayName,
                                        action: .playVFSNode(sourceID: src.id, path: n.path, fileID: n.fileID, isAudio: n.kind == .audio)
                                    )
                                )
                            }
                        }
                    }
                    return (.cloudDrive, driveHits)
                }

                // 5. 网络影院（小雅 OpenList 全局秒搜 API / Emby / Jellyfin）
                group.addTask {
                    let netCinemaSources = visibleSources.filter {
                        $0.type == .xiaoyaOpenList || $0.type == .emby || $0.type == .jellyfin
                    }
                    var xiaoyaHits: [UnifiedSearchResultItem] = []
                    for src in netCinemaSources {
                        let token = iCloudKeychainVault.shared.readSecret(forKey: "\(src.keychainCredentialID)_secret")
                        let driver = XiaoyaOpenListDriver(source: src, apiToken: token)
                        if let foundNodes = try? await driver.searchFiles(keyword: trimmed) {
                            for n in foundNodes where n.kind == .video || n.kind == .folder {
                                xiaoyaHits.append(
                                    UnifiedSearchResultItem(
                                        id: "netcinema_\(src.id.uuidString)_\(n.path)",
                                        scope: .networkCinema,
                                        title: n.name,
                                        subtitle: "\(src.name) · 302 直链秒播 · \(n.path)",
                                        badgeText: "小雅直连",
                                        action: .playVFSNode(sourceID: src.id, path: n.path, fileID: n.fileID, isAudio: false)
                                    )
                                )
                            }
                        }
                    }
                    return (.networkCinema, xiaoyaHits)
                }

                // 6. 远程扩展资源站并发检索（苹果 CMS JSON / FongMi / 自定义网页爬虫规则）
                group.addTask {
                    let vods = await RemoteResourceEngineHub.searchAcrossEnabledSites(keyword: trimmed, sites: visibleSites)
                    let remoteHits: [UnifiedSearchResultItem] = vods.compactMap { vod in
                        guard let firstRoute = vod.playRoutes.first,
                              let firstEp = firstRoute.episodes.first else { return nil }
                        return UnifiedSearchResultItem(
                            id: "remote_\(vod.id)",
                            scope: .remoteResource,
                            title: vod.title,
                            subtitle: "\(vod.siteName) · \(vod.categoryName) · \(vod.remarks)",
                            badgeText: firstRoute.routeName,
                            artworkURL: vod.coverURL,
                            action: .playRemoteStream(title: vod.title, siteName: vod.siteName, streamURL: firstEp.url)
                        )
                    }
                    return (.remoteResource, remoteHits)
                }

                // 每完成一个通道，立即在主线程流式追加结果并消除该通道的「正在检索...」状态行
                for await (finishedScope, partialItems) in group {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self.searchingScopes.remove(finishedScope)
                        self.results.append(contentsOf: partialItems)
                    }
                }
            }
        }
    }
}
