import Foundation

/// 瀑布流一行里的一张照片：原始下标与最终尺寸。
public struct JustifiedLayoutItem: Equatable {
    public let index: Int
    public let width: CGFloat
    public let height: CGFloat

    public init(index: Int, width: CGFloat, height: CGFloat) {
        self.index = index
        self.width = width
        self.height = height
    }
}

/// 网格布局纯计算：不依赖 SwiftUI / 模型，便于单测。
public enum GridLayout {
    /// 正方形网格：按容器宽度和目标格子尺寸计算列数。
    public static func columns(contentWidth: CGFloat, targetSize: CGFloat, spacing: CGFloat) -> Int {
        guard targetSize + spacing > 0 else { return 1 }
        return max(1, Int((contentWidth + spacing) / (targetSize + spacing)))
    }

    /// 正方形网格：列数确定后每个格子的边长。
    public static func squareCellWidth(contentWidth: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
        guard columns > 0 else { return contentWidth }
        return (contentWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    /// 瀑布流：按宽高比把照片切成一行行，行高尽量贴近目标高度。
    public static func justifiedRows(aspects: [CGFloat],
                                     width: CGFloat,
                                     targetHeight: CGFloat,
                                     spacing: CGFloat,
                                     maxPerRow: Int = 8) -> [[JustifiedLayoutItem]] {
        guard !aspects.isEmpty else { return [] }
        var rows: [[JustifiedLayoutItem]] = []
        var current: [Int] = []
        var aspectSum: CGFloat = 0

        func flush(fill: Bool) {
            guard !current.isEmpty else { return }
            let available = width - spacing * CGFloat(current.count - 1)
            var height = available / max(aspectSum, 0.1)
            if !fill {
                height = targetHeight
                if current.count == 1 {
                    let singleWidth = height * clampedAspect(aspects[current[0]])
                    if singleWidth > width {
                        height = width / clampedAspect(aspects[current[0]])
                    }
                }
            }
            rows.append(current.map { index in
                JustifiedLayoutItem(index: index,
                                    width: height * clampedAspect(aspects[index]),
                                    height: height)
            })
            current = []
            aspectSum = 0
        }

        for (index, aspect) in aspects.enumerated() {
            current.append(index)
            aspectSum += clampedAspect(aspect)
            let available = width - spacing * CGFloat(current.count - 1)
            let height = available / max(aspectSum, 0.1)
            if height <= targetHeight || current.count >= maxPerRow {
                flush(fill: true)
            }
        }
        flush(fill: false)
        return rows
    }

    /// 瀑布流：按宽高比把照片装进「当前最矮」的一列，返回每列的照片下标。
    public static func masonryColumns(aspects: [CGFloat], columns: Int) -> [[Int]] {
        guard columns > 0 else { return [] }
        var buckets = Array(repeating: [Int](), count: columns)
        var heights = Array(repeating: CGFloat.zero, count: columns)
        for (index, aspect) in aspects.enumerated() {
            // 列宽固定，列高增量与 1/宽高比 成正比。
            let target = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            buckets[target].append(index)
            heights[target] += 1 / clampedAspect(aspect)
        }
        return buckets
    }

    private static func clampedAspect(_ aspect: CGFloat) -> CGFloat {
        min(4, max(0.2, aspect))
    }
}
