import Foundation
import LumaCore

/// 一组重复项目：同一张照片的多个副本（文件大小与像素尺寸相同）。
/// `photos` 已按建议保留顺序排列，第一张为推荐保留项。
struct DuplicateGroup: Identifiable {
    let photos: [PhotoItem]
    let pick: DuplicatePick

    /// 推荐保留项的照片 ID，全局唯一，可直接作为列表标识。
    var id: UUID { pick.photo.id }
    var keepID: UUID { pick.photo.id }
    var keepReasons: [String] { pick.reasons }
    var capturedAt: Date { pick.photo.capturedAt }

    /// 合并后可释放的字节数（保留项以外的副本总和）。
    var reclaimableBytes: Int64 {
        photos.reduce(Int64(0)) { $0 + ($1.id == keepID ? 0 : $1.fileSize) }
    }
}

/// 组内推荐保留的照片与理由（用于界面标注「建议保留」）。
struct DuplicatePick {
    let photo: PhotoItem
    let reasons: [String]
}

/// 重复项目检测：按「文件大小 + 像素尺寸」聚合，再按可保留价值挑出建议保留项。
/// 纯计算，不读写文件与数据库。
enum DuplicateDetector {
    /// 返回按可释放空间从大到小排序的重复组。
    /// `mergeFlagged` 为 true 时（系统图库），再把官方标记为重复、但文件大小与主分组对不上的项目
    /// 按「像素尺寸 + 原文件名」补成额外分组，覆盖元数据不同导致体积不一致的副本。
    static func groups(from photos: [PhotoItem],
                       albumMembership: [UUID: Int] = [:],
                       mergeFlagged: Bool = false) -> [DuplicateGroup] {
        var buckets: [String: [PhotoItem]] = [:]
        for photo in photos where photo.deletedAt == nil && !photo.isHidden {
            guard photo.fileSize > 0, photo.pixelWidth > 0, photo.pixelHeight > 0 else { continue }
            // 有内容哈希时优先按字节完全相同归组；没有哈希的旧资产继续按大小 + 尺寸兜底。
            let key: String
            if let hash = photo.contentHash, !hash.isEmpty {
                key = "content-\(hash)"
            } else {
                key = "\(photo.fileSize)-\(photo.pixelWidth)x\(photo.pixelHeight)"
            }
            buckets[key, default: []].append(photo)
        }
        var groups = buckets.values
            .filter { $0.count > 1 }
            .compactMap { makeGroup($0, albumMembership: albumMembership) }

        if mergeFlagged {
            let covered = Set(groups.flatMap { $0.photos.map(\.id) })
            var flagged: [String: [PhotoItem]] = [:]
            for photo in photos where photo.isDuplicateItem
                && !photo.isHidden && photo.deletedAt == nil
                && !covered.contains(photo.id)
                && photo.pixelWidth > 0 && photo.pixelHeight > 0 {
                let key = "\(photo.pixelWidth)x\(photo.pixelHeight)-\(photo.originalName.lowercased())"
                flagged[key, default: []].append(photo)
            }
            groups.append(contentsOf: flagged.values
                .filter { $0.count > 1 }
                .compactMap { makeGroup($0, albumMembership: albumMembership) })
        }

        return groups.sorted { lhs, rhs in
            if lhs.reclaimableBytes != rhs.reclaimableBytes {
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            return lhs.capturedAt > rhs.capturedAt
        }
    }

    private static func makeGroup(_ members: [PhotoItem],
                                  albumMembership: [UUID: Int]) -> DuplicateGroup? {
        guard let pick = pickBest(in: members, albumMembership: albumMembership) else { return nil }
        let ordered = [pick.photo] + members
            .filter { $0.id != pick.photo.id }
            .sorted { $0.addedAt > $1.addedAt }
        return DuplicateGroup(photos: ordered, pick: pick)
    }

    /// 推荐保留顺序：已收藏 > 含编辑 > 已加入相簿 > 有标题 / 关键词 > 分辨率 > 文件大小 > 更早导入。
    private static func pickBest(in members: [PhotoItem],
                                 albumMembership: [UUID: Int]) -> DuplicatePick? {
        let maxPixels = members.map { $0.pixelWidth * $0.pixelHeight }.max() ?? 0
        let maxBytes = members.map(\.fileSize).max() ?? 0

        var best: (photo: PhotoItem, score: Double, reasons: [String])?

        for photo in members {
            var score = Double(photo.pixelWidth) * Double(photo.pixelHeight)
            score += Double(photo.fileSize) * 0.001
            var reasons: [String] = []

            if photo.isFavorite {
                score += 1e9
                reasons.append("已收藏")
            }
            if photo.hasEdits || photo.editedAt != nil {
                score += 5e8
                reasons.append("保留编辑结果")
            }
            let albumCount = albumMembership[photo.id] ?? 0
            if albumCount > 0 {
                score += Double(albumCount) * 2e5
                reasons.append(albumCount == 1 ? "已加入相簿" : "已加入 \(albumCount) 个相簿")
            }
            if !(photo.title ?? "").isEmpty || !(photo.keywords ?? []).isEmpty {
                score += 1e4
                reasons.append("有标题或关键词")
            }
            if photo.pixelWidth * photo.pixelHeight == maxPixels {
                reasons.append("分辨率最高")
            }
            if photo.fileSize == maxBytes, maxPixels == photo.pixelWidth * photo.pixelHeight {
                reasons.append("文件最大")
            }
            if photo.viewedAt != nil {
                score += 1e3
            }

            if let current = best {
                if score > current.score
                    || (score == current.score && photo.addedAt < current.photo.addedAt) {
                    best = (photo, score, reasons)
                }
            } else {
                best = (photo, score, reasons)
            }
        }

        guard let best else { return nil }
        return DuplicatePick(photo: best.photo, reasons: Array(best.reasons.prefix(3)))
    }
}

/// 相似照片组：按感知哈希 + 拍摄时间窗口 + 宽高比接近归组。
/// 只用于展示与人工判断，不自动合并；避免把同一场景的不同瞬间误删。
struct SimilarPhotoGroup: Identifiable {
    let photos: [PhotoItem]
    let representative: PhotoItem

    var id: UUID { representative.id }
}

enum SimilarPhotoDetector {
    static func groups(from photos: [PhotoItem],
                       threshold: Int = 10,
                       timeWindow: TimeInterval = 600) -> [SimilarPhotoGroup] {
        let candidates = photos.filter {
            $0.deletedAt == nil && !$0.isHidden && !$0.isVideo
                && $0.perceptualHash != nil && $0.pixelWidth > 0 && $0.pixelHeight > 0
        }.sorted { $0.capturedAt < $1.capturedAt }
        guard candidates.count > 1 else { return [] }

        var buckets: [Int: [PhotoItem]] = [:]
        for photo in candidates {
            let bucket = Int(photo.capturedAt.timeIntervalSince1970 / max(1, timeWindow))
            buckets[bucket, default: []].append(photo)
        }

        var result: [SimilarPhotoGroup] = []
        for bucket in buckets.values {
            guard bucket.count > 1 else { continue }
            var groups: [[PhotoItem]] = []
            for photo in bucket {
                guard let hash = photo.perceptualHash else { continue }
                var placed = false
                for index in groups.indices {
                    guard let anchor = groups[index].first,
                          let anchorHash = anchor.perceptualHash else { continue }
                    guard abs(photo.capturedAt.timeIntervalSince(anchor.capturedAt)) <= timeWindow else { continue }
                    guard ratioClose(photo, anchor) else { continue }
                    if PerceptualHash.isSimilar(hash, anchorHash, threshold: threshold) {
                        groups[index].append(photo)
                        placed = true
                        break
                    }
                }
                if !placed {
                    groups.append([photo])
                }
            }
            for group in groups where group.count > 1 {
                // 字节完全相同的副本交给「重复项目」，相似页不重复展示。
                let hashes = Set(group.compactMap(\.contentHash))
                if hashes.count == 1, group.allSatisfy({ $0.contentHash != nil }) { continue }
                guard let representative = pickRepresentative(group) else { continue }
                result.append(SimilarPhotoGroup(photos: group, representative: representative))
            }
        }
        return result.sorted {
            if $0.photos.count != $1.photos.count { return $0.photos.count > $1.photos.count }
            return $0.representative.capturedAt > $1.representative.capturedAt
        }
    }

    private static func ratioClose(_ lhs: PhotoItem, _ rhs: PhotoItem) -> Bool {
        let left = Double(lhs.pixelWidth) / Double(max(1, lhs.pixelHeight))
        let right = Double(rhs.pixelWidth) / Double(max(1, rhs.pixelHeight))
        guard left > 0, right > 0 else { return false }
        let ratio = max(left, right) / min(left, right)
        let pixelRatio = Double(max(lhs.pixelWidth * lhs.pixelHeight, rhs.pixelWidth * rhs.pixelHeight))
            / Double(max(1, min(lhs.pixelWidth * lhs.pixelHeight, rhs.pixelWidth * rhs.pixelHeight)))
        return ratio <= 1.25 && pixelRatio <= 4
    }

    private static func pickRepresentative(_ photos: [PhotoItem]) -> PhotoItem? {
        photos.max { lhs, rhs in
            score(lhs) < score(rhs)
        }
    }

    private static func score(_ photo: PhotoItem) -> Double {
        var value = Double(photo.pixelWidth) * Double(photo.pixelHeight)
        value += Double(photo.fileSize) * 0.001
        value += Double(photo.starRating) * 1e8
        if photo.isFavorite { value += 5e8 }
        if photo.hasEdits { value += 2e8 }
        if photo.pickFlag == .pick { value += 1e8 }
        if photo.pickFlag == .reject { value -= 1e9 }
        return value
    }
}
