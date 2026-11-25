import SwiftUI
import AppKit

/// 网络电视专用视觉：以「直播信号」为核心概念。
/// 所有颜色都是动态色，跟随系统浅色 / 深色外观；
/// 只有播放 OSD 的深色叠加是刻意的例外（底下是视频画面）。
enum TVBrand {
    // MARK: - 语义色

    /// 直播信号红。
    static let signal = dynamic(
        light: rgb(0.851, 0.176, 0.227),   // #D92D3A
        dark: rgb(1.000, 0.300, 0.340)     // #FF4D57
    )
    /// 电波青：选中、悬停、可回看。
    static let wave = dynamic(
        light: rgb(0.055, 0.486, 0.600),   // #0E7C99
        dark: rgb(0.300, 0.840, 0.980)     // #4DD6FA
    )
    /// 4K / HDR 的少量金色点缀。
    static let gold = dynamic(
        light: rgb(0.663, 0.463, 0.122),   // #A9761F
        dark: rgb(0.980, 0.790, 0.400)     // #FACC66
    )
    /// 信号正常。
    static let success = dynamic(
        light: rgb(0.141, 0.541, 0.239),   // #248A3D
        dark: rgb(0.200, 0.780, 0.350)     // #34C759
    )
    /// 需要留意。
    static let warning = dynamic(
        light: rgb(0.706, 0.325, 0.035),   // #B45309
        dark: rgb(1.000, 0.620, 0.040)     // #FF9F0A
    )
    /// 失败。
    static let danger = dynamic(
        light: rgb(0.706, 0.137, 0.094),   // #B42318
        dark: rgb(1.000, 0.270, 0.230)     // #FF453A
    )

    // MARK: - 背景 / 面板

    static let pageTop = dynamic(
        light: rgb(0.969, 0.973, 0.984),   // #F7F8FB
        dark: rgb(0.043, 0.052, 0.086)     // #0B0D16
    )
    static let pageBottom = dynamic(
        light: .white,
        dark: rgb(0.073, 0.094, 0.152)     // #131826
    )
    static let cardTop = dynamic(
        light: .white,
        dark: rgb(0.098, 0.118, 0.188)     // #191E30
    )
    static let cardBottom = dynamic(
        light: rgb(0.949, 0.961, 0.980),   // #F2F5FA
        dark: rgb(0.055, 0.066, 0.112)     // #0E111C
    )

    /// 控件底色：深色白 5.5%，浅色黑 5.5%。
    static let panel = Color.primary.opacity(0.055)
    /// 频道卡常态 / 悬停底色。
    static let surface = Color.primary.opacity(0.045)
    static let surfaceHover = Color.primary.opacity(0.075)
    /// 分割线 / 细描边。
    static let hairline = Color.primary.opacity(0.09)
    static let stroke = Color.primary.opacity(0.08)
    static let shadow = dynamic(
        light: NSColor.black.withAlphaComponent(0.12),
        dark: NSColor.black.withAlphaComponent(0.25)
    )

    /// 台标底板：白色台标在浅色背景上仍然可见。
    static let logoPlate = dynamic(
        light: rgb(0.945, 0.953, 0.973),   // #F1F3F8
        dark: NSColor.white.withAlphaComponent(0.06)
    )
    /// 白色 / 浅色台标专用的深色底板：浅色界面下一眼能看清。
    static let logoPlateDark = dynamic(
        light: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.94),
        dark: NSColor.white.withAlphaComponent(0.06)
    )
    static let logoShadow = dynamic(
        light: NSColor.black.withAlphaComponent(0.10),
        dark: NSColor.black.withAlphaComponent(0.45)
    )

    /// 铺在强调色上的文字。
    static let onWave = dynamic(light: .white, dark: NSColor.black.withAlphaComponent(0.82))
    static let onGold = dynamic(light: .white, dark: NSColor.black.withAlphaComponent(0.82))

    /// LIVE 徽标底色。
    static let liveBadgeFill = dynamic(
        light: NSColor.white.withAlphaComponent(0.92),
        dark: NSColor.black.withAlphaComponent(0.42)
    )
    /// 盖在实时画面上的信息条：始终保持深色。
    static let previewScrim = Color.black.opacity(0.45)

    /// 环境光强度：浅色下更克制。
    static let waveGlow = dynamic(
        light: NSColor(srgbRed: 0.055, green: 0.486, blue: 0.600, alpha: 0.06),
        dark: NSColor(srgbRed: 0.300, green: 0.840, blue: 0.980, alpha: 0.12)
    )
    static let signalGlow = dynamic(
        light: NSColor(srgbRed: 0.851, green: 0.176, blue: 0.227, alpha: 0.035),
        dark: NSColor(srgbRed: 1.000, green: 0.300, blue: 0.340, alpha: 0.10)
    )

    // MARK: - 组合

    /// 画质徽标的前景 / 背景：深浅两套，语义不变。
    static func qualityStyle(_ label: String) -> (fg: Color, bg: Color) {
        switch label {
        case "2160p", "1440p":
            return (onGold, gold)
        case "1080p":
            return (onWave, wave)
        default:
            return (Color.primary.opacity(0.85), Color.primary.opacity(0.12))
        }
    }

    @ViewBuilder
    static var background: some View {
        ZStack {
            LinearGradient(colors: [pageTop, pageBottom],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [waveGlow, .clear],
                           center: .topTrailing, startRadius: 20, endRadius: 720)
            RadialGradient(colors: [signalGlow, .clear],
                           center: .bottomLeading, startRadius: 10, endRadius: 620)
        }
        .ignoresSafeArea()
    }

    // MARK: - 动态色

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// 顶部直播标识：红色呼吸点 + LIVE。
/// 开启「减少动态效果」时只保留静态圆点。
struct TVLiveBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = true
    /// 工具栏等由 AppKit 托管的宿主里关掉呼吸动画：
    /// 永久动画会让整条 toolbar item 持续重排，表现为胶囊里的文字一直漂移。
    var animated = true

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                if animated {
                    Circle()
                        .fill(TVBrand.signal.opacity(0.35))
                        .frame(width: 14, height: 14)
                        .scaleEffect(pulse ? 1.25 : 0.7)
                        .opacity(reduceMotion ? 0 : (pulse ? 0 : 1))
                }
                Circle()
                    .fill(TVBrand.signal)
                    .frame(width: 7, height: 7)
            }
            Text("直播")
                .font(.system(size: compact ? 9.5 : 10.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(TVBrand.signal)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(TVBrand.liveBadgeFill, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(TVBrand.signal.opacity(0.35), lineWidth: 0.6))
        .onAppear {
            guard animated, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .onChange(of: reduceMotion) { _, value in
            if value { pulse = false }
        }
    }
}

/// 台标：走 `TVLogoCache`（内存 + 磁盘 + 网络），失败时给出统一的占位图形。
/// 底下加一层台标底板，保证白色台标在浅色模式下也可见。
struct TVLogoImage: View {
    let urlString: String?
    var size: CGSize = CGSize(width: 120, height: 68)
    var cornerRadius: CGFloat = 8

    @State private var image: NSImage?
    /// 浅色台标（白字 / 透明底）自动换成深色底板，浅色模式下不再「消失」。
    @State private var usesDarkPlate = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(usesDarkPlate ? TVBrand.logoPlateDark : TVBrand.logoPlate)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(min(size.width, size.height) * 0.06)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: min(size.width, size.height) * 0.32, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(TVBrand.hairline, lineWidth: 0.5)
        }
        .task(id: urlString) {
            guard let urlString, !urlString.isEmpty else { return }
            if let cached = await TVLogoCache.shared.image(for: urlString) {
                image = cached
                usesDarkPlate = !Self.isDarkArtwork(cached)
            }
        }
    }

    /// 采样台标亮度，判断它是否适合配浅色底板。
    /// 51zmt 这类央视台标是白字 + 透明底，平均亮度并不高，但白字在浅色底板上会整片消失，
    /// 所以只要不是明显的深色图形，一律换深色底板；深色台标（深蓝 / 黑字）才用浅色底板。
    private static func isDarkArtwork(_ image: NSImage) -> Bool {
        // 采样格比台标字高小得多：16 像素会把细白字直接抹掉，看不到白色占比。
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side,
                                         pixelsHigh: side,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var weightedLuminance = 0.0
        var weight = 0.0
        for x in 0..<side {
            for y in 0..<side {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let alpha = color.alphaComponent
                guard alpha > 0.35 else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                weightedLuminance += luminance * alpha
                weight += alpha
            }
        }
        // 全透明（图片没内容）时保持浅色底板，不要压一块黑方块。
        guard weight > 0 else { return true }
        // 平均亮度足够低才认作深色图形；中间色调和浅色台标都走深色底板。
        return weightedLuminance / weight < 0.42
    }
}
