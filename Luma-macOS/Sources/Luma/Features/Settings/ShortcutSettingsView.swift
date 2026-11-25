import SwiftUI
import AppKit

/// 设置 › 快捷键：可视化列出可自定义的按键，点按按键即可重新录制。
struct ShortcutSettingsView: View {
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @Environment(\.colorScheme) private var scheme

    @State private var query = ""
    @State private var recording: ShortcutAction?
    @State private var message: String?
    @State private var keyMonitor: Any?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchBar
                if let message {
                    notice(message)
                }
                ForEach(visibleContexts) { context in
                    groupCard(context)
                }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    menuReference
                }
                footer
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(colors: [LumaBrand.violet.opacity(scheme == .dark ? 0.10 : 0.05),
                                    LumaBrand.cyan.opacity(scheme == .dark ? 0.06 : 0.03)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .onDisappear(perform: stopRecording)
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索动作或按键", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .disabled(recording != nil)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.primary.opacity(scheme == .dark ? 0.10 : 0.05),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(LumaBrand.amber)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                message = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(LumaBrand.amber.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(LumaBrand.amber.opacity(0.30), lineWidth: 0.8)
        }
    }

    // MARK: - 分组

    private var visibleContexts: [ShortcutContext] {
        ShortcutContext.allCases.filter { !filteredActions($0).isEmpty }
    }

    private func filteredActions(_ context: ShortcutContext) -> [ShortcutAction] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return context.actions }
        return context.actions.filter { action in
            action.title.lowercased().contains(text)
                || action.detail.lowercased().contains(text)
                || shortcuts.binding(for: action).display.lowercased().contains(text)
        }
    }

    private func groupCard(_ context: ShortcutContext) -> some View {
        let actions = filteredActions(context)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: context.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(context.tint)
                    .frame(width: 20, height: 20)
                    .background(context.tint.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.title)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(context.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text("\(actions.count) 项")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().opacity(0.4)

            ForEach(actions) { action in
                row(action)
                if action != actions.last {
                    Divider()
                        .padding(.leading, 48)
                        .opacity(0.28)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.15 : 0.06), lineWidth: 0.7)
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let isRecording = recording == action
        let binding = shortcuts.binding(for: action)
        return HStack(spacing: 11) {
            Image(systemName: action.symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(action.context.tint)
                .frame(width: 25, height: 25)
                .background(action.context.tint.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 12, weight: .medium))
                Text(action.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isRecording {
                recordingPill
            } else {
                Button {
                    beginRecording(action)
                } label: {
                    KeycapView(text: binding.display)
                }
                .buttonStyle(.plain)
                .help("点击后按下新快捷键；Delete 恢复默认")
            }

            if shortcuts.isCustomized(action), !isRecording {
                Button {
                    shortcuts.reset(action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("恢复默认（\(action.defaultBinding.display)）")
            } else if !isRecording {
                Color.clear.frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isRecording ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var recordingPill: some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
            Text("按下新按键…")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 0.8)
        }
    }

    // MARK: - 固定菜单快捷键

    private var menuReference: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("菜单快捷键")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
                Text("由系统菜单固定")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().opacity(0.4)

            let rows: [(String, String)] = [
                ("⌘I", "导入照片"),
                ("⌘E", "导出所选"),
                ("⌘F", "搜索"),
                ("⌘D", "复制照片"),
                ("⌘⌫", "移到最近删除"),
                ("⌘P", "打印"),
                ("⌘/", "打开快捷键面板")
            ]
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 11) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.quaternary)
                        .frame(width: 25)
                    Text(row.1)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    KeycapView(text: row.0, subdued: true)
                    Color.clear.frame(width: 18, height: 18)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                if index < rows.count - 1 {
                    Divider().padding(.leading, 48).opacity(0.28)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.15 : 0.06), lineWidth: 0.7)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("同场景内不能重复；⌘ 组合与 Space、方向键已保留给固定操作。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                stopRecording()
                shortcuts.resetAll()
            } label: {
                Text("恢复全部默认")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(shortcuts.customizedCount > 0 ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
                    }
            }
            .buttonStyle(.plain)
            .disabled(shortcuts.customizedCount == 0)
        }
        .padding(.top, 2)
    }

    // MARK: - 录制

    private func beginRecording(_ action: ShortcutAction) {
        stopRecording()
        message = nil
        recording = action
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            if event.keyCode == 51, flags.isEmpty {
                shortcuts.reset(action)
                stopRecording()
                return nil
            }
            if flags.contains(.command) {
                // 不拦 ⌘Q，避免录制状态下连退出都被吃掉。
                if event.keyCode == 12 { return event }
                message = "⌘ 组合留给系统菜单，请换一个组合"
                return nil
            }
            if ShortcutAction.isReserved(keyCode: event.keyCode, context: action.context) {
                message = "Space、方向键与 Esc 已保留给固定操作"
                return nil
            }

            let binding = ShortcutBinding(event: event)
            if let other = shortcuts.conflict(for: binding, in: action) {
                message = "与「\(other.title)」冲突，请换一个按键"
                return nil
            }
            shortcuts.set(binding, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        recording = nil
        message = nil
    }
}

// MARK: - 键帽

private struct KeycapView: View {
    let text: String
    var subdued = false
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var lifts: Bool { hovering && !subdued }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(lifts ? Color.accentColor
                                   : (subdued ? Color.secondary : Color.primary.opacity(0.85)))
            .padding(.horizontal, 7)
            .frame(height: 21)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(lifts ? 0.16 : 0.10)
                                          : Color.white.opacity(0.92))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(lifts ? Color.accentColor.opacity(0.40) : Color.primary.opacity(0.12),
                                  lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.08), radius: 1, y: 1)
            .offset(y: lifts ? -0.6 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}
