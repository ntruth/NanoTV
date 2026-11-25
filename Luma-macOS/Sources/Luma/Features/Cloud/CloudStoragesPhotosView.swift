import SwiftUI
import Foundation
import LumaContentCore

/// 存储图库：把所有网盘索引里的照片汇成一条时间线。
/// 与「存储影院」并列——影院聚合视频，这里聚合图片；点图直接回到它在网盘里的目录。
struct CloudStoragesPhotosView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel

    @State private var items: [CloudAggregatedPhoto] = []
    @State private var indexStates: [UUID: MetadataStore.CloudIndexState] = [:]
    @State private var loading = false
    @State private var selectedMountID: UUID?
    @State private var mediaFilter: MediaFilter = .all
    @State private var sort: SortOrder = .recent
    @State private var layout: Layout = .timeline
    @State private var query = ""
    @State private var preview: CloudAggregatedPhoto?
    @State private var reloadToken = 0
    /// 载入代次：连续触发重载时只让最后一次写回。
    @State private var loadSeq = 0

    /// 来源卡片的固定尺寸与内边距：进度条按这个宽度算，避免任何弹性布局撑破卡片。
    private static let mountTileWidth: CGFloat = 152
    private static let mountTileContentWidth: CGFloat = 132

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

    enum SortOrder: String, CaseIterable, Identifiable {
        case recent, oldest, name, size
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recent: return "最近"
            case .oldest: return "最早"
            case .name: return "名称"
            case .size: return "大小"
            }
        }
        var symbol: String {
            switch self {
            case .recent: return "arrow.down"
            case .oldest: return "arrow.up"
            case .name: return "textformat"
            case .size: return "externaldrive"
            }
        }
    }

    enum Layout: String, CaseIterable, Identifiable {
        case timeline, grid
        var id: String { rawValue }
        var title: String {
            switch self {
            case .timeline: return "时间线"
            case .grid: return "网格"
            }
        }
        var symbol: String {
            switch self {
            case .timeline: return "calendar.day.timeline.left"
            case .grid: return "square.grid.3x3"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                console

                if cloud.mounts.isEmpty {
                    LumaEmptyState(symbol: "photo.on.rectangle.angled",
                                   title: "还没有可聚合的图片",
                                   message: "接入网络存储并扫描后，各网盘的图片会汇成一条时间线。",
                                   style: .card,
                                   actions: [LumaEmptyAction(title: "接入存储",
                                                             symbol: "plus") {
                                       store.presentCloudWizard()
                                   }])
                } else if filteredItems.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: reloadKey) { await reload() }
        .sheet(item: $preview) { item in
            CloudAggregatePhotoPreview(item: item) {
                openInMount(item)
                preview = nil
            }
        }
    }

    private var reloadKey: String { "\(reloadToken)-\(cloud.mounts.count)" }

    // MARK: - 控制台

    private var console: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 122), spacing: 10)],
                      alignment: .leading,
                      spacing: 10) {
                CloudHubStatPod(title: "存储", value: "\(cloud.mounts.count)", unit: "个",
                                detail: "已接入的网盘",
                                symbol: "externaldrive.connected.to.line.below",
                                tint: Color.accentColor)
                CloudHubStatPod(title: "已索引", value: indexedMedia.formatted(), unit: "项",
                                detail: "所有存储的扫描结果",
                                symbol: "checkmark.seal.fill",
                                tint: LumaBrand.mint)
                CloudHubStatPod(title: "已聚合", value: items.count.formatted(), unit: "张",
                                detail: "所有存储索引里的全部媒体",
                                symbol: "photo.stack",
                                tint: LumaBrand.violet)
                CloudHubStatPod(title: "照片", value: photoCount.formatted(), unit: "张",
                                detail: "已载入的静态图片",
                                symbol: "photo.fill",
                                tint: LumaBrand.amber)
                CloudHubStatPod(title: "视频", value: videoCount.formatted(), unit: "个",
                                detail: "已载入的视频文件",
                                symbol: "video.fill",
                                tint: LumaBrand.coral)
            }

            mountDeck

            bar
        }
        .padding(16)
        .modifier(CloudAggregatePanel())
    }

    /// 图2 式的一条控制带：类型 → 姿态 → 排序 → 搜索。
    private var bar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                mediaSegments
                Divider().frame(height: 20)
                layoutSegments
                Divider().frame(height: 20)
                sortMenu
                searchField
                Spacer(minLength: 0)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: - 来源平铺

    /// 重新载入：原来在页头右侧，页头删掉后收进「来源」这一行的尾部，贴着数字走。
    private var reloadButton: some View {
        Button {
            reloadToken += 1
        } label: {
            HStack(spacing: 4) {
                if loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(loading ? "载入中" : "重新载入")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .help("从各存储的索引重新载入全部照片与视频")
    }

    /// 来源平铺：每个存储一张小卡，横向铺开；点一张只看它，不再收进下拉菜单。
    /// 卡片里的细条是它在本次聚合里的占比，一眼能看出哪个存储贡献最多。
    private var mountDeck: some View {
        let counts = mountPhotoCounts
        let peak = max(1, counts.values.max() ?? 1)
        let total = max(1, items.count)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("来源")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("点一张只看该存储")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text("\(filteredItems.count.formatted()) / \(items.count.formatted())")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                reloadButton
                    .padding(.leading, 4)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    mountTile(id: nil,
                              title: "全部存储",
                              count: items.count,
                              peak: peak,
                              total: total,
                              tint: Color.accentColor,
                              symbol: "square.stack.3d.up.fill",
                              brand: nil)
                    ForEach(cloud.mounts) { mount in
                        mountTile(id: mount.id,
                                  title: mount.name,
                                  count: counts[mount.id] ?? 0,
                                  peak: peak,
                                  total: total,
                                  tint: mountTint(mount.kind),
                                  symbol: mount.kind.symbolName,
                                  brand: mount.kind.brand)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollClipDisabled()
        }
    }

    private func mountTile(id: UUID?,
                           title: String,
                           count: Int,
                           peak: Int,
                           total: Int,
                           tint: Color,
                           symbol: String,
                           brand: CloudBrand?) -> some View {
        let active = selectedMountID == id
        let share = Double(count) / Double(max(1, peak))
        let percent = Int((Double(count) / Double(max(1, total)) * 100).rounded())
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { selectedMountID = id }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if let brand {
                        CloudBrandIcon(brand: brand, size: 18)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(active ? Color.white : tint)
                            .frame(width: 18, height: 18)
                            .background(active ? Color.white.opacity(0.18) : tint.opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if active {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(count.formatted())
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(active ? Color.white : Color.primary)
                    Text("张")
                        .font(.system(size: 8.5))
                        .foregroundStyle(active ? Color.white.opacity(0.7) : Color.secondary)
                    Spacer(minLength: 4)
                    Text("\(percent)%")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(active ? Color.white.opacity(0.75) : Color.secondary.opacity(0.7))
                }
                // 用固定轨道宽度算填充，不用 GeometryReader：
                // 横向 ScrollView 下 GeometryReader 会拿到超宽的提议值，进度条会溢出卡片。
                ZStack(alignment: .leading) {
                    Capsule().fill(active ? Color.white.opacity(0.20) : tint.opacity(0.14))
                    Capsule()
                        .fill(active ? Color.white.opacity(0.9) : tint)
                        .frame(width: max(3, Self.mountTileContentWidth * min(1, share)))
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: Self.mountTileWidth, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.92), tint.opacity(0.70)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                } else {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(active ? Color.white.opacity(0.18) : Color.primary.opacity(0.08),
                                  lineWidth: 0.7)
            }
            .shadow(color: active ? tint.opacity(0.35) : .clear, radius: 8, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(active ? "当前只看「\(title)」" : "只看「\(title)」")
    }

    /// 每个存储在本次聚合里落进来的张数：平铺卡与占比条共用一次遍历。
    private var mountPhotoCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for item in items { counts[item.mountID, default: 0] += 1 }
        return counts
    }

    /// 存储类型 → 卡片主色：沿用网盘自身的视觉语言，同一家一眼认出。
    private func mountTint(_ kind: CloudKind) -> Color {
        switch kind {
        case .webdav: return LumaBrand.cyan
        case .smb: return LumaBrand.mint
        case .aliyun: return Color(red: 0.32, green: 0.64, blue: 1.00)
        case .baidu: return Color(red: 0.22, green: 0.48, blue: 0.96)
        case .quark: return LumaBrand.violet
        case .pan115: return LumaBrand.amber
        }
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
                    Label(order.title, systemImage: sort == order ? "checkmark" : order.symbol)
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
        .help("排序方式")
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索文件名 / 存储", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit {
                    store.startModuleSearch(.cloud, query: query)
                }
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

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if loading && items.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在读各存储的索引…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else if layout == .timeline {
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
        } else {
            photoGrid(filteredItems)
        }
    }

    private func photoGrid(_ photos: [CloudAggregatedPhoto]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 168), spacing: 10)],
                  alignment: .leading,
                  spacing: 10) {
            ForEach(photos) { item in
                CloudAggregatePhotoCard(item: item) {
                    preview = item
                }
            }
        }
    }

    private var emptyState: some View {
        LumaEmptyState(symbol: "photo.on.rectangle.angled",
                       title: items.isEmpty ? "还没有可聚合的图片" : "没有匹配的图片",
                       message: items.isEmpty
                           ? "先在「存储」里让网盘完成一次扫描，索引里的照片与视频会汇总到这里。"
                           : "换一个存储、类型或关键词试试。",
                       actions: items.isEmpty && !cloud.mounts.isEmpty
                           ? [LumaEmptyAction(title: "去存储页扫描", symbol: "arrow.clockwise") {
                               cloud.setStoragesTab(.storages)
                           }]
                           : [])
    }

    // MARK: - 数据

    private var indexedMedia: Int {
        indexStates.values.reduce(0) { $0 + $1.mediaCount }
    }

    private var photoCount: Int { items.filter { !$0.isVideo }.count }
    private var videoCount: Int { items.filter(\.isVideo).count }

    private var filteredItems: [CloudAggregatedPhoto] {
        var result = items
        if let id = selectedMountID {
            result = result.filter { $0.mountID == id }
        }
        switch mediaFilter {
        case .all: break
        case .photos: result = result.filter { !$0.isVideo }
        case .videos: result = result.filter(\.isVideo)
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(keyword)
                    || $0.mountName.localizedCaseInsensitiveContains(keyword)
                    || ($0.folder ?? "").localizedCaseInsensitiveContains(keyword)
            }
        }
        switch sort {
        case .recent: result.sort { $0.date > $1.date }
        case .oldest: result.sort { $0.date < $1.date }
        case .name: result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: result.sort { $0.size > $1.size }
        }
        return result
    }

    private var dayGroups: [(date: Date, items: [CloudAggregatedPhoto])] {
        let calendar = Calendar.current
        var buckets: [Date: [CloudAggregatedPhoto]] = [:]
        for item in filteredItems {
            let day = calendar.startOfDay(for: item.date)
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

    private func openInMount(_ item: CloudAggregatedPhoto) {
        store.navigate(to: .cloudMount(item.mountID))
        if let folder = item.folder, !folder.isEmpty {
            store.selectCloudFolder(path: folder)
        }
    }

    private func reload() async {
        loadSeq += 1
        let seq = loadSeq
        let mounts = cloud.mounts
        indexStates = store.cloudIndexStates()
        guard !mounts.isEmpty else {
            items = []
            loading = false
            return
        }
        loading = true
        let meta = store.metadataStore
        let favorites = store.cloudFavorites
        let keywords = store.cloudKeywords
        let marks = store.cloudMarks
        let viewedAt = cloud.viewedAt

        var collected: [CloudAggregatedPhoto] = []
        for mount in mounts {
            let signature = LibraryStore.scopeSignature(mount)
            let pairs = await Task.detached(priority: .utility) { () -> [(PhotoItem, String?)] in
                guard let result = LibraryStore.loadCloudAlbumSnapshotAndPhotos(
                    store: meta,
                    mount: mount,
                    signature: signature,
                    favorites: favorites,
                    keywords: keywords,
                    marks: marks,
                    viewedAt: viewedAt
                ) else { return [] }
                let snapshot = result.0
                let photos = result.1
                var folderByPath: [String: String] = [:]
                for record in snapshot.records {
                    if let folder = record.folderPath, !folder.isEmpty {
                        folderByPath[record.path] = folder
                    }
                }
                // 聚合页读取每个存储索引里的全部媒体，不再截断；
                // 数量很多时靠下面的 LazyVGrid 与按天分组懒渲染。
                let sorted = photos.sorted { $0.capturedAt > $1.capturedAt }
                return sorted.map { photo in
                    (photo, photo.cloudPath.flatMap { folderByPath[$0] })
                }
            }.value
            collected.append(contentsOf: pairs.map {
                CloudAggregatedPhoto(photo: $0.0, folder: $0.1, mount: mount)
            })
            if seq != loadSeq { return }
        }
        items = collected.sorted { $0.date > $1.date }
        loading = false
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}

// MARK: - 聚合条目

struct CloudAggregatedPhoto: Identifiable {
    let photo: PhotoItem
    let folder: String?
    let mount: CloudMount

    var id: UUID { photo.id }
    var mountID: UUID { mount.id }
    var mountName: String { mount.name }
    var name: String { photo.originalName.isEmpty ? photo.filename : photo.originalName }
    var isVideo: Bool { photo.isVideo }
    var size: Int64 { photo.fileSize }
    var date: Date { photo.capturedAt }
}

// MARK: - 卡片

private struct CloudAggregatePhotoCard: View {
    let item: CloudAggregatedPhoto
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
                            Text(item.name)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Circle()
                                .fill(item.mount.kind.hubTint)
                                .frame(width: 4.5, height: 4.5)
                            Text(item.mountName)
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                        }
                    }
                    .padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    if item.isVideo {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 7, weight: .bold))
                            Text(Self.duration(item.photo.duration ?? 0))
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule(style: .continuous))
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
        .help("\(item.name) · \(item.mountName)")
    }

    private static func duration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "视频" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 预览

private struct CloudAggregatePhotoPreview: View {
    let item: CloudAggregatedPhoto
    let onOpenInMount: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(item.mountName)
                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                        if item.size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("在存储中打开") { onOpenInMount() }
                    .controlSize(.small)
                Button("关闭") { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider().opacity(0.4)

            PhotoThumbnailView(photo: item.photo, purpose: .cover(1400))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.92))
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - 面板样式

/// 与网络存储其它控制台一致：渐变面板 + 细描边 + 四角螺钉。
private struct CloudAggregatePanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.07),
                                                  Color.primary.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.14),
                                                          .clear,
                                                          .black.opacity(0.12)],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing),
                                  lineWidth: 0.9)
            }
            .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
    }
}
