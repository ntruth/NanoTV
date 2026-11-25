import SwiftUI

/// 系统「照片」图库自己的精选集：只读汇总当前系统图库里的收藏、视频、截屏等分类。
/// 与拾光的「精选集」不同，这里不会切换当前图库，数据全部来自 `store.systemPhotos`。
struct SystemCollectionsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var cards: [SystemCollectionSummary.Card] = []
    @State private var isBuilding = true
    @State private var hoveredID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isBuilding {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在汇总系统图库…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 24)
                } else if cards.isEmpty {
                    EmptyStateView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 268, maximum: 380), spacing: 16)],
                              alignment: .leading, spacing: 16) {
                        ForEach(cards) { card in
                            cardView(card)
                                .onHover { hovering in
                                    hoveredID = hovering
                                        ? card.id
                                        : (hoveredID == card.id ? nil : hoveredID)
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: store.contentRevision) {
            await rebuild()
        }
    }

    /// 与拾光「精选集」同一套卡片：拼贴封面 + 渐变叠字 + 左上角图标徽标。
    private func cardView(_ card: SystemCollectionSummary.Card) -> some View {
        Button {
            store.navigate(to: card.target)
        } label: {
            ZStack(alignment: .bottomLeading) {
                if card.samples.isEmpty {
                    LinearGradient(colors: [card.tint.opacity(0.55), card.tint.opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: card.icon)
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(.primary.opacity(0.55))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PhotoMosaicView(photos: card.samples)
                }

                LinearGradient(colors: [.clear, .black.opacity(0.72)],
                               startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(card.subtitle)
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(14)

                VStack {
                    HStack {
                        Image(systemName: card.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(.black.opacity(0.28), in: Circle())
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay {
                                Circle().strokeBorder(card.tint.opacity(0.55), lineWidth: 0.8)
                            }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
            }
            .frame(height: 186)
            .clipShape(RoundedRectangle(cornerRadius: settings.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: settings.cardRadius)
                    .strokeBorder(Color.white.opacity(hoveredID == card.id ? 0.35 : 0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(hoveredID == card.id ? 0.24 : 0.18),
                    radius: hoveredID == card.id ? 14 : 10, y: hoveredID == card.id ? 6 : 4)
            .scaleEffect(hoveredID == card.id && settings.hoverLift ? settings.motion.hoverScale : 1)
            .animation(settings.motion.hover, value: hoveredID)
            .contentShape(RoundedRectangle(cornerRadius: settings.cardRadius))
        }
        .buttonStyle(.plain)
        .help("查看系统图库的\(card.title)")
    }

    private func rebuild() async {
        if cards.isEmpty { isBuilding = true }
        let snapshot: SystemCollectionSnapshot
        if store.systemIndex != nil {
            // 索引模式：按分类各查一次聚合与 4 张样本，放到后台避免卡主线程。
            snapshot = await store.systemCollectionSnapshotAsync()
        } else {
            let photos = store.systemPhotos
            let cutoff = LibraryStore.recentlySavedCutoff
            guard !photos.isEmpty else {
                cards = []
                isBuilding = false
                return
            }
            snapshot = await Task.detached(priority: .utility) {
                SystemCollectionSummary.snapshot(from: photos, savedCutoff: cutoff)
            }.value
        }
        cards = SystemCollectionSummary.cards(from: snapshot)
        isBuilding = false
    }
}

/// 一次遍历得出所有精选集卡片与样本，避免每张卡片各扫一遍十几万张系统照片。
enum SystemCollectionSummary {
    struct Card: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let count: Int
        let samples: [PhotoItem]
        let target: SidebarItem
        let tint: Color
    }

    struct Result {
        let cards: [Card]
    }

    static func snapshot(from photos: [PhotoItem], savedCutoff: Date) -> SystemCollectionSnapshot {
        var result = SystemCollectionSnapshot()
        for photo in photos {
            guard photo.deletedAt == nil, !photo.isHidden else { continue }
            func add(_ key: String) {
                result.counts[key, default: 0] += 1
                if (result.samples[key]?.count ?? 0) < 4 {
                    result.samples[key, default: []].append(photo)
                }
            }
            if photo.isFavorite { add("favorites") }
            if photo.isVideo { add("videos") }
            if !photo.isVideo, photo.kind == .selfie { add("selfies") }
            if photo.kind == .panorama { add("panoramas") }
            if photo.kind == .screenshot { add("screenshots") }
            if photo.addedAt >= savedCutoff { add("recentlySaved") }
            if !photo.isVideo, photo.editedAt != nil || photo.hasEdits { add("edited") }
        }
        return result
    }

    /// 把汇总快照映射成卡片（数量与样本均来自快照）。
    static func cards(from snapshot: SystemCollectionSnapshot) -> [Card] {
        let definitions: [(String, String, String, String, Color, SidebarItem)] = [
            ("favorites", "个人收藏", "项", "heart.fill", .pink, .systemFavorites),
            ("videos", "视频", "个", "video.fill", .purple, .systemVideos),
            ("selfies", "自拍", "项", "person.crop.square", .orange, .systemSelfies),
            ("panoramas", "全景照片", "项", "pano", .indigo, .systemPanoramas),
            ("screenshots", "截屏", "项", "camera.viewfinder", .teal, .systemScreenshots),
            ("recentlySaved", "最近保存", "项", "square.and.arrow.down", .blue, .systemRecentlySaved),
            ("edited", "最近编辑", "项", "slider.horizontal.3", .gray, .systemEdited)
        ]
        return definitions.map { definition in
            let count = snapshot.counts[definition.0] ?? 0
            return Card(id: definition.0,
                        title: definition.1,
                        subtitle: "\(count) \(definition.2)",
                        icon: definition.3,
                        count: count,
                        samples: snapshot.samples[definition.0] ?? [],
                        target: definition.5,
                        tint: definition.4)
        }
    }
}
