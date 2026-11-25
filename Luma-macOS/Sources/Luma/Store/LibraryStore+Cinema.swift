import Foundation
import AppKit
import Combine
import LumaContentCore

/// 影院库的基础数据：索引读写、片头尾、续播记录、收藏与下一集预热。

/// 下一集预热好的边下边播流：首段已生成、ffmpeg 处于挂起状态。
/// 切换过去时直接复用播放列表，省掉解析直链、ffprobe 与首段等待。
struct CinemaPrewarmedStream {
    let photoID: UUID
    let playlistURL: URL
    let sourceURL: URL
    let headers: [String: String]
    /// 条目里记录的时长：网盘元数据不一定带 duration，接管时用它撑起进度条。
    let duration: Double
    /// 预热前探测到的画面尺寸 / 编码：接管时直接复用，不再重新探测。
    let videoSize: CGSize
    let isHEVC: Bool
    /// 探测到的音轨结构：接管后菜单能显示语言 / 声道，也用于对上多音轨缓存。
    let audioTracks: [AudioTrackInfo]
    let session: VideoStreamSession
    let createdAt: Date
}

/// 自动归组的合集：同一个 TMDB belongs_to_collection。
struct CinemaCollectionGroup: Identifiable {
    let id: Int
    let name: String
    let entries: [CinemaEntry]
}

/// 海报墙的字母索引：每个首字母指向第一条内容，点击滚过去。
struct CinemaLetterEntry: Identifiable {
    let letter: String
    let target: String
    var id: String { letter }
}

/// 海报墙统计：规格分布与已看数量。
struct CinemaAggregateStats {
    var matched = 0
    var uhd = 0
    var hd = 0
    var sd = 0
    var watched = 0
}

/// 影院派生数据快照：一次遍历产出所有列表，页面里反复读取不再重复聚合。
struct CinemaAggregate {
    var allEntries: [CinemaEntry] = []
    var entries: [CinemaEntry] = []
    var unmatched: [CinemaEntry] = []
    var movies: [CinemaEntry] = []
    var series: [CinemaSeries] = []
    var unmatchedSeries: [CinemaSeries] = []
    var unmatchedMovies: [CinemaEntry] = []
    var collections: [CinemaCollectionGroup] = []
    var letters: [CinemaLetterEntry] = []
    /// 版本键 → 同版本文件数：卡片上的「N 版本」不再逐张全量扫描索引。
    var versionCounts: [String: Int] = [:]
    var stats = CinemaAggregateStats()
    var favoriteCount = 0
    var recentCount = 0
    var highRatedCount = 0
    var wallItemCount = 0
    /// 当前影院的类型分布：顶栏固定类型与「类型」弹层都读它。
    var types: [CinemaTypeBucket] = []
}

// MARK: - 影院刮削与播放


extension LibraryStore {
    /// 本地图库的刮削结果沿用旧 key，网盘各自一份。
    static let cinemaIndexSettingKey = "cinema_index"
    /// 影院续播记录：与刮削索引分开存，避免清空索引时连带丢掉观看进度。
    static let cinemaProgressSettingKey = "cinema_progress"
    /// 影院用户状态与自定义清单。
    static let cinemaUserStateSettingKey = "cinema_user_state"
    static let cinemaListsSettingKey = "cinema_lists"
    /// 剧集级跳过片头 / 片尾设置。
    static let cinemaIntroSettingKey = "cinema_intro_marks"
    static let cinemaEpisodeIntroSettingKey = "cinema_intro_episode_marks"
    /// 通知中心归档（今天 / 本周，保留 30 天）。
    static let cinemaNotificationsSettingKey = "cinema_notifications"
    /// 多版本默认文件（版本键 → photoID），与刮削索引分开存。
    static let cinemaDefaultVersionSettingKey = "cinema_default_versions"

    nonisolated static func cinemaSettingKey(for scope: CinemaScope) -> String {
        switch scope {
        case .local:
            return "cinema_index"
        case .mount(let id):
            return "cinema_index_\(id.uuidString)"
        }
    }

    /// 已忽略的视频清单：按作用域单独保存，不混进刮削索引。
    nonisolated static func cinemaIgnoredSettingKey(for scope: CinemaScope) -> String {
        switch scope {
        case .local:
            return "cinema_ignored_local"
        case .mount(let id):
            return "cinema_ignored_\(id.uuidString)"
        }
    }

    // MARK: 读写

    /// 当前查看作用域的条目（已排除手动忽略的视频）。
    var cinemaEntries: [UUID: CinemaEntry] {
        cinemaEntries(for: cinemaActiveScope)
    }

    func cinemaEntries(for scope: CinemaScope) -> [UUID: CinemaEntry] {
        guard let entries = cinemaIndexes[scope] else { return [:] }
        let ignored = cinemaIgnoredIDs[scope] ?? []
        guard !ignored.isEmpty else { return entries }
        return entries.filter { !ignored.contains($0.key) }
    }

    func cinemaMatchedCount(for scope: CinemaScope) -> Int {
        (cinemaIndexes[scope] ?? [:]).values.filter { $0.matched }.count
    }

    /// 启动时读取影院索引：当前作用域同步读，其余网盘后台补。
    /// 大库启动不再被逐 scope 读表 + JSON 解码堵在主线程上。
    func loadCinemaIndexes() {
        guard let metadataStore else {
            cinemaIndexLoaded = true
            return
        }
        let scopes: [CinemaScope] = [.local] + cloudMounts.map { .mount($0.id) }
        let active = cinemaActiveScope
        let firstScopes = scopes.contains(active) ? [active] : Array(scopes.prefix(1))
        cinemaIndexes = Self.readCinemaIndexScopes(firstScopes, store: metadataStore)
        cinemaIgnoredIDs = Self.readCinemaIgnoredScopes(firstScopes, store: metadataStore)
        loadCinemaProgress()
        loadCinemaUserState()
        loadSourceJobHistory()
        loadCinemaIntroMarks()
        loadCinemaDefaultVersions()
        loadCinemaNotifications()
        cinemaIndexLoaded = true

        let rest = scopes.filter { !firstScopes.contains($0) }
        guard !rest.isEmpty else { return }
        let store = metadataStore
        Task { [weak self] in
            // 旧版混合 JSON 的拆分迁移在主线程同步跑完后再读表，避免两边互相覆盖。
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, !Task.isCancelled else { return }
            let extra = await Task.detached(priority: .utility) {
                (Self.readCinemaIndexScopes(rest, store: store),
                 Self.readCinemaIgnoredScopes(rest, store: store))
            }.value
            guard !Task.isCancelled else { return }
            // 用户这期间可能已经刮削 / 切换：已有数据时不被后台结果覆盖。
            for (scope, entries) in extra.0 where !entries.isEmpty {
                if self.cinemaIndexes[scope]?.isEmpty != false {
                    self.cinemaIndexes[scope] = entries
                }
            }
            for (scope, ids) in extra.1 where !ids.isEmpty {
                if self.cinemaIgnoredIDs[scope]?.isEmpty != false {
                    self.cinemaIgnoredIDs[scope] = ids
                }
            }
        }
    }

    /// 读一组作用域的影院索引：新表优先，旧 JSON 兜底并顺手迁移。
    nonisolated private static func readCinemaIndexScopes(_ scopes: [CinemaScope],
                                                          store: MetadataStore)
        -> [CinemaScope: [UUID: CinemaEntry]] {
        var loaded: [CinemaScope: [UUID: CinemaEntry]] = [:]
        for scope in scopes {
            let key = cinemaSettingKey(for: scope)
            // 新格式：一条一行存 SQLite。
            let rows = store.cinemaEntries(scope: key)
            if !rows.isEmpty {
                loaded[scope] = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                continue
            }
            // 旧格式：整份 JSON 存在设置表里，读到后一次性迁进新表，下次启动直接读表。
            guard let json = store.setting(key),
                  let data = json.data(using: .utf8),
                  let list = try? JSONDecoder().decode([CinemaEntry].self, from: data) else { continue }
            loaded[scope] = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            // 旧版把所有网盘条目混在本地 key 里：留给 migrateLegacy 拆分，别提前迁走。
            if !list.contains(where: { $0.file.cloudMountID != nil }) {
                store.saveCinemaEntries(list, scope: key)
                store.setSettingAsync(key, nil)
            }
        }
        return loaded
    }

    nonisolated private static func readCinemaIgnoredScopes(_ scopes: [CinemaScope],
                                                            store: MetadataStore)
        -> [CinemaScope: Set<UUID>] {
        var ignored: [CinemaScope: Set<UUID>] = [:]
        for scope in scopes {
            guard let json = store.setting(cinemaIgnoredSettingKey(for: scope)),
                  let data = json.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([UUID].self, from: data) else { continue }
            ignored[scope] = Set(ids)
        }
        return ignored
    }

    /// 多版本默认文件：用户选过哪一版就优先展示哪一版。
    func loadCinemaDefaultVersions() {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaDefaultVersionSettingKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: UUID].self, from: data) else { return }
        cinemaDefaultVersions = map
    }

    func setCinemaDefaultVersion(_ entry: CinemaEntry) {
        cinemaDefaultVersions[cinemaVersionKey(for: entry)] = entry.id
        persistCinemaDefaultVersions()
        showToast("已设为默认版本：\(entry.file.filename)")
    }

    func isCinemaDefaultVersion(_ entry: CinemaEntry) -> Bool {
        cinemaDefaultVersions[cinemaVersionKey(for: entry)] == entry.id
    }

    /// 一组同版本文件里优先选用户指定的默认版本，其次按画质。
    func cinemaPreferredVersion(_ entries: [CinemaEntry]) -> CinemaEntry? {
        guard !entries.isEmpty else { return nil }
        let key = cinemaVersionKey(for: entries[0])
        if let id = cinemaDefaultVersions[key],
           let preferred = entries.first(where: { $0.id == id }) {
            return preferred
        }
        return entries.max { cinemaIsBetterVersion($1, $0) }
    }

    func persistCinemaDefaultVersions() {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(cinemaDefaultVersions),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaDefaultVersionSettingKey, json)
    }

    // MARK: 跳过片头 / 片尾

    func loadCinemaIntroMarks() {
        guard let metadataStore else { return }
        if let json = metadataStore.setting(Self.cinemaIntroSettingKey),
           let data = json.data(using: .utf8),
           let marks = try? JSONDecoder().decode([String: CinemaIntroMark].self, from: data) {
            cinemaIntroMarks = marks
        }
        if let json = metadataStore.setting(Self.cinemaEpisodeIntroSettingKey),
           let data = json.data(using: .utf8),
           let marks = try? JSONDecoder().decode([String: CinemaIntroMark].self, from: data) {
            cinemaEpisodeIntroMarks = marks
        }
    }

    func cinemaIntroMark(forSeriesKey key: String) -> CinemaIntroMark {
        if let mark = cinemaIntroMarks[key] { return mark }
        // 没有单独设置时用设置页的全局默认：90 / 60 秒，0 表示不倒。
        let settings = AppSettings.shared
        return CinemaIntroMark(introSeconds: max(0, settings.cinemaSkipIntroSeconds),
                               outroSeconds: max(0, settings.cinemaSkipOutroSeconds))
    }

    /// 单集设置优先；没有单独设置时沿用整部剧的默认值。
    func cinemaIntroMark(for entry: CinemaEntry) -> CinemaIntroMark {
        cinemaEpisodeIntroMarks[entry.id.uuidString]
            ?? cinemaIntroMark(forSeriesKey: cinemaSeriesKey(for: entry))
    }

    func hasCinemaEpisodeIntroMark(for entry: CinemaEntry) -> Bool {
        cinemaEpisodeIntroMarks[entry.id.uuidString] != nil
    }

    func setCinemaIntroMark(_ mark: CinemaIntroMark, forSeriesKey key: String) {
        if mark.isEnabled {
            cinemaIntroMarks[key] = mark
        } else {
            cinemaIntroMarks.removeValue(forKey: key)
        }
        persistCinemaIntroMarks()
    }

    func setCinemaIntroMark(_ mark: CinemaIntroMark, for entry: CinemaEntry) {
        if mark.isEnabled {
            cinemaEpisodeIntroMarks[entry.id.uuidString] = mark
        } else {
            cinemaEpisodeIntroMarks.removeValue(forKey: entry.id.uuidString)
        }
        persistCinemaIntroMarks()
    }

    /// 清除本集覆盖，回落到整部剧的默认设置。
    func clearCinemaEpisodeIntroMark(for entry: CinemaEntry) {
        guard cinemaEpisodeIntroMarks.removeValue(forKey: entry.id.uuidString) != nil else { return }
        persistCinemaIntroMarks()
    }

    func persistCinemaIntroMarks() {
        guard let metadataStore else { return }
        if let data = try? JSONEncoder().encode(cinemaIntroMarks),
           let json = String(data: data, encoding: .utf8) {
            metadataStore.setSetting(Self.cinemaIntroSettingKey, json)
        }
        if let data = try? JSONEncoder().encode(cinemaEpisodeIntroMarks),
           let json = String(data: data, encoding: .utf8) {
            metadataStore.setSetting(Self.cinemaEpisodeIntroSettingKey, json)
        }
    }

    /// 播放器需要和详情页用同一个 key 找到这部剧的跳过设置。
    func cinemaSeriesKey(for entry: CinemaEntry) -> String {
        seriesKey(entry)
    }

    // MARK: 续播记录

    func loadCinemaProgress() {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaProgressSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([CinemaProgressRecord].self, from: data) else { return }
        let loaded = Dictionary(uniqueKeysWithValues: list.map { ($0.photoID, $0) })
        // 旧版本起流点换算错误会把时间轴放大 1000 倍：丢掉这类脏记录，避免「继续观看」
        // 显示已看完、点续播直接落到片尾。
        let cleaned = loaded.filter { _, record in
            record.isTrustworthy(realDuration: cinemaEntryDuration(for: record.photoID))
        }
        cinemaProgress = cleaned
        if cleaned.count != loaded.count { persistCinemaProgress() }
    }

    /// 条目元数据里的片源时长，用于校验续播记录是否合理。
    func cinemaEntryDuration(for photoID: UUID) -> Double? {
        for entries in cinemaIndexes.values {
            if let duration = entries[photoID]?.file.duration, duration > 0 { return duration }
        }
        return nil
    }

    func persistCinemaProgress() {
        guard let metadataStore else { return }
        // 只保留最近 500 条，避免长期使用后无限增长。
        if cinemaProgress.count > 500 {
            let kept = cinemaProgress.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(500)
            cinemaProgress = Dictionary(uniqueKeysWithValues: kept.map { ($0.photoID, $0) })
        }
        guard let data = try? JSONEncoder().encode(Array(cinemaProgress.values)),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaProgressSettingKey, json)
    }

    /// 当前作用域内可以继续观看的记录：未看完、有实际进度，按最近观看排序。
    func cinemaContinueRecords(for scope: CinemaScope) -> [CinemaProgressRecord] {
        let mountID: UUID?
        if case .mount(let id) = scope {
            mountID = id
        } else {
            mountID = nil
        }
        return cinemaProgress.values
            .filter {
                $0.mountID == mountID
                    && !$0.isFinished
                    && $0.position > 3
                    && $0.duration > 0
                    && !(cinemaIndexes[scope]?[$0.photoID].map { cinemaIsRestricted($0) } ?? false)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func cinemaContinueRecord(for scope: CinemaScope) -> CinemaProgressRecord? {
        cinemaContinueRecords(for: scope).first
    }

    /// 所有网盘的续播记录（不含本地图库）：网络存储总览的「续播」页用它跨盘汇总。
    var cloudMountContinueRecords: [CinemaProgressRecord] {
        let mountIDs = Set(cloudMounts.map(\.id))
        return cinemaProgress.values
            .filter { record in
                guard let mountID = record.mountID, mountIDs.contains(mountID) else { return false }
                return !record.isFinished && record.position > 3 && record.duration > 0
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 所有网盘里已经看完的记录：续播页底部的「最近看完」用它。
    var cloudMountFinishedRecords: [CinemaProgressRecord] {
        let mountIDs = Set(cloudMounts.map(\.id))
        return cinemaProgress.values
            .filter { record in
                guard let mountID = record.mountID, mountIDs.contains(mountID) else { return false }
                return record.isFinished
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: 收藏 / 想看 / 评分 / 清单

    func loadCinemaUserState() {
        guard let metadataStore else { return }
        if let json = metadataStore.setting(Self.cinemaUserStateSettingKey),
           let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([CinemaUserState].self, from: data) {
            cinemaUserStates = Dictionary(uniqueKeysWithValues: list.map { ($0.photoID, $0) })
        }
        if let json = metadataStore.setting(Self.cinemaListsSettingKey),
           let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([CinemaListRecord].self, from: data) {
            cinemaLists = list
        }
        if let id = cinemaActiveListID, !cinemaLists.contains(where: { $0.id == id }) {
            cinemaActiveListID = nil
        }
    }

    func persistCinemaUserState() {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(Array(cinemaUserStates.values)),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaUserStateSettingKey, json)
    }

    func persistCinemaLists() {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(cinemaLists),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.cinemaListsSettingKey, json)
    }

    func cinemaUserState(for id: UUID) -> CinemaUserState {
        cinemaUserStates[id] ?? CinemaUserState(photoID: id)
    }

    func toggleCinemaFavorite(_ id: UUID) {
        var state = cinemaUserState(for: id)
        state.favorite.toggle()
        state.updatedAt = Date()
        cinemaUserStates[id] = state
        persistCinemaUserState()
        let title = cinemaEntry(for: id)?.title
        postCinemaToast(.success,
                        title: state.favorite ? "已加入收藏" : "已取消收藏",
                        detail: title,
                        actionTitle: "撤销") { [weak self] in
            self?.toggleCinemaFavorite(id)
        }
    }

    func toggleCinemaWatchlist(_ id: UUID) {
        var state = cinemaUserState(for: id)
        state.watchlist.toggle()
        state.updatedAt = Date()
        cinemaUserStates[id] = state
        persistCinemaUserState()
        postCinemaToast(.success,
                        title: state.watchlist ? "已加入想看" : "已移出想看",
                        detail: cinemaEntry(for: id)?.title,
                        actionTitle: "撤销") { [weak self] in
            self?.toggleCinemaWatchlist(id)
        }
    }

    func setCinemaRating(_ rating: Int?, for id: UUID) {
        var state = cinemaUserState(for: id)
        state.rating = rating.map { min(5, max(1, $0)) }
        state.updatedAt = Date()
        cinemaUserStates[id] = state
        persistCinemaUserState()
    }

    @discardableResult
    func createCinemaList(named name: String) -> CinemaListRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = CinemaListRecord(name: trimmed.isEmpty ? "未命名清单" : trimmed)
        cinemaLists.append(record)
        persistCinemaLists()
        return record
    }

    func deleteCinemaList(_ id: UUID) {
        cinemaLists.removeAll { $0.id == id }
        if cinemaActiveListID == id { cinemaActiveListID = nil }
        persistCinemaLists()
    }

    func addToCinemaList(_ listID: UUID, entryID: UUID) {
        guard let index = cinemaLists.firstIndex(where: { $0.id == listID }) else { return }
        if !cinemaLists[index].itemIDs.contains(entryID) {
            cinemaLists[index].itemIDs.append(entryID)
            persistCinemaLists()
            showToast("已加入「\(cinemaLists[index].name)」")
        }
    }

    func removeFromCinemaList(_ listID: UUID, entryID: UUID) {
        guard let index = cinemaLists.firstIndex(where: { $0.id == listID }) else { return }
        cinemaLists[index].itemIDs.removeAll { $0 == entryID }
        persistCinemaLists()
    }

    func cinemaList(_ id: UUID?) -> CinemaListRecord? {
        guard let id else { return nil }
        return cinemaLists.first { $0.id == id }
    }

    func cinemaListsContaining(_ entryID: UUID) -> [CinemaListRecord] {
        cinemaLists.filter { $0.itemIDs.contains(entryID) }
    }

    /// 清空观看记录：继续观看、观看历史与详情进度一并消失，不删影片。
    func clearCinemaProgress() {
        cinemaProgress = [:]
        persistCinemaProgress()
        showToast("已清除观看记录")
    }

    /// 清空自定义清单：只删清单引用，不删影片与收藏状态。
    func clearCinemaLists() {
        cinemaLists = []
        cinemaActiveListID = nil
        persistCinemaLists()
        showToast("已清除自定义清单")
    }

    func saveCinemaProgress(position: Double,
                                    duration: Double,
                                    entry: CinemaEntry) {
        // 统一续播存储是唯一写入方：新记录也能补齐标题 / 海报。
        playbackProgressStore.recordCinemaProgress(entry: entry,
                                                   position: position,
                                                   duration: duration)
    }

    /// 关闭查看器或切换到其他视频前落盘。
    func finishCinemaPlayback() {
        if let entry = cinemaPlaybackEntry, viewerID == entry.file.photoID {
            let current = viewerModel.videoPlayer.currentTime
            let duration = viewerModel.videoPlayer.duration
            if duration > 0, current > 3 {
                saveCinemaProgress(position: current, duration: duration, entry: entry)
            }
        }
        cinemaPlaybackEntry = nil
        viewerModel.videoPlaybackUI.subtitleQuery = nil
    }

    // MARK: 下一集预热

    /// 快看完时预热下一集：只预生成首段，ffmpeg 随后挂起。
    /// 切集时直接复用播放列表，跳过解析直链、探测与首段等待。
    func prewarmCinemaNextEpisode(after entry: CinemaEntry) {
        guard entry.kind == .tv,
              let next = cinemaNextEpisode(after: entry) else { return }
        // 原生容器直接播就很快，没必要绕 ffmpeg。
        let ext = (next.file.filename as NSString).pathExtension.lowercased()
        guard !["mp4", "mov", "m4v", "m4a"].contains(ext) else { return }
        if cinemaPrewarmedStream?.photoID == next.id { return }
        // 同一个目标已经试过（成功或失败）：进度回调频率很高，不能每次都重来。
        if cinemaPrewarmTarget == next.id { return }

        cinemaPrewarmTask?.cancel()
        discardPrewarmedCinemaStream()
        cinemaPrewarmTarget = next.id
        let photo = anyPhoto(id: next.file.photoID) ?? next.file.photoItem
        let trailer = next.subtitle
        cinemaPrewarmTask = Task { [weak self] in
            guard let self else { return }
            let source: URL
            var headers: [String: String] = [:]
            if photo.isCloud {
                guard let stream = try? await self.cloudStreamOrThrow(for: photo) else { return }
                source = stream.url
                headers = stream.headers
            } else {
                source = LibraryPaths.sourceURL(for: photo)
                guard FileManager.default.fileExists(atPath: source.path) else { return }
            }
            guard !Task.isCancelled else { return }

            // 预热前探测一次：既要拿到音轨结构去对上多音轨缓存，也要识别
            // HDR / 杜比视界 / 隔行源——它们的真实播放路径是转码或色调映射，
            // 预先转出的 SDR remux 会颜色发灰 / 有梳齿，宁可不预热。
            var options: [String: Any] = [:]
            if !headers.isEmpty { options[CloudPlayback.headerFieldsKey] = headers }
            let probe = await VideoSupport.probe(url: source, options: options)
            guard !Task.isCancelled else { return }
            guard probe.hasVideoTrack || probe.duration > 0 else {
                Diagnostics.record("预热跳过 \(trailer)：探测不到流信息", level: .verbose)
                return
            }
            if probe.isHDR || probe.isDolbyVision || probe.color.isHDR || probe.isInterlaced {
                Diagnostics.record("预热跳过 \(trailer)：HDR / 隔行源需要按播放策略转码", level: .verbose)
                return
            }

            let filename = next.file.filename.lowercased()
            let isHEVC = probe.isHEVC
                || next.file.videoCodec?.lowercased() == "hevc"
                || filename.contains("hevc") || filename.contains("x265")
            let size = probe.size.width > 0 && probe.size.height > 0
                ? probe.size
                : CGSize(width: next.file.pixelWidth, height: next.file.pixelHeight)
            // 带上完整音轨结构：预热会话才能和已有多音轨缓存对上，切集直接命中。
            let audioTracks = probe.audioTracks
            let session = VideoStreamSession(
                environment: .luma,
                photoID: next.id,
                source: source,
                headers: headers,
                trustSelfSigned: self.cloudMount(for: next.file.cloudMountID)?.trustSelfSigned ?? false,
                mode: .remux,
                startOffset: 0,
                isHEVC: isHEVC,
                isHDR: false,
                color: probe.color,
                sourceSize: size,
                frameRate: probe.frameRate,
                audioIndex: 0,
                audioChannels: audioTracks.first?.channels ?? 2,
                audioCodec: audioTracks.first?.codec,
                audioTracks: audioTracks,
                audioDownmix: AppSettings.shared.audioDownmix,
                cacheSignature: VideoStreamSession.lumaCacheSignature,
                // 预热会话不写长期缓存；命中现有缓存时只借用播放列表。
                allowsCachePersistence: false,
                refreshSource: self.cinemaCloudRefreshClosure(for: photo))
            do {
                let playlist = try await Task.detached(priority: .utility) {
                    try await session.start()
                }.value
                guard !Task.isCancelled else {
                    session.stop()
                    return
                }
                // 用户已经切到这一集时，正常播放会话已经接手；预热流直接丢掉，
                // 不能再挂回去，否则同一集会同时跑两个 ffmpeg。
                if self.cinemaPlaybackEntry?.file.photoID == next.id {
                    session.stop()
                    return
                }
                // 首段就绪后挂起，避免预热把整集都转成临时分片。
                session.setGenerationActive(false)
                self.cinemaPrewarmedStream = CinemaPrewarmedStream(photoID: next.id,
                                                                  playlistURL: playlist,
                                                                  sourceURL: source,
                                                                  headers: headers,
                                                                  duration: next.file.duration ?? 0,
                                                                  videoSize: size,
                                                                  isHEVC: isHEVC,
                                                                  audioTracks: audioTracks,
                                                                  session: session,
                                                                  createdAt: Date())
                Diagnostics.record("预热下一集 \(trailer) 首段就绪")
            } catch {
                session.stop()
                Diagnostics.record("预热下一集失败 \(trailer)：\(error.localizedDescription)")
            }
        }
    }

    /// 切集时取走预热流；超过 20 分钟视为直链可能过期，直接丢弃。
    func takePrewarmedCinemaStream(for photoID: UUID) -> CinemaPrewarmedStream? {
        guard let warm = cinemaPrewarmedStream, warm.photoID == photoID else { return nil }
        cinemaPrewarmedStream = nil
        cinemaPrewarmTask = nil
        cinemaPrewarmTarget = nil
        guard Date().timeIntervalSince(warm.createdAt) < 20 * 60 else {
            warm.session.stop()
            return nil
        }
        return warm
    }

    func discardPrewarmedCinemaStream() {
        cinemaPrewarmTask?.cancel()
        cinemaPrewarmTask = nil
        cinemaPrewarmTarget = nil
        guard let warm = cinemaPrewarmedStream else { return }
        cinemaPrewarmedStream = nil
        warm.session.stop()
    }

    func cinemaNextEpisode(after entry: CinemaEntry) -> CinemaEntry? {
        let key = cinemaSeriesKey(for: entry)
        let current = (entry.season ?? 0, entry.episode ?? 0)
        var candidates: [CinemaEntry] = []
        for index in cinemaIndexes.values {
            candidates += index.values.filter { $0.kind == .tv && cinemaSeriesKey(for: $0) == key }
        }
        let ordered = candidates.sorted {
            ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
        }
        var seen = Set<String>()
        for candidate in ordered {
            let position = (candidate.season ?? 0, candidate.episode ?? 0)
            guard position > current else { continue }
            let marker = "\(position.0)-\(position.1)"
            if seen.insert(marker).inserted { return candidate }
        }
        return nil
    }

    /// 预热流运行在后台，直链过期时需要重新解析（与播放页同一套逻辑）。
    func cinemaCloudRefreshClosure(for photo: PhotoItem) -> (() -> (URL, [String: String])?)? {
        guard photo.isCloud else { return nil }
        return { [weak self] in
            guard let self, !Thread.isMainThread else { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            var result: (URL, [String: String])?
            Task { @MainActor in
                if let stream = try? await self.cloudStreamOrThrow(for: photo) {
                    result = (stream.url, stream.headers)
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 20)
            return result
        }
    }

    /// 旧版本把所有网盘的条目混在一个 key 里：按 `cloudMountID` 拆回各自作用域。
    func migrateLegacyCinemaIndexIfNeeded() {
        guard let metadataStore,
              let json = metadataStore.setting(Self.cinemaIndexSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([CinemaEntry].self, from: data),
              list.contains(where: { $0.file.cloudMountID != nil }) else { return }

        var split: [CinemaScope: [UUID: CinemaEntry]] = [:]
        for entry in list {
            let scope: CinemaScope = entry.file.cloudMountID.map { .mount($0) } ?? .local
            split[scope, default: [:]][entry.id] = entry
        }
        for (scope, entries) in split {
            // 已经有新数据的网盘不覆盖。
            if scope != .local, let existing = cinemaIndexes[scope], !existing.isEmpty { continue }
            cinemaIndexes[scope] = entries
            persistCinemaIndex(for: scope)
        }
        // 拆完就把旧的混合 JSON 删掉，下次启动只读新表。
        metadataStore.setSettingAsync(Self.cinemaIndexSettingKey, nil)
    }

    func persistCinemaIndex(for scope: CinemaScope) {
        guard let metadataStore else { return }
        metadataStore.saveCinemaEntries(Array((cinemaIndexes[scope] ?? [:]).values),
                                        scope: Self.cinemaSettingKey(for: scope))
        // 刮削 / 合并 / 清理都会走到这里：内容变化后旧快照不再可信。
        sourceContentCache.bump(cinemaSourceID(for: scope))
    }

    /// 影院作用域对应的源 ID：快照与修订号按它区分。
    func cinemaSourceID(for scope: CinemaScope) -> SourceID {
        switch scope {
        case .local: return .localCinema
        case .mount(let id): return .mountCinema(id)
        }
    }

    func clearCinemaIndex(for scope: CinemaScope) {
        cinemaIndexes[scope] = [:]
        persistCinemaIndex(for: scope)
        cinemaFolderRefreshToken &+= 1
        cinemaScrapeMessage = "已清除这个影院的刮削结果"
    }

    /// 资源页展示：所有影院刮削结果的落盘体积（条目 / 详情补全 / 推荐的 JSON）。
    func scrapedCinemaBytes() -> Int64 {
        metadataStore?.cinemaEntriesBytes() ?? 0
    }

    /// 资源页「清理」：清空所有影院的刮削结果，下次进入影院重新刮削。
    /// 续播进度、手动忽略与自定义片单是另一份数据，不受影响。
    func clearAllCinemaScrapedData() {
        metadataStore?.clearAllCinemaEntries()
        cinemaIndexes = [:]
        cinemaDataRevision &+= 1
        cinemaSeriesCache = [:]
        cinemaAggregateCacheKey = nil
        cinemaAggregateCacheValue = nil
        cinemaFolderRefreshToken &+= 1
        showToast("已清空影院刮削结果，下次进入影院会重新刮削")
    }

    /// 设置页「重建索引缓存」：丢掉聚合与剧集缓存，重新从 SQLite 读当前影院。
    func rebuildCinemaIndexCache() {
        cinemaSeriesCache = [:]
        cinemaAggregateCacheKey = nil
        cinemaAggregateCacheValue = nil
        loadCinemaIndexes()
        showToast("已重建影院索引缓存")
    }

    /// 录入设置打开后，把已识别条目的 NFO 写到视频同目录（只处理本地 / SMB 文件）。
    @discardableResult
    func exportCinemaNFOIfEnabled(for scope: CinemaScope) -> Int {
        guard AppSettings.shared.cinemaExportNFO else { return 0 }
        var written = 0
        for entry in (cinemaIndexes[scope] ?? [:]).values where entry.matched {
            guard entry.file.cloudMountID == nil else { continue }
            let photo = anyPhoto(id: entry.file.photoID) ?? entry.file.photoItem
            let source = LibraryPaths.sourceURL(for: photo)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = source.deletingPathExtension().appendingPathExtension("nfo")
            do {
                try CinemaNFO.export(entry: entry).write(to: target, atomically: true, encoding: .utf8)
                written += 1
            } catch {
                Diagnostics.record("导出 NFO 失败 \(entry.title)：\(error.localizedDescription)")
            }
        }
        if written > 0 { showToast("已导出 \(written) 个 NFO") }
        return written
    }

    /// 清空影院筛选（不改作用域，也不清数据）。
    func resetCinemaFilters() {
        cinemaYears = []
        cinemaGenres = []
        cinemaTypeFilterID = nil
        cinemaKindFilters = []
        cinemaCountries = []
        cinemaLanguages = []
        cinemaRuntimeFilters = []
        cinemaRatingFilters = []
        cinemaResolutions = []
        cinemaWatchFilters = []
        cinemaSpecFilters = []
        cinemaSmartHighRated = false
        cinemaSmartRecent = false
        cinemaFavoritesOnly = false
        cinemaActiveListID = nil
    }

    func activateCinemaScope(_ scope: CinemaScope) {
        if cinemaActiveScope != scope {
            cinemaScrapeMessage = nil
            // 换了影院就回到「全部年代 / 全部类型」，避免筛选条件在另一个库里把人筛空。
            cinemaYears = []
            cinemaGenres = []
            cinemaTypeFilterID = nil
            cinemaKindFilters = []
            cinemaCountries = []
            cinemaLanguages = []
            cinemaRuntimeFilters = []
            cinemaRatingFilters = []
            cinemaResolutions = []
            cinemaWatchFilters = []
            cinemaSpecFilters = []
            cinemaSmartHighRated = false
            cinemaSmartRecent = false
            cinemaFavoritesOnly = false
            cinemaActiveListID = nil
        }
        cinemaActiveScope = scope
        // 进入某个网盘影院时顺手校验索引新鲜度：超过 60 秒就做一次增量扫描，
        // 新加入的视频会先进入索引，刮削与「未识别」列表读到的就是最新清单。
        if case .mount(let mountID) = scope {
            ensureCloudIndexFresh(for: mountID)
        }
    }
}
