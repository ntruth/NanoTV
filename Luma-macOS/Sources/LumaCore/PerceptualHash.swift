import Foundation

/// 64 位 dHash：把 9×8 灰度缩略图转成“相邻像素亮度是否递增”的位图。
/// 纯算法，不依赖 CoreGraphics；App 侧负责把图片采样成 9×8 灰度。
public enum PerceptualHash {
    public static let width = 9
    public static let height = 8

    /// - Parameter grayscale: 行优先的 9×8 灰度值（0–255），长度必须为 72。
    public static func dHash(grayscale: [UInt8]) -> Int64? {
        guard grayscale.count >= width * height else { return nil }
        var bits: UInt64 = 0
        var index = 0
        for row in 0..<height {
            let base = row * width
            for column in 0..<(width - 1) {
                let left = grayscale[base + column]
                let right = grayscale[base + column + 1]
                if left > right {
                    bits |= (UInt64(1) << UInt64(index))
                }
                index += 1
            }
        }
        return Int64(bitPattern: bits)
    }

    public static func hammingDistance(_ lhs: Int64, _ rhs: Int64) -> Int {
        (UInt64(bitPattern: lhs) ^ UInt64(bitPattern: rhs)).nonzeroBitCount
    }

    /// 64 位里允许的差异位数；默认 10 位，能覆盖重压缩 / 缩放，但不至于把不同照片混在一起。
    public static func isSimilar(_ lhs: Int64, _ rhs: Int64, threshold: Int = 10) -> Bool {
        hammingDistance(lhs, rhs) <= max(0, min(64, threshold))
    }
}
