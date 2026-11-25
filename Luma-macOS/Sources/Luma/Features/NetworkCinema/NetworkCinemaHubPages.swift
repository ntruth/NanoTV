import SwiftUI
import AppKit

// MARK: - 影院管理

/// 影院管理：影视源清单 + 聚合读数 + 资料补全 / 缓存维护。
/// 版式参考「网络存储 › 网盘管理」与「网络资源 › 资源」：一屏看完源、内容与维护动作。
struct NetworkCinemaManageView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var model: NetworkCinemaModel

    @State private var hoveringSource: UUID?
    /// 正在编辑的影视源：源行菜单「编辑…」打开。
    @State private var editingSource: CatalogSource?

    private var sources: [CatalogSource] {
        catalog.cinemaSources
    }

    private var enabledSources: [CatalogSource] { sources.filter(\.isEnabled) }

    private var itemsBySource: [UUID: Int] {
        Dictionary(grouping: model.items, by: { $0.source.id }).mapValues(\.count)
    }

    private var cacheText: String {
        ByteCountFormatter.string(fromByteCount: NetworkCinemaModel.cacheBytes(),
                                  countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if sources.isEmpty {
                    emptyState
                } else {
                    sourceSection
                    metadataPanel
                    tipPanel
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LumaAmbientBackground(intensity: 0.55))
        .task { catalog.checkHealth(domain: .networkCinema) }
        .sheet(item: $editingSource) { source in
            CatalogSourceEditorSheet(source: source) { catalog.updateSource($0) }
        }
    }

    /// 影视源导出：导入统一收进「接入影视源」，这里只负责分享给其他人。
    private var transferMenu: some View {
        SourceExportButton(scope: .networkCinema,
                           count: sources.count,
                           exportData: { catalog.exportSourceBundle(domain: .networkCinema) })
    }

    // MARK: 维护动作

    private var sourceActions: some View {
        HStack(spacing: 8) {
            Button {
                store.presentCatalogWizard(domain: .networkCinema)
            } label: {
                Label("接入影视源", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                // 一次只跑一路聚合：模型里的列表是单份的，连续 reload 会互相取消。
                model.reload(sources: catalog.cinemaSources,
                             tab: store.networkCinemaTab.browsesContent
                                 ? store.networkCinemaTab : .movies,
                             tmdb: store.tmdbClient(),
                             force: true)
                catalog.checkHealth(force: true, domain: .networkCinema)
            } label: {
                if model.isLoading {
                    ProgressView().controlSize(.mini)
                        .frame(width: 56)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isLoading)

            transferMenu
        }
    }

    // MARK: 源清单

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LumaBrand.gradient)
                    .frame(width: 3, height: 14)
                Text("影视源")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(sources.count) 个 · 已启用 \(enabledSources.count) 个")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                sourceActions
            }
            VStack(spacing: 6) {
                ForEach(sources) { source in
                    sourceRow(source)
                }
            }
        }
    }

    private func sourceRow(_ source: CatalogSource) -> some View {
        let hovering = hoveringSource == source.id
        return HStack(spacing: 12) {
            sourceBadge(source)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    healthChip(catalog.health[source.id])
                }
                HStack(spacing: 5) {
                    Text(source.kind.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(source.host)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("\(itemsBySource[source.id] ?? 0) 部在架")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { catalog.setEnabled(source.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(source.isEnabled ? "停用这个影视源" : "启用这个影视源")

            Button {
                store.networkCinemaSourceID = source.id
                store.networkCinemaTab = .movies
            } label: {
                Text("查看")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.055), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                    }
            }
            .buttonStyle(.plain)
            .disabled(!source.isEnabled)
            .help("只看这个源的电影")

            Menu {
                Button("在浏览器打开站点") {
                    store.openCatalogSourceInBrowser(source)
                }
                Button("编辑…") { editingSource = source }
                Divider()
                Button("上移") { catalog.moveSource(source.id, by: -1) }
                    .disabled(sources.first?.id == source.id)
                Button("下移") { catalog.moveSource(source.id, by: 1) }
                    .disabled(sources.last?.id == source.id)
                Divider()
                Button("移除影视源", role: .destructive) {
                    catalog.remove(source.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(hovering ? Color.primary.opacity(0.055) : Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.28)
                                       : Color.primary.opacity(0.06),
                              lineWidth: 0.8)
        }
        .opacity(source.isEnabled ? 1 : 0.62)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) {
                hoveringSource = inside ? source.id : nil
            }
        }
    }

    private func sourceBadge(_ source: CatalogSource) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [source.kind.sidebarTint,
                                              source.kind.sidebarTint.opacity(0.62)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            Image(systemName: source.kind.sidebarSymbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.96))
        }
        .frame(width: 34, height: 34)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6)
        }
        .shadow(color: source.kind.sidebarTint.opacity(0.28), radius: 5, y: 2)
    }

    private func healthChip(_ health: CatalogSourceHealth?) -> some View {
        let value = health ?? .unknown
        let tint: Color
        switch value {
        case .online: tint = LumaBrand.mint
        case .limited: tint = LumaBrand.amber
        case .offline: tint = LumaBrand.coral
        case .checking, .unknown: tint = Color.secondary
        }
        return HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 4.5, height: 4.5)
            Text(value.title)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule(style: .continuous))
    }

    // MARK: 资料补全

    private var metadataPanel: some View {
        CloudHubPanel(spacing: 11) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(LumaBrand.amber.opacity(0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LumaBrand.amber)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("TMDB 资料补全")
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.tmdbClient() == nil
                         ? "未配置 API Key：先用源站海报，评分、演职员与豆瓣评分暂不补全。"
                         : "海报、评分、简介与演职员会按标题自动匹配，匹配结果缓存在本机。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)

                if let progress = model.enrichmentProgress, progress.total > 0 {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("\(progress.done)/\(progress.total)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else if store.tmdbClient() == nil {
                    SettingsLink {
                        Text("打开设置")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 9) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LumaBrand.coral)
                Text("本地缓存 \(cacheText)：三页列表快照与 TMDB 匹配结果，清理后下次进入重新聚合。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("清理缓存") {
                    model.clearCaches()
                    store.showToast("已清理网络影院缓存")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var tipPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("影视源与「网络资源」完全分开：接入、启用、排序与移除都在这一页完成，不会出现在资源页或资源检索里。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button {
                store.presentCatalogWizard(domain: .networkCinema)
            } label: {
                Text("接入影视源")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    // MARK: 空态

    private var emptyState: some View {
        LumaEmptyState(symbol: "popcorn",
                       title: "还没有影视源",
                       message: "接入 FongMi 配置、苹果CMS 接口，或 FoFo / 爱看片片 / 爱壹帆站点地址，电影与电视剧会聚合到这一页。",
                       style: .card,
                       actions: [
                        LumaEmptyAction(title: "接入影视源", symbol: "plus", filled: true) {
                            store.presentCatalogWizard(domain: .networkCinema)
                        }
                       ])
        .padding(.top, 30)
    }
}

// MARK: - 关注

/// 关注：收藏的电影 / 剧集，加上未看完的追看记录。
/// 与「网络资源 › 关注」的人物 / 片商不同，这里只读影视源里的条目。
struct NetworkCinemaFollowingView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var catalog: CatalogBrowserModel

    /// 点开收藏条目：交给 Hub 进影院详情页。
    let onOpen: (NetworkCinemaItem) -> Void

    private var sources: [CatalogSource] {
        catalog.cinemaSources
    }

    private var favorites: [CatalogFavorite] {
        catalog.cinemaFavorites
    }

    private var watching: [CatalogProgress] {
        catalog.cinemaContinueWatching.filter { $0.fraction < 0.97 }
    }

    /// 收藏按电影 / 剧集分两块：判断方式与海报墙一致。
    private var movieFavorites: [CatalogFavorite] {
        favorites.filter { !NetworkCinemaModel.guessIsTV(item(of: $0)) }
    }

    private var showFavorites: [CatalogFavorite] {
        favorites.filter { NetworkCinemaModel.guessIsTV(item(of: $0)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if favorites.isEmpty && watching.isEmpty {
                    emptyState
                } else {
                    if !watching.isEmpty { watchingSection }
                    if !favorites.isEmpty { favoriteSection }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LumaAmbientBackground(intensity: 0.55))
    }

    // MARK: 在追

    private var watchingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("在追", detail: "\(watching.count) 部")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(watching, id: \.key) { record in
                        if let source = source(record.sourceID) {
                            followingRailCard(record: record, source: source)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    private func followingRailCard(record: CatalogProgress, source: CatalogSource) -> some View {
        Button {
            catalog.resume(record)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .frame(width: 200, height: 112)
                    .overlay {
                        CatalogArtworkImage(source: source,
                                            urlString: record.coverURL,
                                            cornerRadius: 10)
                    }
                    .overlay(alignment: .bottom) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.35))
                                Rectangle()
                                    .fill(LumaBrand.amber)
                                    .frame(width: max(2, proxy.size.width * record.fraction))
                            }
                        }
                        .frame(height: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                    }
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 3)

                Text(record.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 200, alignment: .leading)

                HStack(spacing: 4) {
                    Circle().fill(source.kind.sidebarTint).frame(width: 4, height: 4)
                    Text("第 \(record.episode) 集")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text("\(Int(record.fraction * 100))%")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 200)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("继续播放 \(record.title)")
        .contextMenu {
            Button("继续播放") { catalog.resume(record) }
            Button("从头播放") { catalog.restart(record) }
            Divider()
            Button("移出追看", role: .destructive) { catalog.removeProgress(record) }
        }
    }

    // MARK: 收藏

    private var favoriteSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !movieFavorites.isEmpty {
                favoriteBlock(title: "收藏的电影", detail: "\(movieFavorites.count) 部",
                              items: movieFavorites)
            }
            if !showFavorites.isEmpty {
                favoriteBlock(title: "收藏的剧集", detail: "\(showFavorites.count) 部",
                              items: showFavorites)
            }
        }
    }

    private func favoriteBlock(title: String, detail: String,
                               items: [CatalogFavorite]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title, detail: detail)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 168), spacing: 14)],
                      alignment: .leading,
                      spacing: 18) {
                ForEach(items) { favorite in
                    if let source = source(favorite.sourceID) {
                        favoriteCard(favorite, source: source)
                    }
                }
            }
        }
    }

    private func favoriteCard(_ favorite: CatalogFavorite, source: CatalogSource) -> some View {
        Button {
            onOpen(NetworkCinemaItem(source: source,
                                     item: item(of: favorite),
                                     isTV: NetworkCinemaModel.guessIsTV(item(of: favorite))))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(CGFloat(source.posterRatio), contentMode: .fit)
                    .overlay {
                        CatalogArtworkImage(source: source,
                                            urlString: favorite.coverURL,
                                            cornerRadius: 11)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                    }
                    .shadow(color: .black.opacity(0.14), radius: 7, y: 3)

                Text(favorite.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle().fill(source.kind.sidebarTint).frame(width: 4, height: 4)
                    Text(source.name)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("查看详情") {
                onOpen(NetworkCinemaItem(source: source,
                                         item: item(of: favorite),
                                         isTV: NetworkCinemaModel.guessIsTV(item(of: favorite))))
            }
            Button("取消收藏", role: .destructive) {
                catalog.toggleFavorite(source: source, item: item(of: favorite))
            }
        }
        .help(favorite.remark.isEmpty ? favorite.title : "\(favorite.title) · \(favorite.remark)")
    }

    // MARK: 空态

    private var emptyState: some View {
        LumaEmptyState(symbol: "star.circle",
                       title: "还没有关注的内容",
                       message: "在电影 / 电视剧里打开任意一部，点「收藏」就会出现在这里；看过的条目也会自动排进「在追」。",
                       style: .card,
                       actions: [
                        LumaEmptyAction(title: "去看电影", symbol: "film", filled: true) {
                            store.networkCinemaTab = .movies
                        },
                        LumaEmptyAction(title: "去看电视剧", symbol: "tv") {
                            store.networkCinemaTab = .shows
                        }
                       ])
        .padding(.top, 26)
    }

    // MARK: 工具

    private func item(of favorite: CatalogFavorite) -> CatalogItem {
        CatalogItem(id: favorite.itemID,
                    title: favorite.title,
                    coverURL: favorite.coverURL,
                    remark: favorite.remark,
                    categoryID: nil)
    }

    private func source(_ id: UUID) -> CatalogSource? {
        catalog.sources.first(where: { $0.id == id })
    }

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LumaBrand.gradient)
                .frame(width: 3, height: 14)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }
}
