import Foundation

/// 网络缓冲档位：统一控制播放器前向缓冲、ffmpeg 生成速度和远端 Range 预取。
///
/// 三档不是画质档位，而是「起播速度、卡顿概率、带宽 / 内存占用」的取舍：
/// 流畅档会把前向缓冲拉到 16 秒、远端按 10× 生成，尽量不让播放器等数据。
public enum BufferProfile: String, CaseIterable, Identifiable, Sendable {
    /// 省流量：缓冲最短、预取最少。
    case thrifty
    /// 均衡：默认的前向缓冲 8 秒。
    case balanced
    /// 流畅：缓冲最长、预取最多，优先保证连续播放。
    case smooth

    public var id: String { rawValue }

    /// App 默认档位：流畅。
    public static let defaultProfile: BufferProfile = .smooth

    public var title: String {
        switch self {
        case .thrifty: return "省流"
        case .balanced: return "均衡"
        case .smooth: return "流畅"
        }
    }

    public var detail: String {
        switch self {
        case .thrifty:
            return "前向缓冲 4 秒、预取最少，流量与内存占用最低；适合热点或弱网。"
        case .balanced:
            return "前向缓冲 8 秒、远端按 6× 生成，兼顾起播速度与稳定性。"
        case .smooth:
            return "前向缓冲 16 秒、远端按 10× 预读，优先保证连续播放；占用更多带宽与内存。"
        }
    }

    /// AVPlayer 前向缓冲秒数。
    public var forwardBufferDuration: Double {
        switch self {
        case .thrifty: return 4
        case .balanced: return 8
        case .smooth: return 16
        }
    }

    /// 远端输入交给 ffmpeg 的 readrate（相对实时的生成倍率）。
    public var remoteReadRate: Int {
        switch self {
        case .thrifty: return 3
        case .balanced: return 6
        case .smooth: return 10
        }
    }

    /// 远端 Range 代理的并行预取窗口。
    public var prefetchWindow: Int {
        switch self {
        case .thrifty: return 3
        case .balanced: return 6
        case .smooth: return 8
        }
    }

    /// 远端 Range 代理保留的分块数。
    public var retainedChunks: Int64 {
        switch self {
        case .thrifty: return 4
        case .balanced: return 8
        case .smooth: return 12
        }
    }

    /// 远端 Range 代理同时在途的下载上限。
    public var maxParallelChunks: Int {
        switch self {
        case .thrifty: return 3
        case .balanced: return 6
        case .smooth: return 8
        }
    }

    /// 远端 Range 代理的分块大小。
    public var chunkSize: Int64 {
        switch self {
        case .thrifty: return 4 * 1024 * 1024
        case .balanced: return 8 * 1024 * 1024
        case .smooth: return 16 * 1024 * 1024
        }
    }

    /// 档位高低：用于网络自适应时判断能否继续降 / 升。
    public var rank: Int {
        switch self {
        case .thrifty: return 0
        case .balanced: return 1
        case .smooth: return 2
        }
    }

    /// 降一档；已经在省流时返回 nil。
    public func downgraded() -> BufferProfile? {
        switch self {
        case .thrifty: return nil
        case .balanced: return .thrifty
        case .smooth: return .balanced
        }
    }

    /// 升一档；已经在流畅时返回 nil。
    public func upgraded() -> BufferProfile? {
        switch self {
        case .thrifty: return .balanced
        case .balanced: return .smooth
        case .smooth: return nil
        }
    }
}
