import Foundation

/// M3U 播放列表里的一条原始记录。
public struct M3UEntry: Hashable, Sendable {
    /// 展示名（已去掉质量 / 状态标记）。
    public var name: String
    /// 原始显示名：画质与状态标记只在解析时清洗展示名，评分仍看原文。
    public var rawName: String
    /// 频道标识（`tvg-id`），用于同名频道去重；可能为空。
    public var tvgID: String?
    public var logoURL: String?
    public var groupTitle: String?
    public var url: String
    /// 播放时需要的请求头（Referer / User-Agent）。
    public var headers: [String: String]
    public var isHLS: Bool
    /// 回看地址模板（`catchup-source`），可能含 `${start}` / `${end}` 等占位符。
    public var catchUpSource: String?
    /// 回看天数（`catchup-days`）。
    public var catchUpDays: Int?

    public init(name: String,
                rawName: String? = nil,
                tvgID: String? = nil,
                logoURL: String? = nil,
                groupTitle: String? = nil,
                url: String,
                headers: [String: String] = [:],
                isHLS: Bool = false,
                catchUpSource: String? = nil,
                catchUpDays: Int? = nil) {
        self.name = name
        self.rawName = rawName ?? name
        self.tvgID = tvgID
        self.logoURL = logoURL
        self.groupTitle = groupTitle
        self.url = url
        self.headers = headers
        self.isHLS = isHLS
        self.catchUpSource = catchUpSource
        self.catchUpDays = catchUpDays
    }
}

/// 一个频道挑出来的最佳线路。
public struct M3UChannelCandidate: Hashable, Sendable {
    /// 去重键：`tvg-id` 或标准化后的频道名。
    public var key: String
    public var name: String
    public var groupTitle: String?
    public var entry: M3UEntry
    /// 画质数字（1080 / 720…），拿不到时为 0。
    public var quality: Int
    /// 展示用画质标签（例如 `1080p`），拿不到时为 nil。
    public var qualityLabel: String?
    /// 同频道的候选线路数量（含当前这条）：信号页用来显示「N 线路」。
    public var lineCount: Int
    /// 除最佳线路外的备用线路：播放失败时按顺序顺延。
    public var alternateEntries: [M3UEntry]

    public init(key: String,
                name: String,
                groupTitle: String?,
                entry: M3UEntry,
                quality: Int,
                qualityLabel: String?,
                lineCount: Int = 1,
                alternateEntries: [M3UEntry] = []) {
        self.key = key
        self.name = name
        self.groupTitle = groupTitle
        self.entry = entry
        self.quality = quality
        self.qualityLabel = qualityLabel
        self.lineCount = lineCount
        self.alternateEntries = alternateEntries
    }
}

/// 解析 IPTV 的 M3U 播放列表，并按画质 / 协议挑出每个频道的可用线路。
/// 只做纯文本处理，不发网络请求，便于单独检查。
public enum M3UPlaylist {

    // MARK: - 解析

    public static func parse(_ text: String) -> [M3UEntry] {
        var entries: [M3UEntry] = []
        var pending: Pending?
        var header = HeaderDefaults()

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXTM3U") {
                // APTV 等列表把 catchup / catchup-source 写在头部，作为所有频道的默认值。
                header = parseHeader(line)
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                var item = parseExtInf(line)
                if item.catchUpSource == nil { item.catchUpSource = header.catchUpSource }
                if item.catchUpDays == nil { item.catchUpDays = header.catchUpDays }
                pending = item
                continue
            }
            if line.hasPrefix("#EXTGRP:") {
                pending?.groupTitle = String(line.dropFirst("#EXTGRP:".count))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("#EXTVLCOPT:") {
                applyVLCOption(String(line.dropFirst("#EXTVLCOPT:".count)), to: &pending)
                continue
            }
            if line.hasPrefix("#") { continue }

            guard let item = pending else { continue }
            pending = nil
            let name = item.name.isEmpty ? (item.tvgName ?? "未命名频道") : item.name
            entries.append(M3UEntry(name: name,
                                    rawName: item.rawName,
                                    tvgID: item.tvgID,
                                    logoURL: item.logoURL,
                                    groupTitle: item.groupTitle,
                                    url: line,
                                    headers: item.headers,
                                    isHLS: isHLS(line),
                                    catchUpSource: item.catchUpSource,
                                    catchUpDays: item.catchUpDays))
        }
        return entries
    }

    private struct Pending {
        var name: String = ""
        var rawName: String = ""
        var tvgName: String?
        var tvgID: String?
        var logoURL: String?
        var groupTitle: String?
        var headers: [String: String] = [:]
        var catchUpSource: String?
        var catchUpDays: Int?
    }

    /// `#EXTM3U` 头部声明的全局回看默认值。
    private struct HeaderDefaults {
        var catchUpSource: String?
        var catchUpDays: Int?
    }

    private static func parseHeader(_ line: String) -> HeaderDefaults {
        var defaults = HeaderDefaults()
        var values: [String: String] = [:]
        scanAttributes(String(line.dropFirst("#EXTM3U".count))) { key, value in
            values[key.lowercased()] = value
        }
        defaults.catchUpSource = values["catchup-source"].flatMap { $0.isEmpty ? nil : $0 }
        defaults.catchUpDays = values["catchup-days"].flatMap { Int($0) }
        return defaults
    }

    private static func parseExtInf(_ line: String) -> Pending {
        var pending = Pending()
        let body = String(line.dropFirst("#EXTINF:".count))
        // 属性与展示名之间以第一个引号外的逗号分隔。
        let split = splitOutsideQuotes(body)
        let attributes = split.attributes
        pending.rawName = split.name
        pending.name = cleanName(split.name)

        var values: [String: String] = [:]
        scanAttributes(attributes) { key, value in
            values[key.lowercased()] = value
        }
        pending.tvgID = values["tvg-id"].flatMap { $0.isEmpty ? nil : $0 }
        pending.tvgName = values["tvg-name"].flatMap { $0.isEmpty ? nil : cleanName($0) }
        pending.logoURL = values["tvg-logo"].flatMap { $0.isEmpty ? nil : $0 }
        pending.groupTitle = values["group-title"].flatMap { $0.isEmpty ? nil : $0 }
        pending.catchUpSource = values["catchup-source"].flatMap { $0.isEmpty ? nil : $0 }
        pending.catchUpDays = values["catchup-days"].flatMap { Int($0) }
        // APTV 等列表把 UA / Referer 直接写在 EXTINF 属性里，与 EXTVLCOPT 等价。
        if let userAgent = values["http-user-agent"], !userAgent.isEmpty {
            pending.headers["User-Agent"] = userAgent
        }
        if let referer = values["http-referer"] ?? values["http-referrer"], !referer.isEmpty {
            pending.headers["Referer"] = referer
        }
        return pending
    }

    private static func splitOutsideQuotes(_ text: String) -> (attributes: String, name: String) {
        var inQuote = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "\"" {
                inQuote.toggle()
            } else if char == ",", !inQuote {
                let attributes = String(text[text.startIndex..<index])
                let name = String(text[text.index(after: index)...])
                return (attributes, name.trimmingCharacters(in: .whitespaces))
            }
            index = text.index(after: index)
        }
        return (text, "")
    }

    private static func scanAttributes(_ text: String, handler: (String, String) -> Void) {
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char.isWhitespace {
                index = text.index(after: index)
                continue
            }
            // key
            let keyStart = index
            while index < text.endIndex, text[index] != "=", !text[index].isWhitespace {
                index = text.index(after: index)
            }
            let key = String(text[keyStart..<index])
            guard index < text.endIndex, text[index] == "=" else { continue }
            index = text.index(after: index)
            guard index < text.endIndex, text[index] == "\"" else { continue }
            index = text.index(after: index)
            let valueStart = index
            while index < text.endIndex, text[index] != "\"" {
                index = text.index(after: index)
            }
            let value = String(text[valueStart..<index])
            if index < text.endIndex { index = text.index(after: index) }
            handler(key, value)
        }
    }

    private static func applyVLCOption(_ option: String, to pending: inout Pending?) {
        guard pending != nil else { return }
        let trimmed = option.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("http-referrer=") {
            let value = String(trimmed.dropFirst("http-referrer=".count))
            if !value.isEmpty { pending?.headers["Referer"] = value }
        } else if trimmed.hasPrefix("http-user-agent=") {
            let value = String(trimmed.dropFirst("http-user-agent=".count))
            if !value.isEmpty { pending?.headers["User-Agent"] = value }
        }
    }

    // MARK: - 选线路

    /// 同一频道可能有多条线路（SD / HD / 不同镜像）。
    /// 保留评分最高的作为主线路，其余按分数排序放进 `alternateEntries` 供播放失败顺延。
    public static func bestChannels(from entries: [M3UEntry]) -> [M3UChannelCandidate] {
        var grouped: [String: [M3UChannelCandidate]] = [:]
        for entry in entries {
            guard isPlayableURL(entry.url) else { continue }
            let quality = qualityValue(entry.rawName)
            let key = dedupeKey(entry)
            let candidate = M3UChannelCandidate(key: key,
                                                name: entry.name,
                                                groupTitle: entry.groupTitle,
                                                entry: entry,
                                                quality: quality,
                                                qualityLabel: quality > 0 ? "\(quality)p" : nil)
            grouped[key, default: []].append(candidate)
        }

        var result: [M3UChannelCandidate] = []
        for (_, list) in grouped {
            let sorted = list.sorted { score($0) > score($1) }
            guard var best = sorted.first else { continue }
            var seen = Set<String>([best.entry.url])
            var alternates: [M3UEntry] = []
            for candidate in sorted.dropFirst() where seen.insert(candidate.entry.url).inserted {
                alternates.append(candidate.entry)
                if alternates.count == 3 { break }
            }
            best.alternateEntries = alternates
            best.lineCount = max(1, 1 + alternates.count)
            result.append(best)
        }
        return result.sorted {
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.key < $1.key
        }
    }

    private static func score(_ candidate: M3UChannelCandidate) -> Int {
        let entry = candidate.entry
        var value = candidate.quality
        if entry.url.lowercased().hasPrefix("https://") { value += 10 }
        if entry.isHLS { value += 6 }
        let lower = entry.rawName.lowercased()
        if lower.contains("not 24/7") { value -= 3 }
        if lower.contains("geo-blocked") { value -= 4 }
        if entry.groupTitle?.lowercased() == "undefined" { value -= 1 }
        return value
    }

    private static func dedupeKey(_ entry: M3UEntry) -> String {
        if let tvgID = entry.tvgID?.lowercased(), !tvgID.isEmpty {
            // iptv-org 用 `CCTV1.cn@HD` 区分画质，去重时只看频道本体。
            return tvgID.split(separator: "@").first.map(String.init) ?? tvgID
        }
        return normalize(entry.name)
    }

    private static func normalize(_ name: String) -> String {
        cleanName(name)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    /// 去掉画质与状态标记，保留干净频道名。
    public static func cleanName(_ raw: String) -> String {
        var name = raw
        for marker in ["[Geo-blocked]", "[Not 24/7]", "[24/7]"] {
            name = name.replacingOccurrences(of: marker, with: "", options: .caseInsensitive)
        }
        // 结尾的 (1080p) / (720p) / (576i) / (4K) 之类。
        let patterns = [#"\s*\(\d{3,4}[pi]\)$"#, #"\s*\(\dK\)$"#, #"\s*\(HD\)$"#, #"\s*\(SD\)$"#]
        for pattern in patterns {
            if let range = name.range(of: pattern, options: .regularExpression) {
                name.removeSubrange(range)
            }
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func qualityValue(_ name: String) -> Int {
        if let value = firstMatch(#"(\d{3,4})[pi]"#, in: name).flatMap(Int.init) {
            return value
        }
        let lower = name.lowercased()
        if lower.contains("4k") || lower.contains("uhd") { return 2160 }
        return 0
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    private static func isHLS(_ url: String) -> Bool {
        url.lowercased().contains(".m3u8")
    }

    private static func isPlayableURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}
