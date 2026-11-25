import Foundation

/// 删除生命周期：把「一张照片的所有痕迹」收敛到一处。
/// 永久删除与「最近删除」过期清理共用同一份清单，避免两条路径清理出不同结果。
extension LibraryStore {
    // MARK: - 文件产物

    /// 删除资产在磁盘上的全部产物：原图、实况照片配对视频、缩略图（含快速层）、
    /// 编辑渲染结果、视频转码缓存、压缩备份，以及网盘缩略图缓存。
    func purgeAssetArtifacts(_ photo: PhotoItem) {
        // 官方「照片」图库的原图与 derivative 属于 Apple，只读，绝不删除。
        guard !photo.isSystem else { return }
        let fm = FileManager.default

        // 库外媒体（蓝光原盘）没有 originals 副本：filename 为空，
        // 直接删 originals/<分片> 会误伤同分片的其他文件，必须显式跳过。
        if photo.externalPath == nil {
            try? fm.removeItem(at: LibraryPaths.originalURL(for: photo))
        }
        if let liveURL = LibraryPaths.livePhotoURL(for: photo) {
            try? fm.removeItem(at: liveURL)
        }
        let thumbnailURL = LibraryPaths.thumbnailURL(for: photo)
        let quickURL = LibraryPaths.quickThumbnailURL(for: photo)
        try? fm.removeItem(at: thumbnailURL)
        try? fm.removeItem(at: quickURL)
        // 索引也要同步：否则后续读取仍会认为这两张缩略图存在。
        ThumbnailFileIndex.shared.forget(path: thumbnailURL.path)
        ThumbnailFileIndex.shared.forget(path: quickURL.path)
        if let editedFilename = photo.editedFilename {
            try? fm.removeItem(at: LibraryPaths.edited.appendingPathComponent(editedFilename))
        }
        try? fm.removeItem(at: PhotoCompressor.backupDirectory(for: photo))
        try? fm.removeItem(at: LibraryPaths.transcodes
            .appendingPathComponent(photo.id.uuidString + ".mp4"))
        if let mountID = photo.cloudMountID, let path = photo.cloudPath {
            try? fm.removeItem(at: CloudPaths.thumbnailURL(mountID: mountID, path: path))
        }

        ImageLoader.invalidate(photo: photo)
        pruneEmptyShard(for: photo)
    }

    /// `originals` / `derivatives` 的分片目录删空后一并移除，避免永久删除后留下空目录。
    private func pruneEmptyShard(for photo: PhotoItem) {
        let fm = FileManager.default
        let shard = LibraryPaths.shard(for: photo.id)
        for base in [LibraryPaths.originals, LibraryPaths.derivatives] {
            let directory = base.appendingPathComponent(shard, isDirectory: true)
            guard let remaining = try? fm.contentsOfDirectory(atPath: directory.path),
                  remaining.isEmpty else { continue }
            try? fm.removeItem(at: directory)
        }
    }

    // MARK: - 元数据

    /// 从所有相簿的成员与封面引用中移除这些项目。
    /// 软删除与永久删除都必须调用：删掉的封面会回落到自动拼图封面。
    func detachFromAlbums(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        albums = albums.map { album in
            var album = album
            album.photoIDs.removeAll { ids.contains($0) }
            if let cover = album.coverPhotoID, ids.contains(cover) {
                album.coverPhotoID = nil
            }
            return album
        }
    }

    /// 清理资产在数据库与内存里的全部痕迹：
    /// 端侧分析结果、人脸扫描记录、人物关系、相簿成员与封面、官方图库的补充元数据。
    func purgeAssetMetadata(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }

        analysisIndex = analysisIndex.filter { !ids.contains($0.key) }
        // 内存里的人物聚类先按新照片集合修剪，再在数据库里按 asset_id 精确清掉关系。
        removeAssetsFromLocalPeople(ids)
        scannedFaceIDs.subtract(ids)
        for id in ids {
            systemOverlays[id] = nil
        }
        metadataStore?.removeAssetDerivedData(ids)

        detachFromAlbums(ids)
    }

    // MARK: - 删除确认（界面层优雅提示）

    /// 确认卡片的数据：最多 4 个预览项 + 照片 / 视频数量。
    /// 按来源各遍历一次，不逐项调用 `anyPhoto`（大选区下会是 O(n²)）。
    func deletionSummary(_ ids: Set<UUID>, limit: Int = 4)
        -> (preview: [PhotoItem], photos: Int, videos: Int) {
        guard !ids.isEmpty else { return ([], 0, 0) }
        var remaining = ids
        var preview: [PhotoItem] = []
        var photoCount = 0
        var videoCount = 0

        func consume(_ item: PhotoItem) {
            guard remaining.contains(item.id) else { return }
            remaining.remove(item.id)
            if item.isVideo {
                videoCount += 1
            } else {
                photoCount += 1
            }
            if preview.count < limit {
                preview.append(item)
            }
        }
        for item in photos {
            consume(item)
        }
        for item in cloudPhotos {
            consume(item)
        }
        for id in remaining {
            if let item = systemPhoto(id: id) {
                consume(item)
            }
        }
        // 找不到对应资产时按数量补齐，避免卡片显示的数量少于实际请求。
        photoCount += remaining.count
        return (preview, photoCount, videoCount)
    }

    /// 移到最近删除前先展示确认卡片；已经在最近删除里则直接转为永久删除确认。
    func confirmDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        // 官方「照片」图库作为当前图库：经 PhotoKit 移到「照片」的最近删除。
        if isSystemScope, canEditNativeOverlay {
            guard canWriteSystemLibrary else {
                showToast("当前图库只读，不能删除；请先在「照片」中打开这个图库")
                return
            }
            if sidebarItem == .systemTrash {
                showToast("已在「照片」的最近删除里；恢复或清空请在「照片」中操作")
                return
            }
            pendingDeletion = DeleteRequest(ids: ids, kind: .trash)
            return
        }
        guard !isReadOnlyScope else { return }
        if sidebarItem == .trash {
            confirmPermanentDelete(ids)
            return
        }
        pendingDeletion = DeleteRequest(ids: ids, kind: .trash)
    }

    /// 确认卡片的主按钮：按请求类型执行真正的删除。
    func performPendingDeletion() {
        guard let request = pendingDeletion else { return }
        pendingDeletion = nil
        switch request.kind {
        case .trash:
            if isSystemScope, canEditNativeOverlay {
                deleteSystemToPhotosTrash(request.ids)
            } else {
                delete(request.ids)
            }
        case .permanent:
            deletePermanently(request.ids)
        case .emptyTrash:
            emptyTrash()
        }
    }

    func cancelPendingDeletion() {
        pendingDeletion = nil
    }

    // MARK: - 断开连接确认

    /// 断开网络存储前先确认：会移除挂载并清理本机缩略图与收藏记录，网盘文件不受影响。
    func confirmRemoveCloudMount(_ id: UUID) {
        guard let mount = cloudMounts.first(where: { $0.id == id }) else { return }
        pendingDisconnect = DisconnectRequest(target: .cloudMount(id: id,
                                                                 name: mount.name,
                                                                 kind: mount.kind))
    }

    /// 断开系统图库前先确认：只移除侧边栏连接，不删除该图库的照片与元数据。
    func confirmRemoveSystemLibrary(path: String, name: String? = nil) {
        guard systemLibraries.contains(where: { isSameSystemLibraryPath($0.path, path) })
                || systemLibraryPath.map({ isSameSystemLibraryPath($0, path) }) == true else {
            return
        }
        let title = name
            ?? systemLibraries.first(where: { isSameSystemLibraryPath($0.path, path) })?.name
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        pendingDisconnect = DisconnectRequest(target: .systemLibrary(path: path, name: title))
    }

    /// 断开一个 App 图库前先确认：默认图库、当前图库都可以断开；
    /// 断开的若是当前图库，会退出到「创建或打开图库」界面，磁盘文件保留。
    func confirmDisconnectLibrary(path: String, name: String? = nil) {
        let title = name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let isCurrent = LibraryPaths.containerLibraryURL.map {
            isSameSystemLibraryPath($0.path, path)
        } ?? false
        pendingDisconnect = DisconnectRequest(target: .appLibrary(path: path,
                                                                  name: title,
                                                                  isCurrent: isCurrent))
    }

    /// 确认卡片的主按钮：执行断开。
    func performPendingDisconnect() {
        guard let request = pendingDisconnect else { return }
        pendingDisconnect = nil
        switch request.target {
        case .appLibrary(let path, _, _):
            disconnectLibrary(path)
        case .systemLibrary(let path, _):
            removeSystemLibrary(path)
        case .cloudMount(let id, _, _):
            removeCloudMount(id)
        }
    }

    func cancelPendingDisconnect() {
        pendingDisconnect = nil
    }

    /// 换库或退出时丢弃待确认请求（里面的 ID 属于上一个图库）。
    func resetConfirmationState() {
        pendingDeletion = nil
        pendingDisconnect = nil
    }
}
