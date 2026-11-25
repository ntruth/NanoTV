import Foundation
import LumaContentCore

/// 把现有的两套续播存储（影院设置 JSON、网络资源 `catalog_progress` 表）
/// 收敛到同一个 `PlaybackProgressStore` 接口下。
///
/// 只做适配，不改表结构、不迁移数据：
/// - 读取：按 `SourceID` 前缀分流到影院或网络资源。
/// - 写入：播放器的影院 / 网络资源续播都由这里创建或更新，不再直接改旧模型。
/// - 删除：与旧路径共用同一份持久化。
@MainActor
final class SourcePlaybackProgressStore: PlaybackProgressStore {
    private weak var library: LibraryStore?
    private let catalog: CatalogBrowserModel

    init(library: LibraryStore, catalog: CatalogBrowserModel) {
        self.library = library
        self.catalog = catalog
    }

    // MARK: - PlaybackProgressStore

    func progress(sourceID: SourceID, itemID: String, episodeID: String?) -> PlaybackProgress? {
        if isCinema(sourceID) {
            guard let uuid = UUID(uuidString: itemID),
                  let record = library?.cinemaProgress[uuid] else { return nil }
            return PlaybackProgress(sourceID: sourceID,
                                    itemID: itemID,
                                    episodeID: nil,
                                    position: record.position,
                                    duration: record.duration,
                                    updatedAt: record.updatedAt)
        }
        if let sourceUUID = catalogSourceID(sourceID),
           let record = catalog.progress(sourceID: sourceUUID, itemID: itemID) {
            return PlaybackProgress(sourceID: sourceID,
                                    itemID: itemID,
                                    episodeID: String(record.episode),
                                    position: record.seconds,
                                    duration: record.duration,
                                    updatedAt: record.updatedAt)
        }
        return nil
    }

    func save(_ progress: PlaybackProgress) {
        if isCinema(progress.sourceID) {
            upsertCinema(progress, entry: nil)
            return
        }
        upsertCatalog(progress, source: nil, item: nil, episode: nil)
    }

    /// 播放器写入影院进度的唯一入口：新记录也能补齐标题 / 副标题 / 海报。
    @discardableResult
    func recordCinemaProgress(entry: CinemaEntry,
                              position: Double,
                              duration: Double) -> PlaybackProgress {
        let sourceID: SourceID = entry.file.cloudMountID.map(SourceID.mountCinema) ?? .localCinema
        let progress = PlaybackProgress(sourceID: sourceID,
                                        itemID: entry.id.uuidString,
                                        position: position,
                                        duration: duration)
        upsertCinema(progress, entry: entry)
        return progress
    }

    /// 播放器写入网络资源进度的唯一入口。
    @discardableResult
    func recordCatalogProgress(source: CatalogSource,
                               item: CatalogItem,
                               episode: Int,
                               seconds: Double,
                               duration: Double) -> PlaybackProgress? {
        // 与旧路径一致：起播前几秒不记，避免误点头就写进「继续观看」。
        guard seconds > 3 else { return nil }
        let progress = PlaybackProgress(sourceID: .catalog(source.id),
                                        itemID: item.id,
                                        episodeID: String(episode),
                                        position: seconds,
                                        duration: duration)
        upsertCatalog(progress, source: source, item: item, episode: episode)
        return progress
    }

    // MARK: - 写入实现

    private func upsertCinema(_ progress: PlaybackProgress, entry: CinemaEntry?) {
        guard let library, let uuid = UUID(uuidString: progress.itemID) else { return }
        let existing = library.cinemaProgress[uuid]
        let subtitle = entry?.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = CinemaProgressRecord(
            photoID: uuid,
            mountID: entry?.file.cloudMountID ?? existing?.mountID,
            title: entry?.title ?? existing?.title ?? "",
            subtitle: entry != nil ? (subtitle?.isEmpty == false ? subtitle : nil) : existing?.subtitle,
            artworkURL: entry?.gridArtworkURL ?? existing?.artworkURL,
            position: progress.position,
            duration: progress.duration,
            updatedAt: progress.updatedAt
        )
        library.cinemaProgress[uuid] = record
        library.persistCinemaProgress()
    }

    private func upsertCatalog(_ progress: PlaybackProgress,
                               source: CatalogSource?,
                               item: CatalogItem?,
                               episode: Int?) {
        guard let sourceUUID = catalogSourceID(progress.sourceID) else { return }
        let existing = catalog.progress(sourceID: sourceUUID, itemID: progress.itemID)
        let resolvedEpisode = episode
            ?? progress.episodeID.flatMap(Int.init)
            ?? existing?.episode
            ?? 1
        let record = CatalogProgress(sourceID: sourceUUID,
                                     itemID: progress.itemID,
                                     episode: resolvedEpisode,
                                     seconds: progress.position,
                                     duration: progress.duration,
                                     title: item?.title ?? existing?.title ?? "",
                                     coverURL: item?.coverURL ?? existing?.coverURL ?? "",
                                     updatedAt: progress.updatedAt)
        catalog.progress[record.key] = record
        catalog.persistProgress(record)
    }

    func remove(sourceID: SourceID, itemID: String, episodeID: String?) {
        if isCinema(sourceID) {
            guard let library, let uuid = UUID(uuidString: itemID),
                  library.cinemaProgress.removeValue(forKey: uuid) != nil else { return }
            library.persistCinemaProgress()
            return
        }
        guard let sourceUUID = catalogSourceID(sourceID),
              let record = catalog.progress(sourceID: sourceUUID, itemID: itemID) else { return }
        catalog.removeProgress(record)
    }

    func removeAll(sourceID: SourceID) {
        if isCinema(sourceID) {
            guard let library else { return }
            let mountID: UUID?
            if sourceID == .localCinema {
                mountID = nil
            } else if sourceID.rawValue.hasPrefix("cinema:mount:"),
                      let uuid = UUID(uuidString: String(sourceID.rawValue.dropFirst("cinema:mount:".count))) {
                mountID = uuid
            } else {
                return
            }
            let removed = library.cinemaProgress.values.contains { $0.mountID == mountID }
            guard removed else { return }
            library.cinemaProgress = library.cinemaProgress.filter { $0.value.mountID != mountID }
            library.persistCinemaProgress()
            return
        }
        guard let sourceUUID = catalogSourceID(sourceID) else { return }
        let keys = catalog.progress.values
            .filter { $0.sourceID == sourceUUID }
            .map(\.key)
        guard !keys.isEmpty else { return }
        for key in keys { catalog.progress[key] = nil }
        CatalogStore.deleteProgress(sourceID: sourceUUID)
    }

    // MARK: - 源 ID 分流

    private func isCinema(_ sourceID: SourceID) -> Bool {
        sourceID.rawValue.hasPrefix("cinema:")
    }

    /// `catalog:<UUID>` → UUID；跨源聚合源 `catalog:hub` 不落到单源记录。
    private func catalogSourceID(_ sourceID: SourceID) -> UUID? {
        let prefix = "catalog:"
        guard sourceID.rawValue.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(sourceID.rawValue.dropFirst(prefix.count)))
    }
}
