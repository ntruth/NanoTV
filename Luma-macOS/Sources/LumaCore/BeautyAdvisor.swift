import Foundation

/// 一张照片的亮度与色彩统计（全部归一化到 0...1），由 App 侧把缩略图缩到 256×256 后采样得到。
/// 这里只放纯数据与建议映射，便于在 `LumaCoreChecks` 里断言。
public struct BeautyStats: Equatable, Sendable {
    /// 平均亮度（Rec.709 加权）。
    public var luma: Double
    /// 亮度标准差，反映画面对比度。
    public var lumaSpread: Double
    /// 平均饱和度。
    public var saturation: Double
    public var red: Double
    public var green: Double
    public var blue: Double
    /// 接近纯白 / 纯黑的像素占比，用来判断过曝与死黑。
    public var highlightClip: Double
    public var shadowClip: Double
    /// 拉普拉斯方差（清晰度）；0 表示未测量。
    public var sharpness: Double

    public init(luma: Double, lumaSpread: Double, saturation: Double,
                red: Double, green: Double, blue: Double,
                highlightClip: Double, shadowClip: Double, sharpness: Double) {
        self.luma = luma
        self.lumaSpread = lumaSpread
        self.saturation = saturation
        self.red = red
        self.green = green
        self.blue = blue
        self.highlightClip = highlightClip
        self.shadowClip = shadowClip
        self.sharpness = sharpness
    }

    /// 一张「不需要调整」的参考照片：中等亮度、正常对比与色彩、未裁剪、清晰。
    public static let neutral = BeautyStats(luma: 0.46, lumaSpread: 0.24, saturation: 0.42,
                                            red: 0.46, green: 0.46, blue: 0.46,
                                            highlightClip: 0, shadowClip: 0, sharpness: 130)
}

/// 智能美化给出的调整量，单位与编辑器滑块一致。
public struct BeautyAdvice: Equatable, Sendable, Codable {
    public var exposure = 0.0
    public var brightness = 0.0
    public var contrast = 0.0
    public var saturation = 0.0
    public var shadows = 0.0
    public var warmth = 0.0
    public var tint = 0.0
    public var sharpness = 0.0
    public var noiseReduction = 0.0
    /// 0...1：越大表示越值得处理，用于推荐排序与筛选。
    public var score = 0.0
    /// 中文理由，最多三条。
    public var reasons: [String] = []

    public var isEmpty: Bool { score < 0.02 }
    public var summary: String { reasons.joined(separator: "；") }
}

/// 把画面统计映射成一组保守的调整量：只在确实有偏差的方向上动，幅度都落在滑块安全区间内。
public enum BeautyAdvisor {
    /// 曝光目标亮度。太亮会丢高光，太暗会显灰。
    public static let targetLuma = 0.46
    /// 低于该亮度视为偏暗。
    public static let darkLuma = 0.34
    /// 高于该亮度视为偏亮。
    public static let brightLuma = 0.68
    /// 对比度低于该标准差视为「发灰」。
    public static let flatSpread = 0.15
    /// 对比度高于该标准差视为「过硬」。
    public static let vividSpread = 0.32
    /// 饱和度低于该值视为色彩偏淡。
    public static let lowSaturation = 0.22
    /// 饱和度高于该值视为色彩过艳。
    public static let highSaturation = 0.60
    /// 通道差超过该值视为白平衡偏色（色温 / 色调）。
    public static let colorCast = 0.055
    public static let tintCast = 0.045
    /// 低于该清晰度视为「偏软」，与 `PhotoQuality.blurryThreshold` 保持一致。
    public static let blurrySharpness = 55.0
    /// 达到该分数才进入推荐列表。
    public static let recommendThreshold = 0.16

    public static func advise(_ stats: BeautyStats) -> BeautyAdvice {
        var advice = BeautyAdvice()
        var reasons: [String] = []

        // 曝光：向目标亮度靠拢；极暗画面（夜景）限制幅度，避免把噪点一起提亮。
        var exposure = clamp(log2(targetLuma / max(0.04, stats.luma)), -0.85, 0.95)
        if stats.luma < 0.12 {
            exposure = min(exposure, 0.6)
        }
        if abs(exposure) < 0.1 {
            exposure = 0
        }
        advice.exposure = exposure
        if exposure > 0 {
            reasons.append("画面偏暗，提亮 \(format(exposure)) EV")
        } else if exposure < 0 {
            reasons.append("画面偏亮，压暗 \(format(-exposure)) EV")
        }

        // 曝光之后的大致亮度，用来决定补光与降噪的力度。
        let projected = min(1, max(0, stats.luma * pow(2, exposure)))

        if projected < darkLuma {
            advice.brightness = min(0.10, (darkLuma - projected) * 0.22)
        } else if projected > brightLuma {
            advice.brightness = -min(0.08, (projected - brightLuma) * 0.2)
        }

        if stats.lumaSpread < flatSpread {
            advice.contrast = min(0.22, (flatSpread - stats.lumaSpread) * 1.5)
            reasons.append("整体偏灰，提升对比度")
        } else if stats.lumaSpread > vividSpread {
            advice.contrast = -min(0.06, (stats.lumaSpread - vividSpread) * 0.4)
        }

        if stats.saturation < lowSaturation {
            advice.saturation = min(0.26, (lowSaturation - stats.saturation) * 1.1)
            reasons.append("色彩偏淡，提升饱和度")
        } else if stats.saturation > highSaturation {
            advice.saturation = -min(0.12, (stats.saturation - highSaturation) * 0.5)
        }

        let cast = stats.red - stats.blue
        if cast > colorCast {
            advice.warmth = -min(0.32, (cast - colorCast) * 2.6)
            reasons.append("白平衡偏暖，已回正色温")
        } else if cast < -colorCast {
            advice.warmth = min(0.32, (-cast - colorCast) * 2.6)
            reasons.append("白平衡偏冷，已回正色温")
        }

        let greenCast = stats.green - (stats.red + stats.blue) / 2
        if abs(greenCast) > tintCast {
            advice.tint = clamp(-greenCast * 2.2, -0.28, 0.28)
            reasons.append(greenCast > 0 ? "画面偏绿，已校正色调" : "画面偏洋红，已校正色调")
        }

        if stats.shadowClip > 0.03 || stats.luma < 0.32 {
            let amount = max(stats.shadowClip * 5.5, (0.32 - stats.luma) * 1.1)
            advice.shadows = min(0.45, amount)
            if advice.shadows > 0.05 {
                reasons.append("暗部细节不足，提亮阴影")
            }
        }

        if stats.sharpness > 0, stats.sharpness < blurrySharpness {
            advice.sharpness = min(0.45, (blurrySharpness - stats.sharpness) / blurrySharpness * 0.5)
            reasons.append("细节偏软，已提升锐度")
        }

        if projected < 0.22 {
            advice.noiseReduction = min(0.3, (0.22 - projected) * 1.2)
            reasons.append("暗部噪点较多，已轻度降噪")
        }

        var score = abs(advice.exposure) * 0.55
            + abs(advice.brightness) * 1.6
            + abs(advice.contrast) * 2.4
            + abs(advice.saturation) * 1.5
            + abs(advice.warmth) * 1.6
            + abs(advice.tint) * 1.4
            + abs(advice.shadows) * 1.2
            + advice.noiseReduction * 0.6

        // 画面本身已经均衡时不加锐化，避免「什么都没改也算美化」。
        if score >= 0.05 {
            advice.sharpness = max(advice.sharpness, stats.sharpness > 0 ? 0.06 : 0)
            score += abs(advice.sharpness) * 1.3
        } else {
            advice.sharpness = 0
        }
        advice.score = min(1, max(0, score))
        advice.reasons = Array(reasons.prefix(3))
        return advice
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
