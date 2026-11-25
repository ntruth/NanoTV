import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore


extension LibraryStore {
    // MARK: - Network storage (WebDAV)

    /// 切换图库：网盘挂载、目录缓存与云端收藏都属于上一个图库，必须先清空再读新库，
    /// 否则旧挂载会被当成新库的连接写回它的 settings。
    func resetCloudStateForLibrarySwitch() {
        cloudLoadToken += 1
        cloudModel.scanLoadToken += 1
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        cloudModel.refreshLoopTask?.cancel()
        cloudModel.refreshLoopTask = nil
        cloudModel.isRestoringScan = false
        cloudMounts = []
        cloudFolders = []
        cloudPhotos = []
        cloudPath = ""
        cloudTrail = []
        cloudError = nil
        cloudBusyText = nil
        cloudSheetMount = nil
        cloudVisibleCacheKey = nil
        cloudVisibleCacheValue = []
        cloudDirectoryCache.removeAll()
        CloudCredentials.clearCache()
        cloudFavorites = []
        resetCloudAlbumScan()
        resetCloudInsight()
    }

    // MARK: - 网盘图库（自动扫描 + 文件夹相簿）

    /// 当前是否正在扫描整个网盘；工具栏与浮层据此显示进度。
    var isCloudScanning: Bool { cloudModel.scanPhase.isScanning }
    var cloudScanFolderCount: Int { cloudModel.scanFolderCount }
    var cloudSelectedFolderPath: String? { cloudModel.selectedFolderPath }
    var cloudOverviewSection: CloudOverviewSection? { cloudModel.overview }
    /// 面包屑根节点 ID（百度为 "/"，其余为 ""）。
    var cloudBreadcrumbRootID: String { cloudBreadcrumbChain.first?.id ?? "" }

    /// 根目录标识：百度用 "/"，其余用 ""。
    func cloudRootPath(for mount: CloudMount) -> String {
        mount.kind == .baidu ? "/" : ""
    }

    /// 探测一个存储是否可连通：与打开网盘走同一条 `CloudService.list`，只读根目录，
    /// 不写索引、不改当前浏览目录，因此可以在总览页对多个存储并发检测。
    func probeCloudMount(_ mount: CloudMount) async -> SourceHealth {
        let started = Date()
        do {
            _ = try await CloudService.list(mount: mount, containerID: cloudRootPath(for: mount))
            return SourceHealth(state: .healthy,
                                checkedAt: Date(),
                                latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            let message = error.localizedDescription
            if let oauth = error as? CloudOAuthError, oauth.requiresReauth {
                return SourceHealth(state: .authRequired, checkedAt: Date(), message: message)
            }
            return SourceHealth(state: .offline, checkedAt: Date(), message: message)
        }
    }

    /// 连通性检测 + 任务中心登记：总览页的「检测状态」与单卡右键都走这里，
    /// 侧边栏「后台任务」能看到「健康检测 · 网盘名」的进行中状态与结果。
    func runCloudHealthCheck(_ mount: CloudMount) async -> SourceHealth {
        if let running = cloudModel.mountHealth[mount.id], running.state == .checking {
            return running
        }
        cloudModel.mountHealth[mount.id] = SourceHealth(state: .checking, checkedAt: Date())
        let job = SourceJob(sourceID: .cloud(mount.id),
                            kind: .connectivity,
                            title: "检测「\(mount.name)」",
                            isCancellable: false)
        let jobID = beginSourceJob(job)
        updateSourceJob(jobID, message: "正在连接…")
        let health = await probeCloudMount(mount)
        cloudModel.mountHealth[mount.id] = health
        switch health.state {
        case .healthy:
            let latency = health.latencyMilliseconds.map { " · \($0) ms" } ?? ""
            finishSourceJob(jobID, message: "在线" + latency)
        case .authRequired:
            failSourceJob(jobID, message: health.message ?? "需要重新授权")
        default:
            failSourceJob(jobID, message: health.message ?? "连接失败")
        }
        return health
    }

    /// 当前选中文件夹的面包屑链（第一项是整个网盘）。
    var cloudBreadcrumbChain: [CloudCrumb] {
        guard let mount = cloudMount(for: currentCloudMountID) else { return [] }
        let rootPath = cloudRootPath(for: mount)
        let crumbs = [CloudCrumb(id: rootPath, name: mount.name)]
        guard let selected = cloudModel.selectedFolderPath else { return crumbs }
        var byPath: [String: CloudScanFolder] = [:]
        for folder in cloudModel.scanFolders where byPath[folder.path] == nil {
            byPath[folder.path] = folder
        }
        var chain: [CloudScanFolder] = []
        var cursor: String? = selected
        while let path = cursor, path != rootPath, let folder = byPath[path] {
            chain.append(folder)
            cursor = folder.parentPath
        }
        return crumbs + chain.reversed().map { CloudCrumb(id: $0.path, name: $0.name) }
    }

    /// 侧边栏「相簿」的顶层文件夹（文件夹 = 相簿），带聚合数量与封面。
    ///
    /// 扫描完成后直接读 SQLite 聚合表（目录数最多一千出头，一条 JOIN 即可），
    /// 不再对两万张照片做「向上累计 + 找封面」的全量遍历；
    /// 扫描过程中只展示目录结构，数量 / 封面等扫描结束再出现。
    var cloudRootFolders: [CloudFolderNode] {
        guard let mount = cloudMount(for: currentCloudMountID) else { return [] }
        let rootPath = cloudRootPath(for: mount)
        let scanning = cloudModel.scanPhase.isScanning
        let key = [
            mount.id.uuidString,
            String(cloudModel.scanFolders.count),
            String(cloudModel.scanPhotos.count),
            String(cloudModel.cloudIndexRevision),
            scanning ? "1" : "0"
        ].joined(separator: "\u{1F}")
        if cloudFolderTreeCacheKey == key { return cloudFolderTreeCacheValue }

        let tree: [CloudFolderNode]
        if scanning {
            tree = buildScanningFolderTree(rootPath: rootPath)
        } else if let rows = metadataStore?.loadCloudIndexFolders(mountID: mount.id), !rows.isEmpty {
            tree = buildFolderTree(rows: rows, mount: mount, rootPath: rootPath)
        } else {
            tree = buildCloudFolderTree(rootPath: rootPath)
        }
        cloudFolderTreeCacheKey = key
        cloudFolderTreeCacheValue = tree
        return tree
    }

    /// 扫描期间只建目录结构：不统计照片、不选封面，避免每批扫描都做 O(n·depth) 遍历。
    func buildScanningFolderTree(rootPath: String) -> [CloudFolderNode] {
        var childrenByParent: [String: [CloudScanFolder]] = [:]
        for folder in cloudModel.scanFolders where folder.path != rootPath {
            childrenByParent[folder.parentPath, default: []].append(folder)
        }
        func makeNode(_ folder: CloudScanFolder) -> CloudFolderNode {
            let children = (childrenByParent[folder.path] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return CloudFolderNode(path: folder.path,
                                   name: folder.name,
                                   parentPath: folder.parentPath,
                                   photoCount: 0,
                                   cover: nil,
                                   children: children.map(makeNode))
        }
        return (childrenByParent[rootPath] ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(makeNode)
    }

    /// 从 SQLite 聚合行建树：子树数量 = 自身直属数量 + 子节点数量，封面优先自身、否则取子目录。
    func buildFolderTree(rows: [MetadataStore.CloudIndexFolderRow],
                                 mount: CloudMount,
                                 rootPath: String) -> [CloudFolderNode] {
        var childrenByParent: [String: [MetadataStore.CloudIndexFolderRow]] = [:]
        childrenByParent.reserveCapacity(rows.count)
        for row in rows where row.path != rootPath {
            childrenByParent[row.parentPath, default: []].append(row)
        }
        func makeNode(_ row: MetadataStore.CloudIndexFolderRow) -> CloudFolderNode {
            let children = (childrenByParent[row.path] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let childNodes = children.map(makeNode)
            let count = row.mediaCount + childNodes.reduce(0) { $0 + $1.photoCount }
            var cover = row.coverRecord.map { albumPhoto(record: $0, mount: mount) }
            if cover == nil {
                cover = childNodes.first(where: { $0.cover != nil })?.cover
            }
            return CloudFolderNode(path: row.path,
                                   name: row.name,
                                   parentPath: row.parentPath,
                                   photoCount: count,
                                   cover: cover,
                                   children: childNodes)
        }
        return (childrenByParent[rootPath] ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(makeNode)
    }

    func buildCloudFolderTree(rootPath: String) -> [CloudFolderNode] {
        var childrenByParent: [String: [CloudScanFolder]] = [:]
        var parentOf: [String: String] = [:]
        for folder in cloudModel.scanFolders {
            parentOf[folder.path] = folder.parentPath
            guard folder.path != rootPath else { continue }
            childrenByParent[folder.parentPath, default: []].append(folder)
        }

        // 照片按目录向上累计，顺便取每个目录最新一张做封面。
        var counts: [String: Int] = [:]
        var covers: [String: PhotoItem] = [:]
        for photo in cloudModel.scanPhotos {
            guard let path = photo.cloudPath,
                  let folder = cloudModel.scanMediaFolder[path] else { continue }
            var cursor: String? = folder
            while let current = cursor, current != rootPath, parentOf[current] != nil {
                counts[current, default: 0] += 1
                if covers[current] == nil { covers[current] = photo }
                cursor = parentOf[current]
            }
        }

        func makeNode(_ folder: CloudScanFolder) -> CloudFolderNode {
            let children = (childrenByParent[folder.path] ?? [])
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return CloudFolderNode(path: folder.path,
                                   name: folder.name,
                                   parentPath: folder.parentPath,
                                   photoCount: counts[folder.path] ?? 0,
                                   cover: covers[folder.path],
                                   children: children.map(makeNode))
        }

        return (childrenByParent[rootPath] ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(makeNode)
    }

    /// 搜索结果直达：打开挂载与所在目录，并直接把这个文件送进查看器。
    /// 索引恢复是异步的：暂时找不到就先记下路径，目录数据就绪后自动打开。
    func openCloudFile(mountID: UUID, folderPath: String?, path: String) {
        openCloudMount(mountID)
        selectCloudFolder(path: folderPath)
        let photos = cloudPhotosForSelection()
        if let photo = photos.first(where: { $0.cloudPath == path }) {
            pendingCloudOpenPath = nil
            openViewer(photo.id, context: photos)
        } else {
            pendingCloudOpenPath = path
        }
    }

    /// 目录数据就绪后，把搜索里点开的文件补送进查看器。
    func consumePendingCloudOpenIfNeeded() {
        guard let pending = pendingCloudOpenPath,
              let photo = cloudPhotos.first(where: { $0.cloudPath == pending }) else { return }
        pendingCloudOpenPath = nil
        openViewer(photo.id, context: cloudPhotos)
    }

    /// 选中一个文件夹相簿；`nil` 表示回到整个网盘。
    func selectCloudFolder(path: String?) {
        // 与 `navigate(to:)` 一致：点当前相簿也把搜索 / 筛选 / 选择回正。
        clearTransientBrowsingState()
        guard cloudModel.selectedFolderPath != path else { return }
        cloudModel.selectedFolderPath = path
        cloudModel.overview = nil
        cloudModel.scope = .all
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
        cloudModel.thumbnailPrefetchTask?.cancel()
        cloudModel.thumbnailPrefetchTask = nil
        if let mountID = currentCloudMountID {
            presentCloudAlbumPhotos(mountID: mountID)
        }
    }

    /// 回到整个网盘的照片列表，但保持当前范围 / 总览状态（由调用方决定）。
    /// 与拾光一致：媒体类型、更多项目与分区总览都是整库口径，不受当前相簿限制。
    func showCloudRootPhotos() {
        guard cloudModel.selectedFolderPath != nil,
              let mountID = currentCloudMountID else { return }
        cloudModel.selectedFolderPath = nil
        presentCloudAlbumPhotos(mountID: mountID)
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
    }

    /// 打开挂载的网盘图库：先显示上次扫描快照，再按需在后台续扫。
    /// - Parameter refreshIfStale: 传入秒数时，索引超过该时长就立刻做一次增量扫描（影院入口用）。
    func openCloudAlbum(_ mount: CloudMount, refreshIfStale: TimeInterval? = nil) {
        cloudModel.pendingRefreshMaxAge = refreshIfStale
        if cloudModel.scanMountID != mount.id {
            cancelCloudAlbumScan()
            cloudModel.scanPhotos = []
            cloudModel.scanFolders = []
            cloudModel.scanMediaFolder = [:]
            cloudModel.scanPhotoPaths = []
            cloudModel.scanFolderPaths = []
            cloudModel.thumbnailPrefetchTask?.cancel()
            cloudModel.thumbnailPrefetchTask = nil
            cloudModel.pendingPhotoUpdates.removeAll()
            cloudModel.metadataDirty = false
            cloudModel.featuresLoadedMountID = nil
            cloudModel.isLoadingCloudFeatures = false
            cloudModel.scanSnapshot = nil
            cloudModel.selectedFolderPath = nil
            cloudModel.scanMountID = mount.id
            cloudModel.scanIndexPersistedFolderCount = 0
            cloudModel.lastPublishedScanMediaCount = -1
            cloudModel.scanLoadToken += 1
            cloudScopeCountsCache = CloudScopeCounts()
            cloudScopeCountsCacheKey = nil
        }
        cloudPath = cloudRootPath(for: mount)
        cloudTrail = [CloudCrumb(id: cloudPath, name: mount.name)]
        cloudFolders = []
        cloudError = nil
        cloudLoading = false
        cloudBusyText = nil
        cloudModel.overview = nil

        if !cloudModel.scanPhotos.isEmpty {
            cloudModel.scanMediaCount = cloudModel.scanPhotos.count
            presentCloudAlbumPhotos(mountID: mount.id)
            finishCloudAlbumOpen(mountID: mount.id)
            return
        }

        // 从 SQLite 索引恢复上次扫描结果：查询 + 映射都放到后台，避免打开网盘时卡主线程。
        cloudModel.scanLoadToken += 1
        let token = cloudModel.scanLoadToken
        let signature = Self.scopeSignature(mount)
        let store = metadataStore
        let favorites = cloudFavorites
        let keywords = cloudKeywords
        let marks = cloudMarks
        let viewedAt = cloudModel.viewedAt
        cloudModel.isRestoringScan = true
        cloudModel.scanPhase = .idle
        let restoreJobID = beginSourceJob(
            SourceJob(sourceID: .cloud(mount.id), kind: .index, title: "恢复网盘索引", isCancellable: false)
        )
        Task { [weak self] in
            guard let self else { return }
            let restored = await Task.detached(priority: .userInitiated) {
                Self.loadCloudAlbumSnapshotAndPhotos(store: store,
                                                     mount: mount,
                                                     signature: signature,
                                                     favorites: favorites,
                                                     keywords: keywords,
                                                     marks: marks,
                                                     viewedAt: viewedAt)
            }.value
            guard token == self.cloudModel.scanLoadToken,
                  self.cloudModel.scanMountID == mount.id else {
                self.cancelSourceJob(restoreJobID)
                return
            }
            self.cloudModel.isRestoringScan = false
            if let (snapshot, photos) = restored {
                self.applyCloudAlbumSnapshot(snapshot, photos: photos, mount: mount)
                self.finishSourceJob(restoreJobID,
                                     message: "已恢复 \(photos.count.formatted()) 项媒体 · \(snapshot.folderCount.formatted()) 个目录")
            } else {
                self.cloudPhotos = []
                self.cloudVisibleCacheKey = nil
                self.cloudScopeCountsCacheKey = nil
                self.cloudModel.scanPhase = .idle
                self.finishSourceJob(restoreJobID, message: "没有可恢复的索引")
            }
            self.finishCloudAlbumOpen(mountID: mount.id)
        }
    }

    /// 索引恢复完成后的入口：默认沿用 10 分钟自动重扫；影院入口要求更严格的新鲜度时立刻增量。
    func finishCloudAlbumOpen(mountID: UUID) {
        if let maxAge = cloudModel.pendingRefreshMaxAge {
            cloudModel.pendingRefreshMaxAge = nil
            refreshCloudIndexIfNeeded(mountID: mountID, maxAge: maxAge)
        } else {
            startCloudAlbumScanIfNeeded(mountID: mountID)
        }
        startCloudIndexRefreshLoop(mountID: mountID)
    }

    /// 停留在当前网盘 / 影院时，每 3 分钟合并做一次增量扫描；离开该挂载后自动结束。
    func startCloudIndexRefreshLoop(mountID: UUID) {
        cloudModel.refreshLoopTask?.cancel()
        cloudModel.refreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.currentCloudMountID == mountID else { return }
                self.ensureCloudIndexFresh(for: mountID, maxAge: 120)
            }
        }
    }

    /// 索引超过 `maxAge` 就做一次增量扫描；不满足时什么都不做。
    func refreshCloudIndexIfNeeded(mountID: UUID, maxAge: TimeInterval) {
        guard cloudModel.scanMountID == mountID,
              !cloudModel.scanPhase.isScanning else { return }
        let fresh: Bool
        if case .finished(let date) = cloudModel.scanPhase {
            fresh = Date().timeIntervalSince(date) < maxAge
        } else if let state = metadataStore?.loadCloudIndexState(mountID: mountID) {
            fresh = Date().timeIntervalSince(state.updatedAt) < maxAge
        } else {
            fresh = false
        }
        if fresh { return }
        beginCloudAlbumScan(mountID: mountID)
    }

    /// 影院 / 网盘入口：保证索引在 `maxAge` 秒内是新鲜的。
    /// 没有打开过这个挂载时先异步恢复索引（后台线程），恢复完成后再按阈值增量扫描。
    func ensureCloudIndexFresh(for mountID: UUID, maxAge: TimeInterval = 60) {
        guard cloudMount(for: mountID) != nil,
              !cloudModel.scanPhase.isScanning,
              !cinemaScrapeRunning else { return }
        if cloudModel.scanMountID == mountID, !cloudModel.scanPhotos.isEmpty {
            refreshCloudIndexIfNeeded(mountID: mountID, maxAge: maxAge)
        } else if let mount = cloudMount(for: mountID) {
            openCloudAlbum(mount, refreshIfStale: maxAge)
        }
    }

    /// App 回到前台时调用：只处理当前正在看的网盘 / 网盘影院。
    func refreshCurrentCloudIndexIfNeeded() {
        switch sidebarItem {
        case .cloudMount(let id), .cloudCinema(let id):
            ensureCloudIndexFresh(for: id, maxAge: 60)
        default:
            break
        }
    }

    /// 索引读取 + 记录映射都在后台完成：两万条记录不会卡住主线程。
    nonisolated static func loadCloudAlbumSnapshotAndPhotos(store: MetadataStore?,
                                                                    mount: CloudMount,
                                                                    signature: String,
                                                                    favorites: Set<String>,
                                                                    keywords: [String: [String]],
                                                                    marks: [String: CloudMark],
                                                                    viewedAt: [UUID: Date])
        -> (CloudScanSnapshot, [PhotoItem])? {
        guard let snapshot = loadCloudAlbumSnapshot(store: store,
                                                   mountID: mount.id,
                                                   signature: signature) else { return nil }
        let photos = snapshot.records.map {
            albumPhoto(record: $0,
                       mount: mount,
                       favorites: favorites,
                       keywords: keywords,
                       marks: marks,
                       viewedAt: viewedAt)
        }
        return (snapshot, photos)
    }

    /// 把索引 / 旧版快照恢复出来的清单灌回内存。
    func applyCloudAlbumSnapshot(_ snapshot: CloudScanSnapshot,
                                         photos: [PhotoItem],
                                         mount: CloudMount) {
        cloudModel.scanSnapshot = snapshot
        cloudModel.scanPhotos = photos
        cloudModel.scanFolders = snapshot.folders ?? []
        var mediaFolders: [String: String] = [:]
        mediaFolders.reserveCapacity(snapshot.records.count)
        for record in snapshot.records {
            if let folder = record.folderPath { mediaFolders[record.path] = folder }
        }
        cloudModel.scanMediaFolder = mediaFolders
        cloudModel.scanPhotoPaths = Set(cloudModel.scanPhotos.compactMap(\.cloudPath))
        cloudModel.scanFolderPaths = Set(cloudModel.scanFolders.map(\.path))
        cloudModel.scanIndexPersistedFolderCount = cloudModel.scanFolders.count
        cloudModel.scanFolderCount = snapshot.folderCount
        cloudModel.scanMediaCount = cloudModel.scanPhotos.count
        cloudModel.scanTruncated = snapshot.truncated
        cloudModel.scanPhase = .finished(snapshot.savedAt)
        presentCloudAlbumPhotos(mountID: mount.id)
        migrateLegacyCloudSnapshotIfNeeded(snapshot, mount: mount)
    }

    /// 旧版把整份扫描结果放在 `derived_reports` 的 JSON 里：第一次打开时顺手迁进索引表，
    /// 之后就走 SQLite 聚合查询，不再解析大 JSON。
    func migrateLegacyCloudSnapshotIfNeeded(_ snapshot: CloudScanSnapshot, mount: CloudMount) {
        guard let store = metadataStore,
              store.loadCloudIndexState(mountID: mount.id) == nil,
              !snapshot.records.isEmpty else { return }
        var folders = snapshot.folders ?? []
        if folders.isEmpty {
            folders = [CloudScanFolder(path: cloudRootPath(for: mount), name: mount.name, parentPath: "")]
        }
        store.saveCloudIndexBatch(mountID: mount.id,
                                  generation: 0,
                                  folders: folders,
                                  assets: snapshot.records)
        if snapshot.complete == true {
            store.setSetting(Self.cloudDeepScanSettingKey(mount.id),
                             String(snapshot.savedAt.timeIntervalSince1970))
        }
        store.finalizeCloudIndex(mountID: mount.id,
                                 state: MetadataStore.CloudIndexState(
                                    folderCount: snapshot.folderCount,
                                    mediaCount: snapshot.records.count,
                                    truncated: snapshot.truncated,
                                    complete: snapshot.complete ?? false,
                                    pathVersion: Self.cloudSnapshotPathVersion,
                                    scopeSignature: Self.scopeSignature(mount),
                                    updatedAt: snapshot.savedAt)) { [weak self] in
            guard let self else { return }
            self.cloudModel.cloudIndexRevision += 1
            self.cloudFolderTreeCacheKey = nil
            self.sourceContentCache.bump(.cloud(mount.id))
        }
    }

    /// 快照超过 10 分钟才自动重扫：反复点同一个网盘不会一直拉目录。
    static let cloudAlbumRescanInterval: TimeInterval = 10 * 60

    func startCloudAlbumScanIfNeeded(mountID: UUID) {
        guard currentCloudMountID == mountID else { return }
        switch cloudModel.scanPhase {
        case .scanning:
            return
        case .cancelled, .failed:
            // 用户主动停止 / 上次失败时不自动重启，等他点「重新扫描」。
            return
        case .finished(let date):
            guard Date().timeIntervalSince(date) >= Self.cloudAlbumRescanInterval else { return }
        case .idle:
            break
        }
        beginCloudAlbumScan(mountID: mountID)
    }

    /// 重新扫描整个挂载（手动刷新 / 首次进入）。
    /// - Parameter forceFull: 手动刷新时强制全量，确保能看到文件内容级别的变化；自动重扫允许增量。
    func beginCloudAlbumScan(mountID: UUID, forceFull: Bool = false) {
        guard let mount = cloudMount(for: mountID) else { return }
        cancelCloudAlbumScan()
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        cloudModel.scanMountID = mountID
        if let oldJob = cloudModel.scanJobID {
            cancelSourceJob(oldJob)
        }
        let scanJob = SourceJob(sourceID: .cloud(mountID), kind: .scan, title: "扫描 \(mount.name)")
        cloudModel.scanJobID = beginSourceJob(scanJob, cancel: { [weak self] in
            Task { @MainActor in
                // 只有这个任务仍是当前扫描时才停：重启扫描时旧任务的取消不应打断新扫描。
                guard let self, self.cloudModel.scanJobID == scanJob.id else { return }
                self.stopCloudAlbumScan()
            }
        })
        cloudModel.scanPhase = .scanning
        cloudModel.scanTruncated = false
        cloudModel.isRestoringScan = false
        // 本次扫描摘要：开始时间 + 基线媒体数（已存在 / 新增据此计算）。
        cloudModel.scanStartedAt = Date()
        cloudModel.scanBaselineMediaCount = cloudModel.scanPhotos.count

        // 增量：上一轮完整、未触顶、24 小时内，且目录修改时间可用。
        // 只跳过父目录列表里 mtime 未变的子树；任何不确定都会正常扫描。
        var plan: CloudScanner.IncrementalPlan?
        var planFromSQL = false
        if !forceFull, let store = metadataStore,
           let made = Self.makeIncrementalPlan(store: store, mountID: mountID, mount: mount) {
            plan = made
            planFromSQL = true
        } else if !forceFull,
                  let snapshot = cloudModel.scanSnapshot,
                  let made = Self.makeIncrementalPlan(snapshot) {
            plan = made
        }
        // 扫描代次：全量扫描结束后据此删掉索引里本轮没见到的旧行；
        // 增量扫描先把已有行全部标记为本轮，避免未回调的子树被误删。
        let generation = metadataStore?.beginCloudIndexScan(mountID: mountID,
                                                            keepExisting: plan != nil) ?? 0
        cloudModel.scanGeneration = generation
        cloudModel.scanIsDeep = plan == nil

        if plan != nil, planFromSQL, let store = metadataStore {
            let rows = store.loadCloudIndexFolders(mountID: mountID)
            if !rows.isEmpty {
                cloudModel.scanFolders = rows.map {
                    CloudScanFolder(path: $0.path,
                                    name: $0.name,
                                    parentPath: $0.parentPath,
                                    modifiedAt: $0.modifiedAt)
                }
                cloudModel.scanFolderPaths = Set(cloudModel.scanFolders.map(\.path))
                cloudModel.scanFolderCount = cloudModel.scanFolders.count
                cloudModel.scanIndexPersistedFolderCount = cloudModel.scanFolders.count
            }
        } else if plan != nil, let snapshot = cloudModel.scanSnapshot {
            cloudModel.scanFolders = snapshot.folders ?? []
            cloudModel.scanFolderPaths = Set(cloudModel.scanFolders.map(\.path))
            var mediaFolders = cloudModel.scanMediaFolder
            for record in snapshot.records {
                if let folder = record.folderPath { mediaFolders[record.path] = folder }
            }
            cloudModel.scanMediaFolder = mediaFolders
            cloudModel.scanFolderCount = cloudModel.scanFolders.count
            cloudModel.scanIndexPersistedFolderCount = cloudModel.scanFolders.count
        } else {
            let rootFolder = CloudScanFolder(path: cloudRootPath(for: mount),
                                             name: mount.name,
                                             parentPath: "")
            cloudModel.scanFolders = [rootFolder]
            cloudModel.scanFolderPaths = [rootFolder.path]
            cloudModel.scanMediaFolder = [:]
            cloudModel.scanFolderCount = 0
            cloudModel.scanIndexPersistedFolderCount = 1
            // 根目录先落库：即使扫描中途退出，下次也能从索引里恢复出目录层级。
            metadataStore?.saveCloudIndexBatch(mountID: mountID,
                                               generation: generation,
                                               folders: [rootFolder],
                                               assets: [])
        }
        if cloudModel.scanPhotoPaths.isEmpty, !cloudModel.scanPhotos.isEmpty {
            cloudModel.scanPhotoPaths = Set(cloudModel.scanPhotos.compactMap(\.cloudPath))
        }
        // 增量扫描只回调变化的子树：内存清单为空时先从索引补齐，避免复用子树「凭空消失」。
        if plan != nil, cloudModel.scanPhotos.isEmpty, let store = metadataStore {
            let records = store.loadCloudIndexAssets(mountID: mountID)
            if !records.isEmpty {
                cloudModel.scanPhotos = records.map { albumPhoto(record: $0, mount: mount) }
                var mediaFolders = cloudModel.scanMediaFolder
                for record in records {
                    if let folder = record.folderPath { mediaFolders[record.path] = folder }
                }
                cloudModel.scanMediaFolder = mediaFolders
                cloudModel.scanPhotoPaths = Set(cloudModel.scanPhotos.compactMap(\.cloudPath))
            }
        }
        cloudModel.scanSnapshot = nil
        cloudModel.thumbnailPrefetchTask?.cancel()
        cloudModel.thumbnailPrefetchTask = nil
        cloudModel.selectedFolderPath = nil
        cloudError = nil
        cloudModel.needsCloudReauth = false
        cloudModel.pendingScanFolderCount = cloudModel.scanFolderCount
        cloudModel.lastPublishedScanMediaCount = -1
        cloudModel.scanMediaCount = cloudModel.scanPhotos.count
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
        cloudFolderTreeCacheKey = nil
        presentCloudAlbumPhotos(mountID: mountID)

        cloudModel.scanTask = Task { [weak self] in
            guard let self else { return }
            let result = await CloudScanner.scan(mount: mount, incremental: plan) { batch, folderCount, mediaCount in
                self.ingestCloudAlbumBatch(batch,
                                           mount: mount,
                                           folderCount: folderCount,
                                           mediaCount: mediaCount)
            }
            guard !Task.isCancelled else { return }
            self.finishCloudAlbumScan(result: result, mountID: mountID)
        }
    }

    /// 把上一轮完整扫描（SQLite 索引）转换成增量扫描计划；不满足条件时返回 nil（走全量）。
    static func makeIncrementalPlan(store: MetadataStore,
                                            mountID: UUID,
                                            mount: CloudMount) -> CloudScanner.IncrementalPlan? {
        guard let state = store.loadCloudIndexState(mountID: mountID),
              state.complete, !state.truncated,
              Date().timeIntervalSince(state.updatedAt) < 24 * 3600,
              state.scopeSignature == scopeSignature(mount) else { return nil }
        // 目录 mtime 只能发现「新增 / 删除 / 改名」；已存在文件被同名替换时目录 mtime 不变。
        // 因此定期强制一次深度扫描（SMB 1 小时、其它网盘 6 小时），兜底文件内容更新。
        let deepAge: TimeInterval = mount.kind == .smb ? 3600 : 6 * 3600
        guard let deepRaw = store.setting(cloudDeepScanSettingKey(mountID)),
              let deepAt = Double(deepRaw),
              Date().timeIntervalSince1970 - deepAt < deepAge else { return nil }
        let folders = store.loadCloudIndexFolders(mountID: mountID)
        guard !folders.isEmpty, folders.contains(where: { $0.modifiedAt != nil }) else { return nil }
        var byPath: [String: CloudScanFolder] = [:]
        var children: [String: [String]] = [:]
        byPath.reserveCapacity(folders.count)
        for row in folders {
            byPath[row.path] = CloudScanFolder(path: row.path,
                                               name: row.name,
                                               parentPath: row.parentPath,
                                               modifiedAt: row.modifiedAt)
            children[row.parentPath, default: []].append(row.path)
        }
        var media: [String: [String]] = [:]
        for record in store.loadCloudIndexAssets(mountID: mountID) {
            guard let folder = record.folderPath else { continue }
            media[folder, default: []].append(record.path)
        }
        return CloudScanner.IncrementalPlan(foldersByPath: byPath,
                                            childrenByParent: children,
                                            mediaByFolder: media)
    }

    /// 旧版 JSON 快照的增量计划（仅用于迁移过渡）。
    static func makeIncrementalPlan(_ snapshot: CloudScanSnapshot) -> CloudScanner.IncrementalPlan? {
        guard snapshot.complete == true,
              !snapshot.truncated,
              Date().timeIntervalSince(snapshot.savedAt) < 24 * 3600,
              let folders = snapshot.folders, !folders.isEmpty,
              folders.contains(where: { $0.modifiedAt != nil }) else { return nil }
        var byPath: [String: CloudScanFolder] = [:]
        var children: [String: [String]] = [:]
        byPath.reserveCapacity(folders.count)
        for folder in folders {
            byPath[folder.path] = folder
            children[folder.parentPath, default: []].append(folder.path)
        }
        var media: [String: [String]] = [:]
        for record in snapshot.records {
            guard let folder = record.folderPath else { continue }
            media[folder, default: []].append(record.path)
        }
        return CloudScanner.IncrementalPlan(foldersByPath: byPath,
                                            childrenByParent: children,
                                            mediaByFolder: media)
    }

    func cancelCloudAlbumScan() {
        cloudModel.scanTask?.cancel()
        cloudModel.scanTask = nil
        if let jobID = cloudModel.scanJobID {
            cancelSourceJob(jobID)
            cloudModel.scanJobID = nil
        }
    }

    /// 更新接入范围与排除目录；返回 true 表示有变化（需要重扫）。nil 表示该项保持不变。
    @discardableResult
    func updateCloudMountAccess(_ mountID: UUID,
                                scopes: [CloudScopeRoot]?,
                                excludes: [CloudScopeRoot]? = nil) -> Bool {
        guard let index = cloudMounts.firstIndex(where: { $0.id == mountID }) else { return false }
        var mount = cloudMounts[index]
        var changed = false
        if let scopes, mount.scopeRoots != scopes {
            mount.scopeRoots = scopes
            changed = true
        }
        if let excludes, mount.excludedRoots != excludes {
            mount.excludedRoots = excludes
            changed = true
        }
        guard changed else { return false }
        cloudMounts[index] = mount
        saveCloudMounts()
        clearCloudScanForScopeChange(mountID: mountID)
        return true
    }

    /// 接入范围变化后，旧目录树、快照与缓存都不再适用，必须从头扫一遍。
    func clearCloudScanForScopeChange(mountID: UUID) {
        cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(mountID.uuidString) }
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
        cloudFolderTreeCacheKey = nil
        // 接入范围变了：旧索引整体作废，下一次扫描重新建表（即使当前打开的不是这个挂载）。
        metadataStore?.purgeCloudIndex(mountID: mountID)
        metadataStore?.setSetting(Self.cloudDeepScanSettingKey(mountID), nil)
        guard cloudModel.scanMountID == mountID else { return }
        cancelCloudAlbumScan()
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        cloudModel.scanPhotos = []
        cloudModel.scanFolders = []
        cloudModel.scanMediaFolder = [:]
        cloudModel.scanPhotoPaths = []
        cloudModel.scanFolderPaths = []
        cloudModel.scanSnapshot = nil
        cloudModel.scanFolderCount = 0
        cloudModel.scanMediaCount = 0
        cloudModel.pendingScanFolderCount = 0
        cloudModel.lastPublishedScanMediaCount = -1
        cloudModel.scanIndexPersistedFolderCount = 0
        cloudModel.scanGeneration = 0
        cloudModel.scanPhase = .idle
        cloudModel.selectedFolderPath = nil
        cloudPhotos = []
    }

    /// 用户手动停止扫描：保留已发现的媒体，并落一份部分状态供下次打开直接显示。
    func stopCloudAlbumScan() {
        cancelCloudAlbumScan()
        guard cloudModel.scanPhase.isScanning else { return }
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        cloudModel.scanPhase = .cancelled
        cloudModel.scanFolderCount = cloudModel.pendingScanFolderCount
        cloudModel.scanMediaCount = cloudModel.scanPhotos.count
        if let mountID = cloudModel.scanMountID {
            saveCloudAlbumSnapshot(mountID: mountID)
        }
    }

    func ingestCloudAlbumBatch(_ batch: CloudScanner.Batch,
                                       mount: CloudMount,
                                       folderCount: Int,
                                       mediaCount: Int) {
        guard cloudModel.scanMountID == mount.id,
              cloudModel.scanPhase.isScanning else { return }
        cloudModel.pendingScanFolderCount = folderCount
        let updatedFolders = registerCloudFolders(batch.folders, container: batch.container, mount: mount)
        for entry in batch.media {
            cloudModel.scanMediaFolder[entry.path] = batch.container
        }
        guard !batch.media.isEmpty else {
            persistCloudIndexBatch(mount: mount,
                                   folders: updatedFolders,
                                   assets: [])
            return
        }

        // 增量去重：只用本批与累积集合比较，避免每批都重建整份 scanPhotos 的路径集合。
        var added: [PhotoItem] = []
        for entry in batch.media where cloudModel.scanPhotoPaths.insert(entry.path).inserted {
            added.append(makeCloudPhoto(mount: mount, entry: entry))
        }
        guard !added.isEmpty else {
            persistCloudIndexBatch(mount: mount, folders: updatedFolders, assets: [])
            return
        }
        cloudModel.scanPhotos.append(contentsOf: added)
        persistCloudIndexBatch(mount: mount, folders: updatedFolders, assets: added)
        // 扫描期间不再逐目录 publish：合并成 0.6 秒一次，侧边栏与网格只重算一次。
        scheduleCloudScanProgressPublish(mountID: mount.id)
    }

    /// 把本批新增 / 更新的目录与媒体写入 SQLite 索引（后台串行队列，不阻塞扫描）。
    func persistCloudIndexBatch(mount: CloudMount,
                                        folders: [CloudScanFolder],
                                        assets: [PhotoItem]) {
        guard let store = metadataStore else { return }
        let start = min(cloudModel.scanIndexPersistedFolderCount, cloudModel.scanFolders.count)
        let appended = start < cloudModel.scanFolders.count
            ? Array(cloudModel.scanFolders[start...])
            : []
        cloudModel.scanIndexPersistedFolderCount = cloudModel.scanFolders.count
        let allFolders = appended + folders
        let records = assets.compactMap {
            Self.albumRecord(photo: $0, mediaFolders: cloudModel.scanMediaFolder)
        }
        guard !allFolders.isEmpty || !records.isEmpty else { return }
        store.saveCloudIndexBatch(mountID: mount.id,
                                  generation: cloudModel.scanGeneration,
                                  folders: allFolders,
                                  assets: records)
    }

    /// 记录扫描到的目录（父目录缺失时按路径补出来，SMB 的扁平结果也能建树）。
    /// - Returns: 本批需要回写索引的目录（新建 + mtime / 名称变化的），供增量扫描下一轮复用。
    @discardableResult
    func registerCloudFolders(_ folders: [CloudEntry],
                                      container: String,
                                      mount: CloudMount) -> [CloudScanFolder] {
        ensureCloudFolder(path: container, parent: nil, name: nil, mount: mount)
        var indexByPath: [String: Int] = [:]
        indexByPath.reserveCapacity(cloudModel.scanFolders.count)
        for (offset, folder) in cloudModel.scanFolders.enumerated() {
            indexByPath[folder.path] = offset
        }
        var changed: [CloudScanFolder] = []
        for entry in folders {
            if let offset = indexByPath[entry.path] {
                // 已存在的目录也要刷新 mtime：否则下一轮增量会一直把它当成"有变化"重复扫描。
                var updated = cloudModel.scanFolders[offset]
                var dirty = false
                if let modified = entry.modifiedAt, updated.modifiedAt != modified {
                    updated.modifiedAt = modified
                    dirty = true
                }
                if updated.name != entry.name {
                    updated.name = entry.name
                    dirty = true
                }
                if dirty {
                    cloudModel.scanFolders[offset] = updated
                    changed.append(updated)
                }
            } else if cloudModel.scanFolderPaths.insert(entry.path).inserted {
                let folder = CloudScanFolder(path: entry.path,
                                             name: entry.name,
                                             parentPath: container,
                                             modifiedAt: entry.modifiedAt)
                indexByPath[entry.path] = cloudModel.scanFolders.count
                cloudModel.scanFolders.append(folder)
                changed.append(folder)
            }
        }
        cloudFolderTreeCacheKey = nil
        return changed
    }

    func ensureCloudFolder(path: String,
                                   parent: String?,
                                   name: String?,
                                   mount: CloudMount) {
        let rootPath = cloudRootPath(for: mount)
        if cloudModel.scanFolderPaths.contains(path) { return }
        if path == rootPath {
            cloudModel.scanFolders.append(CloudScanFolder(path: path,
                                                          name: mount.name,
                                                          parentPath: ""))
            cloudModel.scanFolderPaths.insert(path)
            return
        }
        let resolvedParent = parent ?? CloudScanner.parentPath(of: path)
        if resolvedParent != rootPath, resolvedParent != path {
            ensureCloudFolder(path: resolvedParent, parent: nil, name: nil, mount: mount)
        }
        guard cloudModel.scanFolderPaths.insert(path).inserted else { return }
        let fallbackName = path.split(separator: "/").last.map(String.init) ?? "文件夹"
        cloudModel.scanFolders.append(CloudScanFolder(path: path,
                                                      name: name ?? fallbackName,
                                                      parentPath: resolvedParent))
    }

    func finishCloudAlbumScan(result: CloudScanner.Result, mountID: UUID) {
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        // 完整扫完（未触顶、没有目录读取失败）才按扫描结果剔除网盘上已删除的项目。
        if !result.truncated, result.failedFolders == 0, result.folderCount > 0 {
            let seen = result.mediaPaths
            let removed = cloudModel.scanPhotos.compactMap { photo -> String? in
                guard let path = photo.cloudPath, !seen.contains(path) else { return nil }
                return path
            }
            if !removed.isEmpty {
                metadataStore?.deleteCloudIndexAssets(mountID: mountID, paths: removed)
            }
            cloudModel.scanPhotos.removeAll { !seen.contains($0.cloudPath ?? "") }
        }
        // 增量扫描发现某些子树已从远端消失：把目录树与路径 → 目录映射一起清掉。
        if !result.removedFolderPaths.isEmpty {
            let removed = result.removedFolderPaths
            metadataStore?.deleteCloudIndexFolders(mountID: mountID, paths: Array(removed))
            cloudModel.scanFolders.removeAll { folder in
                removed.contains(folder.path)
                    || removed.contains(where: { folder.path.hasPrefix($0 + "/") })
            }
            cloudModel.scanFolderPaths = Set(cloudModel.scanFolders.map(\.path))
            cloudModel.scanMediaFolder = cloudModel.scanMediaFolder.filter { _, folder in
                !removed.contains(folder)
                    && !removed.contains(where: { folder.hasPrefix($0 + "/") })
            }
        }
        cloudModel.scanFolderCount = result.folderCount
        cloudModel.pendingScanFolderCount = result.folderCount
        cloudModel.scanMediaCount = cloudModel.scanPhotos.count
        cloudModel.scanTruncated = result.truncated
        cloudModel.scanPhase = .finished(Date())
        if let jobID = cloudModel.scanJobID {
            if let error = result.firstErrorDescription, result.mediaCount == 0 {
                failSourceJob(jobID, message: error)
            } else {
                finishSourceJob(jobID,
                                message: "扫描完成 · \(result.folderCount) 个目录 · \(cloudModel.scanPhotos.count) 项媒体")
            }
            cloudModel.scanJobID = nil
        }
        cloudModel.scanTask = nil
        cloudModel.scanSnapshot = nil
        // 扫描期间不再每批全量排序；结束时排一次，快照顺序稳定，省下每批 O(n log n)。
        cloudModel.scanPhotos.sort { $0.capturedAt > $1.capturedAt }
        cloudModel.scanPhotoPaths = Set(cloudModel.scanPhotos.compactMap(\.cloudPath))
        presentCloudAlbumPhotos(mountID: mountID)
        // 一条都没扫到且有目录报错（常见于授权失效 / 钥匙串拒绝）：把原因显示在相册页顶部。
        if cloudModel.scanPhotos.isEmpty, let message = result.firstErrorDescription {
            cloudError = message
            cloudModel.needsCloudReauth = result.sawAuthError
            if result.sawAuthError { CloudCredentials.invalidate(for: mountID) }
        } else {
            cloudModel.needsCloudReauth = false
        }
        let complete = !result.truncated
            && result.failedFolders == 0
            && result.folderCount > 0
        // 完整扫完才清理索引旧行：中断 / 触顶的扫描保留上次目录，避免界面突然变空。
        if complete, cloudModel.scanGeneration != 0 {
            metadataStore?.pruneCloudIndex(mountID: mountID,
                                           generation: cloudModel.scanGeneration)
        }
        saveCloudAlbumSnapshot(mountID: mountID, complete: complete)
        // EXIF 与刮削都让路：先让网格与侧边栏稳定，再在空闲时补读元数据。
        // 刮削只由用户进入影院 / 显式点击触发，避免扫描结束后同时抢占网络与 CPU。
        cloudModel.metadataScanDelayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.scanCloudMetadataIfNeeded()
        }
        if result.truncated {
            showToast("已扫描 \(result.folderCount) 个文件夹，达到扫描上限；可在「相簿」里查看已扫描的目录")
        }
    }

    /// 把扫描清单（按当前选中的文件夹相簿筛选）贴到网格。
    func presentCloudAlbumPhotos(mountID: UUID) {
        guard currentCloudMountID == mountID else { return }
        cloudPhotos = cloudPhotosForSelection()
        cloudModel.lastPublishedScanMediaCount = cloudModel.scanPhotos.count
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
        cloudFolderTreeCacheKey = nil
        // 搜索里点开的文件可能刚随快照恢复进来：这时补开查看器。
        consumePendingCloudOpenIfNeeded()
    }

    /// 合并扫描进度：每 0.6 秒最多发布一次，避免每个目录都触发整页重算。
    func scheduleCloudScanProgressPublish(mountID: UUID) {
        guard cloudModel.scanPublishTask == nil else { return }
        cloudModel.scanPublishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.cloudModel.scanPublishTask = nil
            guard self.cloudModel.scanMountID == mountID,
                  self.cloudModel.scanPhase.isScanning else { return }
            self.publishCloudScanProgress(mountID: mountID)
        }
    }

    func publishCloudScanProgress(mountID: UUID) {
        guard cloudModel.scanMountID == mountID else { return }
        let mediaCount = cloudModel.scanPhotos.count
        let folderCount = cloudModel.pendingScanFolderCount
        guard mediaCount != cloudModel.lastPublishedScanMediaCount
                || folderCount != cloudModel.scanFolderCount else { return }
        cloudModel.lastPublishedScanMediaCount = mediaCount
        cloudModel.scanFolderCount = folderCount
        cloudModel.scanMediaCount = mediaCount
        if let jobID = cloudModel.scanJobID {
            updateSourceJob(jobID,
                            completed: folderCount,
                            message: "已扫描 \(folderCount) 个目录 · \(mediaCount) 项媒体")
        }
        cloudPhotos = cloudPhotosForSelection()
        cloudVisibleCacheKey = nil
        cloudScopeCountsCacheKey = nil
        cloudFolderTreeCacheKey = nil
        cloudFolderDescendantCacheKey = nil
    }

    func cloudPhotosForSelection() -> [PhotoItem] {
        guard let selected = cloudModel.selectedFolderPath else { return cloudModel.scanPhotos }
        let paths = cloudDescendantFolderPaths(of: selected)
        return cloudModel.scanPhotos.filter { photo in
            guard let path = photo.cloudPath,
                  let folder = cloudModel.scanMediaFolder[path] else { return false }
            return paths.contains(folder)
        }
    }

    /// 选中目录及其所有子目录。
    func cloudDescendantFolderPaths(of path: String) -> Set<String> {
        let key = "\(cloudModel.revision)|\(path)|\(cloudModel.scanFolders.count)"
        if cloudFolderDescendantCacheKey == key { return cloudFolderDescendantCacheValue }
        var childrenByParent: [String: [String]] = [:]
        for folder in cloudModel.scanFolders {
            childrenByParent[folder.parentPath, default: []].append(folder.path)
        }
        var result: Set<String> = [path]
        var queue = [path]
        while let next = queue.popLast() {
            for child in childrenByParent[next] ?? [] where result.insert(child).inserted {
                queue.append(child)
            }
        }
        cloudFolderDescendantCacheKey = key
        cloudFolderDescendantCacheValue = result
        return result
    }
}
