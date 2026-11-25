import Foundation
import PlaybackCore
import LumaContentCore

/// 把现有本地 / 云盘 / 网络资源三种片源收敛成一个解析入口。
/// 播放器只消费 `ResolvedStream`，后续影院在线源与电视直播源在这里追加即可。
extension LibraryStore {
    /// 播放会话统一入口：现有 PhotoItem 流程也带上模式与能力语义。
    func preparePlaybackSession(for photo: PhotoItem) async throws -> ResolvedPlayback {
        let target = playbackTarget(for: photo)
        do {
            return try await playbackCoordinator.prepare(target)
        } catch let error as SourceError where error.kind == .unsupported {
            // 注册表里找不到这个条目时退回当前 PhotoItem 流程。
            let stream = try await resolvePlaybackStream(for: photo)
            return playbackCoordinator.session(for: target, stream: stream)
        }
    }

    /// 按 photoID 找回用于播放的条目：图库 / 云盘 / 影院 / 网络资源虚拟分集统一入口。
    func playbackPhoto(id: UUID) -> PhotoItem? {
        if let photo = catalogPlaybackPhoto(for: id) { return photo }
        if let photo = tvPlaybackPhoto(for: id) { return photo }
        if let entry = cinemaPlaybackEntry, entry.file.photoID == id { return entry.file.photoItem }
        if let photo = anyPhoto(id: id) { return photo }
        if let photo = cloudPhotos.first(where: { $0.id == id }) { return photo }
        for entries in cinemaIndexes.values {
            if let entry = entries[id] { return entry.file.photoItem }
        }
        return nil
    }

    /// 把一个照片 / 虚拟分集映射成统一播放目标：用于模式、能力与后续进度定位。
    func playbackTarget(for photo: PhotoItem) -> PlaybackTarget {
        if let channel = tvPlaybackChannel(for: photo.id) {
            // 回看是「过去某一段时间」：必须按点播处理，有真实时长、可拖动、可续播；
            // 只有直播才用 .live（不写续播、可回到直播沿）。
            // 以前这里一律 .live，回看会被当成直播流，画面边播边追流，就会出现跳着播。
            return PlaybackTarget(storage: .provider(sourceID: .television(channel.playlistID),
                                                     itemID: photo.id.uuidString,
                                                     episodeID: nil),
                                  mode: channel.isCatchUp ? .vod : .live,
                                  title: channel.name,
                                  artworkURL: channel.logoURL)
        }
        if let context = catalogPlaybackContext(for: photo.id) {
            return PlaybackTarget(storage: .provider(sourceID: .catalog(context.source.id),
                                                     itemID: context.item.id,
                                                     episodeID: String(context.episode.index)),
                                  mode: .vod,
                                  title: context.item.title)
        }
        if let entry = cinemaEntry(for: photo)
            ?? (cinemaPlaybackEntry?.file.photoID == photo.id ? cinemaPlaybackEntry : nil) {
            let sourceID: SourceID = entry.file.cloudMountID.map(SourceID.mountCinema) ?? .localCinema
            return PlaybackTarget(storage: .provider(sourceID: sourceID,
                                                     itemID: photo.id.uuidString,
                                                     episodeID: nil),
                                  mode: .vod,
                                  title: entry.title,
                                  artworkURL: entry.gridArtworkURL)
        }
        if photo.isCloud, let mountID = photo.cloudMountID {
            return PlaybackTarget(storage: .provider(sourceID: .cloud(mountID),
                                                     itemID: photo.id.uuidString,
                                                     episodeID: nil),
                                  mode: .vod,
                                  title: photo.title ?? photo.originalName)
        }
        let path = (LibraryPaths.containerLibraryURL ?? LibraryPaths.root).standardizedFileURL.path
        return PlaybackTarget(storage: .provider(sourceID: .library(path),
                                                 itemID: photo.id.uuidString,
                                                 episodeID: nil),
                              mode: .vod,
                              title: photo.title ?? photo.originalName)
    }

    func resolvePlaybackStream(for photo: PhotoItem) async throws -> ResolvedStream {
        // 网络电视：直播流不走续播与转码，直接把频道地址交给播放器。
        if let stream = resolveTVStream(for: photo.id) { return stream }
        // 网络资源：按虚拟分集取当前集的播放直链。
        if let context = catalogPlaybackContext(for: photo.id) {
            let stream = try await catalog.stream(source: context.source, episode: context.episode)
            return ResolvedStream(url: stream.url,
                                  headers: stream.headers,
                                  isHLS: stream.isHLS,
                                  mode: .vod)
        }

        // 云盘：官方转码可能返回 HLS，其他情况返回直链或代理地址。
        if photo.isCloud {
            let stream = try await cloudStreamOrThrow(for: photo)
            let mount = cloudMount(for: photo.cloudMountID)
            return ResolvedStream(url: stream.url,
                                  headers: stream.headers,
                                  isHLS: stream.isHLS,
                                  mode: .vod,
                                  trustSelfSigned: mount?.trustSelfSigned ?? false)
        }

        // 本地文件：图库 originals / 外置路径。
        return ResolvedStream(url: LibraryPaths.sourceURL(for: photo),
                              headers: [:],
                              isHLS: false,
                              mode: .vod)
    }
}

/// 播放 Provider 注册表：把历史图库 / 云盘 / 影院 / 网络资源的 `.provider` 目标
/// 解析回现有片源流程，新源只需要在 `LibraryStore.resolvePlaybackStream` 里追加分支。
@MainActor
final class LibraryPlaybackProvider: PlaybackResolving {
    private unowned let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    func resolve(_ target: PlaybackTarget) async throws -> ResolvedStream {
        switch target.storage {
        case .localFile, .remote:
            return try await DirectPlaybackResolver().resolve(target)
        case .provider(_, let itemID, _):
            guard let uuid = UUID(uuidString: itemID),
                  let photo = store.playbackPhoto(id: uuid) else {
                throw SourceError.unsupported("找不到要播放的条目：\(itemID)")
            }
            return try await store.resolvePlaybackStream(for: photo)
        }
    }
}
