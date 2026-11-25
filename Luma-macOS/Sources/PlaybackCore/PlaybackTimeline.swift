import Foundation

/// 播放时间轴：会话内时间（AVPlayer 的 0 点）与完整片源时间之间的唯一换算入口。
///
/// 边下边播 / 跳片头 / 续播都会让会话从片源中间起流，播放器看到的 0 秒并不是片源的 0 秒。
/// 之前这套换算散落在播放器、播放页和路由闭包里，任何一处漏改都会造成进度或跳转偏差。
public struct PlaybackTimeline: Equatable, Sendable {
    /// 会话 0 点对应的片源秒数。
    public var sessionStart: Double

    public init(sessionStart: Double = 0) {
        self.sessionStart = max(0, sessionStart)
    }

    /// 会话内时间 → 完整时间轴。
    public func absolute(local: Double) -> Double {
        max(0, local + sessionStart)
    }

    /// 完整时间轴 → 会话内时间。
    public func local(absolute: Double) -> Double {
        max(0, absolute - sessionStart)
    }

    /// 把目标秒数夹到 [会话起点, 总时长]。
    public func clamp(_ value: Double, duration: Double) -> Double {
        // NaN / 无穷大不能进时间轴：会让进度条宽度、AVPlayer seek 一起失效。
        guard value.isFinite else { return sessionStart }
        let lower = sessionStart
        let upper = duration > 0 ? max(lower, duration) : max(lower, value)
        return min(max(value, lower), upper)
    }
}
