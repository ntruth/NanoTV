import Foundation
import NanoCore

/// IPTV 直播源解析器、同名频道多线聚合器、回看 URL 拼装与信号测速引擎
public struct IPTVLiveEngine: Sendable {
    public init() {}

    /// 同时兼容 `#EXTM3U` 标准格式与国内 `分类,#genre#` TXT 格式，并自动归一化同名频道合并多线路
    public static func parseAndAggregate(content: String, subscriptionID: UUID) -> [IPTVChannelGroup] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawEntries: [(name: String, group: String, logo: String?, line: IPTVStreamLine)]
        if trimmed.hasPrefix("#EXTM3U") || trimmed.contains("#EXTINF:") {
            rawEntries = parseM3U(content: trimmed, subscriptionID: subscriptionID)
        } else {
            rawEntries = parseGenreTXT(content: trimmed, subscriptionID: subscriptionID)
        }

        // 按归一化频道名聚合多条线路（实现 `< 央视三套 1/25 >` 故障秒切）
        var groupedDict: [String: IPTVChannelGroup] = [:]
        var orderedKeys: [String] = []

        for entry in rawEntries {
            let stdKey = normalizeChannelName(entry.name)
            let category = classifyCategory(groupTitle: entry.group, channelName: entry.name)
            let province = inferProvince(from: entry.group + " " + entry.name)

            if var existing = groupedDict[stdKey] {
                existing.lines.append(entry.line)
                if existing.logoURL == nil, let logo = entry.logo {
                    existing.logoURL = logo
                }
                groupedDict[stdKey] = existing
            } else {
                orderedKeys.append(stdKey)
                groupedDict[stdKey] = IPTVChannelGroup(
                    channelNumber: orderedKeys.count,
                    standardName: stdKey,
                    displayName: entry.name,
                    category: category,
                    province: province,
                    logoURL: entry.logo,
                    lines: [entry.line]
                )
            }
        }

        return orderedKeys.compactMap { groupedDict[$0] }
    }

    /// 根据 EPG 节目起止时间拼装回看（Catch-up / Timeshift）流地址
    public static func buildCatchupStreamURL(line: IPTVStreamLine, program: EPGProgramItem) -> URL? {
        guard line.catchupMode != .none else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmmss"
        fmt.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        let startStr = fmt.string(from: program.startTime)
        let endStr = fmt.string(from: program.endTime)

        if var template = line.catchupSourceTemplate, !template.isEmpty {
            template = template
                .replacingOccurrences(of: "${(b)yyyyMMddHHmmss}", with: startStr)
                .replacingOccurrences(of: "${(e)yyyyMMddHHmmss}", with: endStr)
                .replacingOccurrences(of: "{utc}", with: String(Int(program.startTime.timeIntervalSince1970)))
                .replacingOccurrences(of: "{lutc}", with: String(Int(program.endTime.timeIntervalSince1970)))
            if line.catchupMode == .append {
                let sep = line.url.contains("?") ? "&" : "?"
                let cleanAppend = template.trimmingCharacters(in: CharacterSet(charactersIn: "?&"))
                return URL(string: "\(line.url)\(sep)\(cleanAppend)")
            }
            return URL(string: template)
        }

        // 默认国内广电/运营商通用 playseek 回看协议
        let sep = line.url.contains("?") ? "&" : "?"
        return URL(string: "\(line.url)\(sep)playseek=\(startStr)-\(endStr)")
    }

    /// 并发检测一个频道下所有备用线路的响应耗时 (ms)，并按最快线路自动排序
    public static func probeChannelLines(_ lines: [IPTVStreamLine]) async -> [IPTVStreamLine] {
        await withTaskGroup(of: IPTVStreamLine.self) { group in
            for line in lines {
                group.addTask {
                    var mutableLine = line
                    guard let url = URL(string: line.url) else { return mutableLine }
                    var req = URLRequest(url: url)
                    req.httpMethod = "GET"
                    req.timeoutInterval = 4.0
                    req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                    if let ua = line.userAgent { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
                    let start = ContinuousClock.now
                    do {
                        let (_, resp) = try await URLSession.shared.data(for: req)
                        if let http = resp as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                            let elapsed = start.duration(to: ContinuousClock.now)
                            let ms = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                            mutableLine.latencyMs = max(1, ms)
                        }
                    } catch {
                        mutableLine.latencyMs = nil
                    }
                    return mutableLine
                }
            }
            var updated: [IPTVStreamLine] = []
            for await item in group {
                updated.append(item)
            }
            return updated.sorted {
                ($0.latencyMs ?? Int.max) < ($1.latencyMs ?? Int.max)
            }
        }
    }

    // MARK: - 内部解析辅助

    private static func parseM3U(content: String, subscriptionID: UUID) -> [(name: String, group: String, logo: String?, line: IPTVStreamLine)] {
        var output: [(String, String, String?, IPTVStreamLine)] = []
        let lines = content.components(separatedBy: .newlines)

        var pendingName = ""
        var pendingGroup = "未分类"
        var pendingLogo: String? = nil
        var pendingCatchup: IPTVCatchupMode = .none
        var pendingCatchupSource: String? = nil
        var pendingUA: String? = nil
        var pendingReferer: String? = nil

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF:") {
                if let commaIdx = line.lastIndex(of: ",") {
                    pendingName = String(line[line.index(after: commaIdx)...]).trimmingCharacters(in: .whitespaces)
                }
                pendingGroup = extractAttr("group-title", in: line) ?? "未分类"
                pendingLogo = extractAttr("tvg-logo", in: line)
                if let catchupStr = extractAttr("catchup", in: line)?.lowercased() {
                    pendingCatchup = IPTVCatchupMode(rawValue: catchupStr) ?? .append
                } else {
                    pendingCatchup = .none
                }
                pendingCatchupSource = extractAttr("catchup-source", in: line)
                if pendingCatchupSource != nil && pendingCatchup == .none {
                    pendingCatchup = .append
                }
            } else if line.hasPrefix("#EXTVLCOPT:http-user-agent=") {
                pendingUA = String(line.dropFirst("#EXTVLCOPT:http-user-agent=".count))
            } else if line.hasPrefix("#EXTVLCOPT:http-referrer=") {
                pendingReferer = String(line.dropFirst("#EXTVLCOPT:http-referrer=".count))
            } else if !line.hasPrefix("#") && (line.hasPrefix("http") || line.hasPrefix("rtmp") || line.hasPrefix("rtsp")) {
                let isV6 = line.contains("://[")
                let tag4K = (pendingName.uppercased().contains("4K") || pendingGroup.uppercased().contains("4K")) ? "4K" : nil
                let streamLine = IPTVStreamLine(
                    subscriptionID: subscriptionID,
                    url: line,
                    userAgent: pendingUA,
                    referer: pendingReferer,
                    isIPv6: isV6,
                    resolutionTag: tag4K,
                    catchupMode: pendingCatchup,
                    catchupSourceTemplate: pendingCatchupSource
                )
                let finalName = pendingName.isEmpty ? "未命名频道" : pendingName
                output.append((finalName, pendingGroup, pendingLogo, streamLine))
                pendingName = ""
                pendingUA = nil
                pendingReferer = nil
            }
        }
        return output
    }

    private static func parseGenreTXT(content: String, subscriptionID: UUID) -> [(name: String, group: String, logo: String?, line: IPTVStreamLine)] {
        var output: [(String, String, String?, IPTVStreamLine)] = []
        var currentGroup = "未分类"
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.lowercased().hasSuffix(",#genre#") {
                currentGroup = String(line.dropLast(",#genre#".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[1].hasPrefix("http") {
                let streamLine = IPTVStreamLine(
                    subscriptionID: subscriptionID,
                    url: parts[1].trimmingCharacters(in: .whitespaces),
                    isIPv6: parts[1].contains("://[")
                )
                output.append((parts[0].trimmingCharacters(in: .whitespaces), currentGroup, nil, streamLine))
            }
        }
        return output
    }

    private static func extractAttr(_ key: String, in extinf: String) -> String? {
        let pattern = "\(key)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(extinf.startIndex..<extinf.endIndex, in: extinf)
        guard let match = regex.firstMatch(in: extinf, options: [], range: range),
              let valRange = Range(match.range(at: 1), in: extinf) else { return nil }
        let str = String(extinf[valRange])
        return str.isEmpty ? nil : str
    }

    public static func normalizeChannelName(_ name: String) -> String {
        var s = name.uppercased()
        let noiseWords = ["超高清", "高清", "标清", "FHD", "UHD", "HD", "HEVC", "50FPS", "IPV6", "IPV4", "-", " "]
        for w in noiseWords {
            s = s.replacingOccurrences(of: w, with: "")
        }
        return s
    }

    private static func classifyCategory(groupTitle: String, channelName: String) -> String {
        let combined = (groupTitle + " " + channelName).uppercased()
        if combined.contains("4K") || combined.contains("8K") { return "4K8K 频道" }
        if combined.contains("央视") || combined.contains("CCTV") || combined.contains("CGTN") { return "央视" }
        if combined.contains("卫视") { return "卫视" }
        if combined.contains("港澳") || combined.contains("台湾") || combined.contains("凤凰") || combined.contains("翡翠") || combined.contains("明珠") || combined.contains("台视") || combined.contains("华视") || combined.contains("公视") || combined.contains("民视") {
            return "港澳台"
        }
        if !groupTitle.isEmpty && groupTitle != "未分类" { return "地方" }
        return "未分类"
    }

    public static func inferProvince(from text: String) -> String? {
        let upper = text.uppercased()
        // 省级卫视别名智能映射（例如搜「上海」精准命中东方卫视、第一财经、五星体育等）
        let aliasMapping: [(province: String, keywords: [String])] = [
            ("上海", ["上海", "东方卫视", "东方影视", "上视", "第一财经", "五星体育", "哈哈炫动", "纪实人文"]),
            ("北京", ["北京", "BTV", "BRTV", "卡酷"]),
            ("广东", ["广东", "大湾区", "南方卫视", "珠江", "深圳卫视", "嘉佳卡通"]),
            ("湖南", ["湖南", "金鹰", "芒果", "茶频道", "快乐垂钓"]),
            ("浙江", ["浙江", "钱江", "之江"]),
            ("江苏", ["江苏", "优漫卡通", "靓妆"]),
            ("福建", ["福建", "东南卫视", "海峡卫视", "厦门卫视"]),
            ("海南", ["海南", "旅游卫视"]),
            ("香港", ["香港", "凤凰", "翡翠", "明珠", "TVB", "VIUTV", "HOY", "NOW"]),
            ("台湾", ["台湾", "台视", "华视", "中视", "民视", "公视", "东森", "中天", "TVBS", "纬来", "三立"]),
            ("澳门", ["澳门", "澳亚", "澳视"]),
            ("四川", ["四川", "康巴", "成都"]),
            ("山东", ["山东", "齐鲁"]),
            ("湖北", ["湖北", "武汉"]),
            ("河南", ["河南", "梨园"]),
            ("辽宁", ["辽宁"]),
            ("黑龙江", ["黑龙江"]),
            ("重庆", ["重庆"])
        ]
        for entry in aliasMapping {
            if entry.keywords.contains(where: { upper.contains($0.uppercased()) }) {
                return entry.province
            }
        }
        return nil
    }

    /// 统一搜索匹配：同时匹配频道名、分类、智能省份别名（如「上海」-> 东方卫视）及当前/下期节目单标题
    public static func matchesSearch(channel: IPTVChannelGroup, keyword: String) -> Bool {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return false }
        if channel.displayName.localizedCaseInsensitiveContains(kw) { return true }
        if channel.category.localizedCaseInsensitiveContains(kw) { return true }
        if let prov = channel.province ?? inferProvince(from: channel.displayName),
           prov.localizedCaseInsensitiveContains(kw) {
            return true
        }
        if let cur = channel.currentProgram?.title, cur.localizedCaseInsensitiveContains(kw) {
            return true
        }
        if let next = channel.nextProgram?.title, next.localizedCaseInsensitiveContains(kw) {
            return true
        }
        return false
    }
}
