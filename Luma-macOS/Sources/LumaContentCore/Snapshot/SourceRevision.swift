import Foundation

/// 源的修订号：内容变化时自增，界面与快照据此判断是否要重读。
/// 图库 / 云盘 / 资源 / 影院 / 电视各持有一个，互不影响。
public struct SourceRevision: Hashable, Codable, Sendable {
    public var sourceID: SourceID
    public var value: Int
    public var updatedAt: Date

    public init(sourceID: SourceID, value: Int = 0, updatedAt: Date = Date()) {
        self.sourceID = sourceID
        self.value = value
        self.updatedAt = updatedAt
    }
}

/// 修订号追踪器：后台线程也能安全自增，界面只读当前值。
public final class SourceRevisionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: SourceRevision] = [:]

    public init() {}

    public func revision(for sourceID: SourceID) -> SourceRevision {
        lock.lock()
        defer { lock.unlock() }
        return storage[sourceID.rawValue]
            ?? SourceRevision(sourceID: sourceID, value: 0, updatedAt: .distantPast)
    }

    @discardableResult
    public func bump(_ sourceID: SourceID) -> SourceRevision {
        lock.lock()
        defer { lock.unlock() }
        let current = storage[sourceID.rawValue]?.value ?? 0
        let next = SourceRevision(sourceID: sourceID, value: current + 1, updatedAt: Date())
        storage[sourceID.rawValue] = next
        return next
    }

    public func reset(_ sourceID: SourceID) {
        lock.lock()
        defer { lock.unlock() }
        storage[sourceID.rawValue] = nil
    }

    /// 换图库：所有源的修订号都属于上一个图库，整体作废。
    public func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
