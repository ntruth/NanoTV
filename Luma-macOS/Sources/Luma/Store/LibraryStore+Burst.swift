import Foundation

extension LibraryStore {
    // MARK: - 连拍快照

    /// 载入当前查看照片所在的连拍组（按拍摄时间升序）。
    /// 与官方「照片」一致：打开连拍代表图后就进入整组浏览。
    func refreshViewerBurstGroup() {
        guard let id = viewerID, let photo = anyPhoto(id: id),
              let group = photo.burstGroupID, !group.isEmpty else {
            clearViewerBurstState()
            return
        }
        let members = burstGroupMembers(groupID: group)
        // 有效成员只剩一张时按普通照片浏览，不显示连拍标题与播放。
        guard members.count > 1 else {
            clearViewerBurstState()
            return
        }
        guard viewerModel.burstMembers.map(\.id) != members.map(\.id) else { return }
        viewerModel.burstMembers = members
        viewerModel.burstSelectionMode = false
        viewerModel.burstSelection = []
        viewerModel.burstPlaying = false
    }

    func clearViewerBurstState() {
        viewerModel.burstMembers = []
        viewerModel.burstPlaying = false
        viewerModel.burstSelectionMode = false
        viewerModel.burstSelection = []
    }

    /// 取一个连拍组的有效成员：系统图库优先走索引 / 直连的单组查询，
    /// 尚未建索引时从已载入内容过滤；本地图库直接过滤 `photos`。
    private func burstGroupMembers(groupID: String) -> [PhotoItem] {
        if isSystemScope {
            if let index = systemIndex {
                let members = index.burstMembers(groupID: groupID)
                if !members.isEmpty {
                    return members
                        .filter { $0.deletedAt == nil && !$0.isHidden }
                        .map { applySystemOverlay($0) }
                }
            }
            return systemPhotos
                .filter { $0.burstGroupID == groupID && $0.deletedAt == nil && !$0.isHidden }
                .sorted { $0.capturedAt < $1.capturedAt }
                .map { applySystemOverlay($0) }
        }
        return photos
            .filter { $0.burstGroupID == groupID && $0.deletedAt == nil && !$0.isHidden }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    // MARK: - 组内选择与处理

    func toggleBurstSelection(_ id: UUID) {
        if viewerModel.burstSelection.contains(id) {
            viewerModel.burstSelection.remove(id)
        } else {
            viewerModel.burstSelection.insert(id)
        }
    }

    func selectAllBurstMembers() {
        viewerModel.burstSelection = Set(viewerModel.burstMembers.map(\.id))
    }

    /// 收藏组内所选：官方「照片」图库经 PhotoKit 写回，其余范围只记录在拾光。
    func favoriteBurstSelection() {
        let ids = viewerModel.burstSelection
        guard !ids.isEmpty else {
            showToast("请先选择要收藏的照片")
            return
        }
        guard canToggleFavorite else {
            showToast("当前图库不支持修改收藏")
            return
        }
        if isSystemScope, canEditNativeOverlay {
            setSystemFavorite(true, ids: ids)
        } else if !ids.allSatisfy({ anyPhoto(id: $0)?.isFavorite == true }) {
            // 本地图库：只在还有未收藏项时统一切换为收藏，避免把已收藏的又取消。
            toggleFavorite(ids: ids)
        }
        // 组内缓存同步标记，胶片条上的收藏状态立即生效。
        for index in viewerModel.burstMembers.indices
        where ids.contains(viewerModel.burstMembers[index].id) {
            viewerModel.burstMembers[index].isFavorite = true
        }
        showToast("已收藏所选 \(ids.count) 张")
    }

    /// 保留组内所选，其余移入最近删除：官方图库经 PhotoKit，本地图库走确认卡片。
    func deleteBurstPhotos(keeping keep: Set<UUID>) {
        let members = viewerModel.burstMembers
        guard !members.isEmpty else { return }
        let removeIDs = members.map(\.id).filter { !keep.contains($0) }
        guard !removeIDs.isEmpty else {
            showToast("请先选择要保留的照片")
            return
        }
        if isSystemScope {
            deleteSystemBurstPhotos(removeIDs: removeIDs, keeping: keep)
            return
        }
        guard !isReadOnlyScope else {
            showToast("当前来源不支持删除")
            return
        }
        confirmDelete(Set(removeIDs))
    }

    private func deleteSystemBurstPhotos(removeIDs: [UUID], keeping keep: Set<UUID>) {
        guard canDeleteSystemPhotos else {
            showToast("只有官方「照片」图库作为当前图库时才能删除")
            return
        }
        Task {
            guard await PhotoKitBridge.ensureAuthorized() else {
                self.showToast("需要相册读写权限，请在系统设置中允许拾光访问照片")
                return
            }
            do {
                try await PhotoKitBridge.delete(assetIDs: removeIDs)
            } catch {
                self.showToast("移入「照片」的最近删除失败：\(error.localizedDescription)")
                return
            }
            self.removeSystemPhotosFromMemory(Set(removeIDs))
            let survivors = self.viewerModel.burstMembers.filter { keep.contains($0.id) }
            self.viewerModel.burstMembers = survivors
            self.viewerModel.burstSelectionMode = false
            self.viewerModel.burstSelection = []
            self.viewerModel.burstPlaying = false
            if let first = survivors.first {
                self.viewerID = first.id
            } else {
                self.closeViewer()
            }
            self.showToast("已保留 \(survivors.count) 张，其余移到「照片」的最近删除")
        }
    }
}
