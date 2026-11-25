import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 侧边栏拖拽排序

/// 「固定」分区的拖动数据：拾光 / 系统图库 / 网盘共用同一种拖拽类型。
func pinnedDragProviderForSidebar(_ item: PinnedSidebarItem) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: pinnedSidebarDragType.identifier,
                                        visibility: .ownProcess) { completion in
        completion(Data(item.id.utf8), nil)
        return nil
    }
    return provider
}

/// 「固定」分区的拖拽排序：只接受固定项自身的拖拽，照片拖拽仍交给相簿 / 文件夹处理。
func loadPinnedDragID(from info: DropInfo, completion: @escaping (String) -> Void) -> Bool {
    guard let provider = info.itemProviders(for: [pinnedSidebarDragType]).first else {
        return false
    }
    provider.loadDataRepresentation(forTypeIdentifier: pinnedSidebarDragType.identifier) { data, _ in
        guard let data, let raw = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            completion(raw)
        }
    }
    return true
}

struct PinnedReorderDropDelegate: DropDelegate {
    let target: PinnedSidebarItem
    let store: LibraryStore

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [pinnedSidebarDragType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        loadPinnedDragID(from: info) { id in
            store.movePinned(id: id, before: target.id)
        }
    }
}

/// 拖到「固定」列表末尾：移到最后一位。
struct PinnedEndDropDelegate: DropDelegate {
    let store: LibraryStore

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [pinnedSidebarDragType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        loadPinnedDragID(from: info) { id in
            store.movePinnedToEnd(id: id)
        }
    }
}

/// 网络资源的拖动数据：只带源 id，顺序落盘在源列表里。
func catalogSourceDragProvider(_ id: UUID) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: catalogSourceDragType.identifier,
                                        visibility: .ownProcess) { completion in
        completion(Data(id.uuidString.utf8), nil)
        return nil
    }
    return provider
}

private func loadCatalogSourceDragID(from info: DropInfo,
                                     completion: @escaping (UUID) -> Void) -> Bool {
    guard let provider = info.itemProviders(for: [catalogSourceDragType]).first else {
        return false
    }
    provider.loadDataRepresentation(forTypeIdentifier: catalogSourceDragType.identifier) { data, _ in
        guard let data, let raw = String(data: data, encoding: .utf8),
              let id = UUID(uuidString: raw) else { return }
        DispatchQueue.main.async {
            completion(id)
        }
    }
    return true
}

struct CatalogSourceReorderDropDelegate: DropDelegate {
    let target: UUID
    let catalog: CatalogBrowserModel
    var onTargeted: (Bool) -> Void = { _ in }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [catalogSourceDragType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        onTargeted(true)
    }

    func dropExited(info: DropInfo) {
        onTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        onTargeted(false)
        return loadCatalogSourceDragID(from: info) { id in
            withAnimation(.easeOut(duration: 0.16)) {
                catalog.moveSource(id, before: target)
            }
        }
    }
}

/// 拖到网络资源列表末尾：移到最后一位。
struct CatalogSourceEndDropDelegate: DropDelegate {
    let catalog: CatalogBrowserModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [catalogSourceDragType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        loadCatalogSourceDragID(from: info) { id in
            withAnimation(.easeOut(duration: 0.16)) {
                catalog.moveSourceToEnd(id)
            }
        }
    }
}

// MARK: - 网络电视源拖拽排序

/// 电视源的拖动数据：只带源 id，顺序由电视库的 position 决定。
func tvSourceDragProvider(_ id: UUID) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: tvSourceDragType.identifier,
                                        visibility: .ownProcess) { completion in
        completion(Data(id.uuidString.utf8), nil)
        return nil
    }
    return provider
}

private func loadTVSourceDragID(from info: DropInfo,
                                completion: @escaping @MainActor (UUID) -> Void) -> Bool {
    guard let provider = info.itemProviders(for: [tvSourceDragType]).first else {
        return false
    }
    provider.loadDataRepresentation(forTypeIdentifier: tvSourceDragType.identifier) { data, _ in
        guard let data, let raw = String(data: data, encoding: .utf8),
              let id = UUID(uuidString: raw) else { return }
        Task { @MainActor in
            completion(id)
        }
    }
    return true
}

struct TVSourceReorderDropDelegate: DropDelegate {
    let target: UUID
    let tv: IPTVBrowserModel
    var onTargeted: (Bool) -> Void = { _ in }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [tvSourceDragType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        onTargeted(true)
    }

    func dropExited(info: DropInfo) {
        onTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        onTargeted(false)
        return loadTVSourceDragID(from: info) { id in
            withAnimation(.easeOut(duration: 0.16)) {
                tv.movePlaylist(id, before: target)
            }
        }
    }
}

/// 拖到电视源列表末尾：移到最后一位。
struct TVSourceEndDropDelegate: DropDelegate {
    let tv: IPTVBrowserModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [tvSourceDragType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        loadTVSourceDragID(from: info) { id in
            withAnimation(.easeOut(duration: 0.16)) {
                tv.movePlaylistToEnd(id)
            }
        }
    }
}

// MARK: - 相簿封面

struct AlbumCoverView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cloud: CloudBrowserModel
    @EnvironmentObject private var settings: AppSettings
    let album: Album

    private var coverPhoto: PhotoItem? {
        if let coverID = album.coverPhotoID, album.photoIDs.contains(coverID),
           let cover = store.photo(id: coverID) {
            return cover
        }
        guard let first = album.photoIDs.first else { return nil }
        return store.photo(id: first)
    }

    var body: some View {
        Group {
            if let coverPhoto {
                PhotoThumbnailView(photo: coverPhoto, purpose: .cover(LumaMetrics.sidebarCoverSize))
            } else {
                RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
        .clipShape(RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous))
    }
}

struct SystemAlbumCoverView: View {
    @EnvironmentObject private var store: LibraryStore
    let albumID: Int64
    @State private var photo: PhotoItem?
    @State private var loadedAlbumID: Int64?

    var body: some View {
        Group {
            if let photo {
                PhotoThumbnailView(photo: photo, purpose: .cover(LumaMetrics.sidebarCoverSize))
            } else {
                RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: LumaMetrics.sidebarCoverSize, height: LumaMetrics.sidebarCoverSize)
        .clipShape(RoundedRectangle(cornerRadius: LumaMetrics.sidebarCoverRadius, style: .continuous))
        // 封面在后台查询并按相簿缓存：侧边栏有上百个相簿时，body 里逐行查库会直接卡住滚动。
        .task(id: albumID) {
            if loadedAlbumID != albumID { photo = nil }
            let loaded = await store.systemAlbumCover(albumID)
            guard !Task.isCancelled else { return }
            loadedAlbumID = albumID
            photo = loaded
        }
    }
}
