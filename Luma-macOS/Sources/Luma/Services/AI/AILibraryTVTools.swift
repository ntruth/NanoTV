import Foundation

/// 网络电视的智能助手工具：源库、频道、节目单、直播 / 回看、收藏与导航。
extension AILibraryTools {
    static let tvWriteToolNames: Set<String> = ["favorite_tv_channel"]

    static var tvToolDefinitions: [AIRequestTool] {
        [listTVSources, listTVChannels, getTVGuide, playTVChannel,
         favoriteTVChannel, navigateTV]
    }

    private static var listTVSources: AIRequestTool {
        AIRequestTool(
            name: "list_tv_sources",
            description: "列出网络电视的全部电视源：id、名称、地区、是否启用、频道数、延迟与错误。之后可用源 id 过滤频道或直接打开某个源。",
            parameters: objectSchema([:])
        )
    }

    private static var listTVChannels: AIRequestTool {
        AIRequestTool(
            name: "list_tv_channels",
            description: "列出网络电视的频道（可跨源聚合）：频道 id、名称、分组、省份、来源、画质、线路数与可回看天数。支持关键词、电视源与分组筛选，一次最多 2000 个。",
            parameters: objectSchema([
                "query": stringSchema("频道名、分组或省份关键词，可省略"),
                "source": stringSchema("只列某个电视源：源 id 或名称，可省略"),
                "group": stringSchema("只看某个分组，例如「央视」「卫视」，可省略"),
                "limit": integerSchema("最多返回多少个频道，默认 200，最大 2000", minimum: 1, maximum: 2000)
            ])
        )
    }

    private static var getTVGuide: AIRequestTool {
        AIRequestTool(
            name: "get_tv_guide",
            description: "查看某个频道某天的节目单：开始 / 结束时间、标题、简介与是否可回看。day_offset 0 为今天，-1 昨天，最多前后 3 天。",
            parameters: objectSchema([
                "channel": stringSchema("频道名称或频道 id"),
                "source": stringSchema("限定电视源：源 id 或名称，可省略"),
                "day_offset": integerSchema("相对今天的天数偏移，-3…3，默认 0", minimum: -3, maximum: 3),
                "limit": integerSchema("最多返回多少个节目，默认 60，最大 200", minimum: 1, maximum: 200)
            ], required: ["channel"])
        )
    }

    private static var playTVChannel: AIRequestTool {
        AIRequestTool(
            name: "play_tv_channel",
            description: "播放电视直播，或回看某个节目。channel 传频道名称或 id；回看时传 catch_up=true 并用 program 指定节目标题片段。只打开播放器，不修改数据。",
            parameters: objectSchema([
                "channel": stringSchema("频道名称或频道 id"),
                "source": stringSchema("限定电视源：源 id 或名称，可省略"),
                "catch_up": booleanSchema("true 为回看节目，默认 false 播放直播"),
                "program": stringSchema("要回看的节目名称片段；catch_up 时使用，可省略则取当天第一个节目"),
                "day_offset": integerSchema("回看日期相对今天的天数偏移，-3…3，默认 0",
                                            minimum: -3, maximum: 3)
            ], required: ["channel"])
        )
    }

    private static var favoriteTVChannel: AIRequestTool {
        AIRequestTool(
            name: "favorite_tv_channel",
            description: "收藏或取消收藏电视频道。targets 可传频道名称或频道 id。",
            parameters: objectSchema([
                "targets": arraySchema(["type": "string"], description: "频道名称或频道 id"),
                "favorite": booleanSchema("true 收藏，false 取消收藏"),
                "source": stringSchema("限定电视源：源 id 或名称，可省略")
            ], required: ["targets", "favorite"])
        )
    }

    private static var navigateTV: AIRequestTool {
        AIRequestTool(
            name: "navigate_tv",
            description: "打开网络电视并切换分页 / 源 / 分组 / 搜索：tab 可选 channels 直播、tonight 夜航、guide 节目回看、status 信号、overview 源库。只改变界面，不修改数据。",
            parameters: objectSchema([
                "source": stringSchema("电视源 id 或名称；省略则全部频道"),
                "tab": enumSchema(["channels", "tonight", "guide", "status", "overview"],
                                  "要打开的分页，默认 channels"),
                "group": stringSchema("频道分组，例如「央视」「卫视」，可省略"),
                "search": stringSchema("频道搜索词，可省略"),
                "day_offset": integerSchema("节目回看的日期偏移，-3…3，可省略",
                                            minimum: -3, maximum: 3)
            ])
        )
    }
}

// MARK: - 执行

extension LibraryStore {
    func listTVSourcesTool() -> AIToolExecution {
        let items = tvModel.playlists.map { playlist -> [String: Any] in
            var item: [String: Any] = [
                "id": playlist.id.uuidString,
                "name": playlist.name,
                "region": playlist.region.title,
                "enabled": playlist.isEnabled,
                "focused": tvModel.focusedPlaylistID == playlist.id
            ]
            if let count = playlist.lastChannelCount { item["channels"] = count }
            if let latency = playlist.lastLatencyMilliseconds { item["latency_ms"] = latency }
            if let error = playlist.lastError, !error.isEmpty { item["error"] = error }
            return item
        }
        return success(["enabled": tvModel.enabled,
                        "count": items.count,
                        "sources": items],
                       summary: "电视源 \(items.count) 个",
                       photoIDs: [])
    }

    func listTVChannelsTool(_ args: [String: Any]) async -> AIToolExecution {
        guard await tvEnsureChannelsLoaded() else {
            return failure("电视源正在加载或没有可用频道；可在「网络电视 · 源库」检查电视源是否启用")
        }
        let query = (AILibraryTools.string(args["query"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let limit = min(2000, max(1, AILibraryTools.integer(args["limit"], fallback: 200)))
        var source: TVPlaylist?
        if let raw = AILibraryTools.string(args["source"]) {
            guard let resolved = tvResolveSource(raw) else {
                return failure("没有找到电视源「\(raw)」，可先调用 list_tv_sources")
            }
            source = resolved
        }
        let group = AILibraryTools.string(args["group"])?.lowercased()
        let items: [[String: Any]] = tvModel.channels
            .filter { channel in
                if let source, channel.playlistID != source.id { return false }
                if let group, !group.isEmpty,
                   !channel.group.lowercased().contains(group) { return false }
                guard !query.isEmpty else { return true }
                return channel.name.lowercased().contains(query)
                    || channel.group.lowercased().contains(query)
                    || (channel.province ?? "").lowercased().contains(query)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(limit)
            .map { tvChannelPayload($0) }
        return success(["count": items.count,
                        "source": source?.name ?? "全部频道",
                        "channels": items],
                       summary: "频道 \(items.count) 个",
                       photoIDs: [])
    }

    func getTVGuideTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let raw = AILibraryTools.string(args["channel"]) else {
            return failure("请提供频道名称或 id")
        }
        guard await tvEnsureChannelsLoaded() else {
            return failure("电视源正在加载或没有可用频道；可先调用 list_tv_channels")
        }
        guard let channel = tvResolveChannel(raw, sourceRaw: AILibraryTools.string(args["source"])) else {
            return failure("没有找到频道「\(raw)」，可先调用 list_tv_channels")
        }
        let offset = min(3, max(-3, AILibraryTools.integer(args["day_offset"], fallback: 0)))
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let programs = await tvPrograms(on: date, for: channel)
        let limit = min(200, max(1, AILibraryTools.integer(args["limit"], fallback: 60)))
        let items: [[String: Any]] = programs.prefix(limit).map { program in
            var item: [String: Any] = [
                "title": program.title,
                "start": Self.tvTimeFormatter.string(from: program.start),
                "end": Self.tvTimeFormatter.string(from: program.end),
                "live": program.isLive
            ]
            if let subtitle = program.subtitle, !subtitle.isEmpty { item["subtitle"] = subtitle }
            if let overview = program.overview, !overview.isEmpty {
                item["overview"] = String(overview.prefix(200))
            }
            if channel.catchUpSource != nil { item["catch_up"] = true }
            return item
        }
        var payload: [String: Any] = [
            "channel": channel.name,
            "source": tvModel.playlistName(for: channel.playlistID),
            "date": Self.tvDayFormatter.string(from: date),
            "count": items.count,
            "programs": items
        ]
        if tvModel.isLoadingEPG { payload["epg_loading"] = true }
        if let updated = tvModel.epgUpdatedAt {
            payload["epg_updated"] = Self.tvTimeFormatter.string(from: updated)
        }
        return success(payload,
                       summary: programs.isEmpty
                            ? "「\(channel.name)」这天还没有节目单"
                            : "「\(channel.name)」\(items.count) 档节目",
                       photoIDs: [])
    }

    func playTVChannelTool(_ args: [String: Any]) async -> AIToolExecution {
        guard let raw = AILibraryTools.string(args["channel"]) else {
            return failure("请提供频道名称或 id")
        }
        guard await tvEnsureChannelsLoaded() else {
            return failure("电视源正在加载或没有可用频道；可先调用 list_tv_channels")
        }
        guard let channel = tvResolveChannel(raw, sourceRaw: AILibraryTools.string(args["source"])) else {
            return failure("没有找到频道「\(raw)」，可先调用 list_tv_channels")
        }
        guard AILibraryTools.bool(args["catch_up"], fallback: false) else {
            openTVChannel(channel)
            return success(["channel": channel.name,
                            "source": tvModel.playlistName(for: channel.playlistID),
                            "mode": "live"],
                           summary: "播放直播「\(channel.name)」",
                           photoIDs: [])
        }

        let offset = min(3, max(-3, AILibraryTools.integer(args["day_offset"], fallback: 0)))
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let programs = await tvPrograms(on: date, for: channel)
        guard !programs.isEmpty else {
            return failure("「\(channel.name)」这天还没有节目单，可先调用 get_tv_guide 确认")
        }
        let wanted = (AILibraryTools.string(args["program"]) ?? "").lowercased()
        guard let program = programs.first(where: {
            wanted.isEmpty || $0.title.lowercased().contains(wanted)
        }) else {
            let names = programs.prefix(5).map(\.title).joined(separator: "、")
            return failure("没有找到节目「\(wanted)」，这天的节目有：\(names)")
        }
        guard channel.catchUpSource != nil else {
            return failure("「\(channel.name)」这个源不支持回看，只能播放直播")
        }
        openTVCatchup(channel, program: program)
        return success(["channel": channel.name,
                        "program": program.title,
                        "start": Self.tvTimeFormatter.string(from: program.start),
                        "mode": "catchup"],
                       summary: "回看「\(channel.name)」· \(program.title)",
                       photoIDs: [])
    }

    func favoriteTVChannelTool(_ args: [String: Any]) -> AIToolExecution {
        guard tvEnsureChannelsAvailable() else {
            return failure("电视源还没有加载出频道；可先在「网络电视」打开一次")
        }
        let favorite = AILibraryTools.bool(args["favorite"], fallback: true)
        let raws = AILibraryTools.stringArray(args["targets"])
        guard !raws.isEmpty else { return failure("请提供频道名称或 id") }
        let sourceRaw = AILibraryTools.string(args["source"])
        var resolved: [TVChannel] = []
        var missing: [String] = []
        for raw in raws {
            if let channel = tvResolveChannel(raw, sourceRaw: sourceRaw) {
                resolved.append(channel)
            } else {
                missing.append(raw)
            }
        }
        guard !resolved.isEmpty else {
            return failure("没有找到这些频道：\(missing.prefix(3).joined(separator: "、"))")
        }
        var changed = 0
        for channel in resolved {
            let isFavorite = tvModel.favoriteIDs.contains(channel.id)
            if isFavorite != favorite {
                tvModel.toggleFavorite(channel)
                changed += 1
            }
        }
        var payload: [String: Any] = ["favorite": favorite, "count": changed]
        if !missing.isEmpty { payload["missing"] = missing }
        return success(payload,
                       summary: "\(favorite ? "收藏" : "取消收藏") \(changed) 个频道",
                       photoIDs: [])
    }

    func navigateTVTool(_ args: [String: Any]) -> AIToolExecution {
        tvModel.setEnabled(true)
        if let raw = AILibraryTools.string(args["source"]) {
            guard let playlist = tvResolveSource(raw) else {
                return failure("没有找到电视源「\(raw)」，可先调用 list_tv_sources")
            }
            sourceHub.activate(.television(playlist.id))
        } else {
            tvModel.focusAllSources()
            navigate(to: .iptv)
        }
        if let raw = AILibraryTools.string(args["tab"]) {
            tvModel.setHubTab(TVHubTab(rawValue: raw) ?? .channels)
        } else {
            tvModel.setHubTab(.channels)
        }
        if let group = AILibraryTools.string(args["group"]), !group.isEmpty {
            if let id = tvModel.focusedPlaylistID {
                tvModel.focusGroup(group, in: id)
            } else {
                tvModel.groupFilter = group
            }
        }
        if let search = AILibraryTools.string(args["search"]) {
            tvModel.searchText = search
        }
        if args["day_offset"] != nil {
            tvModel.guideDayOffset = min(3, max(-3, AILibraryTools.integer(args["day_offset"],
                                                                          fallback: 0)))
        }
        tvModel.refreshIfNeeded()
        return success(["tab": tvModel.hubTab.title,
                        "source": tvModel.focusedPlaylistID.map { tvModel.playlistName(for: $0) }
                            ?? "全部频道",
                        "count": tvModel.visibleChannels.count],
                       summary: "已打开网络电视 · \(tvModel.hubTab.title)",
                       photoIDs: [])
    }

    // MARK: - 辅助

    /// 首次调用时电视源可能还没加载：给后台拉取一点时间，失败再提示用户。
    private func tvEnsureChannelsLoaded(timeout: TimeInterval = 6) async -> Bool {
        tvModel.setEnabled(true)
        tvModel.refreshIfNeeded()
        if tvEnsureChannelsAvailable() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if tvEnsureChannelsAvailable() { return true }
        }
        return tvEnsureChannelsAvailable()
    }

    private func tvEnsureChannelsAvailable() -> Bool {
        if !tvModel.channels.isEmpty { return true }
        tvModel.refreshIfNeeded()
        return !tvModel.channels.isEmpty
    }

    private func tvPrograms(on date: Date, for channel: TVChannel) async -> [TVEPGProgram] {
        tvModel.loadEPGIfNeeded()
        var programs = tvModel.programs(on: date, for: channel)
        guard programs.isEmpty else { return programs }
        // 节目单是异步下载：短等一会儿，仍为空就按「暂无节目单」返回。
        for _ in 0..<16 {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
            programs = tvModel.programs(on: date, for: channel)
            if !programs.isEmpty { break }
        }
        return programs
    }

    private func tvResolveSource(_ raw: String) -> TVPlaylist? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "all" || text == "全部" || text == "全部频道" { return nil }
        if let id = UUID(uuidString: text) {
            return tvModel.playlists.first { $0.id == id }
        }
        if let exact = tvModel.playlists.first(where: {
            $0.name.caseInsensitiveCompare(text) == .orderedSame
        }) {
            return exact
        }
        return tvModel.playlists.first {
            $0.name.lowercased().contains(text.lowercased())
        }
    }

    private func tvResolveChannel(_ raw: String, sourceRaw: String?) -> TVChannel? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var pool = tvModel.channels
        if let sourceRaw, let playlist = tvResolveSource(sourceRaw) {
            pool = pool.filter { $0.playlistID == playlist.id }
        }
        if let exact = pool.first(where: { $0.id == text }) { return exact }
        if let exact = pool.first(where: {
            $0.name.caseInsensitiveCompare(text) == .orderedSame
        }) {
            return exact
        }
        let normalized = TVChannel.normalizedName(text)
        if let match = pool.first(where: { TVChannel.normalizedName($0.name) == normalized }) {
            return match
        }
        let lower = text.lowercased()
        return pool.first {
            $0.name.lowercased().contains(lower) || $0.group.lowercased().contains(lower)
        }
    }

    private func tvChannelPayload(_ channel: TVChannel) -> [String: Any] {
        var item: [String: Any] = [
            "id": channel.id,
            "name": channel.name,
            "group": channel.group,
            "source_id": channel.playlistID.uuidString,
            "source": tvModel.playlistName(for: channel.playlistID),
            "region": channel.region.title,
            "lines": channel.lineCount,
            "catchup_days": channel.effectiveCatchUpDays,
            "favorite": tvModel.favoriteIDs.contains(channel.id)
        ]
        if let quality = channel.qualityLabel, !quality.isEmpty { item["quality"] = quality }
        if let province = channel.province, !province.isEmpty { item["province"] = province }
        return item
    }

    private static let tvTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let tvDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
