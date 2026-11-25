import SwiftUI
import Foundation

/// 五个可以独立开关的产品模块。
///
/// 开关属于「能力层」：关闭后侧边栏入口隐藏、全局搜索不再返回该模块的结果，
/// 但已经保存的数据不会被删除，重新打开就能回来。图库是一切内容的基础，始终开启。
///
/// 口径（1.2.1 收敛）：`cinema` 只代表「网络影院」——聚合网络影视源（苹果 CMS 系）的入口。
/// 本地磁盘 / 网盘里的影片（影院货架、AI 刮削）不属于独立模块，随「图库」与「网络存储」一起出现；
/// 因此影院模块的开关不会影响网络存储里的影片浏览与播放。
enum AppModule: String, CaseIterable, Identifiable {
    case library
    case cloud
    case catalog
    case television
    case cinema

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "图库"
        case .cloud: return "网络存储"
        case .catalog: return "网络资源"
        case .television: return "网络电视"
        case .cinema: return "网络影院"
        }
    }

    /// 卡片上的一行关键词，扫一眼就知道这个模块负责什么。
    var tagline: String {
        switch self {
        case .library: return "照片 · 视频 · 相簿 · 人物"
        case .cloud: return "网盘与 NAS 直读"
        case .catalog: return "站点聚合 · 海报墙"
        case .television: return "直播 · 节目单 · 回看"
        case .cinema: return "影视源 · 追剧"
        }
    }

    /// 关闭后会发生什么：设置页里作为辅助说明。
    var detail: String {
        switch self {
        case .library: return "所有内容的基础模块，始终开启。"
        case .cloud: return "隐藏侧边栏入口，网盘文件不再出现在搜索结果里。"
        case .catalog: return "隐藏资源站点入口，资源条目不再出现在搜索结果里。"
        case .television: return "隐藏频道入口并停止拉流，频道不再出现在搜索结果里。"
        case .cinema: return "隐藏网络影院入口；影视源与网络资源各自独立管理，网盘里的影片不受影响。"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "photo.on.rectangle.angled"
        case .cloud: return "externaldrive.connected.to.line.below"
        case .catalog: return "square.stack.3d.up.fill"
        case .television: return "tv"
        case .cinema: return "film.stack"
        }
    }

    /// 卡片图标的两档渐变色。
    var tints: [Color] {
        switch self {
        case .library: return [LumaBrand.violet, LumaBrand.cyan]
        case .cloud: return [LumaBrand.cyan, LumaBrand.mint]
        case .catalog: return [LumaBrand.mint, LumaBrand.violet]
        case .television: return [Color(red: 1.00, green: 0.72, blue: 0.30), LumaBrand.coral]
        case .cinema: return [LumaBrand.coral, LumaBrand.violet]
        }
    }

    /// 基础模块不允许关闭：关掉之后没有内容可看。
    var isLocked: Bool { self == .library }

    var storageKey: String {
        switch self {
        case .library: return SettingsKeys.moduleLibraries
        case .cloud: return SettingsKeys.moduleCloud
        case .catalog: return SettingsKeys.moduleCatalog
        case .television: return SettingsKeys.showTelevision
        case .cinema: return SettingsKeys.moduleCinema
        }
    }

    /// 这个模块对应的全局搜索来源：关闭后来源胶囊与结果一起消失。
    /// 网络影院用独立的「网络影院」来源，网络资源只代表站点聚合出来的资源条目。
    var searchSource: SearchSourceKind {
        switch self {
        case .library: return .library
        case .cloud: return .cloud
        case .catalog: return .catalog
        case .television: return .television
        case .cinema: return .networkCinema
        }
    }
}

/// 模块开关的读写入口：视图用 `@AppStorage` 获得实时刷新，
/// 搜索与启动恢复这类「取一次」的地方直接用这里的静态方法。
enum AppModules {
    static func isEnabled(_ module: AppModule) -> Bool {
        guard !module.isLocked else { return true }
        return UserDefaults.standard.object(forKey: module.storageKey) as? Bool ?? true
    }

    static func isEnabled(_ source: SearchSourceKind) -> Bool {
        switch source {
        case .catalog:
            return isEnabled(AppModule.catalog)
        case .networkCinema:
            return isEnabled(AppModule.cinema)
        default:
            return isEnabled(module(for: source))
        }
    }

    static func module(for source: SearchSourceKind) -> AppModule {
        AppModule.allCases.first { $0.searchSource == source } ?? .library
    }

    /// 全局搜索允许出现的来源：模块关闭后连来源胶囊都不再显示。
    static var enabledSearchScopes: [SearchSourceKind] {
        SearchSourceKind.allCases.filter { isEnabled($0) }
    }
}

// MARK: - 五宫格开关

/// 五宫格模块开关：设置页与建库引导共用同一套卡片，只调整密度。
struct ModuleSwitchGrid: View {
    enum Density {
        /// 设置页：图标 + 标题 + 关键词 + 说明。
        case settings
        /// 建库引导：更紧凑，两行放得下。
        case setup
    }

    var density: Density = .settings
    /// 建库引导里额外的「全选 / 全不选」，默认不显示。
    var showsBulkActions = false

    /// 悬停说明单独占一行固定高度：卡片高度始终一致，不会因为说明展开而顶动整块布局。
    @State private var hintModule: AppModule?
    /// 建库引导里悬停中的能力珠。
    @State private var hoveredBead: AppModule?

    @AppStorage(SettingsKeys.moduleLibraries) private var libraries = true
    @AppStorage(SettingsKeys.moduleCloud) private var cloud = true
    @AppStorage(SettingsKeys.moduleCatalog) private var catalog = true
    @AppStorage(SettingsKeys.showTelevision) private var television = true
    @AppStorage(SettingsKeys.moduleCinema) private var cinema = true

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: density == .settings ? 150 : 132), spacing: 8)]
    }

    var body: some View {
        if density == .setup {
            setupList
        } else {
            settingsGrid
        }
    }

    /// 建库引导：把五个模块做成一条「光串」——五颗发光珠挂在细绳上，点亮就是拾起。
    private var setupList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsBulkActions {
                HStack(spacing: 9) {
                    Spacer(minLength: 0)
                    Button("全部拾起") { setAll(true) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Rectangle()
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: 0.8, height: 9)
                    Button("全部放下") { setAll(false) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            setupGarland
        }
    }

    /// 一条微垂的细绳 + 五颗等距能力珠；珠子上方有短吊绳，下方是名称与关键词。
    private var setupGarland: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let modules = AppModule.allCases
            let slot = width / CGFloat(modules.count)
            let bead: CGFloat = 54
            let centers: [CGPoint] = modules.enumerated().map { index, _ in
                let t = (CGFloat(index) + 0.5) / CGFloat(modules.count)
                let sag = 16 * CGFloat(sin(Double.pi * Double(t)))
                return CGPoint(x: slot * (CGFloat(index) + 0.5), y: 52 + sag)
            }

            ZStack(alignment: .topLeading) {
                garlandString(centers: centers, width: width, bead: bead)

                ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                    let center = centers[index]
                    let anchorY = center.y - bead / 2 - 14

                    // 细绳上的一颗小光点，珠子从这里垂下来。
                    Circle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 3.4, height: 3.4)
                        .shadow(color: LumaBrand.cyan.opacity(0.55), radius: 3)
                        .position(x: center.x, y: anchorY)

                    // 珠子与细绳之间的短吊绳。
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1.2, height: 14)
                        .position(x: center.x, y: center.y - bead / 2 - 7)

                    beadButton(module, center: center, size: bead)
                    beadLabel(module, center: center, slot: slot, bead: bead)
                }
            }
        }
        .frame(height: 172)
    }

    private func garlandString(centers: [CGPoint], width: CGFloat, bead: CGFloat) -> some View {
        let anchors = centers.map { CGPoint(x: $0.x, y: $0.y - bead / 2 - 14) }
        return Path { path in
            guard let first = anchors.first, let last = anchors.last else { return }
            path.move(to: CGPoint(x: 0, y: first.y))
            path.addLine(to: first)
            for index in 1..<anchors.count {
                let previous = anchors[index - 1]
                let current = anchors[index]
                path.addQuadCurve(to: current,
                                  control: CGPoint(x: (previous.x + current.x) / 2,
                                                   y: max(previous.y, current.y) + 12))
            }
            path.addLine(to: CGPoint(x: width, y: last.y))
        }
        .stroke(LinearGradient(colors: [LumaBrand.violet.opacity(0.50),
                                        LumaBrand.cyan.opacity(0.50)],
                               startPoint: .leading,
                               endPoint: .trailing),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    /// 一颗能力珠：点亮 = 拾起（彩色发光 + 打勾），放下 = 灰暗；图库常亮并带锁。
    private func beadButton(_ module: AppModule, center: CGPoint, size: CGFloat) -> some View {
        let isOn = binding(for: module).wrappedValue
        let active = module.isLocked || isOn
        let hovered = hoveredBead == module

        return Button {
            guard !module.isLocked else { return }
            binding(for: module).wrappedValue.toggle()
        } label: {
            ZStack {
                // 珠子里透出来的光：点亮时才亮，给整串增加纵深。
                Circle()
                    .fill(module.tints[0])
                    .frame(width: size + 18, height: size + 18)
                    .blur(radius: 18)
                    .opacity(active ? 0.45 : 0)

                Circle()
                    .fill(Color.primary.opacity(active ? 0.06 : 0.03))

                Circle()
                    .fill(LinearGradient(colors: module.tints,
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .opacity(active ? 1 : 0.14)

                // 左上高光：像一颗有厚度的玻璃珠。
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.48),
                                                  Color.white.opacity(0)],
                                         center: .topLeading,
                                         startRadius: 1,
                                         endRadius: size * 0.72))
                    .opacity(active ? 1 : 0.45)

                ModuleGlyph(module: module, size: size * 0.52)
                    .opacity(active ? 1 : 0.55)

                Group {
                    if module.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    } else {
                        Image(systemName: isOn ? "checkmark" : "minus")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(isOn ? Color.white : Color.secondary)
                            .frame(width: 16, height: 16)
                            .background {
                                Circle()
                                    .fill(isOn ? AnyShapeStyle(Color.accentColor)
                                               : AnyShapeStyle(Color.primary.opacity(0.10)))
                            }
                            .overlay {
                                Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                            }
                    }
                }
                .offset(x: 19, y: 19)
            }
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(active ? Color.white.opacity(0.40)
                                             : Color.primary.opacity(0.10),
                                      lineWidth: 1)
            }
            .shadow(color: active ? module.tints[0].opacity(0.55) : .clear, radius: 14, y: 5)
            .scaleEffect(hovered ? 1.08 : 1)
            .opacity(active ? 1 : 0.55)
            .animation(.snappy(duration: 0.18), value: isOn)
            .animation(.easeOut(duration: 0.14), value: hovered)
        }
        .buttonStyle(.plain)
        .position(x: center.x, y: center.y)
        .onHover { hovering in
            if hovering { hoveredBead = module }
            else if hoveredBead == module { hoveredBead = nil }
        }
        .help(module.detail)
    }

    private func beadLabel(_ module: AppModule, center: CGPoint, slot: CGFloat, bead: CGFloat) -> some View {
        let isOn = binding(for: module).wrappedValue
        let active = module.isLocked || isOn

        return Button {
            guard !module.isLocked else { return }
            binding(for: module).wrappedValue.toggle()
        } label: {
            VStack(spacing: 3) {
                Text(module.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.55))
                Text(module.tagline)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .multilineTextAlignment(.center)
            .frame(width: slot - 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: center.x, y: center.y + bead / 2 + 32)
        .help(module.detail)
    }

    private var settingsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsBulkActions {
                HStack(spacing: 10) {
                    Text("默认全部开启，按需要去掉不用的")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Button("全选") { setAll(true) }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                    Button("全不选") { setAll(false) }
                        .buttonStyle(.link)
                        .font(.system(size: 10.5))
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(AppModule.allCases) { module in
                    ModuleSwitchCard(module: module,
                                     isOn: binding(for: module),
                                     density: density) { hovering in
                        guard density == .settings else { return }
                        // 相邻卡片先后触发的 hover 事件交错时，只清掉自己那条说明。
                        hintModule = hovering ? module : (hintModule == module ? nil : hintModule)
                    }
                }
            }

            if density == .settings {
                Text(hintModule?.detail ?? "关闭只隐藏入口与搜索结果，已经存下的数据仍然保留。")
                    .font(.system(size: 10))
                    .foregroundStyle(hintModule == nil ? Color.secondary.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: hintModule)
            }
        }
    }

    private func binding(for module: AppModule) -> Binding<Bool> {
        switch module {
        case .library: return $libraries
        case .cloud: return $cloud
        case .catalog: return $catalog
        case .television: return $television
        case .cinema: return $cinema
        }
    }

    private func setAll(_ value: Bool) {
        libraries = true          // 基础模块保持开启
        cloud = value
        catalog = value
        television = value
        cinema = value
    }
}

/// 单个模块卡片：彩色图标 + 名称 + 关键词 + 开关；关闭时整卡降饱和。
/// 卡片高度只由图标与两行文字决定，悬停说明交给外面的固定说明行，避免整块布局跳动。
private struct ModuleSwitchCard: View {
    let module: AppModule
    @Binding var isOn: Bool
    let density: ModuleSwitchGrid.Density
    var onHover: ((Bool) -> Void)?

    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    private var isDark: Bool { scheme == .dark }
    private var isSetup: Bool { density == .setup }
    private var active: Bool { module.isLocked || isOn }

    var body: some View {
        VStack(alignment: .leading, spacing: isSetup ? 6 : 8) {
            HStack(alignment: .top, spacing: 6) {
                iconTile
                Spacer(minLength: 0)
                control
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(module.title)
                    .font(.system(size: isSetup ? 11.5 : 12.5, weight: .semibold))
                    .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.55))
                    .lineLimit(1)
                Text(module.tagline)
                    .font(.system(size: isSetup ? 9.5 : 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, isSetup ? 9 : 10)
        .padding(.vertical, isSetup ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(active ? (isDark ? 0.07 : 0.045) : 0.028))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active
                              ? AnyShapeStyle(LinearGradient(colors: module.tints.map { $0.opacity(isDark ? 0.55 : 0.42) },
                                                             startPoint: .topLeading,
                                                             endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color.primary.opacity(0.07)),
                              lineWidth: active ? 1 : 0.6)
        }
        .opacity(active ? 1 : 0.72)
        .scaleEffect(hovered ? 1.008 : 1)
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.easeOut(duration: 0.18), value: isOn)
        .onHover { hovering in
            guard density == .settings else { return }
            hovered = hovering
            onHover?(hovering)
        }
        .help(module.detail)
        .accessibilityElement(children: .combine)
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: module.tints,
                                 startPoint: .topLeading,
                                 endPoint: .bottomTrailing))
            .frame(width: isSetup ? 22 : 26, height: isSetup ? 22 : 26)
            .overlay {
                ModuleGlyph(module: module, size: isSetup ? 15 : 18)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6)
            }
            .saturation(active ? 1 : 0.1)
            .shadow(color: active ? module.tints[0].opacity(0.28) : .clear, radius: 5, y: 2)
    }

    @ViewBuilder
    private var control: some View {
        if module.isLocked {
            Text("常开")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))
        } else {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(module.title)
        }
    }
}

// MARK: - 模块拟物图标

/// 五个模块的拟物插图：分别画出「叠放的照片 / NAS 硬盘 / 站点海报墙 / 带天线电视 / 胶片盘」，
/// 用多层形状、渐变与投影做出厚度，建库引导的能力珠与设置页的小图标共用同一套图形。
private struct ModuleGlyph: View {
    let module: AppModule
    let size: CGFloat

    var body: some View {
        ZStack {
            switch module {
            case .library: AlbumGlyph(s: size)
            case .cloud: NASGlyph(s: size)
            case .catalog: PosterWallGlyph(s: size)
            case .television: TelevisionGlyph(s: size)
            case .cinema: FilmReelGlyph(s: size)
            }
        }
        .frame(width: size, height: size)
        .compositingGroup()
    }
}

/// 图库：两张叠放的照片——背面斜卡露出边缘，正面白框拍立得里有天空、太阳与远山。
private struct AlbumGlyph: View {
    let s: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.09, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.92, green: 0.96, blue: 1.0),
                                              Color(red: 0.77, green: 0.87, blue: 0.99)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: s * 0.56, height: s * 0.68)
                .overlay {
                    RoundedRectangle(cornerRadius: s * 0.09, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.75),
                                      lineWidth: max(0.6, s * 0.02))
                }
                .rotationEffect(.degrees(-14))
                .offset(x: -s * 0.12, y: -s * 0.02)
                .shadow(color: .black.opacity(0.20), radius: s * 0.04, y: s * 0.02)

            VStack(spacing: 0) {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.56, green: 0.84, blue: 0.99),
                                            Color(red: 0.40, green: 0.60, blue: 0.96)],
                                   startPoint: .top,
                                   endPoint: .bottom)
                    Circle()
                        .fill(Color(red: 1.0, green: 0.84, blue: 0.36))
                        .frame(width: s * 0.13, height: s * 0.13)
                        .offset(x: s * 0.15, y: -s * 0.13)
                    MountainShape()
                        .fill(Color(red: 0.27, green: 0.48, blue: 0.83))
                        .frame(width: s * 0.46, height: s * 0.20)
                        .offset(y: s * 0.11)
                }
                .frame(width: s * 0.46, height: s * 0.32)
                .clipShape(RoundedRectangle(cornerRadius: s * 0.03, style: .continuous))
                .padding(.top, s * 0.06)

                Spacer(minLength: 0)
            }
            .frame(width: s * 0.58, height: s * 0.72)
            .background {
                RoundedRectangle(cornerRadius: s * 0.07, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 1.0), Color(white: 0.90)],
                                         startPoint: .top,
                                         endPoint: .bottom))
            }
            .rotationEffect(.degrees(6))
            .offset(x: s * 0.09, y: s * 0.03)
            .shadow(color: .black.opacity(0.26), radius: s * 0.05, y: s * 0.03)
        }
    }
}

/// 网络存储：一台 NAS——顶盖、机身、三个硬盘抽屉与状态灯，右上角三层网络信号。
private struct NASGlyph: View {
    let s: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.05, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 1.0), Color(white: 0.86)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .frame(width: s * 0.56, height: s * 0.11)
                .offset(y: -s * 0.27)
                .shadow(color: .black.opacity(0.16), radius: s * 0.02, y: s * 0.01)

            RoundedRectangle(cornerRadius: s * 0.10, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.76)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: s * 0.60, height: s * 0.58)
                .offset(y: s * 0.03)
                .shadow(color: .black.opacity(0.28), radius: s * 0.05, y: s * 0.03)

            VStack(spacing: s * 0.06) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: s * 0.05) {
                        RoundedRectangle(cornerRadius: s * 0.02, style: .continuous)
                            .fill(Color(white: 0.38))
                            .frame(width: s * 0.28, height: s * 0.055)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.20))
                                    .frame(height: max(0.5, s * 0.012))
                            }
                        Circle()
                            .fill(index == 0
                                  ? Color(red: 0.36, green: 0.92, blue: 0.58)
                                  : Color(red: 0.38, green: 0.78, blue: 0.98))
                            .frame(width: s * 0.055, height: s * 0.055)
                            .shadow(color: (index == 0
                                            ? Color(red: 0.36, green: 0.92, blue: 0.58)
                                            : Color(red: 0.38, green: 0.78, blue: 0.98)).opacity(0.8),
                                    radius: s * 0.025)
                        Spacer(minLength: 0)
                    }
                    .frame(width: s * 0.42)
                }
            }
            .offset(y: s * 0.02)

            SignalWaves()
                .stroke(Color(red: 0.32, green: 0.90, blue: 0.72),
                        style: StrokeStyle(lineWidth: max(0.7, s * 0.025), lineCap: .round))
                .frame(width: s * 0.22, height: s * 0.22)
                .offset(x: s * 0.23, y: -s * 0.22)
        }
    }
}

/// 网络资源：浏览器窗口里是一面迷你海报墙，背后再斜放两张海报，表达「多站点聚合」。
private struct PosterWallGlyph: View {
    let s: CGFloat

    var body: some View {
        ZStack {
            backCard(colors: [Color(red: 0.72, green: 0.62, blue: 0.99),
                              Color(red: 0.52, green: 0.44, blue: 0.95)],
                     angle: -17, dx: -s * 0.20, dy: -s * 0.02)
            backCard(colors: [Color(red: 0.44, green: 0.90, blue: 0.82),
                              Color(red: 0.30, green: 0.78, blue: 0.88)],
                     angle: 15, dx: s * 0.21, dy: s * 0.02)

            VStack(spacing: 0) {
                HStack(spacing: s * 0.026) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index == 0
                                  ? Color(red: 1.0, green: 0.44, blue: 0.40)
                                  : (index == 1 ? Color(red: 1.0, green: 0.78, blue: 0.32)
                                                : Color(red: 0.36, green: 0.82, blue: 0.50)))
                            .frame(width: s * 0.034, height: s * 0.034)
                    }
                    Capsule()
                        .fill(Color(white: 0.86))
                        .frame(height: max(1.2, s * 0.04))
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, s * 0.05)
                .frame(height: s * 0.11)

                VStack(spacing: s * 0.028) {
                    HStack(spacing: s * 0.028) {
                        miniPoster([Color(red: 0.62, green: 0.55, blue: 0.99),
                                    Color(red: 0.86, green: 0.52, blue: 0.90)])
                        miniPoster([Color(red: 0.38, green: 0.82, blue: 0.99),
                                    Color(red: 0.34, green: 0.56, blue: 0.95)])
                    }
                    HStack(spacing: s * 0.028) {
                        miniPoster([Color(red: 1.0, green: 0.74, blue: 0.38),
                                    Color(red: 0.99, green: 0.52, blue: 0.44)])
                        miniPoster([Color(red: 0.44, green: 0.90, blue: 0.72),
                                    Color(red: 0.26, green: 0.72, blue: 0.64)])
                    }
                }
                .padding(.horizontal, s * 0.05)
                .padding(.top, s * 0.04)
                .padding(.bottom, s * 0.05)
            }
            .frame(width: s * 0.72, height: s * 0.62)
            .background {
                RoundedRectangle(cornerRadius: s * 0.07, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 1.0), Color(white: 0.90)],
                                         startPoint: .top,
                                         endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: s * 0.07, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: s * 0.07, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.85),
                                  lineWidth: max(0.6, s * 0.02))
            }
            .shadow(color: .black.opacity(0.28), radius: s * 0.05, y: s * 0.03)
        }
    }

    private func backCard(colors: [Color], angle: Double, dx: CGFloat, dy: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: s * 0.05, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: s * 0.30, height: s * 0.42)
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: s * 0.015, style: .continuous)
                    .fill(Color.white.opacity(0.55))
                    .frame(height: s * 0.035)
                    .padding(.horizontal, s * 0.04)
                    .padding(.bottom, s * 0.04)
            }
            .rotationEffect(.degrees(angle))
            .offset(x: dx, y: dy)
            .shadow(color: .black.opacity(0.20), radius: s * 0.03, y: s * 0.02)
    }

    private func miniPoster(_ colors: [Color]) -> some View {
        RoundedRectangle(cornerRadius: s * 0.02, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: s * 0.24, height: s * 0.15)
    }
}

/// 网络电视：带天线的复古电视——机身厚度、玻璃屏幕、红点直播灯与侧边旋钮。
private struct TelevisionGlyph: View {
    let s: CGFloat

    var body: some View {
        ZStack {
            AntennaShape()
                .stroke(Color(white: 0.96),
                        style: StrokeStyle(lineWidth: max(0.7, s * 0.032), lineCap: .round))
                .frame(width: s * 0.44, height: s * 0.18)
                .offset(y: -s * 0.30)
            Circle()
                .fill(Color(white: 0.98))
                .frame(width: s * 0.05, height: s * 0.05)
                .offset(x: -s * 0.22, y: -s * 0.38)
            Circle()
                .fill(Color(white: 0.98))
                .frame(width: s * 0.05, height: s * 0.05)
                .offset(x: s * 0.19, y: -s * 0.36)

            RoundedRectangle(cornerRadius: s * 0.11, style: .continuous)
                .fill(Color(white: 0.52))
                .frame(width: s * 0.80, height: s * 0.52)
                .offset(x: s * 0.03, y: s * 0.11)

            RoundedRectangle(cornerRadius: s * 0.11, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 1.0), Color(white: 0.78)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .frame(width: s * 0.80, height: s * 0.52)
                .offset(y: s * 0.06)
                .shadow(color: .black.opacity(0.30), radius: s * 0.05, y: s * 0.035)

            RoundedRectangle(cornerRadius: s * 0.06, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.80, blue: 0.99),
                                              Color(red: 0.35, green: 0.42, blue: 0.92)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: s * 0.48, height: s * 0.34)
                .overlay {
                    LinearGradient(colors: [Color.white.opacity(0.42), .clear],
                                   startPoint: .topLeading,
                                   endPoint: .center)
                        .clipShape(RoundedRectangle(cornerRadius: s * 0.06, style: .continuous))
                }
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.32, blue: 0.30))
                        .frame(width: s * 0.06, height: s * 0.06)
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(0.85),
                                                  lineWidth: max(0.5, s * 0.012))
                        }
                        .padding(s * 0.035)
                }
                .offset(x: -s * 0.10, y: s * 0.05)
                .shadow(color: .black.opacity(0.22), radius: s * 0.02, y: s * 0.01)

            VStack(spacing: s * 0.05) {
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.66)],
                                         startPoint: .top,
                                         endPoint: .bottom))
                    .frame(width: s * 0.10, height: s * 0.10)
                RoundedRectangle(cornerRadius: s * 0.012, style: .continuous)
                    .fill(Color(white: 0.45))
                    .frame(width: s * 0.10, height: max(0.6, s * 0.018))
                RoundedRectangle(cornerRadius: s * 0.012, style: .continuous)
                    .fill(Color(white: 0.45))
                    .frame(width: s * 0.10, height: max(0.6, s * 0.018))
            }
            .offset(x: s * 0.25, y: s * 0.03)

            Capsule()
                .fill(Color(white: 0.62))
                .frame(width: s * 0.16, height: s * 0.05)
                .offset(x: -s * 0.20, y: s * 0.33)
            Capsule()
                .fill(Color(white: 0.62))
                .frame(width: s * 0.16, height: s * 0.05)
                .offset(x: s * 0.20, y: s * 0.33)
        }
    }
}

/// 网络影院：一只胶片盘——六个卷片孔、中心轴、边缘高光，右下方拖出一小段带齿孔的胶片。
private struct FilmReelGlyph: View {
    let s: CGFloat

    var body: some View {
        ZStack {
            filmTail

            Circle()
                .fill(Color.black.opacity(0.22))
                .frame(width: s * 0.72, height: s * 0.72)
                .offset(y: s * 0.05)
                .blur(radius: s * 0.04)

            Circle()
                .fill(LinearGradient(colors: [Color(white: 1.0), Color(white: 0.80)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: s * 0.70, height: s * 0.70)

            Circle()
                .strokeBorder(Color(white: 0.60), lineWidth: max(0.7, s * 0.03))
                .frame(width: s * 0.66, height: s * 0.66)

            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(Color(white: 0.44))
                    .frame(width: s * 0.115, height: s * 0.115)
                    .offset(y: -s * 0.225)
                    .rotationEffect(.degrees(Double(index) * 60))
                    .shadow(color: .black.opacity(0.18), radius: s * 0.01, y: s * 0.008)
            }

            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.72)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .frame(width: s * 0.20, height: s * 0.20)
                .shadow(color: .black.opacity(0.22), radius: s * 0.015, y: s * 0.008)
            Circle()
                .fill(Color(white: 0.40))
                .frame(width: s * 0.07, height: s * 0.07)

            Circle()
                .trim(from: 0.08, to: 0.32)
                .stroke(Color.white.opacity(0.75),
                        style: StrokeStyle(lineWidth: max(0.8, s * 0.025), lineCap: .round))
                .frame(width: s * 0.62, height: s * 0.62)
                .rotationEffect(.degrees(-16))
        }
    }

    /// 从盘后拖出的胶片头：白底 + 四个齿孔，斜插在右下角。
    private var filmTail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.02, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.86)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .frame(width: s * 0.17, height: s * 0.38)
            VStack(spacing: s * 0.045) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: s * 0.008, style: .continuous)
                        .fill(Color(white: 0.46))
                        .frame(width: s * 0.05, height: s * 0.045)
                }
            }
        }
        .rotationEffect(.degrees(26))
        .offset(x: s * 0.30, y: s * 0.26)
        .shadow(color: .black.opacity(0.22), radius: s * 0.03, y: s * 0.02)
    }
}

// MARK: - 拟物图标用到的形状

private struct MountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34,
                                 y: rect.minY + rect.height * 0.30))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.54,
                                 y: rect.minY + rect.height * 0.66))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72,
                                 y: rect.minY + rect.height * 0.26))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// NAS 右上角的三层网络信号：以左下角为圆心向外画的四分之一圆弧。
private struct SignalWaves: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let origin = CGPoint(x: rect.minX, y: rect.maxY)
        for index in 0..<3 {
            let radius = rect.width * (0.34 + 0.33 * CGFloat(index))
            path.addArc(center: origin,
                        radius: radius,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(0),
                        clockwise: false)
        }
        return path
    }
}

/// 电视的两根天线：从机身顶部往左上 / 右上张开。
private struct AntennaShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let base = CGPoint(x: rect.midX, y: rect.maxY)
        path.move(to: base)
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY))
        path.move(to: base)
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.84,
                                 y: rect.minY + rect.height * 0.10))
        return path
    }
}
