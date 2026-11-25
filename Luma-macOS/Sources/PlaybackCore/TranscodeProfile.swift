import CoreGraphics
import Foundation

/// 边下边播 / 离线转码的编码档位：输出分辨率上限与码率由「源分辨率 × 帧率」推导。
///
/// 决定降档的是**像素率**（宽 × 高 × 帧率），不是分辨率：HDR 色调映射走 GPU（libplacebo），
/// 4K60 的像素率是 4K24 的 2.5 倍，实测已经贴近实时；4K24 则还有近 3 倍余量。
///
/// 本机实测基线（M5 基础款，4K60 HEVC → libplacebo bt.2390 → H.264 VideoToolbox，10s 素材）：
/// - 4K 输出：8.6s（≈1.16× 实时，容易周期性缓冲）
/// - 1440p：5.8s（≈1.74× 实时）
/// - 1080p：5.1s（≈1.96×，其中解码 + 映射就占满了，编码几乎免费）
///
/// 因此把输出压在约 2.5 亿像素/秒以内：4K30 及以下保持原分辨率，4K50 / 4K60 降到 1440p 或更低。
public struct TranscodeProfile: Equatable, Sendable {
    /// 输出像素尺寸；nil 表示保持源分辨率。
    public var outputSize: CGSize?
    /// 目标码率（bps）。
    public var bitrate: Int
    /// 输出编码。HEVC 使用同一张码率表：同码率下画质更高，不做额外压缩。
    public var codec: TranscodeVideoCodec

    public var maxrate: Int { Int(Double(bitrate) * 1.35) }
    public var bufsize: Int { bitrate * 2 }

    /// 编码器的像素格式：HEVC 用 10-bit，H.264 用 8-bit 4:2:0。
    public var pixelFormat: String { codec == .hevc ? "p010le" : "yuv420p" }

    /// 输出像素率上限。超过它就说明「解码 + 映射 + 编码」已经吃满一台基础款 Mac。
    public static let pixelRateCeiling = 250_000_000.0
    /// 可选的输出高度阶梯（保持源宽高比）。
    private static let heightSteps = [2160, 1600, 1440, 1200, 1080, 720]

    /// 帧率未知时按 30fps 估算：4K30 不会降档，4K60 会降档，取偏保守的中间值。
    private static let assumedFrameRate = 30.0

    public init(outputSize: CGSize? = nil, bitrate: Int, codec: TranscodeVideoCodec = .h264) {
        self.outputSize = outputSize
        self.bitrate = bitrate
        self.codec = codec
    }

    public static func make(sourceSize: CGSize, frameRate: Double,
                            transcodeMode: VideoTranscodeMode = .compatibility) -> TranscodeProfile {
        let codec: TranscodeVideoCodec = transcodeMode.usesHEVC ? .hevc : .h264
        let width = Int(sourceSize.width.rounded())
        let height = Int(sourceSize.height.rounded())
        guard width > 0, height > 0 else {
            // 尺寸未知（列表元数据缺失）：用 1080p 档位，宁可清楚一点也不要跑不动。
            return TranscodeProfile(bitrate: bitrate(forHeight: 1080), codec: codec)
        }
        let fps = frameRate > 0 ? frameRate : assumedFrameRate
        let pixelRate = Double(width) * Double(height) * fps

        guard pixelRate > pixelRateCeiling else {
            return TranscodeProfile(bitrate: bitrate(forHeight: height), codec: codec)
        }

        // 从高到低找第一个满足像素率上限的输出高度；都不满足就用最低档。
        var chosen = heightSteps.last ?? 720
        for candidate in heightSteps where candidate < height {
            let scaledWidth = evenWidth(sourceWidth: width, sourceHeight: height, outputHeight: candidate)
            if Double(scaledWidth) * Double(candidate) * fps <= pixelRateCeiling {
                chosen = candidate
                break
            }
        }
        let outputHeight = min(chosen, height)
        guard outputHeight < height else {
            return TranscodeProfile(bitrate: bitrate(forHeight: height), codec: codec)
        }
        let outputWidth = evenWidth(sourceWidth: width, sourceHeight: height, outputHeight: outputHeight)
        return TranscodeProfile(outputSize: CGSize(width: outputWidth, height: outputHeight),
                                bitrate: bitrate(forHeight: outputHeight),
                                codec: codec)
    }

    /// 按输出高度给 H.264 VideoToolbox 的目标码率；SDR 映射后的画面用这个档位足够。
    public static func bitrate(forHeight height: Int) -> Int {
        switch height {
        case 2000...: return 20_000_000
        case 1400..<2000: return 12_000_000
        case 1000..<1400: return 8_000_000
        default: return 5_000_000
        }
    }

    private static func evenWidth(sourceWidth: Int, sourceHeight: Int, outputHeight: Int) -> Int {
        let scaled = Double(sourceWidth) * Double(outputHeight) / Double(sourceHeight)
        return max(2, Int(scaled.rounded()) & ~1)
    }
}
