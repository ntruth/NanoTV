import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore


/// 网盘图库的全盘扫描快照与总览索引概况。

extension LibraryStore {
    // MARK: 全盘扫描快照

    nonisolated static let cloudAlbumSnapshotKind = "album-scan"

    func loadCloudAlbumSnapshot(mountID: UUID) -> CloudScanSnapshot? {
        Self.loadCloudAlbumSnapshot(store: metadataStore,
                                    mountID: mountID,
                                    signature: Self.scopeSignature(cloudMount(for: mountID)))
    }

    /// 从 SQLite 索引恢复扫描结果；索引为空时回退旧版 JSON 快照（仅迁移用）。
    nonisolated static func loadCloudAlbumSnapshot(store: MetadataStore?,
                                                           mountID: UUID,
                                                           signature: String) -> CloudScanSnapshot? {
        guard let store else { return nil }
        if let state = store.loadCloudIndexState(mountID: mountID),
           state.mediaCount > 0,
           state.pathVersion >= cloudSnapshotPathVersion,
           state.scopeSignature == signature {
            let records = store.loadCloudIndexAssets(mountID: mountID)
            guard !records.isEmpty else { return nil }
            let folders = store.loadCloudIndexFolders(mountID: mountID).map {
                CloudScanFolder(path: $0.path,
                                name: $0.name,
                                parentPath: $0.parentPath,
                                modifiedAt: $0.modifiedAt)
            }
            return CloudScanSnapshot(savedAt: state.updatedAt,
                                     folderCount: state.folderCount,
                                     truncated: state.truncated,
                                     records: records,
                                     folders: folders,
                                     complete: state.complete,
                                     pathVersion: state.pathVersion,
                                     scopeSignature: state.scopeSignature)
        }
        // 旧版 path：整份 JSON 写在一个 derived_reports 行里。
        let key = DerivedReportKey.cloud(mountID, "", cloudAlbumSnapshotKind)
        guard let cached = store.loadDerivedReport(key: key),
              let snapshot = try? JSONDecoder().decode(CloudScanSnapshot.self, from: cached.payload),
              (snapshot.pathVersion ?? 1) >= cloudSnapshotPathVersion,
              (snapshot.scopeSignature ?? "") == signature else { return nil }
        return snapshot
    }

    /// 接入范围签名：包含目录与排除目录排序后拼接，用于判断快照是否还属于当前选择。
    static func scopeSignature(_ mount: CloudMount?) -> String {
        guard let mount else { return "" }
        let includes = mount.scopeRoots.map(\.path).sorted().joined(separator: ",")
        let excludes = mount.excludedRoots.map(\.path).sorted().joined(separator: ",")
        if includes.isEmpty, excludes.isEmpty { return "" }
        return "in:\(includes)|out:\(excludes)"
    }

    /// 上一次「深度扫描」的时间（秒）：增量扫描不更新它，只有全量扫描成功后才刷新。
    static func cloudDeepScanSettingKey(_ mountID: UUID) -> String {
        "cloud_deep_scan|\(mountID.uuidString)"
    }

    /// 网盘条目路径的语义版本：递增会让旧快照失效并触发一次全量重扫。
    /// 2：修复 WebDAV 子目录里的文件被记成裸文件名（导致播放 404）。
    /// 3：阿里云盘路径改为「盘ID|文件ID」，覆盖默认盘 / 资源库 / 备份盘。
    nonisolated static let cloudSnapshotPathVersion = 3

    /// 扫描结束 / 手动停止：聚合计数与状态落库。扫描期间媒体与目录已按批写入，
    /// 这里只重算一次「目录 → 直属数量 / 封面」，不再编码整份 JSON。
    func saveCloudAlbumSnapshot(mountID: UUID, complete: Bool = false) {
        guard let store = metadataStore else { return }
        if complete, cloudModel.scanIsDeep {
            store.setSetting(Self.cloudDeepScanSettingKey(mountID),
                             String(Date().timeIntervalSince1970))
        }
        let state = MetadataStore.CloudIndexState(folderCount: cloudModel.scanFolderCount,
                                                  mediaCount: cloudModel.scanPhotos.count,
                                                  truncated: cloudModel.scanTruncated,
                                                  complete: complete,
                                                  pathVersion: Self.cloudSnapshotPathVersion,
                                                  scopeSignature: Self.scopeSignature(cloudMount(for: mountID)),
                                                  updatedAt: Date())
        store.finalizeCloudIndex(mountID: mountID, state: state) { [weak self] in
            guard let self, self.cloudModel.scanMountID == mountID else { return }
            self.cloudModel.cloudIndexRevision += 1
            self.cloudFolderTreeCacheKey = nil
            self.sourceContentCache.bump(.cloud(mountID))
        }
        // 内存里的旧快照只用于旧版增量路径；SQLite 状态已经更新。
        cloudModel.scanSnapshot = nil
    }

    /// 影院刮削需要读取扫描快照与快照里的媒体条目（文件内私有实现，这里开一个内部入口）。
    func cloudAlbumSnapshot(mountID: UUID) -> CloudScanSnapshot? {
        loadCloudAlbumSnapshot(mountID: mountID)
    }

    // MARK: 总览用的轻量索引概况

    /// 每个挂载的索引状态：目录数 / 媒体数 / 是否完整 / 最近扫描时间。
    /// 只查状态行，不加载索引里的媒体清单，网盘总览的「索引」页可以放心一次读完。
    func cloudIndexStates() -> [UUID: MetadataStore.CloudIndexState] {
        guard let store = metadataStore else { return [:] }
        var result: [UUID: MetadataStore.CloudIndexState] = [:]
        for mount in cloudMounts {
            if let state = store.loadCloudIndexState(mountID: mount.id) {
                result[mount.id] = state
            }
        }
        return result
    }

    /// 上一次「深度扫描」的时间：增量扫描不会刷新它，只有完整重扫成功后才更新。
    func cloudDeepScanDate(_ mountID: UUID) -> Date? {
        guard let raw = metadataStore?.setting(Self.cloudDeepScanSettingKey(mountID)),
              let seconds = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func cloudAlbumPhoto(record: CloudScanRecord, mount: CloudMount) -> PhotoItem {
        albumPhoto(record: record, mount: mount)
    }

    nonisolated static func albumRecord(photo: PhotoItem,
                                                mediaFolders: [String: String]) -> CloudScanRecord? {
        guard let path = photo.cloudPath else { return nil }
        return CloudScanRecord(path: path,
                               name: photo.originalName,
                               size: photo.fileSize,
                               // 远端修改时间（「最近保存」用），不要拿 EXIF 拍摄时间覆盖它。
                               modifiedAt: photo.addedAt,
                               width: photo.pixelWidth,
                               height: photo.pixelHeight,
                               duration: photo.duration,
                               remoteID: photo.cloudRemoteID,
                               thumbnailURL: photo.cloudThumbnailURL,
                               isVideo: photo.isVideo,
                               folderPath: mediaFolders[path],
                               codec: photo.videoCodec,
                               capturedAt: photo.capturedAt,
                               addedAt: photo.addedAt)
    }

    func albumPhoto(record: CloudScanRecord, mount: CloudMount) -> PhotoItem {
        Self.albumPhoto(record: record,
                        mount: mount,
                        favorites: cloudFavorites,
                        keywords: cloudKeywords,
                        marks: cloudMarks,
                        viewedAt: cloudModel.viewedAt)
    }

    /// 纯函数版本：索引恢复时在后台线程批量映射，避免两万条记录阻塞主线程。
    nonisolated static func albumPhoto(record: CloudScanRecord,
                                       mount: CloudMount,
                                       favorites: Set<String>,
                                       keywords: [String: [String]],
                                       marks: [String: CloudMark],
                                       viewedAt: [UUID: Date]) -> PhotoItem {
        var entry = CloudEntry(path: record.path,
                               name: record.name,
                               isDirectory: false,
                               size: record.size,
                               modifiedAt: record.modifiedAt ?? record.addedAt,
                               contentType: record.isVideo ? "video/mp4" : nil)
        entry.thumbnailURL = record.thumbnailURL
        entry.remoteID = record.remoteID
        entry.pixelWidth = record.width
        entry.pixelHeight = record.height
        entry.duration = record.duration
        entry.codecName = record.codec
        var photo = makeCloudPhoto(mount: mount,
                                   entry: entry,
                                   favorites: favorites,
                                   keywords: keywords,
                                   marks: marks,
                                   viewedAt: viewedAt)
        if let captured = record.capturedAt ?? record.modifiedAt {
            photo.capturedAt = captured
        }
        if let added = record.addedAt ?? record.modifiedAt {
            photo.addedAt = added
        }
        return photo
    }

    /// 换库 / 断开挂载时清掉扫描任务与清单。
    func resetCloudAlbumScan() {
        cancelCloudAlbumScan()
        cloudModel.scanPublishTask?.cancel()
        cloudModel.scanPublishTask = nil
        cloudModel.metadataScanDelayTask?.cancel()
        cloudModel.metadataScanDelayTask = nil
        cloudModel.refreshLoopTask?.cancel()
        cloudModel.refreshLoopTask = nil
        cloudModel.scanLoadToken += 1
        cloudModel.isRestoringScan = false
        cloudModel.thumbnailPrefetchTask?.cancel()
        cloudModel.thumbnailPrefetchTask = nil
        cloudModel.metadataFlushTask?.cancel()
        cloudModel.metadataFlushTask = nil
        cloudModel.metadataDirty = false
        cloudModel.pendingPhotoUpdates.removeAll()
        cloudModel.featuresLoadedMountID = nil
        cloudModel.isLoadingCloudFeatures = false
        cloudModel.scanPhase = .idle
        cloudModel.scanFolderCount = 0
        cloudModel.scanMediaCount = 0
        cloudModel.pendingScanFolderCount = 0
        cloudModel.lastPublishedScanMediaCount = -1
        cloudModel.scanIndexPersistedFolderCount = 0
        cloudModel.scanGeneration = 0
        cloudModel.scanTruncated = false
        cloudModel.scanPhotos = []
        cloudModel.scanFolders = []
        cloudModel.scanMediaFolder = [:]
        cloudModel.scanPhotoPaths = []
        cloudModel.scanFolderPaths = []
        cloudModel.selectedFolderPath = nil
        cloudModel.scanMountID = nil
        cloudModel.scanSnapshot = nil
        cloudFolderTreeCacheKey = nil
        cloudFolderDescendantCacheKey = nil
    }

    func loadCloudMounts() {
        guard let json = metadataStore?.setting("cloud_mounts"),
              let data = json.data(using: .utf8),
              let mounts = try? JSONDecoder().decode([CloudMount].self, from: data) else { return }
        cloudMounts = mounts
    }

    func saveCloudMounts() {
        guard let metadataStore,
              let data = try? JSONEncoder().encode(cloudMounts),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting("cloud_mounts", json)
    }

    /// 调整网盘在侧边栏里的顺序：注册表按 `cloudMounts` 的顺序生成，
    /// 排序结果同样作用于网盘总览与影院入口。
    func moveCloudMount(_ id: UUID, by offset: Int) {
        guard let index = cloudMounts.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard cloudMounts.indices.contains(target) else { return }
        cloudMounts.swapAt(index, target)
        saveCloudMounts()
    }

    /// 网盘密码由 `CloudCredentials` 在进程内缓存：目录滚动不会反复读钥匙串，
    /// 只有第一次连接或认证失败后才重新读取。
    func cloudPassword(for mountID: UUID) -> String {
        CloudCredentials.password(for: mountID)
    }

    /// 认证失败说明钥匙串里的密码可能已经过期：丢掉内存缓存，下次点击重新读取。
    func invalidateCloudPasswordIfNeeded(_ error: Error, mountID: UUID) {
        if let webdav = error as? WebDAVError, case .unauthorized = webdav {
            CloudCredentials.invalidate(for: mountID)
            return
        }
        if error is SMBError {
            let message = error.localizedDescription
            if message.contains("认证") || message.contains("密码") {
                CloudCredentials.invalidate(for: mountID)
            }
        }
    }

    func cloudMount(for id: UUID?) -> CloudMount? {
        guard let id else { return nil }
        return cloudMounts.first(where: { $0.id == id })
    }

    func presentCloudSheet(_ mount: CloudMount?) {
        cloudSheetMount = mount
        showCloudSheet = true
    }

    func presentCloudWizard(flow: CloudWizardFlow? = nil) {
        cloudSheetMount = nil
        showCloudSheet = false
        cloudWizardInitialFlow = flow
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            showCloudWizard = true
        }
    }

    /// 编辑已有挂载的接入范围：直接打开确认页，凭据从钥匙串带入。
    func presentCloudWizard(editing mount: CloudMount) {
        cloudWizardEditingMountID = mount.id
        presentCloudWizard(flow: mount.kind.wizardFlow)
    }

    func probeAList(address: String) async -> (ok: Bool, message: String) {
        await AListProbe.check(address: address)
    }

    func dismissCloudSheet() {
        showCloudSheet = false
        cloudSheetMount = nil
    }

    func testCloudConnection(address: String, username: String,
                             password: String,
                             trustSelfSigned: Bool = false) async -> (ok: Bool, message: String) {
        if CloudKind.detect(from: address) == .smb {
            return await SMBClient.test(address: address, username: username, password: password)
        }
        guard let client = WebDAVClient(baseURLString: address,
                                        username: username,
                                        password: password,
                                        allowsSelfSignedCertificate: trustSelfSigned) else {
            return (false, "服务器地址无效，请填写 http(s)://主机:端口/路径")
        }
        do {
            let entries = try await client.list(path: "")
            let folders = entries.filter { $0.isDirectory }.count
            let media = entries.filter { !$0.isDirectory && $0.isMedia }.count
            return (true, "连接成功：\(folders) 个文件夹、\(media) 个媒体文件")
        } catch {
            let description = error.localizedDescription
            let isTrustError = description.contains("SSL") || description.contains("TLS")
                || description.contains("certificate") || description.contains("证书")
            if isTrustError {
                return (false, "连接失败：\(description)。HTTPS 地址若使用自签名证书，请勾选「信任自签名证书」。")
            }
            return (false, "连接失败：\(description)")
        }
    }

    @discardableResult
    func saveCloudMount(existing: CloudMount?, name: String, address: String,
                        username: String, password: String,
                        kind requestedKind: CloudKind = .webdav,
                        trustSelfSigned: Bool = false,
                        scopes: [CloudScopeRoot]? = nil,
                        excludes: [CloudScopeRoot]? = nil) -> String? {
        let kind = existing?.kind ?? CloudKind.detect(from: address) ?? requestedKind
        let normalized: String
        let host: String?
        switch kind {
        case .smb:
            guard let value = SMBClient.normalizedAddress(address) else {
                return "SMB 地址无效，请填写 smb://主机/共享名，例如 smb://192.168.1.10/photo"
            }
            normalized = value
            host = URLComponents(string: value)?.host
        default:
            guard let base = WebDAVClient.normalizedBaseURL(address) else {
                return "服务器地址无效，请填写 http(s)://主机:端口/路径"
            }
            normalized = base.absoluteString
            host = base.host
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = kind == .smb
            ? (SMBClient.displayName(address) ?? "SMB 共享")
            : (host ?? "网络存储")
        let finalName = trimmedName.isEmpty ? fallbackName : trimmedName

        if var mount = existing, let index = cloudMounts.firstIndex(where: { $0.id == mount.id }) {
            let previousAddress = mount.baseURL
            mount.name = finalName
            mount.baseURL = normalized
            mount.username = username
            mount.trustSelfSigned = trustSelfSigned
            cloudMounts[index] = mount
            if !password.isEmpty {
                CloudCredentials.setPassword(password, for: mount.id)
            }
            if mount.kind == .smb, previousAddress != normalized {
                SMBClient.unmount(address: previousAddress)
                // 换了共享 / 目录后旧范围不再适用；向导显式传入的范围除外。
                if scopes == nil { mount.scopeRoots = [] }
                if excludes == nil { mount.excludedRoots = [] }
            }
            cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(mount.id.uuidString) }
            saveCloudMounts()
            updateCloudMountAccess(mount.id, scopes: scopes, excludes: excludes)
            if case .cloudMount(let current) = sidebarItem, current == mount.id {
                beginCloudAlbumScan(mountID: mount.id)
            }
            showToast("已更新「\(finalName)」")
            return nil
        }

        let mount = CloudMount(kind: kind, name: finalName,
                               baseURL: normalized, username: username,
                               scanAll: kind == .smb,
                               trustSelfSigned: kind == .webdav && trustSelfSigned,
                               scopeRoots: scopes ?? [],
                               excludedRoots: excludes ?? [])
        cloudMounts.append(mount)
        CloudCredentials.setPassword(password, for: mount.id)
        saveCloudMounts()
        showToast("已添加「\(finalName)」")
        navigate(to: .cloudMount(mount.id))
        return nil
    }

    /// 只改侧边栏里的显示名称，不动地址、凭据与缓存。
    func renameCloudMount(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = cloudMounts.firstIndex(where: { $0.id == id }) else { return }
        guard cloudMounts[index].name != trimmed else { return }
        cloudMounts[index].name = trimmed
        saveCloudMounts()
        showToast("已重命名为「\(trimmed)」")
    }

    func removeCloudMount(_ id: UUID) {
        if let mount = cloudMounts.first(where: { $0.id == id }), mount.kind == .smb {
            SMBClient.unmount(address: mount.baseURL)
        }
        cloudMounts.removeAll { $0.id == id }
        CloudCredentials.delete(for: id)
        CloudOAuthStore.deleteToken(mountID: id)
        if cloudModel.insightMountID == id { resetCloudInsight() }
        if cloudModel.scanMountID == id { resetCloudAlbumScan() }
        // 清掉该挂载的本地收藏记录，避免残留键越积越多。
        let favoritePrefix = "\(id.uuidString)|"
        if cloudFavorites.contains(where: { $0.hasPrefix(favoritePrefix) }) {
            cloudFavorites = cloudFavorites.filter { !$0.hasPrefix(favoritePrefix) }
            persistCloudFavorites()
        }
        cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(id.uuidString) }
        // 清掉该挂载的持久化缓存：EXIF / 识别 / 特征 / 人物 / 派生报告 / 扫描索引。
        metadataStore?.purgeCloudAssets(mountID: id)
        metadataStore?.purgeCloudPeople(mountID: id)
        metadataStore?.purgeCloudIndex(mountID: id)
        metadataStore?.setSetting(Self.cloudDeepScanSettingKey(id), nil)
        metadataStore?.removeDerivedReports(prefix: DerivedReportKey.cloudMountPrefix(id))
        try? FileManager.default.removeItem(at: LibraryPaths.cloudThumbs.appendingPathComponent(id.uuidString,
                                                                                            isDirectory: true))
        if case .cloudMount(let current) = sidebarItem, current == id {
            navigate(to: .library)
        }
        saveCloudMounts()
        showToast("已断开网络存储")
    }

    func openCloudMount(_ id: UUID) {
        guard let mount = cloudMounts.first(where: { $0.id == id }) else { return }
        prepareCloudInsight(for: id)
        cloudModel.overview = nil
        openCloudAlbum(mount)
    }


    func refreshCloudDirectory() {
        guard let id = currentCloudMountID else { return }
        // 手动刷新走全量：文件内容变化不一定改变父目录 mtime，只有全量能发现。
        beginCloudAlbumScan(mountID: id, forceFull: true)
    }

    func cloudGoUp() {
        guard let selected = cloudModel.selectedFolderPath,
              let folder = cloudModel.scanFolders.first(where: { $0.path == selected }) else { return }
        let rootPath = cloudMount(for: currentCloudMountID).map { cloudRootPath(for: $0) } ?? ""
        selectCloudFolder(path: folder.parentPath == rootPath ? nil : folder.parentPath)
    }

    func loadCloudDirectory(mountID: UUID, path: String, force: Bool = false) {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return }
        cloudPath = path
        cloudError = nil
        cloudLoadToken += 1
        let token = cloudLoadToken
        similarScope = nil
        cloudModel.healthReport = nil

        let cacheKey = "\(mountID.uuidString)|\(path)"
        if !force, let cached = cloudDirectoryCache[cacheKey] {
            cloudFolders = cached.folders
            cloudPhotos = hydrateCloudCache(photos: cached.photos, mountID: mountID)
            cloudDirectoryCache[cacheKey] = (cached.folders, cloudPhotos)
            cloudLoading = false
            restoreCloudDerivedReports(mountID: mountID, path: path)
            scanCloudMetadataIfNeeded()
            return
        }

        cloudLoading = true
        cloudBusyText = nil

        // 目录页由只读仓库接管：首屏先铺上次快照，再拉最新目录并回写快照。
        let repository = sourceHub.repository(for: .cloud(mountID))
        let query = ContentQuery(containerID: path,
                                 sort: ContentSort(key: .latest),
                                 limit: Self.cloudDirectoryPageLimit)
        if let snapshot = repository?.cachedPage(query), !snapshot.isEmpty {
            applyCloudDirectoryPage(snapshot, mount: mount)
        } else {
            cloudFolders = []
            cloudPhotos = []
        }

        Task {
            guard let repository else {
                self.cloudLoading = false
                self.cloudError = "网盘挂载已不存在"
                return
            }
            do {
                let page = try await repository.page(query)
                guard token == self.cloudLoadToken else { return }

                self.applyCloudDirectoryPage(page, mount: mount)
                self.cloudDirectoryCache[cacheKey] = (self.cloudFolders, self.cloudPhotos)
                self.cloudLoading = false
                self.cloudError = nil
                self.cloudModel.needsCloudReauth = false
                self.restoreCloudDerivedReports(mountID: mount.id, path: path)
                self.scanCloudMetadataIfNeeded()

                if mount.kind == .webdav || mount.kind == .smb,
                   let index = self.cloudMounts.firstIndex(where: { $0.id == mountID }),
                   self.cloudMounts[index].lastPath != path {
                    self.cloudMounts[index].lastPath = path
                    self.saveCloudMounts()
                }
            } catch {
                guard token == self.cloudLoadToken else { return }
                self.cloudLoading = false
                self.cloudError = error.localizedDescription
                self.invalidateCloudPasswordIfNeeded(error, mountID: mount.id)
                if let sourceError = error as? SourceError, sourceError.kind == .unauthorized {
                    self.cloudModel.needsCloudReauth = true
                }
                self.showToast(error.localizedDescription)
            }
        }
    }

    /// 单次目录请求的上限：目录页一次性展示全部条目，分页交给首屏快照裁剪。
    static let cloudDirectoryPageLimit = 100_000

    /// 仓库返回的一页目录 → 现有网盘网格模型（文件夹 + 云照片）。
    func applyCloudDirectoryPage(_ page: ContentPage, mount: CloudMount) {
        let folders = page.containers
            .map { Self.cloudEntry(from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var photos = page.items
            .map { Self.cloudEntry(from: $0) }
            .filter(\.isMedia)
            .map { Self.makeCloudPhoto(mount: mount,
                                       entry: $0,
                                       favorites: cloudFavorites,
                                       keywords: cloudKeywords,
                                       marks: cloudMarks,
                                       viewedAt: cloudModel.viewedAt) }
        photos = hydrateCloudCache(photos: photos, mountID: mount.id)
        photos.sort { $0.capturedAt > $1.capturedAt }
        cloudFolders = folders
        cloudPhotos = photos
    }

    /// 文件夹容器还原成 CloudEntry：路径即容器 ID，日期从展示文案还原。
    static func cloudEntry(from container: ContentContainer) -> CloudEntry {
        CloudEntry(path: container.id,
                   name: container.title,
                   isDirectory: true,
                   size: 0,
                   modifiedAt: container.subtitle.flatMap(cloudDate(from:)),
                   contentType: nil)
    }

    /// 文件卡片还原成 CloudEntry：尺寸 / 时长 / 远端 ID 都在卡片事实层里。
    static func cloudEntry(from card: ContentCard) -> CloudEntry {
        let asset = card.asset
        return CloudEntry(path: card.ref.itemID,
                          name: card.title,
                          isDirectory: false,
                          size: asset?.byteCount ?? 0,
                          modifiedAt: asset?.updatedAt,
                          contentType: nil,
                          thumbnailURL: card.artworkURL,
                          remoteID: asset?.remoteID,
                          pixelWidth: asset?.pixelWidth,
                          pixelHeight: asset?.pixelHeight,
                          duration: asset?.duration,
                          isRestricted: asset?.isRestricted ?? false,
                          codecName: asset?.videoCodec)
    }

    static func cloudDate(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)
    }

    /// 递归扫描 SMB 共享，把所有媒体汇总成一个列表（不受当前文件夹限制）。
    func loadCloudTree(mountID: UUID, rootPath: String, force: Bool = false) {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return }
        cloudPath = rootPath
        cloudError = nil
        cloudLoadToken += 1
        let token = cloudLoadToken
        similarScope = nil
        cloudModel.healthReport = nil

        let cacheKey = "\(mountID.uuidString)|tree|\(rootPath)"
        if !force, let cached = cloudDirectoryCache[cacheKey] {
            cloudFolders = []
            cloudPhotos = hydrateCloudCache(photos: cached.photos, mountID: mountID)
            cloudDirectoryCache[cacheKey] = ([], cloudPhotos)
            cloudLoading = false
            cloudBusyText = nil
            restoreCloudDerivedReports(mountID: mountID, path: rootPath)
            scanCloudMetadataIfNeeded()
            return
        }

        cloudLoading = true
        cloudFolders = []
        cloudPhotos = []
        cloudBusyText = "正在扫描整个共享…"

        Task {
            do {
                let entries = try await CloudService.scanTree(mount: mount, path: rootPath).media
                guard token == self.cloudLoadToken else { return }
                var photos = entries.map { self.makeCloudPhoto(mount: mount, entry: $0) }
                photos = self.hydrateCloudCache(photos: photos, mountID: mount.id)
                photos.sort { $0.capturedAt > $1.capturedAt }
                self.cloudFolders = []
                self.cloudPhotos = photos
                self.cloudDirectoryCache[cacheKey] = ([], photos)
                self.cloudBusyText = nil
                self.cloudLoading = false
                self.cloudError = nil
                self.cloudModel.needsCloudReauth = false
                self.restoreCloudDerivedReports(mountID: mount.id, path: rootPath)
                self.scanCloudMetadataIfNeeded()
            } catch {
                guard token == self.cloudLoadToken else { return }
                self.cloudBusyText = nil
                self.cloudLoading = false
                self.cloudError = error.localizedDescription
                self.invalidateCloudPasswordIfNeeded(error, mountID: mount.id)
                if let oauth = error as? CloudOAuthError, oauth.requiresReauth {
                    self.cloudModel.needsCloudReauth = true
                }
                self.showToast(error.localizedDescription)
            }
        }
    }

    func makeCloudPhoto(mount: CloudMount, entry: CloudEntry) -> PhotoItem {
        Self.makeCloudPhoto(mount: mount,
                            entry: entry,
                            favorites: cloudFavorites,
                            keywords: cloudKeywords,
                            marks: cloudMarks,
                            viewedAt: cloudModel.viewedAt)
    }

    /// 纯函数版本：打开网盘时可在后台线程批量映射两万条索引记录，不阻塞主线程。
    nonisolated static func makeCloudPhoto(mount: CloudMount,
                                           entry: CloudEntry,
                                           favorites: Set<String>,
                                           keywords: [String: [String]],
                                           marks: [String: CloudMark],
                                           viewedAt: [UUID: Date]) -> PhotoItem {
        var item = PhotoItem(
            id: CloudIdentity.id(mountID: mount.id, path: entry.path),
            filename: entry.name,
            editedFilename: nil,
            originalName: entry.name,
            capturedAt: entry.modifiedAt ?? Date.distantPast,
            pixelWidth: entry.pixelWidth ?? 0,
            pixelHeight: entry.pixelHeight ?? 0,
            fileSize: entry.size,
            kind: entry.isVideo ? .video : .photo
        )
        item.source = .cloud
        item.cloudMountID = mount.id
        item.cloudPath = entry.path
        item.cloudRemoteID = entry.remoteID
        item.cloudThumbnailURL = entry.thumbnailURL
        item.cloudRestricted = entry.isRestricted ? true : nil
        item.videoCodec = entry.codecName
        item.duration = entry.duration
        // 「最近保存」按网盘文件的修改时间判断；EXIF 之后会改写拍摄时间，这里保留一份落盘时间。
        item.addedAt = entry.modifiedAt ?? Date.distantPast
        let keywordKey = cloudFavoriteKey(mountID: mount.id, path: entry.path)
        item.isFavorite = favorites.contains(keywordKey)
        if let tags = keywords[keywordKey], !tags.isEmpty {
            item.keywords = tags
        }
        if let mark = marks[keywordKey] {
            item.rating = mark.rating
            item.flag = mark.flag
            item.colorLabel = mark.colorLabel
        }
        item.viewedAt = viewedAt[item.id]
        return item
    }
}
