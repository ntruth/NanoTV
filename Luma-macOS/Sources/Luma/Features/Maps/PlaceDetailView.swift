import SwiftUI
import AppKit
import Foundation
import MapKit

/// 地点详情：地图感页头 + 地点摘要 + 旅行日志式的全部照片。
/// 与人物详情共用滚动收缩与「摘要 / 全部」交互，但内容全部围绕地点：到访轨迹、四季、地标与坐标。
struct PlaceDetailView: View {
    @EnvironmentObject private var store: LibraryStore

    let place: PlaceCluster
    let photos: [PhotoItem]
    let onBack: () -> Void
    let onOpenMap: () -> Void

    @State private var mode: PersonDetailMode = .summary
    @State private var insight: PlaceInsight?
    @State private var collapseProgress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                PlaceDetailHero(place: place,
                                insight: insight,
                                fallbackPhotos: photos,
                                mode: mode,
                                collapse: collapseProgress,
                                onBack: onBack,
                                onModeChange: { mode = $0 },
                                onOpenMap: onOpenMap)

                ScrollView {
                    VStack(spacing: 0) {
                        PersonScrollTracker(coordinateSpace: "placeDetailScroll")
                        if mode == .summary {
                            if let insight {
                                PlaceInsightSummaryView(insight: insight, photos: photos, onOpenMap: onOpenMap)
                            } else {
                                VStack(spacing: 10) {
                                    ProgressView()
                                    Text("正在整理这段旅程…")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 360)
                            }
                        } else {
                            PlaceAllPhotosView(photos: photos,
                                               availableWidth: proxy.size.width,
                                               fillHeight: proxy.size.height)
                        }
                    }
                    .id(mode)
                }
                .coordinateSpace(name: "placeDetailScroll")
                .onPreferenceChange(PersonScrollOffsetKey.self) { offset in
                    let value = min(1, max(0, offset / 180))
                    if abs(value - collapseProgress) > 0.004 {
                        collapseProgress = value
                    }
                }
            }
        }
        .task(id: "\(place.id)|\(photos.count)") {
            mode = .summary
            collapseProgress = 0
            insight = nil
            insight = await store.placeInsightAsync(for: place)
        }
    }
}

// MARK: - 页头

private struct PlaceDetailHero: View {
    @EnvironmentObject private var store: LibraryStore

    let place: PlaceCluster
    let insight: PlaceInsight?
    let fallbackPhotos: [PhotoItem]
    let mode: PersonDetailMode
    let collapse: CGFloat
    let onBack: () -> Void
    let onModeChange: (PersonDetailMode) -> Void
    let onOpenMap: () -> Void

    private var progress: CGFloat { min(1, max(0, collapse)) }
    private var heroHeight: CGFloat { 250 - 152 * progress }
    private var pinSize: CGFloat { 56 - 24 * progress }
    private var titleSize: CGFloat { 27 - 12 * progress }
    private var edgePadding: CGFloat { 18 - 6 * progress }
    private var cornerRadius: CGFloat { 24 - 8 * progress }
    private var subtitleOpacity: Double { Double(max(0, 1 - progress * 1.8)) }

    private var cover: PhotoItem? { insight?.coverPhoto ?? fallbackPhotos.first }

    private var subtitle: String {
        if let insight { return insight.subtitle }
        let region = place.subtitle ?? place.group
        return "\(region) · \(fallbackPhotos.count.formatted()) 张"
    }

    private var coordinateText: String {
        if let insight { return insight.coordinateText }
        let lat = String(format: "%.2f°%@", abs(place.latitude), place.latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.2f°%@", abs(place.longitude), place.longitude >= 0 ? "E" : "W")
        return "\(lat) · \(lon)"
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background
            PlaceMapGrid()
            radarMotif
            LinearGradient(colors: [Color.black.opacity(0.38),
                                    Color.black.opacity(0.08),
                                    Color.black.opacity(0.72)],
                           startPoint: .topLeading,
                           endPoint: .bottom)
            content
        }
        .frame(height: heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.18 * Double(1 - progress * 0.6)),
                radius: 16 - 8 * progress,
                y: 8 - 3 * progress)
        .padding(.horizontal, 20)
        .padding(.top, 16 - 6 * progress)
    }

    private var background: some View {
        Group {
            if let cover {
                GeometryReader { geo in
                    PhotoHeroCover(photo: cover)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                LinearGradient(colors: [Color.teal.opacity(0.5),
                                        Color.blue.opacity(0.25),
                                        Color.black.opacity(0.85)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            }
        }
    }

    /// 地图坐标感的细网格。
    private var radarMotif: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
                    .frame(width: 230)
                Circle()
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.8)
                    .frame(width: 145)
                Circle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 4)
            }
            .position(x: geo.size.width * 0.68, y: geo.size.height * 0.40)
            .allowsHitTesting(false)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                glassCircle(icon: "chevron.left", help: "返回位置", action: onBack)
                Spacer()
                Button(action: onOpenMap) {
                    HStack(spacing: 5) {
                        Image(systemName: "map")
                        if progress < 0.45 {
                            Text("在地图中查看")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11 - 3 * progress)
                    .padding(.vertical, 6)
                    .heroGlass(Capsule())
                }
                .buttonStyle(.plain)
                .help("在地图中查看这个位置")
            }

            Spacer(minLength: 2)

            HStack(alignment: .bottom, spacing: 14 - 6 * progress) {
                pinBadge
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.title)
                        .font(.system(size: titleSize, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .opacity(subtitleOpacity)
                    }
                    Text(coordinateText)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .heroGlass(Capsule(), strokeWidth: 0.6)
                        .opacity(subtitleOpacity)
                }
                Spacer(minLength: 10)
                DetailModeSwitch(mode: mode, collapse: progress, onChange: onModeChange)
            }
        }
        .padding(edgePadding)
    }

    private var pinBadge: some View {
        ZStack {
            Color.clear
                .heroGlass(Circle())
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: pinSize * 0.42, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: pinSize, height: pinSize)
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: pinSize * 0.2, height: pinSize * 0.2)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.4))
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
    }

    private func glassCircle(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .heroGlass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 页头上的细网格，模拟地图坐标格。
private struct PlaceMapGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 44
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(.white.opacity(0.09)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 摘要

private struct PlaceInsightSummaryView: View {
    let insight: PlaceInsight
    let photos: [PhotoItem]
    let onOpenMap: () -> Void

    private let spacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            narrativeCard
            statsGrid
            if !insight.years.isEmpty { visitChartCard }
            seasonCard

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 288), spacing: spacing, alignment: .top)],
                      alignment: .leading,
                      spacing: spacing) {
                if !insight.spots.isEmpty { spotsCard }
                periodsCard
                if !insight.companions.isEmpty { companionsCard }
                miniMapCard
                if !insight.palettePhotos.isEmpty { paletteCard }
            }

            if !insight.highlights.isEmpty { highlightsSection }
            footnote
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
        .padding(.bottom, 60)
        .frame(maxWidth: 1280, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var narrativeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "location.north.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("\(insight.title) 的影像足迹")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text("端侧生成")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Text(insight.narrative)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color.teal.opacity(0.16),
                                              Color.accentColor.opacity(0.05)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.22), lineWidth: 0.8)
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 12)],
                  alignment: .leading,
                  spacing: 12) {
            PlaceStatCard(value: insight.totalCount.formatted(),
                          caption: "影像总数",
                          icon: "photo.stack")
            PlaceStatCard(value: "\(insight.visitYearCount)",
                          caption: insight.visitYearCount > 1 ? "到访年份" : "记录年份",
                          icon: "calendar")
            PlaceStatCard(value: yearText(insight.firstDate),
                          caption: "首次到访",
                          icon: "airplane.arrival")
            PlaceStatCard(value: yearText(insight.lastDate),
                          caption: "最近到访",
                          icon: "airplane.departure")
        }
    }

    private func yearText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return String(Calendar.current.component(.year, from: date))
    }

    private var visitChartCard: some View {
        InsightCard(title: "到访轨迹", icon: "chart.line.uptrend.xyaxis", subtitle: "按拍摄年份") {
            PlaceVisitChart(years: insight.years)
        }
    }

    private var seasonCard: some View {
        InsightCard(title: "四季流转", icon: "leaf", subtitle: "按拍摄月份") {
            VStack(spacing: 14) {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(insight.seasons) { season in
                            if season.fraction > 0 {
                                Rectangle()
                                    .fill(placeSeasonColor(season.name))
                                    .frame(width: geo.size.width * CGFloat(season.fraction))
                                    .help("\(season.name)季 · \(season.count) 张")
                            }
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 14)

                HStack(spacing: 10) {
                    ForEach(insight.seasons) { season in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: season.symbol)
                                    .font(.system(size: 10))
                                    .foregroundStyle(placeSeasonColor(season.name))
                                Text(season.name)
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            Text("\(Int((season.fraction * 100).rounded()))%")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("\(season.count) 张")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var spotsCard: some View {
        InsightCard(title: "镜头里的地标", icon: "building.2", subtitle: "按照片地点细化") {
            let peak = max(1, insight.spots.first?.count ?? 1)
            VStack(spacing: 12) {
                ForEach(insight.spots.indices, id: \.self) { index in
                    let spot = insight.spots[index]
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 9.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.accentColor.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(spot.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(spot.count) 张")
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.07))
                                    Capsule()
                                        .fill(LinearGradient(colors: [Color.accentColor,
                                                                      Color.accentColor.opacity(0.45)],
                                                             startPoint: .leading,
                                                             endPoint: .trailing))
                                        .frame(width: max(4, geo.size.width * CGFloat(spot.count) / CGFloat(peak)))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                }
            }
        }
    }

    private var periodsCard: some View {
        InsightCard(title: "一天中的这里", icon: "sun.horizon", subtitle: "按拍摄时段") {
            VStack(spacing: 12) {
                ForEach(insight.periods) { slice in
                    HStack(spacing: 10) {
                        Text(slice.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 30, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule()
                                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.9),
                                                                  Color.accentColor.opacity(0.35)],
                                                         startPoint: .leading,
                                                         endPoint: .trailing))
                                    .frame(width: max(slice.count > 0 ? 4 : 0,
                                                      geo.size.width * CGFloat(slice.fraction)))
                            }
                        }
                        .frame(height: 6)
                        Text("\(Int((slice.fraction * 100).rounded()))%")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var companionsCard: some View {
        InsightCard(title: "同行的人", icon: "person.2", subtitle: "照片中同时出现") {
            VStack(spacing: 10) {
                ForEach(insight.companions) { companion in
                    HStack(spacing: 10) {
                        CompanionAvatar(companion: companion, size: 30)
                        Text(companion.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("同框 \(companion.count) 次")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 按地点内照片的实际分布取景；同一处照片重叠时至少保留 0.012° 的街区视野。
    private var miniMapRegion: MKCoordinateRegion {
        let located = photos.filter { $0.latitude != nil && $0.longitude != nil }
        if !located.isEmpty {
            return PhotoMapRegion.region(for: located)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: insight.latitude, longitude: insight.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
    }

    private var miniMapCard: some View {
        InsightCard(title: "位置坐标", icon: "location.north.circle", subtitle: "地点聚类中心") {
            VStack(alignment: .leading, spacing: 10) {
                Map(initialPosition: .region(miniMapRegion), interactionModes: []) {
                    Annotation("",
                               coordinate: CLLocationCoordinate2D(latitude: insight.latitude,
                                                                  longitude: insight.longitude),
                               anchor: .bottom) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.accentColor, Color.white)
                            .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .frame(height: 148)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                }
                .allowsHitTesting(false)

                HStack(spacing: 8) {
                    Text(insight.coordinateText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button(action: onOpenMap) {
                        Label("在地图中查看", systemImage: "map")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var paletteCard: some View {
        InsightCard(title: "色彩气质", icon: "paintpalette", subtitle: "缩略图平均色") {
            PhotoPalettePanel(photos: insight.palettePhotos)
        }
    }

    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("高光时刻")
                    .font(.system(size: 15, weight: .semibold))
                Text("每个年份最值得回看的一张")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(insight.highlights) { photo in
                        PhotoHighlightCard(photo: photo)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
            Text("地点画像与统计全部在本机由照片元数据派生，不上传任何照片。")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 2)
    }
}

/// 地点指标卡。
private struct PlaceStatCard: View {
    let value: String
    let caption: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
        }
    }
}

/// 到访轨迹：折线 + 渐变面积的年度曲线，比人物页的柱状图更像旅程。
private struct PlaceVisitChart: View {
    let years: [PlaceInsight.YearCount]

    var body: some View {
        GeometryReader { geo in
            let chartHeight = geo.size.height - 20
            let maxCount = max(1, years.map(\.count).max() ?? 1)
            let points = points(width: geo.size.width, height: chartHeight, maxCount: maxCount)

            ZStack(alignment: .topLeading) {
                gridLines(width: geo.size.width, height: chartHeight)

                areaPath(points: points, height: chartHeight)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.34),
                                                  Color.accentColor.opacity(0.02)],
                                         startPoint: .top,
                                         endPoint: .bottom))

                linePath(points: points)
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                ForEach(points.indices, id: \.self) { index in
                    let point = points[index]
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                        .position(point)

                    Text(years[index].count.formatted())
                        .font(.system(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .position(x: point.x, y: max(8, point.y - 14))

                    Text(String(years[index].year))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .position(x: point.x, y: chartHeight + 10)
                }
            }
        }
        .frame(height: 150)
    }

    private func points(width: CGFloat, height: CGFloat, maxCount: Int) -> [CGPoint] {
        guard !years.isEmpty else { return [] }
        let usable = max(1, width - 16)
        let step = years.count > 1 ? usable / CGFloat(years.count - 1) : 0
        return years.enumerated().map { index, bucket in
            let x = years.count > 1 ? 8 + CGFloat(index) * step : width / 2
            let ratio = CGFloat(bucket.count) / CGFloat(maxCount)
            let y = height - ratio * (height - 24) - 6
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
    }

    private func areaPath(points: [CGPoint], height: CGFloat) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: height))
            path.addLine(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.closeSubpath()
        }
    }

    private func gridLines(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, _ in
            for index in 0...3 {
                let y = height * CGFloat(index) / 3
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
                context.stroke(path, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private func placeSeasonColor(_ name: String) -> Color {
    switch name {
    case "春": return .green
    case "夏": return .orange
    case "秋": return .brown
    default: return .cyan
    }
}

// MARK: - 全部照片

/// 「全部」：旅行日志式年份分段，每个年份带四季比例条与瀑布流拼贴。
private struct PlaceAllPhotosView: View {
    @EnvironmentObject private var store: LibraryStore

    let photos: [PhotoItem]
    let availableWidth: CGFloat
    let fillHeight: CGFloat

    var body: some View {
        let groups = Dictionary(grouping: photos) {
            Calendar.current.component(.year, from: $0.capturedAt)
        }
        let years = groups.keys.sorted(by: >)

        LazyVStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("旅行日志")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(photos.count.formatted()) 张 · 按年份回看")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 26)

            ForEach(years, id: \.self) { year in
                let yearPhotos = groups[year] ?? []
                VStack(alignment: .leading, spacing: 12) {
                    PlaceYearHeader(year: year, photos: yearPhotos)
                    MasonryPhotoGrid(photos: yearPhotos,
                                     availableWidth: availableWidth,
                                     targetWidth: CGFloat(store.thumbSize) * 1.25,
                                     viewerContext: photos)
                }
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 56)
        .photoMarqueeSelection(fillHeight: fillHeight)
    }
}

private struct PlaceYearHeader: View {
    let year: Int
    let photos: [PhotoItem]

    private var seasonCounts: [Int] {
        var counts = [0, 0, 0, 0]
        let calendar = Calendar.current
        for photo in photos {
            let month = calendar.component(.month, from: photo.capturedAt)
            switch month {
            case 3...5: counts[0] += 1
            case 6...8: counts[1] += 1
            case 9...11: counts[2] += 1
            default: counts[3] += 1
            }
        }
        return counts
    }

    var body: some View {
        let counts = seasonCounts
        let total = max(1, counts.reduce(0, +))
        let names = ["春", "夏", "秋", "冬"]

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(year))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LinearGradient(colors: [Color.accentColor,
                                                         Color.accentColor.opacity(0.5)],
                                                startPoint: .top,
                                                endPoint: .bottom))
            Text("\(photos.count) 张")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                ForEach(counts.indices, id: \.self) { index in
                    if counts[index] > 0 {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(placeSeasonColor(names[index]).opacity(0.8))
                            .frame(width: max(3, 64 * CGFloat(counts[index]) / CGFloat(total)))
                            .help("\(names[index])季 · \(counts[index]) 张")
                    }
                }
            }
            .frame(height: 5)

            Rectangle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.30), Color.clear],
                                     startPoint: .leading,
                                     endPoint: .trailing))
                .frame(height: 0.8)
        }
        .padding(.horizontal, 26)
    }
}
