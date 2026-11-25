import Foundation
import LumaContentCore

/// 一次 M3U 拉取的结果：频道 + 列表头部声明的 EPG 地址。
struct TVSourceSnapshot {
    var channels: [TVChannel]
    var epgURLString: String?
}

/// 网络电视的拉取层：读 M3U → 解析 → 每个频道挑一条最高画质线路。
/// 统一走 `HTTPSourceTransport`，UA / 超时 / 重试与其他源一致。
enum IPTVService {
    static func channels(for playlist: TVPlaylist) async throws -> [TVChannel] {
        try await load(for: playlist).channels
    }

    static func load(for playlist: TVPlaylist) async throws -> TVSourceSnapshot {
        let text = try await loadText(for: playlist)
        let entries = M3UPlaylist.parse(text)
        guard !entries.isEmpty else {
            throw SourceError.parse("播放列表里没有可用频道")
        }

        let channels = M3UPlaylist.bestChannels(from: entries).map { candidate in
            let group = TVGrouping.display(candidate.groupTitle)
            let displayName = TVChannelNames.chinese(name: candidate.name,
                                                     key: candidate.key)
            // 大陆列表里额外标出省份，供频道墙按省份聚合；其他地区留空。
            let province = playlist.region == .mainland
                ? TVProvinces.province(for: displayName, key: candidate.key)
                : nil
            // 不同地区的列表可能收录同一频道：id 带列表前缀，保留各自地区的收录。
            return TVChannel(id: "\(playlist.id.uuidString)#\(candidate.key)",
                             name: displayName,
                             group: TVGrouping.refine(group,
                                                      name: candidate.name,
                                                      region: playlist.region),
                             logoURL: candidate.entry.logoURL,
                             streamURL: candidate.entry.url,
                             headers: candidate.entry.headers,
                             isHLS: candidate.entry.isHLS,
                             qualityLabel: candidate.qualityLabel,
                             playlistID: playlist.id,
                             region: playlist.region,
                             province: province,
                             tvgID: candidate.entry.tvgID,
                             catchUpSource: catchupTemplate(candidate.entry.catchUpSource,
                                                            base: candidate.entry.url),
                             catchUpDays: candidate.entry.catchUpDays,
                             lineCount: candidate.lineCount,
                             alternateStreamURLs: candidate.alternateEntries.map(\.url))
        }
        return TVSourceSnapshot(channels: channels,
                                epgURLString: absoluteURL(epgURL(in: text),
                                                          base: playlist.urlString))
    }

    /// 拉取播放列表文本：本地导入的列表直接读图库里的副本，网络地址仍走统一传输层。
    private static func loadText(for playlist: TVPlaylist) async throws -> String {
        let address = playlist.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: address), url.isFileURL {
            return try readLocalPlaylist(at: url)
        }
        // 少数本地路径带空格或中文，`URL(string:)` 解析不出来，按文件路径再试一次。
        if address.hasPrefix("/") && !address.lowercased().hasPrefix("http") {
            return try readLocalPlaylist(at: URL(fileURLWithPath: address))
        }
        guard let url = URL(string: address) else {
            throw SourceError.parse("播放列表地址无效：\(playlist.urlString)")
        }
        let response = try await HTTPSourceTransport.shared.send(
            HTTPTransportRequest(url: url, timeout: 25),
            profile: .luma,
            retryPolicy: HTTPRetryPolicy(maxRetries: 1, baseDelay: 0.5)
        )
        guard let text = response.text else {
            throw SourceError.parse("播放列表不是文本格式")
        }
        return text
    }

    private static func readLocalPlaylist(at url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SourceError.parse("读取本地播放列表失败：\(error.localizedDescription)")
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // 部分国内列表仍是 GBK 系编码，退一步按 Latin1 读出，至少能解析出地址。
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw SourceError.parse("播放列表不是文本格式")
    }

    /// M3U 头部常见写法：`#EXTM3U url-tvg="https://…xml"` 或 `x-tvg-url="…"`。
    static func epgURL(in text: String) -> String? {
        let head = String(text.prefix(16_384))
        for key in ["url-tvg", "x-tvg-url"] {
            guard let range = head.range(of: "\(key)=\"", options: .caseInsensitive) else {
                continue
            }
            let rest = head[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            let value = String(rest[..<end])
                .split(separator: ",")
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    /// 回看模板：`?playseek=…` 这类查询串要拼在原地址之后，不能按 URL 相对解析，
    /// 否则会把 `id=fhzw` 这类已有查询参数丢掉。
    private static func catchupTemplate(_ raw: String?, base: String) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("?") {
            let query = String(raw.dropFirst())
            return base.contains("?") ? base + "&" + query : base + "?" + query
        }
        return absoluteURL(raw, base: base)
    }

    private static func absoluteURL(_ raw: String?, base: String) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return raw
        }
        guard let baseURL = URL(string: base),
              let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL else {
            return raw
        }
        return resolved.absoluteString
    }
}
