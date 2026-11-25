import SwiftUI
import AppKit

/// 窗口级键盘监听。隐藏按钮 + keyboardShortcut 在覆盖层/零尺寸视图里经常收不到按键，
/// 这里直接监听 NSWindow 的 keyDown，保证左右方向键等快捷键稳定生效。
struct KeyEventMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    final class Coordinator {
        var handler: (NSEvent) -> Bool
        var monitor: Any?
        weak var hostView: NSView?

        init(handler: @escaping (NSEvent) -> Bool) {
            self.handler = handler
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let hostView = coordinator.hostView else { return event }
            guard let hostWindow = hostView.window, event.window === hostWindow else { return event }
            guard hostWindow.attachedSheet == nil else { return event }
            if hostWindow.firstResponder is NSTextView { return event }
            return coordinator.handler(event) ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
        coordinator.hostView = nil
    }
}

// MARK: - 文本框粘贴 / 复制兼容

/// 文本框里的复制粘贴快捷键统一在这里兜底：
/// - Ctrl+C / Ctrl+V / Ctrl+X / Ctrl+A：兼容 Windows 习惯；
/// - ⌘C / ⌘V / ⌘X / ⌘A：本地监听先于菜单快捷键处理，避免「照片」菜单里的 ⌘V
///   （粘贴照片）把输入框的文本粘贴吞掉（向导、设置、网盘 Cookie 输入框都受影响）。
/// 只在第一响应者是文本视图时接管，网格里的照片复制粘贴不受影响。
enum ControlKeyTextShortcuts {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommand = flags.contains(.command)
            let isControl = flags.contains(.control)
            // 只处理「单修饰键」的复制粘贴组合，⌘⌥V 等业务快捷键原样放行。
            guard isCommand != isControl,
                  !flags.contains(.option),
                  !flags.contains(.shift) else { return event }

            // 只有正在编辑文本时才接管；其余场景原样交回。
            guard let responder = (event.window ?? NSApp.keyWindow)?.firstResponder,
                  responder is NSTextView || responder is NSTextField else { return event }

            // charactersIgnoringModifiers 在部分输入法 / 键盘布局下会带控制字符，
            // 因此用物理键位兜底。
            let char = event.charactersIgnoringModifiers?.lowercased()
            let key: String
            switch event.keyCode {
            case 8: key = "c"
            case 9: key = "v"
            case 7: key = "x"
            case 0: key = "a"
            default: key = char ?? ""
            }

            let action: Selector?
            switch key {
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            default: action = nil
            }
            guard let action else { return event }
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
        }
    }
}
