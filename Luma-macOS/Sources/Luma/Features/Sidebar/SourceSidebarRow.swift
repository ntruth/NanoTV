import SwiftUI
import LumaContentCore

/// 侧边栏「源」行的统一描述：云盘、网络资源、影院、电视共用。
/// 只放展示数据，不放具体业务动作；动作由调用方通过闭包注入。
struct SourceRowModel {
    enum BadgeTone {
        case neutral
        case current
        case ok
        case warn
        case bad
    }

    struct Badge {
        var text: String
        var tone: BadgeTone = .neutral
    }

    var title: String
    var subtitle: String?
    var badge: Badge?
    var countText: String?
    var isCurrent: Bool = false
    var isEnabled: Bool = true
    var isLoading: Bool = false
    var showsNewBadge: Bool = false
    /// 刮削进度（0–1）：有值时在行尾画一枚小进度环。
    var progress: Double? = nil
    /// 源健康状态：未知 / 正常时不画点，只把异常（降级 / 离线 / 需登录）露出来。
    var health: SourceHealth? = nil
}

/// 侧边栏源行的统一外壳：封面、标题、状态、悬停、拖拽手柄、展开按钮与右键菜单。
/// 与 `SidebarCategoryRow` 保持同一套行高、图标列、圆角与高亮。
struct SourceSidebarRow<Cover: View, Menu: View>: View {
    let model: SourceRowModel
    var isExpanded: Bool = false
    var showsToggle: Bool = false
    var isDropTarget: Bool = false
    var onOpen: () -> Void
    var onToggle: (() -> Void)?
    /// 健康点可点开：重试 / 重新登录都由调用方注入，和页面里的错误卡走同一套恢复动作。
    var onRetry: (() -> Void)?
    var onReauthorize: (() -> Void)?
    var dragProvider: (() -> NSItemProvider)?
    @ViewBuilder var cover: (Bool) -> Cover
    @ViewBuilder var menu: () -> Menu

    @State private var isHovering = false
    @State private var showHealth = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                    cover(isHovering)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.title)
                            .font(.system(size: LumaMetrics.sidebarTextSize))
                            .lineLimit(1)
                        if let subtitle = model.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if model.showsNewBadge {
                        Text("新")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.85), in: Capsule(style: .continuous))
                    }
                    Spacer(minLength: 0)
                    if !model.isEnabled {
                        Text("未启用")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    } else if model.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    if let progress = model.progress {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 2)
                            Circle()
                                .trim(from: 0, to: max(0.02, min(1, progress)))
                                .stroke(LumaBrand.amber,
                                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 12, height: 12)
                        .help("刮削中 \(Int(progress * 100))%")
                    }
                    if let badge = model.badge {
                        badgeView(badge)
                    }
                    if let health = model.health, let dot = healthDot(health) {
                        Button {
                            showHealth.toggle()
                        } label: {
                            Circle()
                                .fill(dot.color)
                                .frame(width: 6, height: 6)
                                .contentShape(Rectangle().inset(by: -5))
                        }
                        .buttonStyle(.plain)
                        .help(dot.help)
                        .popover(isPresented: $showHealth, arrowEdge: .bottom) {
                            healthPopover(health)
                                .environment(\.colorScheme, .light)
                        }
                    }
                    if let countText = model.countText, !countText.isEmpty {
                        Text(countText)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let dragProvider {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isHovering ? Color.secondary : Color.clear)
                    .frame(width: 16)
                    .contentShape(Rectangle())
                    .onDrag(dragProvider)
                    .help("拖动调整源顺序")
            }

            if showsToggle, let onToggle {
                Button(action: onToggle) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 16, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起" : "展开")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
        .background {
            LumaRowHighlight(active: model.isCurrent, hovered: isHovering)
        }
        .overlay(alignment: .top) {
            if isDropTarget {
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .shadow(color: Color.accentColor.opacity(0.5), radius: 3)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            menu()
        }
        .accessibilityLabel(model.title)
    }

    /// 源健康 → 行尾状态点：只暴露需要用户处理的异常，正常 / 未知保持安静。
    private func healthDot(_ health: SourceHealth) -> (color: Color, help: String)? {
        let detail = health.message.map { " · \($0)" } ?? ""
        switch health.state {
        case .healthy, .unknown, .checking:
            return nil
        case .degraded:
            return (LumaBrand.amber, "源响应偏慢\(detail)")
        case .offline:
            return (LumaBrand.coral, "源暂时连不上\(detail)")
        case .authRequired:
            return (.orange, "需要重新登录 / 授权\(detail)")
        }
    }

    /// 健康点弹层：原因 + 与页面错误卡相同的恢复动作。
    private func healthPopover(_ health: SourceHealth) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.title)
                .font(.system(size: 11.5, weight: .semibold))
            SourceErrorView(error: sourceError(health)) { action in
                showHealth = false
                switch action {
                case .retry:
                    onRetry?()
                case .reauthorize, .reconfigureSource:
                    onReauthorize?()
                case .openInBrowser(let address):
                    if let url = URL(string: address) { NSWorkspace.shared.open(url) }
                case .openSystemSettings:
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                case .allowInsecureTLS:
                    break
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    /// 源健康 → 统一错误模型：弹层与页面错误卡共用同一套文案和按钮。
    private func sourceError(_ health: SourceHealth) -> SourceError {
        switch health.state {
        case .authRequired:
            return SourceError(kind: .unauthorized,
                               message: health.message ?? "授权已失效，请重新登录或授权。",
                               recovery: [.reauthorize, .retry])
        case .offline:
            return SourceError(kind: .unavailable,
                               message: health.message ?? "源暂时连不上。",
                               recovery: [.retry])
        case .degraded:
            return SourceError(kind: .unavailable,
                               message: health.message ?? "源响应偏慢，可能影响加载速度。",
                               recovery: [.retry])
        case .healthy, .unknown, .checking:
            return SourceError(kind: .unavailable,
                               message: health.message ?? "源状态正常。",
                               recovery: [.retry])
        }
    }

    private func badgeView(_ badge: SourceRowModel.Badge) -> some View {
        Text(badge.text)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(badgeForeground(badge.tone))
            .background(badgeBackground(badge.tone), in: Capsule(style: .continuous))
    }

    private func badgeForeground(_ tone: SourceRowModel.BadgeTone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .current: return .white
        case .ok: return Color(red: 0.23, green: 0.72, blue: 0.45)
        case .warn: return Color(red: 0.78, green: 0.55, blue: 0.10)
        case .bad: return Color(red: 0.80, green: 0.30, blue: 0.24)
        }
    }

    private func badgeBackground(_ tone: SourceRowModel.BadgeTone) -> Color {
        switch tone {
        case .neutral: return Color.primary.opacity(0.06)
        case .current: return Color.accentColor
        case .ok: return Color(red: 0.23, green: 0.72, blue: 0.45).opacity(0.13)
        case .warn: return Color(red: 0.78, green: 0.55, blue: 0.10).opacity(0.14)
        case .bad: return Color(red: 0.80, green: 0.30, blue: 0.24).opacity(0.14)
        }
    }
}
