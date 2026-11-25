import Foundation

/// 一条 XMLTV 节目。`channelID` 对应 XMLTV 的 `<programme channel="…">`，
/// 播放层再用频道的 `tvgID` / 台名映射过去。
struct TVEPGProgram: Identifiable, Hashable, Codable {
    var id: String
    var channelID: String
    var title: String
    var subtitle: String?
    var overview: String?
    var start: Date
    var end: Date

    var isLive: Bool {
        let now = Date()
        return start <= now && end > now
    }

    var duration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }
}

/// 一次 XMLTV 拉取的结果：节目 + 频道别名表（用于没有 `tvg-id` 的源按台名映射）。
struct TVEPGData {
    var programs: [TVEPGProgram]
    /// XMLTV channel id -> display names。
    var channelNames: [String: [String]]
}
