import SwiftUI
import AppKit

struct MetadataOptions: Codable, Equatable {
    var title = false
    var capturedDate = false
    var keywords = false
    var edited = false
    var fileType = false
    var favorite = true
    var location = false
    var resolution = false
    var fileSize = false
    var camera = false
    var source = false
    var duration = true

    /// 除「个人收藏」「视频时长」这类角标外，是否还有文字信息需要遮罩。
    var hasTextOverlay: Bool {
        title || capturedDate || keywords || edited || fileType
            || location || resolution || fileSize || camera || source
    }
}

/// 缩略图角标与文字的快速预设。
enum MetadataPreset {
    case minimal
    case standard
    case full
}

/// 设置窗口的分页。其它入口（如影院菜单）可以先把目标页写进 `SettingsKeys.selectedTab`，
/// 再打开设置窗口，直接落在对应分页上。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case browsing
    case cinema
    case models
    case assistant
    case shortcuts
    case about

    var id: String { rawValue }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 引导里的小胶囊只放得下两三个字，这里给一档短名。
    var compactTitle: String {
        switch self {
        case .system: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case system
    case blue
    case indigo
    case purple
    case pink
    case orange
    case gold
    case green
    case mint
    case teal
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统"
        case .blue: return "蓝色"
        case .indigo: return "靛蓝"
        case .purple: return "紫色"
        case .pink: return "粉色"
        case .orange: return "橙色"
        case .gold: return "金色"
        case .green: return "绿色"
        case .mint: return "薄荷"
        case .teal: return "青色"
        case .graphite: return "石墨"
        }
    }

    var color: Color? {
        switch self {
        case .system: return nil
        case .blue: return .blue
        case .indigo: return Color(red: 0.36, green: 0.42, blue: 0.96)
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .gold: return Color(red: 0.95, green: 0.74, blue: 0.28)
        case .green: return .green
        case .mint: return Color(red: 0.32, green: 0.84, blue: 0.70)
        case .teal: return .teal
        case .graphite: return Color(red: 0.47, green: 0.50, blue: 0.56)
        }
    }

    var swatch: Color {
        color ?? Color.accentColor
    }
}

enum PhotoOpenMode: String, CaseIterable, Identifiable {
    case viewer
    case editor
    case systemApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .viewer: return "在本 App 中查看"
        case .editor: return "直接进入编辑（仅照片）"
        case .systemApp: return "用系统默认应用打开"
        }
    }

    var detail: String {
        switch self {
        case .viewer: return "双击照片打开查看器，视频直接播放。"
        case .editor: return "双击照片进入编辑；视频和只读项目仍用查看器。"
        case .systemApp: return "双击交给「预览」等默认应用；云端项目仍用查看器。"
        }
    }

    /// 设置卡片上的短标题与图标。
    var shortTitle: String {
        switch self {
        case .viewer: return "App 内查看"
        case .editor: return "直接编辑"
        case .systemApp: return "系统应用"
        }
    }

    var icon: String {
        switch self {
        case .viewer: return "eye"
        case .editor: return "slider.horizontal.3"
        case .systemApp: return "arrow.up.forward.app"
        }
    }
}

/// 查看器呈现方式：窗口内浏览（保留侧边栏与工具栏）或全屏沉浸。
enum ViewerLayout: String, CaseIterable, Identifiable {
    case window
    case fullscreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: return "窗口内浏览"
        case .fullscreen: return "全屏沉浸"
        }
    }

    var detail: String {
        switch self {
        case .window: return "保留侧边栏与顶部工具栏，照片居中显示，可一边浏览一边切换相簿。"
        case .fullscreen: return "查看器覆盖整个窗口并隐藏侧边栏，适合专注看图。"
        }
    }
}

/// 视频控制条的位置：画面底部悬浮，或贴着窗口工具栏下缘融入画面上方。
enum VideoControlPlacement: String, CaseIterable, Identifiable {
    case floating
    case topIntegrated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floating: return "画面底部悬浮"
        case .topIntegrated: return "顶栏融合"
        }
    }

    var detail: String {
        switch self {
        case .floating: return "控制条悬浮在画面底部，可拖到画面内任意位置，双击顶部把手复位。"
        case .topIntegrated: return "播放控制并入窗口工具栏：播放按钮与返回共用左侧胶囊，中部显示拍摄信息、序号与进度，音量 / 播放选项 / 全屏排在右侧操作按钮之前。"
        }
    }
}

/// 网络缓冲选项：自适应是三档之外的一个「按网络自动调节」模式。
enum VideoBufferMode: String, CaseIterable, Identifiable {
    /// 以流畅为目标，网络变慢时临时降档，恢复后升回。
    case adaptive
    case smooth
    case balanced
    case thrifty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adaptive: return "自适应"
        case .smooth: return "流畅"
        case .balanced: return "均衡"
        case .thrifty: return "省流"
        }
    }

    var detail: String {
        switch self {
        case .adaptive:
            return "以流畅档为上限，网络变慢时自动降到均衡 / 省流，恢复后升回；只在云端 / WebDAV 等远端片源生效。"
        case .smooth:
            return BufferProfile.smooth.detail
        case .balanced:
            return BufferProfile.balanced.detail
        case .thrifty:
            return BufferProfile.thrifty.detail
        }
    }

    var isAdaptive: Bool { self == .adaptive }

    /// 各选项对应的档位；自适应以流畅为目标。
    var profile: BufferProfile {
        switch self {
        case .adaptive, .smooth: return .smooth
        case .balanced: return .balanced
        case .thrifty: return .thrifty
        }
    }

    init(profile: BufferProfile) {
        switch profile {
        case .smooth: self = .smooth
        case .balanced: self = .balanced
        case .thrifty: self = .thrifty
        }
    }
}

/// HDR / 杜比视界片源的播放策略。
enum VideoHDRMode: String, CaseIterable, Identifiable {
    /// 有 HDR 屏幕就保持 HDR；SDR 屏或杜比视界 Profile 5 自动映射到 SDR。
    case automatic
    /// 一律先做 HDR → SDR 色调映射，颜色与片源观感一致，代价是要转码。
    case toneMapSDR
    /// 保持片源原样，不做任何色调映射（HDR 屏 + 支持杜比视界的播放器）。
    case keepHDR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .toneMapSDR: return "映射到 SDR"
        case .keepHDR: return "保持 HDR"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "HDR 屏保留原样，杜比视界交给系统解码；SDR 屏自动映射到 SDR。若 HDR 屏出现偏色，可改为「映射到 SDR」。"
        case .toneMapSDR:
            return "HDR / 杜比视界片源都先做色调映射再播放，颜色最接近原始观感；需要 ffmpeg 带 libplacebo 才能处理杜比视界。"
        case .keepHDR:
            return "不做色调映射，把片源原样交给系统解码；SDR 屏上可能发灰，杜比视界可能偏色。"
        }
    }
}

/// 动效预设。影响页面切换、查看器开合、侧边栏展开与卡片悬停。
enum MotionPreset: String, CaseIterable, Identifiable {
    case silky
    case standard
    case quick
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silky: return "丝滑"
        case .standard: return "标准"
        case .quick: return "轻快"
        case .off: return "关闭"
        }
    }

    var detail: String {
        switch self {
        case .silky: return "弹性收尾，接近系统「照片」的过渡手感。"
        case .standard: return "较短的平滑过渡，兼顾手感与响应。"
        case .quick: return "几乎瞬时的淡入淡出，适合高频操作。"
        case .off: return "完全关闭动画，立即切换。"
        }
    }

    /// 页面切换、尺寸变化等布局动画。
    var layout: Animation? {
        switch self {
        case .silky: return .spring(response: 0.42, dampingFraction: 0.86)
        case .standard: return .snappy(duration: 0.25)
        case .quick: return .easeOut(duration: 0.15)
        case .off: return nil
        }
    }

    /// 查看器、信息面板等浮层动画。
    var overlay: Animation? {
        switch self {
        case .silky: return .spring(response: 0.48, dampingFraction: 0.9)
        case .standard: return .easeInOut(duration: 0.24)
        case .quick: return .easeOut(duration: 0.15)
        case .off: return nil
        }
    }

    /// 卡片悬停等微交互。
    var hover: Animation? {
        switch self {
        case .silky: return .spring(response: 0.26, dampingFraction: 0.92)
        case .standard: return .snappy(duration: 0.18)
        case .quick: return .easeOut(duration: 0.12)
        case .off: return nil
        }
    }

    /// 查看器打开时的初始缩放。
    var viewerScale: CGFloat {
        switch self {
        case .silky: return 0.94
        case .standard: return 0.97
        case .quick: return 0.98
        case .off: return 1
        }
    }

    var hoverScale: CGFloat {
        switch self {
        case .silky: return 1.01
        case .standard: return 1.006
        case .quick: return 1.004
        case .off: return 1
        }
    }
}

// MARK: - 设置存储
