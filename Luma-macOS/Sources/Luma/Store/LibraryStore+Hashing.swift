import Foundation
import LumaContentCore

/// 查重 2.0：为本地资产补齐 SHA-256 与 dHash，并生成相似照片组。
/// 扫描在后台按 CPU 核数并发；结果逐批写回内存与 SQLite，可随时取消。
extension LibraryStore {
    var hashScanFraction: Double {
        guard hashScanTotal > 0 else { return 0 }
        return min(1, Double(hashScanCompleted) / Double(hashScanTotal))
    }

    var pendingHashCount: Int {
        photos.lazy.filter {
            $0.deletedAt == nil && ($0.contentHash == nil || (!$0.isVideo && $0.perceptualHash == nil))
        }.count
    }

    func startHashScanIfNeeded() {
        guard !isCloudScope, !isSystemScope, !isScanningHashes else { return }
        let pending = photos.filter {
            $0.deletedAt == nil && !$0.isHidden
                && ($0.contentHash == nil || (!$0.isVideo && $0.perceptualHash == nil))
        }
        guard !pending.isEmpty else {
            refreshSimilarPhotoGroups()
            return
        }
        isScanningHashes = true
        hashScanCompleted = 0
        hashScanTotal = pending.count
        let token = UUID()
        hashScanToken = token
        let libraryPath = (LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
            .standardizedFileURL.path
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(libraryPath), kind: .dedupe, title: "重复项哈希扫描"),
            cancel: { [weak self] in
                Task { @MainActor in self?.cancelHashScan() }
            }
        )
        hashScanTask = Task { [weak self] in
            guard let self else { return }
            let concurrency = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
            var index = 0
            while index < pending.count {
                if Task.isCancelled || self.hashScanToken != token { break }
                let end = min(index + concurrency, pending.count)
                let chunk = Array(pending[index..<end])
                let results = await withTaskGroup(of: (UUID, String?, Int64?).self,
                                                  returning: [(UUID, String?, Int64?)].self) { group in
                    for photo in chunk {
                        group.addTask(priority: .utility) {
                            // 库外媒体（蓝光原盘）没有 originals 副本，不能按路径哈希整张盘。
                            guard photo.externalPath == nil else { return (photo.id, nil, nil) }
                            let url = LibraryPaths.originalURL(for: photo)
                            guard FileManager.default.fileExists(atPath: url.path) else {
                                return (photo.id, nil, nil)
                            }
                            let result = PhotoHasher.hashes(for: url, includePerceptual: !photo.isVideo)
                            return (photo.id, result.sha256, result.perceptualHash)
                        }
                    }
                    var collected: [(UUID, String?, Int64?)] = []
                    for await result in group { collected.append(result) }
                    return collected
                }
                if Task.isCancelled || self.hashScanToken != token { break }
                let updates = results.filter { $0.1 != nil || $0.2 != nil }
                if !updates.isEmpty {
                    for (id, hash, perceptual) in updates {
                        if let index = self.photos.firstIndex(where: { $0.id == id }) {
                            if let hash { self.photos[index].contentHash = hash }
                            if let perceptual { self.photos[index].perceptualHash = perceptual }
                        }
                    }
                    self.metadataStore?.updateHashes(updates.map {
                        (id: $0.0, contentHash: $0.1, perceptualHash: $0.2)
                    })
                }
                index = end
                self.hashScanCompleted = index
                self.duplicateGroupsCacheKey = nil
                self.updateSourceJob(jobID,
                                     completed: index,
                                     total: pending.count,
                                     message: "已计算 \(index.formatted()) / \(pending.count.formatted()) 项")
            }
            guard self.hashScanToken == token else {
                self.cancelSourceJob(jobID)
                return
            }
            self.isScanningHashes = false
            self.hashScanTask = nil
            self.refreshSimilarPhotoGroups()
            if Task.isCancelled {
                self.cancelSourceJob(jobID)
            } else {
                self.finishSourceJob(jobID, message: "完成 · \(self.similarPhotoGroups.count) 组相似照片")
            }
            self.showToast("查重扫描完成：\(self.similarPhotoGroups.count) 组相似照片")
        }
    }

    func cancelHashScan() {
        hashScanTask?.cancel()
        hashScanTask = nil
        hashScanToken = UUID()
        isScanningHashes = false
    }

    func refreshSimilarPhotoGroups() {
        guard !isSystemScope, !isCloudScope else {
            similarPhotoGroups = []
            return
        }
        similarPhotoGroups = SimilarPhotoDetector.groups(from: photos)
    }

    func resetHashState() {
        cancelHashScan()
        similarPhotoGroups = []
        hashScanCompleted = 0
        hashScanTotal = 0
        duplicateGroupsCacheKey = nil
    }
}
