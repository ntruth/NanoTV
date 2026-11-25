import Foundation

/// HTTP `Range: bytes=...` 的解析结果。
///
/// 只处理播放器 / ffmpeg 实际会发的形态，并取第一段（多段 Range 基本不出现）：
/// - `bytes=start-end`
/// - `bytes=start-`（到文件末尾）
/// - `bytes=-suffix`（最后 N 字节；支持它是为了不把 ffmpeg 的尾部探测误当成从头读）
public struct HTTPByteRange: Equatable, Sendable {
    public var start: Int64
    /// nil 表示一直到文件末尾。
    public var end: Int64?
    public var isSuffix: Bool

    public init(start: Int64, end: Int64?, isSuffix: Bool = false) {
        self.start = start
        self.end = end
        self.isSuffix = isSuffix
    }

    /// - Parameters:
    ///   - header: 完整请求行（`Range: bytes=...`）或只有 `bytes=...`。
    ///   - total: 上游文件总长度；未知时不要调用。
    public static func parse(_ header: String?, total: Int64) -> HTTPByteRange? {
        guard total > 0, var value = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("range:") {
            value = String(value.dropFirst("range:".count))
                .trimmingCharacters(in: .whitespaces)
        }
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        value = String(value.dropFirst("bytes=".count))
        // 多段 Range 只认第一段。
        let first = value.split(separator: ",").first.map(String.init) ?? ""
        let bounds = first.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count <= 2 else { return nil }

        if bounds.count == 1 {
            // 只有 "N"，按规范等同于 "N-"。
            guard let start = Int64(bounds[0]), start >= 0, start < total else { return nil }
            return HTTPByteRange(start: start, end: nil)
        }

        let startText = bounds[0].trimmingCharacters(in: .whitespaces)
        let endText = bounds[1].trimmingCharacters(in: .whitespaces)
        if startText.isEmpty {
            // suffix：最后 N 字节。
            guard let length = Int64(endText), length > 0 else { return nil }
            let start = max(0, total - length)
            return HTTPByteRange(start: start, end: total - 1, isSuffix: true)
        }
        guard let start = Int64(startText), start >= 0, start < total else { return nil }
        if endText.isEmpty {
            return HTTPByteRange(start: start, end: nil)
        }
        guard let requestedEnd = Int64(endText), requestedEnd >= start else { return nil }
        return HTTPByteRange(start: start, end: min(requestedEnd, total - 1))
    }
}
