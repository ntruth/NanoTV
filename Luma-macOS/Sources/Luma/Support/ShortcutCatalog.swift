import AppKit
import SwiftUI

/// 可自定义的快捷键动作。只收录由窗口键盘监听处理、不会与系统菜单冲突的按键。
enum ShortcutAction: String, CaseIterable, Identifiable {
    // 图库网格
    case galleryOpen
    case galleryFavorite

    // 照片查看器
    case viewerFavorite
    case viewerInfo
    case viewerEdit
    case viewerLivePhoto
    case viewerFullscreen
    case viewerZoomIn
    case viewerZoomOut
    case viewerZoomFit

    // 视频播放
    case videoPlayPause
    case videoMute
    case videoForward
    case videoBackward
    case videoAspect
    case videoRotate
    case videoFullscreen

    // 幻灯片
    case slideshowToggle
    case slideshowPrevious
    case slideshowNext

    var id: String { rawValue }

    var context: ShortcutContext {
        switch self {
        case .galleryOpen, .galleryFavorite:
            return .gallery
        case .viewerFavorite, .viewerInfo, .viewerEdit, .viewerLivePhoto,
             .viewerFullscreen, .viewerZoomIn, .viewerZoomOut, .viewerZoomFit:
            return .viewer
        case .videoPlayPause, .videoMute, .videoForward, .videoBackward,
             .videoAspect, .videoRotate, .videoFullscreen:
            return .video
        case .slideshowToggle, .slideshowPrevious, .slideshowNext:
            return .slideshow
        }
    }

    var title: String {
        switch self {
        case .galleryOpen: return "打开所选照片"
        case .galleryFavorite: return "收藏 / 取消收藏"
        case .viewerFavorite: return "收藏 / 取消收藏"
        case .viewerInfo: return "信息面板"
        case .viewerEdit: return "进入编辑"
        case .viewerLivePhoto: return "播放实况照片"
        case .viewerFullscreen: return "全屏查看"
        case .viewerZoomIn: return "放大"
        case .viewerZoomOut: return "缩小"
        case .viewerZoomFit: return "适应窗口"
        case .videoPlayPause: return "播放 / 暂停"
        case .videoMute: return "静音"
        case .videoForward: return "快进"
        case .videoBackward: return "快退"
        case .videoAspect: return "填充 / 适应画面"
        case .videoRotate: return "旋转 90°"
        case .videoFullscreen: return "全屏播放"
        case .slideshowToggle: return "暂停 / 继续"
        case .slideshowPrevious: return "上一张"
        case .slideshowNext: return "下一张"
        }
    }

    var detail: String {
        switch self {
        case .galleryOpen: return "选中照片后进入查看器；空格始终保留为备用"
        case .galleryFavorite: return "与系统「照片」一致的点号收藏"
        case .viewerFavorite: return "与系统「照片」一致的点号收藏"
        case .viewerInfo: return "显示相机参数、位置与关键词"
        case .viewerEdit: return "仅对本地可编辑照片生效"
        case .viewerLivePhoto: return "仅实况照片可用"
        case .viewerFullscreen: return "进入系统全屏"
        case .viewerZoomIn, .viewerZoomOut, .viewerZoomFit: return "围绕鼠标位置缩放"
        case .videoPlayPause: return "回车键始终保留为备用"
        case .videoMute: return "恢复音量请在控制条操作"
        case .videoForward, .videoBackward: return "与 ← → 共用设置里的步长；连按 / 按住会加速"
        case .videoAspect: return "在填充与适应之间切换"
        case .videoRotate: return "只影响播放显示，不改文件"
        case .videoFullscreen: return "进入系统全屏"
        case .slideshowToggle: return "空格键始终保留为备用"
        case .slideshowPrevious, .slideshowNext: return "方向键始终保留为备用"
        }
    }

    var symbol: String {
        switch self {
        case .galleryOpen: return "arrow.up.forward.square"
        case .galleryFavorite: return "heart"
        case .viewerFavorite: return "heart"
        case .viewerInfo: return "info.circle"
        case .viewerEdit: return "slider.horizontal.3"
        case .viewerLivePhoto: return "livephoto"
        case .viewerFullscreen: return "arrow.up.left.and.arrow.down.right"
        case .viewerZoomIn: return "plus.magnifyingglass"
        case .viewerZoomOut: return "minus.magnifyingglass"
        case .viewerZoomFit: return "arrow.down.right.and.arrow.up.left"
        case .videoPlayPause: return "playpause.fill"
        case .videoMute: return "speaker.slash.fill"
        case .videoForward: return "goforward"
        case .videoBackward: return "gobackward"
        case .videoAspect: return "aspectratio"
        case .videoRotate: return "rotate.right"
        case .videoFullscreen: return "arrow.up.left.and.arrow.down.right"
        case .slideshowToggle: return "pause.fill"
        case .slideshowPrevious: return "backward.end.fill"
        case .slideshowNext: return "forward.end.fill"
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .galleryOpen: return .init(keyCode: 36, characters: "", modifiers: [])
        case .galleryFavorite: return .init(keyCode: 47, characters: ".", modifiers: [])
        case .viewerFavorite: return .init(keyCode: 47, characters: ".", modifiers: [])
        case .viewerInfo: return .init(keyCode: 34, characters: "i", modifiers: [])
        case .viewerEdit: return .init(keyCode: 14, characters: "e", modifiers: [])
        case .viewerLivePhoto: return .init(keyCode: 37, characters: "l", modifiers: [])
        case .viewerFullscreen: return .init(keyCode: 3, characters: "f", modifiers: [])
        case .viewerZoomIn: return .init(keyCode: 24, characters: "=", modifiers: [])
        case .viewerZoomOut: return .init(keyCode: 27, characters: "-", modifiers: [])
        case .viewerZoomFit: return .init(keyCode: 29, characters: "0", modifiers: [])
        case .videoPlayPause: return .init(keyCode: 40, characters: "k", modifiers: [])
        case .videoMute: return .init(keyCode: 46, characters: "m", modifiers: [])
        case .videoForward: return .init(keyCode: 37, characters: "l", modifiers: [])
        case .videoBackward: return .init(keyCode: 38, characters: "j", modifiers: [])
        case .videoAspect: return .init(keyCode: 0, characters: "a", modifiers: [])
        case .videoRotate: return .init(keyCode: 15, characters: "r", modifiers: [])
        case .videoFullscreen: return .init(keyCode: 3, characters: "f", modifiers: [])
        case .slideshowToggle: return .init(keyCode: 49, characters: " ", modifiers: [])
        case .slideshowPrevious: return .init(keyCode: 123, characters: "", modifiers: [])
        case .slideshowNext: return .init(keyCode: 124, characters: "", modifiers: [])
        }
    }

    /// 各场景下始终保留的固定按键，录制时直接拒绝。
    static func isReserved(keyCode: UInt16, context: ShortcutContext) -> Bool {
        if keyCode == 53 { return true } // Esc
        switch context {
        case .gallery:
            return [49, 123, 124, 125, 126].contains(keyCode)
        case .viewer:
            return [49, 123, 124, 125, 126].contains(keyCode)
        case .video:
            // 回车保留为播放 / 暂停的备用键，避免录制后与固定键位混淆。
            return [36, 49, 123, 124, 125, 126].contains(keyCode)
        case .slideshow:
            return false
        }
    }
}

enum ShortcutContext: String, CaseIterable, Identifiable {
    case gallery
    case viewer
    case video
    case slideshow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gallery: return "图库网格"
        case .viewer: return "照片查看器"
        case .video: return "视频播放"
        case .slideshow: return "幻灯片"
        }
    }

    var subtitle: String {
        switch self {
        case .gallery: return "主窗口网格中的键盘操作"
        case .viewer: return "双击打开照片后的单键操作"
        case .video: return "播放器窗口内的键盘控制"
        case .slideshow: return "全窗口轮播时的控制"
        }
    }

    var symbol: String {
        switch self {
        case .gallery: return "square.grid.2x2"
        case .viewer: return "photo"
        case .video: return "play.rectangle"
        case .slideshow: return "rectangle.fill.on.rectangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .gallery: return LumaBrand.mint
        case .viewer: return LumaBrand.coral
        case .video: return LumaBrand.violet
        case .slideshow: return LumaBrand.cyan
        }
    }

    var actions: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.context == self }
    }
}

/// 一条快捷键：物理键位 + 修饰键。
struct ShortcutBinding: Codable, Hashable {
    var keyCode: UInt16
    var characters: String
    var modifiers: UInt

    init(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers.intersection(Self.relevantFlags).rawValue
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode,
                  characters: (event.charactersIgnoringModifiers ?? "").lowercased(),
                  modifiers: event.modifierFlags)
    }

    private static let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevantFlags)
    }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += Self.keyLabel(keyCode: keyCode, characters: characters)
        return text
    }

    var isEmpty: Bool { keyCode == .max }

    /// 只比较物理键位与修饰键：同一组合在不同键盘布局下的字符可能不同。
    func sameChord(as other: ShortcutBinding) -> Bool {
        keyCode == other.keyCode && flags == other.flags
    }

    func matches(_ event: NSEvent) -> Bool {
        guard !isEmpty, event.keyCode == keyCode else { return false }
        let eventFlags = event.modifierFlags.intersection(Self.relevantFlags)
        if eventFlags == flags { return true }
        // 让 ⇧ 的符号切换仍命中同一个动作（= / +、- / _）。
        if flags.isEmpty, eventFlags == .shift,
           Self.shiftAliases[keyCode] == characters {
            return true
        }
        return false
    }

    private static let shiftAliases: [UInt16: String] = [24: "=", 27: "-"]

    static func keyLabel(keyCode: UInt16, characters: String) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PgUp"
        case 121: return "PgDn"
        case 117: return "⌦"
        default:
            let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Key \(keyCode)" }
            return trimmed.uppercased()
        }
    }
}

/// 快捷键偏好：修改即时写入 UserDefaults，键盘监听每次按键都从这里取当前绑定。
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published private(set) var overrides: [String: ShortcutBinding] = [:]

    private static let defaultsKey = "settings.shortcuts.v1"

    private init() {
        load()
    }

    func binding(for action: ShortcutAction) -> ShortcutBinding {
        overrides[action.rawValue] ?? action.defaultBinding
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    var customizedCount: Int { overrides.count }

    func set(_ binding: ShortcutBinding, for action: ShortcutAction) {
        if binding.sameChord(as: action.defaultBinding) {
            overrides[action.rawValue] = nil
        } else {
            overrides[action.rawValue] = binding
        }
        save()
    }

    func reset(_ action: ShortcutAction) {
        guard overrides.removeValue(forKey: action.rawValue) != nil else { return }
        save()
    }

    func resetAll() {
        guard !overrides.isEmpty else { return }
        overrides = [:]
        save()
    }

    /// 同一场景内重复的按键：返回先占用它的动作。
    func conflict(for binding: ShortcutBinding, in action: ShortcutAction) -> ShortcutAction? {
        action.context.actions.first {
            $0 != action && self.binding(for: $0).sameChord(as: binding)
        }
    }

    static func matches(_ event: NSEvent, _ action: ShortcutAction) -> Bool {
        shared.binding(for: action).matches(event)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else {
            return
        }
        overrides = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
