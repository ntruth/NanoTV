import SwiftUI
import AppKit

/// 关于页的品牌首屏：一条「光之河」从历史流向未来。
///
/// 左侧暖色代表过去，中央是此刻的拾光，右侧冷色代表未来；
/// 光点从河面升起、被拾成「拾光」二字，再散回时间里。
/// 舞台固定为深空夜色：光只有在暗处才看得见，浅色模式下同样是星野。
struct AboutBrandHeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                AboutStageWash(t: t)
                LightRiverCanvas(t: t)
                    .opacity(appeared ? 1 : 0)
                LightMoteCanvas(t: t)
                    .opacity(appeared ? 1 : 0)
                AboutRiverLabels()
                    .opacity(appeared ? 0.92 : 0)
                heroContent(t: t)
            }
        }
        .frame(height: 334)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            guard !appeared else { return }
            withAnimation(.easeOut(duration: 0.9)) { appeared = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("拾光：拾，是拾起；光，是光影；拾光，也是时光。每一张照片都是一束被留下的光。")
    }

    // MARK: - 文案

    private func heroContent(t: TimeInterval) -> some View {
        VStack(spacing: 10) {
            Text("SHIGUANG")
                .font(.system(size: 9, weight: .semibold))
                .tracking(5)
                .foregroundStyle(Color.white.opacity(0.42))
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
                .animation(.easeOut(duration: 0.7).delay(0.08), value: appeared)

            wordmark(t: t)

            copyBlock
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func wordmark(t: TimeInterval) -> some View {
        let shimmer = (t * 0.16).truncatingRemainder(dividingBy: 1)

        return HStack(spacing: 16) {
            ForEach(Array("拾光".enumerated()), id: \.offset) { item in
                Text(String(item.element))
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(LumaBrand.gradient)
                    .shadow(color: LumaBrand.violet.opacity(0.55), radius: 22, y: 6)
                    .opacity(appeared ? 1 : 0)
                    .blur(radius: appeared ? 0 : 12)
                    .offset(y: appeared ? 0 : 20)
                    .animation(.spring(response: 1.0, dampingFraction: 0.76)
                        .delay(0.20 + Double(item.offset) * 0.16),
                               value: appeared)
            }
        }
        .overlay { shimmerLayer(progress: shimmer) }
    }

    /// 掠过字面的一束高光，让「拾光」像被光扫过。
    private func shimmerLayer(progress: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            LinearGradient(
                colors: [Color.clear,
                         Color.white.opacity(0.55),
                         Color.clear],
                startPoint: .leading,
                endPoint: .trailing)
                .frame(width: width * 0.62)
                .offset(x: -width * 0.75 + CGFloat(progress) * width * 1.75)
                .blendMode(.plusLighter)
        }
        .mask {
            HStack(spacing: 16) {
                Text("拾").font(.system(size: 56, weight: .bold))
                Text("光").font(.system(size: 56, weight: .bold))
            }
        }
        .opacity(appeared ? 1 : 0)
        .allowsHitTesting(false)
    }

    private var copyBlock: some View {
        VStack(spacing: 7) {
            Text("拾，是拾起；光，是光影；拾光，也是时光。")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.94))

            Text("我们相信，每一张照片都是一束被留下的光。\n拾光，就是替你把散落的光，一片一片捡回来。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.64))
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Text("从历史拾起光，向未来写下光")
                .font(.system(size: 9.5, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Color.white.opacity(0.40))
                .padding(.top, 2)
        }
        .padding(.top, 2)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .blur(radius: appeared ? 0 : 6)
        .animation(.easeOut(duration: 0.8).delay(0.74), value: appeared)
    }
}

// MARK: - 舞台底光

/// 深空底：黑色夜空上叠品牌色的星云与极光，不写死 RGB。
/// 这样浅色模式也能保留完整的星光密度，而不是被白底冲淡。
private struct AboutStageWash: View {
    let t: TimeInterval

    var body: some View {
        ZStack {
            Color.black

            // 斜向银河：一层很淡的紫青雾气，制造纵深
            LinearGradient(
                colors: [Color.clear,
                         LumaBrand.violet.opacity(0.16),
                         LumaBrand.cyan.opacity(0.12),
                         Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
                .scaleEffect(x: 1.8, y: 1.2)
                .rotationEffect(.degrees(-16))
                .blur(radius: 46)

            // 中央暖光：托住标题的那束光
            RadialGradient(
                colors: [LumaBrand.amber.opacity(0.18), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.34),
                startRadius: 2,
                endRadius: 220)

            // 左下暖（历史）
            Circle()
                .fill(LumaBrand.coral.opacity(0.20))
                .frame(width: 280, height: 280)
                .blur(radius: 92)
                .offset(x: -150 + CGFloat(sin(t * 0.10)) * 12,
                        y: 74 + CGFloat(cos(t * 0.12)) * 6)

            // 右上冷（未来）
            Circle()
                .fill(LumaBrand.cyan.opacity(0.18))
                .frame(width: 320, height: 320)
                .blur(radius: 104)
                .offset(x: 168 + CGFloat(cos(t * 0.08)) * 14,
                        y: -64 + CGFloat(sin(t * 0.09)) * 8)

            LinearGradient(colors: [Color.clear,
                                    Color.black.opacity(0.34)],
                           startPoint: .center,
                           endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 光之河

private enum AboutRiver {
    /// 三个时间锚点：历史 → 此刻 → 未来。
    static let markers: [(x: CGFloat, title: String, color: Color)] = [
        (0.16, "历史", LumaBrand.coral),
        (0.50, "此刻", LumaBrand.violet),
        (0.84, "未来", LumaBrand.cyan)
    ]

    /// 河面曲线：固定公式，Canvas 与文字标签共用，保证光点落在线上。
    static func point(nx: CGFloat, size: CGSize, t: TimeInterval) -> CGPoint {
        let baseY = size.height * 0.79
        let envelope = 0.5 + 0.5 * sin(Double(nx) * .pi)
        let wave = sin(Double(nx) * 9.0 + t * 0.6) * 7.0 * envelope
        return CGPoint(x: nx * size.width, y: baseY + CGFloat(wave))
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        guard size.width > 1, size.height > 1 else { return }

        var river = Path()
        let steps = 160
        for index in 0...steps {
            let nx = CGFloat(index) / CGFloat(steps)
            let point = point(nx: nx, size: size, t: t)
            if index == 0 {
                river.move(to: point)
            } else {
                river.addLine(to: point)
            }
        }

        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                LumaBrand.amber.opacity(0.0),
                LumaBrand.coral.opacity(0.65),
                LumaBrand.amber.opacity(0.85),
                LumaBrand.violet.opacity(0.95),
                LumaBrand.cyan.opacity(0.85),
                LumaBrand.cyan.opacity(0.0)
            ]),
            startPoint: CGPoint(x: 0, y: size.height * 0.79),
            endPoint: CGPoint(x: size.width, y: size.height * 0.79))

        // 外辉光
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 10))
            layer.stroke(river, with: shading, lineWidth: 6)
        }
        // 芯线
        context.stroke(river, with: shading, lineWidth: 1.2)

        // 时间锚点
        for marker in markers {
            let point = point(nx: marker.x, size: size, t: t)
            let rect = CGRect(x: point.x - 2.2, y: point.y - 2.2, width: 4.4, height: 4.4)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 6))
                layer.fill(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                           with: .color(marker.color.opacity(0.45)))
            }
            context.fill(Path(ellipseIn: rect), with: .color(marker.color.opacity(0.95)))
        }

        // 沿河移动的一束光：从历史出发，驶向未来
        let travel = CGFloat((t * 0.085).truncatingRemainder(dividingBy: 1))
        let head = point(nx: travel, size: size, t: t)

        for index in 0..<18 {
            let back = travel - CGFloat(index) * 0.012
            guard back > 0 else { break }
            let trail = point(nx: back, size: size, t: t)
            let alpha = (1.0 - Double(index) / 18.0) * 0.45
            let radius = max(0.6, 2.6 - CGFloat(index) * 0.1)
            let rect = CGRect(x: trail.x - radius, y: trail.y - radius,
                              width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(alpha)))
        }

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 14))
            layer.fill(
                Path(ellipseIn: CGRect(x: head.x - 16, y: head.y - 16, width: 32, height: 32)),
                with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(0.95),
                                      LumaBrand.amber.opacity(0.45),
                                      Color.clear]),
                    center: head, startRadius: 0, endRadius: 16))
        }
        context.fill(
            Path(ellipseIn: CGRect(x: head.x - 2.6, y: head.y - 2.6, width: 5.2, height: 5.2)),
            with: .color(.white))
    }
}

private struct LightRiverCanvas: View {
    let t: TimeInterval

    var body: some View {
        Canvas { context, size in
            AboutRiver.draw(in: &context, size: size, t: t)
        }
        .allowsHitTesting(false)
    }
}

private struct AboutRiverLabels: View {
    var body: some View {
        GeometryReader { proxy in
            let baseY = proxy.size.height * 0.79
            ForEach(AboutRiver.markers.indices, id: \.self) { index in
                let marker = AboutRiver.markers[index]
                Text(marker.title)
                    .font(.system(size: 9, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(marker.color.opacity(0.92))
                    .position(x: proxy.size.width * marker.x, y: baseY + 24)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 星空

private enum AboutMotes {
    struct Mote {
        let x: CGFloat
        let phase: CGFloat
        let speed: CGFloat
        let radius: CGFloat
        let colorIndex: Int
        let glow: Bool
    }

    /// 固定位置的繁星：只闪烁、不上浮，负责「浩瀚」。
    struct Star {
        let x: CGFloat
        let y: CGFloat
        let phase: CGFloat
        let radius: CGFloat
        let colorIndex: Int
    }

    static let colors: [Color] = [
        LumaBrand.amber, LumaBrand.coral, LumaBrand.violet, LumaBrand.cyan, LumaBrand.mint
    ]

    private static func makeGenerator() -> () -> CGFloat {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        return {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = (seed >> 33) & 0x00FF_FFFF
            return CGFloat(value) / CGFloat(0x00FF_FFFF)
        }
    }

    /// 升腾的光尘：从河面拾起的那部分光。
    static let motes: [Mote] = {
        let next = makeGenerator()
        return (0..<26).map { index in
            Mote(x: 0.03 + next() * 0.94,
                 phase: next(),
                 speed: 0.010 + next() * 0.022,
                 radius: 0.8 + next() * 1.6,
                 colorIndex: index % colors.count,
                 glow: next() > 0.45)
        }
    }()

    static let stars: [Star] = {
        let next = makeGenerator()
        return (0..<64).map { index in
            Star(x: 0.02 + next() * 0.96,
                 y: 0.03 + next() * 0.74,
                 phase: next(),
                 radius: 0.45 + next() * next() * 1.5,
                 colorIndex: index % colors.count)
        }
    }()
}

private struct LightMoteCanvas: View {
    let t: TimeInterval

    var body: some View {
        Canvas { context, size in
            guard size.width > 1 else { return }

            // 背景繁星
            for star in AboutMotes.stars {
                let twinkle = 0.30 + 0.70 * abs(sin(t * 0.8 + Double(star.phase) * 6.28))
                let alpha = twinkle * (star.radius > 1.4 ? 0.95 : 0.7)
                let color = AboutMotes.colors[star.colorIndex]
                let point = CGPoint(x: size.width * star.x, y: size.height * star.y)
                let rect = CGRect(x: point.x - star.radius, y: point.y - star.radius,
                                  width: star.radius * 2, height: star.radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                if star.radius > 1.4 {
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 4))
                        layer.fill(Path(ellipseIn: rect.insetBy(dx: -1.6, dy: -1.6)),
                                   with: .color(color.opacity(alpha * 0.6)))
                    }
                }
            }

            // 升腾的光尘
            for mote in AboutMotes.motes {
                let progress = (mote.phase + CGFloat(t) * mote.speed)
                    .truncatingRemainder(dividingBy: 1)
                let y = size.height * (1.02 - progress * 1.06)
                let x = size.width * mote.x
                    + CGFloat(sin(t * 0.5 + Double(mote.phase) * 6.28)) * 8
                let twinkle = 0.35 + 0.65 * abs(sin(t * 0.9 + Double(mote.phase) * 6.28))
                let alpha = twinkle * 0.9
                let color = AboutMotes.colors[mote.colorIndex]
                let rect = CGRect(x: x - mote.radius, y: y - mote.radius,
                                  width: mote.radius * 2, height: mote.radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                if mote.glow {
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 5))
                        layer.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)),
                                   with: .color(color.opacity(alpha * 0.5)))
                    }
                }
            }
        }
        .mask {
            LinearGradient(
                stops: [.init(color: Color.clear, location: 0),
                        .init(color: Color.white, location: 0.12),
                        .init(color: Color.white, location: 0.80),
                        .init(color: Color.clear, location: 0.97)],
                startPoint: .top,
                endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}
