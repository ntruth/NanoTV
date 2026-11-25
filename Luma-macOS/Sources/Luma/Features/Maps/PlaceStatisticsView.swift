import SwiftUI
import AppKit

/// 「位置」——按城市 / 区县聚合的地点统计卡片墙。
struct PlaceStatisticsView: View {
    @EnvironmentObject private var store: LibraryStore
    /// 由顶部工具栏共享的搜索关键词。
    @Binding var query: String
    @State private var pinchBase: Double?
    /// 点分组标题收起 / 展开；默认全部展开。
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        if let place = store.selectedPlace {
            placeDetail(place)
        } else {
            overview
        }
    }

    // MARK: - 概览

    private var overview: some View {
        VStack(spacing: 0) {
            if store.isResolvingPlaces {
                resolveProgress
            }
            ScrollView {
                if store.placeClusters.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 30) {
                        ForEach(groups, id: \.title) { group in
                            groupSection(group)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                    .padding(.bottom, 56)
                }
            }
            .simultaneousGesture(pinchGesture)
        }
        .onChange(of: store.placeGranularity) { _, _ in
            // 换层级就是换一批分组，收起状态跟着重置。
            collapsedGroups = []
        }
        .task {
            await store.awaitDirectGeoIfNeeded()
            store.resolveMissingPlacesIfNeeded()
        }
    }

    @ViewBuilder
    private func groupSection(_ group: (title: String, clusters: [PlaceCluster])) -> some View {
        let isCollapsed = collapsedGroups.contains(group.title)
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isCollapsed {
                        collapsedGroups.remove(group.title)
                    } else {
                        collapsedGroups.insert(group.title)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "展开「\(group.title)」" : "收起「\(group.title)」")

            if !isCollapsed {
                LazyVGrid(columns: columns, alignment: .leading, spacing: cardSize * 0.17) {
                    ForEach(group.clusters) { cluster in
                        placeCard(cluster)
                    }
                }
            }
        }
    }

    private func placeCard(_ cluster: PlaceCluster) -> some View {
        PlaceCardView(cluster: cluster)
            .onTapGesture { store.openPlace(cluster) }
    }

    /// 地点卡片尺寸跟随工具栏缩放（56…360 → 90…400，默认 132 → 约 152）。
    private var cardSize: CGFloat {
        min(400, max(90, CGFloat(store.thumbSize) * 1.15))
    }

    private var pinchGesture: some Gesture {
        // 阈值要够大：触摸板双指滚动经常带一点张合，阈值太小会把滚动误判成缩放，
        // 卡片尺寸一变，整页内容高度跟着变，滚动就会不停跳动。
        MagnifyGesture(minimumScaleDelta: 0.04)
            .onChanged { value in
                let delta = value.magnification - 1
                guard abs(delta) > 0.02 else { return }
                if pinchBase == nil { pinchBase = store.thumbSize }
                guard let base = pinchBase else { return }
                store.thumbSize = min(LibraryStore.thumbSizeRange.upperBound,
                                        max(LibraryStore.thumbSizeRange.lowerBound, base * value.magnification))
            }
            .onEnded { _ in pinchBase = nil }
    }

    private var resolveProgress: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(store.placeResolveDone),
                         total: Double(max(1, store.placeResolveTotal)))
                .progressViewStyle(.linear)
                .frame(width: 160)
            Text("正在解析地点 \(store.placeResolveDone) / \(store.placeResolveTotal)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有带位置信息的照片")
                .font(.system(size: 13, weight: .medium))
            Text("照片需要包含 GPS 信息才会纳入地点统计。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.35), spacing: cardSize * 0.15, alignment: .top)]
    }

    private var groups: [(title: String, clusters: [PlaceCluster])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return store.placeGroups }
        return store.placeGroups.compactMap { group in
            let matches = group.clusters.filter {
                $0.title.lowercased().contains(trimmed)
                    || ($0.subtitle?.lowercased().contains(trimmed) ?? false)
            }
            return matches.isEmpty ? nil : (group.title, matches)
        }
    }

    // MARK: - 某个地点的照片

    /// 位置详情直接使用聚类里已经带上的照片：不受当前搜索 / 筛选影响，
    /// 也不会因为大图库分页窗口尚未加载而显示为空。
    private func photos(in place: PlaceCluster) -> [PhotoItem] {
        if store.isCloudScope {
            return store.cloudGeoPhotos.filter {
                PlaceClusterBuilder.key(for: $0, granularity: store.placeGranularity).id == place.id
            }
        }
        return place.photos.filter { $0.deletedAt == nil && !$0.isHidden }
    }

    private func placeDetail(_ place: PlaceCluster) -> some View {
        PlaceDetailView(place: place,
                        photos: photos(in: place),
                        onBack: { store.closePlace() },
                        onOpenMap: {
                            if store.isCloudScope {
                                store.setCloudScope(.map)
                            } else {
                                store.navigate(to: store.isSystemScope ? .systemMap : .map)
                            }
                        })
    }
}

private struct PlaceCardView: View {
    let cluster: PlaceCluster
    /// 悬停状态放在卡片内部：滚动时鼠标扫过卡片只重算自己，
    /// 不会因为整页共享一个 hoveredID 而反复重建整个列表。
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            cover
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if cluster.count > 1 {
                        Text("\(cluster.count)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(8)
                    }
                }
                .shadow(color: .black.opacity(isHovered ? 0.28 : 0.12),
                        radius: isHovered ? 14 : 7,
                        y: isHovered ? 8 : 3)

            Text(cluster.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Text("\(cluster.count.formatted()) 张照片")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var cover: some View {
        Rectangle()
            .fill(Color.clear)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let photo = cluster.cover {
                    PhotoThumbnailView(photo: photo, purpose: .cover(200))
                } else {
                    LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.2)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.primary.opacity(0.55))
                    }
                }
            }
            .clipped()
    }
}
