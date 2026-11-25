import SwiftUI
import AppKit
import LumaCore

/// 地图「网格」模式：按「地点 + 连续日期」把照片切成行程段，用卡片网格逐段展示。
/// 与系统「照片」的地点网格一致：段头是城市、日期范围与「查看地点」入口，下面是该段照片。
struct MapPlaceGridView: View {
    @EnvironmentObject private var store: LibraryStore
    let photos: [PhotoItem]
    let availableWidth: CGFloat
    /// 视野指纹：换一片区域时即便照片数量相同也要重算行程段。
    let scopeKey: String
    let emptyText: String

    @State private var trips: [MapTripGroup] = []

    private let spacing: CGFloat = 6
    private let horizontalPadding: CGFloat = 24

    init(photos: [PhotoItem],
         scopeKey: String = "all",
         availableWidth: CGFloat,
         emptyText: String = "这些照片还没有可用的地点信息。") {
        self.photos = photos
        self.scopeKey = scopeKey
        self.availableWidth = availableWidth
        self.emptyText = emptyText
        // 初始值留空，交给 `.task` 计算：视图每次重新构造时不必再把全部照片重排一遍。
        _trips = State(initialValue: [])
    }

    /// 视野、照片数量、图库版本、地点层级或地点解析进度变化时重算行程段。
    private var tripsKey: String {
        "\(scopeKey)|\(photos.count)|\(store.contentRevision)|\(store.placeGranularity.rawValue)|\(store.placeResolveDone)"
    }

    /// 查看器序号与翻页的基准：整片视野按段落显示顺序（段间由新到旧、段内由新到旧）展开。
    private var viewerContextPhotos: [PhotoItem] {
        trips.flatMap { $0.photos }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if trips.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        ForEach(Array(trips.enumerated()), id: \.element.id) { index, trip in
                            VStack(alignment: .leading, spacing: 12) {
                                header(trip, showsDivider: index > 0)
                                grid(trip)
                            }
                        }
                        Color.clear.frame(height: 36)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 88)
                .photoMarqueeSelection(fillHeight: proxy.size.height)
            }
            .scrollIndicators(.automatic)
        }
        .task(id: tripsKey) {
            // 行程分段要排序整片照片，放到后台算，避免大图库切换网格时卡住界面。
            let photos = self.photos
            let granularity = store.placeGranularity
            let result = await Task.detached(priority: .userInitiated) {
                Self.makeTrips(photos, granularity: granularity)
            }.value
            guard !Task.isCancelled else { return }
            trips = result
        }
    }

    // MARK: - 段头

    private func header(_ trip: MapTripGroup, showsDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)
            }
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                Text(trip.title)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                Text(trip.dateText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(trip.photos.count) 张")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                if let cluster = cluster(for: trip) {
                    Button {
                        store.navigate(to: .places)
                        store.openPlace(cluster)
                    } label: {
                        HStack(spacing: 3) {
                            Text(trip.title)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("打开「\(trip.title)」的地点页")
                }
            }
        }
    }

    // MARK: - 网格

    private func grid(_ trip: MapTripGroup) -> some View {
        let contentWidth = max(120, availableWidth - horizontalPadding * 2)
        let target = CGFloat(store.thumbSize)
        let columns = GridLayout.columns(contentWidth: contentWidth,
                                         targetSize: target,
                                         spacing: spacing)
        let cell = GridLayout.squareCellWidth(contentWidth: contentWidth,
                                              columns: columns,
                                              spacing: spacing)
        let context = viewerContextPhotos
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: columns),
            spacing: spacing
        ) {
            ForEach(trip.photos) { photo in
                PhotoCell(photo: photo, width: cell, height: cell,
                          cornerRadius: 0,
                          viewerContext: context)
                    .id(photo.id)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: PhotoFramePreferenceKey.self,
                                value: [photo.id: geo.frame(in: .named(PhotoMarqueeSpace.name))]
                            )
                        }
                    )
            }
        }
    }

    private func cluster(for trip: MapTripGroup) -> PlaceCluster? {
        store.placeClusters.first { $0.id == trip.placeID }
    }

    // MARK: - 行程分组

    private nonisolated static func makeTrips(_ photos: [PhotoItem],
                                              granularity: PlaceGranularity = .district) -> [MapTripGroup] {
        let sorted = photos
            .filter { $0.latitude != nil && $0.longitude != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard !sorted.isEmpty else { return [] }

        let calendar = Calendar.current
        let keys = sorted.map { PlaceClusterBuilder.key(for: $0, granularity: granularity) }
        let days = sorted.map { calendar.startOfDay(for: $0.capturedAt) }
        let ordinals = days.map { calendar.ordinality(of: .day, in: .era, for: $0) ?? 0 }
        let spans = TripSegmentation.spans(placeKeys: keys.map(\.id), dayOrdinals: ordinals)

        return spans.map { span in
            let first = keys[span.lowerBound]
            let members = sorted[span].sorted { $0.capturedAt > $1.capturedAt }
            return MapTripGroup(id: "\(first.id)|\(span.lowerBound)",
                                placeID: first.id,
                                title: first.title,
                                photos: members,
                                startDay: days[span.lowerBound],
                                endDay: days[span.upperBound])
        }
        .sorted { $0.startDay > $1.startDay }
    }
}

/// 一段行程：同一地点、连续日期内拍摄的一组照片。
struct MapTripGroup: Identifiable {
    let id: String
    let placeID: String
    let title: String
    let photos: [PhotoItem]
    let startDay: Date
    let endDay: Date

    var dateText: String {
        let calendar = Calendar.current
        let start = calendar.dateComponents([.year, .month, .day], from: startDay)
        let end = calendar.dateComponents([.year, .month, .day], from: endDay)
        guard let y = start.year, let m = start.month, let d = start.day else { return "" }
        let ey = end.year ?? y
        let em = end.month ?? m
        let ed = end.day ?? d
        if ey == y, em == m, ed == d { return "\(y)年\(m)月\(d)日" }
        if ey == y, em == m { return "\(y)年\(m)月\(d)日-\(ed)日" }
        if ey == y { return "\(y)年\(m)月\(d)日 - \(em)月\(ed)日" }
        return "\(y)年\(m)月\(d)日 - \(ey)年\(em)月\(ed)日"
    }
}
