import Foundation
import LumaContentCore

/// 源运行时的唯一入口：
/// - `state`：统一注册表（由各模块的当前状态构建），侧边栏与搜索都读它。
/// - `activate(_:)`：链接图库换库，其余 kind 只切浏览上下文，不再由视图各自判断。
/// - `session(for:)`：按源拿到 `SourceSession`，回答“当前浏览哪个源、健康状态如何”。
@MainActor
final class SourceHubModel: ObservableObject {
    private unowned let store: LibraryStore
    /// 同一种源只创建一个会话，避免每次切换都重建连接状态。
    private var sessions: [String: any SourceSession] = [:]

    /// 最近一次激活的源会话；后续状态条 / 侧边栏角标直接读它。
    @Published private(set) var activeSession: (any SourceSession)?
    /// 各源最近一次已知的健康状态：侧边栏行尾的状态点读它（会话内部变化不会自动发通知）。
    @Published private(set) var healthSnapshot: [String: SourceHealth] = [:]

    func health(for sourceID: SourceID) -> SourceHealth? {
        healthSnapshot[sourceID.rawValue]
    }

    private func recordHealth(_ session: any SourceSession) {
        healthSnapshot[session.descriptor.id.rawValue] = session.health
    }

    init(store: LibraryStore) {
        self.store = store
    }

    var state: SourceRegistryState { store.buildSourceRegistryState() }

    var currentBrowseSourceID: SourceID? { state.activeBrowseSourceID }

    // MARK: - 激活

    /// 点击源时唯一的入口。语义由激活策略决定：
    /// 换库策略替换当前图库会话，浏览策略只切右侧文案与浏览上下文。
    func activate(_ sourceID: SourceID) {
        let policy = state.descriptor(for: sourceID)?.activation
            ?? Self.kind(of: sourceID).defaultActivation
        switch policy {
        case .replaceLibrarySession:
            activateLibrary(sourceID)
        case .browseReadOnly:
            browse(sourceID)
        }

        if let session = session(for: sourceID) {
            activeSession = session
            Task {
                await session.activate()
                recordHealth(session)
            }
        } else {
            activeSession = nil
        }
    }

    /// 只读浏览：不改变当前图库与写入能力，只换右侧内容。
    private func browse(_ sourceID: SourceID) {
        switch Self.kind(of: sourceID) {
        case .cloudMount:
            guard let mountID = Self.uuid(in: sourceID, prefix: "cloud:") else { return }
            store.navigate(to: .cloudMount(mountID))
        case .catalogSite:
            guard let id = Self.uuid(in: sourceID, prefix: "catalog:") else { return }
            store.catalogModel.focus(id)
            store.navigate(to: .catalogSource(id))
        case .cinemaFeed:
            if sourceID == .localCinema {
                store.activateCinemaScope(.local)
                store.navigate(to: .cinema)
            } else if let mountID = Self.uuid(in: sourceID, prefix: "cinema:mount:") {
                store.activateCinemaScope(.mount(mountID))
                store.navigate(to: .cloudCinema(mountID))
            }
        case .iptv:
            store.tvModel.setEnabled(true)
            // 电视源是独立可点条目：带上具体源，页面直接聚焦到它。
            if let playlistID = Self.uuid(in: sourceID, prefix: "tv:") {
                store.tvModel.focusPlaylist(playlistID)
                store.tvModel.setHubTab(.channels)
            }
            store.navigate(to: .iptv)
        case .library:
            // 换库策略已在上面处理；走到这里说明策略与 kind 不一致，按换库兜底。
            activateLibrary(sourceID)
        }
    }

    /// 链接图库：替换当前图库会话；当前图库本身只回到图库浏览。
    private func activateLibrary(_ sourceID: SourceID) {
        let path = String(sourceID.rawValue.dropFirst("library:".count))
        // 统一按归一化路径比较：尾斜杠 / 相对写法不同也算同一个库。
        if let ref = store.systemLibraries.first(where: { store.isSameSystemLibraryPath($0.path, path) }) {
            store.activateSystemLibrary(ref)
            return
        }
        let containerPath = LibraryPaths.containerLibraryURL?.standardizedFileURL.path
        if let containerPath, store.isSameSystemLibraryPath(containerPath, path) {
            // 图库本身就是官方照片图库：切回它，而不是只跳页面（否则会停在外接图库的内容上）。
            if LibraryPaths.isNativeLibrary(URL(fileURLWithPath: path)) {
                store.connectSystemLibrary(URL(fileURLWithPath: path))
            } else {
                store.navigate(to: .library)
            }
        } else {
            store.switchLibraryContainer(URL(fileURLWithPath: path))
        }
    }

    // MARK: - 会话

    /// 源对应的只读内容仓库；云盘 / 资源已接入，图库与后续 kind 由各自模型补齐。
    /// 统一套一层快照装饰器：取回即存，下一次先用上次内容铺首屏。
    func repository(for sourceID: SourceID) -> (any ContentRepository)? {
        let base: (any ContentRepository)?
        switch Self.kind(of: sourceID) {
        case .cloudMount:
            guard let id = Self.uuid(in: sourceID, prefix: "cloud:"),
                  let mount = store.cloudMounts.first(where: { $0.id == id }) else { return nil }
            base = CloudContentRepository(mount: mount, rootPath: store.cloudRootPath(for: mount))
        case .catalogSite:
            guard let id = Self.uuid(in: sourceID, prefix: "catalog:"),
                  let source = store.catalogModel.sources.first(where: { $0.id == id }) else { return nil }
            base = CatalogContentRepository(source: source)
        case .cinemaFeed:
            let scope: CinemaScope = sourceID == .localCinema
                ? .local
                : (sourceID.uuidValue.map(CinemaScope.mount) ?? .local)
            base = CinemaContentRepository(store: store, scope: scope)
        case .library:
            base = LibraryContentRepository(store: store, sourceID: sourceID)
        case .iptv:
            // 电视频道由直播页承载，暂不提供分页仓库。
            base = nil
        }
        guard let base else { return nil }
        // 详情先补元数据，再套快照：页面拿到的都是补全后的内容。
        let enriched = EnrichedContentRepository(base: base,
                                                 sourceID: sourceID,
                                                 kind: Self.kind(of: sourceID),
                                                 center: store.metadataEnrichers)
        return SnapshottedContentRepository(base: enriched,
                                            sourceID: sourceID,
                                            cache: store.sourceContentCache)
    }

    func session(for sourceID: SourceID) -> (any SourceSession)? {
        if let cached = sessions[sourceID.rawValue] { return cached }
        let session: (any SourceSession)?
        if let descriptor = state.descriptor(for: sourceID) {
            session = makeSession(for: descriptor)
        } else if Self.kind(of: sourceID) == .iptv,
                  let playlistID = Self.uuid(in: sourceID, prefix: "tv:"),
                  let playlist = store.tvModel.playlists.first(where: { $0.id == playlistID }) {
            // 电视源不在注册表里也能建会话：侧边栏直接点某个源时同样有健康状态。
            session = TVSourceSession(
                store: store,
                playlistID: playlistID,
                descriptor: SourceDescriptor(id: sourceID,
                                             kind: .iptv,
                                             name: playlist.name,
                                             subtitle: playlist.region.title,
                                             activation: .browseReadOnly,
                                             content: .television,
                                             sortIndex: 500)
            )
        } else {
            session = nil
        }
        if let session { sessions[sourceID.rawValue] = session }
        return session
    }

    private func makeSession(for descriptor: SourceDescriptor) -> (any SourceSession)? {
        let sourceID = descriptor.id
        switch descriptor.kind {
        case .library:
            return LibrarySourceSession(store: store, descriptor: descriptor)
        case .cloudMount:
            return Self.uuid(in: sourceID, prefix: "cloud:").map {
                CloudSourceSession(store: store, mountID: $0, descriptor: descriptor)
            }
        case .catalogSite:
            return Self.uuid(in: sourceID, prefix: "catalog:").map {
                CatalogSourceSession(store: store, sourceID: $0, descriptor: descriptor)
            }
        case .cinemaFeed:
            return CinemaSourceSession(store: store, descriptor: descriptor)
        default:
            return nil
        }
    }

    // MARK: - SourceID 解析

    private static func kind(of sourceID: SourceID) -> SourceKind {
        let raw = sourceID.rawValue
        if raw.hasPrefix("library:") { return .library }
        if raw.hasPrefix("cloud:") { return .cloudMount }
        if raw.hasPrefix("catalog:") { return .catalogSite }
        if raw.hasPrefix("cinema:") { return .cinemaFeed }
        if raw.hasPrefix("tv:") { return .iptv }
        return .library
    }

    private static func uuid(in sourceID: SourceID, prefix: String) -> UUID? {
        guard sourceID.rawValue.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(sourceID.rawValue.dropFirst(prefix.count)))
    }
}
