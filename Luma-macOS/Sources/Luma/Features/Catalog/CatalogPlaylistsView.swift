import SwiftUI

// MARK: - 片单页

/// 片单分页：上半是聚合片单（关键字跨源动态聚合），下半是手动片单。
struct CatalogPlaylistsView: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel

    @State private var showCreateSmart = false
    @State private var showCreateManual = false
    @State private var manualName = ""

    var body: some View {
        Group {
            switch catalog.openPlaylistPage {
            case .manual(let id):
                CatalogPlaylistDetailView(playlistID: id) { closeDetail() }
                    .environmentObject(catalog)
                    .transition(.opacity)
            case .smart(let id):
                CatalogSmartPlaylistDetailView(playlistID: id) { closeDetail() }
                    .environmentObject(catalog)
                    .transition(.opacity)
            case nil:
                list
            }
        }
        .task { refreshSmartPlaylists() }
        .sheet(isPresented: $showCreateSmart) {
            CreateSmartPlaylistSheet { name, query in
                let id = catalog.createSmartPlaylist(name: name, query: query)
                showCreateSmart = false
                catalog.openPlaylistPage = .smart(id)
            } onCancel: {
                showCreateSmart = false
            }
        }
        .sheet(isPresented: $showCreateManual) {
            manualNameSheet
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                smartSection
                manualSection
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.automatic)
    }

    private func closeDetail() {
        withAnimation(.easeOut(duration: 0.18)) { catalog.openPlaylistPage = nil }
    }

    // MARK: 头部

    private var header: some View {
        // 分页标题在窗口工具栏：这里只保留说明与新建入口。
        HStack(alignment: .center, spacing: 14) {
            Text("聚合片单按关键字跨源聚合；手动片单可以排序、设封面、整单连播。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Button {
                showCreateSmart = true
            } label: {
                Label("新建聚合片单", systemImage: "sparkles")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                manualName = ""
                showCreateManual = true
            } label: {
                Label("新建片单", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: 聚合片单

    @ViewBuilder
    private var smartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("聚合片单",
                          subtitle: "输入关键字，各平台结果实时聚合",
                          symbol: "sparkles")
            if catalog.smartPlaylists.isEmpty {
                Button {
                    showCreateSmart = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("试试「中文字幕 校园 90 年代」")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("不用手动收藏：规则会在每次打开时重新跨源聚合。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12),
                                          style: StrokeStyle(lineWidth: 0.8, dash: [5, 4]))
                    }
                }
                .buttonStyle(.plain)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    ForEach(catalog.smartPlaylists) { playlist in
                        smartCard(playlist)
                    }
                }
            }
        }
    }

    private func smartCard(_ playlist: CatalogSmartPlaylist) -> some View {
        let groups = catalog.smartResults[playlist.id] ?? []
        let loading = catalog.smartLoading.contains(playlist.id)
        let newCount = catalog.smartNewIDs[playlist.id]?.count ?? 0
        let covers = groupCovers(groups)
        let plan = CatalogQueryPlan.parse(playlist.query)
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { catalog.openPlaylistPage = .smart(playlist.id) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    mosaic(covers)
                    LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.62)],
                                   startPoint: .center, endPoint: .bottom)
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text("聚合")
                            .font(.system(size: 9, weight: .bold))
                        if newCount > 0, !loading {
                            Text("新 \(newCount)")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.red.opacity(0.9), in: Capsule(style: .continuous))
                        }
                        Spacer()
                        if loading {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Text("\(catalog.smartPlaylistCount(playlist.id)) 部")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                }
                .frame(height: 128)
                .clipped()

                VStack(alignment: .leading, spacing: 6) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    CatalogFlowLayout(spacing: 5, lineSpacing: 4) {
                        ForEach(plan.chips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1),
                                            in: Capsule(style: .continuous))
                        }
                    }
                    Text("\(groups.count) 个源 · 打开时重新聚合")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
            }
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("播放全部") { catalog.playSmartPlaylist(playlist.id) }
            Button("重新聚合") { catalog.refreshSmartPlaylist(playlist.id) }
            Divider()
            Button("删除聚合片单", role: .destructive) { catalog.deleteSmartPlaylist(playlist.id) }
        }
        .help(playlist.query)
    }

    // MARK: 手动片单

    @ViewBuilder
    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("手动片单",
                          subtitle: "拖拽排序 · 设封面 · 整单连播",
                          symbol: "rectangle.stack.fill")
            if catalog.playlists.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("在任意源的卡片上右键「加入片单」，收藏会汇总到这里。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("新建片单") {
                        manualName = ""
                        showCreateManual = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
                .padding(16)
                .background(Color.primary.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    ForEach(catalog.playlists) { playlist in
                        manualCard(playlist)
                    }
                }
            }
        }
    }

    private func manualCard(_ playlist: CatalogPlaylist) -> some View {
        let covers = playlist.entries.prefix(3).compactMap { entry -> (CatalogSource, String)? in
            guard let source = catalog.sources.first(where: { $0.id == entry.sourceID }) else { return nil }
            return (source, entry.coverURL)
        }
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { catalog.openPlaylistPage = .manual(playlist.id) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    if let first = covers.first {
                        CatalogArtworkImage(source: first.0, urlString: first.1, cornerRadius: 0)
                    } else {
                        LinearGradient(colors: [Color.accentColor.opacity(0.75),
                                                Color.accentColor.opacity(0.3)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                   startPoint: .center, endPoint: .bottom)
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(playlist.entries.count) 部")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Spacer()
                        if covers.count > 1 {
                            Text("+\(covers.count - 1)")
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(.white.opacity(0.18), in: Capsule(style: .continuous))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                }
                .frame(height: 120)
                .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(playlist.entries.isEmpty ? "空片单" : "整单连播")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        ForEach(sourceDots(playlist), id: \.self) { sourceID in
                            if let source = catalog.sources.first(where: { $0.id == sourceID }) {
                                Circle()
                                    .fill(source.kind.sidebarTint)
                                    .frame(width: 5, height: 5)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("整单连播") { catalog.playPlaylist(playlist.id) }
            Button("打开片单") { withAnimation(.easeOut(duration: 0.18)) { catalog.openPlaylistPage = .manual(playlist.id) } }
            Divider()
            Button("删除片单", role: .destructive) { catalog.deletePlaylist(playlist.id) }
        }
        .help(playlist.name)
    }

    private func sourceDots(_ playlist: CatalogPlaylist) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for entry in playlist.entries where seen.insert(entry.sourceID).inserted {
            result.append(entry.sourceID)
        }
        return Array(result.prefix(4))
    }

    // MARK: 新建手动片单

    private var manualNameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建片单")
                .font(.system(size: 15, weight: .semibold))
            TextField("片单名称", text: $manualName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createManual)
            HStack {
                Spacer()
                Button("取消") { showCreateManual = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("创建", action: createManual)
                    .buttonStyle(.borderedProminent)
                    .disabled(manualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func createManual() {
        let id = catalog.createPlaylist(name: manualName)
        showCreateManual = false
        catalog.openPlaylistPage = .manual(id)
    }

    // MARK: 工具

    private func groupCovers(_ groups: [CatalogGlobalResult])
        -> [(CatalogSource, String)] {
        var result: [(CatalogSource, String)] = []
        for group in groups {
            guard let source = catalog.sources.first(where: { $0.id == group.sourceID }) else { continue }
            for item in group.items where !item.coverURL.isEmpty {
                result.append((source, item.coverURL))
                if result.count >= 4 { return result }
            }
        }
        return result
    }

    private func mosaic(_ covers: [(CatalogSource, String)]) -> some View {
        GeometryReader { proxy in
            let half = (proxy.size.width - 1) / 2
            let cellHeight = (proxy.size.height - 1) / 2
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    mosaicCell(covers, index: 0, size: CGSize(width: half, height: cellHeight))
                    mosaicCell(covers, index: 1, size: CGSize(width: half, height: cellHeight))
                }
                HStack(spacing: 1) {
                    mosaicCell(covers, index: 2, size: CGSize(width: half, height: cellHeight))
                    mosaicCell(covers, index: 3, size: CGSize(width: half, height: cellHeight))
                }
            }
        }
    }

    @ViewBuilder
    private func mosaicCell(_ covers: [(CatalogSource, String)], index: Int,
                            size: CGSize) -> some View {
        if covers.indices.contains(index) {
            CatalogArtworkImage(source: covers[index].0,
                                urlString: covers[index].1,
                                cornerRadius: 0)
                .frame(width: size.width, height: size.height)
        } else {
            Color.primary.opacity(0.06)
                .frame(width: size.width, height: size.height)
        }
    }

    /// 先用上次缓存的结果铺卡片，再在后台重新聚合，避免每次进来先空一片。
    private func refreshSmartPlaylists() {
        for playlist in catalog.smartPlaylists
        where !catalog.smartLoading.contains(playlist.id) {
            catalog.refreshSmartPlaylist(playlist.id)
        }
    }

    private func sectionHeader(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

// MARK: - 新建聚合片单

private struct CreateSmartPlaylistSheet: View {
    let onCreate: (String, String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var query = ""

    private var plan: CatalogQueryPlan {
        CatalogQueryPlan.parse(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("新建聚合片单")
                    .font(.system(size: 16, weight: .semibold))
                Text("输入关键字，片单每次打开都会重新跨源聚合。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("名称（可留空）")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("例如：中文字幕校园", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("关键字 / 条件")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("例如：中文字幕 校园 90 年代", text: $query)
                    .textFieldStyle(.roundedBorder)
            }

            if !plan.chips.isEmpty {
                HStack(spacing: 6) {
                    Text("会按")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ForEach(plan.chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Color.accentColor.opacity(0.11),
                                        in: Capsule(style: .continuous))
                    }
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("创建并聚合") {
                    onCreate(name, query)
                }
                .buttonStyle(.borderedProminent)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

// MARK: - 聚合片单详情

struct CatalogSmartPlaylistDetailView: View {
    let playlistID: UUID
    /// 非空表示嵌在片单页里展示：左上角给「返回」，不再用弹窗。
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var catalog: CatalogBrowserModel
    @Environment(\.dismiss) private var dismiss

    private var isEmbedded: Bool { onClose != nil }

    private var playlist: CatalogSmartPlaylist? {
        catalog.smartPlaylists.first { $0.id == playlistID }
    }

    private var groups: [CatalogGlobalResult] {
        catalog.smartResults[playlistID] ?? []
    }

    private var loading: Bool {
        catalog.smartLoading.contains(playlistID)
    }

    private var totalCount: Int {
        groups.reduce(0) { $0 + $1.items.count }
    }

    /// 相对上一次聚合新增的条目：排最前并高亮。
    private var newIDs: Set<String> {
        Set(catalog.smartNewIDs[playlistID] ?? [])
    }

    /// 头图：第一个源的封面做模糊底。
    private var heroCover: (CatalogSource, String)? {
        for group in groups {
            guard let source = catalog.sources.first(where: { $0.id == group.sourceID }),
                  let item = group.items.first(where: { !$0.coverURL.isEmpty })
            else { continue }
            return (source, item.coverURL)
        }
        return nil
    }

    var body: some View {
        ZStack {
            LumaAmbientBackground(intensity: 0.6)
            VStack(alignment: .leading, spacing: 0) {
                hero
                content
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isEmbedded {
                closeButton.padding(16)
            }
        }
        .frame(width: isEmbedded ? nil : 820, height: isEmbedded ? nil : 660)
        .task { catalog.refreshSmartPlaylist(playlistID) }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(height: 176)
                .overlay {
                    if let cover = heroCover {
                        CatalogArtworkImage(source: cover.0, urlString: cover.1, cornerRadius: 0)
                            .blur(radius: 34, opaque: true)
                            .opacity(0.55)
                            .scaleEffect(1.14)
                    }
                }
                .clipped()
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.16), .black.opacity(0.62)],
                                   startPoint: .top, endPoint: .bottom)
                }

            HStack(alignment: .bottom, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.10)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.26), lineWidth: 0.8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("聚合片单")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(playlist?.name ?? "聚合片单")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let plan = playlist.map({ CatalogQueryPlan.parse($0.query) }) {
                            ForEach(plan.chips, id: \.self) { chip in
                                Text(chip)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.white.opacity(0.16),
                                                in: Capsule(style: .continuous))
                            }
                        }
                        if loading {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else if !groups.isEmpty {
                            statChip(symbol: "film.stack", text: "\(totalCount) 部")
                            statChip(symbol: "antenna.radiowaves.left.and.right",
                                     text: "\(groups.count) 个源")
                            if !newIDs.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkle")
                                        .font(.system(size: 8.5, weight: .bold))
                                    Text("\(newIDs.count) 条新内容")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.red.opacity(0.85), in: Capsule(style: .continuous))
                                .shadow(color: Color.red.opacity(0.35), radius: 5, y: 1)
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button {
                        catalog.playSmartPlaylist(playlistID)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(groups.isEmpty)

                    Button {
                        catalog.refreshSmartPlaylist(playlistID)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("重新聚合")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .padding(.top, 26)
        }
    }

    private func statChip(symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white.opacity(0.14), in: Capsule(style: .continuous))
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if groups.isEmpty {
            VStack(spacing: 10) {
                if loading {
                    ProgressView().controlSize(.small)
                    Text("正在跨源聚合…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("各源都没有找到匹配内容")
                        .font(.system(size: 13, weight: .medium))
                    Text("换一个关键字，或去掉过窄的年份条件。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        let freshCount = group.items.filter {
                            newIDs.contains("\(group.sourceID.uuidString)|\($0.id)")
                        }.count
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 7) {
                                if let source = catalog.sources.first(where: {
                                    $0.id == group.sourceID
                                }) {
                                    Circle()
                                        .fill(source.kind.sidebarTint)
                                        .frame(width: 5, height: 5)
                                    Text(source.name)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                Text("\(group.items.count) 条")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                if freshCount > 0 {
                                    Text("新 \(freshCount)")
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.red.opacity(0.86),
                                                    in: Capsule(style: .continuous))
                                }
                                Spacer()
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200),
                                                         spacing: 12)],
                                      alignment: .leading, spacing: 14) {
                                ForEach(group.items) { item in
                                    if let source = catalog.sources.first(where: {
                                        $0.id == group.sourceID
                                    }) {
                                        cell(item, source: source,
                                             isNew: newIDs.contains(
                                                "\(group.sourceID.uuidString)|\(item.id)"))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
    }

    private func cell(_ item: CatalogItem, source: CatalogSource,
                      isNew: Bool = false) -> some View {
        Button {
            catalog.playRemote(sourceID: source.id, item: item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(CGFloat(source.posterRatio), contentMode: .fit)
                    .overlay {
                        CatalogArtworkImage(source: source, urlString: item.coverURL,
                                            cornerRadius: 9)
                    }
                    .overlay(alignment: .topLeading) {
                        if isNew {
                            Text("新")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.red.opacity(0.9), in: Capsule(style: .continuous))
                                .shadow(color: Color.red.opacity(0.4), radius: 4, y: 1)
                                .padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isNew ? Color.red.opacity(0.55)
                                                : Color.primary.opacity(0.07),
                                          lineWidth: isNew ? 1.1 : 0.6)
                    }
                Text(item.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isNew ? Color.primary.opacity(0.95)
                                           : Color.primary.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 28, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            CatalogPlaylistMenu(source: source, item: item)
        }
        .help(item.title)
    }
}
