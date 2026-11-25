import Foundation
import LumaContentCore

/// 网络存储的分类浏览：媒体类型、场景、图内文字，以及由 EXIF 派生的地图 / 位置 / 人物 /
/// 值得重看 / 重复项目。
///
/// 网盘照片的拍摄时间、相机与 GPS 由 `CloudEXIF` 读取文件头部得到（SMB 直接读文件，
/// WebDAV / 官方网盘走 Range），识别结果与 EXIF 都写入当前图库的 `cloud_assets` 缓存，
/// 换挂载只清内存，不写网盘、不上传任何内容。
extension LibraryStore {
    /// 当前打开中的网盘挂载 ID。
    /// 影院也归属这个网盘：进入影院后分类树（媒体类型 / 更多项目 / 场景 / 相簿）仍要正常显示，
    /// 不能因为 `sidebarItem` 变成 `.cloudCinema` 就把相簿树清空。
    var currentCloudMountID: UUID? {
        switch sidebarItem {
        case .cloudMount(let id): return id
        case .cloudCinema(let id): return id
        default: return nil
        }
    }

    var cloudScope: CloudScope { cloudModel.scope }

    func setCloudScope(_ scope: CloudScope) {
        if cloudModel.scope != scope {
            if scope.requiresAnalysis, cloudModel.analysis.isEmpty {
                showToast("先点「识别内容」，完成后即可按场景或文字浏览")
            }
            cloudModel.scope = scope
        }
        // 选了具体范围就回到网格；与 `navigate(to:)` 一致，点当前范围也把搜索 / 筛选 / 选择回正。
        cloudModel.overview = nil
        // 媒体类型与「更多项目」是整库口径：像拾光一样离开当前目录相簿；
        // 回到「全部项目」则保留当前相簿，方便只清除筛选。
        if scope != .all { showCloudRootPhotos() }
        clearTransientBrowsingState()
        cloudVisibleCacheKey = nil
    }

    /// 打开 / 关闭网盘的分区总览（媒体类型、更多项目），与拾光 / 系统图库的分区标题行为一致。
    func showCloudOverview(_ section: CloudOverviewSection?) {
        if let section, cloudModel.overview == section {
            cloudModel.overview = nil
        } else {
            cloudModel.overview = section
        }
    }

    /// 只打开不关闭：点分区标题与拾光一样进入总览，再次点击不会退回照片网格。
    func openCloudOverview(_ section: CloudOverviewSection) {
        // 与拾光一致：媒体类型 / 更多项目 / 场景 / 相簿总览都是整库口径，进入时先离开当前目录相簿。
        showCloudRootPhotos()
        cloudModel.overview = section
    }

    /// 单张云照片是否属于某个范围。
    func cloudPhoto(_ photo: PhotoItem, matches scope: CloudScope) -> Bool {
        switch scope {
        case .all: return true
        case .videos: return photo.isVideo
        case .photos: return !photo.isVideo
        case .screenshots: return !photo.isVideo && CloudMediaNaming.looksLikeScreenshot(photo.originalName)
        case .screenRecordings:
            return photo.isVideo && CloudMediaNaming.looksLikeScreenRecording(photo.originalName)
        case .panoramas:
            return !photo.isVideo && CloudMediaNaming.looksLikePanorama(photo.originalName,
                                                                       pixelWidth: photo.pixelWidth,
                                                                       pixelHeight: photo.pixelHeight)
        case .animated: return photo.isAnimatedFile
        case .raws: return photo.isRAWFile
        case .favorites: return photo.isFavorite
        case .text: return !(cloudModel.analysis[photo.id]?.text.isEmpty ?? true)
        case .recentlyViewed:
            return (photo.viewedAt ?? .distantPast) >= Self.recentlyViewedCutoff
        case .recentlySaved:
            return photo.addedAt >= Self.recentlySavedCutoff
        case .ratings: return true
        case .recentlyEdited, .trash, .imports: return false
        case .scene(let id):
            guard let category = SceneCatalog.category(id: id),
                  let analysis = cloudModel.analysis[photo.id] else { return false }
            return SceneCatalog.matches(category, analysis: analysis, photo: photo)
        case .revisit:
            let now = Date()
            guard photo.capturedAt < now.addingTimeInterval(-LibraryHealthTuning.revisitCaptureAge) else {
                return false
            }
            guard let viewedAt = cloudModel.viewedAt[photo.id] else { return true }
            return viewedAt < now.addingTimeInterval(-LibraryHealthTuning.revisitViewAge)
        case .map, .places:
            return !photo.isVideo && photo.hasLocation
        case .people:
            return cloudPeople.contains { $0.assetIDs.contains(photo.id) }
        case .duplicates:
            return cloudDuplicatePhotoIDs.contains(photo.id)
        case .health:
            return false
        case .keywords:
            return false
        case .keyword(let name):
            return photo.tags.contains(name)
        }
    }

    /// 当前网盘列表的分类计数（一次遍历，按目录版本 + 识别 / 元数据进度缓存）。
    var cloudScopeCounts: CloudScopeCounts {
        // 扫描期间不做整库统计：每次发布都全量遍历两万张照片会直接把主线程拖慢，
        // 计数在扫描结束后自然补齐。
        if cloudModel.scanPhase.isScanning { return cloudScopeCountsCache }
        let key = [
            String(cloudModel.revision),
            String(cloudModel.analysis.count),
            String(cloudModel.metadataRevision),
            String(cloudModel.people.count),
            String(cloudModel.viewedAt.count),
            String(cloudModel.healthReport?.scannedAt.timeIntervalSince1970 ?? 0),
            String(cloudKeywords.count)
        ].joined(separator: "\u{1F}")
        if key == cloudScopeCountsCacheKey { return cloudScopeCountsCache }
        var counts = CloudScopeCounts()
        if let report = cloudModel.healthReport {
            counts.health = report.blurry.count
                + report.similarDuplicatePhotos.count
                + report.largeVideos.count
        }
        let now = Date()
        let captureCutoff = now.addingTimeInterval(-LibraryHealthTuning.revisitCaptureAge)
        let viewCutoff = now.addingTimeInterval(-LibraryHealthTuning.revisitViewAge)
        let savedCutoff = Self.recentlySavedCutoff
        let viewedCutoff = Self.recentlyViewedCutoff
        let peopleIDs = Set(cloudPeople.flatMap { $0.assetIDs })
        let duplicateIDs = cloudDuplicatePhotoIDs
        for photo in cloudPhotos where !photo.isHidden {
            if photo.isVideo {
                counts.videos += 1
            } else {
                counts.photos += 1
            }
            if !photo.isVideo, CloudMediaNaming.looksLikeScreenshot(photo.originalName) {
                counts.screenshots += 1
            }
            if photo.isVideo, CloudMediaNaming.looksLikeScreenRecording(photo.originalName) {
                counts.screenRecordings += 1
            }
            if !photo.isVideo, CloudMediaNaming.looksLikePanorama(photo.originalName,
                                                                  pixelWidth: photo.pixelWidth,
                                                                  pixelHeight: photo.pixelHeight) {
                counts.panoramas += 1
            }
            if photo.isAnimatedFile { counts.animated += 1 }
            if photo.isRAWFile { counts.raws += 1 }
            if photo.isFavorite { counts.favorites += 1 }
            if (photo.viewedAt ?? .distantPast) >= viewedCutoff { counts.recentlyViewed += 1 }
            if photo.addedAt >= savedCutoff { counts.recentlySaved += 1 }
            if photo.starRating > 0 || photo.pickFlag != .none || photo.labelColor != .none {
                counts.ratings += 1
            }
            if !photo.isVideo, photo.hasLocation { counts.located += 1 }
            if peopleIDs.contains(photo.id) { counts.people += 1 }
            if duplicateIDs.contains(photo.id) { counts.duplicates += 1 }
            if !photo.isVideo, photo.capturedAt < captureCutoff,
               (cloudModel.viewedAt[photo.id] ?? .distantPast) < viewCutoff {
                counts.revisit += 1
            }
            for tag in photo.tags {
                counts.keywords[tag, default: 0] += 1
            }
            guard let analysis = cloudModel.analysis[photo.id] else { continue }
            if !analysis.text.isEmpty { counts.text += 1 }
            for category in SceneCatalog.categories
            where SceneCatalog.matches(category, analysis: analysis, photo: photo) {
                counts.scenes[category.id, default: 0] += 1
            }
        }
        cloudScopeCountsCacheKey = key
        cloudScopeCountsCache = counts
        return counts
    }

    /// 当前范围内仍待识别的照片数（视频不参与）。
    var cloudPendingAnalysisCount: Int {
        cloudPhotos.lazy.filter {
            !$0.isVideo && self.cloudModel.analysis[$0.id] == nil
        }.count
    }

    var cloudAnalyzedCount: Int { cloudModel.analysis.count }

    /// 逐张识别当前网盘列表的照片（场景 + 图内文字），每次最多 120 张，避免一次触发大规模网络读取。
    func analyzeCloudContent() {
        guard isCloudScope else {
            showToast("请先打开一个网络存储")
            return
        }
        guard !cloudModel.isAnalyzing else { return }
        let targets = cloudPhotos
            .filter { !$0.isVideo && self.cloudModel.analysis[$0.id] == nil }
            .prefix(120)
        guard !targets.isEmpty else {
            showToast(cloudPhotos.isEmpty ? "当前文件夹没有可识别的照片" : "当前列表已完成内容识别")
            return
        }

        cloudModel.insightMountID = currentCloudMountID
        cloudModel.isAnalyzing = true
        cloudModel.analysisProgress = 0
        let total = Double(targets.count)
        // 网盘识别也进任务中心：任务条与详情浮层能直接看到当前列表的识别进度。
        let mountID = cloudModel.insightMountID
        let jobID = mountID.map { id in
            beginSourceJob(
                SourceJob(sourceID: .cloud(id), kind: .analyze, title: "识别网盘内容"),
                cancel: { [weak self] in
                    Task { @MainActor in self?.cancelCloudContentAnalysis() }
                }
            )
        }
        cloudModel.analysisTask = Task { [weak self] in
            guard let self else { return }
            var done = 0
            for photo in targets {
                if Task.isCancelled { break }
                if let image = await self.cloudThumbnail(for: photo),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let result = await Task.detached(priority: .utility) {
                        PhotoIntelligence.analyze(cgImage: cgImage)
                    }.value
                    if let result {
                        let labels = Set(result.labels.split(separator: " ").map(String.init))
                        self.cloudModel.analysis[photo.id] = PhotoAnalysis(
                            labels: labels,
                            text: result.text,
                            searchBlob: (result.labels + " " + result.text).lowercased()
                        )
                        if let feature = result.feature {
                            self.cloudModel.features[photo.id] = feature
                        }
                        // 识别结果写入当前图库数据库，重开网盘 / 换目录不必重新识别。
                        if let mountID = photo.cloudMountID, let path = photo.cloudPath {
                            self.metadataStore?.saveCloudAnalysis(mountID: mountID,
                                                                  path: path,
                                                                  labels: result.labels,
                                                                  text: result.text,
                                                                  feature: result.feature)
                        }
                        // 只有按场景/文字浏览时列表才会变化，避免识别过程中反复重排整个网格。
                        if self.cloudModel.scope.requiresAnalysis {
                            self.cloudVisibleCacheKey = nil
                        }
                        self.cloudScopeCountsCacheKey = nil
                    }
                }
                done += 1
                self.cloudModel.analysisProgress = Double(done) / total
                if let jobID {
                    self.updateSourceJob(jobID,
                                         completed: done,
                                         total: targets.count,
                                         message: "已识别 \(done) / \(targets.count)")
                }
            }
            let analysed = self.cloudModel.analysis.count
            self.cloudModel.isAnalyzing = false
            self.cloudModel.analysisProgress = 0
            self.cloudModel.analysisTask = nil
            self.cloudScopeCountsCacheKey = nil
            self.cloudVisibleCacheKey = nil
            if Task.isCancelled {
                if let jobID { self.cancelSourceJob(jobID) }
                self.showToast("已停止识别，当前已识别 \(analysed) 张")
            } else {
                if let jobID { self.finishSourceJob(jobID, message: "已识别 \(analysed) 张") }
                self.showToast("内容识别完成，共识别 \(analysed) 张")
            }
        }
    }

    func cancelCloudContentAnalysis() {
        cloudModel.analysisTask?.cancel()
    }

    /// 切换网盘或换库时清空识别结果与范围（识别结果只在内存，属于当前挂载）。
    func resetCloudInsight() {
        cloudModel.analysisTask?.cancel()
        cloudModel.analysisTask = nil
        cloudModel.isAnalyzing = false
        cloudModel.analysisProgress = 0
        cloudModel.analysis = [:]
        cloudModel.scope = .all
        cloudModel.overview = nil
        cloudModel.insightMountID = nil
        cloudScopeCountsCacheKey = nil
        cloudScopeCountsCache = CloudScopeCounts()
        cloudVisibleCacheKey = nil
        resetCloudDerivedData()
    }

    /// 打开某个网盘前调用：只有挂载变化时才清空，避免在同一网盘内换目录丢结果。
    func prepareCloudInsight(for mountID: UUID) {
        guard let current = cloudModel.insightMountID else {
            cloudModel.insightMountID = mountID
            loadCloudCacheForMount(mountID)
            return
        }
        guard current != mountID else { return }
        resetCloudInsight()
        cloudModel.insightMountID = mountID
        loadCloudCacheForMount(mountID)
    }
}
