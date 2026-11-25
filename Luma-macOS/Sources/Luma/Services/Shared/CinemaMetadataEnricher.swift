import Foundation
import LumaContentCore

/// 影院详情补全：仓库只给出卡片与基础事实，这里补上文件大小、目录与来源，
/// 供详情页统一展示，不需要每个影院视图各自去查。
@MainActor
final class CinemaMetadataEnricher: ContentMetadataEnricher {
    private unowned let store: LibraryStore
    let kind: SourceKind = .cinemaFeed

    init(store: LibraryStore) {
        self.store = store
    }

    func enrich(_ detail: ContentDetail, ref: ContentRef) async -> ContentDetail {
        guard let id = UUID(uuidString: ref.itemID),
              let entry = entry(id: id) else { return detail }

        var facts = detail.facts
        let labels = Set(facts.map(\.label))
        if entry.file.fileSize > 0, !labels.contains("文件大小") {
            facts.append(ContentFact(label: "文件大小",
                                     value: ByteCountFormatter.string(fromByteCount: entry.file.fileSize,
                                                                      countStyle: .file)))
        }
        if let folder = entry.folderHint, !folder.isEmpty, !labels.contains("目录") {
            facts.append(ContentFact(label: "目录", value: folder))
        }
        if !labels.contains("来源") {
            facts.append(ContentFact(label: "来源",
                                     value: entry.file.cloudMountID == nil ? "本地影院" : "网盘影院"))
        }

        var enriched = detail
        enriched.facts = facts
        return enriched
    }

    /// 影院条目按作用域分散存放：按 id 在全部索引里找一次。
    private func entry(id: UUID) -> CinemaEntry? {
        for entries in store.cinemaIndexes.values {
            if let entry = entries[id] { return entry }
        }
        return nil
    }
}
