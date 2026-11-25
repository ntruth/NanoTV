import Foundation

/// 把 M3U 的 `catchup-source` 模板展开成某一条节目的回看地址。
/// 支持常见的 `${start}` / `${end}` / `${utc}` / `${utcend}` / `${timestamp}` 写法，
/// 同时兼容不带 `$` 的 `{start}` 等变体。
enum TVCatchupURL {
    static func build(template: String,
                      program: TVEPGProgram,
                      channel: TVChannel) -> URL? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let local = formatter(timeZone: .current)
        let startLocal = local.string(from: program.start)
        let endLocal = local.string(from: program.end)
        let startEpoch = String(Int(program.start.timeIntervalSince1970))
        let endEpoch = String(Int(program.end.timeIntervalSince1970))
        let values: [String: String] = [
            "start": startLocal,
            "end": endLocal,
            "utc": startEpoch,
            "utcstart": startEpoch,
            "utcend": endEpoch,
            "lutc": startEpoch,
            "timestamp": startEpoch,
            "duration": String(Int(program.duration / 60))
        ]

        var expanded = trimmed
        for (key, value) in values {
            expanded = expanded.replacingOccurrences(of: "${\(key)}", with: value)
            expanded = expanded.replacingOccurrences(of: "{$key}", with: value)
            expanded = expanded.replacingOccurrences(of: "%7B\(key)%7D", with: value)
        }
        // APTV / 酷9 常见的模板写法：${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}。
        expanded = expanded.replacingOccurrences(of: "${(b)yyyyMMddHHmmss}", with: startLocal)
        expanded = expanded.replacingOccurrences(of: "${(e)yyyyMMddHHmmss}", with: endLocal)
        expanded = expanded.replacingOccurrences(of: "{(b)yyyyMMddHHmmss}", with: startLocal)
        expanded = expanded.replacingOccurrences(of: "{(e)yyyyMMddHHmmss}", with: endLocal)
        expanded = expanded.replacingOccurrences(of: "&amp;", with: "&")

        guard let url = URL(string: expanded) else { return nil }
        if url.scheme == nil,
           let base = URL(string: channel.streamURL),
           let resolved = URL(string: expanded, relativeTo: base)?.absoluteURL {
            return resolved
        }
        return url
    }

    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = timeZone
        return formatter
    }
}
