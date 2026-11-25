import Foundation

/// JPEG 无损优化的纯字节逻辑：只剥离元数据段，压缩数据原样保留，像素完全不变。
/// 放在 LumaCore 便于用 `swift run LumaCoreChecks` 直接断言。
public enum JPEGMetadataStripper {
    /// 需要丢弃的标记：APP1（EXIF / XMP）、APP13（IPTC）与 COM 注释。
    private static let removableMarkers: Set<UInt8> = [0xE1, 0xED, 0xFE]

    /// 按 JPEG 段结构重建文件；输入不是合法 JPEG 或段结构异常时返回 nil。
    public static func strip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var output = Data(capacity: bytes.count)
        output.append(contentsOf: bytes[0...1])

        var index = 2
        while index < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            // 标记前允许出现多个 0xFF 填充字节。
            var markerPos = index + 1
            while markerPos < bytes.count, bytes[markerPos] == 0xFF { markerPos += 1 }
            guard markerPos < bytes.count else { return nil }
            let marker = bytes[markerPos]

            // SOS 之后是熵编码数据，原样复制到文件末尾（含 EOI）。
            if marker == 0xDA || marker == 0xD9 {
                output.append(contentsOf: bytes[index..<bytes.count])
                return output
            }
            // 无长度字段的独立标记。
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                output.append(contentsOf: bytes[index...markerPos])
                index = markerPos + 1
                continue
            }

            guard markerPos + 2 < bytes.count else { return nil }
            let length = Int(bytes[markerPos + 1]) << 8 | Int(bytes[markerPos + 2])
            guard length >= 2, markerPos + 1 + length <= bytes.count else { return nil }
            if !removableMarkers.contains(marker) {
                output.append(contentsOf: bytes[index..<(markerPos + 1 + length)])
            }
            index = markerPos + 1 + length
        }
        return nil
    }
}
