import Foundation

/// 缩略图尺寸策略：把请求像素收敛到固定档位，供内存/磁盘缓存共用。
public enum ThumbnailSizing {
    /// 网格解码档位，按从小到大排列。
    public static let buckets: [Int] = [128, 192, 256, 384, 512, 768, 1024]

    /// 网格快速层（先出低清再升级）。
    public static let quickPixel = 192

    /// 向上取整到最近的档位，超出上限时取最大档。
    public static func bucket(for maxPixel: CGFloat) -> Int {
        let target = Int(maxPixel.rounded(.up))
        return buckets.first { $0 >= target } ?? buckets[buckets.count - 1]
    }
}
