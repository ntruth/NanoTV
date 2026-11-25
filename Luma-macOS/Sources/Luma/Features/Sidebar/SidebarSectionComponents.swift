import SwiftUI

/// 侧边栏层级缩进：图库下的树整体比图库行再深一级。
enum SidebarTreeMetrics {
    /// 图库行图标列在 22pt 处（8 留白 + 12 折叠箭头 + 2 间距）；
    /// 树里的行整体再缩进 26pt，图标列落在 34pt、文字落在 62pt，
    /// 与父行的 22 / 50 拉开清楚的一级，子分区标题的竖线也对齐到 34pt。
    static let childIndent: CGFloat = 26
}

/// 侧边栏分类行：拾光、系统图库与网盘共用同一套图标列、字号、内边距与悬停高亮。
/// 数量只在调用方传入时显示（场景类型带数量，媒体类型与「更多项目」不带）。
struct SidebarCategoryRow: View {
    let icon: String
    let title: String
    var iconColor: Color = .accentColor
    var trailingIcon: String?
    var count: Int?
    var isActive: Bool = false
    var isHovered: Bool = false
    var helpText: String?
    /// 传了缩略图就用它替代系统图标（网络资源的分类行用站点真实封面）。
    var thumbnailSource: CatalogSource?
    var thumbnailURL: String?
    /// 二级分类向右缩进，和一级分组拉开层级。
    var leadingIndent: CGFloat = 8
    /// 二级分类用小圆点当图标。
    var iconSize: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LumaMetrics.sidebarRowSpacing) {
                iconView
                    .frame(width: LumaMetrics.sidebarIconColumn)
                Text(title)
                    .font(.system(size: LumaMetrics.sidebarTextSize))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let count, count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, leadingIndent)
            .padding(.trailing, 8)
            .padding(.vertical, LumaMetrics.sidebarRowVerticalPadding)
            .contentShape(Rectangle())
            .background {
                LumaRowHighlight(active: isActive, hovered: isHovered)
            }
        }
        .buttonStyle(.plain)
        .help(helpText ?? title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var iconView: some View {
        if let thumbnailSource, let thumbnailURL, !thumbnailURL.isEmpty {
            // 缩略图固定 20×20：封面是横图，scaledToFill 会向外撑开，
            // 这里用 Color.clear 兜住尺寸、再裁到圆角方块，避免盖住右边的标题。
            Color.clear
                .frame(width: LumaMetrics.sidebarCoverSize,
                       height: LumaMetrics.sidebarCoverSize)
                .overlay {
                    CatalogArtworkImage(source: thumbnailSource,
                                        urlString: thumbnailURL,
                                        cornerRadius: LumaMetrics.sidebarCoverRadius)
                }
                .clipShape(RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                           style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius,
                                     style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
        } else {
            Image(systemName: icon)
                .font(.system(size: iconSize ?? LumaMetrics.sidebarIconSize))
                .foregroundStyle(iconColor)
        }
    }
}

/// 可收起的分区头：整行（含左右留白）是点击区，标题可点击打开总览；
/// 悬停时浮出「更多」与收起 / 展开按钮。拾光、系统图库与网盘共用。
struct SidebarSectionHeader<MenuContent: View>: View {
    let title: String
    let collapsed: Bool
    var active: Bool = false
    var topPadding: CGFloat = 12
    /// 嵌套在上级分区里时向右缩进，和一级分区拉开层级。
    var indent: CGFloat = 0
    /// 一级模块（图库 / 网络存储 / 网络资源 / 网络影院 / 网络电视）：标题更大、行更高，
    /// 末尾常驻一枚箭头，明确表达「整行可点，进入该模块主页」。
    var isModule: Bool = false
    var isHovered: Bool = false
    var onOpen: (() -> Void)?
    let onToggle: () -> Void
    let menu: () -> MenuContent

    init(title: String,
         collapsed: Bool,
         active: Bool = false,
         topPadding: CGFloat = 12,
         indent: CGFloat = 0,
         isModule: Bool = false,
         isHovered: Bool = false,
         onOpen: (() -> Void)? = nil,
         onToggle: @escaping () -> Void,
         @ViewBuilder menu: @escaping () -> MenuContent = { EmptyView() }) {
        self.title = title
        self.collapsed = collapsed
        self.active = active
        self.topPadding = topPadding
        self.indent = indent
        self.isModule = isModule
        self.isHovered = isHovered
        self.onOpen = onOpen
        self.onToggle = onToggle
        self.menu = menu
    }

    private var rowHeight: CGFloat { isModule ? 26 : 22 }

    var body: some View {
        ZStack(alignment: .trailing) {
            // 整行（含左右留白）都是点击区域，不只是标题那几个字。
            if let onOpen {
                Button(action: onOpen) {
                    HStack(spacing: 0) {
                        label
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开「\(title)」主页")
            } else {
                // 没有二级总览的分区：整行点击就展开 / 收起，不必非要点右侧箭头。
                Button(action: onToggle) {
                    HStack(spacing: 0) {
                        label
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "展开「\(title)」" : "收起「\(title)」")
            }

            // 「更多」与收起 / 展开按钮浮在整行点击区之上，各自响应自己的点击。
            HStack(spacing: 2) {
                if isHovered {
                    Menu {
                        Button(collapsed ? "展开" : "收起") { onToggle() }
                        menu()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 16)
                    .help("更多")
                }
                if isHovered || collapsed || isModule {
                    Button(action: onToggle) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isModule && !isHovered
                                             ? Color.secondary.opacity(0.65)
                                             : Color.secondary)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(collapsed ? "展开" : "收起")
                }
            }
            .padding(.trailing, 8)
        }
        .padding(.top, topPadding)
        .padding(.bottom, isModule ? 2 : 3)
        .contentShape(Rectangle())
        .background {
            if isModule {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered
                          ? Color.primary.opacity(0.06)
                          : (active ? Color.accentColor.opacity(0.10) : Color.clear))
                    .padding(.horizontal, 2)
            }
        }
    }

    /// 分区标题：一级模块用一条更长的渐变竖线 + 13.5pt 主色标题；
    /// 嵌套分区保留短细线 + 小号次级标题。
    private var label: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(
                    LinearGradient(colors: [
                        Color.accentColor.opacity(active ? 0.95 : (isModule ? 0.55 : 0.42)),
                        Color.accentColor.opacity(active ? 0.35 : (isModule ? 0.18 : 0.08))
                    ], startPoint: .top, endPoint: .bottom)
                )
                .frame(width: isModule ? 2.5 : 2, height: isModule ? 14 : 10)
            Text(title)
                .font(.system(size: isModule ? 13.5 : 11, weight: .semibold))
                .tracking(0.06)
                .foregroundStyle(active
                                 ? Color.accentColor
                                 : (isModule ? Color.primary.opacity(0.92) : Color.secondary))
        }
        .padding(.leading, indent)
    }
}
