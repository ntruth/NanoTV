import Foundation

/// 详情补全：拿到仓库返回的 `ContentDetail` 后，按源追加元数据（文件事实、刮削信息等）。
/// 影院、网盘、资源、电视共用同一入口，不再各自在详情页拼 facts。
@MainActor
public protocol ContentMetadataEnricher: AnyObject {
    var kind: SourceKind { get }
    func enrich(_ detail: ContentDetail, ref: ContentRef) async -> ContentDetail
}

/// 按 kind 注册的补全器集合：仓库层只调一次，不需要知道具体来源。
@MainActor
public final class MetadataEnricherCenter {
    private var enrichers: [SourceKind: [any ContentMetadataEnricher]] = [:]

    public init() {}

    public func register(_ enricher: any ContentMetadataEnricher) {
        enrichers[enricher.kind, default: []].append(enricher)
    }

    public func enrich(_ detail: ContentDetail,
                       ref: ContentRef,
                       kind: SourceKind) async -> ContentDetail {
        var current = detail
        for enricher in enrichers[kind] ?? [] {
            current = await enricher.enrich(current, ref: ref)
        }
        return current
    }
}
