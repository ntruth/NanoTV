import Foundation
import LumaContentCore

/// 内容快照 + 修订号的统一入口。
///
/// 读：先看有没有上次的快照；快照过期、或该源在快照之后又发生过内容变化，就不再用它。
/// 写：仓库成功取回一页后保存快照；源内容真正变化时自增修订号，旧快照随之失效。
@MainActor
final class SourceContentCache {
    private unowned let store: LibraryStore
    private var didPrune = false

    /// 快照最长复用时长：超过后即使源没变化也重新拉，避免长期显示旧内容。
    private let maxAge: TimeInterval = 15 * 60

    init(store: LibraryStore) {
        self.store = store
    }

    func revision(_ sourceID: SourceID) -> SourceRevision {
        store.sourceRevisions.revision(for: sourceID)
    }

    /// 首屏快照：源未变化且快照未过期时返回，调用方可以立即渲染。
    func cachedPage(sourceID: SourceID,
                    containerID: String?,
                    search: String?,
                    maxAge: TimeInterval? = nil) -> ContentPage? {
        guard let snapshot = store.contentSnapshots.snapshot(sourceID: sourceID,
                                                             containerID: containerID,
                                                             search: search) else {
            return nil
        }
        guard !snapshot.isStale(olderThan: maxAge ?? self.maxAge) else { return nil }
        // 源在快照之后变过：旧内容不可信。
        guard store.sourceRevisions.revision(for: sourceID).updatedAt <= snapshot.savedAt else {
            return nil
        }
        return snapshot.page
    }

    func savePage(_ page: ContentPage,
                  sourceID: SourceID,
                  containerID: String?,
                  search: String?) {
        store.contentSnapshots.save(ContentPageSnapshot(sourceID: sourceID,
                                                        containerID: containerID,
                                                        search: search,
                                                        page: page))
        pruneIfNeeded()
    }

    /// 源内容发生变化：修订号自增，并丢掉它的旧快照。
    func invalidate(_ sourceID: SourceID) {
        store.sourceRevisions.bump(sourceID)
        store.contentSnapshots.removeAll(sourceID: sourceID)
    }

    /// 只自增修订号（快照按修订号判断失效，不必每次清盘）。
    func bump(_ sourceID: SourceID) {
        store.sourceRevisions.bump(sourceID)
    }

    /// 换图库 / 启动时清理过期快照，避免 JSON 无限增长。
    func prune() {
        store.contentSnapshots.prune(olderThan: 7 * 24 * 3600, keeping: 300)
    }

    private func pruneIfNeeded() {
        guard !didPrune else { return }
        didPrune = true
        prune()
    }
}
