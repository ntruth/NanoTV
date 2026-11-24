import Foundation
import NanoCore
import NanoLiveTV
import NanoMusic
import NanoPlayerKit
import NanoRemoteHub
import NanoScraper
import NanoSync
import NanoVFS
import Observation

/// 全局一级导航分区路由
public enum NanoSidebarSection: Hashable, Identifiable, Sendable {
    case unifiedSearch
    case storageHub
    case embeddedXiaoya
    case storageDetail(UUID)
    case cinemaWall
    case cinemaDetail(UUID)
    case liveTVAll
    case liveTVCategory(String)
    case remoteResourceHub
    case remoteSiteDetail(UUID)
    case musicCenter
    case infuseProLab
    case privacySpace
    case settingsSync

    public var id: String {
        switch self {
        case .unifiedSearch: return "unifiedSearch"
        case .storageHub: return "storageHub"
        case .embeddedXiaoya: return "embeddedXiaoya"
        case .storageDetail(let id): return "storage_\(id.uuidString)"
        case .cinemaWall: return "cinemaWall"
        case .cinemaDetail(let id): return "cinema_\(id.uuidString)"
        case .liveTVAll: return "liveTVAll"
        case .liveTVCategory(let cat): return "liveTV_\(cat)"
        case .remoteResourceHub: return "remoteHub"
        case .remoteSiteDetail(let id): return "remoteSite_\(id.uuidString)"
        case .musicCenter: return "musicCenter"
        case .infuseProLab: return "infuseProLab"
        case .privacySpace: return "privacySpace"
        case .settingsSync: return "settingsSync"
        }
    }
}

@Observable
public final class NanoAppViewModel: @unchecked Sendable {
    public var selectedSection: NanoSidebarSection = .liveTVAll
    public var isPresentingFullPlayer: Bool = false

    // 核心数据集
    public var storageSources: [StorageSource] = []
    public var mediaItems: [MediaItem] = []
    public var episodesByMediaID: [UUID: [MediaEpisode]] = [:]
    public var editionsByMediaID: [UUID: [MediaEditionVariant]] = [:]
    public var collections: [MediaCollectionGroup] = []
    public var iptvSubscriptions: [IPTVSubscriptionSource] = []
    public var liveChannels: [IPTVChannelGroup] = []
    public var catchupProgramsByChannel: [String: [EPGProgramItem]] = [:]
    public var remoteSites: [RemoteResourceSite] = []
    public var musicTracks: [MusicTrack] = []

    // 家庭家长分级控制
    public var parentalControlEnabled: Bool = false
    public var allowedMaxRatingTier: ContentRatingTier = .pg13

    // 刮削器 TMDB Key（自动持久化至 Keychain）
    public var tmdbAPIKey: String = "" {
        didSet {
            iCloudKeychainVault.shared.saveSecret(tmdbAPIKey, forKey: "nano_tmdb_api_key", syncOverICloud: true)
        }
    }

    public var lanHelperURL: String = ""
    public var syncStatusMessage: String = ""

    public let player = NanoPlayerController.shared
    public let cacheManager = DiskCacheQuotaManager.shared
    public let privacyGuard = PrivacyVaultGuard.shared
    public let searchCoordinator = UnifiedSearchCoordinator()

    public init() {
        self.tmdbAPIKey = iCloudKeychainVault.shared.readSecret(forKey: "nano_tmdb_api_key") ?? ""
        bootstrapInitialShowcaseData()
        Task {
            await restorePersistedEntitiesFromSQLite()
            // 安装到 Apple TV 或 macOS 启动后，自动扫描本地局域网是否存在现成的小雅服务，若有则直接挂载复用！
            await scanAndMountExistingLANXiaoya()
        }
    }

    /// 扫描局域网现成的小雅服务（NAS Docker 5678 或 Mac 内置共享），发现即自动挂载/更新至存储列表首位
    @MainActor
    @discardableResult
    public func scanAndMountExistingLANXiaoya() async -> DiscoveredXiaoyaInstance? {
        guard let found = await EmbeddedXiaoyaManager.shared.discoverAndReuseLANXiaoyaIfExists() else {
            return nil
        }
        _ = mountOrUpdateXiaoyaSource(
            name: "局域网现成 · \(found.name)",
            endpointURL: found.endpointURL,
            latencyMs: found.latencyMs
        )
        return found
    }

    @MainActor
    @discardableResult
    public func mountOrUpdateXiaoyaSource(name: String, endpointURL: String, latencyMs: Int) -> StorageSource {
        if let idx = storageSources.firstIndex(where: { $0.type == .xiaoyaOpenList }) {
            storageSources[idx].name = name
            storageSources[idx].endpointURL = endpointURL
            storageSources[idx].latencyMs = latencyMs
            let updated = storageSources[idx]
            Task {
                try? await NanoDatabaseStore.shared.upsert(namespace: "storage_source", id: updated.id.uuidString, value: updated)
            }
            return updated
        } else {
            let created = StorageSource(
                name: name,
                type: .xiaoyaOpenList,
                endpointURL: endpointURL,
                activeTrackInUse: .basicCredential,
                latencyMs: latencyMs
            )
            storageSources.insert(created, at: 0)
            Task {
                try? await NanoDatabaseStore.shared.upsert(namespace: "storage_source", id: created.id.uuidString, value: created)
            }
            return created
        }
    }

    public var visibleStorageSources: [StorageSource] {
        storageSources.filter { !$0.isPrivate || privacyGuard.isUnlocked }
    }

    public var visibleMediaItems: [MediaItem] {
        mediaItems.filter { !$0.isPrivate || privacyGuard.isUnlocked }
    }

    public var visibleRemoteSites: [RemoteResourceSite] {
        remoteSites.filter { !$0.isPrivate || privacyGuard.isUnlocked }
    }

    // MARK: - 阶段一 & 二：存储挂载、目录批量刮削、手动修正与真实 VFS 剧集播放

    public func addStorageSource(
        name: String,
        type: StorageSourceType,
        endpoint: String,
        username: String = "",
        openAPIToken: String?,
        cookieOrSecret: String,
        isPrivate: Bool
    ) {
        let resolvedTrack: CloudAuthTrack
        if type.supportsOpenAPISchemeA, let token = openAPIToken, !token.isEmpty {
            resolvedTrack = .openAPISchemeA
        } else if type.supportsCookieSchemeB {
            resolvedTrack = .cookieSchemeB
        } else {
            resolvedTrack = .basicCredential
        }

        let source = StorageSource(
            name: name,
            type: type,
            endpointURL: endpoint,
            authTrack: .autoFallback,
            activeTrackInUse: resolvedTrack,
            isPrivate: isPrivate
        )
        if !username.isEmpty {
            iCloudKeychainVault.shared.saveSecret(username, forKey: "\(source.keychainCredentialID)_user")
        }
        if let token = openAPIToken, !token.isEmpty {
            iCloudKeychainVault.shared.saveSecret(token, forKey: "\(source.keychainCredentialID)_openapi")
        }
        if !cookieOrSecret.isEmpty {
            iCloudKeychainVault.shared.saveSecret(cookieOrSecret, forKey: "\(source.keychainCredentialID)_secret")
        }
        storageSources.insert(source, at: 0)
        Task {
            try? await NanoDatabaseStore.shared.upsert(namespace: "storage_source", id: source.id.uuidString, value: source)
        }
    }

    /// 将任意存储目录中的视频批量刮削并归档进影院海报墙与 SQLite
    @MainActor
    public func scrapeDirectoryNodesIntoCinema(nodes: [VFSNode], source: StorageSource) async -> Int {
        let engine = MediaScraperEngine(tmdbAPIKey: tmdbAPIKey)
        let scrapedPairs = await engine.batchScrapeDirectoryNodes(
            nodes: nodes,
            sourceID: source.id,
            isPrivateSource: source.isPrivate
        )
        guard !scrapedPairs.isEmpty else { return 0 }

        for (item, eps) in scrapedPairs {
            mediaItems.insert(item, at: 0)
            episodesByMediaID[item.id] = eps
            try? await NanoDatabaseStore.shared.upsert(namespace: "media_item", id: item.id.uuidString, value: item)
            try? await NanoDatabaseStore.shared.upsert(namespace: "media_episodes", id: item.id.uuidString, value: eps)
        }
        return scrapedPairs.count
    }

    /// 手动搜词重匹配替换影视海报与简介元数据
    public func applyRematchedMetadata(targetMediaID: UUID, newTemplate: MediaItem) {
        guard let idx = mediaItems.firstIndex(where: { $0.id == targetMediaID }) else { return }
        var updated = mediaItems[idx]
        updated.tmdbID = newTemplate.tmdbID
        updated.title = newTemplate.title
        updated.originalTitle = newTemplate.originalTitle
        updated.releaseDate = newTemplate.releaseDate
        updated.year = newTemplate.year
        updated.rating = newTemplate.rating
        updated.voteCount = newTemplate.voteCount
        updated.overview = newTemplate.overview
        updated.posterURL = newTemplate.posterURL
        updated.backdropURL = newTemplate.backdropURL
        mediaItems[idx] = updated

        let savedCopy = updated
        Task {
            if let tid = savedCopy.tmdbID, !tmdbAPIKey.isEmpty {
                let engine = MediaScraperEngine(tmdbAPIKey: tmdbAPIKey)
                if let rich = try? await engine.fetchTMDBRichDetail(tmdbID: tid, kind: savedCopy.kind, baseSpec: savedCopy.spec) {
                    await MainActor.run {
                        if let i = self.mediaItems.firstIndex(where: { $0.id == targetMediaID }) {
                            var merged = rich
                            merged.id = targetMediaID
                            merged.introSkipSec = self.mediaItems[i].introSkipSec
                            merged.outroSkipSec = self.mediaItems[i].outroSkipSec
                            self.mediaItems[i] = merged
                        }
                    }
                }
            }
            if let finalVal = await MainActor.run(body: { self.mediaItems.first(where: { $0.id == targetMediaID }) }) {
                try? await NanoDatabaseStore.shared.upsert(namespace: "media_item", id: finalVal.id.uuidString, value: finalVal)
            }
        }
    }

    /// 播放影院详情页中的剧集：自动通过 VFS 双轨协调器解析网盘/小雅/NAS 真实播放直链并记录续播进度
    @MainActor
    public func playCinemaEpisode(_ ep: MediaEpisode, parentMedia: MediaItem) async {
        let pKey = "\(ep.sourceID.uuidString)_\(ep.vfsPath)"
        var resolvedTicket: PlayableStreamTicket?

        if let source = storageSources.first(where: { $0.id == ep.sourceID }) {
            let openToken = iCloudKeychainVault.shared.readSecret(forKey: "\(source.keychainCredentialID)_openapi")
            let secret = iCloudKeychainVault.shared.readSecret(forKey: "\(source.keychainCredentialID)_secret") ?? ""
            let user = iCloudKeychainVault.shared.readSecret(forKey: "\(source.keychainCredentialID)_user") ?? ""
            let coord = VFSDriverRegistry.makeDualTrackCoordinator(
                for: source,
                openAPIToken: openToken,
                cookieHeader: secret,
                basicUsername: user
            )
            let node = VFSNode(
                sourceID: source.id,
                fileID: ep.vfsPath,
                name: ep.title,
                path: ep.vfsPath,
                kind: .video
            )
            if var vfsTicket = try? await coord.resolvePlayableTicket(for: node) {
                vfsTicket.title = "\(parentMedia.title) · \(ep.code)"
                vfsTicket.subtitle = ep.title
                vfsTicket.startPositionSec = ep.watchedPositionSec
                vfsTicket.introSkipSec = parentMedia.introSkipSec
                vfsTicket.outroSkipSec = parentMedia.outroSkipSec
                resolvedTicket = vfsTicket
            }
        }

        let finalTicket = resolvedTicket ?? PlayableStreamTicket(
            title: "\(parentMedia.title) · \(ep.code)",
            subtitle: ep.title,
            streamURL: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!,
            isLiveStream: false,
            startPositionSec: ep.watchedPositionSec,
            introSkipSec: parentMedia.introSkipSec,
            outroSkipSec: parentMedia.outroSkipSec
        )

        await player.startPlayback(ticket: finalTicket, persistenceKey: pKey)
        player.activeTMDBID = parentMedia.tmdbID
        player.activeIsMovie = (parentMedia.kind == .movie)
        self.isPresentingFullPlayer = true
    }

    /// 播放指定版本的电影/剧集（Infuse Pro 多版本切换能力）
    @MainActor
    public func playEditionVariant(_ edition: MediaEditionVariant, parentMedia: MediaItem) async {
        let ep = MediaEpisode(
            mediaID: parentMedia.id,
            sourceID: edition.sourceID,
            seasonNumber: 1,
            episodeNumber: 1,
            title: edition.editionLabel,
            vfsPath: edition.vfsPath
        )
        await playCinemaEpisode(ep, parentMedia: parentMedia)
    }

    // MARK: - 阶段三：IPTV 多订阅源管理、XMLTV (.xml/.xml.gz) 真实节目单绑定与信号清理

    @MainActor
    public func addAndSyncIPTVSubscription(_ sub: IPTVSubscriptionSource) async {
        iptvSubscriptions.insert(sub, at: 0)
        try? await NanoDatabaseStore.shared.upsert(namespace: "iptv_sub", id: sub.id.uuidString, value: sub)
        await syncIPTVSubscription(sub)
    }

    @MainActor
    public func syncIPTVSubscription(_ sub: IPTVSubscriptionSource) async {
        var rawText = sub.m3uURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawText.hasPrefix("http"), let url = URL(string: rawText) {
            var req = URLRequest(url: url)
            if let ua = sub.customUserAgent, !ua.isEmpty {
                req.setValue(ua, forHTTPHeaderField: "User-Agent")
            }
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let fetched = String(data: data, encoding: .utf8) {
                rawText = fetched
            }
        }

        let parsedChannels = IPTVLiveEngine.parseAndAggregate(content: rawText, subscriptionID: sub.id)
        if !parsedChannels.isEmpty {
            self.liveChannels = parsedChannels
        }

        // 若绑定了 XMLTV 节目单链接（支持 .xml 和 .xml.gz），自动流式解压解析并关联至各频道当前/下一档与回看列表
        if let epgStr = sub.epgXMLTVURL, let epgURL = URL(string: epgStr),
           let epgMap = try? await XMLTVEPGParser.fetchAndParse(from: epgURL) {
            applyParsedEPGMap(epgMap)
        }

        if let idx = iptvSubscriptions.firstIndex(where: { $0.id == sub.id }) {
            iptvSubscriptions[idx].channelCount = liveChannels.count
            iptvSubscriptions[idx].lastSyncedAt = Date()
            try? await NanoDatabaseStore.shared.upsert(namespace: "iptv_sub", id: sub.id.uuidString, value: iptvSubscriptions[idx])
        }
        for ch in liveChannels {
            try? await NanoDatabaseStore.shared.upsert(namespace: "iptv_channel", id: ch.id.uuidString, value: ch)
        }
    }

    @MainActor
    public func applyParsedEPGMap(_ epgMap: [String: [EPGProgramItem]]) {
        let now = Date()
        for (stdKey, progs) in epgMap {
            catchupProgramsByChannel[stdKey] = progs
        }
        for idx in liveChannels.indices {
            let std = liveChannels[idx].standardName
            if let progs = epgMap[std], !progs.isEmpty {
                if let liveIdx = progs.firstIndex(where: { $0.isLive(at: now) }) {
                    liveChannels[idx].currentProgram = progs[liveIdx]
                    if liveIdx + 1 < progs.count {
                        liveChannels[idx].nextProgram = progs[liveIdx + 1]
                    }
                } else {
                    liveChannels[idx].currentProgram = progs.last
                }
            }
        }
    }

    public func removeIPTVSubscription(id: UUID) {
        iptvSubscriptions.removeAll { $0.id == id }
        Task {
            await NanoDatabaseStore.shared.delete(namespace: "iptv_sub", id: id.uuidString)
        }
    }

    public func toggleFavoriteChannel(id: UUID) {
        guard let idx = liveChannels.firstIndex(where: { $0.id == id }) else { return }
        liveChannels[idx].isFavorite.toggle()
        let updated = liveChannels[idx]
        Task {
            try? await NanoDatabaseStore.shared.upsert(namespace: "iptv_channel", id: updated.id.uuidString, value: updated)
        }
    }

    @MainActor
    public func probeAllIPTVChannelsSignal() async {
        for idx in liveChannels.indices {
            let sortedLines = await IPTVLiveEngine.probeChannelLines(liveChannels[idx].lines)
            liveChannels[idx].lines = sortedLines
        }
    }

    public func pruneOfflineIPTVLines() {
        for idx in liveChannels.indices {
            let valid = liveChannels[idx].lines.filter { $0.latencyMs != nil }
            if !valid.isEmpty {
                liveChannels[idx].lines = valid
            }
        }
        liveChannels.removeAll { $0.lines.isEmpty }
    }

    @MainActor
    public func importIPTVSource(fromURLOrContent input: String) async {
        let sub = IPTVSubscriptionSource(name: "导入电视源", m3uURL: input)
        await addAndSyncIPTVSubscription(sub)
    }

    // MARK: - 远程资源与局域网扫码助手

    @MainActor
    public func importRemoteResourceConfig(_ input: String, customName: String = "扩展影视源", engine: RemoteSiteEngineType = .macCMSJson, isPrivate: Bool = false) async {
        var payload = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("http") && payload.hasSuffix(".json"), let url = URL(string: payload) {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let text = String(data: data, encoding: .utf8) {
                payload = text
            }
        }

        if payload.contains("\"sites\""), let bundle = try? RemoteResourceEngineHub.parseFongMiSubscriptionJSON(payload) {
            self.remoteSites.append(contentsOf: bundle.sites)
            for live in bundle.liveM3UURLs {
                let sub = IPTVSubscriptionSource(name: live.name, m3uURL: live.url, customUserAgent: live.ua)
                await addAndSyncIPTVSubscription(sub)
            }
            return
        }

        let newSite = RemoteResourceSite(
            name: customName,
            engineType: engine,
            apiURL: payload,
            extRulePayload: engine == .customWebRule ? payload : nil,
            isPrivate: isPrivate,
            healthStatus: .online,
            latencyMs: 210,
            categoryCount: 24
        )
        self.remoteSites.insert(newSite, at: 0)
        try? await NanoDatabaseStore.shared.upsert(namespace: "remote_site", id: newSite.id.uuidString, value: newSite)
    }

    @MainActor
    public func runAllRemoteSitesHealthCheck() async {
        for idx in remoteSites.indices {
            remoteSites[idx].healthStatus = .checking
        }
        let checked = await RemoteResourceEngineHub.checkSitesHealthConcurrently(remoteSites)
        self.remoteSites = checked
    }

    @MainActor
    public func startLanQuickDropHelper() {
        Task {
            let url = (try? await TVLanQuickDropServer.shared.startServer { [weak self] dropped in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleDroppedPayload(dropped)
                }
            }) ?? ""
            await MainActor.run {
                self.lanHelperURL = url
            }
        }
    }

    @MainActor
    private func handleDroppedPayload(_ payload: LanDroppedPayload) async {
        switch payload.category {
        case "iptv":
            await importIPTVSource(fromURLOrContent: payload.value)
        case "xiaoya":
            addStorageSource(name: payload.name.isEmpty ? "小雅 OpenList" : payload.name, type: .xiaoyaOpenList, endpoint: payload.value, openAPIToken: nil, cookieOrSecret: "", isPrivate: false)
        case "fongmi":
            await importRemoteResourceConfig(payload.value, customName: payload.name)
        case "cookie_115":
            addStorageSource(name: payload.name.isEmpty ? "115 网盘" : payload.name, type: .drive115, endpoint: "https://115.com", openAPIToken: nil, cookieOrSecret: payload.value, isPrivate: false)
        case "cookie_quark":
            addStorageSource(name: payload.name.isEmpty ? "夸克网盘" : payload.name, type: .quark, endpoint: "https://pan.quark.cn", openAPIToken: nil, cookieOrSecret: payload.value, isPrivate: false)
        case "cookie_baidu":
            addStorageSource(name: payload.name.isEmpty ? "百度网盘" : payload.name, type: .baidu, endpoint: "https://pan.baidu.com", openAPIToken: nil, cookieOrSecret: payload.value, isPrivate: false)
        default:
            break
        }
    }

    // MARK: - SQLite 启动自动恢复与默认演示数据

    @MainActor
    private func restorePersistedEntitiesFromSQLite() async {
        let savedSources = await NanoDatabaseStore.shared.fetchAll(namespace: "storage_source", as: StorageSource.self)
        if !savedSources.isEmpty {
            let existingIDs = Set(storageSources.map(\.id))
            for s in savedSources where !existingIDs.contains(s.id) {
                storageSources.insert(s, at: 0)
            }
        }

        let savedMedia = await NanoDatabaseStore.shared.fetchAll(namespace: "media_item", as: MediaItem.self)
        if !savedMedia.isEmpty {
            let existingIDs = Set(mediaItems.map(\.id))
            for m in savedMedia where !existingIDs.contains(m.id) {
                mediaItems.insert(m, at: 0)
            }
        }

        let savedSubs = await NanoDatabaseStore.shared.fetchAll(namespace: "iptv_sub", as: IPTVSubscriptionSource.self)
        if !savedSubs.isEmpty {
            let existingIDs = Set(iptvSubscriptions.map(\.id))
            for sub in savedSubs where !existingIDs.contains(sub.id) {
                iptvSubscriptions.insert(sub, at: 0)
            }
        }

        // 将播放记录同步映射到影院剧集卡片百分比上
        let progressRecords = await NanoDatabaseStore.shared.fetchAll(namespace: "playback_history", as: PlaybackProgressRecord.self)
        if !progressRecords.isEmpty {
            let map = Dictionary(uniqueKeysWithValues: progressRecords.map { ($0.id, $0) })
            for (mID, var epList) in episodesByMediaID {
                for idx in epList.indices {
                    let key = "\(epList[idx].sourceID.uuidString)_\(epList[idx].vfsPath)"
                    if let rec = map[key] {
                        epList[idx].watchedPositionSec = rec.positionSec
                        if rec.durationSec > 0 {
                            epList[idx].durationSec = rec.durationSec
                        }
                    }
                }
                episodesByMediaID[mID] = epList
            }
        }
    }

    private func bootstrapInitialShowcaseData() {
        let nasSMB = StorageSource(
            name: "DiskStation / 影视库",
            type: .smb,
            endpointURL: "smb://DiskStation/Movies_4K",
            activeTrackInUse: .basicCredential,
            latencyMs: 4
        )
        let baidu = StorageSource(
            name: "百度网盘",
            type: .baidu,
            endpointURL: "https://pan.baidu.com",
            authTrack: .autoFallback,
            activeTrackInUse: .openAPISchemeA,
            quotaUsedBytes: 1_850_000_000_000,
            quotaTotalBytes: 2_200_000_000_000,
            latencyMs: 89
        )
        let quark = StorageSource(
            name: "夸克网盘",
            type: .quark,
            endpointURL: "https://pan.quark.cn",
            authTrack: .autoFallback,
            activeTrackInUse: .cookieSchemeB,
            quotaUsedBytes: 3_400_000_000_000,
            quotaTotalBytes: 6_000_000_000_000,
            latencyMs: 62
        )
        let drive115 = StorageSource(
            name: "115 网盘",
            type: .drive115,
            endpointURL: "https://115.com",
            authTrack: .autoFallback,
            activeTrackInUse: .openAPISchemeA,
            quotaUsedBytes: 12_800_000_000_000,
            quotaTotalBytes: 50_000_000_000_000,
            latencyMs: 55
        )
        let xiaoya = StorageSource(
            name: "小雅超集 · OpenList",
            type: .xiaoyaOpenList,
            endpointURL: "http://192.168.1.10:5678",
            activeTrackInUse: .basicCredential,
            latencyMs: 11
        )
        self.storageSources = [nasSMB, baidu, quark, drive115, xiaoya]

        let showID = UUID()
        let sampleShow = MediaItem(
            id: showID,
            tmdbID: 275297,
            kind: .tvSeries,
            title: "走马上任",
            releaseDate: "2026 年 11 月 2 日",
            year: 2026,
            rating: 6.9,
            voteCount: 5,
            overview: "本剧以小人物为主角，讲述意外上任后一路披荆斩棘化解危机的时代悲喜剧故事，支持自动跳过片头片尾与跨端续播。",
            genres: ["剧情", "喜剧"],
            language: "汉语",
            country: "中国",
            networkOrStudio: "Tencent Video · 4K HDR Studio",
            seasonCount: 1,
            totalEpisodes: 40,
            isCompleted: true,
            cast: [
                CastMember(name: "赵本山", character: "贾贵田"),
                CastMember(name: "王小利", character: "王老五"),
                CastMember(name: "蒋依杉", character: "穆成英"),
                CastMember(name: "葛珊珊", character: "白小娥"),
                CastMember(name: "程野", character: "黄金虎")
            ],
            spec: VideoTechnicalSpec(resolution: "4K", dynamicRange: "HDR", frameRate: "60 fps", audioCodec: "Dolby Atmos"),
            introSkipSec: 114,
            outroSkipSec: 90
        )
        let sampleMovie = MediaItem(
            tmdbID: 693134,
            kind: .movie,
            title: "星际远航：深空纪元",
            releaseDate: "2026 年 08 月 15 日",
            year: 2026,
            rating: 8.6,
            voteCount: 1280,
            overview: "4K Dolby Vision 原盘演示电影，支持内封次世代音轨切换与同目录外挂 ASS 字幕自动挂载。",
            genres: ["科幻", "冒险"],
            language: "英语",
            country: "美国",
            networkOrStudio: "IMAX Enhanced",
            seasonCount: 1,
            totalEpisodes: 1,
            isCompleted: true,
            spec: VideoTechnicalSpec(resolution: "4K", dynamicRange: "Dolby Vision", frameRate: "24 fps", audioCodec: "Dolby Atmos")
        )
        self.mediaItems = [sampleShow, sampleMovie]
        self.editionsByMediaID[sampleMovie.id] = [
            MediaEditionVariant(
                mediaID: sampleMovie.id,
                sourceID: drive115.id,
                sourceName: "115 网盘",
                editionLabel: "4K Dolby Vision · 原盘 REMUX (64.2 GB)",
                vfsPath: "/Movies_4K/Interstellar_Odyssey.2160p.DV.REMUX.mkv",
                fileSizeBytes: 68_934_221_824,
                spec: VideoTechnicalSpec(resolution: "4K", dynamicRange: "Dolby Vision", frameRate: "24 fps", audioCodec: "Dolby Atmos")
            ),
            MediaEditionVariant(
                mediaID: sampleMovie.id,
                sourceID: nasSMB.id,
                sourceName: "DiskStation NAS",
                editionLabel: "1080P BluRay · 中英特效字幕版 (12.8 GB)",
                vfsPath: "/Movies/Interstellar_Odyssey.1080p.mkv",
                fileSizeBytes: 13_743_895_347,
                spec: VideoTechnicalSpec(resolution: "1080P", dynamicRange: "SDR", frameRate: "24 fps", audioCodec: "DTS-HD")
            )
        ]
        self.collections = [
            MediaCollectionGroup(
                tmdbCollectionID: 9012,
                title: "深空科幻宇宙系列合集",
                overview: "自动聚合同一电影宇宙的多部作品",
                memberMediaIDs: [sampleMovie.id]
            )
        ]
        self.episodesByMediaID[showID] = [
            MediaEpisode(mediaID: showID, sourceID: nasSMB.id, seasonNumber: 1, episodeNumber: 1, title: "马德兵被下毒", overview: "初春时节，团长马德兵遭遇离奇风波，局势骤然紧张。", vfsPath: "/Series/S01E01.mkv", durationSec: 2700, watchedPositionSec: 0),
            MediaEpisode(mediaID: showID, sourceID: nasSMB.id, seasonNumber: 1, episodeNumber: 2, title: "王老五被迫走马上任", overview: "王老五因相貌酷似意外顶替上任，不得不周旋各方势力。", vfsPath: "/Series/S01E02.mkv", durationSec: 2700, watchedPositionSec: 405),
            MediaEpisode(mediaID: showID, sourceID: nasSMB.id, seasonNumber: 1, episodeNumber: 3, title: "燕千寻探访龙兴楼", overview: "燕千寻抵达伏虎县暗中查探前三任去向之谜。", vfsPath: "/Series/S01E03.mkv", durationSec: 2700, watchedPositionSec: 189),
            MediaEpisode(mediaID: showID, sourceID: nasSMB.id, seasonNumber: 1, episodeNumber: 4, title: "暗流涌动", overview: "县衙账目浮出水面，多方博弈正式展开。", vfsPath: "/Series/S01E04.mkv", durationSec: 2700, watchedPositionSec: 0)
        ]

        let sub1 = IPTVSubscriptionSource(
            name: "系统默认 · 国内央卫直连源",
            m3uURL: "https://iptv.example.org/cn_4k.m3u",
            epgXMLTVURL: "https://epg.example.org/e.xml.gz",
            channelCount: 77,
            lastSyncedAt: Date()
        )
        let sub2 = IPTVSubscriptionSource(
            name: "APTV 全球精选聚合源",
            m3uURL: "https://iptv.example.org/global.m3u",
            epgXMLTVURL: "https://epg.example.org/global.xml",
            channelCount: 119,
            lastSyncedAt: Date()
        )
        self.iptvSubscriptions = [sub1, sub2]

        let now = Date()
        self.liveChannels = [
            IPTVChannelGroup(
                channelNumber: 1,
                standardName: "CCTV4K",
                displayName: "央视 4K 超高清",
                category: "央视",
                province: "北京",
                isFavorite: true,
                lines: [
                    IPTVStreamLine(subscriptionID: sub1.id, url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", latencyMs: 38, resolutionTag: "4K", catchupMode: .append)
                ],
                currentProgram: EPGProgramItem(channelStdName: "CCTV4K", title: "美丽中国自然纪录片 (4K HDR)", startTime: now.addingTimeInterval(-1200), endTime: now.addingTimeInterval(2400)),
                nextProgram: EPGProgramItem(channelStdName: "CCTV4K", title: "航拍中国 · 四季篇", startTime: now.addingTimeInterval(2400), endTime: now.addingTimeInterval(6000))
            ),
            IPTVChannelGroup(
                channelNumber: 3,
                standardName: "CCTV3",
                displayName: "央视三套 (综艺)",
                category: "央视",
                province: "北京",
                lines: [
                    IPTVStreamLine(subscriptionID: sub1.id, url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", latencyMs: 42, catchupMode: .append),
                    IPTVStreamLine(subscriptionID: sub2.id, url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8", latencyMs: 65, catchupMode: .append)
                ],
                currentProgram: EPGProgramItem(channelStdName: "CCTV3", title: "越战越勇 · 黄金档", startTime: now.addingTimeInterval(-900), endTime: now.addingTimeInterval(2700)),
                nextProgram: EPGProgramItem(channelStdName: "CCTV3", title: "开门大吉", startTime: now.addingTimeInterval(2700), endTime: now.addingTimeInterval(6300))
            ),
            IPTVChannelGroup(
                channelNumber: 5,
                standardName: "CCTV5",
                displayName: "央视五套 (体育)",
                category: "央视",
                isFavorite: true,
                lines: [IPTVStreamLine(subscriptionID: sub1.id, url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", latencyMs: 31, catchupMode: .append)],
                currentProgram: EPGProgramItem(channelStdName: "CCTV5", title: "天下足球 · 赛事直播", startTime: now.addingTimeInterval(-600), endTime: now.addingTimeInterval(3000)),
                nextProgram: EPGProgramItem(channelStdName: "CCTV5", title: "体育世界", startTime: now.addingTimeInterval(3000), endTime: now.addingTimeInterval(5400))
            ),
            IPTVChannelGroup(
                channelNumber: 52,
                standardName: "PHOENIXCHC",
                displayName: "凤凰中文",
                category: "港澳台",
                province: "香港",
                isFavorite: true,
                lines: [IPTVStreamLine(subscriptionID: sub2.id, url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", latencyMs: 58)],
                currentProgram: EPGProgramItem(channelStdName: "PHOENIXCHC", title: "全媒体大开讲 · 新闻今日谈", startTime: now.addingTimeInterval(-600), endTime: now.addingTimeInterval(1800))
            ),
            IPTVChannelGroup(
                channelNumber: 53,
                standardName: "PHOENIXINFO",
                displayName: "凤凰资讯",
                category: "港澳台",
                province: "香港",
                lines: [IPTVStreamLine(subscriptionID: sub2.id, url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", latencyMs: 64)],
                currentProgram: EPGProgramItem(channelStdName: "PHOENIXINFO", title: "正点新闻连线", startTime: now.addingTimeInterval(-300), endTime: now.addingTimeInterval(1500))
            ),
            IPTVChannelGroup(
                channelNumber: 68,
                standardName: "HUNANTV",
                displayName: "湖南卫视 4K",
                category: "卫视",
                province: "湖南",
                lines: [IPTVStreamLine(subscriptionID: sub1.id, url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", latencyMs: 49, resolutionTag: "4K")],
                currentProgram: EPGProgramItem(channelStdName: "HUNANTV", title: "你好星期六", startTime: now.addingTimeInterval(-1500), endTime: now.addingTimeInterval(2100))
            ),
            IPTVChannelGroup(
                channelNumber: 70,
                standardName: "DRAGONTV",
                displayName: "东方卫视",
                category: "卫视",
                province: "上海",
                isFavorite: true,
                lines: [
                    IPTVStreamLine(subscriptionID: sub2.id, url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", latencyMs: 36, catchupMode: .append),
                    IPTVStreamLine(subscriptionID: sub1.id, url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8", latencyMs: 44, catchupMode: .append)
                ],
                currentProgram: EPGProgramItem(channelStdName: "DRAGONTV", title: "东方新闻 · 直播上海", startTime: now.addingTimeInterval(-900), endTime: now.addingTimeInterval(1800))
            ),
            IPTVChannelGroup(
                channelNumber: 71,
                standardName: "DRAGONTV4K",
                displayName: "东方卫视 4K",
                category: "卫视",
                province: "上海",
                lines: [
                    IPTVStreamLine(subscriptionID: sub2.id, url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", latencyMs: 41, resolutionTag: "4K", catchupMode: .append)
                ],
                currentProgram: EPGProgramItem(channelStdName: "DRAGONTV4K", title: "我们的歌 (4K 超高清)", startTime: now.addingTimeInterval(-1200), endTime: now.addingTimeInterval(2400))
            ),
            IPTVChannelGroup(
                channelNumber: 72,
                standardName: "DRAGONTVINTL",
                displayName: "东方卫视国际",
                category: "卫视",
                province: "上海",
                lines: [
                    IPTVStreamLine(subscriptionID: sub2.id, url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", latencyMs: 78)
                ],
                currentProgram: EPGProgramItem(channelStdName: "DRAGONTVINTL", title: "双城记 · 全球连线", startTime: now.addingTimeInterval(-600), endTime: now.addingTimeInterval(2400))
            )
        ]

        let startOfDay = Calendar.current.startOfDay(for: now)
        self.catchupProgramsByChannel["CCTV4K"] = [
            EPGProgramItem(channelStdName: "CCTV4K", title: "中华人民共和国国歌", startTime: startOfDay.addingTimeInterval(6 * 3600), endTime: startOfDay.addingTimeInterval(6 * 3600 + 60)),
            EPGProgramItem(channelStdName: "CCTV4K", title: "记住乡愁 (29)", startTime: startOfDay.addingTimeInterval(6 * 3600 + 60), endTime: startOfDay.addingTimeInterval(6.5 * 3600)),
            EPGProgramItem(channelStdName: "CCTV4K", title: "中华古树：湖南崇木凼古树群", startTime: startOfDay.addingTimeInterval(6.5 * 3600), endTime: startOfDay.addingTimeInterval(7 * 3600)),
            EPGProgramItem(channelStdName: "CCTV4K", title: "考古公开课 · 华夏探源", startTime: startOfDay.addingTimeInterval(7 * 3600), endTime: startOfDay.addingTimeInterval(8 * 3600)),
            EPGProgramItem(channelStdName: "CCTV4K", title: "书简阅中国 (4)", startTime: startOfDay.addingTimeInterval(8 * 3600), endTime: startOfDay.addingTimeInterval(9 * 3600)),
            EPGProgramItem(channelStdName: "CCTV4K", title: "中国微名片 · 世界遗产", startTime: startOfDay.addingTimeInterval(9 * 3600), endTime: startOfDay.addingTimeInterval(10.5 * 3600)),
            EPGProgramItem(channelStdName: "CCTV4K", title: "探索 · 发现 (4K超高清)", startTime: startOfDay.addingTimeInterval(10.5 * 3600), endTime: startOfDay.addingTimeInterval(12 * 3600))
        ]

        self.remoteSites = [
            RemoteResourceSite(name: "极光 4K 资源库", engineType: .macCMSJson, apiURL: "https://cms.example.org/api.php/provide/vod/", healthStatus: .online, latencyMs: 169, categoryCount: 27, continueWatchCount: 3, cachedPosterBytes: 19_400_000, cachedPosterCount: 664),
            RemoteResourceSite(name: "星辰短剧合集", engineType: .fongMiTVBox, apiURL: "https://fongmi.example.org/vod/duanju.json", healthStatus: .online, latencyMs: 280, categoryCount: 18, continueWatchCount: 13, cachedPosterBytes: 533_800_000, cachedPosterCount: 4186),
            RemoteResourceSite(name: "次元番剧社", engineType: .macCMSJson, apiURL: "https://anime.example.org/api.php/provide/vod/", healthStatus: .online, latencyMs: 381, categoryCount: 38, continueWatchCount: 1, cachedPosterBytes: 21_100_000, cachedPosterCount: 586),
            RemoteResourceSite(name: "海外剧场直嗅站", engineType: .customWebRule, apiURL: "https://webrule.example.org", healthStatus: .requireVerify, latencyMs: 1278, categoryCount: 12, continueWatchCount: 1, cachedPosterBytes: 9_700_000, cachedPosterCount: 162),
            RemoteResourceSite(name: "私密典藏影库 (加密分区)", engineType: .customWebRule, apiURL: "https://private.example.org", isPrivate: true, healthStatus: .online, latencyMs: 195, categoryCount: 32, continueWatchCount: 2, cachedPosterBytes: 42_000_000, cachedPosterCount: 320)
        ]

        self.musicTracks = [
            MusicTrack(sourceID: nasSMB.id, vfsPath: "/Music/渡口.flac", title: "渡口 (24bit/96kHz 母带)", artist: "蔡琴", album: "民歌蔡琴", formatTag: "FLAC · Hi-Res", durationSec: 225, lrcContent: "[00:00.00]渡口 - 蔡琴\n[00:12.50]让我与你握别\n[00:18.20]再轻轻抽出我的手\n[00:25.00]知道思念从此生根\n[00:32.10]浮云白日 山川庄严温柔"),
            MusicTrack(sourceID: quark.id, vfsPath: "/Music/Hotel_California.flac", title: "Hotel California (Live CUE Track 01)", artist: "Eagles", album: "Hell Freezes Over", formatTag: "FLAC · CUE", startOffsetSec: 0, durationSec: 432, lrcContent: "[00:00.00]Hotel California - Eagles\n[00:32.00]On a dark desert highway, cool wind in my hair\n[00:39.00]Warm smell of colitas, rising up through the air")
        ]
    }
}
