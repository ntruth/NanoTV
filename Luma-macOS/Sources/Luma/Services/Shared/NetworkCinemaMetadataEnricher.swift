import Foundation
import LumaContentCore

/// 网络影院详情补全：与本地影院共用 `MetadataEnricherCenter`，不再由详情页自己拼事实。
///
/// 条目引用使用 `NetworkCinemaItem.id`（`sourceUUID|itemID`），因此同一部片在多个源上时
/// 也能找回「主条目 + 其它源」的全部线路信息。
@MainActor
final class NetworkCinemaMetadataEnricher: ContentMetadataEnricher {
    private unowned let store: LibraryStore
    let kind: SourceKind = .cinemaFeed

    init(store: LibraryStore) {
        self.store = store
    }

    func enrich(_ detail: ContentDetail, ref: ContentRef) async -> ContentDetail {
        let model = store.networkCinemaModel
        guard let item = model.item(refID: ref.itemID) else { return detail }

        var facts = detail.facts
        let labels = Set(facts.map(\.label))

        let sources = model.sources(for: item)
        if !labels.contains("可用线路") {
            let value: String
            if sources.count > 1 {
                let names = sources.prefix(3).map(\.source.name).joined(separator: " / ")
                value = "\(sources.count) 个源 · \(names)"
            } else {
                value = item.source.name
            }
            facts.append(ContentFact(label: "可用线路", value: value))
        }

        if let enrichment = model.enrichment(for: item),
           let rating = enrichment.rating, rating > 0,
           !labels.contains("TMDB 评分") {
            facts.append(ContentFact(label: "TMDB 评分", value: String(format: "%.1f", rating)))
        }

        if let douban = model.cachedDoubanRating(for: item), douban > 0,
           !labels.contains("豆瓣评分") {
            facts.append(ContentFact(label: "豆瓣评分", value: String(format: "%.1f", douban)))
        }

        var enriched = detail
        enriched.facts = facts
        return enriched
    }
}
