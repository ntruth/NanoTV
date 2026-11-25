import SwiftUI
import CoreImage
import CoreGraphics
import Foundation
import AppKit
import Vision

// MARK: - 编辑器辅助类型

enum CompareMode {
    case off
    case split
}

enum CropGridStyle: String, CaseIterable, Identifiable {
    case thirds
    case golden
    case diagonal
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thirds: return "三分"
        case .golden: return "黄金"
        case .diagonal: return "对角"
        case .none: return "无"
        }
    }
}

/// 用 Vision 找地平线，把倾斜角换算成拉直角度。
enum HorizonDetector {
    static func straightenAngle(for image: CGImage) -> Double? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        // Vision 的角度与 Core Image 的旋转方向相反，直接用观察角即可抵消倾斜。
        return Double(observation.angle) * 180 / .pi
    }
}

// MARK: - 色彩分级

/// 单段色彩分级：色相 -1...1（映射 ±60°）、饱和 -1...1、亮度 -1...1。
struct EditGradeBand: Codable, Equatable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    static let neutral = EditGradeBand()

    var isNeutral: Bool {
        abs(hue) < 0.0001 && abs(saturation) < 0.0001 && abs(luminance) < 0.0001
    }
}

// MARK: - 画框

enum EditFrameStyle: String, Codable, CaseIterable, Identifiable {
    case none
    case white
    case black
    case polaroid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "无边框"
        case .white: return "白边"
        case .black: return "黑边"
        case .polaroid: return "拍立得"
        }
    }
}

// MARK: - 预设

struct EditPreset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var state: EditState
    var isBuiltin: Bool = false
}

/// 预设持久化：只存自定义预设，内置风格每次从代码生成。
enum EditPresetStore {
    static func loadCustom() -> [EditPreset] {
        guard let data = try? Data(contentsOf: LibraryPaths.presetsFile),
              let list = try? JSONDecoder().decode([EditPreset].self, from: data) else {
            return []
        }
        return list.filter { !$0.isBuiltin }
    }

    static func saveCustom(_ presets: [EditPreset]) {
        let custom = presets.filter { !$0.isBuiltin }
        guard let data = try? JSONEncoder().encode(custom) else { return }
        let url = LibraryPaths.presetsFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func export(_ presets: [EditPreset]) -> Data? {
        try? JSONEncoder().encode(presets)
    }

    static func decodeImport(_ data: Data) -> [EditPreset] {
        (try? JSONDecoder().decode([EditPreset].self, from: data)) ?? []
    }
}

/// 内置风格：只动基础参数、曲线、HSL、分级与胶片，不动几何与蒙版。
enum EditPresets {
    static var builtins: [EditPreset] {
        [
            preset("builtin.clear", "清透", .init()) { state in
                state.exposure = 0.06
                state.contrast = 0.08
                state.saturation = 0.06
                state.highlights = -0.12
                state.shadows = 0.14
                state.warmth = 0.02
                state.sharpness = 0.12
                state.curvePoints = curve(0, 0.22, 0.5, 0.78, 1)
            },
            preset("builtin.cream", "奶油", .init()) { state in
                state.exposure = 0.05
                state.contrast = -0.04
                state.warmth = 0.14
                state.tint = 0.03
                state.shadows = 0.1
                state.highlights = -0.05
                state.fade = 0.32
                state.grain = 0.1
                state.gradingBands = [
                    EditGradeBand(hue: 0.02, saturation: 0.12, luminance: 0.04),
                    EditGradeBand(hue: 0.05, saturation: 0.06, luminance: 0.03),
                    EditGradeBand(hue: 0.08, saturation: 0.1, luminance: 0.05)
                ]
            },
            preset("builtin.airy", "日系青", .init()) { state in
                state.exposure = 0.08
                state.contrast = -0.06
                state.saturation = -0.05
                state.highlights = -0.08
                state.shadows = 0.18
                state.warmth = -0.04
                state.fade = 0.22
                state.hslAdjustments = hsl(teal: 0.18, blue: 0.08, orange: -0.06)
                state.gradingBands = [
                    EditGradeBand(hue: -0.2, saturation: 0.16, luminance: 0.02),
                    EditGradeBand(),
                    EditGradeBand(hue: 0.35, saturation: 0.12, luminance: 0.04)
                ]
            },
            preset("builtin.cinematic", "电影青橙", .init()) { state in
                state.contrast = 0.14
                state.saturation = -0.08
                state.highlights = -0.16
                state.shadows = 0.1
                state.sharpness = 0.1
                state.fade = 0.12
                state.curvePoints = curve(0.03, 0.2, 0.48, 0.8, 0.97)
                state.gradingBands = [
                    EditGradeBand(hue: -0.55, saturation: 0.32, luminance: -0.02),
                    EditGradeBand(),
                    EditGradeBand(hue: 0.12, saturation: 0.26, luminance: 0.05)
                ]
            },
            preset("builtin.warmfilm", "暖调胶片", .init()) { state in
                state.exposure = 0.03
                state.warmth = 0.18
                state.tint = -0.03
                state.contrast = -0.06
                state.highlights = -0.1
                state.shadows = 0.08
                state.fade = 0.22
                state.grain = 0.3
                state.halation = 0.26
                state.curvePoints = curve(0.04, 0.24, 0.5, 0.78, 0.98)
                state.gradingBands = [
                    EditGradeBand(hue: 0.06, saturation: 0.18, luminance: 0.02),
                    EditGradeBand(hue: 0.1, saturation: 0.08, luminance: 0.02),
                    EditGradeBand(hue: 0.04, saturation: 0.14, luminance: 0.06)
                ]
            },
            preset("builtin.citycool", "冷调都市", .init()) { state in
                state.contrast = 0.16
                state.saturation = -0.12
                state.warmth = -0.14
                state.highlights = -0.1
                state.shadows = 0.06
                state.vignette = 0.15
                state.curvePoints = curve(0, 0.2, 0.5, 0.8, 1)
                state.gradingBands = [
                    EditGradeBand(hue: -0.72, saturation: 0.3, luminance: -0.02),
                    EditGradeBand(),
                    EditGradeBand(hue: -0.5, saturation: 0.12, luminance: 0.02)
                ]
            },
            preset("builtin.mono", "黑白高反差", .init()) { state in
                state.saturation = -1
                state.contrast = 0.24
                state.highlights = -0.08
                state.shadows = -0.06
                state.sharpness = 0.18
                state.grain = 0.26
                state.curvePoints = curve(0, 0.18, 0.5, 0.84, 1)
            },
            preset("builtin.faded", "褪色记忆", .init()) { state in
                state.contrast = -0.14
                state.saturation = -0.3
                state.warmth = 0.06
                state.highlights = -0.06
                state.shadows = 0.12
                state.fade = 0.5
                state.grain = 0.18
                state.curvePoints = curve(0.08, 0.26, 0.5, 0.74, 0.94)
            },
            preset("builtin.darkstill", "暗调静物", .init()) { state in
                state.exposure = -0.16
                state.contrast = 0.18
                state.saturation = -0.06
                state.highlights = -0.1
                state.shadows = -0.12
                state.vignette = 0.35
                state.grain = 0.12
                state.curvePoints = curve(0, 0.22, 0.5, 0.84, 1)
            }
        ]
    }

    /// 生成一条 5 点曲线，y 值依次对应 x = 0 / 0.25 / 0.5 / 0.75 / 1。
    static func curve(_ y0: Double, _ y1: Double, _ y2: Double,
                      _ y3: Double, _ y4: Double) -> [EditCurvePoint] {
        [EditCurvePoint(x: 0, y: y0),
         EditCurvePoint(x: 0.25, y: y1),
         EditCurvePoint(x: 0.5, y: y2),
         EditCurvePoint(x: 0.75, y: y3),
         EditCurvePoint(x: 1, y: y4)]
    }

    private static func hsl(teal: Double, blue: Double, orange: Double) -> [Double] {
        var values = [Double](repeating: 0, count: 24)
        // 色带索引：红 0 / 橙 1 / 黄 2 / 绿 3 / 青 4 / 蓝 5 / 紫 6 / 洋红 7，每段 3 个值。
        values[1 * 3 + 1] = orange
        values[4 * 3 + 1] = teal
        values[5 * 3 + 1] = blue
        return values
    }

    private static func preset(_ id: String, _ name: String,
                               _ base: EditState,
                               _ configure: (inout EditState) -> Void) -> EditPreset {
        var state = base
        configure(&state)
        return EditPreset(id: id, name: name, state: state, isBuiltin: true)
    }
}

// MARK: - 快照 / 选择性粘贴

struct EditSnapshot: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var state: EditState
}

struct EditPasteParts: OptionSet {
    let rawValue: Int
    static let basic = EditPasteParts(rawValue: 1 << 0)
    static let color = EditPasteParts(rawValue: 1 << 1)
    static let geometry = EditPasteParts(rawValue: 1 << 2)
    static let local = EditPasteParts(rawValue: 1 << 3)
    static let all: EditPasteParts = [.basic, .color, .geometry, .local]
}

extension EditState {
    /// 按分类合并另一份编辑点，用于「选择性粘贴」。
    func merging(_ other: EditState, parts: EditPasteParts) -> EditState {
        var result = self
        if parts.contains(.geometry) {
            result.rotation = other.rotation
            result.flipH = other.flipH
            result.flipV = other.flipV
            result.crop = other.crop
            result.aspect = other.aspect
            result.straighten = other.straighten
            result.lensDistortion = other.lensDistortion
            result.perspectiveV = other.perspectiveV
            result.perspectiveH = other.perspectiveH
            result.lensProfile = other.lensProfile
            result.lensVignetteFix = other.lensVignetteFix
        }
        if parts.contains(.basic) {
            result.filter = other.filter
            result.exposure = other.exposure
            result.brightness = other.brightness
            result.contrast = other.contrast
            result.saturation = other.saturation
            result.highlights = other.highlights
            result.shadows = other.shadows
            result.warmth = other.warmth
            result.tint = other.tint
            result.sharpness = other.sharpness
            result.vignette = other.vignette
            result.noiseReduction = other.noiseReduction
            result.autoEnhance = other.autoEnhance
        }
        if parts.contains(.color) {
            result.curvePoints = other.curvePoints
            result.curveRed = other.curveRed
            result.curveGreen = other.curveGreen
            result.curveBlue = other.curveBlue
            result.hslAdjustments = other.hslAdjustments
            result.gradingBands = other.gradingBands
            result.lutName = other.lutName
            result.lutStrength = other.lutStrength
            result.grain = other.grain
            result.halation = other.halation
            result.lightLeak = other.lightLeak
            result.fade = other.fade
            result.tiltBlur = other.tiltBlur
            result.zoomBlur = other.zoomBlur
            result.frameStyle = other.frameStyle
        }
        if parts.contains(.local) {
            result.masks = other.masks
            result.healSpots = other.healSpots
        }
        return result
    }

    /// 把某个风格按 0...1 强度叠加到当前参数上；几何、蒙版与修复保持不变。
    func applying(style: EditState, strength rawStrength: Double) -> EditState {
        Self.mixed(self, style, ratio: rawStrength)
    }

    /// 两套风格按比例混合；只混合颜色与基础参数，几何 / 蒙版 / 修复 / 画框保持第一套。
    static func mixed(_ first: EditState, _ second: EditState, ratio rawRatio: Double) -> EditState {
        let s = min(1, max(0, rawRatio))
        guard s > 0.0001 else { return first }
        var result = first
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * s }
        result.filter = s >= 0.5 ? second.filter : first.filter
        result.autoEnhance = s >= 0.5 ? second.autoEnhance : first.autoEnhance
        result.exposure = mix(first.exposure, second.exposure)
        result.brightness = mix(first.brightness, second.brightness)
        result.contrast = mix(first.contrast, second.contrast)
        result.saturation = mix(first.saturation, second.saturation)
        result.highlights = mix(first.highlights, second.highlights)
        result.shadows = mix(first.shadows, second.shadows)
        result.warmth = mix(first.warmth, second.warmth)
        result.tint = mix(first.tint, second.tint)
        result.sharpness = mix(first.sharpness, second.sharpness)
        result.vignette = mix(first.vignette, second.vignette)
        result.noiseReduction = mix(first.noiseReduction, second.noiseReduction)
        result.curvePoints = blendCurve(first.curvePoints, second.curvePoints, s)
        result.curveRed = blendCurve(first.curveRed, second.curveRed, s)
        result.curveGreen = blendCurve(first.curveGreen, second.curveGreen, s)
        result.curveBlue = blendCurve(first.curveBlue, second.curveBlue, s)
        result.hslAdjustments = blendValues(first.hslAdjustments, second.hslAdjustments, s)
        result.gradingBands = zip(first.gradingBands, second.gradingBands).map { a, b in
            EditGradeBand(hue: mix(a.hue, b.hue),
                          saturation: mix(a.saturation, b.saturation),
                          luminance: mix(a.luminance, b.luminance))
        }
        result.lutName = s >= 0.5 ? second.lutName : first.lutName
        result.lutStrength = mix(first.lutStrength, second.lutStrength)
        result.grain = mix(first.grain, second.grain)
        result.halation = mix(first.halation, second.halation)
        result.lightLeak = mix(first.lightLeak, second.lightLeak)
        result.fade = mix(first.fade, second.fade)
        result.tiltBlur = mix(first.tiltBlur, second.tiltBlur)
        result.zoomBlur = mix(first.zoomBlur, second.zoomBlur)
        return result
    }

    private static func blendCurve(_ current: [EditCurvePoint],
                                   _ target: [EditCurvePoint],
                                   _ t: Double) -> [EditCurvePoint] {
        guard current.count == target.count else { return t >= 0.5 ? target : current }
        return zip(current, target).map { a, b in
            EditCurvePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    private static func blendValues(_ current: [Double], _ target: [Double], _ t: Double) -> [Double] {
        guard current.count == target.count else { return t >= 0.5 ? target : current }
        return zip(current, target).map { $0 + ($1 - $0) * t }
    }
}

// MARK: - 3D LUT

enum EditLUTLoader {
    private static let lock = NSLock()
    private static var cache: [String: (data: Data, size: Int)] = [:]

    static func url(for name: String) -> URL {
        LibraryPaths.lutsDir.appendingPathComponent(name)
    }

    /// 把外部 .cube 复制进图库，返回库内文件名。
    static func importLUT(from url: URL) throws -> String {
        let name = url.lastPathComponent
        let destination = self.url(for: name)
        try FileManager.default.createDirectory(at: LibraryPaths.lutsDir,
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        lock.lock()
        cache[name] = nil
        lock.unlock()
        return name
    }

    static func load(name: String) -> (data: Data, size: Int)? {
        lock.lock()
        if let hit = cache[name] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let file = url(for: name)
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let parsed = parse(text) else { return nil }
        lock.lock()
        cache[name] = parsed
        lock.unlock()
        return parsed
    }

    static func parse(_ text: String) -> (data: Data, size: Int)? {
        var size = 0
        var values = [Float]()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last ?? "") ?? 0
                continue
            }
            if upper.hasPrefix("TITLE") || upper.hasPrefix("LUT_1D")
                || upper.hasPrefix("DOMAIN") || upper.hasPrefix("LUT_3D_INPUT") {
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3,
                  let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                continue
            }
            values.append(r)
            values.append(g)
            values.append(b)
            values.append(1)
        }
        guard size >= 2, size <= 64, values.count == size * size * size * 4 else { return nil }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return (data, size)
    }
}

// MARK: - 渲染：LUT / 胶片 / 创意虚化 / 画框

private enum EditFilmCache {
    static let lock = NSLock()
    static var grain: [String: CIImage] = [:]

    /// 颗粒噪声固定成一张图，避免每次调滑块都换一套随机纹理。
    static func noise(for extent: CGRect) -> CIImage? {
        let key = "\(Int(extent.width))x\(Int(extent.height))"
        lock.lock()
        if let hit = grain[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let grainScale = max(1, Double(extent.width) / 1200) * 1.7
        guard let image = CIFilter(name: "CIRandomGenerator")?.outputImage?
            .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.5
            ]) else { return nil }
        lock.lock()
        grain[key] = image
        if grain.count > 4 { grain.removeAll() }
        lock.unlock()
        return image
    }
}

extension PhotoRenderer {
    static func applyLUT(_ image: CIImage, name: String, strength: Double) -> CIImage {
        guard let lut = EditLUTLoader.load(name: name) else { return image }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let graded = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": lut.size,
            "inputCubeData": lut.data,
            "inputColorSpace": space
        ])
        let alpha = min(1, max(0, strength))
        if alpha >= 0.999 { return graded }
        return blended(graded, over: image, alpha: alpha, extent: image.extent)
    }

    static func applyFilm(_ image: CIImage, state: EditState) -> CIImage {
        var output = image
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return output }

        if state.fade > 0.001 {
            let amount = state.fade
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 - 0.2 * amount,
                kCIInputBrightnessKey: 0.012 * amount
            ])
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.035 * amount,
                                            y: 0.035 * amount,
                                            z: 0.035 * amount,
                                            w: 0)
            ])
        }

        if state.halation > 0.001 {
            let threshold = highlightCube(threshold: 0.66)
            var glow = output.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": 2,
                "inputCubeData": threshold,
                "inputColorSpace": CGColorSpaceCreateDeviceRGB()
            ])
            glow = glow.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: min(extent.width, extent.height) * 0.012
            ]).cropped(to: extent)
            glow = glow.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.7, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.38, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            let screened = glow.applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: output
            ])
            output = blended(screened, over: output, alpha: state.halation * 0.65, extent: extent)
        }

        if state.lightLeak > 0.001 {
            let leak = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: extent.maxX, y: extent.maxY),
                "inputRadius0": 0,
                "inputRadius1": max(extent.width, extent.height) * 0.9,
                "inputColor0": CIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            ])?.outputImage?.cropped(to: extent)
            if let leak {
                let screened = leak.applyingFilter("CIScreenBlendMode", parameters: [
                    kCIInputBackgroundImageKey: output
                ])
                output = blended(screened, over: output, alpha: state.lightLeak * 0.5, extent: extent)
            }
        }

        if state.grain > 0.001 {
            if let noise = EditFilmCache.noise(for: extent) {
                let mixed = noise.applyingFilter("CISoftLightBlendMode", parameters: [
                    kCIInputBackgroundImageKey: output
                ])
                output = blended(mixed, over: output, alpha: state.grain * 0.55, extent: extent)
            }
        }

        return output.cropped(to: extent)
    }

    static func applyCreativeBlur(_ image: CIImage, state: EditState) -> CIImage {
        let extent = image.extent
        var output = image
        guard extent.width > 1, extent.height > 1 else { return output }

        if state.tiltBlur > 0.001 {
            let radius = min(extent.width, extent.height) * (0.004 + 0.05 * state.tiltBlur)
            let blurred = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
            let band = extent.height * 0.2
            let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            let black = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            let top = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: extent.midX, y: extent.maxY),
                "inputPoint1": CIVector(x: extent.midX, y: extent.midY + band),
                "inputColor0": white,
                "inputColor1": black
            ])?.outputImage
            let bottom = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: extent.midX, y: extent.minY),
                "inputPoint1": CIVector(x: extent.midX, y: extent.midY - band),
                "inputColor0": white,
                "inputColor1": black
            ])?.outputImage
            if var mask = top {
                if let bottom {
                    mask = mask.applyingFilter("CIMaximumCompositing", parameters: [
                        kCIInputBackgroundImageKey: bottom
                    ])
                }
                mask = mask.cropped(to: extent)
                output = blurred.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: output,
                    kCIInputMaskImageKey: mask
                ])
            }
        }

        if state.zoomBlur > 0.001 {
            output = output.clampedToExtent()
                .applyingFilter("CIZoomBlur", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputAmountKey: state.zoomBlur * 42
                ])
                .cropped(to: extent)
        }

        return output.cropped(to: extent)
    }

    static func applyFrame(_ image: CIImage, style: EditFrameStyle) -> CIImage {
        guard style != .none else { return image }
        let extent = image.extent
        guard extent.width > 4, extent.height > 4 else { return image }
        let side = max(2, (extent.width * 0.035).rounded())
        let bottom = style == .polaroid ? max(side, (extent.width * 0.14).rounded()) : side
        let color: CIColor
        switch style {
        case .white: color = CIColor(red: 0.985, green: 0.98, blue: 0.97, alpha: 1)
        case .polaroid: color = CIColor(red: 0.97, green: 0.965, blue: 0.95, alpha: 1)
        case .black, .none: color = CIColor(red: 0.05, green: 0.05, blue: 0.055, alpha: 1)
        }
        let canvasRect = CGRect(x: 0, y: 0,
                                width: extent.width + side * 2,
                                height: extent.height + side + bottom).integral
        let canvas = CIImage(color: color).cropped(to: canvasRect)
        let placed = image.transformed(by: CGAffineTransform(
            translationX: side - extent.minX,
            y: bottom - extent.minY))
        return placed.composited(over: canvas).cropped(to: canvasRect)
    }

    /// 用均匀 alpha 把 top 叠回 bottom。
    private static func blended(_ top: CIImage, over bottom: CIImage,
                                alpha: Double, extent: CGRect) -> CIImage {
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1,
                                          alpha: CGFloat(min(1, max(0, alpha)))))
            .cropped(to: extent)
        return top.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: bottom,
            kCIInputMaskImageKey: mask
        ])
    }

    /// 2×2×2 的高光阈值立方体：亮度高于阈值输出白色，低于输出黑色。
    private static func highlightCube(threshold: Double) -> Data {
        var values = [Float]()
        for blueStep in 0..<2 {
            for greenStep in 0..<2 {
                for redStep in 0..<2 {
                    let luma = 0.2126 * Double(redStep) + 0.7152 * Double(greenStep)
                        + 0.0722 * Double(blueStep)
                    let value: Float = luma >= threshold ? 1 : 0
                    values.append(contentsOf: [value, value, value, 1])
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - 色彩分级色轮

struct EditGradeWheel: View {
    let title: String
    @Binding var band: EditGradeBand

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let size = min(proxy.size.width, proxy.size.height)
                let radius = size / 2
                ZStack {
                    Circle()
                        .fill(AngularGradient(colors: [
                            Color(hue: 0, saturation: 0.9, brightness: 0.95),
                            Color(hue: 0.17, saturation: 0.9, brightness: 0.95),
                            Color(hue: 0.33, saturation: 0.9, brightness: 0.95),
                            Color(hue: 0.5, saturation: 0.9, brightness: 0.95),
                            Color(hue: 0.67, saturation: 0.9, brightness: 0.95),
                            Color(hue: 0.83, saturation: 0.9, brightness: 0.95),
                            Color(hue: 1, saturation: 0.9, brightness: 0.95)
                        ], center: .center))
                        .overlay(
                            RadialGradient(colors: [Color.white.opacity(0.85), Color.clear],
                                           center: .center,
                                           startRadius: 0,
                                           endRadius: radius)
                        )
                        .clipShape(Circle())

                    Circle()
                        .stroke(Color.white, lineWidth: 1.6)
                        .frame(width: 10, height: 10)
                        .position(handlePosition(radius: radius))
                        .shadow(color: .black.opacity(0.4), radius: 1)
                }
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let dx = value.location.x - radius
                            let dy = value.location.y - radius
                            let distance = sqrt(dx * dx + dy * dy)
                            guard distance > 0.001 else { return }
                            var hue = atan2(dy, dx) / (2 * .pi)
                            if hue < 0 { hue += 1 }
                            band.hue = hue > 0.5 ? hue - 1 : hue
                            band.saturation = min(1, distance / radius)
                        }
                )
            }
            .frame(width: 84, height: 84)

            Slider(value: $band.luminance, in: -1...1)
                .controlSize(.mini)
        }
    }

    private func handlePosition(radius: CGFloat) -> CGPoint {
        let hue = band.hue < 0 ? band.hue + 1 : band.hue
        let angle = CGFloat(hue) * 2 * .pi
        let distance = CGFloat(min(1, band.saturation)) * radius * 0.88
        return CGPoint(x: radius + cos(angle) * distance,
                       y: radius + sin(angle) * distance)
    }
}

// MARK: - 面板：颜色升级版

struct EditColorPanel: View {
    @Binding var hsl: [Double]
    @Binding var grading: [EditGradeBand]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditHSLPanel(values: $hsl)

            Divider()

            Text("色彩分级")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(grading.indices), id: \.self) { index in
                    EditGradeWheel(title: ["阴影", "中间调", "高光"][index],
                                   band: Binding(
                                    get: { index < grading.count ? grading[index] : .neutral },
                                    set: {
                                        guard index < grading.count else { return }
                                        grading[index] = $0
                                    }
                                   ))
                }
            }

            Button("重置分级") {
                grading = [.neutral, .neutral, .neutral]
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.accentColor)

            Text("分级按亮度分区上色：给阴影压青、高光加暖，是最快做出电影感的方法。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 面板：风格（LUT + 胶片）

struct EditStylePanel: View {
    let lutName: String?
    @Binding var lutStrength: Double
    @Binding var grain: Double
    @Binding var halation: Double
    @Binding var lightLeak: Double
    @Binding var fade: Double
    let onImportLUT: () -> Void
    let onRemoveLUT: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("3D LUT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(lutName ?? "未加载")
                        .font(.system(size: 11.5))
                        .foregroundStyle(lutName == nil ? .tertiary : .primary)
                        .lineLimit(1)
                }
                Spacer()
                Button(lutName == nil ? "导入…" : "更换…", action: onImportLUT)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)
                if lutName != nil {
                    Button("移除", action: onRemoveLUT)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            if lutName != nil {
                slider("LUT 强度", value: $lutStrength, range: 0...1)
            }

            Divider()

            Text("胶片质感")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            slider("颗粒", value: $grain, range: 0...1)
            slider("高光光晕", value: $halation, range: 0...1)
            slider("漏光", value: $lightLeak, range: 0...1)
            slider("褪色", value: $fade, range: 0...1)

            Button("清除胶片质感") {
                grain = 0
                halation = 0
                lightLeak = 0
                fade = 0
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.accentColor)

            Text("光晕只影响高光，颗粒随画面尺寸缩放；漏光从右上角进入，适合暖调回忆。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12))
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

// MARK: - 面板：创意（虚化 + 画框）

struct EditCreativePanel: View {
    @Binding var tiltBlur: Double
    @Binding var zoomBlur: Double
    @Binding var frameStyle: EditFrameStyle
    let onCinematic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onCinematic) {
                HStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("一键电影感")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("2.39:1 + 青橙分级 + 颗粒 + 光晕")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Color(red: 0.1, green: 0.35, blue: 0.4),
                                                  Color(red: 0.55, green: 0.3, blue: 0.15)],
                                         startPoint: .leading,
                                         endPoint: .trailing)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Divider()

            Text("虚化")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            slider("移轴 / 上下模糊", value: $tiltBlur, range: 0...1)
            slider("径向模糊", value: $zoomBlur, range: 0...1)

            Button("清除虚化") {
                tiltBlur = 0
                zoomBlur = 0
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.accentColor)

            Divider()

            Text("画框")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(EditFrameStyle.allCases) { style in
                    Button {
                        frameStyle = style
                    } label: {
                        Text(style.title)
                            .font(.system(size: 11.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(frameStyle == style ? Color.accentColor : Color.primary.opacity(0.08)))
                            .foregroundStyle(frameStyle == style ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("虚化与画框只改最终画面，不影响蒙版和修复的坐标；画框在保存时烘焙进副本。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12))
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

// MARK: - 面板：预设 + 快照

struct EditPresetsPanel: View {
    let builtins: [EditPreset]
    let custom: [EditPreset]
    let thumbnails: [String: NSImage]
    @Binding var strength: Double
    let selectionCount: Int
    let onApply: (EditPreset) -> Void
    let onSaveCurrent: () -> Void
    let onDelete: (EditPreset) -> Void
    let onImport: () -> Void
    let onExport: () -> Void
    let onApplyToSelection: () -> Void
    let snapshots: [EditSnapshot]
    let onSnapshot: () -> Void
    let onRestoreSnapshot: (EditSnapshot) -> Void
    let onDeleteSnapshot: (EditSnapshot) -> Void
    let recommendations: [SceneRecommendation]
    let onApplyRecommendation: (SceneRecommendation) -> Void
    let onApplyMixed: (EditState) -> Void

    @State private var mixA: String = ""
    @State private var mixB: String = ""
    @State private var mixRatio: Double = 0.5

    private var allPresets: [EditPreset] { builtins + custom }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            strengthControl

            if !recommendations.isEmpty {
                recommendationSection
            }

            section("内置风格", presets: builtins)

            if !custom.isEmpty {
                section("我的预设", presets: custom)
            }

            HStack(spacing: 10) {
                Button("保存当前为预设", action: onSaveCurrent)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button("导入…", action: onImport)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Button("导出…", action: onExport)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if selectionCount > 0 {
                Button("套用到选中的 \(selectionCount) 张照片", action: onApplyToSelection)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .font(.system(size: 11.5))
            }

            Divider()

            styleMixer

            Divider()

            HStack {
                Text("快照")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("存快照", action: onSnapshot)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)
            }

            if snapshots.isEmpty {
                Text("保存当前所有参数，之后可以一键回到这个状态（仅本次编辑有效）。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(snapshots) { snapshot in
                    HStack(spacing: 8) {
                        Text(snapshot.name)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer()
                        Button("恢复") { onRestoreSnapshot(snapshot) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                        Button {
                            onDeleteSnapshot(snapshot)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Text("预设不改动裁剪、蒙版与修复点；组合预设时可用强度控制风格浓度。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if mixA.isEmpty { mixA = builtins.first?.id ?? "" }
            if mixB.isEmpty { mixB = builtins.dropFirst().first?.id ?? mixA }
        }
    }

    private var recommendationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("为这张照片推荐")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(recommendations) { recommendation in
                Button {
                    onApplyRecommendation(recommendation)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(presetName(for: recommendation.presetID))
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recommendation.scene)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Text(recommendation.reason)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var styleMixer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("风格混合")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                mixMenu(selection: $mixA)
                Text("+")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                mixMenu(selection: $mixB)
            }

            HStack(spacing: 8) {
                Text("比例")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Slider(value: $mixRatio, in: 0...1)
                    .controlSize(.mini)
                Text("\(Int(mixRatio * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button("应用混合风格") {
                guard let first = allPresets.first(where: { $0.id == mixA }),
                      let second = allPresets.first(where: { $0.id == mixB }) else { return }
                onApplyMixed(EditState.mixed(first.state, second.state, ratio: mixRatio))
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.accentColor)
        }
    }

    private func mixMenu(selection: Binding<String>) -> some View {
        Menu(presetName(for: selection.wrappedValue)) {
            ForEach(allPresets) { preset in
                Button(preset.name) { selection.wrappedValue = preset.id }
            }
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity)
    }

    private func presetName(for id: String) -> String {
        allPresets.first { $0.id == id }?.name ?? "选择风格"
    }

    private var strengthControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("风格强度")
                    .font(.system(size: 12))
                Spacer()
                Text("\(Int(strength * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $strength, in: 0...1)
                .controlSize(.small)
        }
    }

    private func section(_ title: String, presets: [EditPreset]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(presets) { preset in
                    ZStack(alignment: .topTrailing) {
                        Button {
                            onApply(preset)
                        } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.08))
                                    if let thumb = thumbnails[preset.id] {
                                        Image(nsImage: thumb)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    }
                                }
                                .frame(height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(preset.name)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)

                        if !preset.isBuiltin {
                            Button {
                                onDelete(preset)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.5), radius: 1)
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .help("删除预设")
                        }
                    }
                }
            }
        }
    }
}
