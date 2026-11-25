import Foundation

/// 播放生命周期钩子：影院 / 目录的续播、片头、片尾、进度与预热都通过它注入内核。
/// 内核只负责「什么时候调用」，具体存哪里、怎么识别片头由 App 实现。
@MainActor
public protocol PlaybackHooks: AnyObject {
    /// 起播位置（完整时间轴）；nil 表示从头。
    func resumePosition(for photoID: UUID) -> Double?
    /// 续播位置已经被消费：目录的「本次从第几秒开始」只生效一次。
    func resumeConsumed(for photoID: UUID)
    /// 续播位置是否来自「上次看到一半」的进度（而不是片头）。
    /// 片头识别只会在真正续播时停手；从片头起播仍允许在线结果修正。
    func hasResumeProgress(for photoID: UUID) -> Bool
    /// 片头秒数：没有续播时，首帧后自动跳过。
    func introSeconds(for photoID: UUID) -> Double
    /// 片尾秒数：剩余时间进入该区间时直接跳到结尾。
    func outroSeconds(for photoID: UUID) -> Double
    /// 进度变化（约 10 秒一次）。
    func playbackProgress(photoID: UUID, position: Double, duration: Double)
    /// 接近片尾（剩余 5 分钟），用于预热下一集。
    func playbackNearEnd(photoID: UUID)
    /// 播放结束 / 跳片尾。
    func playbackFinished(photoID: UUID, position: Double, duration: Double)
}

public extension PlaybackHooks {
    func resumePosition(for photoID: UUID) -> Double? { nil }
    func resumeConsumed(for photoID: UUID) {}
    func hasResumeProgress(for photoID: UUID) -> Bool { false }
    func introSeconds(for photoID: UUID) -> Double { 0 }
    func outroSeconds(for photoID: UUID) -> Double { 0 }
    func playbackProgress(photoID: UUID, position: Double, duration: Double) {}
    func playbackNearEnd(photoID: UUID) {}
    func playbackFinished(photoID: UUID, position: Double, duration: Double) {}
}
