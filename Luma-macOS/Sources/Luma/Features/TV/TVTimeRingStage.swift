import SwiftUI

/// 表带配色：时间轴的节目块与时间环共用一套色。
/// 正在播换成信号红，已播且没有回看时压暗。
enum TVRingPalette {
    static let colors: [Color] = [
        Color(red: 0.55, green: 0.30, blue: 0.95),
        Color(red: 0.36, green: 0.52, blue: 0.98),
        Color(red: 0.18, green: 0.72, blue: 0.70),
        Color(red: 0.96, green: 0.60, blue: 0.18),
        Color(red: 0.90, green: 0.36, blue: 0.52),
        Color(red: 0.62, green: 0.44, blue: 0.94)
    ]
}

/// 时间环表盘：把一整天卷成一个表盘，指针扫过哪一段就选中那一档节目。
///
/// 指针 / 悬停状态全部收在这个视图内部。拖动时只有表盘自身重绘，
/// 外层的频道栏、日期条和节目列表都不会跟着重算——这是它跟手的前提。
struct TVTimeRingStage: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel
    @Environment(\.colorScheme) private var scheme

    /// 浅色主题：表盘变成暖白瓷面，文字改用主色，不再是一块黑表。
    private var isLight: Bool { scheme == .light }

    /// 当前日期与相对今天的偏移（0 = 今天）。
    let day: Date
    let dayOffset: Int
    let channel: TVChannel?
    let programs: [TVEPGProgram]
    /// 「今天 · 11/24」这类日期标签，由外层统一格式化，避免每次都建 DateFormatter。
    let dayLabel: String
    /// 频道 / 日期 / 「回到现在」变化时复位指针。
    let resetToken: String

    @State private var pointer: Date?
    @State private var hoverDate: Date?
    @State private var lastHoverTick = Date.distantPast
    @State private var lastDragTick = Date.distantPast

    var body: some View {
        ZStack {
            backdrop
            GeometryReader { proxy in
                let side = max(240, min(proxy.size.width, proxy.size.height) - 16)
                ZStack {
                    plate(side: side)
                    band(side: side)
                    hourMarks(side: side)
                    interactionLayer(side: side)
                    pointerView(side: side)
                    centerBlocker(side: side)
                    center(side: side)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: resetToken) { _, _ in
            pointer = nil
            hoverDate = nil
        }
    }

    // MARK: - 指针时间

    /// 指针默认位置：今天就是此刻，其他日子落在 20:00。
    private var defaultFocusDate: Date {
        if dayOffset == 0 { return Date() }
        return day.addingTimeInterval(TimeInterval(20 * 3600))
    }

    private var focusDate: Date {
        hoverDate ?? pointer ?? defaultFocusDate
    }

    private var focusProgram: TVEPGProgram? {
        programs.first { $0.start <= focusDate && $0.end > focusDate }
    }

    private func dayFraction(_ date: Date) -> Double {
        let start = Calendar.current.startOfDay(for: day)
        return min(1, max(0, date.timeIntervalSince(start) / 86_400))
    }

    private func date(atFraction fraction: Double) -> Date {
        let start = Calendar.current.startOfDay(for: day)
        return start.addingTimeInterval(min(0.999, max(0, fraction)) * 86_400)
    }

    /// 把鼠标位置换算成表盘上的时刻：0 点在正上方，顺时针走。
    private func date(atPoint point: CGPoint, side: CGFloat) -> Date {
        let dx = point.x - side / 2
        let dy = point.y - side / 2
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return date(atFraction: angle / (2 * .pi))
    }

    // MARK: - 几何

    /// 表盘几何：所有半径从边长推出来，窗口缩放时比例不变。
    private struct RingGeometry {
        let side: CGFloat
        let radius: CGFloat
        let inner: CGFloat
        let bandOuter: CGFloat
        let bandThickness: CGFloat
        let bandCenter: CGFloat

        init(side: CGFloat) {
            self.side = side
            radius = side / 2
            inner = radius * 0.54
            bandOuter = radius - 4
            bandThickness = max(14, radius * 0.145)
            bandCenter = bandOuter - bandThickness / 2
        }
    }

    /// 只有表带可以拖 / 悬停：中央留给信息与播放按钮。
    private struct RingDonut: Shape {
        var innerRatio: CGFloat

        func path(in rect: CGRect) -> Path {
            let outer = min(rect.width, rect.height) / 2
            let inner = outer * innerRatio
            let center = CGPoint(x: rect.midX, y: rect.midY)
            var path = Path()
            path.addArc(center: center, radius: outer,
                        startAngle: .degrees(0), endAngle: .degrees(360),
                        clockwise: false)
            path.addLine(to: CGPoint(x: center.x + inner, y: center.y))
            path.addArc(center: center, radius: inner,
                        startAngle: .degrees(0), endAngle: .degrees(360),
                        clockwise: true)
            path.closeSubpath()
            return path
        }
    }

    /// 指针光锥：从表带内侧扫向中央信息的一束追光，像影院里引导入座的灯。
    private struct PointerBeam: Shape {
        var innerRatio: CGFloat
        var outerRatio: CGFloat
        var halfAngle: Double

        func path(in rect: CGRect) -> Path {
            let radius = min(rect.width, rect.height) / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let start = -90 - halfAngle
            let end = -90 + halfAngle
            var path = Path()
            path.move(to: point(center: center, radius: radius * innerRatio, angle: start))
            path.addArc(center: center,
                        radius: radius * outerRatio,
                        startAngle: .degrees(start),
                        endAngle: .degrees(end),
                        clockwise: false)
            path.addLine(to: point(center: center, radius: radius * innerRatio, angle: end))
            path.addArc(center: center,
                        radius: radius * innerRatio,
                        startAngle: .degrees(end),
                        endAngle: .degrees(start),
                        clockwise: true)
            path.closeSubpath()
            return path
        }

        private func point(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
            let radians = angle * .pi / 180
            return CGPoint(x: center.x + cos(radians) * radius,
                           y: center.y + sin(radians) * radius)
        }
    }

    /// 唱针形状的指针：靠近中央细、靠近表带粗。
    private struct PointerNeedle: Shape {
        var baseWidth: CGFloat
        var tipWidth: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX - baseWidth / 2, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX - tipWidth / 2, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + tipWidth / 2, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + baseWidth / 2, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    /// 表盘底：暗色是黑曜石，浅色是暖白瓷面。
    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: isLight
                           ? [Color(red: 0.975, green: 0.968, blue: 0.952),
                              Color(red: 0.905, green: 0.905, blue: 0.918)]
                           : [Color.black.opacity(0.68), Color.black.opacity(0.93)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.85, green: 0.70, blue: 0.42)
                                        .opacity(isLight ? 0.14 : 0.26),
                                    Color.clear],
                           center: UnitPoint(x: 0.30, y: 0.06),
                           startRadius: 0,
                           endRadius: 520)
            RadialGradient(colors: [Color.white.opacity(isLight ? 0.40 : 0.035), Color.clear],
                           center: UnitPoint(x: 0.86, y: 0.94),
                           startRadius: 0,
                           endRadius: 420)
        }
        .allowsHitTesting(false)
    }

    /// 表盘：一圈表带轨道 + 中央信息圆。
    private func plate(side: CGFloat) -> some View {
        let m = RingGeometry(side: side)
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: isLight
                                     ? [Color(red: 0.99, green: 0.985, blue: 0.975),
                                        Color(red: 0.885, green: 0.878, blue: 0.868)]
                                     : [Color(red: 0.13, green: 0.13, blue: 0.14),
                                        Color(red: 0.015, green: 0.015, blue: 0.02)],
                                     center: UnitPoint(x: 0.42, y: 0.26),
                                     startRadius: 0,
                                     endRadius: m.radius))
                .frame(width: side, height: side)
            Circle()
                .strokeBorder(isLight ? Color.black.opacity(0.10) : Color.black.opacity(0.65),
                              lineWidth: 5)
                .frame(width: side - 2, height: side - 2)
            Circle()
                .strokeBorder(isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.05),
                              lineWidth: 0.7)
                .frame(width: (m.radius - 3) * 2, height: (m.radius - 3) * 2)
            // 中央信息圆：所有读数与播放按钮都落在这块圆盘里。
            Circle()
                .fill(RadialGradient(colors: isLight
                                     ? [Color.white, Color(red: 0.935, green: 0.928, blue: 0.918)]
                                     : [Color(red: 0.155, green: 0.155, blue: 0.165),
                                        Color(red: 0.05, green: 0.05, blue: 0.058)],
                                     center: UnitPoint(x: 0.42, y: 0.24),
                                     startRadius: 0,
                                     endRadius: m.inner))
                .frame(width: m.inner * 2, height: m.inner * 2)
                .overlay {
                    Circle().strokeBorder(isLight ? Color.black.opacity(0.06)
                                                  : Color.white.opacity(0.07),
                                          lineWidth: 0.8)
                }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }

    /// 刻度与 0 / 3 / 6 … 21 的小时读数，位置落在表带与中央圆之间。
    private func hourMarks(side: CGFloat) -> some View {
        let m = RingGeometry(side: side)
        let tickOuter = m.bandOuter - m.bandThickness - 9
        let labelRadius = (m.inner + tickOuter) * 0.5 + 4
        return ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for index in 0..<96 {
                    let angle = Double(index) / 96 * 2 * .pi - .pi / 2
                    let major = index % 4 == 0
                    let inner = tickOuter - (major ? 9 : 4.5)
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + cos(angle) * inner,
                                          y: center.y + sin(angle) * inner))
                    path.addLine(to: CGPoint(x: center.x + cos(angle) * tickOuter,
                                             y: center.y + sin(angle) * tickOuter))
                    context.stroke(path,
                                   with: .color(Color.primary.opacity(major ? 0.32 : 0.12)),
                                   style: StrokeStyle(lineWidth: major ? 1.1 : 0.6,
                                                      lineCap: .round))
                }
            }
            .frame(width: side, height: side)

            ForEach(0..<8, id: \.self) { index in
                let hour = index * 3
                let angle = Double(hour) / 24 * 360
                ZStack {
                    Text(String(format: "%02d", hour))
                        .font(.system(size: max(10, side * 0.022),
                                      weight: .regular, design: .serif))
                        .foregroundStyle(hour % 6 == 0
                                         ? Color.primary.opacity(0.78)
                                         : Color.primary.opacity(0.36))
                        // 文字反向自转保持直立，位置由外层旋转带到位。
                        .rotationEffect(.degrees(-angle))
                        .offset(y: -labelRadius)
                }
                .frame(width: side, height: side)
                .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }

    /// 连续色带：整圈是一条缓慢变色的锥形渐变，节目之间只用深色细缝分隔。
    /// 相邻两档不再突然换成对比色，过渡自然；状态用柔和的暗化 / 高亮叠层表达。
    private func band(side: CGFloat) -> some View {
        let m = RingGeometry(side: side)
        let list = programs
        let focusID = focusProgram?.id
        let isToday = dayOffset == 0
        let canCatchUp = !(channel?.catchUpSource ?? "").isEmpty
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: day)
        let span: Double = 86_400
        let bandInner = m.bandCenter - m.bandThickness / 2
        return Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // 轨道：一整圈连续渐变，取代一档一档的纯色块。
            let track = Path(ellipseIn: CGRect(x: center.x - m.bandCenter,
                                               y: center.y - m.bandCenter,
                                               width: m.bandCenter * 2,
                                               height: m.bandCenter * 2))
            let shading = GraphicsContext.Shading.conicGradient(
                Gradient(colors: Self.bandGradient),
                center: center,
                angle: .degrees(-90))
            context.stroke(track, with: shading,
                           style: StrokeStyle(lineWidth: m.bandThickness, lineCap: .butt))

            for program in list {
                let rawStart = min(1, max(0, program.start.timeIntervalSince(dayStart) / span))
                let rawEnd = min(1, max(0, program.end.timeIntervalSince(dayStart) / span))
                guard rawEnd > rawStart else { continue }
                var path = Path()
                path.addArc(center: center,
                            radius: m.bandCenter,
                            startAngle: .degrees(rawStart * 360 - 90),
                            endAngle: .degrees(rawEnd * 360 - 90),
                            clockwise: false)
                let live = program.isLive && isToday
                let past = program.end <= now
                if live {
                    // 正在播：一层柔光和红色罩染，保留底色的连续性。
                    context.stroke(path,
                                   with: .color(TVBrand.signal.opacity(0.26)),
                                   style: StrokeStyle(lineWidth: m.bandThickness + 14, lineCap: .butt))
                    context.stroke(path,
                                   with: .color(TVBrand.signal.opacity(0.40)),
                                   style: StrokeStyle(lineWidth: m.bandThickness, lineCap: .butt))
                } else if past, !canCatchUp {
                    // 不能回看的已播段：暗色下压黑，浅色下洗白。
                    context.stroke(path,
                                   with: .color(isLight ? Color.white.opacity(0.62)
                                                        : Color.black.opacity(0.62)),
                                   style: StrokeStyle(lineWidth: m.bandThickness, lineCap: .butt))
                } else if !past {
                    context.stroke(path,
                                   with: .color(isLight ? Color.white.opacity(0.30)
                                                        : Color.black.opacity(0.18)),
                                   style: StrokeStyle(lineWidth: m.bandThickness, lineCap: .butt))
                }
                if program.id == focusID {
                    // 选中：一条更亮的内衬，而不是换色。
                    context.stroke(path,
                                   with: .color(Color.white.opacity(isLight ? 0.45 : 0.20)),
                                   style: StrokeStyle(lineWidth: m.bandThickness - 8, lineCap: .butt))
                }
            }

            // 分隔缝：深色细线压在色带上，让每一档仍然可分，但不再是硬换色。
            for program in list {
                let fraction = min(1, max(0, program.start.timeIntervalSince(dayStart) / span))
                let angle = (fraction * 360 - 90) * .pi / 180
                var separator = Path()
                separator.move(to: CGPoint(x: center.x + cos(angle) * bandInner,
                                           y: center.y + sin(angle) * bandInner))
                separator.addLine(to: CGPoint(x: center.x + cos(angle) * m.bandOuter,
                                              y: center.y + sin(angle) * m.bandOuter))
                context.stroke(separator,
                               with: .color(isLight ? Color.white.opacity(0.85)
                                                    : Color.black.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 2.2, lineCap: .butt))
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }

    /// 表带渐变：紫 → 蓝 → 青 → 绿 → 金 → 珊瑚 → 玫红 → 紫，首尾相接，没有突变。
    private static let bandGradient: [Color] = [
        Color(red: 0.52, green: 0.33, blue: 0.90),
        Color(red: 0.40, green: 0.46, blue: 0.94),
        Color(red: 0.28, green: 0.62, blue: 0.92),
        Color(red: 0.20, green: 0.74, blue: 0.70),
        Color(red: 0.36, green: 0.76, blue: 0.50),
        Color(red: 0.90, green: 0.70, blue: 0.30),
        Color(red: 0.92, green: 0.48, blue: 0.42),
        Color(red: 0.84, green: 0.38, blue: 0.62),
        Color(red: 0.52, green: 0.33, blue: 0.90)
    ]

    private func interactionLayer(side: CGFloat) -> some View {
        // 只让表带这一圈响应：中央的信息圆彻底不动，鼠标落在里面不会改时间。
        let geometry = RingGeometry(side: side)
        let innerRatio = geometry.inner / geometry.radius + 0.02
        return RingDonut(innerRatio: innerRatio)
            .fill(Color.clear)
            .frame(width: side, height: side)
            .contentShape(RingDonut(innerRatio: innerRatio))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !isInsideCore(value.location, side: side) else { return }
                        throttledDrag {
                            hoverDate = nil
                            pointer = date(atPoint: value.location, side: side)
                        }
                    }
                    .onEnded { value in
                        guard !isInsideCore(value.location, side: side) else { return }
                        let target = date(atPoint: value.location, side: side)
                        withAnimation(.easeOut(duration: 0.18)) { pointer = target }
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    updateHover(point, side: side)
                case .ended:
                    hoverDate = nil
                }
            }
    }

    /// 鼠标落在中央信息圆里：不改时间、不动指针，保持上一次的选择，
    /// 这样播放 / 预约按钮不会被「转动」打断。
    private func isInsideCore(_ point: CGPoint, side: CGFloat) -> Bool {
        let m = RingGeometry(side: side)
        let dx = point.x - side / 2
        let dy = point.y - side / 2
        return (dx * dx + dy * dy).squareRoot() <= m.inner + 4
    }

    /// 悬停限频到约 20 次/秒：表针要跟手，但不必跟着鼠标每一个像素重绘。
    private func updateHover(_ point: CGPoint, side: CGFloat) {
        guard !isInsideCore(point, side: side) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHoverTick) > 0.05 else { return }
        lastHoverTick = now
        let target = date(atPoint: point, side: side)
        hoverDate = target
        // 鼠标挪到别的刻度即解锁：指针跟着走并记住这个位置，
        // 离开表盘后停在这里，不会弹回上一次点过的刻度。
        pointer = target
    }

    /// 拖动限频到约 30 次/秒，高刷鼠标也不会把状态写爆。
    private func throttledDrag(_ update: () -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastDragTick) > 0.033 else { return }
        lastDragTick = now
        update()
    }

    /// 指针：一束从表带扫向中央的追光 + 一枚细长的金色唱针。
    /// 光锥负责「引导观影」——视线顺着光落到中央的节目与播放键；针尖精确停在选中的那一段表带上。
    private func pointerView(side: CGFloat) -> some View {
        let m = RingGeometry(side: side)
        let fraction = dayFraction(focusDate)
        let needleBase = m.inner + 10
        let needleLength = max(12, m.bandCenter - needleBase - 9)
        let bandInner = m.bandCenter - m.bandThickness / 2
        return ZStack {
            // 追光：从中央圆边缘向外变亮，落在表带内侧就收住，不遮盖节目色块。
            PointerBeam(innerRatio: m.inner / m.radius,
                        outerRatio: (bandInner + 2) / m.radius,
                        halfAngle: 7)
                .fill(RadialGradient(colors: [TVBrand.gold.opacity(0),
                                              TVBrand.gold.opacity(isLight ? 0.16 : 0.10),
                                              Color(red: 0.88, green: 0.55, blue: 0.12)
                                                  .opacity(isLight ? 0.26 : 0.18)],
                                     center: .center,
                                     startRadius: m.inner,
                                     endRadius: bandInner))
                .frame(width: side, height: side)

            // 针身：靠近中央细、靠近表带粗，像唱机落针。
            PointerNeedle(baseWidth: 3.2, tipWidth: 0.8)
                .fill(LinearGradient(colors: [isLight
                                              ? Color(red: 0.55, green: 0.40, blue: 0.10).opacity(0.30)
                                              : Color(red: 0.95, green: 0.92, blue: 0.86).opacity(0.18),
                                              isLight
                                              ? Color(red: 0.68, green: 0.47, blue: 0.08)
                                              : TVBrand.gold],
                                     startPoint: .bottom, endPoint: .top))
                .frame(width: 7, height: needleLength)
                .offset(y: -(needleBase + needleLength / 2))

            // 针头：一枚「放映镜头」——金环 + 镜筒 + 高光点，像投影机对准那一档节目。
            ZStack {
                Circle()
                    .fill(isLight ? Color.white.opacity(0.95) : Color.black.opacity(0.62))
                    .frame(width: 16, height: 16)
                Circle()
                    .strokeBorder(isLight ? Color(red: 0.68, green: 0.47, blue: 0.08)
                                          : TVBrand.gold,
                                  lineWidth: 1.8)
                    .frame(width: 16, height: 16)
                Circle()
                    .fill(TVBrand.gold.opacity(0.92))
                    .frame(width: 6, height: 6)
                Circle()
                    .fill(isLight ? Color(red: 0.34, green: 0.24, blue: 0.05)
                                  : Color.white.opacity(0.95))
                    .frame(width: 2.4, height: 2.4)
            }
            .shadow(color: TVBrand.gold.opacity(0.45), radius: 6)
            .offset(y: -m.bandCenter)
        }
        .frame(width: side, height: side)
        .rotationEffect(.degrees(fraction * 360))
        .allowsHitTesting(false)
    }

    /// 中央信息圆只做展示：吞掉悬停和拖动，鼠标挪进来不选段、指针不转，
    /// 否则按钮会被指针的拖动抢走事件，点不了播放 / 预约。
    private func centerBlocker(side: CGFloat) -> some View {
        let m = RingGeometry(side: side)
        return Circle()
            .fill(Color.clear)
            .frame(width: m.inner * 2, height: m.inner * 2)
            .contentShape(Circle())
            .onContinuousHover { _ in }
            .gesture(DragGesture(minimumDistance: 0))
            .allowsHitTesting(true)
    }

    /// 中央读数：时间、日期、频道、当前节目与播放按钮，全部随指针移动实时变化。
    private func center(side: CGFloat) -> some View {
        let m = RingGeometry(side: side)
        let focus = focusProgram
        let active = channel
        let width = m.inner * 1.62
        return VStack(spacing: max(3, side * 0.011)) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(dayLabel)
                    .font(.system(size: max(9, side * 0.016),
                                  weight: .semibold, design: .monospaced))
                    .foregroundStyle(TVBrand.gold.opacity(0.85))
                Text(Self.clock(focusDate))
                    .font(.system(size: max(22, side * 0.052), weight: .light, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(isLight ? Color.primary
                                             : Color(red: 0.95, green: 0.92, blue: 0.86))
            }
            if let active {
                Text("\(String(format: "%02d", tv.channelNumber(for: active))) · \(active.name)")
                    .font(.system(size: max(8.5, side * 0.015),
                                  weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.44))
                    .lineLimit(1)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: width * 0.34, height: 0.6)
                .padding(.vertical, 1)
            Text(focus?.title ?? "这段时间没有节目")
                .font(.system(size: max(10.5, side * 0.022), weight: .semibold))
                .foregroundStyle(Color.primary.opacity(focus == nil ? 0.42 : 0.93))
                .lineLimit(1)
                .frame(width: width * 0.88)
            if let focus {
                Text("\(Self.timeRange(focus)) · \(statusText(focus))")
                    .font(.system(size: max(8.5, side * 0.0145), design: .monospaced))
                    .foregroundStyle(focus.isLive && dayOffset == 0
                                     ? TVBrand.signal.opacity(0.95)
                                     : Color.primary.opacity(0.46))
            }
            if let active, let focus {
                playButton(channel: active, program: focus, side: side)
                    .padding(.top, 2)
            }
        }
        .frame(width: width)
        .multilineTextAlignment(.center)
    }

    /// 中央播放按钮：直播直接播，已播且有回看就回看，未播则预约。
    @ViewBuilder
    private func playButton(channel: TVChannel,
                            program: TVEPGProgram,
                            side: CGFloat) -> some View {
        let live = program.isLive && dayOffset == 0
        let past = program.end <= Date() && !live
        let canCatchUp = !(channel.catchUpSource ?? "").isEmpty
        let playable = live || (past && canCatchUp)
        let reminded = tv.isReminded(program)
        let size = max(34, side * 0.072)
        let label: String = {
            if live { return "播放直播" }
            if past { return canCatchUp ? "回看这档" : "不可回看" }
            return reminded ? "已预约" : "预约提醒"
        }()
        VStack(spacing: 3) {
            Button {
                if live {
                    store.openTVChannel(channel)
                } else if past, canCatchUp {
                    store.openTVCatchup(channel, program: program)
                } else if !past {
                    tv.toggleReminder(program, channel: channel)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(playable ? TVBrand.gold : Color.primary.opacity(0.08))
                    Circle()
                        .strokeBorder(Color.primary.opacity(playable ? 0.28 : 0.07), lineWidth: 0.8)
                    Image(systemName: live || (past && canCatchUp)
                          ? "play.fill"
                          : (past ? "slash" : (reminded ? "bell.slash.fill" : "bell.fill")))
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(playable ? Color.black.opacity(0.86)
                                                  : Color.primary.opacity(0.34))
                        .offset(x: playable ? size * 0.04 : 0)
                }
                .frame(width: size, height: size)
            }
            .buttonStyle(.plain)
            .disabled(past && !canCatchUp)
            .help(label)
            Text(label)
                .font(.system(size: max(8.5, side * 0.0145), weight: .medium))
                .foregroundStyle(playable ? TVBrand.gold.opacity(0.92)
                                          : Color.primary.opacity(0.38))
        }
    }

    private func statusText(_ program: TVEPGProgram) -> String {
        if program.isLive, dayOffset == 0 { return "正在播" }
        if program.end <= Date() {
            return (channel?.catchUpSource ?? "").isEmpty ? "已结束" : "可回看"
        }
        return tv.isReminded(program) ? "已预约" : "待播"
    }

    private static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static func timeRange(_ program: TVEPGProgram) -> String {
        "\(clock(program.start)) – \(clock(program.end))"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
