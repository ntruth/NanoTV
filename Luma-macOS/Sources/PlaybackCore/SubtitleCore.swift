import Foundation

/// 字幕颜色：0…1 的 RGBA。ASS 的 `&HAABBGGRR&` 会被转换成同一表示。
public struct SubtitleColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
        self.alpha = min(1, max(0, alpha))
    }

    /// 解析 ASS / SSA 的 `&HAABBGGRR&`（AA 可省略，末尾 `&` 可省略）。
    public static func parseASS(_ raw: String) -> SubtitleColor? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("-") { text.removeFirst() }
        guard text.count > 2, text.lowercased().hasPrefix("&h") else { return nil }
        text = String(text.dropFirst(2))
        if text.hasSuffix("&") { text.removeLast() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        let blue = Double(value & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let red = Double((value >> 16) & 0xFF) / 255
        // ASS 的 alpha 是「透明度」，0 为不透明。
        let alpha = text.count == 8 ? Double(255 - ((value >> 24) & 0xFF)) / 255 : 1
        return SubtitleColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// 一条字幕的展示样式。来自 ASS / SSA 的样式表与行内覆盖标签；
/// 普通 SRT / VTT 为 nil，播放器沿用用户设置。
public struct SubtitleCueStyle: Equatable, Sendable {
    /// ASS 的 Fontsize，用于按 1080p 基准换算倍率。
    public var fontSize: Double?
    public var bold = false
    public var italic = false
    public var primaryColor: SubtitleColor?
    public var outlineColor: SubtitleColor?
    /// ASS 的 `\an` 1…9：1-3 底部、4-6 中部、7-9 顶部。
    public var alignment: Int?
    /// 相对 1080p 的字号倍率。
    public var fontScale: Double {
        guard let fontSize, fontSize > 0 else { return 1 }
        return min(1.9, max(0.6, fontSize / 54))
    }

    /// 相对画面高度的位置：0 顶部、0.5 中部、1 底部。
    public var verticalAnchor: Double {
        guard let alignment else { return 1 }
        switch alignment {
        case 7...9: return 0
        case 4...6: return 0.5
        default: return 1
        }
    }

    public init() {}
}

/// 一条字幕：按完整播放时间轴记录起止秒数。
public struct SubtitleCue: Equatable {
    public let start: Double
    public let end: Double
    public let text: String
    /// ASS / SSA 样式；SRT / VTT 为 nil。
    public let style: SubtitleCueStyle?

    public init(start: Double, end: Double, text: String, style: SubtitleCueStyle? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.style = style
    }
}

/// 外挂 / 内嵌字幕解析：srt / vtt / ass / ssa。
/// ASS 会保留常用样式（颜色、粗斜体、字号、对齐）；复杂特效仍压成纯文本。
public enum SubtitleParser {
    public static let supportedExtensions = ["srt", "vtt", "ass", "ssa"]

    public static func load(url: URL) -> [SubtitleCue] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(text: decode(data), fileExtension: url.pathExtension)
    }

    /// 直接解析文本内容：内嵌字幕提取出的 WebVTT 也走这里。
    public static func parse(text: String, fileExtension: String) -> [SubtitleCue] {
        switch fileExtension.lowercased() {
        case "ass", "ssa":
            return parseASS(text)
        default:
            return parseSRT(text)
        }
    }

    public static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        guard !cues.isEmpty else { return nil }
        // 二分查找：大文件字幕可能有上万条。
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if time < cue.start {
                high = mid - 1
            } else if time > cue.end {
                low = mid + 1
            } else {
                return cue
            }
        }
        return nil
    }

    // MARK: - 解析

    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[timeIndex].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = parseTime(times[0]),
                  let end = parseTime(times[1]) else { continue }
            let body = lines[(timeIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = stripTags(body)
            guard !cleaned.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private struct ASSStyle {
        var fontSize: Double
        var primary: SubtitleColor?
        var outline: SubtitleColor?
        var bold: Bool
        var italic: Bool
        var alignment: Int
    }

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var styles: [String: ASSStyle] = [:]
        var cues: [SubtitleCue] = []
        var inStyles = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inStyles = line.lowercased().contains("styles")
                continue
            }
            if inStyles, line.lowercased().hasPrefix("style:") {
                let body = line.dropFirst("style:".count)
                let fields = body.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // Name,Fontname,Fontsize,Primary,Secondary,Outline,Back,Bold,Italic,...,Alignment,...,MarginV,...
                guard fields.count >= 19 else { continue }
                styles[fields[0]] = ASSStyle(
                    fontSize: Double(fields[2]) ?? 0,
                    primary: SubtitleColor.parseASS(fields[3]),
                    outline: SubtitleColor.parseASS(fields[5]),
                    bold: fields[7] == "1" || fields[7] == "-1",
                    italic: fields[8] == "1" || fields[8] == "-1",
                    alignment: Int(fields[18]) ?? 2)
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            // Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            let body = line.dropFirst("dialogue:".count)
            let fields = body.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard fields.count >= 10,
                  let start = parseTime(String(fields[1])),
                  let end = parseTime(String(fields[2])) else { continue }
            let styleName = String(fields[3]).trimmingCharacters(in: .whitespaces)
            var content = String(fields[9])
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")

            var style = SubtitleCueStyle()
            if let base = styles[styleName] {
                style.fontSize = base.fontSize > 0 ? base.fontSize : nil
                style.bold = base.bold
                style.italic = base.italic
                style.primaryColor = base.primary
                style.outlineColor = base.outline
                style.alignment = base.alignment
            }
            // 行内覆盖：取第一组 `{...}`，覆盖整条字幕的样式（不拆分 runs）。
            if let override = content.range(of: "\\{[^}]*\\}", options: .regularExpression) {
                applyOverrides(String(content[override]).trimmingCharacters(in: CharacterSet(charactersIn: "{}")),
                               to: &style)
            }
            while let range = content.range(of: "\\{[^}]*\\}", options: .regularExpression) {
                content.removeSubrange(range)
            }
            let cleaned = stripTags(content).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned, style: style))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// 解析 ASS 行内覆盖标签的常用子集：`\an` `\b` `\i` `\fs` `\c`。
    private static func applyOverrides(_ raw: String, to style: inout SubtitleCueStyle) {
        if let value = firstMatch(in: raw, pattern: "\\\\an([1-9])"), let number = Int(value) {
            style.alignment = number
        }
        if let value = firstMatch(in: raw, pattern: "\\\\b([01])") {
            style.bold = value == "1"
        }
        if let value = firstMatch(in: raw, pattern: "\\\\i([01])") {
            style.italic = value == "1"
        }
        if let value = firstMatch(in: raw, pattern: "\\\\fs([0-9.]+)"), let number = Double(value), number > 0 {
            style.fontSize = number
        }
        if let value = firstMatch(in: raw, pattern: "\\\\1?c(&H[0-9A-Fa-f]+&?)"),
           let color = SubtitleColor.parseASS(value) {
            style.primaryColor = color
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    /// 支持 `00:00:01,000`、`00:00:01.000` 与 ASS 的 `0:00:01.00`。
    private static func parseTime(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let head = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? text
        let parts = head.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count >= 2 else { return nil }
        var seconds: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        // 上面的循环按“时:分:秒”累乘，parts 为 2 段时等同于“分:秒”。
        return seconds.isFinite ? seconds : nil
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        // 中文外挂字幕常见 GB18030 编码。
        let gb18030 = String.Encoding(rawValue: 0x80000632)
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
