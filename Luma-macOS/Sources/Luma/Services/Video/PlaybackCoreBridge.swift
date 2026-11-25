import Foundation
import PlaybackCore

// MARK: - 播放内核类型桥接
//
// 播放内核已经独立成 `PlaybackCore` target。App 侧保留同名类型别名，
// 这样现有调用点（ViewerModel / LibraryStore / SwiftUI 视图）不需要逐个改 import。

typealias VideoPlayerModel = PlaybackCore.VideoPlayerModel
typealias VideoStreamSession = PlaybackCore.VideoStreamSession
typealias VideoError = PlaybackCore.VideoError
typealias VideoProbe = PlaybackCore.VideoProbe
typealias VideoColorInfo = PlaybackCore.VideoColorInfo
typealias AudioTrackInfo = PlaybackCore.AudioTrackInfo
typealias VideoChapter = PlaybackCore.VideoChapter
typealias SubtitleCue = PlaybackCore.SubtitleCue
typealias SubtitleCueStyle = PlaybackCore.SubtitleCueStyle
typealias SubtitleColor = PlaybackCore.SubtitleColor
typealias SubtitleTrackInfo = PlaybackCore.SubtitleTrackInfo
typealias PlaybackTimeline = PlaybackCore.PlaybackTimeline
typealias BufferProfile = PlaybackCore.BufferProfile
typealias AudioDownmixMode = PlaybackCore.AudioDownmixMode
typealias VideoTranscodeMode = PlaybackCore.VideoTranscodeMode
typealias VideoFramingMode = PlaybackCore.VideoFramingMode
typealias VideoAspectPreset = PlaybackCore.VideoAspectPreset

// MARK: - 内核依赖注入

extension PlaybackEnvironment {
    /// App 侧唯一的注入点：把图库路径、内置 ffmpeg、诊断日志与缓存策略交给内核。
    static var luma: PlaybackEnvironment {
        PlaybackEnvironment(
            cache: .luma,
            ffmpeg: FFmpeg.executable,
            ffmpegForToneMap: FFmpeg.toneMapExecutable,
            ffmpegForDolbyVision: FFmpeg.libplaceboExecutable,
            ffprobe: FFmpeg.probe,
            supportsToneMapping: VideoSupport.supportsToneMapping,
            supportsLibplacebo: FFmpeg.supportsLibplacebo,
            processEnvironment: FFmpeg.processEnvironment,
            bufferProfile: { AppSettings.shared.videoBufferProfile },
            adaptiveBuffering: { AppSettings.shared.videoAdaptiveBuffering },
            record: { Diagnostics.record($0) })
    }
}

extension PlaybackCache {
    /// 图库转码目录 + 设置里的缓存上限。
    static var luma: PlaybackCache {
        PlaybackCache(
            root: LibraryPaths.transcodes,
            limitBytes: { Int64(max(0, AppSettings.shared.videoCacheLimitGB)) * 1_000_000_000 })
    }
}

/// App 侧的缓存门面：设置页 / 维护任务只依赖这个入口，不直接碰内核类型。
enum VideoCache {
    static var luma: PlaybackCache { .luma }
}

extension PlaybackCore.VideoStreamSession {
    /// 当前播放策略签名：进入缓存目录名。分片内容只在这些策略下会变化。
    /// 以后新增滤镜 / 画面策略时，把它加进签名或把 `cacheKeyVersion` +1。
    static var lumaCacheSignature: String {
        let settings = AppSettings.shared
        // 逐项拼接再 join：一次性长表达式会让 Swift 类型检查超时。
        var parts = ["v\(cacheKeyVersion)"]
        parts.append(settings.instantAudioSwitch ? "am" : "as")
        parts.append(settings.videoHDRMode.rawValue.lowercased())
        parts.append(settings.audioDownmix.rawValue)
        parts.append(settings.videoTranscodeMode.rawValue)
        return parts.joined(separator: "-")
    }
}
