import Foundation
import LumaCore

extension EditState {
    /// 在现有编辑的基础上叠加美化建议。
    /// `strength` 为 1 时使用建议值，大于 1 更明显，小于 1 更克制；crop / rotation / filter 保持不变。
    static func beautified(_ base: EditState, advice: BeautyAdvice, strength: Double) -> EditState {
        let amount = min(1.5, max(0.2, strength))
        var next = base
        next.exposure = clamp(base.exposure + advice.exposure * amount, -2, 2)
        next.brightness = clamp(base.brightness + advice.brightness * amount, -0.5, 0.5)
        next.contrast = clamp(base.contrast + advice.contrast * amount, -0.5, 0.5)
        next.saturation = clamp(base.saturation + advice.saturation * amount, -1, 1)
        next.shadows = clamp(base.shadows + advice.shadows * amount, -1, 1)
        next.warmth = clamp(base.warmth + advice.warmth * amount, -1, 1)
        next.tint = clamp(base.tint + advice.tint * amount, -1, 1)
        next.sharpness = clamp(base.sharpness + advice.sharpness * amount, 0, 1)
        next.noiseReduction = clamp(base.noiseReduction + advice.noiseReduction * amount, 0, 1)
        return next
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
