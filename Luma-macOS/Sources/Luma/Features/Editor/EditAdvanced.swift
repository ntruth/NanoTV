import SwiftUI
import CoreImage
import CoreGraphics
import Foundation

// MARK: - 曲线

/// 曲线控制点：x / y 都是 0...1。首尾两点的 x 固定为 0 与 1。
struct EditCurvePoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    static let identity: [EditCurvePoint] = [
        EditCurvePoint(x: 0, y: 0),
        EditCurvePoint(x: 0.25, y: 0.25),
        EditCurvePoint(x: 0.5, y: 0.5),
        EditCurvePoint(x: 0.75, y: 0.75),
        EditCurvePoint(x: 1, y: 1)
    ]

    var isIdentity: Bool { abs(x - y) < 0.0001 }
}

enum EditCurve {
    static func isIdentity(_ points: [EditCurvePoint]) -> Bool {
        points.count == EditCurvePoint.identity.count && points.allSatisfy(\.isIdentity)
    }

    /// 单调三次 Hermite 插值，避免普通样条在端点处过冲。
    static func lut(points: [EditCurvePoint], count: Int = 256) -> [Double] {
        let pts = points.sorted { $0.x < $1.x }
        guard pts.count >= 2 else {
            return (0..<count).map { Double($0) / Double(max(1, count - 1)) }
        }
        var xs = pts.map { min(1, max(0, $0.x)) }
        let ys = pts.map { min(1, max(0, $0.y)) }
        for index in 1..<xs.count where xs[index] <= xs[index - 1] {
            xs[index] = min(1, xs[index - 1] + 0.001)
        }
        let n = xs.count
        var delta = [Double](repeating: 0, count: n - 1)
        for index in 0..<(n - 1) {
            delta[index] = (ys[index + 1] - ys[index]) / max(0.000_001, xs[index + 1] - xs[index])
        }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = delta[0]
        tangents[n - 1] = delta[n - 2]
        if n > 2 {
            for index in 1..<(n - 1) {
                tangents[index] = (delta[index - 1] + delta[index]) / 2
            }
        }
        for index in 0..<(n - 1) {
            if delta[index] == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
            } else {
                let a = tangents[index] / delta[index]
                let b = tangents[index + 1] / delta[index]
                let sum = a * a + b * b
                if sum > 9 {
                    let scale = 3 / sqrt(sum)
                    tangents[index] = scale * a * delta[index]
                    tangents[index + 1] = scale * b * delta[index]
                }
            }
        }

        var result = [Double](repeating: 0, count: count)
        for step in 0..<count {
            let x = Double(step) / Double(max(1, count - 1))
            if x <= xs[0] {
                result[step] = ys[0]
                continue
            }
            if x >= xs[n - 1] {
                result[step] = ys[n - 1]
                continue
            }
            var segment = n - 2
            for index in 0..<(n - 1) where x >= xs[index] && x <= xs[index + 1] {
                segment = index
                break
            }
            let h = xs[segment + 1] - xs[segment]
            let t = (x - xs[segment]) / max(0.000_001, h)
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            let value = h00 * ys[segment] + h10 * h * tangents[segment]
                + h01 * ys[segment + 1] + h11 * h * tangents[segment + 1]
            result[step] = min(1, max(0, value))
        }
        return result
    }
}

// MARK: - 局部蒙版

enum EditMaskKind: String, Codable, CaseIterable, Identifiable {
    case radial
    case linear
    case colorRange
    case lumaRange
    case brush

    var id: String { rawValue }

    var title: String {
        switch self {
        case .radial: return "径向"
        case .linear: return "线性"
        case .colorRange: return "颜色"
        case .lumaRange: return "亮度"
        case .brush: return "画笔"
        }
    }

    var icon: String {
        switch self {
        case .radial: return "circle.dashed"
        case .linear: return "line.diagonal"
        case .colorRange: return "eyedropper.halffull"
        case .lumaRange: return "circle.lefthalf.filled"
        case .brush: return "paintbrush.pointed"
        }
    }
}

/// 画笔的一笔一个圆点：坐标与半径都相对整图，左上角为 0,0。
struct EditBrushDab: Codable, Equatable {
    var x: Double = 0.5
    var y: Double = 0.5
    var radius: Double = 0.05
    var softness: Double = 0.5
    var erase = false
}

/// 局部蒙版：几何 / 颜色范围 / 亮度范围 / 画笔 + 局部曝光 / 对比 / 饱和 / 色温。
/// 坐标以「旋转后的整图」为基准，左上角为 0,0。
struct EditMask: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: EditMaskKind = .radial
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var radius: Double = 0.3
    var angle: Double = 0
    var feather: Double = 0.5
    var inverted = false
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var warmth: Double = 0
    /// 颜色范围蒙版：目标色相 0...1、色相容差 0...0.5、最低饱和度。
    var rangeHue: Double = 0.08
    var rangeWidth: Double = 0.12
    var rangeSaturationMin: Double = 0.15
    /// 亮度范围蒙版：0...1 的亮度区间与羽化。
    var lumaMin: Double = 0.2
    var lumaMax: Double = 0.8
    var lumaFeather: Double = 0.12
    /// 画笔蒙版的圆点序列。
    var brushDabs: [EditBrushDab] = []

    var isNeutral: Bool {
        exposure == 0 && contrast == 0 && saturation == 0 && warmth == 0
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case id, kind, centerX, centerY, radius, angle, feather, inverted
        case exposure, contrast, saturation, warmth
        case rangeHue, rangeWidth, rangeSaturationMin
        case lumaMin, lumaMax, lumaFeather, brushDabs
    }

    /// v1.3 的蒙版没有范围 / 画笔字段，缺省即默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(EditMaskKind.self, forKey: .kind) ?? .radial
        centerX = try container.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try container.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5
        radius = try container.decodeIfPresent(Double.self, forKey: .radius) ?? 0.3
        angle = try container.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        feather = try container.decodeIfPresent(Double.self, forKey: .feather) ?? 0.5
        inverted = try container.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        rangeHue = try container.decodeIfPresent(Double.self, forKey: .rangeHue) ?? 0.08
        rangeWidth = try container.decodeIfPresent(Double.self, forKey: .rangeWidth) ?? 0.12
        rangeSaturationMin = try container.decodeIfPresent(Double.self, forKey: .rangeSaturationMin) ?? 0.15
        lumaMin = try container.decodeIfPresent(Double.self, forKey: .lumaMin) ?? 0.2
        lumaMax = try container.decodeIfPresent(Double.self, forKey: .lumaMax) ?? 0.8
        lumaFeather = try container.decodeIfPresent(Double.self, forKey: .lumaFeather) ?? 0.12
        brushDabs = try container.decodeIfPresent([EditBrushDab].self, forKey: .brushDabs) ?? []
    }
}

// MARK: - 修复点

/// 修复点：点按处用邻近区域覆盖，适合灰尘、传感器脏点。
/// 显式给出采样点时为克隆（sourceX / sourceY），否则按 sourceDX / sourceDY 自动取样。
struct EditHealSpot: Codable, Equatable, Identifiable {
    var id = UUID()
    var x: Double = 0.5
    var y: Double = 0.5
    var radius: Double = 0.03
    var sourceDX: Double = -0.08
    var sourceDY: Double = 0
    var sourceX: Double?
    var sourceY: Double?
}

// MARK: - HSL 色带

enum HSLBand: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, magenta

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .teal: return "青"
        case .blue: return "蓝"
        case .purple: return "紫"
        case .magenta: return "洋红"
        }
    }

    /// 色带中心色相（度）。
    var hue: Double {
        switch self {
        case .red: return 0
        case .orange: return 30
        case .yellow: return 60
        case .green: return 120
        case .teal: return 180
        case .blue: return 240
        case .purple: return 280
        case .magenta: return 320
        }
    }

    var baseIndex: Int { rawValue * 3 }

    var swatch: Color {
        Color(hue: hue / 360, saturation: 0.78, brightness: 0.96)
    }
}

// MARK: - 颜色立方体（曲线 + HSL 合成）

enum EditColorCube {
    static let dimension = 28

    private static let lock = NSLock()
    private static var cache: [String: Data] = [:]
    private static var order: [String] = []

    static func data(curve: [EditCurvePoint],
                     redCurve: [EditCurvePoint],
                     greenCurve: [EditCurvePoint],
                     blueCurve: [EditCurvePoint],
                     hsl: [Double],
                     grading: [EditGradeBand]) -> Data {
        let key = cacheKey(curve: curve, red: redCurve, green: greenCurve, blue: blueCurve,
                           hsl: hsl, grading: grading)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let built = build(curve: curve, red: redCurve, green: greenCurve, blue: blueCurve,
                          hsl: hsl, grading: grading)

        lock.lock()
        cache[key] = built
        order.append(key)
        while order.count > 6 {
            let oldest = order.removeFirst()
            cache[oldest] = nil
        }
        lock.unlock()
        return built
    }

    private static func cacheKey(curve: [EditCurvePoint],
                                 red: [EditCurvePoint],
                                 green: [EditCurvePoint],
                                 blue: [EditCurvePoint],
                                 hsl: [Double],
                                 grading: [EditGradeBand]) -> String {
        func points(_ list: [EditCurvePoint]) -> String {
            list.map { String(format: "%.3f,%.3f", $0.x, $0.y) }.joined(separator: ";")
        }
        let hslPart = hsl.map { String(format: "%.2f", $0) }.joined(separator: ",")
        let gradePart = grading.map {
            String(format: "%.2f,%.2f,%.2f", $0.hue, $0.saturation, $0.luminance)
        }.joined(separator: ";")
        return [points(curve), points(red), points(green), points(blue), hslPart, gradePart]
            .joined(separator: "|")
    }

    private static func build(curve: [EditCurvePoint],
                              red: [EditCurvePoint],
                              green: [EditCurvePoint],
                              blue: [EditCurvePoint],
                              hsl: [Double],
                              grading: [EditGradeBand]) -> Data {
        let dimension = Self.dimension
        let lut = EditCurve.lut(points: curve, count: 256)
        let redLut = EditCurve.lut(points: red, count: 256)
        let greenLut = EditCurve.lut(points: green, count: 256)
        let blueLut = EditCurve.lut(points: blue, count: 256)
        let bands = hslBands(hsl)
        let hasHSL = bands.contains { abs($0.hue) > 0.0001 || abs($0.saturation) > 0.0001 || abs($0.luminance) > 0.0001 }
        let hasGrading = grading.contains { !$0.isNeutral }
        var data = [Float]()
        data.reserveCapacity(dimension * dimension * dimension * 4)

        for blueStep in 0..<dimension {
            let blue = Double(blueStep) / Double(dimension - 1)
            for greenStep in 0..<dimension {
                let green = Double(greenStep) / Double(dimension - 1)
                for redStep in 0..<dimension {
                    let red = Double(redStep) / Double(dimension - 1)
                    let channelRed = redLut[Int((red * 255).rounded())]
                    let channelGreen = greenLut[Int((green * 255).rounded())]
                    let channelBlue = blueLut[Int((blue * 255).rounded())]
                    let curvedRed = lut[Int((channelRed * 255).rounded())]
                    let curvedGreen = lut[Int((channelGreen * 255).rounded())]
                    let curvedBlue = lut[Int((channelBlue * 255).rounded())]

                    var finalRed = curvedRed
                    var finalGreen = curvedGreen
                    var finalBlue = curvedBlue

                    // 近中性色没有可靠色相，直接跳过，避免「调红」把灰阶也带偏。
                    let converted = rgbToHSL(curvedRed, curvedGreen, curvedBlue)
                    if hasHSL, converted.1 > 0.02 {
                        var hue = converted.0
                        var saturation = converted.1
                        var luminance = converted.2
                        var hueShift = 0.0
                        var saturationShift = 0.0
                        var luminanceShift = 0.0
                        var weightSum = 0.0
                        for band in bands {
                            var distance = abs(hue - band.center)
                            distance = min(distance, 360 - distance)
                            let weight = max(0, 1 - distance / 45)
                            guard weight > 0 else { continue }
                            hueShift += band.hue * weight
                            saturationShift += band.saturation * weight
                            luminanceShift += band.luminance * weight
                            weightSum += weight
                        }
                        if weightSum > 0 {
                            hueShift /= weightSum
                            saturationShift /= weightSum
                            luminanceShift /= weightSum
                        }
                        hue = (hue + hueShift * 30).truncatingRemainder(dividingBy: 360)
                        if hue < 0 { hue += 360 }
                        saturation = min(1, max(0, saturation * (1 + saturationShift)))
                        luminance = min(1, max(0, luminance + luminanceShift * 0.25))
                        let rgb = hslToRGB(hue, saturation, luminance)
                        finalRed = rgb.0
                        finalGreen = rgb.1
                        finalBlue = rgb.2
                    }

                    if hasGrading {
                        let graded = gradedColor(finalRed, finalGreen, finalBlue, bands: grading)
                        finalRed = graded.0
                        finalGreen = graded.1
                        finalBlue = graded.2
                    }

                    data.append(Float(finalRed))
                    data.append(Float(finalGreen))
                    data.append(Float(finalBlue))
                    data.append(1)
                }
            }
        }
        return data.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// 色彩分级：按亮度把像素分到阴影 / 中间调 / 高光，分别做色相、饱和与亮度偏移。
    private static func gradedColor(_ red: Double, _ green: Double, _ blue: Double,
                                    bands: [EditGradeBand]) -> (Double, Double, Double) {
        let converted = rgbToHSL(red, green, blue)
        let lightness = converted.2
        let weights = [
            max(0, 1 - lightness * 2),
            1 - abs(lightness * 2 - 1),
            max(0, lightness * 2 - 1)
        ]
        var hueShift = 0.0
        var saturationShift = 0.0
        var luminanceShift = 0.0
        for (index, band) in bands.enumerated() where index < weights.count && !band.isNeutral {
            let weight = weights[index]
            guard weight > 0 else { continue }
            hueShift += band.hue * 60 * weight
            saturationShift += band.saturation * 0.6 * weight
            luminanceShift += band.luminance * 0.3 * weight
        }
        guard abs(hueShift) + abs(saturationShift) + abs(luminanceShift) > 0.0001 else {
            return (red, green, blue)
        }
        var hue = (converted.0 + hueShift).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let saturation = min(1, max(0, converted.1 + saturationShift))
        let luminance = min(1, max(0, lightness + luminanceShift))
        return hslToRGB(hue, saturation, luminance)
    }

    /// 返回 8 条色带的 hue / saturation / luminance 调整（已乘上系数前的原始 -1...1）。
    private static func hslBands(_ values: [Double]) -> [(center: Double, hue: Double, saturation: Double, luminance: Double)] {
        HSLBand.allCases.map { band in
            let base = band.baseIndex
            let hue = base < values.count ? values[base] : 0
            let saturation = base + 1 < values.count ? values[base + 1] : 0
            let luminance = base + 2 < values.count ? values[base + 2] : 0
            return (band.hue, hue, saturation, luminance)
        }
    }

    static func rgbToHSL(_ red: Double, _ green: Double, _ blue: Double) -> (Double, Double, Double) {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let luminance = (maxValue + minValue) / 2
        let delta = maxValue - minValue
        guard delta > 0.000_001 else { return (0, 0, luminance) }
        let saturation = luminance > 0.5
            ? delta / max(0.000_001, 2 - maxValue - minValue)
            : delta / max(0.000_001, maxValue + minValue)
        var hue: Double
        if maxValue == red {
            hue = (green - blue) / delta + (green < blue ? 6 : 0)
        } else if maxValue == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue *= 60
        return (hue, saturation, luminance)
    }

    static func hslToRGB(_ hue: Double, _ saturation: Double, _ luminance: Double) -> (Double, Double, Double) {
        guard saturation > 0.000_001 else { return (luminance, luminance, luminance) }
        let q = luminance < 0.5
            ? luminance * (1 + saturation)
            : luminance + saturation - luminance * saturation
        let p = 2 * luminance - q
        func channel(_ offset: Double) -> Double {
            var t = (hue / 360 + offset).truncatingRemainder(dividingBy: 1)
            if t < 0 { t += 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (channel(0), channel(-1 / 3), channel(1 / 3))
    }
}

// MARK: - 直方图

struct EditHistogram: Equatable {
    var red = [Double](repeating: 0, count: 64)
    var green = [Double](repeating: 0, count: 64)
    var blue = [Double](repeating: 0, count: 64)
    /// 纯黑 / 纯白像素占比，用来提示高光与阴影剪切。
    var shadowClip: Double = 0
    var highlightClip: Double = 0

    var isEmpty: Bool {
        red.allSatisfy { $0 <= 0 } && green.allSatisfy { $0 <= 0 } && blue.allSatisfy { $0 <= 0 }
    }
}

/// 缩略采样图：给吸管取色用，避免每次悬停都重新解码整张预览。
struct EditSampleImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// `x` / `y` 都是 0...1，左上角为 0,0。
    func color(atX x: Double, y: Double) -> (red: Int, green: Int, blue: Int)? {
        guard width > 0, height > 0 else { return nil }
        let px = min(width - 1, max(0, Int(x * Double(width))))
        let py = min(height - 1, max(0, Int(y * Double(height))))
        let index = (py * width + px) * 4
        guard index + 2 < bytes.count else { return nil }
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    var hex: String? {
        color(atX: 0.5, y: 0.5).map { String(format: "#%02X%02X%02X", $0.red, $0.green, $0.blue) }
    }
}

enum EditHistogramSampler {
    static func analyze(_ image: CGImage) -> (histogram: EditHistogram, sample: EditSampleImage?) {
        let maxSide = 320
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (EditHistogram(), nil)
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pointer = context.data else { return (EditHistogram(), nil) }
        let pixels = pointer.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var histogram = EditHistogram()
        let bins = 64
        var red = [Double](repeating: 0, count: bins)
        var green = [Double](repeating: 0, count: bins)
        var blue = [Double](repeating: 0, count: bins)
        var shadowClipped = 0
        var highlightClipped = 0
        let total = width * height
        var bytes = [UInt8](repeating: 0, count: total * 4)
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.update(from: pixels, count: total * 4)
        }
        for index in stride(from: 0, to: total * 4, by: 4) {
            let r = Int(pixels[index])
            let g = Int(pixels[index + 1])
            let b = Int(pixels[index + 2])
            red[r * bins / 256] += 1
            green[g * bins / 256] += 1
            blue[b * bins / 256] += 1
            if r == 0 || g == 0 || b == 0 { shadowClipped += 1 }
            if r == 255 || g == 255 || b == 255 { highlightClipped += 1 }
        }
        let peak = max(1, max(red.max() ?? 1, max(green.max() ?? 1, blue.max() ?? 1)))
        histogram.red = red.map { $0 / peak }
        histogram.green = green.map { $0 / peak }
        histogram.blue = blue.map { $0 / peak }
        histogram.shadowClip = total > 0 ? Double(shadowClipped) / Double(total) : 0
        histogram.highlightClip = total > 0 ? Double(highlightClipped) / Double(total) : 0
        return (histogram, EditSampleImage(width: width, height: height, bytes: bytes))
    }

    static func compute(_ image: CGImage) -> EditHistogram {
        analyze(image).histogram
    }
}

// MARK: - 渲染

extension PhotoRenderer {
    /// 高级调整：修复 → 曲线 + HSL → 局部蒙版 → 镜头 / 透视。
    /// 放在基础调整之后、裁剪之前，保证蒙版坐标与裁剪坐标都基于旋转后的整图。
    static func applyAdvanced(_ image: CIImage, state: EditState) -> CIImage {
        var output = image
        if !state.healSpots.isEmpty {
            output = applyHeal(output, spots: state.healSpots)
        }
        let hasCurve = !EditCurve.isIdentity(state.curvePoints)
            || !EditCurve.isIdentity(state.curveRed)
            || !EditCurve.isIdentity(state.curveGreen)
            || !EditCurve.isIdentity(state.curveBlue)
        let hasHSL = state.hslAdjustments.contains { abs($0) > 0.0001 }
        let hasGrading = state.gradingBands.contains { !$0.isNeutral }
        if hasCurve || hasHSL || hasGrading {
            output = applyColorCube(output, state: state)
        }
        if let lut = state.lutName, state.lutStrength > 0.001 {
            output = applyLUT(output, name: lut, strength: state.lutStrength)
        }
        if state.fade > 0.001 || state.grain > 0.001
            || state.halation > 0.001 || state.lightLeak > 0.001 {
            output = applyFilm(output, state: state)
        }
        if !state.masks.isEmpty {
            output = applyMasks(output, masks: state.masks)
        }
        if state.lensDistortion != 0 {
            output = applyLens(output, amount: state.lensDistortion)
        }
        if state.lensVignetteFix > 0.001 {
            output = applyLensVignetteFix(output, amount: state.lensVignetteFix)
        }
        if state.perspectiveV != 0 || state.perspectiveH != 0 {
            output = applyPerspective(output, vertical: state.perspectiveV, horizontal: state.perspectiveH)
        }
        if state.tiltBlur > 0.001 || state.zoomBlur > 0.001 {
            output = applyCreativeBlur(output, state: state)
        }
        return output
    }

    private static func applyColorCube(_ image: CIImage, state: EditState) -> CIImage {
        let data = EditColorCube.data(curve: state.curvePoints,
                                      redCurve: state.curveRed,
                                      greenCurve: state.curveGreen,
                                      blueCurve: state.curveBlue,
                                      hsl: state.hslAdjustments,
                                      grading: state.gradingBands)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": EditColorCube.dimension,
            "inputCubeData": data,
            "inputColorSpace": space
        ])
    }

    private static func applyHeal(_ image: CIImage, spots: [EditHealSpot]) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        var output = image
        let minDimension = min(extent.width, extent.height)
        for spot in spots {
            let radius = max(2, CGFloat(spot.radius) * minDimension)
            let center = CGPoint(x: extent.minX + CGFloat(spot.x) * extent.width,
                                 y: extent.maxY - CGFloat(spot.y) * extent.height)
            let mask = radialMask(center: center,
                                  radius: radius,
                                  feather: 0.55,
                                  inverted: false,
                                  extent: extent)
            let shiftX: CGFloat
            let shiftY: CGFloat
            if let sourceX = spot.sourceX, let sourceY = spot.sourceY {
                shiftX = CGFloat(spot.x - sourceX) * extent.width
                shiftY = -CGFloat(spot.y - sourceY) * extent.height
            } else {
                shiftX = -CGFloat(spot.sourceDX) * extent.width
                shiftY = CGFloat(spot.sourceDY) * extent.height
            }
            let shifted = output
                .transformed(by: CGAffineTransform(translationX: shiftX, y: shiftY))
                .cropped(to: extent)
            output = shifted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: mask
            ])
        }
        return output
    }

    private static func applyMasks(_ image: CIImage, masks: [EditMask]) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        var output = image
        let minDimension = min(extent.width, extent.height)

        for mask in masks where !mask.isNeutral {
            let center = CGPoint(x: extent.minX + CGFloat(mask.centerX) * extent.width,
                                 y: extent.maxY - CGFloat(mask.centerY) * extent.height)
            let maskImage: CIImage
            switch mask.kind {
            case .radial:
                let radius = max(2, CGFloat(mask.radius) * minDimension)
                maskImage = radialMask(center: center,
                                       radius: radius,
                                       feather: mask.feather,
                                       inverted: mask.inverted,
                                       extent: extent)
            case .linear:
                let angle = CGFloat(mask.angle * .pi / 180)
                let direction = CGVector(dx: cos(angle), dy: sin(angle))
                let half = max(2, CGFloat(mask.radius) * minDimension)
                let point0 = CGPoint(x: center.x - direction.dx * half,
                                     y: center.y - direction.dy * half)
                let point1 = CGPoint(x: center.x + direction.dx * half,
                                     y: center.y + direction.dy * half)
                let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
                let black = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                let gradient = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(cgPoint: point0),
                    "inputPoint1": CIVector(cgPoint: point1),
                    "inputColor0": mask.inverted ? black : white,
                    "inputColor1": mask.inverted ? white : black
                ])?.outputImage ?? CIImage(color: mask.inverted ? .black : .white)
                maskImage = gradient.cropped(to: extent)
            case .colorRange, .lumaRange:
                guard var rangeMask = EditRangeMask.mask(for: mask, from: output, extent: extent) else {
                    continue
                }
                if mask.inverted {
                    rangeMask = rangeMask.applyingFilter("CIColorInvert").cropped(to: extent)
                }
                maskImage = rangeMask
            case .brush:
                guard var brushMask = EditBrushMask.image(mask: mask, extent: extent) else {
                    continue
                }
                if mask.inverted {
                    brushMask = brushMask.applyingFilter("CIColorInvert").cropped(to: extent)
                }
                maskImage = brushMask
            }

            var local = output
            if mask.exposure != 0 {
                local = local.applyingFilter("CIExposureAdjust", parameters: [
                    kCIInputEVKey: mask.exposure
                ])
            }
            if mask.contrast != 0 || mask.saturation != 0 {
                local = local.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1 + mask.contrast * 0.8,
                    kCIInputSaturationKey: 1 + mask.saturation
                ])
            }
            if mask.warmth != 0 {
                local = local.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 6500 + mask.warmth * 2200, y: 0)
                ])
            }
            output = local.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: maskImage
            ])
        }
        return output
    }

    private static func radialMask(center: CGPoint,
                                   radius: CGFloat,
                                   feather: Double,
                                   inverted: Bool,
                                   extent: CGRect) -> CIImage {
        let outer = max(2, radius)
        let inner = max(0, outer * CGFloat(1 - min(0.95, max(0, feather))))
        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y),
            "inputRadius0": inner,
            "inputRadius1": max(inner + 0.5, outer),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        ])?.outputImage ?? CIImage(color: .white)
        var mask = gradient.cropped(to: extent)
        if inverted {
            mask = mask.applyingFilter("CIColorInvert").cropped(to: extent)
        }
        return mask
    }

    /// 用 Core Image 内置的挤压畸变近似镜头校正：正向拉直桶形（向内取样，满幅），
    /// 负向导回枕形（向外取样，四角会露空，按比例放大铺满原画幅）。
    private static func applyLens(_ image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let radius = Double(max(extent.width, extent.height)) * 0.75
        let scale = amount * 0.45
        var output = image.applyingFilter("CIPinchDistortion", parameters: [
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
            kCIInputRadiusKey: radius,
            kCIInputScaleKey: scale
        ])
        let zoom = 1 + max(0, scale) * 0.7
        if zoom > 1.0001 {
            output = output
                .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
                .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
                .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
        }
        return output.cropped(to: extent)
    }

    /// 透视校正：把较窄的一边向外扩，保证输出铺满原画幅，不出现透明缺口。
    private static func applyPerspective(_ image: CIImage,
                                         vertical: Double,
                                         horizontal: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let dx = CGFloat(vertical) * 0.18 * extent.width
        let dy = CGFloat(horizontal) * 0.18 * extent.height
        let topOut = max(0, dx)
        let bottomOut = max(0, -dx)
        let leftOut = max(0, dy)
        let rightOut = max(0, -dy)
        let output = image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: CGPoint(x: extent.minX - topOut,
                                                     y: extent.maxY + leftOut)),
            "inputTopRight": CIVector(cgPoint: CGPoint(x: extent.maxX + topOut,
                                                      y: extent.maxY + rightOut)),
            "inputBottomLeft": CIVector(cgPoint: CGPoint(x: extent.minX - bottomOut,
                                                        y: extent.minY - leftOut)),
            "inputBottomRight": CIVector(cgPoint: CGPoint(x: extent.maxX + bottomOut,
                                                         y: extent.minY - rightOut))
        ])
        return output.cropped(to: extent)
    }
}

// MARK: - 直方图视图

struct EditHistogramView: View {
    let histogram: EditHistogram

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.35))

                if !histogram.isEmpty {
                    channel(histogram.red, color: .red, size: proxy.size)
                    channel(histogram.green, color: .green, size: proxy.size)
                    channel(histogram.blue, color: .blue, size: proxy.size)
                } else {
                    Text("直方图")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Path { path in
                    for index in 1...3 {
                        let x = proxy.size.width * CGFloat(index) / 4
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    }
                }
                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)

                if histogram.shadowClip > 0.005 {
                    VStack {
                        Spacer()
                        HStack {
                            Circle()
                                .fill(Color.cyan.opacity(0.85))
                                .frame(width: 6, height: 6)
                                .padding(3)
                            Spacer()
                        }
                    }
                }
                if histogram.highlightClip > 0.005 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Circle()
                                .fill(Color.red.opacity(0.85))
                                .frame(width: 6, height: 6)
                                .padding(3)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(height: 62)
    }

    private func channel(_ values: [Double], color: Color, size: CGSize) -> some View {
        Path { path in
            guard !values.isEmpty else { return }
            let step = size.width / CGFloat(max(1, values.count - 1))
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in values.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(index) * step,
                                         y: size.height * (1 - CGFloat(value) * 0.94)))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
        .fill(color.opacity(0.32))
        .blendMode(.plusLighter)
    }
}

// MARK: - 曲线编辑器

struct EditCurveEditor: View {
    @Binding var points: [EditCurvePoint]
    var tint: Color = .accentColor
    @State private var dragIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let lut = EditCurve.lut(points: points, count: 96)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.28))

                Path { path in
                    for index in 1...3 {
                        let x = size.width * CGFloat(index) / 4
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        let y = size.height * CGFloat(index) / 4
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)

                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))

                Path { path in
                    for (index, value) in lut.enumerated() {
                        let x = size.width * CGFloat(index) / CGFloat(max(1, lut.count - 1))
                        let y = size.height * (1 - CGFloat(value))
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(tint, lineWidth: 1.6)

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(tint, lineWidth: 1.4))
                        .position(x: CGFloat(point.x) * size.width,
                                  y: (1 - CGFloat(point.y)) * size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let normalized = CGPoint(x: min(1, max(0, value.location.x / max(1, size.width))),
                                                 y: min(1, max(0, 1 - value.location.y / max(1, size.height))))
                        if dragIndex == nil {
                            dragIndex = nearestIndex(to: normalized)
                        }
                        guard let index = dragIndex, index < points.count else { return }
                        var updated = points[index]
                        if index == 0 {
                            updated.x = 0
                        } else if index == points.count - 1 {
                            updated.x = 1
                        } else {
                            let lower = points[index - 1].x + 0.01
                            let upper = points[index + 1].x - 0.01
                            updated.x = min(upper, max(lower, Double(normalized.x)))
                        }
                        updated.y = Double(normalized.y)
                        points[index] = updated
                    }
                    .onEnded { _ in
                        dragIndex = nil
                    }
            )
        }
        .frame(height: 176)
    }

    private func nearestIndex(to point: CGPoint) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, candidate) in points.enumerated() {
            let dx = CGFloat(candidate.x) - point.x
            let dy = CGFloat(candidate.y) - point.y
            let distance = sqrt(dx * dx + dy * dy)
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        guard let best, best.distance < 0.18 else { return nil }
        return best.index
    }
}

// MARK: - 面板

enum CurveChannel: String, CaseIterable, Identifiable {
    case rgb = "RGB"
    case red = "R"
    case green = "G"
    case blue = "B"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .rgb: return .accentColor
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }
}

struct EditCurvePanel: View {
    @Binding var points: [EditCurvePoint]
    @Binding var red: [EditCurvePoint]
    @Binding var green: [EditCurvePoint]
    @Binding var blue: [EditCurvePoint]
    let histogram: EditHistogram
    @State private var channel: CurveChannel = .rgb

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(CurveChannel.allCases) { item in
                    Button {
                        channel = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(channel == item ? item.tint.opacity(0.85) : Color.primary.opacity(0.07)))
                            .foregroundStyle(channel == item ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            EditHistogramView(histogram: histogram)
            EditCurveEditor(points: activeCurve, tint: channel.tint)

            HStack {
                Button("复位当前通道") {
                    activeCurve.wrappedValue = EditCurvePoint.identity
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text(channel == .rgb ? "拖动控制点调整整体影调" : "单通道曲线用于冷暖分离")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var activeCurve: Binding<[EditCurvePoint]> {
        switch channel {
        case .rgb: return $points
        case .red: return $red
        case .green: return $green
        case .blue: return $blue
        }
    }
}

struct EditHSLPanel: View {
    @Binding var values: [Double]
    @State private var band: HSLBand = .red

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(HSLBand.allCases) { item in
                    Button {
                        band = item
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(item.swatch)
                                .frame(width: 7, height: 7)
                            Text(item.title)
                                .font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(band == item ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.06))
                        )
                        .foregroundStyle(band == item ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            slider("色相", index: band.baseIndex)
            slider("饱和度", index: band.baseIndex + 1)
            slider("明度", index: band.baseIndex + 2)

            Button("重置全部颜色") {
                values = Array(repeating: 0, count: 24)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.accentColor)

            Text("按色带调整，只影响对应色相附近的像素；对天空、肤色、草地最直观。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func slider(_ title: String, index: Int) -> some View {
        let binding = Binding<Double>(
            get: { index < values.count ? values[index] : 0 },
            set: { newValue in
                var next = values
                if next.count != 24 { next = Array(repeating: 0, count: 24) }
                next[index] = newValue
                values = next
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(String(format: "%+.2f", binding.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: -1...1)
                .controlSize(.small)
        }
    }
}

struct EditMaskPanel: View {
    @Binding var masks: [EditMask]
    @Binding var selection: UUID?
    @Binding var brushRadius: Double
    @Binding var brushErase: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(EditMaskKind.allCases) { kind in
                    Button {
                        add(kind)
                    } label: {
                        Label(kind.title, systemImage: kind.icon)
                            .font(.system(size: 10.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }
            }

            if masks.isEmpty {
                Text("添加蒙版后，在画面里拖动定位（画笔直接在画面上涂抹）；蒙版内可单独调曝光 / 对比 / 饱和 / 色温。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(masks.enumerated()), id: \.element.id) { index, mask in
                            Button {
                                selection = mask.id
                            } label: {
                                Text("\(mask.kind.title) \(index + 1)")
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(selection == mask.id ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07))
                                    )
                                    .foregroundStyle(selection == mask.id ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let index = selectedIndex {
                    maskEditor(index: index)
                }
            }
        }
        .onAppear {
            if selection == nil || !masks.contains(where: { $0.id == selection }) {
                selection = masks.first?.id
            }
        }
    }

    private var selectedIndex: Int? {
        if let selection, let index = masks.firstIndex(where: { $0.id == selection }) {
            return index
        }
        return masks.isEmpty ? nil : 0
    }

    private func add(_ kind: EditMaskKind) {
        var mask = EditMask()
        mask.kind = kind
        // 新蒙版给一点可见的局部效果，否则画上去会以为没生效。
        mask.exposure = 0.3
        mask.saturation = 0.05
        switch kind {
        case .linear:
            mask.angle = 90
            mask.radius = 0.4
        case .colorRange:
            mask.rangeHue = 0.55
            mask.rangeWidth = 0.15
            mask.rangeSaturationMin = 0.12
        case .lumaRange:
            mask.lumaMin = 0.4
            mask.lumaMax = 0.9
            mask.lumaFeather = 0.12
        case .brush:
            mask.feather = 0.35
        case .radial:
            break
        }
        masks.append(mask)
        selection = mask.id
    }

    @ViewBuilder
    private func maskEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch masks[index].kind {
            case .radial:
                slider("大小", value: binding(index, \.radius), range: 0.05...0.9)
                slider("羽化", value: binding(index, \.feather), range: 0...1)
            case .linear:
                slider("大小", value: binding(index, \.radius), range: 0.05...0.9)
                slider("角度", value: binding(index, \.angle), range: -180...180)
            case .colorRange:
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hue: masks[index].rangeHue, saturation: 0.8, brightness: 0.95))
                        .frame(width: 14, height: 14)
                    Text("目标颜色")
                        .font(.system(size: 12))
                    Spacer()
                }
                slider("色相", value: binding(index, \.rangeHue), range: 0...1)
                slider("容差", value: binding(index, \.rangeWidth), range: 0.02...0.4)
                slider("最低饱和", value: binding(index, \.rangeSaturationMin), range: 0...0.8)
            case .lumaRange:
                slider("亮度下限", value: binding(index, \.lumaMin), range: 0...1)
                slider("亮度上限", value: binding(index, \.lumaMax), range: 0...1)
                slider("羽化", value: binding(index, \.lumaFeather), range: 0.01...0.4)
            case .brush:
                slider("画笔大小", value: $brushRadius, range: 0.01...0.2)
                slider("柔和度", value: binding(index, \.feather), range: 0...1)
                Toggle("橡皮（擦掉笔迹）", isOn: $brushErase)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11.5))
                HStack {
                    Text("已涂 \(masks[index].brushDabs.count) 笔")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("清除笔迹") {
                        masks[index].brushDabs.removeAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }

            Toggle("反向蒙版", isOn: binding(index, \.inverted))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11.5))

            Divider()

            Text("局部调整")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            slider("曝光", value: binding(index, \.exposure), range: -2...2)
            slider("对比", value: binding(index, \.contrast), range: -0.5...0.5)
            slider("饱和", value: binding(index, \.saturation), range: -1...1)
            slider("色温", value: binding(index, \.warmth), range: -1...1)

            HStack {
                Button("删除这个蒙版") {
                    let id = masks[index].id
                    masks.remove(at: index)
                    if selection == id { selection = masks.first?.id }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.red)

                Spacer()

                Button("全部清除") {
                    masks.removeAll()
                    selection = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func binding(_ index: Int, _ keyPath: WritableKeyPath<EditMask, Double>) -> Binding<Double> {
        Binding(
            get: { index < masks.count ? masks[index][keyPath: keyPath] : 0 },
            set: { newValue in
                guard index < masks.count else { return }
                masks[index][keyPath: keyPath] = newValue
            }
        )
    }

    private func binding(_ index: Int, _ keyPath: WritableKeyPath<EditMask, Bool>) -> Binding<Bool> {
        Binding(
            get: { index < masks.count ? masks[index][keyPath: keyPath] : false },
            set: { newValue in
                guard index < masks.count else { return }
                masks[index][keyPath: keyPath] = newValue
            }
        )
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(String(format: "%+.2f", value.wrappedValue))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }
}

struct EditHealPanel: View {
    @Binding var spots: [EditHealSpot]
    @Binding var brushRadius: Double
    @Binding var cloneMode: Bool
    let pendingSource: CGPoint?
    let onCancelSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("画笔大小")
                        .font(.system(size: 12))
                    Spacer()
                    Text(String(format: "%.0f", brushRadius * 1000))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $brushRadius, in: 0.008...0.12)
                    .controlSize(.small)
            }

            Toggle("克隆模式（手动采样）", isOn: $cloneMode)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11.5))

            if cloneMode {
                if pendingSource != nil {
                    HStack {
                        Text("已选采样点，点画面上的目标位置覆盖")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Button("取消采样", action: onCancelSource)
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("先点一下采样点，再点要覆盖的位置。适合去电线、路人等小物件。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("在画面上点按要修复的位置；会自动从旁边采样覆盖，适合灰尘、传感器脏点。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if spots.isEmpty {
                Text("还没有修复点")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text("已修复 \(spots.count) 处")
                    .font(.system(size: 11.5))
                HStack {
                    Button("撤销上一处") {
                        if !spots.isEmpty { spots.removeLast() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)

                    Spacer()

                    Button("清除全部") {
                        spots.removeAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct EditOpticsPanel: View {
    @Binding var distortion: Double
    @Binding var vertical: Double
    @Binding var horizontal: Double
    @Binding var vignetteFix: Double
    let profile: EditLensProfile
    let lensLabel: String?
    let onSelectProfile: (EditLensProfile) -> Void
    let onAutoDetect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("镜头配置")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(EditLensProfile.allCases) { item in
                    Button {
                        onSelectProfile(item)
                    } label: {
                        Text(item.title)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(profile == item ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07)))
                            .foregroundStyle(profile == item ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(profile.hint)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    onAutoDetect()
                } label: {
                    Label("按镜头自动", systemImage: "camera.metering.matrix")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Spacer()
                Text(lensLabel ?? "无镜头信息")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Divider()

            slider("镜头畸变", value: $distortion, range: -1...1)
            slider("暗角校正", value: $vignetteFix, range: 0...1)
            slider("垂直透视", value: $vertical, range: -1...1)
            slider("水平透视", value: $horizontal, range: -1...1)

            Button("重置镜头与透视") {
                distortion = 0
                vertical = 0
                horizontal = 0
                vignetteFix = 0
                onSelectProfile(.none)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.accentColor)

            Text("畸变修桶形 / 枕形；暗角校正只提亮四角；垂直透视用来拉直仰拍建筑的收敛线。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(String(format: "%+.2f", value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }
}
