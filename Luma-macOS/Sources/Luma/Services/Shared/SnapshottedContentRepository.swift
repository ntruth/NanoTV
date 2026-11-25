import Foundation
import LumaContentCore

/// 给任意 `ContentRepository` 套一层「取回即存快照」。
/// 页面先用 `cachedPage` 铺上次内容，仓库请求回来后再替换。
@MainActor
struct SnapshottedContentRepository: ContentRepository {
    let base: any ContentRepository
    let sourceID: SourceID
    let cache: SourceContentCache

    /// 快照只保留首屏需要的前几条：目录可能上万条，整份落盘又慢又占空间。
    private static let snapshotItemLimit = 120
    private static let snapshotContainerLimit = 200

    func containers(_ query: ContentQuery) async throws -> [ContentContainer] {
        try await base.containers(query)
    }

    func page(_ query: ContentQuery) async throws -> ContentPage {
        let page = try await base.page(query)
        saveSnapshot(page, query: query)
        return page
    }

    func detail(_ ref: ContentRef) async throws -> ContentDetail {
        try await base.detail(ref)
    }

    func search(_ query: ContentQuery) async throws -> ContentPage {
        let page = try await base.search(query)
        saveSnapshot(page, query: query)
        return page
    }

    func cachedPage(_ query: ContentQuery) -> ContentPage? {
        cache.cachedPage(sourceID: sourceID,
                         containerID: query.containerID,
                         search: query.search)
    }

    private func saveSnapshot(_ page: ContentPage, query: ContentQuery) {
        let trimmed = ContentPage(items: Array(page.items.prefix(Self.snapshotItemLimit)),
                                  containers: Array(page.containers.prefix(Self.snapshotContainerLimit)),
                                  next: nil,
                                  totalHint: page.totalHint)
        cache.savePage(trimmed,
                       sourceID: sourceID,
                       containerID: query.containerID,
                       search: query.search)
    }
}
