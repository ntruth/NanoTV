import SwiftUI
import CoreImage
import LumaCore
import AppKit
import UniformTypeIdentifiers

struct EditState: Equatable, Codable {
    var rotation: Int = 0
    var flipH = false
    var flipV = false
    var crop = EditState.fullCrop
    var aspect: CropAspect = .original
    var filter: FilterPreset = .none
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var sharpness: Double = 0
    var vignette: Double = 0
    var noiseReduction: Double = 0
    var autoEnhance = false

    // 高级调整：曲线、HSL、局部蒙版、修复点、镜头与透视。
    var curvePoints: [EditCurvePoint] = EditCurvePoint.identity
    var curveRed: [EditCurvePoint] = EditCurvePoint.identity
    var curveGreen: [EditCurvePoint] = EditCurvePoint.identity
    var curveBlue: [EditCurvePoint] = EditCurvePoint.identity
    var hslAdjustments: [Double] = Array(repeating: 0, count: 24)
    /// 色彩分级：阴影 / 中间调 / 高光三段，各一条色相 + 饱和 + 亮度。
    var gradingBands: [EditGradeBand] = [.neutral, .neutral, .neutral]
    var masks: [EditMask] = []
    var healSpots: [EditHealSpot] = []
    var lensDistortion: Double = 0
    var perspectiveV: Double = 0
    var perspectiveH: Double = 0
    var lensProfile: EditLensProfile = .none
    var lensVignetteFix: Double = 0
    /// 拉直角度（度）：正数顺时针。
    var straighten: Double = 0
    /// 风格：3D LUT、胶片颗粒 / 光晕 / 漏光 / 褪色。
    var lutName: String?
    var lutStrength: Double = 0.8
    var grain: Double = 0
    var halation: Double = 0
    var lightLeak: Double = 0
    var fade: Double = 0
    /// 创意虚化与画框。
    var tiltBlur: Double = 0
    var zoomBlur: Double = 0
    var frameStyle: EditFrameStyle = .none

    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    init() {}

    enum CodingKeys: String, CodingKey {
        case rotation, flipH, flipV, crop, aspect, filter
        case exposure, brightness, contrast, saturation, highlights, shadows
        case warmth, tint, sharpness, vignette, noiseReduction, autoEnhance
        case curvePoints, curveRed, curveGreen, curveBlue
        case hslAdjustments, gradingBands, masks, healSpots
        case lensDistortion, perspectiveV, perspectiveH, straighten
        case lensProfile, lensVignetteFix
        case lutName, lutStrength, grain, halation, lightLeak, fade
        case tiltBlur, zoomBlur, frameStyle
    }

    /// 旧配方没有高级字段，缺省即默认值；不能因为新增字段让老编辑点解码失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        flipH = try container.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        flipV = try container.decodeIfPresent(Bool.self, forKey: .flipV) ?? false
        crop = try container.decodeIfPresent(CGRect.self, forKey: .crop) ?? EditState.fullCrop
        aspect = try container.decodeIfPresent(CropAspect.self, forKey: .aspect) ?? .original
        filter = try container.decodeIfPresent(FilterPreset.self, forKey: .filter) ?? .none
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        vignette = try container.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        noiseReduction = try container.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        autoEnhance = try container.decodeIfPresent(Bool.self, forKey: .autoEnhance) ?? false
        curvePoints = try container.decodeIfPresent([EditCurvePoint].self, forKey: .curvePoints)
            ?? EditCurvePoint.identity
        curveRed = try container.decodeIfPresent([EditCurvePoint].self, forKey: .curveRed)
            ?? EditCurvePoint.identity
        curveGreen = try container.decodeIfPresent([EditCurvePoint].self, forKey: .curveGreen)
            ?? EditCurvePoint.identity
        curveBlue = try container.decodeIfPresent([EditCurvePoint].self, forKey: .curveBlue)
            ?? EditCurvePoint.identity
        var hsl = try container.decodeIfPresent([Double].self, forKey: .hslAdjustments) ?? []
        if hsl.count != 24 { hsl = Array(repeating: 0, count: 24) }
        hslAdjustments = hsl
        var grading = try container.decodeIfPresent([EditGradeBand].self, forKey: .gradingBands) ?? []
        if grading.count != 3 { grading = [.neutral, .neutral, .neutral] }
        gradingBands = grading
        masks = try container.decodeIfPresent([EditMask].self, forKey: .masks) ?? []
        healSpots = try container.decodeIfPresent([EditHealSpot].self, forKey: .healSpots) ?? []
        lensDistortion = try container.decodeIfPresent(Double.self, forKey: .lensDistortion) ?? 0
        perspectiveV = try container.decodeIfPresent(Double.self, forKey: .perspectiveV) ?? 0
        perspectiveH = try container.decodeIfPresent(Double.self, forKey: .perspectiveH) ?? 0
        lensProfile = try container.decodeIfPresent(EditLensProfile.self, forKey: .lensProfile) ?? .none
        lensVignetteFix = try container.decodeIfPresent(Double.self, forKey: .lensVignetteFix) ?? 0
        straighten = try container.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        lutName = try container.decodeIfPresent(String.self, forKey: .lutName)
        lutStrength = try container.decodeIfPresent(Double.self, forKey: .lutStrength) ?? 0.8
        grain = try container.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        halation = try container.decodeIfPresent(Double.self, forKey: .halation) ?? 0
        lightLeak = try container.decodeIfPresent(Double.self, forKey: .lightLeak) ?? 0
        fade = try container.decodeIfPresent(Double.self, forKey: .fade) ?? 0
        tiltBlur = try container.decodeIfPresent(Double.self, forKey: .tiltBlur) ?? 0
        zoomBlur = try container.decodeIfPresent(Double.self, forKey: .zoomBlur) ?? 0
        frameStyle = try container.decodeIfPresent(EditFrameStyle.self, forKey: .frameStyle) ?? .none
    }

    var isModified: Bool {
        rotation != 0 || flipH || flipV || crop != EditState.fullCrop || filter != .none
            || exposure != 0 || brightness != 0 || contrast != 0 || saturation != 0
            || highlights != 0 || shadows != 0 || warmth != 0 || tint != 0
            || sharpness != 0 || vignette != 0 || noiseReduction != 0 || autoEnhance
            || !EditCurve.isIdentity(curvePoints)
            || !EditCurve.isIdentity(curveRed)
            || !EditCurve.isIdentity(curveGreen)
            || !EditCurve.isIdentity(curveBlue)
            || hslAdjustments.contains { abs($0) > 0.0001 }
            || gradingBands.contains { !$0.isNeutral }
            || !masks.isEmpty || !healSpots.isEmpty
            || lensDistortion != 0 || perspectiveV != 0 || perspectiveH != 0
            || lensVignetteFix != 0
            || straighten != 0
            || lutName != nil
            || grain != 0 || halation != 0 || lightLeak != 0 || fade != 0
            || tiltBlur != 0 || zoomBlur != 0
            || frameStyle != .none
    }

    func cropless() -> EditState {
        var copy = self
        copy.crop = EditState.fullCrop
        return copy
    }
}

extension EditState {
    /// 序列化为 JSON，供复制/粘贴编辑点与再次打开编辑器时恢复。
    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(EditState.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

enum EditTool: String, CaseIterable, Identifiable {
    case adjust = "调整"
    case curve = "曲线"
    case hsl = "颜色"
    case presets = "预设"
    case style = "风格"
    case mask = "蒙版"
    case heal = "修复"
    case optics = "镜头"
    case creative = "创意"
    case filters = "滤镜"
    case crop = "裁剪"
    case poster = "海报"
    case beauty = "美化"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .adjust: return "slider.horizontal.3"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .hsl: return "paintpalette"
        case .presets: return "square.grid.2x2"
        case .style: return "camera.filters"
        case .mask: return "circle.dashed"
        case .heal: return "bandage"
        case .optics: return "camera.aperture"
        case .creative: return "sparkles"
        case .filters: return "camera.metering.center.weighted"
        case .crop: return "crop"
        case .poster: return "doc.richtext"
        case .beauty: return "wand.and.stars"
        }
    }

    /// 蒙版 / 修复需要看到未裁剪的整图，坐标才不会被裁掉。
    var needsFullFrame: Bool {
        self == .crop || self == .mask || self == .heal
    }
}

enum PhotoRenderer {
    private static let context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])

    static func loadBase(url: URL) -> CIImage? {
        if RawFormats.isRaw(url) {
            if let image = RawFormats.ciImage(url: url, maxPixel: 8000) {
                return normalized(image)
            }
        }
        let options: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .cacheImmediately: true
        ]
        guard let image = CIImage(contentsOf: url, options: options) else { return nil }
        return normalized(image)
    }

    static func normalized(_ image: CIImage) -> CIImage {
        let extent = image.extent
        if extent.origin != .zero {
            return image.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                           y: -extent.origin.y))
        }
        return image
    }

    static func render(base: CIImage, state: EditState, maxPixel: CGFloat?) -> NSImage? {
        guard let cgImage = renderCG(base: base, state: state, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func renderCG(base: CIImage, state: EditState, maxPixel: CGFloat?) -> CGImage? {
        var ci = base

        let steps = (((state.rotation % 360) + 360) % 360) / 90
        if steps != 0 {
            ci = ci.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(steps) * .pi / 2))
            ci = normalized(ci)
        }
        if state.flipH {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            ci = normalized(ci)
        }
        if state.flipV {
            ci = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            ci = normalized(ci)
        }
        if state.straighten != 0 {
            ci = straightened(ci, degrees: state.straighten)
        }

        if state.noiseReduction > 0 {
            ci = ci.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.01 + state.noiseReduction * 0.08,
                "inputSharpness": 0.4
            ])
        }
        if state.autoEnhance {
            for filter in ci.autoAdjustmentFilters() {
                filter.setValue(ci, forKey: kCIInputImageKey)
                if let output = filter.outputImage {
                    ci = output
                }
            }
        }
        if state.exposure != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: state.exposure])
        }
        if state.highlights != 0 || state.shadows != 0 {
            ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": min(1, max(0, 1 - state.highlights)),
                "inputShadowAmount": min(1, max(-1, state.shadows))
            ])
        }
        if state.warmth != 0 || state.tint != 0 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + state.warmth * 2600, y: state.tint * 120)
            ])
        }
        if state.brightness != 0 || state.contrast != 0 || state.saturation != 0 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: state.brightness,
                kCIInputContrastKey: 1 + state.contrast,
                kCIInputSaturationKey: 1 + state.saturation
            ])
        }
        if state.sharpness > 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: state.sharpness * 1.2
            ])
        }
        if let filterName = state.filter.ciName {
            ci = ci.applyingFilter(filterName)
        }
        if state.vignette != 0 {
            ci = ci.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: state.vignette * 1.6,
                kCIInputRadiusKey: 1.6
            ])
        }

        // 曲线 / HSL / 局部蒙版 / 修复 / 镜头透视：都在裁剪之前处理。
        ci = applyAdvanced(ci, state: state)

        let extent = ci.extent
        if state.crop != EditState.fullCrop {
            let rect = CGRect(
                x: extent.minX + state.crop.minX * extent.width,
                y: extent.minY + (1 - state.crop.maxY) * extent.height,
                width: max(1, state.crop.width * extent.width),
                height: max(1, state.crop.height * extent.height)
            ).integral
            ci = ci.cropped(to: rect)
            ci = normalized(ci)
        }

        if let maxPixel {
            let width = ci.extent.width
            let height = ci.extent.height
            let scale = min(1, maxPixel / max(width, height))
            if scale < 1 {
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                ci = normalized(ci)
            }
        }

        if state.frameStyle != .none {
            ci = applyFrame(ci, style: state.frameStyle)
        }

        return context.createCGImage(ci, from: ci.extent)
    }

    /// 拉直：绕中心旋转后裁出最大的同比例内接矩形，避免四角露黑。
    static func straightened(_ image: CIImage, degrees: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, abs(degrees) > 0.001 else { return image }
        let angle = CGFloat(degrees) * .pi / 180
        let cw = cos(abs(angle))
        let sw = sin(abs(angle))
        let width = extent.width
        let height = extent.height
        let scale = min(width / (width * cw + height * sw),
                        height / (width * sw + height * cw))
        let target = CGSize(width: width * scale, height: height * scale)
        let cropRect = CGRect(x: -target.width / 2, y: -target.height / 2,
                              width: target.width, height: target.height).integral
            .insetBy(dx: 1, dy: 1)
        let rotated = image
            .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
            .transformed(by: CGAffineTransform(rotationAngle: angle))
            .cropped(to: cropRect)
        return normalized(rotated)
    }
}

struct PhotoEditorView: View {
    @EnvironmentObject private var store: LibraryStore
    let photo: PhotoItem

    @State private var state = EditState()
    @State private var tool: EditTool = .adjust
    @State private var baseCI: CIImage?
    @State private var basePixelSize: CGSize = .zero
    @State private var preview: NSImage?
    @State private var filterThumbs: [FilterPreset: NSImage] = [:]
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var dragStartCrop: CGRect?

    // 高级调整：直方图、前后对比、蒙版选择与修复画笔。
    @State private var histogram = EditHistogram()
    @State private var histogramToken = 0
    @State private var showOriginal = false
    @State private var originalPreview: NSImage?
    @State private var maskSelection: UUID?
    @State private var healBrushRadius: Double = 0.03
    @State private var maskDragID: UUID?
    @State private var maskDragOrigin: CGPoint?
    @State private var maskBrushRadius: Double = 0.06
    @State private var maskBrushErase = false
    @State private var brushCursor: CGPoint?
    @State private var lastBrushPoint: CGPoint?
    @State private var cloneMode = false
    @State private var pendingCloneSource: CGPoint?

    // 海报模板。
    @State private var posterTemplate: PosterTemplate = .magazine
    @State private var posterTitle = ""
    @State private var posterSubtitle = "MEMORIES"
    @State private var posterLocation = ""
    @State private var posterDate = ""
    @State private var posterSignature = ""
    @State private var isExportingPoster = false
    @State private var posterPhotoID: UUID?

    // 吸管、分屏、裁剪拉直与网格。
    @State private var sampleImage: EditSampleImage?
    @State private var eyedropperOn = false
    @State private var eyedropperColor: (Int, Int, Int)?
    @State private var compareMode: CompareMode = .off
    @State private var splitFraction: CGFloat = 0.5
    @State private var cropGrid: CropGridStyle = .thirds
    @State private var isAutoStraightening = false

    // 预设、快照与批量套用。
    @State private var presetStrength: Double = 1
    @State private var builtinPresets: [EditPreset] = EditPresets.builtins
    @State private var customPresets: [EditPreset] = []
    @State private var presetThumbs: [String: NSImage] = [:]
    @State private var snapshots: [EditSnapshot] = []
    @State private var sceneRecommendations: [SceneRecommendation] = []

    // 智能美化：分析结果、强度与应用前快照（撤销用）。
    @State private var beautyAdvice: BeautyAdvice?
    @State private var beautyStrength: Double = 1
    @State private var beautyBase: EditState?
    @State private var isBeautifying = false

    // 撤销 / 重做：连续拖动滑块会被合并为一步。
    @State private var history: [EditState] = []
    @State private var redoStack: [EditState] = []
    @State private var pendingSnapshot: EditState?
    @State private var historyTask: Task<Void, Never>?
    @State private var suppressHistory = false
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                HStack(spacing: 0) {
                    previewArea
                    controlPanel
                        .frame(width: 312)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .task {
            await load()
        }
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            historyTask?.cancel()
            historyTask = nil
        }
        .onChange(of: state) { oldValue, newValue in
            let suppressed = suppressHistory
            suppressHistory = false

            if tool == .crop {
                var oldAdjusted = oldValue
                oldAdjusted.crop = EditState.fullCrop
                var newAdjusted = newValue
                newAdjusted.crop = EditState.fullCrop
                if oldAdjusted != newAdjusted {
                    refreshPreview()
                }
            } else {
                refreshPreview()
            }

            if !suppressed {
                scheduleHistory(oldValue)
            }
        }
        .onChange(of: tool) { _, newValue in
            refreshPreview()
            if newValue == .beauty, beautyAdvice == nil {
                analyzeBeauty()
            }
            if newValue == .presets {
                refreshPresetThumbs()
                refreshSceneRecommendations()
            }
            if newValue != .mask {
                brushCursor = nil
                lastBrushPoint = nil
            }
            if newValue != .heal {
                pendingCloneSource = nil
            }
        }
        .onChange(of: cloneMode) { _, newValue in
            if !newValue { pendingCloneSource = nil }
        }
        .onChange(of: beautyStrength) { _, _ in
            // 拖动强度时按「应用前的快照 + 建议 × 强度」重算，而不是在已应用的结果上继续叠加。
            guard let base = beautyBase, let advice = beautyAdvice else { return }
            apply(EditState.beautified(base, advice: advice, strength: beautyStrength))
        }
    }

    private var canUndo: Bool { !history.isEmpty || pendingSnapshot != nil }
    private var canRedo: Bool { !redoStack.isEmpty }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("取消") {
                store.closeEditor()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)

            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canUndo ? Color.primary : Color.secondary.opacity(0.45))
            .disabled(!canUndo)
            .help("撤销 (⌘Z)")

            Button {
                redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canRedo ? Color.primary : Color.secondary.opacity(0.45))
            .disabled(!canRedo)
            .help("重做 (⇧⌘Z)")

            Menu {
                Button("复制编辑点") {
                    guard let json = state.jsonString else { return }
                    store.copiedEditRecipe = json
                    store.showToast("已复制编辑点")
                }
                .disabled(!state.isModified)

                Menu("粘贴编辑点") {
                    Button("全部") { pasteEdits(.all) }
                    Button("仅基础调整") { pasteEdits(.basic) }
                    Button("仅颜色与风格") { pasteEdits(.color) }
                    Button("仅几何与镜头") { pasteEdits(.geometry) }
                    Button("仅蒙版与修复") { pasteEdits(.local) }
                }
                .disabled(store.copiedEditRecipe == nil)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("复制 / 粘贴编辑点")

            Spacer()

            Text("编辑")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Button("还原") {
                resetAll()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .disabled(!state.isModified && !photo.hasEdits)

            Button {
                save()
            } label: {
                Text(isSaving ? "存储中…" : "完成")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(baseCI == nil || isSaving)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var previewArea: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else if let preview {
                    if compareMode == .split, let originalPreview {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        Image(nsImage: originalPreview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: proxy.size.width * splitFraction)
                            }
                        splitHandle(container: proxy.size)
                    } else {
                        Image(nsImage: showOriginal ? (originalPreview ?? preview) : preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }

                    if state.frameStyle != .none,
                       tool != .crop, tool != .mask, tool != .heal {
                        frameOverlay(container: proxy.size)
                            .allowsHitTesting(false)
                    }

                    if tool == .crop {
                        cropOverlay(container: proxy.size)
                    }
                    if tool == .mask {
                        maskOverlay(container: proxy.size)
                    }
                    if tool == .heal {
                        healOverlay(container: proxy.size)
                    }

                    if eyedropperOn {
                        eyedropperOverlay(container: proxy.size)
                    }

                    if let color = eyedropperColor {
                        eyedropperReadout(color)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(14)
                    }

                    compareControl
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(14)
                } else {
                    Text("无法载入照片")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(24)
    }

    private func splitHandle(container: CGSize) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 1, height: container.height)
                .position(x: container.width * splitFraction, y: container.height / 2)

            Circle()
                .fill(Color.white)
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.black)
                }
                .position(x: container.width * splitFraction, y: container.height / 2)

            Color.clear
                .frame(width: 28, height: container.height)
                .contentShape(Rectangle())
                .position(x: container.width * splitFraction, y: container.height / 2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            splitFraction = min(1, max(0, value.location.x / max(1, container.width)))
                        }
                )
        }
    }

    /// 画框在预览里用 SwiftUI 叠一层，保存时才烘焙进副本。
    private func frameOverlay(container: CGSize) -> some View {
        let rect = frameContentRect(container: container)
        let color: Color = state.frameStyle == .black ? Color(white: 0.06) : Color(white: 0.97)
        return Path { path in
            path.addRect(rect.outer)
            path.addRect(rect.inner)
        }
        .fill(color, style: FillStyle(eoFill: true))
    }

    private func frameContentRect(container: CGSize) -> (outer: CGRect, inner: CGRect) {
        let fit = fitRect(imageSize: preview?.size ?? .zero, in: container)
        guard state.frameStyle != .none,
              tool != .crop, tool != .mask, tool != .heal else {
            return (fit, fit)
        }
        let side = fit.width * 0.035
        let bottom = state.frameStyle == .polaroid ? fit.width * 0.14 : side
        let inner = CGRect(x: fit.minX + side,
                           y: fit.minY + side,
                           width: max(1, fit.width - side * 2),
                           height: max(1, fit.height - side - bottom))
        return (fit, inner)
    }

    private func eyedropperOverlay(container: CGSize) -> some View {
        let rect = frameContentRect(container: container).inner
        return Color.clear
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .contentShape(Rectangle())
            .position(x: rect.midX, y: rect.midY)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let x = Double(min(1, max(0, point.x / max(1, rect.width))))
                    let y = Double(min(1, max(0, point.y / max(1, rect.height))))
                    if let sample = sampleImage?.color(atX: x, y: y) {
                        eyedropperColor = sample
                    }
                case .ended:
                    break
                }
            }
    }

    private func eyedropperReadout(_ color: (Int, Int, Int)) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: Double(color.0) / 255,
                            green: Double(color.1) / 255,
                            blue: Double(color.2) / 255))
                .frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "#%02X%02X%02X", color.0, color.1, color.2))
                    .font(.system(size: 10.5, design: .monospaced))
                Text("R \(color.0)  G \(color.1)  B \(color.2)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.62)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(Color.white.opacity(0.16), lineWidth: 0.5))
    }

    private func cropOverlay(container: CGSize) -> some View {
        let imageSize = preview?.size ?? CGSize(width: 1, height: 1)
        let fit = fitRect(imageSize: imageSize, in: container)
        let cropRect = CGRect(
            x: fit.minX + state.crop.minX * fit.width,
            y: fit.minY + state.crop.minY * fit.height,
            width: state.crop.width * fit.width,
            height: state.crop.height * fit.height
        )

        return ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: container))
                path.addRect(cropRect)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                path.addPath(gridPath(in: cropRect))
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .allowsHitTesting(false)

            Color.clear
                .frame(width: cropRect.width, height: cropRect.height)
                .contentShape(Rectangle())
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStartCrop ?? state.crop
                            if dragStartCrop == nil { dragStartCrop = start }
                            let dx = value.translation.width / max(1, fit.width)
                            let dy = value.translation.height / max(1, fit.height)
                            let newX = min(max(0, start.minX + dx), 1 - start.width)
                            let newY = min(max(0, start.minY + dy), 1 - start.height)
                            state.crop = CGRect(x: newX, y: newY, width: start.width, height: start.height)
                        }
                        .onEnded { _ in
                            dragStartCrop = nil
                        }
                )
        }
    }

    private var compareControl: some View {
        HStack(spacing: 6) {
            chip("分屏", icon: "rectangle.split.2x1", active: compareMode == .split) {
                if compareMode == .split {
                    compareMode = .off
                } else {
                    compareMode = .split
                    refreshOriginalPreview(force: true)
                }
            }

            chip("吸管", icon: "eyedropper", active: eyedropperOn) {
                eyedropperOn.toggle()
                if !eyedropperOn { eyedropperColor = nil }
            }

            HStack(spacing: 5) {
                Image(systemName: "rectangle.split.2x1")
                Text(showOriginal ? "原图" : "按住对比")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .foregroundStyle(.white)
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: 0.05, maximumDistance: 24, pressing: { pressing in
                showOriginal = pressing
                if pressing { refreshOriginalPreview() }
            }, perform: {})
            .help("按住查看原图（也可按住 \\ 键）")
        }
    }

    private func chip(_ title: String, icon: String, active: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(active ? Color.accentColor.opacity(0.9)
                                                  : Color.black.opacity(0.55)))
                .foregroundStyle(.white)
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func maskOverlay(container: CGSize) -> some View {
        let fit = fitRect(imageSize: preview?.size ?? .zero, in: container)
        return ZStack {
            ForEach(state.masks) { mask in
                if mask.kind == .radial || mask.kind == .linear {
                    maskShape(mask, fit: fit)
                        .allowsHitTesting(false)

                    Circle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: 30, height: 30)
                        .position(maskCenter(mask, fit: fit))
                        .gesture(maskDragGesture(mask: mask, fit: fit))
                } else if mask.kind == .brush {
                    brushDabsOverlay(mask, fit: fit)
                }
            }

            if let index = activeBrushMaskIndex {
                brushCanvas(index: index, fit: fit)
                if let cursor = brushCursor {
                    let radius = max(4, maskBrushRadius * min(fit.width, fit.height))
                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 1)
                        .background(Circle().fill(Color.accentColor.opacity(0.12)))
                        .frame(width: radius * 2, height: radius * 2)
                        .position(x: fit.minX + cursor.x, y: fit.minY + cursor.y)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var activeBrushMaskIndex: Int? {
        guard tool == .mask else { return nil }
        let resolved = maskSelection.flatMap { selected in
            state.masks.contains(where: { $0.id == selected }) ? selected : nil
        } ?? state.masks.first?.id
        guard let resolved,
              let index = state.masks.firstIndex(where: { $0.id == resolved }),
              state.masks[index].kind == .brush else { return nil }
        return index
    }

    @ViewBuilder
    private func brushDabsOverlay(_ mask: EditMask, fit: CGRect) -> some View {
        ForEach(Array(mask.brushDabs.suffix(600).enumerated()), id: \.offset) { _, dab in
            let radius = max(2, dab.radius * min(fit.width, fit.height))
            Circle()
                .fill((dab.erase ? Color.red : Color.accentColor).opacity(0.12))
                .frame(width: radius * 2, height: radius * 2)
                .position(x: fit.minX + dab.x * fit.width,
                          y: fit.minY + dab.y * fit.height)
                .allowsHitTesting(false)
        }
    }

    private func brushCanvas(index: Int, fit: CGRect) -> some View {
        Color.clear
            .frame(width: max(1, fit.width), height: max(1, fit.height))
            .contentShape(Rectangle())
            .position(x: fit.midX, y: fit.midY)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    brushCursor = point
                case .ended:
                    brushCursor = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        addBrushDab(at: value.location, index: index, fit: fit)
                    }
                    .onEnded { _ in
                        lastBrushPoint = nil
                    }
            )
    }

    private func addBrushDab(at point: CGPoint, index: Int, fit: CGRect) {
        guard index < state.masks.count, fit.width > 1, fit.height > 1 else { return }
        let radiusPixels = max(3, maskBrushRadius * min(fit.width, fit.height))
        if let last = lastBrushPoint {
            let distance = hypot(point.x - last.x, point.y - last.y)
            if distance < radiusPixels * 0.25 { return }
        }
        lastBrushPoint = point
        let dab = EditBrushDab(x: Double(min(1, max(0, point.x / fit.width))),
                               y: Double(min(1, max(0, point.y / fit.height))),
                               radius: maskBrushRadius,
                               softness: min(1, max(0, state.masks[index].feather)),
                               erase: maskBrushErase)
        state.masks[index].brushDabs.append(dab)
        if state.masks[index].brushDabs.count > 3000 {
            state.masks[index].brushDabs.removeFirst(state.masks[index].brushDabs.count - 3000)
        }
    }

    private func maskCenter(_ mask: EditMask, fit: CGRect) -> CGPoint {
        CGPoint(x: fit.minX + mask.centerX * fit.width,
                y: fit.minY + mask.centerY * fit.height)
    }

    @ViewBuilder
    private func maskShape(_ mask: EditMask, fit: CGRect) -> some View {
        let center = maskCenter(mask, fit: fit)
        let radius = max(12, mask.radius * min(fit.width, fit.height))
        let color = mask.id == maskSelection ? Color.accentColor : Color.white.opacity(0.75)
        if mask.kind == .radial {
            Ellipse()
                .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: radius * 2, height: radius * 2)
                .position(center)
        } else {
            let radians = CGFloat(mask.angle * .pi / 180)
            let dx = cos(radians) * radius
            let dy = sin(radians) * radius
            Path { path in
                path.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
                path.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    private func maskDragGesture(mask: EditMask, fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard fit.width > 1, fit.height > 1,
                      let index = state.masks.firstIndex(where: { $0.id == mask.id }) else { return }
                if maskDragID != mask.id {
                    maskDragID = mask.id
                    maskDragOrigin = CGPoint(x: state.masks[index].centerX,
                                             y: state.masks[index].centerY)
                    maskSelection = mask.id
                }
                let origin = maskDragOrigin ?? CGPoint(x: mask.centerX, y: mask.centerY)
                state.masks[index].centerX = min(1, max(0, origin.x + value.translation.width / fit.width))
                state.masks[index].centerY = min(1, max(0, origin.y + value.translation.height / fit.height))
            }
            .onEnded { _ in
                maskDragID = nil
                maskDragOrigin = nil
            }
    }

    private func healOverlay(container: CGSize) -> some View {
        let fit = fitRect(imageSize: preview?.size ?? .zero, in: container)
        return ZStack {
            ForEach(state.healSpots) { spot in
                let radius = max(5, spot.radius * min(fit.width, fit.height))
                let target = CGPoint(x: fit.minX + spot.x * fit.width,
                                     y: fit.minY + spot.y * fit.height)
                if let sourceX = spot.sourceX, let sourceY = spot.sourceY {
                    let source = CGPoint(x: fit.minX + sourceX * fit.width,
                                         y: fit.minY + sourceY * fit.height)
                    Path { path in
                        path.move(to: source)
                        path.addLine(to: target)
                    }
                    .stroke(Color.accentColor.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .allowsHitTesting(false)
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 1.2)
                        .frame(width: radius * 1.3, height: radius * 1.3)
                        .position(source)
                        .allowsHitTesting(false)
                }
                Circle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(target)
                    .allowsHitTesting(false)
            }

            if let pending = pendingCloneSource {
                let point = CGPoint(x: fit.minX + pending.x * fit.width,
                                    y: fit.minY + pending.y * fit.height)
                Circle()
                    .strokeBorder(Color.orange, lineWidth: 1.4)
                    .background(Circle().fill(Color.orange.opacity(0.15)))
                    .frame(width: 22, height: 22)
                    .position(point)
                    .allowsHitTesting(false)
                Path { path in
                    path.move(to: CGPoint(x: point.x - 14, y: point.y))
                    path.addLine(to: CGPoint(x: point.x + 14, y: point.y))
                    path.move(to: CGPoint(x: point.x, y: point.y - 14))
                    path.addLine(to: CGPoint(x: point.x, y: point.y + 14))
                }
                .stroke(Color.orange.opacity(0.8), lineWidth: 1)
                .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: max(1, fit.width), height: max(1, fit.height))
                .position(x: fit.midX, y: fit.midY)
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            handleHealTap(at: value.location, fit: fit)
                        }
                )
        }
    }

    private func handleHealTap(at point: CGPoint, fit: CGRect) {
        guard fit.width > 1, fit.height > 1 else { return }
        let normalized = CGPoint(x: min(1, max(0, point.x / fit.width)),
                                 y: min(1, max(0, point.y / fit.height)))
        if cloneMode {
            if pendingCloneSource == nil {
                pendingCloneSource = normalized
            } else {
                addHealSpot(at: normalized, source: pendingCloneSource)
                pendingCloneSource = nil
            }
        } else {
            addHealSpot(at: normalized, source: nil)
        }
    }

    private func addHealSpot(at normalized: CGPoint, source: CGPoint?) {
        guard fitSizeIsValid else { return }
        var spot = EditHealSpot()
        spot.x = normalized.x
        spot.y = normalized.y
        spot.radius = healBrushRadius
        if let source {
            spot.sourceX = source.x
            spot.sourceY = source.y
        } else {
            let offset = healBrushRadius * 2.4
            spot.sourceDX = normalized.x < 0.35 ? offset : -offset
        }
        state.healSpots.append(spot)
    }

    private var fitSizeIsValid: Bool {
        (preview?.size.width ?? 0) > 0 && (preview?.size.height ?? 0) > 0
    }

    private var controlPanel: some View {
        VStack(spacing: 0) {
            toolPicker

            Divider()

            ScrollView {
                Group {
                    switch tool {
                    case .adjust: adjustControls
                    case .curve:
                        EditCurvePanel(points: $state.curvePoints,
                                       red: $state.curveRed,
                                       green: $state.curveGreen,
                                       blue: $state.curveBlue,
                                       histogram: histogram)
                    case .hsl:
                        EditColorPanel(hsl: $state.hslAdjustments, grading: $state.gradingBands)
                    case .presets: presetsPanel
                    case .style: stylePanel
                    case .mask:
                        EditMaskPanel(masks: $state.masks,
                                      selection: $maskSelection,
                                      brushRadius: $maskBrushRadius,
                                      brushErase: $maskBrushErase)
                    case .heal:
                        EditHealPanel(spots: $state.healSpots,
                                      brushRadius: $healBrushRadius,
                                      cloneMode: $cloneMode,
                                      pendingSource: pendingCloneSource,
                                      onCancelSource: { pendingCloneSource = nil })
                    case .optics:
                        EditOpticsPanel(distortion: $state.lensDistortion,
                                        vertical: $state.perspectiveV,
                                        horizontal: $state.perspectiveH,
                                        vignetteFix: $state.lensVignetteFix,
                                        profile: state.lensProfile,
                                        lensLabel: photo.lens,
                                        onSelectProfile: selectLensProfile,
                                        onAutoDetect: autoDetectLens)
                    case .creative: creativePanel
                    case .filters: filterControls
                    case .crop: cropControls
                    case .poster: posterPanel
                    case .beauty: beautyControls
                    }
                }
                .padding(16)
            }

            Divider()

            VStack(spacing: 6) {
                if photo.hasEdits {
                    Button("还原为原始照片") {
                        resetAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Text("完成时会存储修改后的副本")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5)
        }
    }

    private var toolPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(EditTool.allCases) { item in
                Button {
                    tool = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(item.rawValue)
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tool == item ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.06))
                    )
                    .foregroundStyle(tool == item ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .help(item.rawValue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var adjustControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditHistogramView(histogram: histogram)

            adjustSlider("曝光", value: $state.exposure, range: -2...2)
            adjustSlider("亮度", value: $state.brightness, range: -0.5...0.5)
            adjustSlider("对比度", value: $state.contrast, range: -0.5...0.5)
            adjustSlider("饱和度", value: $state.saturation, range: -1...1)
            adjustSlider("高光", value: $state.highlights, range: -1...1)
            adjustSlider("阴影", value: $state.shadows, range: -1...1)
            adjustSlider("色温", value: $state.warmth, range: -1...1)
            adjustSlider("色调", value: $state.tint, range: -1...1)
            adjustSlider("锐化", value: $state.sharpness, range: 0...1)
            adjustSlider("降噪", value: $state.noiseReduction, range: 0...1)
            adjustSlider("晕影", value: $state.vignette, range: -1...1)

            Toggle("自动增强", isOn: $state.autoEnhance)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))

            Button("恢复默认调整") {
                state.exposure = 0
                state.brightness = 0
                state.contrast = 0
                state.saturation = 0
                state.highlights = 0
                state.shadows = 0
                state.warmth = 0
                state.tint = 0
                state.sharpness = 0
                state.noiseReduction = 0
                state.vignette = 0
                state.autoEnhance = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.accentColor)
        }
    }

    private func adjustSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
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

    // MARK: - 预设 / 风格 / 创意

    private var presetsPanel: some View {
        EditPresetsPanel(
            builtins: builtinPresets,
            custom: customPresets,
            thumbnails: presetThumbs,
            strength: $presetStrength,
            selectionCount: store.commandTargetIDs.subtracting([photo.id]).count,
            onApply: applyPreset,
            onSaveCurrent: saveCurrentPreset,
            onDelete: deletePreset,
            onImport: importPresets,
            onExport: exportPresets,
            onApplyToSelection: {
                store.applyStyleToSelection(state, strength: presetStrength)
            },
            snapshots: snapshots,
            onSnapshot: addSnapshot,
            onRestoreSnapshot: restoreSnapshot,
            onDeleteSnapshot: deleteSnapshot,
            recommendations: sceneRecommendations,
            onApplyRecommendation: { recommendation in
                if let preset = (builtinPresets + customPresets).first(where: { $0.id == recommendation.presetID }) {
                    applyPreset(preset)
                }
            },
            onApplyMixed: { style in
                applyStyleState(style)
            }
        )
    }

    private var stylePanel: some View {
        EditStylePanel(
            lutName: state.lutName,
            lutStrength: $state.lutStrength,
            grain: $state.grain,
            halation: $state.halation,
            lightLeak: $state.lightLeak,
            fade: $state.fade,
            onImportLUT: importLUT,
            onRemoveLUT: { state.lutName = nil }
        )
    }

    private var creativePanel: some View {
        EditCreativePanel(
            tiltBlur: $state.tiltBlur,
            zoomBlur: $state.zoomBlur,
            frameStyle: $state.frameStyle,
            onCinematic: applyCinematic
        )
    }

    private func applyPreset(_ preset: EditPreset) {
        applyStyleState(preset.state)
    }

    private func applyStyleState(_ style: EditState) {
        let next = state.applying(style: style, strength: presetStrength)
        guard next != state else { return }
        historyTask?.cancel()
        commitPendingHistory()
        history.append(state)
        redoStack.removeAll()
        apply(next)
    }

    // MARK: - 电影感 / 镜头

    private func applyCinematic() {
        var next = state
        next.aspect = .cinematic
        let size = orientedBaseSize
        if let ratio = CropAspect.cinematic.ratio, size.width > 0, size.height > 0 {
            let imageRatio = size.width / size.height
            var width: CGFloat = 1
            var height: CGFloat = 1
            if ratio > imageRatio {
                height = imageRatio / ratio
            } else {
                width = ratio / imageRatio
            }
            width = min(1, max(0.05, width))
            height = min(1, max(0.05, height))
            next.crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2,
                               width: width, height: height)
        }
        next.frameStyle = .none
        next.curvePoints = EditPresets.curve(0.02, 0.22, 0.5, 0.8, 0.98)
        next.contrast = 0.12
        next.saturation = min(next.saturation, -0.04)
        next.gradingBands = [
            EditGradeBand(hue: -0.55, saturation: 0.32, luminance: -0.02),
            .neutral,
            EditGradeBand(hue: 0.12, saturation: 0.26, luminance: 0.05)
        ]
        next.grain = max(next.grain, 0.18)
        next.halation = max(next.halation, 0.22)
        historyTask?.cancel()
        commitPendingHistory()
        history.append(state)
        redoStack.removeAll()
        apply(next)
        store.showToast("已套用电影感")
    }

    private func selectLensProfile(_ profile: EditLensProfile) {
        state.lensProfile = profile
        state.lensDistortion = profile.distortion
        state.lensVignetteFix = profile.vignetteFix
    }

    private func autoDetectLens() {
        let detected = EditLensProfile.detect(from: photo.lens)
        guard detected != .none else {
            store.showToast("没有识别到可用镜头信息")
            return
        }
        selectLensProfile(detected)
        store.showToast("已按镜头选择：\(detected.title)")
    }

    // MARK: - 海报模板

    private enum PosterAction {
        case save
        case quickSave
        case copy
        case share
    }

    private var posterOptions: PosterOptions {
        PosterOptions(title: posterTitle,
                      subtitle: posterSubtitle,
                      location: posterLocation,
                      date: posterDate,
                      signature: posterSignature)
    }

    private var posterPanel: some View {
        EditPosterPanel(preview: preview,
                        template: $posterTemplate,
                        title: $posterTitle,
                        subtitle: $posterSubtitle,
                        location: $posterLocation,
                        date: $posterDate,
                        signature: $posterSignature,
                        isExporting: isExportingPoster,
                        onExport: { exportPoster(action: .save) },
                        onQuickExport: { exportPoster(action: .quickSave) },
                        onCopy: { exportPoster(action: .copy) },
                        onShare: { exportPoster(action: .share) })
    }

    private func exportPoster(action: PosterAction) {
        guard let baseCI, !isExportingPoster else { return }
        isExportingPoster = true
        var target = state
        target.frameStyle = .none
        let options = posterOptions
        let template = posterTemplate
        Task {
            let cgImage = await Task.detached(priority: .userInitiated) {
                PhotoRenderer.renderCG(base: baseCI, state: target, maxPixel: 2400)
            }.value
            guard let cgImage else {
                isExportingPoster = false
                store.showToast("海报渲染失败")
                return
            }
            let image = NSImage(cgImage: cgImage,
                                size: NSSize(width: cgImage.width, height: cgImage.height))
            guard let composed = PosterExporter.render(image: image,
                                                       template: template,
                                                       options: options,
                                                       width: 1200) else {
                isExportingPoster = false
                store.showToast("海报生成失败")
                return
            }
            isExportingPoster = false
            switch action {
            case .save:
                savePosterPNG(composed)
            case .quickSave:
                savePosterToDesktop(composed)
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([composed])
                store.showToast("海报已复制")
            case .share:
                presentPosterShare(composed)
            }
        }
    }

    private func savePosterPNG(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "拾光海报.png"
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: url, options: .atomic)
            store.showToast("已导出海报")
        } catch {
            store.showToast("海报导出失败")
        }
    }

    private func presentPosterShare(_ image: NSImage) {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func savePosterToDesktop(_ image: NSImage) {
        guard let desktop = FileManager.default.urls(for: .desktopDirectory,
                                                     in: .userDomainMask).first,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            store.showToast("海报导出失败")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "拾光海报-\(formatter.string(from: Date())).png"
        let url = desktop.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            store.showToast("已导出到桌面：\(name)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.showToast("海报导出失败")
        }
    }

    private func saveCurrentPreset() {
        let alert = NSAlert()
        alert.messageText = "保存为预设"
        alert.informativeText = "当前的基础调整、曲线、HSL、分级、LUT 与胶片参数会被保存；裁剪、蒙版和修复点不会写入预设。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "预设名称"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = EditPreset(id: UUID().uuidString,
                                name: name.isEmpty ? "我的预设 \(customPresets.count + 1)" : name,
                                state: state,
                                isBuiltin: false)
        customPresets.append(preset)
        EditPresetStore.saveCustom(customPresets)
        refreshPresetThumbs()
        store.showToast("已保存预设")
    }

    private func deletePreset(_ preset: EditPreset) {
        customPresets.removeAll { $0.id == preset.id }
        presetThumbs[preset.id] = nil
        EditPresetStore.saveCustom(customPresets)
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let imported = EditPresetStore.decodeImport(data).map { preset -> EditPreset in
            var copy = preset
            copy.id = UUID().uuidString
            copy.isBuiltin = false
            return copy
        }
        guard !imported.isEmpty else {
            store.showToast("没有可导入的预设")
            return
        }
        customPresets.append(contentsOf: imported)
        EditPresetStore.saveCustom(customPresets)
        refreshPresetThumbs()
        store.showToast("已导入 \(imported.count) 个预设")
    }

    private func exportPresets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "拾光预设.json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = EditPresetStore.export(builtinPresets + customPresets) else { return }
        try? data.write(to: url, options: .atomic)
        store.showToast("已导出预设")
    }

    private func refreshSceneRecommendations() {
        guard let sampleImage else {
            sceneRecommendations = []
            return
        }
        sceneRecommendations = ScenePresetAdvisor.recommend(from: sampleImage)
    }

    private func refreshPresetThumbs() {
        guard let baseCI, !isLoading else { return }
        let maxSide = max(baseCI.extent.width, baseCI.extent.height)
        guard maxSide > 0 else { return }
        let scale = 140 / maxSide
        let small = PhotoRenderer.normalized(baseCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        let presets = builtinPresets + customPresets
        let missing = presets.filter { presetThumbs[$0.id] == nil }
        guard !missing.isEmpty else { return }
        Task {
            let rendered = await Task.detached(priority: .utility) { () -> [String: NSImage] in
                var result: [String: NSImage] = [:]
                for preset in missing {
                    var thumbState = preset.state
                    thumbState.rotation = 0
                    thumbState.flipH = false
                    thumbState.flipV = false
                    thumbState.crop = EditState.fullCrop
                    thumbState.straighten = 0
                    thumbState.masks = []
                    thumbState.healSpots = []
                    thumbState.frameStyle = .none
                    if let image = PhotoRenderer.render(base: small, state: thumbState, maxPixel: nil) {
                        result[preset.id] = image
                    }
                }
                return result
            }.value
            presetThumbs.merge(rendered) { _, new in new }
        }
    }

    private func addSnapshot() {
        snapshots.append(EditSnapshot(name: "快照 \(snapshots.count + 1)", state: state))
        store.showToast("已保存快照")
    }

    private func restoreSnapshot(_ snapshot: EditSnapshot) {
        guard snapshot.state != state else { return }
        historyTask?.cancel()
        commitPendingHistory()
        history.append(state)
        redoStack.removeAll()
        apply(snapshot.state)
    }

    private func deleteSnapshot(_ snapshot: EditSnapshot) {
        snapshots.removeAll { $0.id == snapshot.id }
    }

    private func importLUT() {
        let panel = NSOpenPanel()
        if let cube = UTType(filenameExtension: "cube") {
            panel.allowedContentTypes = [cube]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = try EditLUTLoader.importLUT(from: url)
            state.lutName = name
            state.lutStrength = 1
            store.showToast("已导入 LUT：\(url.deletingPathExtension().lastPathComponent)")
        } catch {
            store.showToast("LUT 导入失败")
        }
    }

    // MARK: - 选择性粘贴

    private func pasteEdits(_ parts: EditPasteParts) {
        guard let recipe = store.copiedEditRecipe,
              let pasted = EditState(jsonString: recipe) else {
            store.showToast("请先复制编辑点")
            return
        }
        historyTask?.cancel()
        commitPendingHistory()
        history.append(state)
        redoStack.removeAll()
        apply(state.merging(pasted, parts: parts))
        store.showToast(parts == .all ? "已粘贴编辑点" : "已粘贴所选参数")
    }

    // MARK: - 裁剪网格与自动拉直

    private func gridPath(in rect: CGRect) -> Path {
        var path = Path()
        switch cropGrid {
        case .none:
            break
        case .thirds:
            for index in 1...2 {
                let fraction = CGFloat(index) / 3
                let x = rect.minX + rect.width * fraction
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * fraction
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        case .golden:
            for fraction in [CGFloat(0.382), CGFloat(0.618)] {
                let x = rect.minX + rect.width * fraction
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * fraction
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        case .diagonal:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }

    private func autoStraighten() {
        guard let baseCI, !isAutoStraightening else { return }
        isAutoStraightening = true
        var geometry = EditState()
        geometry.rotation = state.rotation
        geometry.flipH = state.flipH
        geometry.flipV = state.flipV
        let base = baseCI
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                PhotoRenderer.renderCG(base: base, state: geometry, maxPixel: 640)
            }.value
            var angle: Double?
            if let image {
                angle = await Task.detached(priority: .userInitiated) {
                    HorizonDetector.straightenAngle(for: image)
                }.value
            }
            if let angle {
                state.straighten = min(15, max(-15, angle))
            } else {
                store.showToast("没有识别到地平线")
            }
            isAutoStraightening = false
        }
    }


        private var filterControls: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
            ForEach(FilterPreset.allCases) { preset in
                Button {
                    state.filter = preset
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.08))
                            if let thumb = filterThumbs[preset] {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            if state.filter == preset {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                        Text(preset.title)
                            .font(.system(size: 11))
                            .foregroundStyle(state.filter == preset ? Color.accentColor : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("比例")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(CropAspect.allCases) { aspect in
                    Button {
                        applyAspect(aspect)
                    } label: {
                        Text(aspect.title)
                            .font(.system(size: 11.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(state.aspect == aspect ? Color.accentColor : Color.primary.opacity(0.08))
                            )
                            .foregroundStyle(state.aspect == aspect ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("拖动取景框可调整位置")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            Divider()

            HStack {
                Text("拉直")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.1f°", state.straighten))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $state.straighten, in: -15...15)
                .controlSize(.small)

            HStack(spacing: 10) {
                Button {
                    autoStraighten()
                } label: {
                    Label(isAutoStraightening ? "识别中…" : "自动拉直", systemImage: "level")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(isAutoStraightening)

                Button("归零") { state.straighten = 0 }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 6) {
                Text("网格")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(CropGridStyle.allCases) { style in
                    Button(style.title) { cropGrid = style }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(cropGrid == style ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07)))
                        .foregroundStyle(cropGrid == style ? Color.white : Color.primary)
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 10) {
                transformButton("rotate.left") { rotate(-90) }
                transformButton("rotate.right") { rotate(90) }
                transformButton("arrow.left.and.right.righttriangle.left.righttriangle.right") { state.flipH.toggle() }
                transformButton("arrow.up.and.down.righttriangle.up.righttriangle.down") { state.flipV.toggle() }
                Spacer()
            }

            Button("重置裁剪与旋转") {
                state.rotation = 0
                state.flipH = false
                state.flipV = false
                state.aspect = .original
                state.crop = EditState.fullCrop
                state.straighten = 0
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.accentColor)
        }
    }

    private func transformButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 34, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func fitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2,
                      width: width, height: height)
    }

    private var orientedBaseSize: CGSize {
        let rotated = ((state.rotation % 360) + 360) % 360
        if rotated == 90 || rotated == 270 {
            return CGSize(width: basePixelSize.height, height: basePixelSize.width)
        }
        return basePixelSize
    }

    private func applyAspect(_ aspect: CropAspect) {
        state.aspect = aspect
        guard let ratio = aspect.ratio else {
            state.crop = EditState.fullCrop
            return
        }
        let size = orientedBaseSize
        guard size.width > 0, size.height > 0 else { return }
        let imageRatio = size.width / size.height
        var width: CGFloat = 1
        var height: CGFloat = 1
        if ratio > imageRatio {
            height = imageRatio / ratio
        } else {
            width = ratio / imageRatio
        }
        width = min(1, max(0.05, width))
        height = min(1, max(0.05, height))
        state.crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    private func rotate(_ degrees: Int) {
        state.rotation = (state.rotation + degrees + 360) % 360
        state.aspect = .original
        state.crop = EditState.fullCrop
        state.straighten = 0
    }

    // MARK: - 撤销 / 重做

    private func scheduleHistory(_ snapshot: EditState) {
        if pendingSnapshot == nil {
            pendingSnapshot = snapshot
        }
        historyTask?.cancel()
        historyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            commitPendingHistory()
        }
    }

    private func commitPendingHistory() {
        defer { pendingSnapshot = nil }
        guard let pending = pendingSnapshot, pending != state else { return }
        history.append(pending)
        if history.count > 60 {
            history.removeFirst(history.count - 60)
        }
        redoStack.removeAll()
    }

    private func undo() {
        historyTask?.cancel()
        historyTask = nil
        commitPendingHistory()
        guard let previous = history.popLast() else { return }
        redoStack.append(state)
        apply(previous)
    }

    private func redo() {
        historyTask?.cancel()
        historyTask = nil
        pendingSnapshot = nil
        guard let next = redoStack.popLast() else { return }
        history.append(state)
        apply(next)
    }

    private func apply(_ newState: EditState) {
        guard newState != state else { return }
        suppressHistory = true
        state = newState
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard let window = NSApp.keyWindow, event.window === window else { return event }
            guard window.attachedSheet == nil else { return event }
            guard store.editorID == photo.id else { return event }

            // 按住 \ 查看原图，松开恢复。
            if event.charactersIgnoringModifiers == "\\" {
                if event.type == .keyDown {
                    if !event.isARepeat {
                        showOriginal = true
                        refreshOriginalPreview()
                    }
                } else {
                    showOriginal = false
                }
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.type == .keyDown, flags.contains(.command) else { return event }
            guard event.charactersIgnoringModifiers?.lowercased() == "z" else { return event }

            if flags.contains(.shift) {
                redo()
            } else {
                undo()
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func load() async {
        isLoading = true
        customPresets = EditPresetStore.loadCustom()
        snapshots.removeAll()
        presetThumbs.removeAll()
        sceneRecommendations.removeAll()
        if posterPhotoID != photo.id {
            posterPhotoID = photo.id
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy.MM.dd"
            posterDate = formatter.string(from: photo.capturedAt)
            posterTitle = photo.title ?? ""
            posterLocation = photo.placeCity ?? photo.placePOI ?? ""
            posterSignature = ""
            posterSubtitle = "MEMORIES"
        }
        // 系统照片只能经 PhotoKit 取原图；本地照片优先从原图 + 配方重建。
        if photo.isSystem {
            guard let data = await PhotoKitBridge.originalImageData(assetID: photo.id),
                  let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                isLoading = false
                preview = nil
                return
            }
            state = EditState()
            history.removeAll()
            redoStack.removeAll()
            pendingSnapshot = nil
            beautyAdvice = nil
            beautyBase = nil
            beautyStrength = 1
            baseCI = ci
            basePixelSize = CGSize(width: ci.extent.width, height: ci.extent.height)
            var previewState = state.cropless()
            previewState.frameStyle = .none
            preview = PhotoRenderer.render(base: ci, state: previewState, maxPixel: 1600)
            originalPreview = nil
            refreshAnalysis(base: ci, state: previewState)
            buildFilterThumbs(base: ci)
            isLoading = false
            if tool == .beauty { analyzeBeauty() }
            if tool == .presets { refreshPresetThumbs() }
            return
        }
        // 有编辑配方时从原图重建，保证再次编辑是非破坏性的。
        let recipe = photo.editRecipe
        let useOriginal = photo.hasEdits && recipe != nil
        let url = useOriginal ? LibraryPaths.originalURL(for: photo) : LibraryPaths.sourceURL(for: photo)
        guard let ci = PhotoRenderer.loadBase(url: url) else {
            isLoading = false
            preview = nil
            return
        }
        var initial = EditState()
        if let recipe, let restored = EditState(jsonString: recipe) {
            initial = restored
        } else if !photo.hasEdits {
            // 原图可能带非破坏性旋转；编辑渲染结果本身已经是正向的。
            initial.rotation = photo.rotationAngle
        }
        if initial != state {
            suppressHistory = true
        }
        state = initial
        history.removeAll()
        redoStack.removeAll()
        pendingSnapshot = nil
        beautyAdvice = nil
        beautyBase = nil
        beautyStrength = 1
        baseCI = ci
        basePixelSize = CGSize(width: ci.extent.width, height: ci.extent.height)
        var previewState = state.cropless()
        previewState.frameStyle = .none
        preview = PhotoRenderer.render(base: ci, state: previewState, maxPixel: 1600)
        originalPreview = nil
        refreshAnalysis(base: ci, state: previewState)
        buildFilterThumbs(base: ci)
        isLoading = false
        if tool == .beauty {
            analyzeBeauty()
        }
        if tool == .presets {
            refreshPresetThumbs()
        }
    }

    private func buildFilterThumbs(base: CIImage) {
        let maxSide = max(base.extent.width, base.extent.height)
        guard maxSide > 0 else { return }
        let scale = 160 / maxSide
        let small = PhotoRenderer.normalized(base.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        var thumbs: [FilterPreset: NSImage] = [:]
        for preset in FilterPreset.allCases {
            var smallState = EditState()
            smallState.filter = preset
            if let image = PhotoRenderer.render(base: small, state: smallState, maxPixel: nil) {
                thumbs[preset] = image
            }
        }
        filterThumbs = thumbs
    }

    private func refreshPreview() {
        guard let baseCI else { return }
        var renderState = tool.needsFullFrame ? state.cropless() : state
        // 画框在预览里用 SwiftUI 叠层，渲染时不烘焙，蒙版坐标才不会被边推偏。
        renderState.frameStyle = .none
        preview = PhotoRenderer.render(base: baseCI, state: renderState, maxPixel: 1600)
        originalPreview = nil
        if compareMode == .split {
            refreshOriginalPreview(force: true)
        }
        refreshAnalysis(base: baseCI, state: renderState)
    }

    private func refreshAnalysis(base: CIImage, state: EditState) {
        histogramToken += 1
        let token = histogramToken
        Task.detached(priority: .utility) {
            guard let image = PhotoRenderer.renderCG(base: base, state: state, maxPixel: 320) else { return }
            let result = EditHistogramSampler.analyze(image)
            await MainActor.run {
                guard token == histogramToken else { return }
                histogram = result.histogram
                sampleImage = result.sample
                if tool == .presets, let sample = result.sample {
                    sceneRecommendations = ScenePresetAdvisor.recommend(from: sample)
                }
            }
        }
    }

    /// 按住对比时渲染「保留几何、清空所有调整」的原图，裁剪 / 旋转 / 拉直仍对齐。
    private func refreshOriginalPreview(force: Bool = false) {
        guard let baseCI else { return }
        if !force, originalPreview != nil { return }
        var geometry = EditState()
        geometry.rotation = state.rotation
        geometry.flipH = state.flipH
        geometry.flipV = state.flipV
        geometry.straighten = state.straighten
        geometry.crop = state.crop
        geometry.aspect = state.aspect
        geometry.frameStyle = .none
        let target = tool.needsFullFrame ? geometry.cropless() : geometry
        let base = baseCI
        Task.detached(priority: .userInitiated) {
            let image = PhotoRenderer.render(base: base, state: target, maxPixel: 1600)
            await MainActor.run {
                originalPreview = image
            }
        }
    }

    private func resetAll() {
        if photo.hasEdits {
            history.removeAll()
            redoStack.removeAll()
            pendingSnapshot = nil
            store.revertEdits(photo.id)
            if EditState() != state {
                suppressHistory = true
            }
            state = EditState()
            Task { await load() }
        } else {
            var reset = EditState()
            reset.rotation = photo.rotationAngle
            guard reset != state else { return }
            history.append(state)
            redoStack.removeAll()
            apply(reset)
        }
    }

    // MARK: - 智能美化

    private var beautyControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isBeautifying {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在分析画面…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let advice = beautyAdvice {
                if advice.isEmpty {
                    Label("画面已经比较均衡", systemImage: "checkmark.seal")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentColor)
                            Text("建议")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(advice.reasons, id: \.self) { reason in
                            Text("• \(reason)")
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    adjustSlider("强度", value: $beautyStrength, range: 0.2...1.5)

                    HStack(spacing: 10) {
                        Button(beautyBase == nil ? "应用美化" : "重新应用") {
                            applyBeauty()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if beautyBase != nil {
                            Button("撤销美化") { undoBeauty() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        Spacer()
                    }
                }
            } else {
                Text("无法分析这张照片")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button {
                analyzeBeauty()
            } label: {
                Label("重新分析画面", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(isBeautifying || baseCI == nil)

            Text("分析只读取缩略图，全部在本机完成；美化结果保存为副本，原图不受影响。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 用当前画面（含已有调整、不含裁剪）渲染一张 512px 预览来分析。
    private func analyzeBeauty() {
        guard let baseCI, !isBeautifying else { return }
        isBeautifying = true
        let renderState = state.cropless()
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                PhotoRenderer.renderCG(base: baseCI, state: renderState, maxPixel: 512)
            }.value
            var advice: BeautyAdvice?
            if let image {
                advice = await Task.detached(priority: .userInitiated) {
                    PhotoBeauty.advice(image: image)
                }.value
            }
            beautyAdvice = advice
            isBeautifying = false
        }
    }

    private func applyBeauty() {
        guard let advice = beautyAdvice, !advice.isEmpty else { return }
        historyTask?.cancel()
        commitPendingHistory()
        if beautyBase == nil {
            beautyBase = state
        }
        history.append(state)
        redoStack.removeAll()
        let base = beautyBase ?? state
        apply(EditState.beautified(base, advice: advice, strength: beautyStrength))
    }

    private func undoBeauty() {
        guard let base = beautyBase else { return }
        history.append(state)
        redoStack.removeAll()
        beautyBase = nil
        beautyStrength = 1
        apply(base)
    }

    private func save() {
        guard let baseCI, !isSaving else { return }
        guard state.isModified else {
            store.closeEditor()
            return
        }
        isSaving = true
        let renderState = state
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                PhotoRenderer.renderCG(base: baseCI, state: renderState, maxPixel: nil)
            }.value
            guard let rendered,
                  let data = jpegData(from: rendered) else {
                isSaving = false
                store.showToast("保存失败")
                return
            }
            if photo.isSystem {
                // 系统照片：整帧作为非破坏性调整写回「照片」。
                store.saveSystemEdit(photoID: photo.id, jpegData: data)
                isSaving = false
                return
            }
            store.commitEditedImage(photoID: photo.id,
                                    jpegData: data,
                                    pixelWidth: rendered.width,
                                    pixelHeight: rendered.height,
                                    recipe: renderState.jsonString)
            isSaving = false
        }
    }

    private func jpegData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.94])
    }
}
