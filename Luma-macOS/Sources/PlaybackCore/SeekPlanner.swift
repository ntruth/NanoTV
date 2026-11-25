import Foundation

/// 跳转决策：是让 AVPlayer 在当前 HLS 会话里 seek，还是重启 ffmpeg 重新起流。
/// 决策只依赖时间轴窗口，和 SwiftUI / 播放页状态无关，便于单测。
public enum SeekPlanner {
    public enum Decision: Equatable {
        /// 目标仍在当前会话已生成 / 已保留的区间内，直接 seek。
        case inSession
        /// 目标早于已删除分片或晚于已生成末尾，需要重建流。
        case restart
    }

    /// - Parameters:
    ///   - target: 完整时间轴上的目标秒数。
    ///   - retainedStart: 当前会话仍保留的最早分片起点（完整时间轴）。
    ///   - generatedEnd: 当前会话已生成到的末尾（完整时间轴）。
    ///   - isCompleteCache: 是否在播放完整 HLS 缓存（整部片都可直接 seek）。
    ///   - backwardSlack: 允许回退到保留窗口之前多少秒（避免临界抖动）。
    ///   - forwardSlack: 允许向前超出已生成末尾多少秒。
    public static func decide(target: Double,
                              retainedStart: Double,
                              generatedEnd: Double,
                              isCompleteCache: Bool,
                              backwardSlack: Double = 1,
                              forwardSlack: Double = 8) -> Decision {
        if isCompleteCache { return .inSession }
        if target < retainedStart - backwardSlack { return .restart }
        if target > generatedEnd + forwardSlack { return .restart }
        return .inSession
    }
}
