import Foundation

/// 系统图库的派生缓存落库：端侧识别结果、特征向量与体检 / 美化报告。
/// 全部写当前图库自己的 `Luma.sqlite`，不写 Apple 的 `Photos.sqlite`。
extension LibraryStore {
    /// 当前系统图库的缓存签名（只取图库路径）。
    /// 照片增删不应该让整库识别缓存作废；同一路径被另一个图库替换时由 `purgeSystemCache` 手动清理。
    var systemCacheSignature: String {
        systemLibraryPath ?? ""
    }

    /// 载入系统图库后回填识别结果与特征；图库被替换时先清掉旧缓存。
    func hydrateSystemCacheIfNeeded() {
        guard isSystemScope, let store = metadataStore, let path = systemLibraryPath else { return }
        let signature = systemCacheSignature
        let cachedSignature = store.systemAnalysisSignature(path)
        if let cachedSignature, cachedSignature != signature {
            store.purgeSystemCache(libraryPath: path)
            store.removeDerivedReports(prefix: DerivedReportKey.systemPrefix(path))
            systemAnalysisIndex = [:]
            systemFeatures = [:]
            healthReport = nil
            healthReportScopeTag = nil
            beautyReport = nil
            beautyReportIsSystem = false
            systemPendingAnalysisCacheKey = nil
            sceneSummaryCacheKey = nil
            systemAnalysisAutoResume = false
            contentRevision &+= 1
        }
        // 用户上次没跑完识别就关库 / 切库：这个标记也随图库保存，回来后自动接着跑。
        if store.systemAnalysisAutoResume(path) {
            systemAnalysisAutoResume = true
        }
        guard systemAnalysisIndex.isEmpty, systemAnalysisHydration == nil else { return }

        // 十万级图库同步在读回识别结果会在加载完成的瞬间卡住主线程（还会连带搬走所有特征向量）。
        // 这里放到后台线程读，只回填标签 / 文字；特征向量由体检 / 相似检索按需现算。
        systemAnalysisHydration = Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) {
                store.loadSystemAnalysis(libraryPath: path)
            }.value
            guard let self else { return }
            defer { self.systemAnalysisHydration = nil }
            guard self.isSystemScope, self.systemLibraryPath == path, !rows.isEmpty else { return }
            var index: [UUID: PhotoAnalysis] = [:]
            index.reserveCapacity(rows.count)
            for row in rows where row.analyzed {
                let labels = Set(row.labels.split(separator: " ").map { $0.lowercased() })
                index[row.id] = PhotoAnalysis(labels: labels,
                                              text: row.text,
                                              searchBlob: (row.labels + " " + row.text).lowercased())
            }
            self.systemAnalysisIndex = index
            self.systemPendingAnalysisCacheKey = nil
            self.sceneSummaryCacheKey = nil
            if cachedSignature == nil {
                store.setSystemAnalysisSignature(path, signature)
            }
            self.contentRevision &+= 1
            // 之前没跑完的识别：缓存读回后再续跑，避免把已识别的照片重跑一遍。
            self.resumeSystemAnalysisIfNeeded()
        }
    }

    /// 上次识别停下的查询偏移（关库 / 切库后从这里继续）。
    var systemAnalysisSavedOffset: Int {
        guard let path = systemLibraryPath, let store = metadataStore else { return 0 }
        return max(0, store.systemAnalysisCursor(path) ?? 0)
    }

    func saveSystemAnalysisOffset(_ offset: Int) {
        guard let path = systemLibraryPath, let store = metadataStore else { return }
        store.setSystemAnalysisCursor(path, offset)
    }

    /// 把「是否自动续跑识别」随当前系统图库持久化。
    func persistSystemAnalysisAutoResume(_ value: Bool) {
        guard let path = systemLibraryPath, let store = metadataStore else { return }
        store.setSystemAnalysisAutoResume(path, value)
    }

    /// 把识别结果写回当前图库数据库（分批调用，避免逐张写盘）。
    func persistSystemAnalysis(_ entries: [(id: UUID, labels: String, text: String, feature: Data?)]) {
        guard !entries.isEmpty,
              let store = metadataStore,
              let path = systemLibraryPath else { return }
        store.setSystemAnalysisSignature(path, systemCacheSignature)
        store.saveSystemAnalysis(libraryPath: path, entries: entries)
    }

    /// 把体检 / 相似检索现算的特征写回当前图库数据库。
    func persistSystemFeatures(_ entries: [(id: UUID, feature: Data)]) {
        guard !entries.isEmpty,
              let store = metadataStore,
              let path = systemLibraryPath else { return }
        store.setSystemAnalysisSignature(path, systemCacheSignature)
        store.saveSystemFeatures(libraryPath: path, entries: entries)
    }
}
