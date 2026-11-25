import SwiftUI
import AppKit
import Foundation
import LumaContentCore

/// 图库分区的分页：资源 / 照片 / 收藏。三者都是「多个图库」的聚合视图。
enum LibraryHubTab: String, CaseIterable, Identifiable {
    case resources
    case photos
    case favorites

    static let storageKey = "library.hubTab.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resources: return "资源"
        case .photos: return "照片"
        case .favorites: return "收藏"
        }
    }

    var symbol: String {
        switch self {
        case .resources: return "photo.stack"
        case .photos: return "photo.on.rectangle.angled"
        case .favorites: return "heart.fill"
        }
    }
}

// MARK: - 工具栏分页

/// 图库分区的分页胶囊：资源 / 照片 / 收藏，与其它 Hub 同一套工具栏样式。
struct LibraryHubTabs: View {
    @EnvironmentObject private var store: LibraryStore
    @AppStorage(LibraryHubTab.storageKey) private var tabRaw = LibraryHubTab.resources.rawValue
    @Namespace private var tabNamespace

    private var tab: LibraryHubTab { LibraryHubTab(rawValue: tabRaw) ?? .resources }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LibraryHubTab.allCases) { item in
                tabButton(item)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tabButton(_ item: LibraryHubTab) -> some View {
        let active = tab == item
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                tabRaw = item.rawValue
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .fixedSize()
                Text(item.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let badge = badge(for: item), badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(active ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(active ? Color.white.opacity(0.92)
                                           : Color.primary.opacity(0.08),
                                    in: Capsule(style: .continuous))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if active {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "library-hub-tab", in: tabNamespace)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    private func badge(for item: LibraryHubTab) -> Int? {
        switch item {
        case .resources:
            return store.systemLibraries.count + 1
        case .photos, .favorites:
            return nil
        }
    }
}

// MARK: - 聚合数据

/// 多个图库的聚合读取：每个图库各自的体量 + 最近照片 / 收藏。
/// 外接图库直连 Photos.sqlite（只读、不建索引），App 自己的图库沿用内存数据。
@MainActor
final class LibraryAggregateModel: ObservableObject {
    struct LibrarySummary: Identifiable {
        let id: String
        let name: String
        let path: String
        let isNative: Bool
        let isAppContainer: Bool
        var photos: Int
        var videos: Int
        var albums: Int
        var folders: Int
        var updatedAt: Date?
        var error: String?
        /// 打开过、但不是当前容器的 App 图库：点进去等于切换 App 图库。
        var isOtherAppLibrary: Bool = false
    }

    struct Item: Identifiable {
        let photo: PhotoItem
        let libraryID: String
        let libraryName: String
        var id: String { "\(libraryID)|\(photo.id.uuidString)" }
    }

    private struct Target {
        let id: String
        let name: String
        let path: String
        let isNative: Bool
        let isAppContainer: Bool
        var isOtherAppLibrary: Bool = false
    }

    private struct Loaded {
        let summary: LibrarySummary
        let items: [Item]
        let favorites: [Item]
    }

    @Published private(set) var summaries: [LibrarySummary] = []
    @Published private(set) var items: [Item] = []
    @Published private(set) var favorites: [Item] = []
    @Published private(set) var loading = false

    private var didLoad = false
    private var loadSeq = 0

    /// 每个图库参与聚合的最近条目数：总览只做「最近」，整库浏览仍然进具体图库。
    private static let photoLimit = 300
    private static let favoriteLimit = 160

    func load(store: LibraryStore, force: Bool = false) async {
        guard !loading else { return }
        if didLoad, !force { return }
        loading = true
        loadSeq += 1
        let token = loadSeq

        let targets = Self.targets(store: store)
        var loadedSummaries: [LibrarySummary] = []
        var loadedItems: [Item] = []
        var loadedFavorites: [Item] = []

        for target in targets {
            if target.isNative {
                if let loaded = await Task.detached(priority: .utility, operation: {
                    Self.loadNative(target)
                }).value {
                    loadedSummaries.append(loaded.summary)
                    loadedItems.append(contentsOf: loaded.items)
                    loadedFavorites.append(contentsOf: loaded.favorites)
                } else {
                    loadedSummaries.append(LibrarySummary(id: target.id,
                                                          name: target.name,
                                                          path: target.path,
                                                          isNative: true,
                                                          isAppContainer: target.isAppContainer,
                                                          photos: 0, videos: 0,
                                                          albums: 0, folders: 0,
                                                          updatedAt: nil,
                                                          error: "无法读取 Photos.sqlite"))
                }
            } else if target.isOtherAppLibrary {
                // 打开过的其他 App 图库：只读它自己的 Luma.sqlite 取体量，
                // 不加载整库，也不参与照片 / 收藏聚合。
                if let loaded = await Task.detached(priority: .utility, operation: {
                    Self.loadAppLibrary(target)
                }).value {
                    loadedSummaries.append(loaded.summary)
                } else {
                    loadedSummaries.append(LibrarySummary(id: target.id,
                                                          name: target.name,
                                                          path: target.path,
                                                          isNative: false,
                                                          isAppContainer: false,
                                                          photos: 0, videos: 0,
                                                          albums: 0, folders: 0,
                                                          updatedAt: nil,
                                                          error: "无法读取图库数据库",
                                                          isOtherAppLibrary: true))
                }
            } else {
                let live = store.photos.filter { $0.deletedAt == nil && !$0.isHidden }
                let sorted = live.sorted { $0.capturedAt > $1.capturedAt }
                loadedSummaries.append(LibrarySummary(id: target.id,
                                                      name: target.name,
                                                      path: target.path,
                                                      isNative: false,
                                                      isAppContainer: target.isAppContainer,
                                                      photos: live.filter { !$0.isVideo }.count,
                                                      videos: live.filter(\.isVideo).count,
                                                      albums: store.albums.count,
                                                      folders: store.folders.count,
                                                      updatedAt: nil,
                                                      error: nil))
                loadedItems.append(contentsOf: sorted.prefix(Self.photoLimit).map {
                    Item(photo: $0, libraryID: target.id, libraryName: target.name)
                })
                loadedFavorites.append(contentsOf: sorted.filter(\.isFavorite)
                    .prefix(Self.favoriteLimit).map {
                        Item(photo: $0, libraryID: target.id, libraryName: target.name)
                    })
            }
            if token != loadSeq { return }
        }

        summaries = loadedSummaries
        items = loadedItems.sorted { $0.photo.capturedAt > $1.photo.capturedAt }
        favorites = loadedFavorites.sorted { $0.photo.capturedAt > $1.photo.capturedAt }
        loading = false
        didLoad = true
    }

    /// 图库是否正处于浏览状态（资源卡片上的「当前」标记）。
    func isCurrent(_ summary: LibrarySummary, store: LibraryStore) -> Bool {
        if summary.isAppContainer {
            return store.isNativeContainer
                ? (!store.isSystemScope || store.isBrowsingContainerSystemLibrary)
                : !store.isSystemScope
        }
        guard let active = store.systemLibraryPath else { return false }
        return store.isSameSystemLibraryPath(active, summary.path)
    }

    // MARK: 载入

    private static func targets(store: LibraryStore) -> [Target] {
        var list: [Target] = []
        if let url = LibraryPaths.containerLibraryURL {
            let path = url.standardizedFileURL.path
            let name = url.deletingPathExtension().lastPathComponent
            list.append(Target(id: path,
                               name: name.isEmpty ? "图库" : name,
                               path: path,
                               isNative: LibraryPaths.isNativeLibrary(url),
                               isAppContainer: true))
        } else {
            let path = LibraryPaths.root.standardizedFileURL.path
            list.append(Target(id: path, name: "图库", path: path,
                               isNative: false, isAppContainer: true))
        }
        for ref in store.systemLibraries {
            let path = URL(fileURLWithPath: ref.path).standardizedFileURL.path
            guard !list.contains(where: { $0.id == path }) else { continue }
            list.append(Target(id: path,
                               name: ref.name,
                               path: path,
                               isNative: LibraryPaths.isNativeLibrary(URL(fileURLWithPath: path)),
                               isAppContainer: false))
        }
        // 所有打开过的图库都要出现在「全部图库」里：
        // 自己新建的其他 App 图库之前完全不可见，和侧边栏、选取图库对不上。
        for ref in store.knownLibraries {
            let path = URL(fileURLWithPath: ref.path).standardizedFileURL.path
            guard !list.contains(where: { $0.id == path }) else { continue }
            guard !store.systemLibraries.contains(where: { store.isSameSystemLibraryPath($0.path, path) }) else {
                continue
            }
            let url = URL(fileURLWithPath: path)
            let isNative = LibraryPaths.isNativeLibrary(url)
            list.append(Target(id: path,
                               name: ref.name,
                               path: path,
                               isNative: isNative,
                               isAppContainer: false,
                               isOtherAppLibrary: !isNative))
        }
        return list
    }

    /// 直连一个系统照片图库：读合计、相簿 / 文件夹数量与最近照片。
    private nonisolated static func loadNative(_ target: Target) -> Loaded? {
        let url = URL(fileURLWithPath: target.path)
        guard let index = SystemIndex.openDirect(libraryURL: url) else { return nil }
        let totals = index.summary(SystemQuery())
        let meta = SystemIndex.albumMetadata(libraryURL: url)
        let photos = index.page(SystemQuery(), offset: 0, limit: photoLimit)
        let favs = index.page(SystemQuery(scope: .favorites), offset: 0, limit: favoriteLimit)
        let dbURL = url.appendingPathComponent("database/Photos.sqlite")
        let updated = (try? FileManager.default.attributesOfItem(atPath: dbURL.path))?[.modificationDate] as? Date

        let summary = LibrarySummary(id: target.id,
                                     name: target.name,
                                     path: target.path,
                                     isNative: true,
                                     isAppContainer: target.isAppContainer,
                                     photos: max(0, totals.total - totals.videos),
                                     videos: totals.videos,
                                     albums: meta.albums.count,
                                     folders: meta.folders.count,
                                     updatedAt: updated,
                                     error: nil)
        let items = photos.map {
            Item(photo: $0, libraryID: target.id, libraryName: target.name)
        }
        let favorites = favs.map {
            Item(photo: $0, libraryID: target.id, libraryName: target.name)
        }
        return Loaded(summary: summary, items: items, favorites: favorites)
    }

    /// 只读一个打开过的 App 图库的数据库，取体量 / 相簿 / 文件夹数与更新时间。
    /// 不加载整库资产，避免为一次总览把几十 GB 的图库读进内存。
    private nonisolated static func loadAppLibrary(_ target: Target) -> Loaded? {
        let url = URL(fileURLWithPath: target.path)
        guard let dbURL = LibraryPaths.existingMetadataFile(in: url) else { return nil }
        guard let db = try? SQLiteDatabase(path: dbURL.path, readonly: true) else { return nil }
        let totals = (try? db.query("""
            SELECT COUNT(*) AS total,
                   SUM(CASE WHEN kind = 'video' THEN 1 ELSE 0 END) AS videos
            FROM assets WHERE deleted_at IS NULL AND is_hidden = 0
            """))?.first
        let total = totals?["total"]?.int ?? 0
        let videos = totals?["videos"]?.int ?? 0
        let albums = (try? db.query("SELECT COUNT(*) AS c FROM albums"))?.first?["c"]?.int ?? 0
        let folders = (try? db.query("SELECT COUNT(*) AS c FROM folders"))?.first?["c"]?.int ?? 0
        let updated = (try? FileManager.default.attributesOfItem(atPath: dbURL.path))?[.modificationDate] as? Date
        let summary = LibrarySummary(id: target.id,
                                     name: target.name,
                                     path: target.path,
                                     isNative: false,
                                     isAppContainer: false,
                                     photos: max(0, total - videos),
                                     videos: videos,
                                     albums: albums,
                                     folders: folders,
                                     updatedAt: updated,
                                     error: nil,
                                     isOtherAppLibrary: true)
        return Loaded(summary: summary, items: [], favorites: [])
    }
}

// MARK: - 照片 / 收藏聚合

/// 多个图库的照片汇成一条时间线；收藏分页复用同一套筛选与预览。
struct LibraryAggregatePhotosView: View {
    enum Mode {
        case photos
        case favorites
    }

    enum MediaFilter: String, CaseIterable, Identifiable {
        case all, photos, videos
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .photos: return "照片"
            case .videos: return "视频"
            }
        }
    }

    enum Layout: String, CaseIterable, Identifiable {
        case timeline, grid
        var id: String { rawValue }
        var title: String { self == .timeline ? "时间线" : "网格" }
        var symbol: String { self == .timeline ? "calendar.day.timeline.left" : "square.grid.3x3" }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case recent, oldest, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recent: return "最近"
            case .oldest: return "最早"
            case .name: return "名称"
            }
        }
    }

    let mode: Mode

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var aggregate: LibraryAggregateModel

    @State private var selectedLibraryID: String?
    @State private var mediaFilter: MediaFilter = .all
    @State private var layout: Layout = .timeline
    @State private var sort: SortOrder = .recent
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                console

                if filteredItems.isEmpty {
                    emptyState
                } else if layout == .timeline {
                    timeline
                } else {
                    photoGrid(filteredItems)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 页名与张数由顶栏标题区承担，内容区从控制台开始，画面更满。
    }

    private var sourceItems: [LibraryAggregateModel.Item] {
        mode == .photos ? aggregate.items : aggregate.favorites
    }

    /// 「重新载入」并入控制台最右侧：与筛选 / 搜索同一行，不再单独占一条页头。
    private var reloadButton: some View {
        Button {
            Task { await aggregate.load(store: store, force: true) }
        } label: {
            HStack(spacing: 5) {
                if aggregate.loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(aggregate.loading ? "载入中" : "重新载入")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(aggregate.loading)
        .help("重新读取每个图库的照片")
    }

    // MARK: 控制台

    private var console: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                libraryMenu
                Divider().frame(height: 20)
                mediaSegments
                Divider().frame(height: 20)
                layoutSegments
                Divider().frame(height: 20)
                sortMenu
                searchField
                Spacer(minLength: 0)
                reloadButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .scrollClipDisabled()
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(0.07),
                                              Color.primary.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.14),
                                                      .clear,
                                                      .black.opacity(0.12)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing),
                              lineWidth: 0.9)
        }
    }

    private var libraryMenu: some View {
        Menu {
            Button {
                selectedLibraryID = nil
            } label: {
                Label("全部图库 · \(sourceItems.count)", systemImage: selectedLibraryID == nil
                      ? "checkmark" : "photo.stack")
            }
            Divider()
            ForEach(aggregate.summaries) { summary in
                Button {
                    selectedLibraryID = summary.id
                } label: {
                    Label("\(summary.name) · \(count(in: summary.id))",
                          systemImage: selectedLibraryID == summary.id ? "checkmark" : "photo.stack")
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(selectedLibraryName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text("\(filteredItems.count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("按图库筛选")
    }

    private var mediaSegments: some View {
        HStack(spacing: 2) {
            ForEach(MediaFilter.allCases) { filter in
                let active = mediaFilter == filter
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { mediaFilter = filter }
                } label: {
                    Text(filter.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background {
                            if active {
                                Capsule(style: .continuous).fill(Color.accentColor)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .fixedSize()
    }

    private var layoutSegments: some View {
        HStack(spacing: 2) {
            ForEach(Layout.allCases) { item in
                let active = layout == item
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { layout = item }
                } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                        .frame(width: 28, height: 24)
                        .background {
                            if active {
                                Capsule(style: .continuous).fill(Color.accentColor)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortOrder.allCases) { order in
                Button {
                    sort = order
                } label: {
                    Label(order.title, systemImage: sort == order ? "checkmark" : "arrow.up.arrow.down")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(sort.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索文件名 / 图库", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 190, height: 26)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    // MARK: 内容

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(dayGroups, id: \.date) { group in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text(Self.dayFormatter.string(from: group.date))
                            .font(.system(size: 13, weight: .semibold))
                        Text(weekdayText(group.date))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                        Text("\(group.items.count) 张")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    photoGrid(group.items)
                }
            }
        }
    }

    private func photoGrid(_ items: [LibraryAggregateModel.Item]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 168), spacing: 10)],
                  alignment: .leading,
                  spacing: 10) {
            ForEach(items) { item in
                LibraryAggregatePhotoCard(item: item) {
                    openInViewer(item)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: mode == .photos ? "photo.on.rectangle.angled" : "heart")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(mode == .photos ? "还没有可聚合的照片" : "还没有收藏的照片")
                .font(.system(size: 16, weight: .semibold))
            Text(mode == .photos
                 ? "连接到「照片」图库后，各图库最近的照片会汇成一条时间线。"
                 : "在各个图库里标了心形的照片会汇总到这里。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if aggregate.loading {
                ProgressView().controlSize(.small).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    // MARK: 数据

    private var selectedLibraryName: String {
        guard let id = selectedLibraryID,
              let summary = aggregate.summaries.first(where: { $0.id == id }) else { return "全部图库" }
        return summary.name
    }

    private func count(in libraryID: String) -> Int {
        sourceItems.filter { $0.libraryID == libraryID }.count
    }

    private var filteredItems: [LibraryAggregateModel.Item] {
        var result = sourceItems
        if let id = selectedLibraryID {
            result = result.filter { $0.libraryID == id }
        }
        switch mediaFilter {
        case .all:
            break
        case .photos:
            result = result.filter { !$0.photo.isVideo }
        case .videos:
            result = result.filter { $0.photo.isVideo }
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            result = result.filter {
                $0.photo.originalName.localizedCaseInsensitiveContains(keyword)
                    || $0.photo.filename.localizedCaseInsensitiveContains(keyword)
                    || $0.libraryName.localizedCaseInsensitiveContains(keyword)
            }
        }
        switch sort {
        case .recent: result.sort { $0.photo.capturedAt > $1.photo.capturedAt }
        case .oldest: result.sort { $0.photo.capturedAt < $1.photo.capturedAt }
        case .name:
            result.sort {
                $0.photo.originalName.localizedStandardCompare($1.photo.originalName) == .orderedAscending
            }
        }
        return result
    }

    private var dayGroups: [(date: Date, items: [LibraryAggregateModel.Item])] {
        let calendar = Calendar.current
        var buckets: [Date: [LibraryAggregateModel.Item]] = [:]
        for item in filteredItems {
            let day = calendar.startOfDay(for: item.photo.capturedAt)
            buckets[day, default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { ($0, buckets[$0] ?? []) }
    }

    private func weekdayText(_ date: Date) -> String {
        let weekday = date.formatted(.dateTime.weekday(.wide))
        if Calendar.current.isDateInToday(date) { return "今天 · \(weekday)" }
        if Calendar.current.isDateInYesterday(date) { return "昨天 · \(weekday)" }
        return weekday
    }

    /// 点开照片 / 视频：一律用原来的查看器（视频也走同一套播放器），
    /// 不再弹静态预览页。条目可能属于其它图库，先切 / 连到那个库再打开。
    private func openInViewer(_ item: LibraryAggregateModel.Item) {
        guard let summary = aggregate.summaries.first(where: { $0.id == item.libraryID }) else { return }
        store.openSearchResultInLibrary(path: summary.path, pending: .photo(item.photo.id))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}

// MARK: - 卡片

private struct LibraryAggregatePhotoCard: View {
    let item: LibraryAggregateModel.Item
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PhotoThumbnailView(photo: item.photo, purpose: .cover(240))
                }
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(hovering ? 0.62 : 0.30)],
                                   startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 1) {
                        if hovering {
                            Text(item.photo.originalName)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "photo.stack.fill")
                                .font(.system(size: 6.5, weight: .semibold))
                            Text(item.libraryName)
                                .font(.system(size: 8.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    if item.photo.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(hovering ? Color.accentColor.opacity(0.75)
                                               : Color.primary.opacity(0.06),
                                      lineWidth: hovering ? 1.2 : 0.5)
                }
                .scaleEffect(hovering ? 1.018 : 1)
                .shadow(color: .black.opacity(hovering ? 0.20 : 0.06),
                        radius: hovering ? 10 : 4, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(item.photo.originalName) · \(item.libraryName)")
    }
}
