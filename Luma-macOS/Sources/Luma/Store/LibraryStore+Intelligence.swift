import Foundation
import SwiftUI
import LumaContentCore

/// 场景总览用的汇总：数量与封面各一次遍历算完。
struct SceneSummary {
    var counts: [String: Int] = [:]
    var covers: [String: PhotoItem] = [:]
    /// 封面候选 ID：系统图库索引模式下内存里没有照片对象，用它在索引里补封面。
    var coverIDs: [String: UUID] = [:]
}

/// 端侧智能分析：场景标签、OCR 文字与相似照片检索。本地图库写入数据库；
/// 系统图库（`systemAnalysisIndex`）的结果写入 `system_analysis`，网盘（`CloudBrowserModel.analysis`）写入 `cloud_assets`。
extension LibraryStore {
    // MARK: - 分析索引

    /// 打开图库后把已分析结果读入内存（只含标签与文字，不含特征向量）。
    func loadAnalysisIndex() {
        guard !isSystemScope, !isCloudScope, let store = metadataStore else {
            analysisIndex = [:]
            return
        }
        let rows = store.loadAnalysisIndex()
        var index: [UUID: PhotoAnalysis] = [:]
        index.reserveCapacity(rows.count)
        for row in rows {
            let labels = Set(row.labels.split(separator: " ").map { $0.lowercased() })
            index[row.id] = PhotoAnalysis(labels: labels,
                                          text: row.text,
                                          searchBlob: (row.labels + " " + row.text).lowercased())
        }
        analysisIndex = index
        sceneCountsCacheKey = nil
    }

    var canAnalyzeIntelligence: Bool {
        !isSystemScope && !isCloudScope && !needsLibrarySetup && metadataStore != nil
    }

    var analyzedCount: Int { analysisIndex.count }

    /// 当前范围是否依赖端侧分析结果（场景 / 图内文字）。
    var isAnalysisScope: Bool {
        switch sidebarItem {
        case .scene, .ocrTexts, .systemScene, .systemOcrTexts: return true
        default: return false
        }
    }

    /// 输入搜索词时按需载入人物名单，并把自然语言扩展成标准标签。
    func prepareSemanticSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        loadFaceDataIfNeeded()
        guard !query.isEmpty else {
            semanticSearchTask?.cancel()
            semanticSearchTask = nil
            semanticSearchQuery = ""
            if !semanticSearchTags.isEmpty { semanticSearchTags = [] }
            return
        }
        if query == semanticSearchQuery, semanticSearchTask != nil { return }
        semanticSearchQuery = query
        semanticSearchTask?.cancel()
        // 词表直配先立即生效，模型扩展结果随后补齐。
        let lexical = PhotoTagCatalog.shared?.searchTitles(for: query) ?? []
        if lexical != semanticSearchTags { semanticSearchTags = lexical }
        semanticSearchTask = Task { [weak self] in
            let expanded = await Task.detached(priority: .userInitiated) {
                SigLIPEngine.shared.expand(query: query)
            }.value
            guard let self, !Task.isCancelled, self.semanticSearchQuery == query else { return }
            var merged: [String] = []
            for tag in lexical + expanded where !merged.contains(tag) { merged.append(tag) }
            if merged != self.semanticSearchTags { self.semanticSearchTags = merged }
            self.semanticSearchTask = nil
        }
    }

    /// 信息面板「画面」一行：按标签目录顺序展示模型命中的中文标签。
    func photoTagTitles(for photo: PhotoItem) -> [String] {
        guard let analysis = analysisIndex[photo.id]
                ?? cloudModel.analysis[photo.id]
                ?? systemAnalysisIndex[photo.id] else { return [] }
        return SigLIPEngine.shared.canonicalTitles(from: analysis.labels)
    }

    /// 端侧分析出的场景中文名，用于信息面板的「智能标签」。
    /// 网盘与系统图库的识别结果只在内存里，这里一并读取。
    func sceneTitles(for photo: PhotoItem) -> [String] {
        guard let analysis = analysisIndex[photo.id]
                ?? cloudModel.analysis[photo.id]
                ?? systemAnalysisIndex[photo.id] else { return [] }
        return SceneCatalog.categories
            .filter { SceneCatalog.matches($0, analysis: analysis, photo: photo) }
            .map(\.title)
    }

    func ocrText(for photoID: UUID) -> String? {
        let text = (analysisIndex[photoID]
                    ?? cloudModel.analysis[photoID]
                    ?? systemAnalysisIndex[photoID])?.text
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// 内置地标表命中的地标名（坐标优先，其次 POI 文字），用于信息面板与场景判定。
    func landmarkName(for photo: PhotoItem) -> String? {
        SceneCatalog.landmarkName(for: photo)
    }

    /// 只分析当前这一张照片（例如在信息面板里点「分析此照片」）。
    func analyzeSinglePhoto(_ photoID: UUID) {
        guard canAnalyzeIntelligence, let store = metadataStore else {
            showToast("智能分析仅支持拾光本地图库")
            return
        }
        guard let photo = photos.first(where: { $0.id == photoID }), !photo.isVideo else {
            showToast("智能分析仅支持拾光本地图库中的照片")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let analyzed = await Task.detached(priority: .utility) {
                PhotoIntelligence.analyze(photo)
            }.value
            guard let result = analyzed else {
                self.showToast("无法分析这张照片")
                return
            }
            let labels = Set(result.labels.split(separator: " ").map(String.init))
            self.analysisIndex[photoID] = PhotoAnalysis(
                labels: labels,
                text: result.text,
                searchBlob: (result.labels + " " + result.text).lowercased()
            )
            store.saveAnalysis([(photoID, result.labels, result.text, result.feature)])
            self.sceneCountsCacheKey = nil
        }
    }

    /// 还没有分析，或分析结果来自旧版 Vision 标签（缺少 SigLIP 版本标记）。
    func needsReanalysis(_ id: UUID) -> Bool {
        guard let analysis = analysisIndex[id] else { return true }
        return !analysis.labels.contains(PhotoTagCatalog.sentinel)
    }

    var pendingAnalysisCount: Int {
        photos.lazy.filter { $0.deletedAt == nil && !$0.isVideo && self.needsReanalysis($0.id) }.count
    }

    /// 逐张分析本地照片：场景分类 + OCR 文字 + 二维码 / 条码 + 特征向量，结果分批写入图库数据库。
    /// `force` 为真时对全库照片重跑一遍，让新增识别项（码、证件照）对历史照片也生效。
    func analyzeIntelligence(force: Bool = false) {
        guard canAnalyzeIntelligence, let store = metadataStore else {
            showToast("智能分析仅支持拾光本地图库")
            return
        }
        guard !isAnalyzingIntelligence else { return }
        let targets = photos.filter {
            $0.deletedAt == nil && !$0.isVideo && (force || self.needsReanalysis($0.id))
        }
        guard !targets.isEmpty else {
            showToast(force ? "图库里没有可分析的照片" : "所有照片都已完成内容分析")
            return
        }

        isAnalyzingIntelligence = true
        intelligenceCancelled = false
        intelligenceDone = 0
        intelligenceTotal = targets.count
        sceneCountsCacheKey = nil
        // 进统一任务中心：侧边栏底部任务条与详情浮层都能看到这次识别，也能从那里取消。
        let libraryPath = (LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
            .standardizedFileURL.path
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(libraryPath),
                      kind: .analyze,
                      title: "分析本地图库内容"),
            cancel: { [weak self] in
                Task { @MainActor in self?.cancelIntelligenceAnalysis() }
            }
        )

        intelligenceTask = Task { [weak self] in
            guard let self else { return }
            var buffer: [(id: UUID, labels: String, text: String, feature: Data?)] = []
            buffer.reserveCapacity(16)
            for (index, photo) in targets.enumerated() {
                if self.intelligenceCancelled || Task.isCancelled { break }
                let result = await Task.detached(priority: .utility) {
                    PhotoIntelligence.analyze(photo)
                }.value
                if let result {
                    let labels = Set(result.labels.split(separator: " ").map(String.init))
                    self.analysisIndex[photo.id] = PhotoAnalysis(
                        labels: labels,
                        text: result.text,
                        searchBlob: (result.labels + " " + result.text).lowercased()
                    )
                    buffer.append((photo.id, result.labels, result.text, result.feature))
                    if buffer.count >= 16 {
                        store.saveAnalysis(buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                self.intelligenceDone = index + 1
                if index % 8 == 0 {
                    self.sceneCountsCacheKey = nil
                    self.updateSourceJob(jobID,
                                         completed: index + 1,
                                         total: targets.count,
                                         message: "已分析 \(index + 1) / \(targets.count)")
                }
            }
            if !buffer.isEmpty { store.saveAnalysis(buffer) }

            self.sceneCountsCacheKey = nil
            self.isAnalyzingIntelligence = false
            self.intelligenceTask = nil
            let analysed = self.intelligenceDone
            self.intelligenceTotal = 0
            self.intelligenceDone = 0
            if self.intelligenceCancelled {
                self.cancelSourceJob(jobID)
                self.intelligenceCancelled = false
                self.showToast("已停止内容分析，已分析 \(analysed) 张")
            } else {
                self.finishSourceJob(jobID, message: "已分析 \(analysed) 张")
                self.showToast("内容分析完成，共分析 \(analysed) 张")
            }
        }
    }

    func cancelIntelligenceAnalysis() {
        intelligenceCancelled = true
        intelligenceTask?.cancel()
    }

    /// 重新分析全部照片：二维码 / 条码与证件照是新增识别项，历史分析结果需要覆盖更新。
    func reanalyzeIntelligence() {
        analyzeIntelligence(force: true)
    }

    /// 清空全部照片内容分析结果（标签 / 文字 / 特征向量）：内存索引与数据库一并删除，不会自动重新分析。
    /// 界面上先做二次确认；入口只在未分析时可见，这里再挡一道。
    func resetIntelligenceAnalysis() {
        guard canAnalyzeIntelligence, let store = metadataStore else {
            showToast("智能分析仅支持拾光本地图库")
            return
        }
        guard !isAnalyzingIntelligence else {
            showToast("请先停止正在进行的分析")
            return
        }
        guard !analysisIndex.isEmpty else {
            showToast("还没有照片内容分析结果")
            return
        }
        analysisIndex = [:]
        store.purgeAnalysis()
        sceneCountsCacheKey = nil
        sceneSummaryCacheKey = nil
        showToast("已清空照片内容分析结果")
    }

    // MARK: - 系统图库的端侧识别（内存 + 落库缓存）

    /// 系统图库同样支持端侧场景 / 文字识别，结果写入当前图库的 `system_analysis`，不写 Apple 的数据库。
    var canAnalyzeSystemContent: Bool {
        isSystemScope && !needsLibrarySetup
    }

    var systemAnalyzedCount: Int { systemAnalysisIndex.count }

    /// 当前系统图库里还没识别过的照片数（结果按索引签名、窗口与识别数量缓存）。
    var systemPendingAnalysisCount: Int {
        guard isSystemScope else { return 0 }
        let key = "\(systemIndexSignature)-\(systemPhotos.count)-\(systemAnalysisIndex.count)"
        if key == systemPendingAnalysisCacheKey { return systemPendingAnalysisCache }
        let total: Int
        if let index = systemIndex {
            // 索引模式：用一条 COUNT 查询拿到整库照片数，不把整库读进内存。
            var query = SystemQuery()
            query.scope = .all
            query.onlyPhotos = true
            total = index.summary(query).total
        } else {
            total = systemPhotos.lazy.filter { $0.deletedAt == nil && !$0.isVideo }.count
        }
        let value = max(0, total - systemAnalysisIndex.count)
        systemPendingAnalysisCacheKey = key
        systemPendingAnalysisCache = value
        return value
    }

    /// 系统图库重新载入或出现新照片后调用：只有用户本次运行中主动开启过识别，才继续处理新增照片。
    /// 打开图库默认不扫描场景，避免一进来就占满 CPU。
    func resumeSystemAnalysisIfNeeded() {
        guard systemAnalysisAutoResume,
              canAnalyzeSystemContent,
              !systemAnalysisIndex.isEmpty,
              !isAnalyzingSystemContent,
              systemPendingAnalysisCount > 0 else { return }
        analyzeSystemContent()
    }

    /// 单批解码数量：控制每次取多少张，避免长任务占满内存。
    static let systemAnalysisPageSize = 200

    /// 在后台持续识别系统图库：结果逐张出现，增量刷新侧边栏与场景总览；
    /// 识别位置按图库记录，关库 / 切库 / 重启后会从断点继续，而不是从头扫描。
    func analyzeSystemContent() {
        guard canAnalyzeSystemContent else {
            showToast("内容识别仅在系统图库范围可用")
            return
        }
        guard !isAnalyzingSystemContent else { return }
        // 先把落库结果读回内存，避免把已识别过的照片当成新照片重跑。
        hydrateSystemCacheIfNeeded()
        let pending = systemPendingAnalysisCount
        guard pending > 0 else {
            showToast("当前系统图库的照片都已完成识别")
            return
        }
        systemAnalysisAutoResume = true
        persistSystemAnalysisAutoResume(true)
        isAnalyzingSystemContent = true
        systemAnalysisCancelled = false
        systemAnalysisDone = 0
        systemAnalysisTotal = pending
        // 与本地图库识别一致：进统一任务中心，任务条 / 详情浮层都能看到进度并取消。
        let libraryPath = systemLibraryPath
            ?? (LibraryPaths.containerLibraryURL ?? LibraryPaths.root).standardizedFileURL.path
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library(libraryPath),
                      kind: .analyze,
                      title: "识别系统图库场景"),
            cancel: { [weak self] in
                Task { @MainActor in self?.cancelSystemContentAnalysis() }
            }
        )

        let index = systemIndex
        // 只取照片，和本地图库的识别范围一致（视频不参与）。
        var indexQuery = SystemQuery()
        indexQuery.onlyPhotos = true
        let pageSize = Self.systemAnalysisPageSize

        systemAnalysisTask = Task { [weak self] in
            guard let self else { return }
            // 等缓存读回后再开始：已识别的照片直接跳过。
            if let hydration = self.systemAnalysisHydration { await hydration.value }

            var cursor = self.systemAnalysisSavedOffset
            var wrappedToStart = false
            var idlePages = 0
            var pendingRows: [(id: UUID, labels: String, text: String, feature: Data?)] = []
            var remaining = self.systemPendingAnalysisCount
            self.systemAnalysisTotal = max(1, remaining)

            while !Task.isCancelled && !self.systemAnalysisCancelled {
                let pageStart = cursor
                let batch: [PhotoItem]
                let nextCursor: Int
                if let index {
                    let page = await Task.detached(priority: .utility) {
                        index.page(indexQuery, offset: cursor, limit: pageSize)
                    }.value
                    if page.isEmpty {
                        // 已经扫到队尾：回到开头再补一遍新照片，只绕一圈。
                        if wrappedToStart { break }
                        wrappedToStart = true
                        cursor = 0
                        self.saveSystemAnalysisOffset(0)
                        continue
                    }
                    nextCursor = cursor + page.count
                    batch = page.filter {
                        $0.deletedAt == nil && !$0.isVideo && self.systemAnalysisIndex[$0.id] == nil
                    }
                } else {
                    let candidates = self.systemPhotos.lazy.filter {
                        $0.deletedAt == nil && !$0.isVideo && self.systemAnalysisIndex[$0.id] == nil
                    }.prefix(pageSize)
                    batch = Array(candidates)
                    if batch.isEmpty { break }
                    nextCursor = cursor + batch.count
                }
                cursor = nextCursor

                var produced = 0
                for photo in batch {
                    if self.systemAnalysisCancelled || Task.isCancelled { break }
                    let result = await Task.detached(priority: .utility) {
                        PhotoIntelligence.analyze(photo)
                    }.value
                    if let result {
                        let labels = Set(result.labels.split(separator: " ").map(String.init))
                        self.systemAnalysisIndex[photo.id] = PhotoAnalysis(
                            labels: labels,
                            text: result.text,
                            searchBlob: (result.labels + " " + result.text).lowercased()
                        )
                        // 识别结果写入当前图库数据库，重开图库不必重新分析。
                        pendingRows.append((photo.id, result.labels, result.text, result.feature))
                        if pendingRows.count >= 16 {
                            self.persistSystemAnalysis(pendingRows)
                            pendingRows.removeAll(keepingCapacity: true)
                        }
                        produced += 1
                        remaining = max(0, remaining - 1)
                    }
                    self.systemAnalysisDone += 1
                    if self.systemAnalysisDone % 16 == 0 {
                        self.updateSourceJob(jobID,
                                             completed: self.systemAnalysisDone,
                                             total: self.systemAnalysisTotal,
                                             message: "已识别 \(self.systemAnalysisDone) / \(self.systemAnalysisTotal)")
                    }
                    // 让界面按张刷新：场景行与「包含文字」会随识别进度逐步出现。
                    await Task.yield()
                }
                if produced == 0 {
                    idlePages += 1
                    // 连续几页都没有产出（例如全部无法解码）就收工，避免原地打转。
                    if idlePages > 6 { break }
                } else {
                    idlePages = 0
                }
                // 处理完一页就落一次续跑位置；中途暂停保留本页起点，下次先补完这一页。
                if index != nil {
                    let interrupted = self.systemAnalysisCancelled || Task.isCancelled
                    self.saveSystemAnalysisOffset(interrupted ? pageStart : cursor)
                }
                self.systemAnalysisTotal = self.systemAnalysisDone + remaining
                if remaining <= 0 { break }
            }

            self.persistSystemAnalysis(pendingRows)
            self.isAnalyzingSystemContent = false
            self.systemAnalysisTask = nil
            let analysed = self.systemAnalysisDone
            self.systemAnalysisTotal = 0
            self.systemAnalysisDone = 0
            if self.systemAnalysisCancelled {
                self.cancelSourceJob(jobID)
                self.systemAnalysisCancelled = false
                self.showToast("已停止识别，本次识别 \(analysed) 张（已缓存到图库）")
            } else {
                self.finishSourceJob(jobID, message: "已识别 \(analysed) 张")
                if self.systemPendingAnalysisCount == 0 {
                    // 全部完成：清掉断点与自动续跑标记，下次从最新的照片重新找增量。
                    self.saveSystemAnalysisOffset(0)
                    self.systemAnalysisAutoResume = false
                    self.persistSystemAnalysisAutoResume(false)
                }
                self.showToast("识别完成，共 \(self.systemAnalysisIndex.count) 张（已缓存到图库）")
            }
        }
    }

    func cancelSystemContentAnalysis() {
        // 用户明确停止后不再自动续跑；断点保留，下次点「继续识别」从原位置接着来。
        systemAnalysisAutoResume = false
        persistSystemAnalysisAutoResume(false)
        systemAnalysisCancelled = true
        systemAnalysisTask?.cancel()
    }

    /// 清空系统图库的全部识别结果：内存索引、特征与 `system_analysis` 缓存一并删除，
    /// 断点与自动续跑标记同时作废；不会自动重新识别。界面上先做二次确认。
    func resetSystemAnalysis() {
        guard canAnalyzeSystemContent, let store = metadataStore, let path = systemLibraryPath else {
            showToast("内容识别仅在系统图库范围可用")
            return
        }
        guard !isAnalyzingSystemContent else {
            showToast("请先停止正在进行的识别")
            return
        }
        guard !systemAnalysisIndex.isEmpty else {
            showToast("还没有系统图库识别结果")
            return
        }
        systemAnalysisIndex = [:]
        systemFeatures = [:]
        systemAnalysisAutoResume = false
        systemPendingAnalysisCacheKey = nil
        sceneSummaryCacheKey = nil
        sceneCountsCacheKey = nil
        store.purgeSystemCache(libraryPath: path)
        contentRevision &+= 1
        showToast("已清空系统图库识别结果")
    }

    /// 从头重新识别系统图库全部照片：先清掉现有结果与断点，再立即开始（界面先做二次确认）。
    func restartSystemAnalysis() {
        guard canAnalyzeSystemContent else {
            showToast("内容识别仅在系统图库范围可用")
            return
        }
        resetSystemAnalysis()
        analyzeSystemContent()
    }

    // MARK: - 场景统计

    /// 场景总览（数量 + 封面）：各场景的照片数随照片内容与分析结果变化自动重算。
    /// 本地图库用落库的分析结果，系统图库用内存里的识别结果。
    var sceneSummary: SceneSummary {
        let key: String
        if isSystemScope {
            key = "sys-\(systemPhotos.count)-\(systemAnalysisIndex.count)-\(systemIndexSignature)"
        } else {
            key = "\(contentRevision)-\(analysisIndex.count)"
        }
        if key == sceneSummaryCacheKey { return sceneSummaryCache }
        var summary = SceneSummary()
        if isSystemScope {
            // 系统图库只遍历已识别的照片，避免扫整库。
            // 索引模式下内存里只有当前窗口，这里绝不能逐张回查索引：
            // 十万级识别结果会变成十万次 SQL，主线程直接卡死。
            var windowIndex: [UUID: PhotoItem] = [:]
            windowIndex.reserveCapacity(systemWindowPhotos.count)
            for item in systemWindowPhotos where windowIndex[item.id] == nil {
                windowIndex[item.id] = item
            }
            for (photoID, analysis) in systemAnalysisIndex {
                let photo = systemPhotoIndex[photoID] ?? windowIndex[photoID]
                if let photo, photo.deletedAt != nil || photo.isHidden { continue }
                for category in SceneCatalog.categories
                where SceneCatalog.matches(category, analysis: analysis, photo: photo) {
                    summary.counts[category.id, default: 0] += 1
                    if summary.coverIDs[category.id] == nil {
                        summary.coverIDs[category.id] = photoID
                    }
                    if summary.covers[category.id] == nil, let photo {
                        summary.covers[category.id] = photo
                    }
                }
            }
            // 索引模式下内存窗口通常不含封面照片，按候选 ID 从索引批量补齐。
            if let index = systemIndex {
                let missing = summary.coverIDs.filter { summary.covers[$0.key] == nil }
                if !missing.isEmpty {
                    let items = index.photos(ids: Array(missing.values))
                    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    for (categoryID, photoID) in missing {
                        guard let item = byID[photoID] else { continue }
                        summary.covers[categoryID] = applySystemOverlay(item)
                    }
                }
            }
        } else if !analysisIndex.isEmpty {
            for photo in photos where photo.deletedAt == nil && !photo.isHidden {
                guard let analysis = analysisIndex[photo.id] else { continue }
                for category in SceneCatalog.categories
                where SceneCatalog.matches(category, analysis: analysis, photo: photo) {
                    summary.counts[category.id, default: 0] += 1
                    if summary.covers[category.id] == nil {
                        summary.covers[category.id] = photo
                    }
                }
            }
        }
        sceneSummaryCacheKey = key
        sceneSummaryCache = summary
        sceneCountsCacheKey = key
        sceneCountsCache = summary.counts
        return summary
    }

    /// 各场景的照片数；随照片内容与分析结果变化自动重算。
    var sceneCounts: [String: Int] { sceneSummary.counts }

    var hasAnyScene: Bool { sceneCounts.values.contains { $0 > 0 } }

    var ocrPhotoCount: Int {
        // 系统图库的识别结果只覆盖已识别照片，直接数索引即可。
        if isSystemScope {
            return systemAnalysisIndex.values.lazy.filter { !$0.text.isEmpty }.count
        }
        guard !analysisIndex.isEmpty else { return 0 }
        return photos.lazy.filter {
            $0.deletedAt == nil && !$0.isHidden && !(self.analysisIndex[$0.id]?.text.isEmpty ?? true)
        }.count
    }

    func photosMatchingScene(_ id: String) -> [PhotoItem] {
        guard let category = SceneCatalog.category(id: id) else { return [] }
        if isSystemScope {
            return systemAnalysisIndex.compactMap { photoID, analysis in
                guard let photo = systemPhoto(id: photoID),
                      photo.deletedAt == nil, !photo.isHidden,
                      SceneCatalog.matches(category, analysis: analysis, photo: photo) else { return nil }
                return photo
            }
        }
        return photos.filter { photo in
            guard photo.deletedAt == nil, !photo.isHidden,
                  let analysis = self.analysisIndex[photo.id] else { return false }
            return SceneCatalog.matches(category, analysis: analysis, photo: photo)
        }
    }

    /// 把已识别的场景生成为智能相簿，之后新照片分析完成会自动落入对应相簿。
    func createSceneSmartAlbums() {
        guard canAnalyzeIntelligence else {
            showToast("智能分析仅支持拾光本地图库")
            return
        }
        let counts = sceneCounts
        var created = 0
        for category in SceneCatalog.categories where (counts[category.id] ?? 0) > 0 {
            if smartAlbums.contains(where: { $0.name == category.title }) { continue }
            var album = SmartAlbum()
            album.name = category.title
            album.matchAll = true
            album.rules = [SmartRule(field: .scene, value: category.title)]
            smartAlbums.append(album)
            created += 1
        }
        guard created > 0 else {
            showToast(analyzedCount > 0 ? "场景智能相簿已是最新" : "请先分析照片内容")
            return
        }
        persistSmartAlbums()
        showToast("已生成 \(created) 个场景智能相簿")
    }

    // MARK: - 相似照片

    func findSimilarPhotos(to id: UUID) {
        // 网盘范围：用缩略图现算端侧特征，在内存里比较当前目录的照片。
        if isCloudScope {
            findSimilarCloudPhotos(to: id)
            return
        }
        // 系统图库：同样用缩略图现算特征，只在内存里比较已载入的照片。
        if isSystemScope {
            findSimilarSystemPhotos(to: id)
            return
        }
        guard !isReadOnlyScope, let store = metadataStore else {
            showToast("相似检索仅支持拾光本地图库")
            return
        }
        guard let photo = photos.first(where: { $0.id == id }) else { return }
        guard !photo.isVideo else {
            showToast("暂不支持视频相似检索")
            return
        }
        guard analysisIndex[id] != nil else {
            showToast("请先在侧边栏「场景」里分析照片内容")
            return
        }
        showToast("正在查找相似照片…")
        let title = photo.displayTitle
        Task { [weak self] in
            let ids = await Task.detached(priority: .userInitiated) { () -> [UUID] in
                guard let feature = store.feature(for: id) else { return [] }
                return store.similarPhotos(to: feature, excluding: id)
            }.value
            guard let self else { return }
            guard !ids.isEmpty else {
                self.showToast("没有找到足够相似的照片")
                return
            }
            self.navigate(to: .library)
            self.similarScope = SimilarityScope(sourceID: id, title: title, ids: Set(ids))
            self.showToast("找到 \(ids.count) 张相似照片")
        }
    }

    func clearSimilarScope() {
        similarScope = nil
        cloudVisibleCacheKey = nil
    }
}
