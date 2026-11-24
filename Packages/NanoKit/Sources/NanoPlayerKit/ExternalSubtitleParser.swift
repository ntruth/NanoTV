import Foundation

public struct SubtitleCueItem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let startSec: Double
    public let endSec: Double
    public let text: String

    public init(startSec: Double, endSec: Double, text: String) {
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
    }
}

/// 原生外挂字幕解析器（同时兼容 `.srt`、`.vtt` 与 `.ass` / `.ssa` 对白行提取）
public struct ExternalSubtitleParser: Sendable {
    public static func parse(content: String, fileExtension: String) -> [SubtitleCueItem] {
        let ext = fileExtension.lowercased()
        if ext == "ass" || ext == "ssa" || content.contains("[Events]") {
            return parseASS(content)
        }
        return parseSRTorVTT(content)
    }

    public static func activeSubtitleText(in cues: [SubtitleCueItem], at playbackSec: Double, delaySec: Double = 0) -> String? {
        let adjusted = playbackSec - delaySec
        guard let hit = cues.first(where: { adjusted >= $0.startSec && adjusted <= $0.endSec }) else {
            return nil
        }
        return hit.text
    }

    private static func parseSRTorVTT(_ raw: String) -> [SubtitleCueItem] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var items: [SubtitleCueItem] = []

        for block in blocks {
            let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let arrowIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeLine = lines[arrowIdx]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1]) else { continue }

            let textLines = lines.dropFirst(arrowIdx + 1)
            let cleanedText = textLines.joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\{[^\\}]+\\}", with: "", options: .regularExpression)
            if !cleanedText.isEmpty {
                items.append(SubtitleCueItem(startSec: start, endSec: end, text: cleanedText))
            }
        }
        return items.sorted { $0.startSec < $1.startSec }
    }

    private static func parseASS(_ raw: String) -> [SubtitleCueItem] {
        var items: [SubtitleCueItem] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Dialogue:") else { continue }
            let payload = line.dropFirst("Dialogue:".count)
            let cols = payload.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 10,
                  let start = parseTimestamp(cols[1]),
                  let end = parseTimestamp(cols[2]) else { continue }
            let rawText = cols[9]
                .replacingOccurrences(of: "\\{[^\\}]+\\}", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawText.isEmpty {
                items.append(SubtitleCueItem(startSec: start, endSec: end, text: rawText))
            }
        }
        return items.sorted { $0.startSec < $1.startSec }
    }

    private static func parseTimestamp(_ raw: String) -> Double? {
        let token = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").compactMap { Double($0) }
        if parts.count == 3 {
            return parts[0] * 3600.0 + parts[1] * 60.0 + parts[2]
        } else if parts.count == 2 {
            return parts[0] * 60.0 + parts[1]
        }
        return nil
    }
}
