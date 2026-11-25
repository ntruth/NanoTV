import AppKit
import SwiftUI

/// 建库引导：首次启动没有图库时整屏展示；App 内点「新建图库」时复用同一套流程，
/// 以 sheet 形式直接进入「选择能力 → 选择位置并创建」，建好后立刻切到新图库。
/// 视觉与官网首屏对齐：真实 App 图标 + 品牌渐变光晕 + 玻璃卡片。
struct LibrarySetupView: View {
    /// 从「新建图库」入口以 sheet 打开：跳过品牌首屏，底部不再提供「退出拾光」。
    let creatingAdditionalLibrary: Bool

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    /// 迁入旧照片只对首次启动有意义；已有图库时新建的应该是一个空图库。
    @State private var migrateLocalPhotos = false
    /// 第二步：选择这台图库要启用哪些能力（默认全开）。
    @State private var showsModuleStep: Bool
    /// 建库 / 迁入进行中：按钮置灰，避免重复点击。
    @State private var isCreating = false
    /// 首屏入场动画：圆环、圆点与 Logo 依次就位。
    @State private var ringAppeared = false
    /// Logo 背后的光晕缓慢呼吸。
    @State private var glowBreathing = false
    /// 年轮徽标：光谱环自转、刻度与光圈缓慢转动。
    @State private var ringSpin = false
    /// 「拾光」隐喻：光粒向中心聚拢 / 散开的循环。
    @State private var motesGathered = false
    /// 外圈光点被一粒粒拾回核心：光粒从色点轨道飞向六边形。
    @State private var gatheringLights = false
    /// 悬停中的外观弧 / 强调色圆点。
    @State private var hoveredArc: AppAppearance?
    @State private var hoveredDot: AppAccent?
    /// 打开向导时的能力开关快照：sheet 里点「取消」要把全局开关还原。
    private let moduleSnapshot: [String: Bool]

    init(creatingAdditionalLibrary: Bool = false) {
        self.creatingAdditionalLibrary = creatingAdditionalLibrary
        _showsModuleStep = State(initialValue: creatingAdditionalLibrary)
        moduleSnapshot = Dictionary(uniqueKeysWithValues: AppModule.allCases.map {
            ($0.storageKey, AppModules.isEnabled($0))
        })
    }

    private var hasLocalPhotos: Bool { !store.photos.isEmpty }
    /// 旧版本地库（没有图库包）残留时也可以选择迁入。
    private var canMigrateLocal: Bool { hasLocalPhotos || LibraryPaths.hasLocalLibraryData }
    private var isDark: Bool { scheme == .dark }

    /// 强调色是否偏亮（金色 / 薄荷这类）：亮底上的文字要改用深色。
    private var accentIsLight: Bool {
        guard let rgb = NSColor(settings.accentColor).usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.62
    }

    /// 填充在强调色上的前景色：浅强调色配深字，其余配白字。
    private var accentForeground: Color {
        accentIsLight ? Color.black.opacity(0.85) : .white
    }

    /// 把强调色当文字用时压深一档，浅色页面上不会发虚。
    private var readableAccent: Color {
        (isDark || !accentIsLight) ? settings.accentColor : Color.black.opacity(0.72)
    }

    var body: some View {
        ZStack {
            LumaAmbientBackground()
            brandAura

            // 窗口够高时整卡居中；不够高（小窗口 / 最近图库较多）时改成可滚动，绝不裁掉内容。
            // sheet 形态里不再留外圈：图层本身就是一张卡片，再包一层只会多出一圈白边。
            ViewThatFits(in: .vertical) {
                card
                    .padding(creatingAdditionalLibrary ? 0 : 40)
                ScrollView(.vertical, showsIndicators: false) {
                    card
                        .padding(creatingAdditionalLibrary ? 0 : 40)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        // 引导里选外观 / 强调色即时预览整屏：点一下就能看到换肤效果。
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(settings.accentColor)
        .accentColor(settings.accentColor)
        .animation(.easeOut(duration: 0.18), value: settings.appearance)
        .onAppear {
            // 首次启动：默认把旧版本地照片迁入新图库。
            // 从「新建图库」进来时保持不勾选——新建的应该是一个空图库。
            if !creatingAdditionalLibrary {
                migrateLocalPhotos = canMigrateLocal
            }
            // 向导里配置的是「将要创建的新库」：主题先只记到 UserDefaults，
            // 建库完成后再写进新库，不能改到当前还在用的旧图库。
            settings.defersThemeToNewLibrary = creatingAdditionalLibrary
            // 入场动画：圆环从两侧旋入、Logo 弹出，随后光晕开始缓慢呼吸。
            DispatchQueue.main.async {
                ringAppeared = true
                glowBreathing = true
                ringSpin = true
                motesGathered = true
                gatheringLights = true
            }
        }
        .onDisappear {
            settings.defersThemeToNewLibrary = false
        }
    }

    // MARK: - 品牌光晕

    /// 官网首屏同款极光：紫 / 珊瑚 / 青三团低饱和光斑，只负责氛围。
    private var brandAura: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                Circle()
                    .fill(LumaBrand.violet.opacity(isDark ? 0.20 : 0.10))
                    .frame(width: max(320, width * 0.62))
                    .blur(radius: 110)
                    .offset(x: width * 0.24, y: -height * 0.26)

                Circle()
                    .fill(LumaBrand.coral.opacity(isDark ? 0.15 : 0.08))
                    .frame(width: max(280, width * 0.52))
                    .blur(radius: 100)
                    .offset(x: -width * 0.26, y: height * 0.20)

                Circle()
                    .fill(LumaBrand.cyan.opacity(isDark ? 0.12 : 0.07))
                    .frame(width: max(240, width * 0.44))
                    .blur(radius: 100)
                    .offset(x: width * 0.04, y: height * 0.40)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - 卡片

    private var card: some View {
        VStack(spacing: 0) {
            if showsModuleStep {
                moduleStep
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            } else {
                introStep
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .opacity))
            }

            // sheet 里创建的是另一个图库，不该再出现「退出拾光」这类首次启动的东西。
            if !creatingAdditionalLibrary {
                footer
                    .padding(.top, showsModuleStep ? 16 : 22)
            }
        }
        .padding(.horizontal, showsModuleStep ? 32 : 44)
        .padding(.vertical, showsModuleStep ? 26 : 34)
        .frame(width: showsModuleStep ? 560 : 500)
        // sheet 里铺满整张 sheet，圆角与投影交给系统窗口，避免四周再露出一圈底。
        .lumaGlassCard(cornerRadius: creatingAdditionalLibrary ? 0 : 32,
                       shadow: !creatingAdditionalLibrary)
        .animation(.snappy(duration: 0.28), value: showsModuleStep)
    }

    /// 第一步：年轮徽标套一圈「主题环」，下面只留一句口号与入口。
    private var introStep: some View {
        VStack(spacing: 0) {
            themeRing
                .padding(.top, 2)

            slogan
                .padding(.top, 16)

            Text("自动 = 跟随系统当前外观 · 点外圈色点换强调色")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .opacity(ringAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.45).delay(0.5), value: ringAppeared)

            if !recentLibraries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近打开的图库")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    recentLibraryList
                }
                .padding(.top, 18)
            }

            actions
                .padding(.top, 20)
        }
    }

    /// 品牌口号：把「每一段时光」做成品牌渐变，整句随 Logo 一起淡入。
    /// 渐变按当前外观取深浅两套色，浅色页面上不会发虚。
    private var slogan: some View {
        HStack(spacing: 0) {
            Text("拾起")
                .foregroundStyle(Color.primary.opacity(0.9))
            Text("每一段时光")
                .foregroundStyle(sloganGradient)
        }
        .font(.system(size: 19.5, weight: .semibold))
        .tracking(1.4)
        .opacity(ringAppeared ? 1 : 0)
        .offset(y: ringAppeared ? 0 : 8)
        .animation(.easeOut(duration: 0.5).delay(0.34), value: ringAppeared)
    }

    private var sloganGradient: LinearGradient {
        let colors: [Color] = isDark
            ? [settings.accentColor, LumaBrand.violet, LumaBrand.coral]
            : [readableAccent,
               Color(red: 0.45, green: 0.24, blue: 0.70),
               Color(red: 0.70, green: 0.24, blue: 0.36)]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    // MARK: - 主题圆环

    /// 圆环外径：年轮徽标居中，内圈三段是外观，外圈圆点是强调色。
    private static let ringSide: CGFloat = 336
    /// 中心徽标的柔光范围（没有实体边框，只留一圈渐隐的光）。
    private static let coreDiameter: CGFloat = 230
    /// 外观圆弧的半径：由容器内边距 56pt 决定。
    private static let arcRadius: CGFloat = 112
    private static let arcInset: CGFloat = 56
    /// 外观文字胶囊贴在圆弧外侧，介于圆弧与色点之间。
    private static let labelRadius: CGFloat = 130
    /// 强调色圆点所在的轨道半径。
    private static let dotRadius: CGFloat = 158

    /// 外观与强调色做成徽标四周的一圈「主题环」：
    /// 内圈三段圆弧 = 自动 / 浅色 / 深色，外圈圆点 = 强调色；点哪里，整个界面立刻跟着换。
    private var themeRing: some View {
        ZStack {
            // 柔光垫底：没有硬边框的方块，浅色下发暖、深色下发紫，不会有一块突兀的黑。
            Circle()
                .fill(RadialGradient(colors: [Color.white,
                                              settings.accentColor.opacity(isDark ? 0.30 : 0.16),
                                              Color.clear],
                                     center: .center,
                                     startRadius: 2,
                                     endRadius: 120))
                .frame(width: Self.coreDiameter, height: Self.coreDiameter)
                .blur(radius: 6)
                .scaleEffect(glowBreathing ? 1.06 : 0.94)
                .opacity(glowBreathing ? 1 : 0.82)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true),
                           value: glowBreathing)

            // 跟着年轮走的光晕：两团柔光绕核心缓慢巡游，露出的部分沿着环流动。
            orbitingGlow

            // 强调色轨道：一条极淡的细线，提示外圈圆点可以点。
            Circle()
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
                .frame(width: Self.dotRadius * 2, height: Self.dotRadius * 2)
                .allowsHitTesting(false)

            // 三段外观弧：入场时从左侧旋入。
            Group {
                ForEach(Array(AppAppearance.allCases.enumerated()), id: \.element.id) { index, mode in
                    appearanceArc(mode, index: index)
                }
            }
            .rotationEffect(.degrees(ringAppeared ? 0 : -26))
            .animation(.spring(response: 0.8, dampingFraction: 0.86), value: ringAppeared)

            // 强调色圆点：入场时从右侧旋入，随后逐颗浮现。
            Group {
                ForEach(Array(AppAccent.allCases.enumerated()), id: \.element.id) { index, item in
                    accentDot(item, index: index)
                }
            }
            .rotationEffect(.degrees(ringAppeared ? 0 : 30))
            .animation(.spring(response: 0.8, dampingFraction: 0.86), value: ringAppeared)

            // 悬停色点：在它外侧浮出颜色名，不用等系统 tooltip。
            if let hoveredDot {
                accentHint(hoveredDot)
                    .transition(.opacity)
            }

            // 拾光：外圈的光点被一粒粒吸回核心。
            lightGathering

            logoCore
                .scaleEffect(ringAppeared ? 1 : 0.84)
                .opacity(ringAppeared ? 1 : 0)
                .animation(.spring(response: 0.75, dampingFraction: 0.78), value: ringAppeared)
        }
        .frame(width: Self.ringSide, height: Self.ringSide)
        .animation(.snappy(duration: 0.22), value: settings.appearance)
        .animation(.snappy(duration: 0.22), value: settings.accent)
    }

    /// 跟着圆环走的光晕：两团柔光绕核心巡游，一多半藏在光圈与年轮后面，
    /// 露出的那一弯亮边会顺着环流动，看起来光随着年轮一起转。
    private var orbitingGlow: some View {
        ZStack {
            // 内圈：贴着光圈叶片外缘顺时针绕行。
            Circle()
                .fill(RadialGradient(colors: [settings.accentColor.opacity(isDark ? 0.55 : 0.45),
                                              settings.accentColor.opacity(0.18),
                                              .clear],
                                     center: .center,
                                     startRadius: 0,
                                     endRadius: 46))
                .frame(width: 92, height: 92)
                .blur(radius: 7)
                .offset(y: -62)
                .rotationEffect(.degrees(ringSpin ? 360 : 0))
                .animation(.linear(duration: 22).repeatForever(autoreverses: false),
                           value: ringSpin)

            // 外圈：更淡更大，压在光谱环与虚线年轮之间，反向绕行。
            Circle()
                .fill(RadialGradient(colors: [LumaBrand.violet.opacity(isDark ? 0.34 : 0.26),
                                              LumaBrand.cyan.opacity(isDark ? 0.14 : 0.12),
                                              .clear],
                                     center: .center,
                                     startRadius: 0,
                                     endRadius: 60))
                .frame(width: 120, height: 120)
                .blur(radius: 10)
                .offset(y: -98)
                .rotationEffect(.degrees(ringSpin ? -360 : 0))
                .animation(.linear(duration: 34).repeatForever(autoreverses: false),
                           value: ringSpin)
        }
        .frame(width: Self.coreDiameter, height: Self.coreDiameter)
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.22), value: settings.accent)
    }

    /// 拾光：外圈散落的光点被一粒粒吸回核心——加速飞向光圈，钻进六边形背后消失。
    /// 与色点同角度错开出发，视觉上就是「把散落在轨道上的光一段段拾回来」。
    private var lightGathering: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .frame(width: index.isMultiple(of: 2) ? 3 : 2.2,
                           height: index.isMultiple(of: 2) ? 3 : 2.2)
                    .shadow(color: settings.accentColor.opacity(0.95), radius: 4)
                    .shadow(color: settings.accentColor.opacity(0.55), radius: 8)
                    .offset(y: gatheringLights ? -50 : -(Self.dotRadius - 10))
                    .opacity(gatheringLights ? 0.12 : 1)
                    .rotationEffect(.degrees(Double(index) / 6 * 360))
                    .animation(.easeIn(duration: 3.2)
                                .repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.53),
                               value: gatheringLights)
            }
        }
        .frame(width: Self.ringSide, height: Self.ringSide)
        .allowsHitTesting(false)
    }

    /// 内圈的一段外观圆弧：选中变粗、变亮，悬停再粗一档，图标贴在弧线中点。
    private func appearanceArc(_ mode: AppAppearance, index: Int) -> some View {
        let selected = settings.appearance == mode
        let hovered = hoveredArc == mode
        let span: Double = 0.28
        let gap: Double = 0.0533
        let start = Double(index) * (span + gap)

        return Button {
            settings.appearance = mode
        } label: {
            ZStack {
                Circle()
                    .trim(from: start, to: start + span)
                    .stroke(arcStyle(mode),
                            style: StrokeStyle(lineWidth: selected ? 13 : (hovered ? 11 : 9),
                                               lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(Self.arcInset)
                    .opacity(ringAppeared ? (selected ? 1 : (hovered ? 0.9 : 0.5)) : 0)
                    .shadow(color: arcShadow(mode, selected: selected), radius: selected ? 8 : 0)

                // 圆弧外侧贴「自动 / 浅色 / 深色」，一眼就知道这里能换系统配色。
                HStack(spacing: 3) {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 8, weight: .bold))
                    Text(mode.compactTitle)
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(selected ? accentForeground : Color.primary.opacity(0.82))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background {
                    Capsule(style: .continuous)
                        .fill(selected ? AnyShapeStyle(settings.accentColor)
                                       : AnyShapeStyle(Color.primary.opacity(0.08)))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(selected ? Color.clear : Color.primary.opacity(0.10),
                                      lineWidth: 0.5)
                }
                .offset(ringOffset(radius: Self.labelRadius, fraction: start + span / 2))
                .opacity(ringAppeared ? 1 : 0)
            }
            // 整个扇区都能点：弧线、弧与标签之间的空隙、标签本身，点到附近就切换。
            .contentShape(RingSectorShape(startFraction: start - gap / 2,
                                          endFraction: start + span + gap / 2,
                                          innerRatio: 0.55,
                                          outerRatio: 0.93))
            .animation(.snappy(duration: 0.2), value: selected)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.5).delay(0.06 + Double(index) * 0.05),
                       value: ringAppeared)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredArc = mode }
            else if hoveredArc == mode { hoveredArc = nil }
        }
        .help(mode.title)
        .accessibilityLabel(mode.title)
    }

    /// 外圈的一颗强调色圆点：选中的会放大、描白边并打勾。
    private func accentDot(_ item: AppAccent, index: Int) -> some View {
        let selected = settings.accent == item
        let hovered = hoveredDot == item
        let fraction = Double(index) / Double(AppAccent.allCases.count)

        return Button {
            settings.accent = item
        } label: {
            Circle()
                .fill(item == .system ? AnyShapeStyle(LumaBrand.gradient)
                                      : AnyShapeStyle(item.swatch))
                .frame(width: selected ? 19 : 15, height: selected ? 19 : 15)
                .overlay {
                    Circle()
                        .strokeBorder(selected ? Color.white.opacity(0.95)
                                               : Color.primary.opacity(0.16),
                                      lineWidth: selected ? 1.6 : 0.6)
                }
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7.5, weight: .black))
                            .foregroundStyle(accentForeground)
                    }
                }
                .shadow(color: selected ? item.swatch.opacity(0.45) : .clear, radius: 5)
                // 每颗色点都是一粒散落在轨道上的光：自带柔光并错相位呼吸。
                .background {
                    Circle()
                        .fill(item.swatch.opacity(selected ? 0.55 : 0.30))
                        .frame(width: selected ? 38 : 30, height: selected ? 38 : 30)
                        .blur(radius: 9)
                        .scaleEffect(glowBreathing ? 1.12 : 0.88)
                        .opacity(glowBreathing ? 1 : 0.55)
                        .animation(.easeInOut(duration: 3.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.19),
                                   value: glowBreathing)
                }
                .scaleEffect(hovered ? 1.18 : 1)
                .scaleEffect(ringAppeared ? 1 : 0.25)
                .opacity(ringAppeared ? 1 : 0)
                .animation(.snappy(duration: 0.18), value: selected)
                .animation(.easeOut(duration: 0.14), value: hovered)
                .animation(.easeOut(duration: 0.4).delay(0.16 + Double(index) * 0.035),
                           value: ringAppeared)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredDot = item }
            else if hoveredDot == item { hoveredDot = nil }
        }
        .offset(ringOffset(radius: Self.dotRadius, fraction: fraction))
        .help(item.title)
        .accessibilityLabel("强调色 \(item.title)")
    }

    /// 悬停强调色时浮出的名字：一颗小色点 + 名称，贴着色点的角度浮在圆环外侧。
    private func accentHint(_ item: AppAccent) -> some View {
        let index = AppAccent.allCases.firstIndex(of: item) ?? 0
        let fraction = Double(index) / Double(AppAccent.allCases.count)
        return HStack(spacing: 4) {
            Circle()
                .fill(item == .system ? AnyShapeStyle(LumaBrand.gradient)
                                      : AnyShapeStyle(item.swatch))
                .frame(width: 7, height: 7)
            Text(item.title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color.primary.opacity(0.10), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .offset(ringOffset(radius: Self.dotRadius + 24, fraction: fraction))
        .allowsHitTesting(false)
    }

    /// 极坐标 → 偏移量：0 在正上方，顺时针排布。
    private func ringOffset(radius: CGFloat, fraction: Double) -> CGSize {
        let angle = fraction * 2 * .pi - .pi / 2
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }

    private func arcStyle(_ mode: AppAppearance) -> AnyShapeStyle {
        switch mode {
        case .system:
            return AnyShapeStyle(LumaBrand.gradient)
        case .light:
            // 浅色弧在浅色底上很容易糊成一片：往银灰压一档，深色下保持明亮的白。
            let colors: [Color] = isDark
                ? [Color.white.opacity(0.96), Color(white: 0.62)]
                : [Color(white: 0.94), Color(white: 0.52)]
            return AnyShapeStyle(LinearGradient(colors: colors,
                                                startPoint: .top,
                                                endPoint: .bottom))
        case .dark:
            return AnyShapeStyle(LinearGradient(colors: [Color(white: 0.46),
                                                         Color(white: 0.14)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing))
        }
    }

    private func arcShadow(_ mode: AppAppearance, selected: Bool) -> Color {
        guard selected else { return .clear }
        switch mode {
        case .system: return settings.accentColor.opacity(0.45)
        case .light: return isDark ? Color.white.opacity(0.60) : Color.black.opacity(0.18)
        case .dark: return Color.black.opacity(0.35)
        }
    }

    /// 年轮：三层虚线环，直径、虚线密度与转速各不相同，越往外转得越慢。
    private struct YearRing {
        let diameter: CGFloat
        let dash: [CGFloat]
        let darkOpacity: Double
        let lightOpacity: Double
        let duration: Double
    }

    private static let yearRings: [YearRing] = [
        YearRing(diameter: 200, dash: [2, 5], darkOpacity: 0.18, lightOpacity: 0.12, duration: 54),
        YearRing(diameter: 176, dash: [1.5, 5], darkOpacity: 0.14, lightOpacity: 0.10, duration: 78),
        YearRing(diameter: 154, dash: [1, 4], darkOpacity: 0.10, lightOpacity: 0.07, duration: 44)
    ]

    /// 由内到外：六边形核心（拾光）→ 光圈叶片 → 刻度环 → 光谱年轮 → 虚线年轮 → 外观弧 → 色点。
    /// 每一层都有自己的半径、透明度与转速，近处快、远处慢，形成纵深。
    private var logoCore: some View {
        ZStack {
            // 最外三圈：几乎不动的虚线年轮。
            ForEach(Array(Self.yearRings.enumerated()), id: \.offset) { index, ring in
                Circle()
                    .strokeBorder(Color.primary.opacity(isDark ? ring.darkOpacity : ring.lightOpacity),
                                  style: StrokeStyle(lineWidth: 0.8, dash: ring.dash))
                    .frame(width: ring.diameter)
                    .rotationEffect(.degrees(ringSpin ? (index.isMultiple(of: 2) ? 360 : -360) : 0))
                    .animation(.linear(duration: ring.duration).repeatForever(autoreverses: false),
                               value: ringSpin)
            }

            // 「拾光」隐喻：细小光粒在年轮之间缓缓向中心聚拢，再散开，像把光一粒粒拾回来。
            ZStack {
                ForEach(0..<7, id: \.self) { index in
                    Circle()
                        .fill(settings.accentColor)
                        .frame(width: index.isMultiple(of: 2) ? 2.6 : 1.8,
                               height: index.isMultiple(of: 2) ? 2.6 : 1.8)
                        .shadow(color: settings.accentColor.opacity(0.8), radius: 3)
                        .offset(y: -(motesGathered ? 64 : 96))
                        .rotationEffect(.degrees(Double(index) / 7 * 360 + 14))
                        .opacity(motesGathered ? 0.15 : 0.75)
                        .animation(.easeInOut(duration: 3.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.24),
                                   value: motesGathered)
                }
            }
            .allowsHitTesting(false)

            // 光谱年轮：整枚徽标的视觉焦点，慢慢自转。
            Circle()
                .trim(from: 0.02, to: 0.88)
                .stroke(AngularGradient(gradient: Gradient(colors: spectrumColors),
                                        center: .center),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .frame(width: 140)
                .rotationEffect(.degrees(ringSpin ? 360 : 0))
                .animation(.linear(duration: 12).repeatForever(autoreverses: false),
                           value: ringSpin)
                .shadow(color: settings.accentColor.opacity(0.55), radius: 6)

            // 刻度环：24 根细刻度反向慢转，像镜头的对焦环。
            ZStack {
                ForEach(0..<24, id: \.self) { index in
                    Capsule()
                        .fill(Color.primary.opacity(isDark ? 0.22 : 0.16))
                        .frame(width: 1, height: 4)
                        .offset(y: -63)
                        .rotationEffect(.degrees(Double(index) / 24 * 360))
                }
            }
            .rotationEffect(.degrees(ringSpin ? -360 : 0))
            .animation(.linear(duration: 64).repeatForever(autoreverses: false), value: ringSpin)

            // 光圈叶片：白色圆盘 + 五道叶片缝，慢慢自转（参考镜头光圈）。
            ZStack {
                Circle()
                    .fill(irisFill)
                    .frame(width: 112, height: 112)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(isDark ? 0.16 : 0.08),
                                          lineWidth: 0.8)
                    }
                    .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.16), radius: 12, y: 5)

                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(Color.black.opacity(isDark ? 0.10 : 0.13))
                        .frame(width: 0.8, height: 20)
                        .offset(y: -46)
                        .rotationEffect(.degrees(Double(index) / 5 * 360))
                }
            }
            .rotationEffect(.degrees(ringSpin ? 360 : 0))
            .animation(.linear(duration: 40).repeatForever(autoreverses: false), value: ringSpin)

            // 中央六边形：不随圆环转动，稳稳托住「拾光」。
            HexagonShape()
                .fill(hexagonFill)
                .frame(width: 100, height: 88)
                .overlay {
                    HexagonShape()
                        .stroke(Color.primary.opacity(isDark ? 0.20 : 0.10), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(isDark ? 0.50 : 0.18), radius: 10, y: 3)

            VStack(spacing: 4) {
                Text("拾光")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(hexagonTextColor)
                    .shadow(color: isDark ? Color.black.opacity(0.45)
                                          : Color.white.opacity(0.85),
                            radius: 4, y: 1)

                Text("LUMA")
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(3.5)
                    .foregroundStyle(hexagonTextColor.opacity(0.55))
            }
        }
        .frame(width: Self.coreDiameter, height: Self.coreDiameter)
        .accessibilityLabel("拾光年轮")
    }

    /// 光圈盘面：始终是亮盘，深色下像一枚发光的镜头，浅色下融进暖白背景。
    private var irisFill: AnyShapeStyle {
        if isDark {
            return AnyShapeStyle(RadialGradient(colors: [Color(white: 0.94),
                                                         settings.accentColor.opacity(0.22),
                                                         Color(white: 0.56)],
                                                center: .topLeading,
                                                startRadius: 6,
                                                endRadius: 84))
        }
        return AnyShapeStyle(RadialGradient(colors: [Color.white,
                                                     settings.accentColor.opacity(0.10),
                                                     Color(white: 0.90)],
                                            center: .topLeading,
                                            startRadius: 6,
                                            endRadius: 84))
    }

    /// 六边形核心跟着主题走：深色是强调色浸染的深空玻璃，浅色是带一点强调色的暖白玻璃。
    private var hexagonFill: AnyShapeStyle {
        if isDark {
            return AnyShapeStyle(LinearGradient(colors: [settings.accentColor.opacity(0.55),
                                                         Color(red: 0.04, green: 0.04, blue: 0.07)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(LinearGradient(colors: [Color.white,
                                                     settings.accentColor.opacity(0.20),
                                                     Color(white: 0.94)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing))
    }

    /// 六边形上的字：深底白字、浅底深字，任何主题下都有明显对比。
    private var hexagonTextColor: Color {
        isDark ? .white : Color(red: 0.12, green: 0.09, blue: 0.15)
    }

    /// 环形扇区：只用于命中测试，把一整段圆弧连同它外侧的标签、空隙都算作可点区域。
    private struct RingSectorShape: Shape {
        let startFraction: Double
        let endFraction: Double
        let innerRatio: CGFloat
        let outerRatio: CGFloat

        func path(in rect: CGRect) -> Path {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            let inner = radius * innerRatio
            let outer = radius * outerRatio
            let start = Angle.degrees(startFraction * 360 - 90)
            let end = Angle.degrees(endFraction * 360 - 90)
            var path = Path()
            path.addArc(center: center, radius: outer,
                        startAngle: start, endAngle: end, clockwise: false)
            path.addArc(center: center, radius: inner,
                        startAngle: end, endAngle: start, clockwise: true)
            path.closeSubpath()
            return path
        }
    }

    /// 六边形核心：平顶六边形，宽窄兼顾四个字的排版。
    private struct HexagonShape: Shape {
        func path(in rect: CGRect) -> Path {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            var path = Path()
            for index in 0..<6 {
                let angle = Double(index) / 6 * 2 * .pi
                let point = CGPoint(x: center.x + cos(angle) * radius,
                                    y: center.y + sin(angle) * radius)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()
            return path
        }
    }

    private var spectrumColors: [Color] {
        [settings.accentColor, LumaBrand.violet, LumaBrand.cyan,
         LumaBrand.coral, settings.accentColor]
    }

    /// 第二步：只做一件事——这个图库要拾起哪些能力。
    // MARK: - 缓存空间

    /// 建库时顺手定的缓存预算：三个档位写回真实的视频 / 海报缓存上限。
    private enum CacheSpaceProfile: String, CaseIterable, Identifiable {
        case compact, balanced, roomy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .compact: return "省空间"
            case .balanced: return "均衡"
            case .roomy: return "大空间"
            }
        }

        var subtitle: String {
            switch self {
            case .compact: return "只留最近用到的"
            case .balanced: return "日常够用"
            case .roomy: return "多留几部"
            }
        }

        var level: Int {
            switch self {
            case .compact: return 1
            case .balanced: return 2
            case .roomy: return 3
            }
        }

        var videoLimitGB: Int {
            switch self {
            case .compact: return 12
            case .balanced: return 50
            case .roomy: return 100
            }
        }

        var posterLimitGB: Int {
            switch self {
            case .compact: return 4
            case .balanced: return 10
            case .roomy: return 20
            }
        }
    }

    private var cacheSpaceProfile: CacheSpaceProfile {
        let limit = settings.videoCacheLimitGB
        if limit <= 20 { return .compact }
        if limit >= 90 { return .roomy }
        return .balanced
    }

    /// 迁入旧照片与缓存档位合成一行：左边勾选迁移，右边点档位。
    private var storageRow: some View {
        let profile = cacheSpaceProfile
        let canMigrate = canMigrateLocal && !creatingAdditionalLibrary
        return HStack(spacing: 12) {
            if canMigrate {
                Toggle(isOn: $migrateLocalPhotos) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(hasLocalPhotos
                             ? "迁入 \(store.photos.count.formatted()) 张照片"
                             : "迁入旧版本地照片")
                            .font(.system(size: 11.5))
                    }
                }
                .toggleStyle(.checkbox)
                .fixedSize()

                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: 1, height: 16)
            } else {
                Image(systemName: "internaldrive")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ForEach(CacheSpaceProfile.allCases) { option in
                Button {
                    settings.videoCacheLimitGB = option.videoLimitGB
                    settings.posterCacheLimitGB = option.posterLimitGB
                } label: {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(profile == option ? accentForeground : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 25)
                        .background {
                            Capsule(style: .continuous)
                                .fill(profile == option
                                      ? AnyShapeStyle(Color.accentColor)
                                      : AnyShapeStyle(Color.primary.opacity(0.06)))
                        }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index < profile.level
                              ? AnyShapeStyle(Color.accentColor.opacity(0.85))
                              : AnyShapeStyle(Color.primary.opacity(0.12)))
                        .frame(width: 3, height: 5 + CGFloat(index) * 3)
                }
            }

            Text(profile.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.05 : 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
        .animation(.snappy(duration: 0.18), value: profile)
    }

    private var moduleStep: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.bottom, 14)

            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LumaBrand.gradient)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: LumaBrand.violet.opacity(0.35), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 3.5) {
                    Text("这个图库想拾起哪些能力？")
                        .font(.system(size: 21, weight: .bold))
                        .tracking(-0.01)
                    Text("把需要的模块拾进来；默认全部拾起，之后随时能在设置里放下或拾回。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            ModuleSwitchGrid(density: .setup, showsBulkActions: true)
                .padding(.top, 20)

            storageRow
                .padding(.top, 20)

            HStack(spacing: 10) {
                if creatingAdditionalLibrary {
                    SetupButton(title: "取消", systemImage: "xmark", style: .ghost) {
                        cancelCreation()
                    }
                    .frame(width: 140)
                    .disabled(isCreating)
                } else {
                    SetupButton(title: "返回", systemImage: "chevron.left", style: .ghost) {
                        showsModuleStep = false
                    }
                    .frame(width: 140)
                }

                SetupButton(title: "选择位置并创建", systemImage: "folder.badge.plus", style: .primary) {
                    createLibrary()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating)
            }
            .padding(.top, 20)

            if creatingAdditionalLibrary {
                Text(isCreating
                     ? "正在创建并切换到新图库…"
                     : "创建后会立刻切换到新图库，并清空上一个图库留在内存里的内容。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
        }
    }

    /// 先把位置选好再创建；建好后立刻切到新图库。
    private func createLibrary() {
        guard !isCreating else { return }
        isCreating = true
        // 已有图库时新建的必须是空库：不能把当前库的照片再复制一份过去。
        let migrating = !creatingAdditionalLibrary && canMigrateLocal && migrateLocalPhotos
        Task {
            let created = await store.presentNewLibraryPanel(migratingLocalData: migrating)
            isCreating = false
            guard created else { return }
            // sheet 形态下建库成功已经切到新图库，关掉向导回到主界面。
            if creatingAdditionalLibrary { dismiss() }
        }
    }

    /// sheet 里取消：把能力开关还原成打开向导前的样子，避免「只是看看」也改了全局设置。
    private func cancelCreation() {
        for (key, value) in moduleSnapshot {
            UserDefaults.standard.set(value, forKey: key)
        }
        dismiss()
    }

    /// 建库的两步进度：一枚走完的圆点 + 一枚当前圆点，中间连一条细线。
    private var stepIndicator: some View {
        HStack(spacing: 7) {
            stepDot(index: 1, active: true, done: true)
            Capsule()
                .fill(LumaBrand.violet.opacity(0.45))
                .frame(width: 26, height: 1.5)
            stepDot(index: 2, active: true, done: false)
            Spacer(minLength: 0)
            Text("第 2 步 / 共 2 步")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private func stepDot(index: Int, active: Bool, done: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? LumaBrand.violet.opacity(0.85) : Color.primary.opacity(active ? 0.14 : 0.08))
                .frame(width: 15, height: 15)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .black))
                    .foregroundStyle(.white)
            } else {
                Text("\(index)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        // 两个入口并成一行，文案各四个字，左右等宽。
        HStack(spacing: 10) {
            SetupButton(title: "新建图库", systemImage: "plus", style: .primary) {
                showsModuleStep = true
            }
            .keyboardShortcut(.defaultAction)

            SetupButton(title: "打开图库", systemImage: "folder", style: .ghost) {
                store.presentLibraryContainerPanel()
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 最近打开的图库

    /// 默认图库断开 / 外置盘没插时，启动会落到这里：直接列出仍然存在的图库，
    /// 不用再去文件面板里翻路径。只显示前三个，其余仍可通过「打开已有图库…」选择。
    private var recentLibraries: [SystemLibraryRef] {
        Array(store.knownLibraries
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(3))
    }

    private var recentLibraryList: some View {
        VStack(spacing: 0) {
            ForEach(Array(recentLibraries.enumerated()), id: \.element.id) { index, ref in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.leading, 42)
                }
                Button {
                    store.activateLibrary(URL(fileURLWithPath: ref.path))
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(settings.accentColor)
                            .frame(width: 24, height: 24)
                            .background(settings.accentColor.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ref.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(ref.path)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开 \(ref.path)")
                .contextMenu {
                    Button("断开连接…", role: .destructive) {
                        store.confirmDisconnectLibrary(path: ref.path, name: ref.name)
                    }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.05 : 0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text("新建拾光图库，或接入系统「照片」图库——每一段时光，都留在本机。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            HStack(spacing: 12) {
                Text("版本 \(appVersion) · 无需账号 · 本地运行")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary.opacity(0.8))
                Button("退出拾光") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(readableAccent)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.1"
    }
}

/// 官网同款按钮：白底胶囊主按钮 + 玻璃描边次按钮。
private struct SetupButton: View {
    enum Style {
        case primary
        case ghost
    }

    @Environment(\.colorScheme) private var scheme
    let title: String
    let systemImage: String
    var style: Style = .ghost
    let action: () -> Void

    @State private var hovered = false

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(foreground)
            .background { background }
            .scaleEffect(hovered ? 1.012 : 1)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { hovered = hovering }
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: return isDark ? Color.black.opacity(0.88) : .white
        case .ghost: return .primary
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            Capsule(style: .continuous)
                .fill(isDark ? Color.white : Color.black.opacity(0.88))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(isDark ? 0.55 : 0.10), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(isDark ? 0.36 : 0.18), radius: 14, y: 7)
                .opacity(hovered ? 1 : 0.96)
        case .ghost:
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(hovered ? (isDark ? 0.09 : 0.06) : (isDark ? 0.05 : 0.035)))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(isDark ? 0.12 : 0.10), lineWidth: 0.7)
                }
        }
    }
}
