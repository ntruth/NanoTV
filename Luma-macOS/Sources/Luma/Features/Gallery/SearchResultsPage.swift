import SwiftUI
import AppKit

/// 全局搜索结果页：只负责「标题 + 数据绑定 + 点击动作」，
/// 检索调度与结果面板都在独立搜索模块里（SearchCenter / SearchScopeBar / SearchContent）。
struct SearchResultsPage<PhotoContent: View>: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var catalog: CatalogBrowserModel

    let query: String
    @ViewBuilder var photoContent: () -> PhotoContent

    /// 模块关闭后，来源胶囊与结果一起消失，跨模块兜底入口也不再出现。
    @AppStorage(SettingsKeys.moduleCatalog) private var catalogModule = true
    @AppStorage(SettingsKeys.moduleCinema) private var cinemaModule = true
    @AppStorage(SettingsKeys.showTelevision) private var televisionModule = true

    @StateObject private var center: SearchCenter
    /// 从详情页「返回搜索」带回来的筛选：等本轮检索排完再套上去，
    /// 否则会被 `setQuery` 的清筛选逻辑覆盖掉。
    @State private var restoredFilters: SearchReturnSnapshot?

    init(query: String,
         store: LibraryStore,
         catalog: CatalogBrowserModel,
         tv: IPTVBrowserModel,
         scopes requestedScopes: [SearchSourceKind]? = nil,
         @ViewBuilder photoContent: @escaping () -> PhotoContent) {
        self.query = query
        self.photoContent = photoContent
        // 模块内搜索只调度这个模块自己的来源；传 nil 才走全量统一搜索。
        // 关闭的模块不参与搜索，连来源胶囊都不显示。
        // 检索本身登记成后台任务：底部任务条能看到进度，结束后进「任务记录」并可一键重搜。
        let scopes = (requestedScopes ?? AppModules.enabledSearchScopes)
            .filter { AppModules.isEnabled($0) }
        let providers = SearchProviders.makeAll(store: store, catalog: catalog, tv: tv)
        // 会话复用：点进结果看完退回来时沿用同一份结果，不再整轮重搜。
        _center = StateObject(wrappedValue: SearchSessionStore.shared.center(for: query, scopes: scopes) {
            SearchCenter(scopes: scopes, providers: providers, store: store)
        })
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            SearchScopeBar(center: center)
            SearchContent(center: center,
                          photoGrid: photoContent,
                          onOpen: open,
                          emptyView: AnyView(emptyState))
                .environmentObject(store)
                .environmentObject(catalog)
        }
        .task(id: query) {
            center.setQuery(query)
            applyRestoredFilters()
        }
        .onAppear {
            applyPendingScope()
            takePendingRestore()
        }
        .onChange(of: store.pendingSearchScope) { _, _ in applyPendingScope() }
        .onChange(of: store.pendingSearchRestore) { _, _ in
            takePendingRestore()
            applyRestoredFilters()
        }
        // 离开搜索页不取消检索：点进结果可以看到完整结果，回来直接复用，不重搜。
        // 真正不再需要的会话由 SearchSessionStore 在淘汰或清除时收尾。
    }

    /// 模块内搜索只预选来源，其余筛选 / 展示仍由统一搜索组件负责。
    /// 这里不清空 `store.pendingSearchScope`：结果页重建时仍要按同一个来源初始化。
    private func applyPendingScope() {
        guard let scope = store.pendingSearchScope else { return }
        center.setActiveSource(scope)
    }

    /// 从详情页「返回搜索」回来：把当时选的来源 / 类型 / 源 / 分类一起恢复。
    private func takePendingRestore() {
        guard let restore = store.pendingSearchRestore else { return }
        store.pendingSearchRestore = nil
        restoredFilters = restore
    }

    private func applyRestoredFilters() {
        guard let restore = restoredFilters else { return }
        // 只恢复一次：否则之后每次改关键词都会把上一轮的来源 / 类型 / 源 / 分类再套一遍，
        // 新结果被旧筛选条件清空。
        restoredFilters = nil
        center.activeSource = restore.source
        center.activeKind = restore.kind
        center.activeOrigin = restore.origin
        center.activeCategory = restore.category
    }

    // MARK: - 顶部

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(store.searchScope == .global ? "全局搜索" : "模块搜索")
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(.secondary)
                    Text(center.scopes.map(\.title).joined(separator: " · "))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                Text("「\(trimmedQuery)」")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text("共 \(center.totalCount.formatted()) 项")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if center.isSearching || catalog.isGlobalSearching {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("正在联网检索…")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                store.searchText = ""
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                    Text("清除")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(.quaternary, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help("清除搜索（Esc）")
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                               startPoint: .topLeading, endPoint: .bottom)
                RadialGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                               center: .topTrailing, startRadius: 4, endRadius: 320)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
        }
    }

    // MARK: - 点击路由

    /// 全部来源都没有命中：保留跨模块兜底入口。
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有找到「\(trimmedQuery)」")
                .font(.system(size: 14, weight: .semibold))
            Text("可以换个更短的关键词，或直接到各个模块里搜索。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            // 模块内搜索只属于这个模块：不再给出跨模块搜索入口，避免把别的域的内容带进来。
            if store.searchScope == .global {
                HStack(spacing: 10) {
                    Button("在影院搜") {
                        store.cinemaSearchSeed = trimmedQuery
                        store.cinemaSearchVisible = true
                        store.navigate(to: .cinema)
                    }
                    if catalogModule {
                        Button("在网络资源搜") {
                            catalog.globalQuery = trimmedQuery
                            store.navigate(to: .catalogSources)
                        }
                    }
                    if cinemaModule {
                        Button("在网络影院搜") {
                            store.networkCinemaSearchSeed = trimmedQuery
                            store.navigate(to: .networkCinema)
                        }
                    }
                    if televisionModule {
                        Button("在网络电视搜") {
                            tvModel.searchText = trimmedQuery
                            store.navigate(to: .iptv)
                        }
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func open(_ hit: SearchHit) {
        // 照片在当前图库就地打开查看器：关掉查看器仍停在搜索页，不需要返回入口；
        // 其它命中会离开搜索页，先记下搜索现场，详情页顶栏据此一步回到搜索结果。
        if !opensInPlace(hit) {
            rememberSearch(landing: landingItem(for: hit.payload))
        }
        // 跨图库命中：先切 / 连到它所属的图库，等内容就绪后再打开条目。
        if let path = hit.libraryPath, !isCurrentLibrary(path),
           let pending = Self.pendingOpen(for: hit.payload) {
            store.openSearchResultInLibrary(path: path, pending: pending)
            return
        }
        switch hit.payload {
        case .photo(let id):
            store.openViewer(id)

        case .localAlbum(let id):
            store.navigate(to: .album(id))

        case .localFolder(let id):
            store.navigate(to: .folder(id))

        case .systemAlbum(let id):
            store.navigate(to: .systemAlbum(id))

        case .systemFolder(let id):
            store.navigate(to: .systemFolder(id))

        case .localPerson(let id):
            store.navigate(to: .people)
            store.selectedLocalPersonID = id

        case .systemPerson(let person):
            store.navigate(to: .systemPeople)
            store.openPerson(person)

        case .place(let cluster):
            store.navigate(to: store.isSystemScope ? .systemPlaces : .places)
            store.openPlace(cluster)

        case .scene(let id):
            // 场景分类直达：系统图库有自己的场景入口。
            store.navigate(to: store.isSystemScope ? .systemScene(id) : .scene(id))

        case .cloudFile(let mountID, let folderPath, let path):
            // 直达文件本身：打开挂载与所在目录后，直接把这一项送进查看器。
            store.openCloudFile(mountID: mountID, folderPath: folderPath, path: path)

        case .cloudFolder(let mountID, let path):
            store.openCloudMount(mountID)
            store.selectCloudFolder(path: path)

        case .cinema(let scopeKey, let queueTitle, let entry):
            openCinema(scopeKey: scopeKey, queueTitle: queueTitle, entry: entry)

        case .channel(let channel):
            tvModel.focusPlaylist(channel.playlistID)
            tvModel.searchText = trimmedQuery
            tvModel.setHubTab(.channels)
            store.navigate(to: .iptv)
            store.openTVChannel(channel)

        case .program(let channel, let program):
            tvModel.focusPlaylist(channel.playlistID)
            store.navigate(to: .iptv)
            if program.isLive {
                tvModel.setHubTab(.channels)
                store.openTVChannel(channel)
            } else if program.end <= Date(), !(channel.catchUpSource ?? "").isEmpty {
                // 已经播完且源支持回看：直接回看这一档。
                store.openTVCatchup(channel, program: program)
            } else {
                // 未开播 / 该源不能回看：停在这档节目当天的节目单上。
                let today = Calendar.current.startOfDay(for: Date())
                let day = Calendar.current.startOfDay(for: program.start)
                let offset = Calendar.current.dateComponents([.day], from: today, to: day).day ?? 0
                tvModel.guideDayOffset = min(2, max(-2, offset))
                tvModel.setHubTab(.guide)
            }

        case .catalogItem(let sourceID, let item):
            // 进入频道页时它会先复位内联详情：必须走「待打开条目」，
            // 由频道页自己的 task 消费，才能一进来就停在详情页。
            catalog.pendingInlineItem = item
            catalog.focus(sourceID)
            store.navigate(to: .catalogSource(sourceID))

        case .networkCinemaItem(let sourceID, let item, let isTV):
            // 与网络资源同样的思路：网络影院页出现时消费「待打开条目」，直接进详情。
            store.networkCinemaSourceID = sourceID
            store.networkCinemaTab = isTV ? .shows : .movies
            if let source = catalog.cinemaSources.first(where: { $0.id == sourceID }) {
                store.networkCinemaPendingItem = NetworkCinemaItem(source: source,
                                                                   item: item,
                                                                   isTV: isTV)
            }
            store.navigate(to: .networkCinema)
        }
    }

    private var tvModel: IPTVBrowserModel { store.tvModel }

    /// 记下搜索现场。
    private func rememberSearch(landing: SidebarItem?) {
        store.beginSearchReturn(SearchReturnSnapshot(
            query: trimmedQuery,
            scope: store.searchScope,
            source: center.activeSource,
            kind: center.activeKind,
            origin: center.activeOrigin,
            category: center.activeCategory,
            originItem: store.sidebarItem,
            landingItem: landing))
    }

    /// 在搜索页即可完成、不需要离开页面的命中。
    private func opensInPlace(_ hit: SearchHit) -> Bool {
        guard case .photo = hit.payload else { return false }
        if let path = hit.libraryPath, !isCurrentLibrary(path) { return false }
        return true
    }

    /// 命中跳转后停留的页面：顶栏「返回搜索」只在这个页面上出现。
    /// 影院控制台自带详情层级，返回入口另有一套，这里不留搜索返回。
    private func landingItem(for payload: SearchPayload) -> SidebarItem? {
        switch payload {
        case .photo: return nil
        case .localAlbum(let id): return .album(id)
        case .localFolder(let id): return .folder(id)
        case .systemAlbum(let id): return .systemAlbum(id)
        case .systemFolder(let id): return .systemFolder(id)
        case .localPerson: return .people
        case .systemPerson: return .systemPeople
        case .place: return store.isSystemScope ? .systemPlaces : .places
        case .scene(let id): return store.isSystemScope ? .systemScene(id) : .scene(id)
        case .cloudFile(let mountID, _, _), .cloudFolder(let mountID, _): return .cloudMount(mountID)
        case .cinema: return nil
        case .channel, .program: return .iptv
        case .catalogItem(let sourceID, _): return .catalogSource(sourceID)
        case .networkCinemaItem: return .networkCinema
        }
    }

    /// 命中所在图库是否就是当前浏览的图库。
    private func isCurrentLibrary(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let container = LibraryPaths.containerLibraryURL?.standardizedFileURL.path,
           container == standardized { return true }
        if let active = store.systemLibraryPath.map({
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }), active == standardized { return true }
        return false
    }

    /// 搜索结果负载 → 切库后要打开的目标。
    private static func pendingOpen(for payload: SearchPayload) -> LibraryPendingOpen? {
        switch payload {
        case .photo(let id): return .photo(id)
        case .localAlbum(let id): return .album(id)
        case .localFolder(let id): return .folder(id)
        case .localPerson(let id): return .person(id)
        case .systemAlbum(let id): return .systemAlbum(id)
        case .systemFolder(let id): return .systemFolder(id)
        case .systemPerson(let person): return .systemPerson(person)
        default: return nil
        }
    }

    private func openCinema(scopeKey: String, queueTitle: String, entry: CinemaEntry) {
        let mountID = Self.mountID(from: scopeKey)
        if let mountID {
            store.navigate(to: .cloudCinema(mountID))
        } else {
            store.navigate(to: .cinema)
        }
        let scope: CinemaScope = mountID.map { CinemaScope.mount($0) } ?? .local
        let queue = (store.cinemaIndexes[scope] ?? [:])
            .values
            .filter { $0.title == queueTitle }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        store.openCinema(entry, queue: queue.isEmpty ? nil : queue)
    }

    private static func mountID(from scopeKey: String) -> UUID? {
        let prefix = "mount-"
        guard scopeKey.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(scopeKey.dropFirst(prefix.count)))
    }
}
