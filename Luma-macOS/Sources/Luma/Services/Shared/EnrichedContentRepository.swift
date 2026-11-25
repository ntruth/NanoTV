import Foundation
import LumaContentCore

/// 给任意仓库的详情补一层元数据：仓库只负责「取回」，补全交给 `MetadataEnricherCenter`。
@MainActor
struct EnrichedContentRepository: ContentRepository {
    let base: any ContentRepository
    let sourceID: SourceID
    let kind: SourceKind
    let center: MetadataEnricherCenter

    func containers(_ query: ContentQuery) async throws -> [ContentContainer] {
        try await base.containers(query)
    }

    func page(_ query: ContentQuery) async throws -> ContentPage {
        try await base.page(query)
    }

    func detail(_ ref: ContentRef) async throws -> ContentDetail {
        let detail = try await base.detail(ref)
        return await center.enrich(detail, ref: ref, kind: kind)
    }

    func search(_ query: ContentQuery) async throws -> ContentPage {
        try await base.search(query)
    }

    func cachedPage(_ query: ContentQuery) -> ContentPage? {
        base.cachedPage(query)
    }
}
