import Foundation
import PlaybackCore

/// 查看器 / 编辑器状态：与图库内容状态分离，翻页和打开编辑不会触发图库整体刷新。
@MainActor
final class ViewerModel: ObservableObject {
    @Published var viewerID: UUID?
    @Published var editorID: UUID?
    @Published var showInfoPanel = false
    /// 视频全屏沉浸：进入系统全屏时隐藏侧边栏与窗口工具栏，退出后恢复原状。
    @Published var videoImmersiveFullScreen = false
    /// 视频播放状态：与查看器同生命周期，窗口工具栏与画面共用同一份播放状态。
    let videoPlayer: VideoPlayerModel
    /// 播放编排：起流 / 降级 / seek 重建 / 分片回收都收在内核里。
    let playbackSession: PlaybackSession
    /// 视频手动旋转角度：画面、顶栏按钮与「视频」菜单共用。
    @Published var videoQuarterTurns = 0
    /// 电视节目单抽屉：窗口工具栏与画面内 OSD 共用同一份开合状态。
    @Published var tvGuideShown = false
    /// 电视时移：暂停直播后回看刚过去的画面；窗口工具栏与画面 OSD 共用。
    @Published var tvTimeshiftActive = false
    /// 睡眠定时剩余分钟：nil 表示未开启；窗口工具栏与画面 OSD 共用。
    @Published var tvSleepMinutes: Int?
    /// 睡眠定时任务：到点前渐隐音量再暂停。
    private var tvSleepTask: Task<Void, Never>?
    /// 音轨 / 字幕状态：顶栏、画面内控制条与「视频」菜单共用同一份。
    let videoPlaybackUI = VideoPlaybackUI()

    init() {
        let player = VideoPlayerModel()
        videoPlayer = player
        playbackSession = PlaybackSession(engine: player, environment: .luma)
    }

    // MARK: - 电视直播：时移 / 睡眠

    /// 睡眠定时：30 / 60 / 90 分钟后渐隐音量并暂停。
    func startTVSleepTimer(minutes: Int) {
        cancelTVSleepTimer()
        tvSleepMinutes = minutes
        tvSleepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = minutes * 60
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
                if remaining <= 5 { break }
            }
            guard !Task.isCancelled else { return }
            let original = self.videoPlayer.volume
            for step in 1...5 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled {
                    self.videoPlayer.volume = original
                    return
                }
                self.videoPlayer.volume = original * Double(5 - step) / 5
            }
            self.videoPlayer.pause()
            self.videoPlayer.volume = original
            self.tvSleepMinutes = nil
        }
    }

    func cancelTVSleepTimer() {
        tvSleepTask?.cancel()
        tvSleepTask = nil
        tvSleepMinutes = nil
    }

    // MARK: - 连拍快照
    //
    // 官方「照片」打开连拍代表图后就进入整组浏览：这里保存当前组（按拍摄时间升序），
    // 查看器的序号、胶片条、播放与选择都基于它；组为空时按普通照片浏览。
    @Published var burstMembers: [PhotoItem] = []
    /// 正在按帧连播组内照片。
    @Published var burstPlaying = false
    /// 「进行选择…」的组内选择模式。
    @Published var burstSelectionMode = false
    @Published var burstSelection: Set<UUID> = []
}
