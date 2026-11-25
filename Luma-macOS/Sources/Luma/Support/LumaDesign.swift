import AppKit
import SwiftUI

/// 拾光的视觉基底：环境光背景、磨砂面板、细描边与行高亮。
///
/// 这里只使用系统语义色与用户强调色（`Color.accentColor`），不写死 RGB，
/// 保证随外观（浅色 / 深色）与设置里的强调色一起变化。
enum LumaMetrics {
    /// 侧边栏、列表行的圆角。
    static let rowRadius: CGFloat = 8
    /// 浮动面板（确认卡片、空状态等）的圆角。
    static let panelRadius: CGFloat = 22
    /// 侧边栏行文字：与 macOS「照片」一致的 13pt。
    static let sidebarTextSize: CGFloat = 13
    /// 侧边栏行图标：16pt 符号，占 20pt 图标列。
    static let sidebarIconSize: CGFloat = 16
    static let sidebarIconColumn: CGFloat = 20
    static let sidebarRowSpacing: CGFloat = 8
    static let sidebarRowVerticalPadding: CGFloat = 4
    /// 侧边栏相簿封面：20pt 圆角方块，圆角 4。
    static let sidebarCoverSize: CGFloat = 20
    static let sidebarCoverRadius: CGFloat = 4
}

/// 官网品牌色与渐变：只用于首屏、关于这类品牌面，不参与常规界面配色。
/// 色值取自 `website/styles.css` 的 `--coral / --amber / --mint / --cyan / --violet / --pink`。
enum LumaBrand {
    static let coral = Color(red: 1.00, green: 0.56, blue: 0.48)
    static let amber = Color(red: 1.00, green: 0.77, blue: 0.42)
    static let mint = Color(red: 0.49, green: 0.97, blue: 0.75)
    static let cyan = Color(red: 0.37, green: 0.85, blue: 1.00)
    static let violet = Color(red: 0.66, green: 0.55, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.48, blue: 0.78)

    /// 官网主渐变（图标光晕、线条、装饰）。
    static let gradient = LinearGradient(
        colors: [amber, coral, pink, violet, cyan],
        startPoint: .leading, endPoint: .trailing)

    /// 图标外圈那道彩色细环。
    static let ring = AngularGradient(
        colors: [coral, amber, mint, cyan, violet, pink, coral],
        center: .center)

    /// 文字用渐变：浅色模式下换成更深的同色相，避免在浅底上发白。
    static func textGradient(dark: Bool) -> LinearGradient {
        guard !dark else { return gradient }
        return LinearGradient(
            colors: [Color(red: 0.85, green: 0.35, blue: 0.24),
                     Color(red: 0.80, green: 0.22, blue: 0.55),
                     Color(red: 0.48, green: 0.30, blue: 0.85),
                     Color(red: 0.10, green: 0.52, blue: 0.78)],
            startPoint: .leading, endPoint: .trailing)
    }
}

/// 窗口级环境光：底部铺一层窗口底色，再叠两团强调色光晕与暗角。
/// 放在内容之后（`.background`）即可让磨砂材质透出颜色，避免整屏死灰。
struct LumaAmbientBackground: View {
    @Environment(\.colorScheme) private var scheme
    /// 0～1，用于侧边栏这类需要更克制的区域。
    var intensity: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let dark = scheme == .dark

            ZStack {
                Color(nsColor: .windowBackgroundColor)

                // 右上主光：让标题栏下方有颜色，磨砂材质会把它晕开。
                Circle()
                    .fill(Color.accentColor.opacity((dark ? 0.32 : 0.11) * intensity))
                    .frame(width: max(360, width * 0.72))
                    .blur(radius: max(70, width * 0.10))
                    .offset(x: width * 0.30, y: -height * 0.34)

                // 左下冷光：与主光形成对角平衡。
                Circle()
                    .fill(Color.accentColor.opacity((dark ? 0.18 : 0.07) * intensity))
                    .frame(width: max(280, width * 0.58))
                    .blur(radius: max(56, width * 0.08))
                    .offset(x: -width * 0.32, y: height * 0.36)

                // 中部提亮：浅色模式下压住颜色，避免整片发粉。
                Ellipse()
                    .fill(Color.white.opacity((dark ? 0.045 : 0.12) * intensity))
                    .frame(width: width * 0.92, height: height * 0.52)
                    .blur(radius: 90)
                    .offset(y: -height * 0.08)

                // 暗角：把注意力收回内容区。
                RadialGradient(colors: [.clear, Color.black.opacity(dark ? 0.30 : 0.04)],
                               center: .center,
                               startRadius: min(width, height) * 0.24,
                               endRadius: max(width, height) * 0.78)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 磨砂面板底：材质 + 一层极淡的斜向高光 + 渐变描边。
struct LumaGlassSurface: View {
    @Environment(\.colorScheme) private var scheme
    let shape: AnyShape

    var body: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay {
                shape.fill(
                    LinearGradient(colors: [
                        Color.white.opacity(scheme == .dark ? 0.10 : 0.46),
                        Color.white.opacity(scheme == .dark ? 0.015 : 0.18),
                        Color.accentColor.opacity(scheme == .dark ? 0.05 : 0.06)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
            .overlay {
                shape.stroke(
                    LinearGradient(colors: [
                        Color.white.opacity(scheme == .dark ? 0.34 : 0.75),
                        Color.white.opacity(scheme == .dark ? 0.05 : 0.24),
                        Color.black.opacity(scheme == .dark ? 0.28 : 0.05)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.8
                )
            }
    }
}

/// 侧边栏与列表的一行：选中用强调色渐变，悬停用极淡的前景色。
struct LumaRowHighlight: View {
    @Environment(\.colorScheme) private var scheme
    let active: Bool
    let hovered: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LumaMetrics.rowRadius, style: .continuous)
        shape
            .fill(fill)
            .overlay {
                if active {
                    shape.strokeBorder(
                        LinearGradient(colors: [
                            Color.white.opacity(scheme == .dark ? 0.24 : 0.62),
                            Color.white.opacity(0.02)
                        ], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.7
                    )
                }
            }
    }

    private var fill: AnyShapeStyle {
        if active {
            return AnyShapeStyle(
                LinearGradient(colors: [
                    Color.accentColor.opacity(scheme == .dark ? 0.36 : 0.26),
                    Color.accentColor.opacity(scheme == .dark ? 0.16 : 0.11)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        return AnyShapeStyle(Color.primary.opacity(hovered ? (scheme == .dark ? 0.09 : 0.06) : 0))
    }
}

/// 行内自管 hover：悬停状态只影响这一行，侧边栏不再维护全局 hovered 状态导致整棵树重算。
/// 系统图库相簿动辄上千条，必须让悬停开销限制在单行内。
struct HoverRowHighlight<Content: View>: View {
    let active: Bool
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        content
            .background { LumaRowHighlight(active: active, hovered: hovered) }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !hovered { hovered = true }
                case .ended:
                    hovered = false
                }
            }
    }
}

private struct LumaGlassModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let shape: AnyShape
    let shadow: Bool

    func body(content: Content) -> some View {
        content
            .background { LumaGlassSurface(shape: shape) }
            .clipShape(shape)
            .shadow(color: .black.opacity(shadow ? (scheme == .dark ? 0.46 : 0.14) : 0),
                    radius: shadow ? 18 : 0,
                    y: shadow ? 8 : 0)
    }
}

extension View {
    /// 磨砂卡片：材质、渐变高光、渐变描边与柔和投影。
    func lumaGlassCard(cornerRadius: CGFloat = LumaMetrics.panelRadius,
                       shadow: Bool = true) -> some View {
        modifier(LumaGlassModifier(
            shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)),
            shadow: shadow
        ))
    }

    /// 磨砂胶囊：用于计数、选择栏、提示条等浮动控件。
    func lumaGlassCapsule(shadow: Bool = true) -> some View {
        modifier(LumaGlassModifier(shape: AnyShape(Capsule()), shadow: shadow))
    }
}

// MARK: - 照片页头上的玻璃控件

/// 覆盖在照片 / 地图页头上的玻璃控件。
/// 深色外观用材质 + 白色描边；浅色外观改成白色半透明玻璃 + 深色描边，
/// 避免 `ultraThinMaterial` 在深色底图上发暗后，浅色模式的深色文字反而看不清。
private struct HeroGlassModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let shape: AnyShape
    var strokeWidth: CGFloat = 0.8

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(scheme == .dark
                           ? AnyShapeStyle(.ultraThinMaterial)
                           : AnyShapeStyle(Color.white.opacity(0.82)))
            }
            .overlay {
                shape.stroke(scheme == .dark
                             ? Color.white.opacity(0.18)
                             : Color.black.opacity(0.10),
                             lineWidth: strokeWidth)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.16), radius: 7, y: 2)
    }
}

extension View {
    /// 页头玻璃底：配合 `.primary` / `.secondary` 文字，两种外观都能读。
    func heroGlass<S: Shape>(_ shape: S, strokeWidth: CGFloat = 0.8) -> some View {
        modifier(HeroGlassModifier(shape: AnyShape(shape), strokeWidth: strokeWidth))
    }
}

// MARK: - 面包屑

/// 层级面包屑胶囊：相簿 / 文件夹与网盘目录共用同一套外观。
/// 根到当前项，超过三级折叠中间层，点任意一级跳回该层。
struct LumaBreadcrumbBar: View {
    struct Crumb: Identifiable, Hashable {
        let id: String
        let title: String
    }

    let crumbs: [Crumb]
    let onSelect: (Crumb) -> Void

    /// 层级过多时保留「根 + 最后两级」，中间收进省略号菜单。
    private var showsEllipsis: Bool { crumbs.count > 3 }
    private var hiddenCrumbs: [Crumb] {
        showsEllipsis ? Array(crumbs.dropFirst().dropLast(2)) : []
    }
    private var visibleCrumbs: [Crumb] {
        guard showsEllipsis, let first = crumbs.first else { return crumbs }
        return [first] + crumbs.suffix(2)
    }
    private var currentID: String? { crumbs.last?.id }

    var body: some View {
        HStack(spacing: 3) {
            if let first = visibleCrumbs.first {
                crumbView(first)
            }
            if showsEllipsis {
                separator
                Menu {
                    ForEach(hiddenCrumbs) { crumb in
                        Button(crumb.title) { onSelect(crumb) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("查看上级层级")
            }
            ForEach(visibleCrumbs.dropFirst()) { crumb in
                separator
                crumbView(crumb)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7.5, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func crumbView(_ crumb: Crumb) -> some View {
        if crumb.id == currentID {
            Text(crumb.title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200)
                .help(crumb.title)
        } else {
            Button {
                onSelect(crumb)
            } label: {
                Text(crumb.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120)
            }
            .buttonStyle(.plain)
            .help("前往「\(crumb.title)」")
        }
    }
}
