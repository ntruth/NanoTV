import AppKit
import Foundation
import LumaContentCore

/// 单个频道的实时画面探测状态。
enum TVProbeState: String {
    case idle
    case probing
    case available
    case unavailable
}

/// 追剧 / 追赛订阅：按归一化节目名记住「这一类节目」，跨频道、跨天都算命中。
struct TVSubscription: Codable, Identifiable, Hashable {
    var id: String { key }
    let key: String
    let title: String
    let createdAt: Date
}

/// 网络电视：默认开启但一个源都不接入；由用户粘贴 M3U 地址或导入文件自行接入。
/// 源、顺序、频道缓存与开关都写进当前图库的 SQLite（`resources/tv/Television.sqlite`）；
/// 连接检测串行排队，并上报到统一任务中心。
@MainActor
final class IPTVBrowserModel: ObservableObject {
    private enum Keys {
        static let enabled = "luma.tv.enabled"
        static let playlists = "luma.tv.playlists"
        static let refreshedAt = "luma.tv.refreshedAt"
        static let hubTab = "luma.tv.hubTab.v1"
        static let favorites = "luma.tv.favorites"
        static let recent = "luma.tv.recent"
        static let preferredLines = "luma.tv.preferredLines"
        static let probeHistory = "luma.tv.probeHistory"
        static let reminders = "luma.tv.reminders"
        static let subscriptions = "luma.tv.subscriptions"
        static let sportFollows = "luma.tv.sportFollows"
        static let recordings = "luma.tv.recordings"
    }

    /// 总开关：关闭后侧边栏仍保留入口，但不再拉流，页面显示关闭提示。
    @Published private(set) var enabled: Bool
    @Published private(set) var playlists: [TVPlaylist]
    @Published private(set) var channels: [TVChannel] = [] {
        didSet {
            channelRevision &+= 1
            aggregatedCache = nil
            focusedChannelsCache = nil
            visibleCacheKey = ""
            channelNumberIndex.removeAll()
            channelNumberIndexKey = ""
            channelsWithProgramsCache.removeAll()
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isChecking = false
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var failedPlaylistIDs: Set<UUID> = []

    @Published var hubTab: TVHubTab
    /// 节目回看选中的日期偏移（-3…3，0 = 今天）。放在模型里，
    /// 顶部工具栏的分页胶囊可以同步显示「N 个频道有节目单 · 昨天」。
    @Published var guideDayOffset = 0
    /// 当前焦点源：写回 SQLite，下次启动仍停在上次看的源。
    @Published var focusedPlaylistID: UUID? {
        didSet { database.setSetting("focusedPlaylistID", focusedPlaylistID?.uuidString) }
    }
    @Published var error: String?
    @Published var sourceError: SourceError?
    @Published var showWizard = false

    @Published var searchText = ""
    @Published var regionFilter: TVRegion?
    @Published var groupFilter: String?
    /// 按省份聚合时的省份筛选；与 `groupFilter` 互斥，切分组方式时清空。
    @Published var provinceFilter: String?
    /// 按国家 / 地区聚合时的国家筛选；与另外两种分组方式互斥。
    @Published var countryFilter: String?
    /// 频道墙分组方式，写进 SQLite，下次进入沿用。
    @Published var groupingMode: TVGroupingMode = .category {
        didSet { database.setSetting("groupingMode", groupingMode.rawValue) }
    }

    /// 每个频道的实时画面探测状态：进入频道页后按可见卡片逐个抓帧。
    @Published private(set) var probeStates: [String: TVProbeState] = [:]
    /// 探测得到的截帧与媒体参数：信号页用这些数字回答「为什么卡 / 哪条线最稳」。
    @Published private(set) var probeReports: [String: TVProbeReport] = [:]
    /// 是否还有频道在排队 / 抓帧：信号页用来切换「探测全部 / 停止」。
    @Published private(set) var isProbingChannels = false
    /// 用户为频道锁定的默认线路：key 是频道 id，value 是完整流地址。
    @Published private(set) var preferredLines: [String: String]
    /// 24 小时探测采样：每个频道最近若干次成功 / 失败与延迟。
    @Published private(set) var probeHistory: [String: [TVProbePoint]]

    /// 收藏与最近观看：只存频道 id，随图库保存在 UserDefaults。
    @Published private(set) var favoriteIDs: Set<String>
    @Published private(set) var recentIDs: [String]
    /// 频道墙快捷筛选：nil 表示全部。
    @Published var quickFilter: TVQuickFilter?

    /// XMLTV 节目单：key 是归一化后的频道 id（去掉 @HD 等后缀）。
    @Published private(set) var epgPrograms: [String: [TVEPGProgram]] = [:]
    /// XMLTV display-name 归一化 -> 可能的 channel id 列表（多份 EPG 可能各用一套 id）。
    @Published private(set) var epgChannelNames: [String: [String]] = [:]
    @Published private(set) var isLoadingEPG = false
    @Published private(set) var epgError: String?
    @Published private(set) var epgUpdatedAt: Date?

    /// 统一任务中心：连接检测会登记为 `.connectivity` 任务，节目单更新会登记为 `.epg` 任务。
    var jobCenter: SourceJobCenter?
    var onJobChange: (() -> Void)?
    /// 任务结束后的归档回调：由 LibraryStore 接到 `archiveSourceJob`，写进任务记录。
    var onJobFinished: ((UUID) -> Void)?

    private let database = TVDatabase.shared
    private var loadTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var checkQueue: [UUID] = []
    private var channelCache: [UUID: [TVChannel]] = [:]
    private var hasLoaded = false
    private var probeTask: Task<Void, Never>?
    private var probeQueue: [TVChannel] = []
    private let probeConcurrency = 2
    private var epgTask: Task<Void, Never>?
    /// 当前这一轮节目单下载的任务 ID：任务条与任务记录据此显示进度。
    private var epgJobID: UUID?
    /// 启动 / 首次进入时从磁盘缓存「垫底」的任务：不联网。
    private var epgHydrateTask: Task<Void, Never>?
    private var isHydratingEPG = false
    /// 画面探测任务：登记到统一任务中心，左下角后台任务条能看到进度并可取消。
    private var probeJobID: UUID?
    private var probeJobTotal = 0
    private var probeJobCompleted = 0
    private var probeJobAvailable = 0
    private var probeJobUnavailable = 0
    /// 探测采样的落盘节流：整批探测可能每秒产生多批结果，
    /// 每批都 JSON 编码整份历史太贵，合并成一次写盘。
    private var probeHistoryFlushTask: Task<Void, Never>?
    private var probeHistoryDirty = false

    // MARK: - 派生数据缓存
    //
    // 节目单数据动辄上万条、频道上千个，而视图（时间轴 / 传送门 / 时间环）会在
    // 悬停、拖动时高频重算。这些缓存把「遍历 + 合并 + 排序」压到每次数据变化只做一次。
    /// `channels` 重建次数：频道派生缓存据此失效。
    private var channelRevision = 0
    private var aggregatedCache: [TVChannel]?
    private var focusedChannelsCache: (id: UUID?, revision: Int, list: [TVChannel])?
    /// 侧边栏每个源的分组：源数量 × 上千频道的分组结果按「频道 revision」缓存，
    /// 探测状态每变一次不再把所有源重新分组一遍。
    private var categoryGroupsCache: [UUID: (revision: Int, groups: [TVCategory])] = [:]
    private var visibleCacheKey = ""
    private var visibleCache: [TVChannel] = []
    private var channelNumberIndex: [String: Int] = [:]
    private var channelNumberIndexKey = ""
    /// EPG 数据版本：节目单刷新后清空按频道 / 按天的节目缓存。
    private var epgRevision = 0
    /// 频道 id -> 命中的 EPG 频道 id 列表。
    private var epgKeyCache: [String: [String]] = [:]
    /// 频道 id -> 合并后的节目。
    private var epgProgramCache: [String: [TVEPGProgram]] = [:]
    /// 节目 id -> 归一化后的「节目名 + 副标题」：搜索节目单时不再逐次折叠中文。
    private var epgSearchText: [String: String] = [:]
    /// `epgSearchText` 对应的 EPG 版本。
    private var epgSearchTextRevision = -1
    /// "频道 id#当天 0 点" -> 当天节目。
    private var epgDayCache: [String: [TVEPGProgram]] = [:]
    /// "可见频道签名#当天 0 点" -> 当天有节目的频道。
    private var channelsWithProgramsCache: [String: [TVChannel]] = [:]
    /// 台名前缀桶：按归一化台名前 2 个字符分组，前缀匹配只扫同桶的键。
    private var epgPrefixBuckets: [String: [(name: String, ids: [String])]] = [:]

    init() {
        let defaults = UserDefaults.standard
        // 总开关与分页是全局偏好，先按 UserDefaults 初始化；
        // 源列表要等 `LibraryPaths.configure()` 之后才能确定是哪个图库，
        // 由 LibraryStore 在配置完成后调用 `reloadForCurrentLibrary()` 载入。
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        // 电视源默认一个都不接入：源列表等 reloadForCurrentLibrary() 从图库库读取。
        playlists = []
        refreshedAt = defaults.object(forKey: Keys.refreshedAt) as? Date
        hubTab = TVHubTab.persisted(defaults.string(forKey: Keys.hubTab))
        focusedPlaylistID = nil
        // 收藏 / 最近 / 预约 / 订阅 / 线路 / 探测历史都属于「当前图库」，
        // 等 LibraryPaths.configure() 之后由 reloadForCurrentLibrary() 从库内 SQLite 读。
        favoriteIDs = []
        recentIDs = []
        preferredLines = [:]
        probeHistory = [:]
        reminderStarts = [:]
        subscriptions = []
        sportFollows = []
        recordings = []
    }

    deinit {
        recordingTimer?.invalidate()
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: key)
    }

    // MARK: - 图库级存储

    /// 读一个属于当前图库的键：新库优先读库内 SQLite，读不到时把旧版 UserDefaults 的值迁移进来。
    private func libraryRaw(_ key: String) -> String? {
        if let raw = database.setting(key) { return raw }
        guard let legacy = UserDefaults.standard.string(forKey: key) else { return nil }
        database.setSetting(key, legacy)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    /// 收藏、预约、订阅这类「内容数据」必须跟着图库走，不能出现切库后串数据。
    private func libraryDecoded<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let raw = libraryRaw(key),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func saveLibraryValue<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value),
              let raw = String(data: data, encoding: .utf8) else { return }
        database.setSetting(key, raw)
    }

    /// 从当前图库加载收藏 / 最近 / 预约 / 订阅 / 线路偏好 / 探测历史。
    private func loadLibraryScopedState() {
        favoriteIDs = Set(libraryDecoded([String].self, key: Keys.favorites) ?? [])
        recentIDs = libraryDecoded([String].self, key: Keys.recent) ?? []
        preferredLines = libraryDecoded([String: String].self, key: Keys.preferredLines) ?? [:]
        probeHistory = libraryDecoded([String: [TVProbePoint]].self, key: Keys.probeHistory) ?? [:]
        // 预约只保留还没开播的：过期的条目顺手清掉，按钮状态才准。
        let storedReminders = libraryDecoded([String: Date].self, key: Keys.reminders) ?? [:]
        reminderStarts = storedReminders.filter { $0.value > Date() }
        subscriptions = libraryDecoded([TVSubscription].self, key: Keys.subscriptions) ?? []
        sportFollows = libraryDecoded([TVSportFollow].self, key: Keys.sportFollows) ?? []
        // 上次退出时还在「录制中」的条目已经不可能继续：如实标成中断，避免一直转圈。
        let storedRecordings = libraryDecoded([TVRecording].self, key: Keys.recordings) ?? []
        recordings = storedRecordings.map { recording in
            guard recording.state == .recording else { return recording }
            var updated = recording
            updated.state = .cancelled
            updated.note = "应用退出，录制已中断"
            return updated
        }
    }

    // MARK: - 开关与入口

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        database.setSetting("enabled", value ? "1" : "0")
        UserDefaults.standard.set(value, forKey: Keys.enabled)
        if value {
            refreshIfNeeded()
        } else {
            cancelLoading()
            cancelChecks()
        }
    }

    func setHubTab(_ tab: TVHubTab) {
        guard hubTab != tab else { return }
        hubTab = tab
        // 收藏 / 最近只属于频道墙，切到节目回看时不要把筛选带过去。
        if tab == .guide {
            quickFilter = nil
        }
        database.setSetting("hubTab", tab.rawValue)
        UserDefaults.standard.set(tab.rawValue, forKey: Keys.hubTab)
    }

    /// nil 表示「全部频道」；点某个源时只显示该源的频道。
    func focusPlaylist(_ id: UUID?) {
        focusedPlaylistID = id
        groupFilter = nil
        provinceFilter = nil
        countryFilter = nil
        quickFilter = nil
    }

    /// 侧边栏二级分类：某个源按类型分组后的分类与频道数。
    func categoryGroups(for playlistID: UUID) -> [TVCategory] {
        guard playlist(for: playlistID)?.isEnabled == true,
              let list = channelCache[playlistID], !list.isEmpty else { return [] }
        if let cached = categoryGroupsCache[playlistID], cached.revision == channelRevision {
            return cached.groups
        }
        let grouped = Dictionary(grouping: list, by: \.group)
        let result = grouped.keys
            .sorted { TVGrouping.rank($0) < TVGrouping.rank($1) }
            .map { TVCategory(group: $0, count: grouped[$0]?.count ?? 0) }
        categoryGroupsCache[playlistID] = (channelRevision, result)
        return result
    }

    /// 聚合视图：不限定源，频道墙合并所有已启用源的频道。
    func focusAllSources() {
        focusedPlaylistID = nil
        groupFilter = nil
        provinceFilter = nil
        countryFilter = nil
        quickFilter = nil
    }

    /// 侧边栏「收藏 / 最近」：跨源聚合，只按快捷筛选收窄。
    func focusQuickFilter(_ filter: TVQuickFilter) {
        focusedPlaylistID = nil
        groupFilter = nil
        provinceFilter = nil
        countryFilter = nil
        quickFilter = filter
    }

    /// 不再限定源时，侧边栏与「全部频道」保持一致的聚合状态。
    var isShowingAllSources: Bool {
        focusedPlaylistID == nil
    }

    /// 从侧边栏直接打开某个源的某个分类。
    func focusGroup(_ group: String, in playlistID: UUID) {
        focusedPlaylistID = playlistID
        groupingMode = .category
        provinceFilter = nil
        countryFilter = nil
        groupFilter = group
        quickFilter = nil
    }

    func playlistName(for id: UUID) -> String {
        playlists.first(where: { $0.id == id })?.name ?? "电视源"
    }

    func playlist(for id: UUID) -> TVPlaylist? {
        playlists.first(where: { $0.id == id })
    }

    // MARK: - 源管理

    /// 导入一条 M3U：先真正拉一次，确认能解析出频道再保存。
    /// 地址可以是 http(s)，也可以是图库里的本地副本（file://）。
    func addPlaylist(name: String, urlString: String, region: TVRegion) async throws -> TVPlaylist {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file" else {
            throw SourceError.parse("请填写 http / https 开头的 M3U 地址")
        }
        let fallbackName = url.host
            ?? (url.isFileURL ? url.deletingPathExtension().lastPathComponent : "自定义电视源")
        var playlist = TVPlaylist(name: trimmedName.isEmpty ? fallbackName : trimmedName,
                                  urlString: trimmedURL,
                                  region: region)
        let started = Date()
        let snapshot = try await IPTVService.load(for: playlist)
        let list = snapshot.channels
        playlist.epgURLString = snapshot.epgURLString ?? playlist.epgURLString
        playlist.lastCheckedAt = Date()
        playlist.lastLatencyMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        playlist.lastChannelCount = list.count
        playlists.append(playlist)
        channelCache[playlist.id] = list
        database.replaceChannels(list, for: playlist.id)
        persistPlaylists()
        rebuildChannels()
        return playlist
    }

    // MARK: - 配置导入导出

    /// 导出全部电视源（含 EPG 地址与地区），方便分享给其他人。
    func exportPlaylistBundle() -> Data? {
        guard !playlists.isEmpty else { return nil }
        return SourceTransferJSON.encode(.television, items: playlists)
    }

    /// 从配置文件导入电视源：按播放地址去重，导入后自动拉一次频道。
    @discardableResult
    func importPlaylistBundle(_ data: Data) -> SourceTransferOutcome {
        switch SourceTransferJSON.decode(TVPlaylist.self, from: data, expecting: .television) {
        case .failure(let error):
            return .failure(error.message)
        case .success(let imported):
            var added: [TVPlaylist] = []
            var skipped = 0
            for var playlist in imported {
                let url = playlist.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else {
                    skipped += 1
                    continue
                }
                let duplicate = playlists.contains {
                    $0.urlString.trimmingCharacters(in: .whitespacesAndNewlines) == url
                }
                guard !duplicate else {
                    skipped += 1
                    continue
                }
                // 分享文件里的 id 只对本机有效：重新生成，避免覆盖已有源。
                playlist.id = UUID()
                playlist.urlString = url
                added.append(playlist)
            }
            guard !added.isEmpty else {
                return SourceTransferOutcome(added: 0, skipped: skipped)
            }
            playlists.append(contentsOf: added)
            persistPlaylists()
            // 频道要联网拉：先登记源，再按正常刷新流程补齐频道与检测结果。
            refresh()
            return SourceTransferOutcome(added: added.count, skipped: skipped)
        }
    }

    /// 本地 M3U：先复制进图库，再按正常流程登记。
    /// 复制之后原文件被移动或删除都不影响播放；校验失败时删掉副本，不在图库里留垃圾。
    func importPlaylistFile(at fileURL: URL) async throws -> TVPlaylist {
        let fm = FileManager.default
        // 同一个文件重复导入时直接复用已有的本地副本，避免频道在墙上重复出现。
        if let incoming = try? Data(contentsOf: fileURL) {
            for playlist in playlists {
                guard let existing = URL(string: playlist.urlString), existing.isFileURL,
                      let data = try? Data(contentsOf: existing), data == incoming else { continue }
                return playlist
            }
        }

        let directory = LibraryPaths.tvPlaylistsDir
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "m3u" : fileURL.pathExtension
        var target = directory.appendingPathComponent("\(base).\(ext)")
        if fm.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).\(ext)")
        }
        try fm.copyItem(at: fileURL, to: target)
        do {
            return try await addPlaylist(name: base,
                                         urlString: target.absoluteString,
                                         region: .mainland)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    /// 批量导入：逐条拉取校验，返回成功条数与失败说明。
    /// 名称按域名自动生成，之后可在源列表里重命名；地址已存在时跳过。
    func addPlaylists(urlStrings: [String],
                      onProgress: ((Int, Int, String) -> Void)? = nil) async -> (added: Int, failures: [String]) {
        var known = Set(playlists.map { $0.urlString.trimmingCharacters(in: .whitespacesAndNewlines) })
        var added = 0
        var failures: [String] = []
        let total = urlStrings.count

        for (index, raw) in urlStrings.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let host = URL(string: trimmed)?.host ?? trimmed
            onProgress?(index + 1, total, host)
            guard known.insert(trimmed).inserted else { continue }
            do {
                _ = try await addPlaylist(name: "",
                                          urlString: trimmed,
                                          region: .mainland)
                added += 1
            } catch {
                let message = (error as? SourceError)?.message ?? error.localizedDescription
                failures.append("\(host)：\(message)")
            }
        }
        return (added, failures)
    }

    func removePlaylist(_ id: UUID) {
        guard playlist(for: id) != nil else { return }
        playlists.removeAll { $0.id == id }
        channelCache[id] = nil
        database.deleteChannels(for: id)
        if focusedPlaylistID == id { focusedPlaylistID = nil }
        persistPlaylists()
        rebuildChannels()
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = trimmed
        persistPlaylists()
    }

    func setPlaylistEnabled(_ id: UUID, enabled value: Bool) {
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].isEnabled != value else { return }
        playlists[index].isEnabled = value
        persistPlaylists()
        if value {
            refreshIfNeeded(forcePlaylist: id)
        } else {
            channelCache[id] = nil
            rebuildChannels()
        }
    }

    /// 侧边栏拖动：把 `id` 放到 `target` 之前，顺序立即写回 SQLite。
    func movePlaylist(_ id: UUID, before target: UUID) {
        guard id != target,
              let from = playlists.firstIndex(where: { $0.id == id }),
              let to = playlists.firstIndex(where: { $0.id == target }) else { return }
        let playlist = playlists.remove(at: from)
        playlists.insert(playlist, at: from < to ? to - 1 : to)
        persistPlaylists()
    }

    /// 拖到列表末尾：移到最后一位。
    func movePlaylistToEnd(_ id: UUID) {
        guard let from = playlists.firstIndex(where: { $0.id == id }),
              from != playlists.count - 1 else { return }
        let playlist = playlists.remove(at: from)
        playlists.append(playlist)
        persistPlaylists()
    }

    /// 右键菜单上移 / 下移，键盘与鼠标都能排序。
    func movePlaylist(_ id: UUID, by offset: Int) {
        guard let from = playlists.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(from + offset, 0), playlists.count - 1)
        guard to != from else { return }
        let playlist = playlists.remove(at: from)
        playlists.insert(playlist, at: to)
        persistPlaylists()
    }

    /// 换图库：电视源、顺序与频道缓存都只属于当前图库，重新从新库的 SQLite 读取。
    func reloadForCurrentLibrary() {
        cancelLoading()
        cancelChecks()
        cancelProbes()
        // 探测历史的落盘任务属于上一个图库：换库时直接丢弃，避免写进新库。
        probeHistoryFlushTask?.cancel()
        probeHistoryFlushTask = nil
        probeHistoryDirty = false
        epgTask?.cancel()
        epgTask = nil
        epgHydrateTask?.cancel()
        epgHydrateTask = nil
        isHydratingEPG = false
        isLoadingEPG = false
        epgPrograms = [:]
        epgChannelNames = [:]
        epgUpdatedAt = nil
        epgError = nil
        resetEPGCaches()
        probeStates = [:]
        probeReports = [:]
        channelCache = [:]
        hasLoaded = false
        guideDayOffset = 0
        error = nil
        sourceError = nil
        failedPlaylistIDs = []

        var restored = database.loadPlaylists()
        // 以前每个图库都会被自动塞进三条内置源：升级后统一移除，之后默认不再接入任何源。
        // 只跑一次；用户自己重新加回来的源是新 id，不受影响。
        if database.setting("builtInsRetired") != "1" {
            let retired = TVPlaylist.retiredBuiltInIDs
            let removed = restored.filter { retired.contains($0.id) }
            if !removed.isEmpty {
                restored.removeAll { retired.contains($0.id) }
                for playlist in removed { database.deleteChannels(for: playlist.id) }
                database.savePlaylists(restored)
            }
            database.setSetting("builtInsRetired", "1")
        }
        // 测试源功能已下线：把之前通过「测试源」加入的三条公开列表一次性清掉。
        if database.setting("testSourcesRetired") != "1" {
            let retired = TVPlaylist.retiredTestSourceURLs
            let removed = restored.filter {
                retired.contains($0.urlString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !removed.isEmpty {
                restored.removeAll {
                    retired.contains($0.urlString.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                for playlist in removed { database.deleteChannels(for: playlist.id) }
                database.savePlaylists(restored)
            }
            database.setSetting("testSourcesRetired", "1")
        }
        playlists = restored
        refreshedAt = database.setting("refreshedAt")
            .flatMap(Double.init)
            .map(Date.init(timeIntervalSince1970:))
        focusedPlaylistID = database.setting("focusedPlaylistID").flatMap(UUID.init(uuidString:))
        groupingMode = TVGroupingMode(rawValue: database.setting("groupingMode") ?? "") ?? .category
        provinceFilter = nil
        groupFilter = nil
        countryFilter = nil
        for playlist in playlists where playlist.isEnabled {
            let cached = database.loadChannels(for: playlist.id)
            if !cached.isEmpty { channelCache[playlist.id] = cached }
        }
        rebuildChannels()
        // 收藏 / 最近 / 预约 / 订阅 / 线路 / 探测历史跟着图库走。
        loadLibraryScopedState()
        startRecordingTicker()
        // 启动即把上次的节目单从磁盘垫进内存：打开「节目回看」不用再等网络。
        hydrateEPGFromCache()
    }

    // MARK: - 拉取

    func refreshIfNeeded() {
        guard enabled, !hasLoaded, !isLoading else { return }
        // 清单 6 小时内直接用库里的缓存，避免每次启动都全量拉一遍；
        // 源库里的「刷新」是显式操作，不受这个 TTL 限制。
        if let refreshedAt,
           Date().timeIntervalSince(refreshedAt) < 6 * 3600,
           !channelCache.isEmpty {
            hasLoaded = true
            rebuildChannels()
            return
        }
        refresh()
    }

    private func refreshIfNeeded(forcePlaylist id: UUID) {
        guard enabled, channelCache[id] == nil else { return }
        refresh()
    }

    func refresh() {
        guard enabled else { return }
        loadTask?.cancel()
        let targets = playlists.filter(\.isEnabled)
        guard !targets.isEmpty else {
            channels = []
            error = "所有电视源都被关闭了，打开至少一条后再刷新。"
            return
        }

        isLoading = true
        error = nil
        sourceError = nil
        failedPlaylistIDs = []

        loadTask = Task { [weak self] in
            var failures: [UUID] = []
            var firstError: SourceError?

            await withTaskGroup(of: (UUID, Int, Result<TVSourceSnapshot, SourceError>).self) { group in
                for playlist in targets {
                    group.addTask {
                        let started = Date()
                        do {
                            let snapshot = try await IPTVService.load(for: playlist)
                            let ms = Int(Date().timeIntervalSince(started) * 1000)
                            return (playlist.id, ms, .success(snapshot))
                        } catch let error as SourceError {
                            return (playlist.id, 0, .failure(error))
                        } catch {
                            return (playlist.id, 0,
                                    .failure(SourceError(kind: .unavailable,
                                                         message: error.localizedDescription)))
                        }
                    }
                }
                for await (id, latency, result) in group {
                    guard let self, !Task.isCancelled else { return }
                    switch result {
                    case .success(let snapshot):
                        let list = snapshot.channels
                        self.channelCache[id] = list
                        self.database.replaceChannels(list, for: id)
                        self.applyEPGURL(snapshot.epgURLString, for: id)
                        self.updateHealth(id: id,
                                          latency: latency,
                                          count: list.count,
                                          errorMessage: nil)
                        // 拉到新频道表：该源的修订号自增，旧快照不再可信。
                        LibraryStore.current?.sourceContentCache.bump(.television(id))
                        // 两条源并行拉取：先成功的（通常是国内源）立即上屏，
                        // 不必等另一条超时结束。
                        self.rebuildChannels()
                    case .failure(let failure):
                        failures.append(id)
                        self.updateHealth(id: id,
                                          latency: nil,
                                          count: nil,
                                          errorMessage: failure.message)
                        if firstError == nil { firstError = failure }
                    }
                }
            }

            guard let self, !Task.isCancelled else { return }
            self.rebuildChannels()
            self.failedPlaylistIDs = Set(failures)
            self.isLoading = false
            self.hasLoaded = true
            if self.channels.isEmpty, let firstError {
                self.sourceError = firstError
                self.error = firstError.message
            } else if let firstError {
                self.error = "部分电视源加载失败：\(firstError.message)"
            }
            if !self.channels.isEmpty {
                let now = Date()
                self.refreshedAt = now
                self.database.setSetting("refreshedAt", String(now.timeIntervalSince1970))
                UserDefaults.standard.set(now, forKey: Keys.refreshedAt)
            }
            self.persistPlaylists()
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    // MARK: - 连接检查（串行队列）

    /// 把源加入检测队列：一次只测一条，避免同时打多个站点；任务条里能看到进度。
    func enqueueConnectionChecks(_ ids: [UUID]) {
        guard enabled else { return }
        let pending = Set(checkQueue)
        for id in ids where !pending.contains(id) && !checkQueue.contains(id) {
            checkQueue.append(id)
        }
        guard !checkQueue.isEmpty else { return }
        isChecking = true
        guard checkTask == nil else { return }
        checkTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard !self.checkQueue.isEmpty else { break }
                let id = self.checkQueue.removeFirst()
                await self.performConnectionCheck(id)
            }
            guard let self else { return }
            self.checkTask = nil
            self.isChecking = false
        }
    }

    func checkAllSources() {
        enqueueConnectionChecks(playlists.filter(\.isEnabled).map(\.id))
    }

    func cancelChecks() {
        checkQueue.removeAll()
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
    }

    /// 清空任务中心里的历史检测记录（不影响源本身的状态）。
    func clearCheckHistory() {
        jobCenter?.clearFinished(kind: .connectivity)
        onJobChange?()
    }

    private func performConnectionCheck(_ id: UUID) async {
        guard let playlist = playlist(for: id), playlist.isEnabled else { return }
        let job = SourceJob(sourceID: .television(id),
                            kind: .connectivity,
                            title: "检测 \(playlist.name)")
        let jobID = jobCenter?.begin(job)
        onJobChange?()

        let started = Date()
        do {
            let snapshot = try await IPTVService.load(for: playlist)
            let list = snapshot.channels
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            channelCache[id] = list
            database.replaceChannels(list, for: id)
            applyEPGURL(snapshot.epgURLString, for: id)
            updateHealth(id: id, latency: ms, count: list.count, errorMessage: nil)
            rebuildChannels()
            persistPlaylists()
            if let jobID {
                jobCenter?.finish(jobID, message: "\(list.count) 个频道 · \(ms) ms")
            }
        } catch {
            let message = (error as? SourceError)?.message ?? error.localizedDescription
            updateHealth(id: id, latency: nil, count: nil, errorMessage: message)
            persistPlaylists()
            if let jobID {
                jobCenter?.fail(jobID, message: message)
            }
        }
        onJobChange?()
    }

    private func updateHealth(id: UUID,
                              latency: Int?,
                              count: Int?,
                              errorMessage: String?) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].lastCheckedAt = Date()
        playlists[index].lastLatencyMilliseconds = latency
        playlists[index].lastChannelCount = count
        playlists[index].lastError = errorMessage
    }

    // MARK: - 展示

    /// 三种分组方式在「全部源」和单个源里都可用：
    /// 省份模式对海外频道退回按类型分组，不会把它们塞进某个省。
    var effectiveGroupingMode: TVGroupingMode { groupingMode }

    func setGroupingMode(_ mode: TVGroupingMode) {
        guard groupingMode != mode else { return }
        groupingMode = mode
        groupFilter = nil
        provinceFilter = nil
        countryFilter = nil
    }

    /// 频道的聚合分区：央视 / 省份 / 其他。
    func section(for channel: TVChannel) -> String {
        if channel.region != .mainland { return channel.group }
        return channel.province ?? TVProvinces.section(for: channel.name)
    }

    /// 当前焦点源的频道数；没有焦点时为所有已启用源之和（同名频道只保留一份）。
    var channelsForFocusedSource: [TVChannel] {
        if let cached = focusedChannelsCache,
           cached.id == focusedPlaylistID,
           cached.revision == channelRevision {
            return cached.list
        }
        let list: [TVChannel]
        if let focusedPlaylistID {
            list = channels.filter { $0.playlistID == focusedPlaylistID }
        } else {
            list = aggregatedChannels
        }
        focusedChannelsCache = (focusedPlaylistID, channelRevision, list)
        return list
    }

    /// 聚合频道墙：同名频道只保留一份（源顺序优先，国内源在前）。
    var aggregatedChannels: [TVChannel] {
        if let cached = aggregatedCache { return cached }
        var seen = Set<String>()
        let list = channels.filter { seen.insert(Self.aggregationKey($0.name)).inserted }
        aggregatedCache = list
        return list
    }

    var aggregateChannelCount: Int { aggregatedChannels.count }

    /// 聚合时判断同名频道：忽略大小写、空格与标点，`CCTV-1` 与 `CCTV1` 视为同一台。
    private static func aggregationKey(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var visibleChannels: [TVChannel] {
        let signature = visibleSignature
        if signature == visibleCacheKey { return visibleCache }
        let result = computeVisibleChannels()
        visibleCache = result
        visibleCacheKey = signature
        return result
    }

    /// 影响可见频道集合的全部条件：任何一项变化就让缓存失效。
    private var visibleSignature: String {
        let favorites = favoriteIDs.sorted().joined(separator: ",")
        let recent = recentIDs.joined(separator: ",")
        return "\(channelRevision)|\(epgRevision)|\(focusedPlaylistID?.uuidString ?? "-")"
            + "|\(regionFilter?.rawValue ?? "-")|\(groupFilter ?? "-")|\(provinceFilter ?? "-")"
            + "|\(countryFilter ?? "-")|\(effectiveGroupingMode.rawValue)|\(quickFilter?.rawValue ?? "-")"
            + "|\(searchText)|\(favorites)|\(recent)"
    }

    /// 「夜航」页缓存用的输入签名：可见频道集合、筛选条件或节目单版本一变就换签名，
    /// 页面据此判断能否直接复用上一次算好的整页数据。
    var tonightDataSignature: String { visibleSignature }

    private func computeVisibleChannels() -> [TVChannel] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchTokens = TVSearchQuery.tokens(keyword)
        let mode = effectiveGroupingMode
        let filtered = channelsForFocusedSource.filter { channel in
            if let regionFilter, channel.region != regionFilter { return false }
            switch mode {
            case .province:
                if let provinceFilter, section(for: channel) != provinceFilter { return false }
            case .country:
                if let countryFilter, TVCountries.country(for: channel) != countryFilter { return false }
            case .category:
                if let groupFilter, channel.group != groupFilter { return false }
            }
            if !keyword.isEmpty {
                // 搜索同时覆盖频道名、分组 / 省份归属与节目名：
                // 用户可能只记得「新闻联播」，也可能直接按「上海」找本地台（东方卫视等）。
                if TVSearchQuery.matchesChannelIdentity(channel, tokens: searchTokens) {
                    return true
                }
                return programs(for: channel).contains {
                    $0.title.localizedCaseInsensitiveContains(keyword)
                }
            }
            return true
        }
        guard let quickFilter else { return filtered }
        switch quickFilter {
        case .favorites:
            return filtered.filter { favoriteIDs.contains($0.id) }
        case .recent:
            let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
            return recentIDs.compactMap { byID[$0] }
        }
    }

    /// 频道号按当前源的完整频道列表编号；筛选后仍保持稳定。
    func channelNumber(for channel: TVChannel) -> Int {
        let key = "\(channelRevision)-\(focusedPlaylistID?.uuidString ?? "-")"
        if key != channelNumberIndexKey {
            var index: [String: Int] = [:]
            for (offset, item) in channelsForFocusedSource.enumerated() where index[item.id] == nil {
                index[item.id] = offset + 1
            }
            channelNumberIndex = index
            channelNumberIndexKey = key
        }
        return channelNumberIndex[channel.id] ?? 0
    }

    var groupedChannels: [(group: String, channels: [TVChannel])] {
        switch effectiveGroupingMode {
        case .category:
            let grouped = Dictionary(grouping: visibleChannels, by: \.group)
            return grouped.keys
                .sorted { TVGrouping.rank($0) < TVGrouping.rank($1) }
                .map { ($0, grouped[$0] ?? []) }
        case .province:
            let grouped = Dictionary(grouping: visibleChannels, by: { section(for: $0) })
            return grouped.keys
                .sorted { provinceSectionRank($0) < provinceSectionRank($1) }
                .map { key in
                    // 省内排序：卫视在前，其余按频道名，避免城市台压过省台。
                    let list = (grouped[key] ?? []).sorted { left, right in
                        let leftSatellite = TVProvinces.isSatellite(left.name)
                        let rightSatellite = TVProvinces.isSatellite(right.name)
                        if leftSatellite != rightSatellite { return leftSatellite }
                        return left.name.localizedStandardCompare(right.name) == .orderedAscending
                    }
                    return (key, list)
                }
        case .country:
            let grouped = Dictionary(grouping: visibleChannels, by: { TVCountries.country(for: $0) })
            return grouped.keys
                .sorted { TVCountries.rank($0) < TVCountries.rank($1) }
                .map { ($0, TVChannelOrder.sorted(grouped[$0] ?? [])) }
        }
    }

    /// 省份分区的顺序：省市按行政区排；海外频道没有省份，退回按频道类型顺序排在后面。
    private func provinceSectionRank(_ section: String) -> Int {
        let index = TVProvinces.rank(section)
        guard index >= TVProvinces.ordered.count else { return index }
        return TVProvinces.ordered.count + TVGrouping.rank(section)
    }

    /// 频道墙上「筛选胶囊」的可选项，跟随当前分组方式。
    /// 「按国家」固定列出全部国家 / 地区：源里暂时没有的也保留入口，
    /// 换源或补源之后不用重新找位置。
    var filterOptions: [String] {
        let scoped = regionFilter.map { region in
            channelsForFocusedSource.filter { $0.region == region }
        } ?? channelsForFocusedSource
        switch effectiveGroupingMode {
        case .category:
            return Array(Set(scoped.map(\.group)))
                .sorted { TVGrouping.rank($0) < TVGrouping.rank($1) }
        case .province:
            return Array(Set(scoped.map { section(for: $0) }))
                .sorted { provinceSectionRank($0) < provinceSectionRank($1) }
        case .country:
            return TVCountries.order
        }
    }

    var totalChannelCount: Int { channels.count }

    // MARK: - 节目预约

    /// 已预约节目的开播时间：节目 id -> 开始时间。用于按钮状态与过期清理。
    @Published private(set) var reminderStarts: [String: Date]
    /// 预约结果提示：由页面转成 Toast 后清空。
    @Published var reminderNotice: String?

    func isReminded(_ program: TVEPGProgram) -> Bool {
        guard let start = reminderStarts[program.id] else { return false }
        return start > Date()
    }

    /// 预约 / 取消预约：预约成功才记状态，避免系统通知没排上却显示「已预约」。
    func toggleReminder(_ program: TVEPGProgram, channel: TVChannel) {
        if isReminded(program) {
            reminderStarts.removeValue(forKey: program.id)
            saveLibraryValue(reminderStarts, key: Keys.reminders)
            TVReminderCenter.shared.cancel(programID: program.id)
            reminderNotice = "已取消预约《\(program.title)》"
            return
        }
        Task { @MainActor in
            let scheduled = await TVReminderCenter.shared.schedule(channel: channel, program: program)
            guard scheduled else {
                reminderNotice = "无法预约：请在系统设置里允许拾光发送通知"
                return
            }
            reminderStarts[program.id] = program.start
            saveLibraryValue(reminderStarts, key: Keys.reminders)
            reminderNotice = "已预约《\(program.title)》"
        }
    }

    func clearReminderNotice() {
        reminderNotice = nil
    }

    // MARK: - 追剧 / 追赛订阅

    /// 已订阅的节目（按归一化节目名去重），跨频道、跨天复用。
    @Published private(set) var subscriptions: [TVSubscription] = []

    /// 关注的球队 / 联赛：夜航据此高亮与筛选，并可一键为相关赛事排提醒。
    @Published private(set) var sportFollows: [TVSportFollow] = []
    /// 录制中心：定时等待与已完成的录制都跟着当前图库保存。
    @Published private(set) var recordings: [TVRecording] = []
    /// 录制调度器：每 20 秒检查一次是否有到点的定时录制。
    private var recordingTimer: Timer?

    /// 节目名归一化：去掉重播标记与集数，跨天、跨频道才能命中同一档节目。
    func programKey(_ title: String) -> String {
        var text = title.lowercased()
        for token in ["（重播）", "(重播)", "重播", "首播"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.replacingOccurrences(
            of: "第[0-9一二三四五六七八九十百]+[集期回季轮]",
            with: "",
            options: .regularExpression
        )
        return text.filter { $0.isLetter || $0.isNumber }
    }

    func isSubscribed(_ program: TVEPGProgram) -> Bool {
        let key = programKey(program.title)
        return subscriptions.contains { $0.key == key }
    }

    /// 追 / 取消追：加入后自动把这档节目未来 7 天里最近的几次排上提醒。
    func toggleSubscription(_ program: TVEPGProgram, channel: TVChannel) {
        let key = programKey(program.title)
        if let index = subscriptions.firstIndex(where: { $0.key == key }) {
            subscriptions.remove(at: index)
            saveLibraryValue(subscriptions, key: Keys.subscriptions)
            cancelReminders(matching: key)
            reminderNotice = "已取消追《\(program.title)》"
            return
        }
        subscriptions.append(TVSubscription(key: key,
                                            title: program.title,
                                            createdAt: Date()))
        saveLibraryValue(subscriptions, key: Keys.subscriptions)
        reminderNotice = "已加入追剧：\(program.title)"
        Task { @MainActor in
            await scheduleSubscriptionReminders(key: key)
        }
    }

    func removeSubscription(_ subscription: TVSubscription) {
        guard let index = subscriptions.firstIndex(where: { $0.key == subscription.key })
        else { return }
        subscriptions.remove(at: index)
        saveLibraryValue(subscriptions, key: Keys.subscriptions)
        cancelReminders(matching: subscription.key)
        reminderNotice = "已取消追《\(subscription.title)》"
    }

    /// 未来若干天里所有命中的播出：按开播时间排序，供「追剧日历」使用。
    func subscriptionOccurrences(days: Int = 7) -> [(channel: TVChannel, program: TVEPGProgram)] {
        guard !subscriptions.isEmpty else { return [] }
        let keys = Set(subscriptions.map(\.key))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let now = Date()
        var result: [(channel: TVChannel, program: TVEPGProgram)] = []
        var seen = Set<String>()
        for offset in 0..<max(1, days) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for channel in channelsForFocusedSource {
                for program in programs(on: day, for: channel) {
                    guard program.end > now, keys.contains(programKey(program.title))
                    else { continue }
                    guard seen.insert("\(channel.id)#\(program.id)").inserted else { continue }
                    result.append((channel, program))
                }
            }
        }
        return result.sorted { $0.program.start < $1.program.start }
    }

    /// 订阅命中的下一次播出：页头与节目单里显示「下一次」用。
    func nextOccurrence(of subscription: TVSubscription) -> (channel: TVChannel, program: TVEPGProgram)? {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            var best: (TVChannel, TVEPGProgram)?
            for channel in channelsForFocusedSource {
                for program in programs(on: day, for: channel) {
                    guard program.start > now,
                          programKey(program.title) == subscription.key else { continue }
                    if best == nil || program.start < best!.1.start {
                        best = (channel, program)
                    }
                }
            }
            if let best { return best }
        }
        return nil
    }

    /// 给订阅排未来几次提醒：最多 3 次，避免一开订阅就塞满系统通知。
    private func scheduleSubscriptionReminders(key: String) async {
        let upcoming = subscriptionOccurrences(days: 7)
            .filter { $0.program.start > Date() && programKey($0.program.title) == key }
            .prefix(3)
        for item in upcoming {
            guard reminderStarts[item.program.id] == nil else { continue }
            let scheduled = await TVReminderCenter.shared.schedule(channel: item.channel,
                                                                   program: item.program)
            guard scheduled else { continue }
            reminderStarts[item.program.id] = item.program.start
        }
        saveLibraryValue(reminderStarts, key: Keys.reminders)
    }

    /// 取消订阅时顺手撤掉已排上的提醒（订阅已从列表移除，这里按节目名直接扫）。
    private func cancelReminders(matching key: String) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for channel in channelsForFocusedSource {
                for program in programs(on: day, for: channel)
                where programKey(program.title) == key {
                    reminderStarts.removeValue(forKey: program.id)
                    TVReminderCenter.shared.cancel(programID: program.id)
                }
            }
        }
        saveLibraryValue(reminderStarts, key: Keys.reminders)
    }

    // MARK: - 赛事关注

    func isFollowingSport(_ keyword: String) -> Bool {
        sportFollows.contains { $0.keyword == keyword }
    }

    func toggleSportFollow(_ keyword: String, kind: TVSportFollow.Kind = .team) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            reminderNotice = "关注词太短，换一个球队或联赛名试试"
            return
        }
        if let index = sportFollows.firstIndex(where: { $0.keyword == trimmed }) {
            sportFollows.remove(at: index)
            reminderNotice = "已取消关注「\(trimmed)」"
        } else {
            sportFollows.append(TVSportFollow(keyword: trimmed, kind: kind, createdAt: Date()))
            reminderNotice = "已关注「\(trimmed)」"
        }
        saveLibraryValue(sportFollows, key: Keys.sportFollows)
    }

    func removeSportFollow(_ follow: TVSportFollow) {
        sportFollows.removeAll { $0.keyword == follow.keyword }
        saveLibraryValue(sportFollows, key: Keys.sportFollows)
    }

    /// 命中的关注项：节目标题包含任一关键词即算「我的主队」。
    func sportFollow(for title: String) -> TVSportFollow? {
        sportFollows.first { title.localizedCaseInsensitiveContains($0.keyword) }
    }

    func isFollowedSport(_ title: String) -> Bool {
        sportFollow(for: title) != nil
    }

    /// 从赛事标题里提出可关注的关键词：按常见分隔符切开，去掉「直播 / 决赛」这类泛词。
    func followCandidates(in title: String) -> [String] {
        var text = title
        let separators = [" vs ", " vs. ", " VS ", " Versus ", " 对 ", "—", "－", "-", "·",
                          "|", "：", ":", " ", "（", "(", "）", ")", "【", "】"]
        for separator in separators {
            text = text.replacingOccurrences(of: separator, with: "\u{1F}")
        }
        let generic = ["直播", "重播", "录像", "录播", "高清", "超清", "4k", "hd", "全场",
                       "集锦", "决赛", "半决赛", "小组赛", "淘汰赛", "常规赛", "季后赛",
                       "联赛", "杯赛", "体育", "第", "轮"]
        var result: [String] = []
        for token in text.split(separator: "\u{1F}") {
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2, value.count <= 12 else { continue }
            let lowered = value.lowercased()
            if generic.contains(where: { lowered == $0 }) { continue }
            if result.contains(value) { continue }
            result.append(value)
        }
        return Array(result.prefix(4))
    }

    /// 为「关注」命中的待开赛赛事批量排提醒，返回新排上的场次。
    @discardableResult
    func remindFollowedSports(_ items: [(channel: TVChannel, program: TVEPGProgram)]) -> Int {
        let now = Date()
        var count = 0
        for item in items where item.program.start > now
            && isFollowedSport(item.program.title)
            && !isReminded(item.program) {
            toggleReminder(item.program, channel: item.channel)
            count += 1
        }
        reminderNotice = count > 0 ? "已为 \(count) 场关注赛事排好提醒" : "关注赛事都已经排好提醒"
        return count
    }

    // MARK: - 录制中心

    var pendingRecordings: [TVRecording] { recordings.filter(\.isPending) }
    var finishedRecordings: [TVRecording] { recordings.filter { !$0.isPending } }

    /// 定时录制：按节目时长录（最长 2 小时）。开始时间已过但仍在窗口内时立即开录。
    func scheduleRecording(channel: TVChannel, program: TVEPGProgram) {
        let now = Date()
        guard program.end > now else {
            reminderNotice = "这档节目已经结束"
            return
        }
        let duplicated = recordings.contains {
            $0.channelID == channel.id && $0.title == program.title
                && abs($0.start.timeIntervalSince(program.start)) < 60 && $0.isPending
        }
        guard !duplicated else {
            reminderNotice = "这档节目已经排过录制"
            return
        }
        let duration = min(max(program.duration, 60), 2 * 3600)
        let recording = TVRecording(id: UUID(),
                                    channelID: channel.id,
                                    channelName: channel.name,
                                    playlistID: channel.playlistID,
                                    title: program.title,
                                    streamURL: channel.streamURL,
                                    headers: channel.headers,
                                    isHLS: channel.isHLS,
                                    start: max(program.start, now),
                                    duration: duration,
                                    state: .scheduled,
                                    photoID: nil,
                                    note: nil,
                                    createdAt: now)
        recordings.insert(recording, at: 0)
        saveRecordings()
        reminderNotice = recording.start <= now
            ? "开始录制《\(program.title)》"
            : "已排定《\(program.title)》的录制"
        processDueRecordings()
    }

    /// 追剧录：给订阅命中的下一场播出排一条录制。
    func scheduleSeriesRecording(for subscription: TVSubscription) {
        guard let next = nextOccurrence(of: subscription) else {
            reminderNotice = "「\(subscription.title)」暂无下一场排期"
            return
        }
        scheduleRecording(channel: next.channel, program: next.program)
    }

    /// 立即录 30 秒：直播里遇到精彩片段时用。
    func recordNow(channel: TVChannel, title: String) {
        let now = Date()
        let recording = TVRecording(id: UUID(),
                                    channelID: channel.id,
                                    channelName: channel.name,
                                    playlistID: channel.playlistID,
                                    title: title,
                                    streamURL: channel.streamURL,
                                    headers: channel.headers,
                                    isHLS: channel.isHLS,
                                    start: now,
                                    duration: 30,
                                    state: .scheduled,
                                    photoID: nil,
                                    note: nil,
                                    createdAt: now)
        recordings.insert(recording, at: 0)
        saveRecordings()
        processDueRecordings()
    }

    func cancelRecording(_ recording: TVRecording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index].state = .cancelled
        recordings[index].note = "已取消"
        saveRecordings()
    }

    func removeRecording(_ recording: TVRecording) {
        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
    }

    private func saveRecordings() {
        saveLibraryValue(recordings, key: Keys.recordings)
    }

    private func startRecordingTicker() {
        guard recordingTimer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processDueRecordings() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
        processDueRecordings()
    }

    /// 到点就开录：真正录制交给 `IngestService`，进度登记到任务中心。
    private func processDueRecordings() {
        let now = Date()
        for recording in recordings where recording.state == .scheduled && recording.start <= now {
            launchRecording(recording)
        }
    }

    private func launchRecording(_ recording: TVRecording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        guard !recording.isExpired else {
            recordings[index].state = .cancelled
            recordings[index].note = "错过了开始时间，未录制"
            saveRecordings()
            return
        }
        guard let store = LibraryStore.current,
              let url = URL(string: recording.streamURL) else {
            recordings[index].state = .failed
            recordings[index].note = "当前没有可写入的图库"
            saveRecordings()
            return
        }
        recordings[index].state = .recording
        saveRecordings()

        let jobID = store.beginSourceJob(
            SourceJob(sourceID: .television(recording.playlistID),
                      kind: .record,
                      title: "录制 \(recording.title)",
                      isCancellable: false)
        )
        store.updateSourceJob(jobID, message: "正在抓取直播流…")

        let seconds = max(30, Int(recording.end.timeIntervalSince(Date())))
        let request = IngestRequest(
            payload: .remoteClip(RemoteMedia(url: url, headers: recording.headers), seconds: seconds),
            title: "电视录制·\(recording.title)"
        )
        Task { @MainActor [weak self] in
            do {
                let result = try await store.ingestService.ingest(request)
                store.finishSourceJob(jobID, message: "已保存到图库：\(result.title)")
                self?.completeRecording(recording.id, photoID: result.itemID)
            } catch {
                store.failSourceJob(jobID, message: error.localizedDescription)
                self?.failRecording(recording.id, note: error.localizedDescription)
            }
        }
    }

    private func completeRecording(_ id: UUID, photoID: String?) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].state = .finished
        recordings[index].photoID = photoID
        recordings[index].note = nil
        saveRecordings()
    }

    private func failRecording(_ id: UUID, note: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].state = .failed
        recordings[index].note = note
        saveRecordings()
    }

    // MARK: - 收藏 / 最近

    func isFavorite(_ channel: TVChannel) -> Bool {
        favoriteIDs.contains(channel.id)
    }

    func toggleFavorite(_ channel: TVChannel) {
        if favoriteIDs.contains(channel.id) {
            favoriteIDs.remove(channel.id)
        } else {
            favoriteIDs.insert(channel.id)
        }
        saveLibraryValue(Array(favoriteIDs), key: Keys.favorites)
    }

    /// 打开频道时调用；回看也记进最近。
    func recordRecent(_ channel: TVChannel) {
        recentIDs.removeAll { $0 == channel.id }
        recentIDs.insert(channel.id, at: 0)
        if recentIDs.count > 40 { recentIDs.removeLast(recentIDs.count - 40) }
        saveLibraryValue(recentIDs, key: Keys.recent)
    }

    // MARK: - 线路偏好与 24 小时可用率

    /// 已启用源里按归一化频道名索引的全部频道：打开频道时一次性取走，
    /// 把其它源的同名频道并成备用线路（运营商 IPTV 与公网源互为兜底）。
    func channelsByName() -> [String: [TVChannel]] {
        var index: [String: [TVChannel]] = [:]
        for playlist in playlists where playlist.isEnabled {
            guard let list = channelCache[playlist.id] else { continue }
            for channel in list {
                let key = TVChannel.normalizedName(channel.name)
                guard !key.isEmpty else { continue }
                index[key, default: []].append(channel)
            }
        }
        return index
    }

    /// 优先使用用户锁定的线路；锁定地址已不在当前频道线路里时自动忽略。
    func preferredStreamURL(for channel: TVChannel) -> String? {
        guard let url = preferredLines[channel.id],
              channel.streamLines.contains(url) else { return nil }
        return url
    }

    func setPreferredLine(_ url: String?, for channel: TVChannel) {
        if let url, channel.streamLines.contains(url) {
            preferredLines[channel.id] = url
        } else {
            preferredLines.removeValue(forKey: channel.id)
        }
        saveLibraryValue(preferredLines, key: Keys.preferredLines)
    }

    func recordProbePoint(channelID: String, report: TVProbeReport) {
        recordProbePoints([(channelID, report)])
    }

    /// 一批采样统一落盘：整批只发布一次 `probeHistory`、只写一次磁盘。
    /// 单个频道逐个写时，322 个频道等于把整份历史编码 322 次，正是加载期间的卡顿来源。
    func recordProbePoints(_ results: [(channelID: String, report: TVProbeReport)]) {
        guard !results.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for item in results {
            var points = probeHistory[item.channelID] ?? []
            points.append(TVProbePoint(date: item.report.updatedAt,
                                       success: item.report.isSuccess,
                                       latencyMilliseconds: item.report.ttfbMilliseconds))
            points.removeAll { $0.date < cutoff }
            if points.count > 48 { points.removeFirst(points.count - 48) }
            probeHistory[item.channelID] = points
        }
        probeHistoryDirty = true
        scheduleProbeHistoryFlush()
    }

    /// 采样结果合并后再落盘：连续几批探测只写一次磁盘，避免编码整份历史卡住主线程。
    private func scheduleProbeHistoryFlush() {
        guard probeHistoryFlushTask == nil else { return }
        probeHistoryFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            self.probeHistoryFlushTask = nil
            self.flushProbeHistoryNow()
        }
    }

    private func flushProbeHistoryNow() {
        probeHistoryFlushTask?.cancel()
        probeHistoryFlushTask = nil
        guard probeHistoryDirty else { return }
        probeHistoryDirty = false
        saveLibraryValue(probeHistory, key: Keys.probeHistory)
    }

    func probePoints(for channelID: String) -> [TVProbePoint] {
        probeHistory[channelID] ?? []
    }

    /// 24 小时内成功次数 / 总次数；没有采样时返回 nil。
    func availability(for channelID: String) -> Double? {
        let points = probePoints(for: channelID)
        guard !points.isEmpty else { return nil }
        return Double(points.filter(\.success).count) / Double(points.count)
    }

    /// 进入信号页时的低频巡检：收藏频道先探，其余只补 6 小时前的旧结果。
    func patrolStaleSignals() {
        guard enabled, !isProbingChannels else { return }
        let now = Date()
        var targets: [TVChannel] = []
        for channel in channelsForFocusedSource {
            if let report = probeReports[channel.id] {
                if now.timeIntervalSince(report.updatedAt) > 6 * 3600 {
                    targets.append(channel)
                }
            } else if favoriteIDs.contains(channel.id) {
                targets.append(channel)
            }
        }
        if targets.count > 24 { targets = Array(targets.prefix(24)) }
        for channel in targets {
            Task { await requestPreview(for: channel, force: true) }
        }
    }

    // MARK: - EPG / 回看

    /// 进入节目单 / 回看页、或在播放里打开节目信息时调用。
    /// 有磁盘缓存就先用起来（不联网）；缓存过期时再把刷新排进后台任务。
    func loadEPGIfNeeded(force: Bool = false) {
        guard enabled else { return }
        if force {
            // 手动刷新：上一轮节目单任务先收尾，再重新登记一轮。
            if let epgJobID {
                jobCenter?.cancel(epgJobID)
                onJobFinished?(epgJobID)
                onJobChange?()
            }
            epgJobID = nil
            epgTask?.cancel()
            epgTask = nil
            isLoadingEPG = false
        }
        guard !isLoadingEPG else { return }
        let feeds = epgFeeds()

        // 内存里还没有节目：先把上次的磁盘缓存垫进来，界面立即可用。
        if epgPrograms.isEmpty {
            hydrateEPGFromCache()
        }

        if !force {
            if let updated = epgUpdatedAt,
               Date().timeIntervalSince(updated) < TVEPGService.cacheMaxAge,
               !epgPrograms.isEmpty {
                return
            }
            // 内存还空、但磁盘缓存还新：等 hydrate 垫上，不重复下载。
            if epgPrograms.isEmpty, isEPGCacheFresh(feeds) {
                return
            }
        }

        isLoadingEPG = true
        epgError = nil
        epgTask?.cancel()
        // 节目单更新登记成后台任务：左下角任务条能看到逐个源的进度，也能取消。
        let jobID = jobCenter?.begin(
            SourceJob(sourceID: SourceID("tv:epg"),
                      kind: .epg,
                      title: "更新网络电视节目单"),
            cancel: { [weak self] in
                Task { @MainActor in self?.epgTask?.cancel() }
            }
        )
        epgJobID = jobID
        onJobChange?()

        epgTask = Task { [weak self] in
            var merged: [String: [TVEPGProgram]] = [:]
            var names: [String: [String]] = [:]
            var errors: [String] = []
            var supplementError: String?
            var seenURLs = Set<String>()
            var done = 0
            var cancelled = false
            var failureMessage: String?
            var successMessage: String?

            // 成功 / 失败 / 取消都要收尾任务条，并写进任务记录。
            defer {
                if let self {
                    // 手动刷新会先开新一轮：旧任务收尾时不能把新任务的 ID / 载入状态清掉。
                    let isCurrent = self.epgJobID == jobID
                    if isCurrent { self.epgJobID = nil }
                    if let jobID {
                        if cancelled || Task.isCancelled {
                            self.jobCenter?.cancel(jobID)
                        } else if let failureMessage {
                            self.jobCenter?.fail(jobID, message: failureMessage)
                        } else {
                            self.jobCenter?.finish(jobID, message: successMessage)
                        }
                        self.onJobFinished?(jobID)
                    }
                    if isCurrent { self.isLoadingEPG = false }
                    self.onJobChange?()
                }
            }

            for feed in feeds {
                if Task.isCancelled {
                    cancelled = true
                    return
                }
                if let jobID {
                    self?.jobCenter?.update(jobID,
                                            completed: done,
                                            total: feeds.count,
                                            message: feed.label)
                    self?.onJobChange?()
                }
                // 多个源共用同一份 XMLTV：只拉一次。
                guard seenURLs.insert(feed.url).inserted else {
                    done += 1
                    continue
                }
                do {
                    let data = try await TVEPGService.load(urlString: feed.url)
                    Self.absorb(data, into: &merged, names: &names)
                } catch {
                    let message = (error as? SourceError)?.message ?? error.localizedDescription
                    if feed.isSupplement {
                        supplementError = message
                    } else {
                        errors.append("\(feed.label)：\(message)")
                    }
                }
                done += 1
            }
            guard let self else { return }
            if Task.isCancelled {
                cancelled = true
                return
            }
            // 合并 / 排序 / 建前缀桶都比较重，放到后台线程，避免刷新节目单时卡主线程。
            let prepared = await Task.detached(priority: .utility) { () -> (
                programs: [String: [TVEPGProgram]],
                buckets: [String: [(name: String, ids: [String])]]
            ) in
                var sorted = merged
                for key in sorted.keys {
                    sorted[key]?.sort { $0.start < $1.start }
                }
                var buckets: [String: [(name: String, ids: [String])]] = [:]
                for (name, ids) in names where name.count >= 4 {
                    buckets[String(name.prefix(2)), default: []].append((name, ids))
                }
                return (sorted, buckets)
            }.value
            if Task.isCancelled {
                cancelled = true
                return
            }
            self.epgPrograms = prepared.programs
            self.epgChannelNames = names
            self.epgUpdatedAt = Date()
            self.resetEPGCaches()
            self.epgPrefixBuckets = prepared.buckets
            // 补充源失败但主源有数据时不打扰用户；全空才把原因抛出来。
            if merged.isEmpty, let supplementError {
                errors.append("补充节目单：\(supplementError)")
            }
            self.epgError = errors.isEmpty ? nil : errors.joined(separator: "；")
            if merged.isEmpty {
                failureMessage = self.epgError ?? "没有取到节目单"
            } else {
                let programCount = merged.values.reduce(0) { $0 + $1.count }
                successMessage = "\(prepared.programs.count) 个频道 · \(programCount) 条节目"
            }
        }
    }

    /// 节目单换了一份：所有按频道 / 按天的派生缓存一起失效，前缀桶重新建。
    private func resetEPGCaches() {
        epgRevision &+= 1
        epgKeyCache.removeAll()
        epgProgramCache.removeAll()
        epgSearchText.removeAll(keepingCapacity: true)
        epgDayCache.removeAll()
        channelsWithProgramsCache.removeAll()
        epgPrefixBuckets.removeAll()
    }

    /// 启用的源各自声明的 XMLTV + 内置补充节目单（去重交给调用方）。
    private func epgFeeds() -> [(url: String, label: String, isSupplement: Bool)] {
        var feeds: [(url: String, label: String, isSupplement: Bool)] = []
        for playlist in playlists where playlist.isEnabled {
            let raw = (playlist.epgURLString ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            feeds.append((raw, playlist.name, false))
        }
        feeds.append((TVPlaylist.supplementEPGURLString, "公共补充节目单", true))
        return feeds
    }

    /// 磁盘缓存是否全都还新鲜：只读旁文件时间戳，不解码 JSON、不联网。
    private func isEPGCacheFresh(_ feeds: [(url: String, label: String, isSupplement: Bool)]) -> Bool {
        for feed in feeds {
            guard let savedAt = TVEPGService.cachedSavedAt(urlString: feed.url),
                  Date().timeIntervalSince(savedAt) < TVEPGService.cacheMaxAge else { return false }
        }
        return true
    }

    /// 启动 / 首次进入节目单时先把磁盘缓存垫进内存：界面立刻有节目，网络刷新另行排期。
    func hydrateEPGFromCache() {
        guard enabled, epgPrograms.isEmpty, !isHydratingEPG else { return }
        let feeds = epgFeeds()
        isHydratingEPG = true
        epgHydrateTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) { () -> (
                programs: [String: [TVEPGProgram]],
                names: [String: [String]],
                buckets: [String: [(name: String, ids: [String])]],
                savedAt: Date
            )? in
                var merged: [String: [TVEPGProgram]] = [:]
                var names: [String: [String]] = [:]
                var newest = Date.distantPast
                for feed in feeds {
                    guard let snapshot = TVEPGService.cachedSnapshot(urlString: feed.url) else { continue }
                    Self.absorb(snapshot.data, into: &merged, names: &names)
                    newest = max(newest, snapshot.savedAt)
                }
                guard !merged.isEmpty else { return nil }
                var buckets: [String: [(name: String, ids: [String])]] = [:]
                for (name, ids) in names where name.count >= 4 {
                    buckets[String(name.prefix(2)), default: []].append((name, ids))
                }
                for key in merged.keys {
                    merged[key]?.sort { $0.start < $1.start }
                }
                return (merged, names, buckets, newest)
            }.value
            guard let self else { return }
            self.isHydratingEPG = false
            guard !Task.isCancelled, let prepared else { return }
            // 网络刷新已经写入了更新的数据时，别让旧缓存覆盖。
            if let current = self.epgUpdatedAt, current >= prepared.savedAt { return }
            self.epgPrograms = prepared.programs
            self.epgChannelNames = prepared.names
            self.epgUpdatedAt = prepared.savedAt
            self.resetEPGCaches()
            self.epgPrefixBuckets = prepared.buckets
        }
    }

    /// 把一份 XMLTV 并进合并结果：节目按频道 id 归堆，台名索引允许多套 EPG id 并存。
    nonisolated private static func absorb(_ data: TVEPGData,
                                           into merged: inout [String: [TVEPGProgram]],
                                           names: inout [String: [String]]) {
        for program in data.programs {
            merged[epgKey(program.channelID), default: []].append(program)
        }
        for (id, displayNames) in data.channelNames {
            let key = epgKey(id)
            for name in displayNames {
                let nameKey = epgNameKey(name)
                guard nameKey.count >= 2 else { continue }
                var ids = names[nameKey] ?? []
                if !ids.contains(key) { ids.append(key) }
                names[nameKey] = ids
            }
        }
    }

    func reloadEPG() {
        epgUpdatedAt = nil
        loadEPGIfNeeded(force: true)
    }

    func setEPGURL(_ raw: String?, for playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[index].epgURLString = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persistPlaylists()
        epgUpdatedAt = nil
        loadEPGIfNeeded(force: true)
    }

    private func applyEPGURL(_ raw: String?, for playlistID: UUID) {
        guard let raw, !raw.isEmpty,
              let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        // 已经设过 EPG（手动填写）就不再被列表头部的境外地址覆盖。
        if !(playlists[index].epgURLString ?? "").isEmpty { return }
        guard playlists[index].epgURLString != raw else { return }
        playlists[index].epgURLString = raw
        persistPlaylists()
    }

    /// 一个频道的节目：多份 EPG（主源 + 补充源）可能各用一套频道 id，
    /// 这里把命中的几套都取出来合并；先命中的来源优先，缺的简介用后面的补。
    /// 两家 EPG 对同一档节目的起止时间常差几分钟，按「时间重叠」去重，
    /// 否则时间轴上会出现两段几乎叠在一起的节目块。
    /// 结果按频道缓存，时间轴 / 传送门 / 时间环高频刷新时不再重复合并排序。
    func programs(for channel: TVChannel) -> [TVEPGProgram] {
        if let cached = epgProgramCache[channel.id] { return cached }
        let keys = epgChannelKeys(for: channel)
        var result: [TVEPGProgram] = []
        if !keys.isEmpty {
            var kept: [TVEPGProgram] = []
            for key in keys {
                for program in epgPrograms[key] ?? [] {
                    // 同一时间只能有一档节目：无论来自主源还是补充源，
                    // 只要有明显重叠就只保留先到的那一档（主源优先），
                    // 顺手补上后到来源里更完整的简介。
                    if let hit = Self.overlappingIndex(of: program, in: kept) {
                        if (kept[hit].overview ?? "").isEmpty, let overview = program.overview {
                            kept[hit].overview = overview
                        }
                        if (kept[hit].subtitle ?? "").isEmpty, let subtitle = program.subtitle {
                            kept[hit].subtitle = subtitle
                        }
                        continue
                    }
                    kept.append(program)
                }
            }
            result = kept.sorted { $0.start < $1.start }
        }
        epgProgramCache[channel.id] = result
        return result
    }

    /// 找出与 `program` 明显重叠的已有节目：重叠部分占较短那档的一半以上就算同一档。
    /// 相邻节目首尾相接（重叠 0 秒）不会误判；只有 EPG 数据把同一档拆成多段时才会命中。
    private static func overlappingIndex(of program: TVEPGProgram,
                                        in list: [TVEPGProgram]) -> Int? {
        for (index, other) in list.enumerated() {
            let overlap = min(other.end, program.end)
                .timeIntervalSince(max(other.start, program.start))
            guard overlap >= 30 else { continue }
            let shortest = min(other.duration, program.duration)
            guard shortest > 0, overlap >= shortest * 0.5 else { continue }
            return index
        }
        return nil
    }

    func currentProgram(for channel: TVChannel) -> TVEPGProgram? {
        let now = Date()
        return programs(for: channel).first { $0.start <= now && $0.end > now }
    }

    func nextProgram(for channel: TVChannel) -> TVEPGProgram? {
        let now = Date()
        return programs(for: channel).first { $0.start > now }
    }

    /// 搜索节目单：按节目名 / 副标题模糊匹配，再把命中的节目挂回同一路 EPG 的频道。
    /// 一档节目经常同时出现在多个源的同名台，按「频道 + 节目名 + 开始时间」去重；
    /// 排序以「现在能看的」优先：正在播 → 即将开播 → 已播（越近越靠前）。
    /// `limit == 0` 表示不限制条数。
    func searchPrograms(keyword: String, limit: Int = 40)
        -> [(channel: TVChannel, program: TVEPGProgram)] {
        let raw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, limit >= 0, !raw.isEmpty, !epgPrograms.isEmpty else { return [] }
        let normalizedQuery = SearchFuzzyText.normalize(raw)
        guard !normalizedQuery.isEmpty else { return [] }
        // 归一化后的「节目名 + 副标题」按 EPG 版本缓存：搜索框每变一次都要扫全量节目单，
        // 不能每次都重新折叠一遍中文。
        if epgSearchTextRevision != epgRevision {
            epgSearchText.removeAll(keepingCapacity: true)
            epgSearchTextRevision = epgRevision
        }
        func isMatch(_ program: TVEPGProgram) -> Bool {
            let text: String
            if let cached = epgSearchText[program.id] {
                text = cached
            } else {
                text = SearchFuzzyText.normalize(
                    [program.title, program.subtitle ?? ""].joined(separator: " "))
                epgSearchText[program.id] = text
            }
            guard !text.isEmpty else { return false }
            if text.contains(normalizedQuery) { return true }
            // 反向包含只对至少 2 个字的节目名生效，避免短词吃掉整份节目单。
            return text.count >= 2 && normalizedQuery.contains(text)
        }
        // EPG 频道 id -> 同名的频道（不同源可能各有一路）。
        var channelIndex: [String: [TVChannel]] = [:]
        for channel in channels {
            for key in epgChannelKeys(for: channel) {
                channelIndex[key, default: []].append(channel)
            }
        }
        guard !channelIndex.isEmpty else { return [] }
        let capacity = limit == 0 ? Int.max : max(limit * 4, 40)
        var seen: Set<String> = []
        var found: [(channel: TVChannel, program: TVEPGProgram)] = []
        for (key, programs) in epgPrograms {
            guard let matchedChannels = channelIndex[key] else { continue }
            for program in programs where isMatch(program) {
                for channel in matchedChannels {
                    let signature = "\(channel.id)|\(program.title)|\(Int(program.start.timeIntervalSince1970))"
                    guard seen.insert(signature).inserted else { continue }
                    found.append((channel, program))
                }
                if found.count >= capacity { break }
            }
            if found.count >= capacity { break }
        }
        let now = Date()
        func rank(_ program: TVEPGProgram) -> (Int, TimeInterval) {
            if program.start <= now && program.end > now { return (0, 0) }
            if program.start > now { return (1, program.start.timeIntervalSince(now)) }
            return (2, now.timeIntervalSince(program.end))
        }
        return Array(found.sorted { left, right in
            let a = rank(left.program)
            let b = rank(right.program)
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return left.channel.name.localizedStandardCompare(right.channel.name) == .orderedAscending
        }.prefix(limit))
    }

    /// 某一天内某个频道的全部节目：节目单时间轴与回看双栏共用。按天缓存。
    func programs(on date: Date, for channel: TVChannel) -> [TVEPGProgram] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let key = "\(channel.id)#\(Int(start.timeIntervalSince1970))"
        if let cached = epgDayCache[key] { return cached }
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        // programs(for:) 已经按时间升序，过滤后无需再排。
        let result = programs(for: channel).filter { $0.start < end && $0.end > start }
        epgDayCache[key] = result
        return result
    }

    /// 某个日期有节目单的频道：节目单页的左侧频道栏与「可回看频道」都用它，
    /// 结果按「可见频道集合 + 日期」缓存，切换视图 / 悬停时不再重算。
    func channelsWithPrograms(on date: Date) -> [TVChannel] {
        let list = visibleChannels
        let day = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        let key = "\(visibleCacheKey)|\(day)"
        if let cached = channelsWithProgramsCache[key] { return cached }
        let result = list.filter { !programs(on: date, for: $0).isEmpty }
        if channelsWithProgramsCache.count >= 8 {
            channelsWithProgramsCache.removeAll(keepingCapacity: true)
        }
        channelsWithProgramsCache[key] = result
        return result
    }

    /// 某一天内、已经结束、且源支持回看的节目。
    func catchupPrograms(on date: Date) -> [(channel: TVChannel, program: TVEPGProgram)] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let now = Date()
        let limit = dayEnd > now ? now : dayEnd

        var result: [(TVChannel, TVEPGProgram)] = []
        for channel in visibleChannels {
            guard let source = channel.catchUpSource, !source.isEmpty else { continue }
            let earliest = now.addingTimeInterval(-Double(channel.effectiveCatchUpDays) * 86_400)
            for program in programs(for: channel)
            where program.start >= dayStart && program.start < dayEnd
                && program.end <= limit && program.start >= earliest {
                result.append((channel, program))
            }
        }
        return result
            .sorted { $0.1.start < $1.1.start }
            .map { (channel: $0.0, program: $0.1) }
    }

    var catchupChannelCount: Int {
        visibleChannels.filter {
            !($0.catchUpSource ?? "").isEmpty
        }.count
    }

    /// 频道在 EPG 里的所有可能 id，按优先级排列：tvg-id → 完全同名 → 前缀同名。
    /// 每个频道只算一次，结果缓存到下一份 EPG。
    private func epgChannelKeys(for channel: TVChannel) -> [String] {
        if let cached = epgKeyCache[channel.id] { return cached }
        let keys = computeEPGChannelKeys(for: channel)
        epgKeyCache[channel.id] = keys
        return keys
    }

    private func computeEPGChannelKeys(for channel: TVChannel) -> [String] {
        var keys: [String] = []
        func add(_ key: String) {
            guard epgPrograms[key] != nil, !keys.contains(key) else { return }
            keys.append(key)
        }
        if let tvgID = channel.tvgID {
            add(Self.epgKey(tvgID))
        }
        let nameKey = Self.epgNameKey(channel.name)
        guard nameKey.count >= 2 else { return keys }
        for id in epgChannelNames[nameKey] ?? [] {
            add(id)
        }
        // 没有精确同名时做一次保守的前缀匹配；至少 4 个字符，且前缀后不能紧跟数字，
        // 否则 CCTV1 会误配到 CCTV10 / CCTV11。只扫同首 2 字的桶。
        guard nameKey.count >= 4 else { return keys }
        let bucket = epgPrefixBuckets[String(nameKey.prefix(2))] ?? []
        for (name, ids) in bucket where name.count >= 4 {
            guard Self.isSafePrefix(name, of: nameKey) || Self.isSafePrefix(nameKey, of: name) else {
                continue
            }
            for id in ids { add(id) }
        }
        return keys
    }

    /// `short` 是否是 `long` 的前缀，且后面紧跟的是中文而不是字母 / 数字。
    /// 只允许「CCTV1 → CCTV1综合」这种同一台的补全；`CCTV4` 与 `CCTV4K`、
    /// `CCTV5` 与 `CCTV5PLUS` 是不同频道，不能互相吃排期。
    private static func isSafePrefix(_ short: String, of long: String) -> Bool {
        guard long.count > short.count, long.hasPrefix(short) else { return false }
        let next = long[long.index(long.startIndex, offsetBy: short.count)]
        return !next.isASCII
    }

    nonisolated private static func epgKey(_ raw: String) -> String {
        let base = raw.split(separator: "@").first.map(String.init) ?? raw
        return base.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    nonisolated private static func epgNameKey(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - 实时画面探测

    func probeState(for channelID: String) -> TVProbeState {
        probeStates[channelID] ?? .idle
    }

    func probeReport(for channelID: String) -> TVProbeReport? {
        probeReports[channelID]
    }

    /// 信号页「探测全部」：把当前源的所有频道按并发上限串进统一任务中心。
    func probeFocusedSourceChannels() {
        for channel in channelsForFocusedSource {
            Task { await requestPreview(for: channel, force: true) }
        }
    }

    /// 卡片出现时调用：缓存未过期就直接标记可用，否则排队抓一帧。
    /// `force` 为信号页的「重新探测」：忽略缓存，覆盖旧截帧与参数。
    func requestPreview(for channel: TVChannel, force: Bool = false) async {
        let id = channel.id
        if force {
            probeStates[id] = .idle
        } else {
            switch probeState(for: id) {
            case .available, .probing, .unavailable:
                return
            case .idle:
                break
            }
            if probeQueue.contains(where: { $0.id == id }) { return }
            if await TVPreviewCache.shared.isFresh(id) {
                probeStates[id] = .available
                return
            }
        }
        if probeQueue.contains(where: { $0.id == id }) { return }
        probeQueue.append(channel)
        probeJobTotal += 1
        startProbeJobIfNeeded(for: channel)
        if let jobID = probeJobID {
            jobCenter?.update(jobID,
                              completed: probeJobCompleted,
                              total: probeJobTotal,
                              message: probeMessage)
        }
        onJobChange?()
        startProbeWorker()
    }

    func retryPreview(for channel: TVChannel) {
        probeStates[channel.id] = .idle
        Task { await requestPreview(for: channel) }
    }

    /// 离开频道页时停掉排队；正在抓的会在下一次进入时重新尝试。
    /// 任务条里按「已完成」收尾，避免留下一直转圈的后台任务。
    func cancelProbes() {
        stopProbeWork()
        finishProbeJob()
    }

    private func stopProbeWork() {
        probeQueue.removeAll()
        probeTask?.cancel()
        probeTask = nil
        isProbingChannels = false
        for (id, state) in probeStates where state == .probing {
            probeStates[id] = .idle
        }
    }

    /// 第一次有频道排队时登记任务；同一轮探测共用一个任务，进度累加。
    private func startProbeJobIfNeeded(for channel: TVChannel) {
        guard probeJobID == nil, let jobCenter else { return }
        let job = SourceJob(sourceID: .television(channel.playlistID),
                            kind: .probe,
                            title: "画面探测")
        probeJobID = jobCenter.begin(job, cancel: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.stopProbeWork()
                self.finishProbeJob(cancelled: true)
            }
        })
        onJobChange?()
    }

    private func finishProbeJob(cancelled: Bool = false) {
        if let id = probeJobID {
            probeJobID = nil
            // 用户从任务条取消时，任务中心已把状态置为「已取消」，这里只停抓帧；
            // 正常收尾（离开页面 / 队列跑完）才写入完成状态与摘要。
            if !cancelled, jobCenter?.progress[id]?.phase == .running {
                jobCenter?.finish(id, message: probeSummary)
            }
        }
        probeJobTotal = 0
        probeJobCompleted = 0
        probeJobAvailable = 0
        probeJobUnavailable = 0
        // 收尾时把还没落盘的采样补写一次，避免节流窗口内退出页面丢数据。
        flushProbeHistoryNow()
        onJobChange?()
    }

    private var probeMessage: String {
        var parts = ["已标注 \(probeJobCompleted) / \(probeJobTotal)"]
        if probeJobAvailable > 0 { parts.append("正常 \(probeJobAvailable)") }
        if probeJobUnavailable > 0 { parts.append("异常 \(probeJobUnavailable)") }
        return parts.joined(separator: " · ")
    }

    private var probeSummary: String {
        var parts = ["已标注 \(probeJobCompleted) 个频道"]
        if probeJobAvailable > 0 { parts.append("信号正常 \(probeJobAvailable)") }
        if probeJobUnavailable > 0 { parts.append("信号异常 \(probeJobUnavailable)") }
        return parts.joined(separator: " · ")
    }

    private func startProbeWorker() {
        guard probeTask == nil else { return }
        isProbingChannels = true
        probeTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard !self.probeQueue.isEmpty else { break }
                let count = min(self.probeConcurrency, self.probeQueue.count)
                let batch = Array(self.probeQueue.prefix(count))
                self.probeQueue.removeFirst(count)
                // 一批只发布一次「探测中」：以前每个频道各写一次 state，
                // 整页（侧边栏 + 频道墙 + 顶栏）都会被重新求值一次，滚动就会卡。
                var probing = self.probeStates
                for channel in batch {
                    probing[channel.id] = .probing
                }
                self.probeStates = probing
                await withTaskGroup(of: (String, TVProbeReport).self) { group in
                    for channel in batch {
                        group.addTask {
                            guard let url = URL(string: channel.streamURL) else {
                                var report = TVProbeReport()
                                report.error = "地址无效"
                                return (channel.id, report)
                            }
                            let report = await TVPreviewProbe.report(url: url,
                                                                      headers: channel.headers)
                            return (channel.id, report)
                        }
                    }
                    // 结果先攒在本地，整批结束时一次性写回：
                    // 状态 / 报告 / 历史各发布一次，任务条也只更新一次。
                    var states = self.probeStates
                    var reports = self.probeReports
                    var results: [(channelID: String, report: TVProbeReport)] = []
                    var available = 0
                    var unavailable = 0
                    for await (id, report) in group {
                        // 离开频道页后仍可能收到一批迟到的抓帧结果：直接丢弃。
                        if Task.isCancelled { continue }
                        reports[id] = report
                        results.append((id, report))
                        if let image = report.image {
                            await TVPreviewCache.shared.store(image, id: id)
                            states[id] = .available
                            available += 1
                        } else {
                            states[id] = .unavailable
                            unavailable += 1
                        }
                    }
                    guard !Task.isCancelled else { return }
                    self.probeReports = reports
                    self.probeStates = states
                    self.recordProbePoints(results)
                    self.probeJobAvailable += available
                    self.probeJobUnavailable += unavailable
                    self.probeJobCompleted += batch.count
                    if let jobID = self.probeJobID {
                        self.jobCenter?.update(jobID,
                                               completed: self.probeJobCompleted,
                                               total: self.probeJobTotal,
                                               message: self.probeMessage)
                    }
                    self.onJobChange?()
                }
            }
            guard let self else { return }
            self.probeTask = nil
            self.isProbingChannels = false
            self.finishProbeJob()
        }
    }

    /// 清空台标与实时画面两类缓存。
    func clearImageCaches() {
        probeStates = [:]
        probeReports = [:]
        stopProbeWork()
        finishProbeJob()
        Task {
            await TVLogoCache.shared.clearAll()
            await TVPreviewCache.shared.clearAll()
        }
    }

    // MARK: - 持久化与重建

    private func rebuildChannels() {
        let merged = playlists
            .filter(\.isEnabled)
            .flatMap { channelCache[$0.id] ?? [] }
        channels = TVChannelOrder.sorted(Self.sharingLogos(merged))
    }

    /// 同名频道跨源共用台标：只要有一个源给了图标，其它同名频道都复用它。
    /// 4K / 高清等画质版本缺台标时，复用同一频道的普通版本台标；
    /// 全都没有的保持为空，由界面统一用同一枚占位图标，节目单和播放窗口一致。
    private static func sharingLogos(_ list: [TVChannel]) -> [TVChannel] {
        var shared: [String: String] = [:]
        for channel in list {
            guard let logo = channel.logoURL, !logo.isEmpty else { continue }
            let key = aggregationKey(channel.name)
            if shared[key] == nil { shared[key] = logo }
        }

        // 去掉画质后缀后的台标池：优先采用普通版本（非 4K / 高清）的图标。
        var baseShared: [String: String] = [:]
        var baseIsVariant: [String: Bool] = [:]
        for channel in list {
            guard let logo = channel.logoURL, !logo.isEmpty else { continue }
            let key = logoKey(channel.name)
            let variant = key != aggregationKey(channel.name)
            if baseShared[key] == nil || (baseIsVariant[key] == true && !variant) {
                baseShared[key] = logo
                baseIsVariant[key] = variant
            }
        }

        guard !shared.isEmpty || !baseShared.isEmpty else { return list }
        return list.map { channel in
            if let logo = channel.logoURL, !logo.isEmpty { return channel }
            let exact = aggregationKey(channel.name)
            guard let logo = shared[exact] ?? baseShared[logoKey(channel.name)] else { return channel }
            var copy = channel
            copy.logoURL = logo
            return copy
        }
    }

    /// 台标匹配键：先去掉 4K / 高清 / HDR 等画质标记，再归一化，
    /// 让「深圳卫视 4K」与「深圳卫视」共用同一枚台标。
    private static func logoKey(_ name: String) -> String {
        var text = name.lowercased()
        for token in ["超高清", "高清", "标清", "蓝光", "4k", "8k", "uhd", "fhd",
                      "h265", "h.265", "hevc", "hdr"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        // HD / SD 只在两侧不是英文字母时去掉，避免误伤 NHK 这类台名。
        text = text.replacingOccurrences(of: "(?<![a-z])(hd|sd)(?![a-z])",
                                          with: "",
                                          options: .regularExpression)
        return text.filter { $0.isLetter || $0.isNumber }
    }

    private func persistPlaylists() {
        database.savePlaylists(playlists)
    }
}
