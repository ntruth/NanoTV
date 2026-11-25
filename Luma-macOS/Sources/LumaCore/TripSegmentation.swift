import Foundation

/// 「同一地点 + 连续日期」行程分段：纯整数运算，便于单测。
public enum TripSegmentation {
    /// 把按拍摄时间升序排列的照片切成若干段。
    /// - Parameters:
    ///   - placeKeys: 每张照片的地点键
    ///   - dayOrdinals: 与 `placeKeys` 一一对应的「天序号」（同一天返回同一个数）
    ///   - maxGapDays: 相邻两张照片的日期差超过该值就另起一段（默认 1 天，即隔天即分段）
    /// - Returns: 每段在原数组中的闭区间
    public static func spans(placeKeys: [String],
                             dayOrdinals: [Int],
                             maxGapDays: Int = 1) -> [ClosedRange<Int>] {
        guard placeKeys.count == dayOrdinals.count, !placeKeys.isEmpty else { return [] }
        var spans: [ClosedRange<Int>] = []
        var start = 0
        for index in 1..<placeKeys.count {
            let gap = dayOrdinals[index] - dayOrdinals[index - 1]
            if placeKeys[index] != placeKeys[index - 1] || gap > maxGapDays {
                spans.append(start...(index - 1))
                start = index
            }
        }
        spans.append(start...(placeKeys.count - 1))
        return spans
    }
}
