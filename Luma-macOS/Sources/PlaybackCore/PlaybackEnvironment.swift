import Foundation

/// 播放内核的外部依赖：由 App 注入，内核本身不读 UserDefaults / 图库路径 / 全局日志。
public struct PlaybackEnvironment {
    /// 转封装缓存：目录、容量上限与清理策略都在这里。
    public var cache: PlaybackCache
    /// 常规 ffmpeg 可执行文件。
    public var ffmpeg: URL?
    /// 带 zscale / tonemap 的 ffmpeg（HDR 色调映射时优先）。
    public var ffmpegForToneMap: URL?
    /// 带 libplacebo 的 ffmpeg：杜比视界的 DOVI RPU 只有它能应用。
    public var ffmpegForDolbyVision: URL?
    /// ffprobe 可执行文件。
    public var ffprobe: URL?
    /// 当前 ffmpeg 是否支持 HDR 色调映射。
    public var supportsToneMapping: Bool
    /// 当前 ffmpeg 是否带 libplacebo（杜比视界的色调映射依赖它）。
    public var supportsLibplacebo: Bool
    /// 诊断日志。
    public var record: (String) -> Void
    /// 子进程额外需要注入的环境变量（如内置 MoltenVK 的 ICD 路径）。
    public var processEnvironment: [String: String]
    /// 网络缓冲档位的实时读取入口：设置页改动后无需重启 App，下次起流即生效。
    public var bufferProfile: BufferProfile { bufferProfileProvider() }
    private let bufferProfileProvider: () -> BufferProfile
    /// 远端弱网自适应是否开启：关闭后固定使用所选档位。
    public var adaptiveBuffering: Bool { adaptiveBufferingProvider() }
    private let adaptiveBufferingProvider: () -> Bool

    /// 转封装结果的根目录（对应图库里的 resources/transcodes）。
    public var cacheDirectory: URL { cache.root }

    public init(cache: PlaybackCache,
                ffmpeg: URL?,
                ffmpegForToneMap: URL?,
                ffmpegForDolbyVision: URL? = nil,
                ffprobe: URL?,
                supportsToneMapping: Bool,
                supportsLibplacebo: Bool = false,
                processEnvironment: [String: String] = [:],
                bufferProfile: @escaping () -> BufferProfile = { .defaultProfile },
                adaptiveBuffering: @escaping () -> Bool = { false },
                record: @escaping (String) -> Void) {
        self.cache = cache
        self.ffmpeg = ffmpeg
        self.ffmpegForToneMap = ffmpegForToneMap
        self.ffmpegForDolbyVision = ffmpegForDolbyVision
        self.ffprobe = ffprobe
        self.supportsToneMapping = supportsToneMapping
        self.supportsLibplacebo = supportsLibplacebo
        self.processEnvironment = processEnvironment
        self.bufferProfileProvider = bufferProfile
        self.adaptiveBufferingProvider = adaptiveBuffering
        self.record = record
    }

    /// 给子进程注入额外环境变量（保留 App 自身环境）。
    public func apply(to process: Process) {
        guard !processEnvironment.isEmpty else { return }
        process.environment = ProcessInfo.processInfo.environment
            .merging(processEnvironment) { _, new in new }
    }

    public func executable(preferToneMap: Bool, preferLibplacebo: Bool = false) -> URL? {
        if preferToneMap, preferLibplacebo, let ffmpegForDolbyVision { return ffmpegForDolbyVision }
        if preferToneMap, let ffmpegForToneMap { return ffmpegForToneMap }
        return ffmpeg
    }
}
