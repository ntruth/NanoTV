import Foundation

/// 元数据工作流：评分、旗标、色标与层级关键词。
/// 本地图库写入 `assets`；官方「照片」图库写入拾光的 `asset_overlays`，不修改 `Photos.sqlite`。
extension LibraryStore {
    /// 当前是否可以对所选项目修改评分 / 旗标 / 色标。
    /// 网盘照片的标记只记在本机 settings（`cloud_marks`），不写回网盘。
    var canEditRatingFlagColor: Bool {
        if isCloudScope { return true }
        return (!isReadOnlyScope && !isCloudScope) || canEditNativeOverlay
    }

    var canEditMetadataWorkflow: Bool {
        isCloudScope || (!isReadOnlyScope || canEditNativeOverlay)
    }

    func setRating(_ rating: Int, ids: Set<UUID>) {
        guard canEditMetadataWorkflow, !ids.isEmpty else { return }
        let value = min(5, max(0, rating))
        if isCloudScope {
            updateCloudMarks(ids) { mark in
                let next: Int? = value == 0 ? nil : value
                guard mark.rating != next else { return false }
                mark.rating = next
                return true
            }
            return
        }
        let systemIDs = ids.filter { isSystemPhotoID($0) }
        let localIDs = ids.subtracting(systemIDs)
        if !systemIDs.isEmpty {
            setSystemRating(value, ids: systemIDs)
        }
        guard !localIDs.isEmpty, !isSystemScope else { return }
        let beforePhotos = photoSnapshot(localIDs)
        var changed = false
        for index in photos.indices where localIDs.contains(photos[index].id) {
            if photos[index].starRating != value {
                photos[index].rating = value
                changed = true
            }
        }
        guard changed else { return }
        save()
        recordUndo(value == 0 ? "清除评分" : "设置 \(value) 星评分", beforePhotos: beforePhotos)
    }

    func setFlag(_ flag: PhotoFlag, ids: Set<UUID>) {
        guard canEditMetadataWorkflow, !ids.isEmpty else { return }
        if isCloudScope {
            updateCloudMarks(ids) { mark in
                let next: PhotoFlag? = flag == .none ? nil : flag
                guard mark.flag != next else { return false }
                mark.flag = next
                return true
            }
            return
        }
        let systemIDs = ids.filter { isSystemPhotoID($0) }
        let localIDs = ids.subtracting(systemIDs)
        if !systemIDs.isEmpty {
            setSystemFlag(flag, ids: systemIDs)
        }
        guard !localIDs.isEmpty, !isSystemScope else { return }
        let beforePhotos = photoSnapshot(localIDs)
        var changed = false
        for index in photos.indices where localIDs.contains(photos[index].id) {
            if photos[index].pickFlag != flag {
                photos[index].flag = flag
                changed = true
            }
        }
        guard changed else { return }
        save()
        recordUndo(flag == .none ? "清除旗标" : "设置旗标：\(flag.title)", beforePhotos: beforePhotos)
    }

    func setColorLabel(_ label: PhotoColorLabel, ids: Set<UUID>) {
        guard canEditMetadataWorkflow, !ids.isEmpty else { return }
        if isCloudScope {
            updateCloudMarks(ids) { mark in
                let next: PhotoColorLabel? = label == .none ? nil : label
                guard mark.colorLabel != next else { return false }
                mark.colorLabel = next
                return true
            }
            return
        }
        let systemIDs = ids.filter { isSystemPhotoID($0) }
        let localIDs = ids.subtracting(systemIDs)
        if !systemIDs.isEmpty {
            setSystemColorLabel(label, ids: systemIDs)
        }
        guard !localIDs.isEmpty, !isSystemScope else { return }
        let beforePhotos = photoSnapshot(localIDs)
        var changed = false
        for index in photos.indices where localIDs.contains(photos[index].id) {
            if photos[index].labelColor != label {
                photos[index].colorLabel = label
                changed = true
            }
        }
        guard changed else { return }
        save()
        recordUndo(label == .none ? "清除色标" : "设置色标：\(label.title)", beforePhotos: beforePhotos)
    }

    func setRatingCurrent(_ rating: Int) {
        setRating(rating, ids: commandTargetIDs)
    }

    func setFlagCurrent(_ flag: PhotoFlag) {
        setFlag(flag, ids: commandTargetIDs)
    }

    func setColorLabelCurrent(_ label: PhotoColorLabel) {
        setColorLabel(label, ids: commandTargetIDs)
    }

    /// 层级关键词使用 `/` 分隔；添加时只补整条路径，不自动创建父级。
    func addKeywordPath(_ path: String, to ids: Set<UUID>) {
        addKeyword(path, to: ids)
    }

    /// 判断某张照片是否命中当前评分 / 旗标 / 色标筛选。
    func matchesMetadataFilters(_ photo: PhotoItem) -> Bool {
        if ratingFilter > 0, photo.starRating < ratingFilter { return false }
        if let flagFilter, photo.pickFlag != flagFilter { return false }
        if let colorLabelFilter, photo.labelColor != colorLabelFilter { return false }
        return true
    }

    var hasMetadataFilters: Bool {
        ratingFilter > 0 || flagFilter != nil || colorLabelFilter != nil
    }

    func clearMetadataFilters() {
        ratingFilter = 0
        flagFilter = nil
        colorLabelFilter = nil
    }
}
