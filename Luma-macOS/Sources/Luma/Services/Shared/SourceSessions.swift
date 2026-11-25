import Foundation
import LumaContentCore

// MARK: - 图库会话

/// 当前图库的会话适配：图库始终是“已就绪”的写入会话，
/// 切换图库仍由 `SourceHubModel.activate` 调 `switchLibraryContainer` / `activateSystemLibrary`。
@MainActor
final class LibrarySourceSession: SourceSession, SourceBrowsing {
    private unowned let store: LibraryStore
    let descriptor: SourceDescriptor
    private(set) var state: SourceSessionState = .ready
    private(set) var health: SourceHealth = .healthy

    /// 图库写入模型由 `LibraryRepository` 负责（单库重构），只读仓库用于统一搜索 / 跨源列表。
    var repository: any ContentRepository {
        store.sourceHub.repository(for: descriptor.id)
            ?? UnavailableContentRepository(message: "图库内容暂时不可读")
    }

    init(store: LibraryStore, descriptor: SourceDescriptor) {
        self.store = store
        self.descriptor = descriptor
    }

    func activate() async {
        state = .ready
    }

    func refresh() async {
        state = .refreshing
        if store.isNativeContainer {
            store.reloadSystemLibrary()
        } else {
            store.reloadPerLibraryState()
        }
        state = .ready
        health = .healthy
    }

    func deactivate() async {
        state = .idle
    }

    func checkHealth() async -> SourceHealth {
        health
    }
}

// MARK: - 网盘会话

/// 一个网盘挂载的只读浏览会话：导航由 hub 完成，这里只反映连接 / 刷新 / 授权状态。
@MainActor
final class CloudSourceSession: BrowseSession {
    private unowned let store: LibraryStore
    let mountID: UUID
    let descriptor: SourceDescriptor
    private(set) var state: SourceSessionState = .ready
    private(set) var health: SourceHealth = .unknown

    var repository: any ContentRepository {
        store.sourceHub.repository(for: descriptor.id)
            ?? UnavailableContentRepository(message: "网盘挂载已不存在")
    }

    init(store: LibraryStore, mountID: UUID, descriptor: SourceDescriptor) {
        self.store = store
        self.mountID = mountID
        self.descriptor = descriptor
    }

    func activate() async {
        state = .ready
        health = currentHealth()
    }

    func refresh() async {
        state = .refreshing
        store.refreshCloudDirectory()
        let refreshed = currentHealth()
        health = refreshed
        if refreshed.state == .authRequired {
            state = .failed(.unauthorized(refreshed.message ?? "网盘授权已失效"))
        } else if refreshed.state == .offline {
            state = .failed(.unavailable(refreshed.message ?? "网盘暂时连不上"))
        } else {
            state = .ready
        }
    }

    func deactivate() async {
        state = .idle
    }

    func checkHealth() async -> SourceHealth {
        let value = currentHealth()
        health = value
        return value
    }

    private func currentHealth() -> SourceHealth {
        if store.cloudModel.needsCloudReauth {
            return SourceHealth(state: .authRequired,
                                checkedAt: Date(),
                                message: store.cloudModel.error)
        }
        if let error = store.cloudModel.error {
            return SourceHealth(state: .offline, checkedAt: Date(), message: error)
        }
        return .healthy
    }
}

// MARK: - 影院会话

/// 一个影院作用域的只读会话：内容来自已刮削索引，刷新只重读本地状态。
@MainActor
final class CinemaSourceSession: BrowseSession {
    private unowned let store: LibraryStore
    let descriptor: SourceDescriptor
    private(set) var state: SourceSessionState = .ready
    private(set) var health: SourceHealth = .unknown

    var repository: any ContentRepository {
        store.sourceHub.repository(for: descriptor.id)
            ?? UnavailableContentRepository(message: "影院作用域已不存在")
    }

    init(store: LibraryStore, descriptor: SourceDescriptor) {
        self.store = store
        self.descriptor = descriptor
    }

    func activate() async {
        state = .ready
        health = currentHealth()
    }

    func refresh() async {
        state = .refreshing
        store.loadCinemaIndexes()
        health = currentHealth()
        state = .ready
    }

    func deactivate() async {
        state = .idle
    }

    func checkHealth() async -> SourceHealth {
        let value = currentHealth()
        health = value
        return value
    }

    private var scope: CinemaScope {
        descriptor.id == .localCinema
            ? .local
            : (descriptor.id.uuidValue.map(CinemaScope.mount) ?? .local)
    }

    private func currentHealth() -> SourceHealth {
        let count = store.cinemaEntries(for: scope).count
        return count > 0
            ? .healthy
            : SourceHealth(state: .unknown, message: "还没有刮削结果")
    }
}

// MARK: - 网络资源会话

/// 一个站点的只读浏览会话：健康检测走站点首页探测，与其他源共用 `SourceHealth`。
@MainActor
final class CatalogSourceSession: BrowseSession {
    private unowned let store: LibraryStore
    let sourceID: UUID
    let descriptor: SourceDescriptor
    private(set) var state: SourceSessionState = .ready
    private(set) var health: SourceHealth = .unknown

    var repository: any ContentRepository {
        store.sourceHub.repository(for: descriptor.id)
            ?? UnavailableContentRepository(message: "资源站已不存在")
    }

    init(store: LibraryStore, sourceID: UUID, descriptor: SourceDescriptor) {
        self.store = store
        self.sourceID = sourceID
        self.descriptor = descriptor
    }

    func activate() async {
        state = .ready
    }

    func refresh() async {
        state = .refreshing
        store.catalogModel.reload()
        state = .ready
    }

    func deactivate() async {
        state = .idle
    }

    func checkHealth() async -> SourceHealth {
        guard let source = store.catalogModel.sources.first(where: { $0.id == sourceID }) else {
            return SourceHealth(state: .unknown)
        }
        let value = await store.catalogModel.probeHealth(source)
        health = value
        switch value.state {
        case .authRequired:
            state = .failed(.unauthorized(value.message ?? "站点要求先完成验证"))
        case .offline:
            state = .failed(.unavailable(value.message ?? "站点暂时连不上"))
        default:
            if state.error != nil { state = .ready }
        }
        return value
    }
}

// MARK: - 网络电视会话

/// 一个电视源的只读会话：健康状态直接复用该源最近一次连接检测的结果，
/// 刷新时触发统一拉流，并等本轮拉取结束后再回报状态。
@MainActor
final class TVSourceSession: BrowseSession {
    private unowned let store: LibraryStore
    let playlistID: UUID
    let descriptor: SourceDescriptor
    private(set) var state: SourceSessionState = .ready
    private(set) var health: SourceHealth = .unknown

    var repository: any ContentRepository {
        UnavailableContentRepository(message: "电视频道由直播页承载，暂不提供分页浏览")
    }

    init(store: LibraryStore, playlistID: UUID, descriptor: SourceDescriptor) {
        self.store = store
        self.playlistID = playlistID
        self.descriptor = descriptor
    }

    func activate() async {
        state = .ready
        health = currentHealth()
    }

    func refresh() async {
        state = .refreshing
        store.tvModel.setEnabled(true)
        store.tvModel.refresh()
        // 拉流在模型里异步跑；等本轮结束再回报健康，避免刚点刷新就显示旧结果。
        let deadline = Date().addingTimeInterval(20)
        while store.tvModel.isLoading, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        health = currentHealth()
        state = .ready
    }

    func deactivate() async {
        state = .idle
    }

    func checkHealth() async -> SourceHealth {
        let value = currentHealth()
        health = value
        return value
    }

    /// 最近一次连接检测的结果就是电视源的健康状态。
    private func currentHealth() -> SourceHealth {
        guard let playlist = store.tvModel.playlists.first(where: { $0.id == playlistID }) else {
            return SourceHealth(state: .offline, checkedAt: Date(), message: "电视源已删除")
        }
        guard playlist.isEnabled else {
            return SourceHealth(state: .unknown, checkedAt: playlist.lastCheckedAt, message: "已停用")
        }
        if let error = playlist.lastError {
            return SourceHealth(state: .offline,
                                checkedAt: playlist.lastCheckedAt,
                                latencyMilliseconds: playlist.lastLatencyMilliseconds,
                                message: error)
        }
        guard let checkedAt = playlist.lastCheckedAt else { return .unknown }
        let latency = playlist.lastLatencyMilliseconds
        if let latency, latency > 2500 {
            return SourceHealth(state: .degraded,
                                checkedAt: checkedAt,
                                latencyMilliseconds: latency,
                                message: "延迟偏高")
        }
        let channelCount = playlist.lastChannelCount.map { "\($0) 个频道" }
        return SourceHealth(state: .healthy,
                            checkedAt: checkedAt,
                            latencyMilliseconds: latency,
                            message: channelCount)
    }
}
