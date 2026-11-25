import CoreGraphics
import AVFoundation

/// 画面显示方式：只改显示层，不重编码、不影响截图与导出。
public enum VideoFramingMode: String, CaseIterable, Identifiable, Sendable {
    /// 适应：完整画面，留黑边。
    case fit
    /// 填充：铺满容器，超出部分裁掉。
    case fill
    /// 拉伸：铺满容器，画面可能变形。
    case stretch
    /// 原始像素：按 1:1 点显示，超出容器时裁切。
    case actualSize

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fit: return "适应"
        case .fill: return "填充"
        case .stretch: return "拉伸"
        case .actualSize: return "原始像素"
        }
    }

    public var detail: String {
        switch self {
        case .fit: return "完整显示画面，比例不符时留黑边。"
        case .fill: return "铺满画面区域，超出部分上下或左右裁切。"
        case .stretch: return "强行铺满画面区域，比例不符时画面会变形。"
        case .actualSize: return "按 1:1 显示，不缩放；大尺寸片源会超出画面并可平移查看。"
        }
    }

    /// 交给 AVPlayerLayer 的重力：尺寸计算由 `VideoFramingGeometry` 负责。
    public var gravity: AVLayerVideoGravity {
        switch self {
        case .fit, .actualSize: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }
}

/// 画面比例预设：在显示层把画面裁成固定比例（16:9 / 4:3 / 2.35:1 / 1:1）。
public enum VideoAspectPreset: String, CaseIterable, Identifiable, Sendable {
    case source
    case widescreen
    case classic
    case cinema
    case square

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: return "源比例"
        case .widescreen: return "16:9"
        case .classic: return "4:3"
        case .cinema: return "2.35:1"
        case .square: return "1:1"
        }
    }

    /// 宽 / 高；nil 表示保持容器比例（不裁剪）。
    public var ratio: CGFloat? {
        switch self {
        case .source: return nil
        case .widescreen: return 16.0 / 9.0
        case .classic: return 4.0 / 3.0
        case .cinema: return 2.35
        case .square: return 1
        }
    }
}

/// 一次画面布局的结果（屏幕坐标）：
/// - `boxSize`：可见裁剪框；
/// - `preRotationContentSize`：旋转前的播放层尺寸（奇数圈与屏幕坐标互换宽高）；
/// - `panOffset`：旋转之后施加在屏幕坐标上的平移。
public struct VideoFramingLayout: Equatable, Sendable {
    public var boxSize: CGSize
    public var preRotationContentSize: CGSize
    public var panOffset: CGSize

    public init(boxSize: CGSize, preRotationContentSize: CGSize, panOffset: CGSize) {
        self.boxSize = boxSize
        self.preRotationContentSize = preRotationContentSize
        self.panOffset = panOffset
    }
}

/// 纯几何计算：把「舞台 + 片源尺寸 + 显示方式 + 比例预设 + 平移」折算成可渲染的尺寸。
/// 不依赖 SwiftUI，便于在 `LumaCoreChecks` 里断言。
public enum VideoFramingGeometry {
    public static func layout(stage: CGSize,
                              naturalSize: CGSize,
                              quarterTurns: Int,
                              mode: VideoFramingMode,
                              preset: VideoAspectPreset,
                              pan: CGSize) -> VideoFramingLayout {
        guard stage.width > 0, stage.height > 0,
              naturalSize.width > 0, naturalSize.height > 0 else {
            return VideoFramingLayout(boxSize: stage,
                                      preRotationContentSize: stage,
                                      panOffset: .zero)
        }
        let turns = ((quarterTurns % 4) + 4) % 4
        let rotated = turns % 2 == 1
        // 旋转奇数次后，屏幕上的片源宽高互换。
        let screenNatural = rotated
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize

        let box = boxSize(stage: stage, ratio: preset.ratio)
        let content: CGSize
        switch mode {
        case .fit:
            content = fit(size: screenNatural, into: box)
        case .fill:
            content = fill(size: screenNatural, into: box)
        case .stretch:
            content = box
        case .actualSize:
            content = screenNatural
        }

        // 画面比裁剪框大时才有多余部分可以平移；pan 取值范围 -1...1。
        let overflowX = max(0, (content.width - box.width) / 2)
        let overflowY = max(0, (content.height - box.height) / 2)
        let clampedX = min(max(pan.width, -1), 1)
        let clampedY = min(max(pan.height, -1), 1)
        // 平移施加在旋转后的屏幕坐标上，因此不需要交换分量。
        let offset = CGSize(width: clampedX * overflowX, height: clampedY * overflowY)
        let preRotation = rotated
            ? CGSize(width: content.height, height: content.width)
            : content
        return VideoFramingLayout(boxSize: box,
                                  preRotationContentSize: preRotation,
                                  panOffset: offset)
    }

    /// 按预设比例在舞台内取最大的居中矩形；源比例直接用整个舞台。
    private static func boxSize(stage: CGSize, ratio: CGFloat?) -> CGSize {
        guard let ratio, ratio > 0 else { return stage }
        let stageRatio = stage.width / stage.height
        if stageRatio > ratio {
            let height = stage.height
            return CGSize(width: height * ratio, height: height)
        }
        let width = stage.width
        return CGSize(width: width, height: width / ratio)
    }

    private static func fit(size: CGSize, into box: CGSize) -> CGSize {
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func fill(size: CGSize, into box: CGSize) -> CGSize {
        let scale = max(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
