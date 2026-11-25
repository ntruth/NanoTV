import Foundation

/// 源的健康状态：侧边栏角标、错误卡片、重连提示共用。
public struct SourceHealth: Hashable, Codable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case unknown
        case checking
        case healthy
        case degraded
        case offline
        case authRequired
    }

    public var state: State
    public var checkedAt: Date?
    public var latencyMilliseconds: Int?
    public var message: String?

    public init(state: State = .unknown,
                checkedAt: Date? = nil,
                latencyMilliseconds: Int? = nil,
                message: String? = nil) {
        self.state = state
        self.checkedAt = checkedAt
        self.latencyMilliseconds = latencyMilliseconds
        self.message = message
    }

    public static let unknown = SourceHealth()
    public static let healthy = SourceHealth(state: .healthy, checkedAt: Date())
    public static let authRequired = SourceHealth(state: .authRequired, checkedAt: Date())
}

/// 源会话状态：激活、刷新、失败都以它为准。
public enum SourceSessionState: Hashable, Sendable {
    case idle
    case activating
    case ready
    case refreshing
    case failed(SourceError)

    public var isReady: Bool { self == .ready }
    public var isBusy: Bool { self == .activating || self == .refreshing }

    public var error: SourceError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

/// 源会话：当前图库、云盘、资源、影院、电视都实现它。
/// library 的会话额外持有写入能力，其他 kind 只读。
@MainActor
public protocol SourceSession: AnyObject {
    var descriptor: SourceDescriptor { get }
    var state: SourceSessionState { get }
    var health: SourceHealth { get }

    func activate() async
    func refresh() async
    func deactivate() async
    func checkHealth() async -> SourceHealth
}

/// 源的连接生命周期：接入 / 断开 / 重新授权。
/// 具体向导仍由各 Feature 负责，这里只定义共同动作。
@MainActor
public protocol SourceLifecycle: AnyObject {
    func connect() async throws
    func disconnect() async
    func reauthorize() async throws
}

/// 只读源的仓库访问入口：由 SourceSession 暴露给内容视图。
@MainActor
public protocol SourceBrowsing: AnyObject {
    var repository: any ContentRepository { get }
}

/// 浏览会话：云盘 / 影院 / 资源 / 电视统一用它表达「当前在浏览哪个源」。
/// 只读、没有写入能力；图库会话仍是 `SourceSession` + `LibraryWriting`。
@MainActor
public protocol BrowseSession: SourceSession, SourceBrowsing {}

/// 当前写入会话：只有 library 实现。
/// 单库方案里的 LibrarySession 应实现这个协议，而不是另造一套会话。
@MainActor
public protocol LibraryWriting: AnyObject {
    var writeCapabilities: WriteCapabilities { get }
    func importMedia() async throws
    func deleteOriginal() async throws
}
