import Foundation
import LumaContentCore

/// 网盘派生缓存的回填与落库：EXIF、场景识别、特征向量、查看记录、体检 / 美化报告。
/// 全部写当前图库自己的 `Luma.sqlite`，不写 NAS / 网盘，也不写 Apple 的数据库。
extension LibraryStore {
    /// 远端文件变化判断：大小不同说明已被替换，缓存作废。
    private func cloudCacheRow(_ row: CloudAssetCacheRow, matches photo: PhotoItem) -> Bool {
        if let size = row.size, size != photo.fileSize { return false }
        return true
    }

    /// 目录列表载入后，把数据库里的 EXIF / 识别 / 特征 / 查看记录回填到照片上。
    func hydrateCloudCache(photos: [PhotoItem], mountID: UUID) -> [PhotoItem] {
        guard let store = metadataStore else { return photos }
        let rows = store.loadCloudAssets(mountID: mountID)
        guard !rows.isEmpty else { return photos }
        var result = photos
        for index in result.indices {
            guard let path = result[index].cloudPath,
                  let row = rows[path],
                  cloudCacheRow(row, matches: result[index]) else { continue }
            var photo = result[index]
            if let exif = row.exif {
                Self.applyCloudEXIFFields(exif, to: &photo)
            }
            if let viewedAt = row.viewedAt {
                photo.viewedAt = viewedAt
                cloudModel.viewedAt[photo.id] = viewedAt
            }
            if row.metadataAt != nil {
                cloudModel.metadataScanned.insert(photo.id)
            }
            if row.peopleAt != nil {
                cloudModel.peopleScanned.insert(photo.id)
            }
            if row.analyzedAt != nil {
                let labels = Set((row.labels ?? "").split(separator: " ").map { $0.lowercased() })
                cloudModel.analysis[photo.id] = PhotoAnalysis(
                    labels: labels,
                    text: row.text ?? "",
                    searchBlob: ((row.labels ?? "") + " " + (row.text ?? "")).lowercased()
                )
            }
            if let feature = row.feature, !feature.isEmpty {
                cloudModel.features[photo.id] = feature
            }
            result[index] = photo
        }
        // 特征向量从轻量查询里拆出来了：每个挂载只加载一次，避免每次切目录都搬 BLOB。
        scheduleCloudFeatureLoadIfNeeded(mountID: mountID, store: store)
        return result
    }

    /// 后台加载这个挂载已落库的特征向量，合并进内存一次。
    private func scheduleCloudFeatureLoadIfNeeded(mountID: UUID, store: MetadataStore) {
        guard cloudModel.featuresLoadedMountID != mountID,
              !cloudModel.isLoadingCloudFeatures else { return }
        cloudModel.isLoadingCloudFeatures = true
        let jobID = beginSourceJob(
            SourceJob(sourceID: .cloud(mountID), kind: .index, title: "加载网盘特征", isCancellable: false)
        )
        Task { [weak self] in
            let features = await Task.detached(priority: .utility) {
                store.loadCloudFeatures(mountID: mountID)
            }.value
            guard let self else { return }
            self.cloudModel.isLoadingCloudFeatures = false
            self.cloudModel.featuresLoadedMountID = mountID
            guard !features.isEmpty else {
                self.finishSourceJob(jobID, message: "没有已缓存的特征")
                return
            }
            var pathToID: [String: UUID] = [:]
            pathToID.reserveCapacity(self.cloudModel.scanPhotos.count)
            for photo in self.cloudModel.scanPhotos {
                if let path = photo.cloudPath { pathToID[path] = photo.id }
            }
            // 扫描清单还没到时先不算完成，下次载入目录再补一次。
            guard !pathToID.isEmpty else {
                self.cloudModel.featuresLoadedMountID = nil
                self.finishSourceJob(jobID, message: "等待扫描清单")
                return
            }
            var merged = self.cloudModel.features
            for (path, data) in features {
                if let id = pathToID[path] { merged[id] = data }
            }
            if !merged.isEmpty { self.cloudModel.features = merged }
            self.finishSourceJob(jobID, message: "已加载 \(features.count.formatted()) 条特征")
        }
    }

    /// 打开某个网盘时回填人物聚类结果与已扫描标记。
    func loadCloudCacheForMount(_ mountID: UUID) {
        guard let store = metadataStore else { return }
        let people = store.loadCloudPeople(mountID: mountID)
        if !people.isEmpty {
            cloudModel.people = people
            cloudScopeCountsCacheKey = nil
        }
    }

    /// 回填当前网盘目录的体检与美化推荐（结果按目录分开缓存）。
    func restoreCloudDerivedReports(mountID: UUID, path: String) {
        guard let store = metadataStore else { return }
        let ids = Set(cloudPhotos.map(\.id))
        if let cached = store.loadDerivedReport(key: DerivedReportKey.cloud(mountID, path, "health")),
           let report = try? JSONDecoder().decode(LibraryHealthReport.self, from: cached.payload) {
            cloudModel.healthReport = report.filtered(to: ids)
        }
        if let cached = store.loadDerivedReport(key: DerivedReportKey.cloud(mountID, path, "beauty")),
           let report = try? JSONDecoder().decode(BeautyReport.self, from: cached.payload) {
            beautyReport = report
            beautyReportIsSystem = false
            cloudModel.beautyReportIsCloud = true
        }
        cloudScopeCountsCacheKey = nil
        cloudVisibleCacheKey = nil
    }

    /// 体检完成后把结果写入当前图库数据库。
    func persistCloudHealthReport(_ report: LibraryHealthReport) {
        guard let mountID = currentCloudMountID ?? cloudModel.insightMountID,
              let store = metadataStore,
              let data = try? JSONEncoder().encode(report) else { return }
        let key = DerivedReportKey.cloud(mountID, cloudPath, "health")
        store.saveDerivedReport(key: key, signature: "cloud#\(cloudPhotos.count)", payload: data)
    }
}
