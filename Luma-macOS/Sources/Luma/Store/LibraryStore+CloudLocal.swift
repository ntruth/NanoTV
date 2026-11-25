import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore


/// 云照片的本地收藏、关键词、评分与云端写操作（都不写回网盘元数据）。

extension LibraryStore {
    // MARK: - 云照片的本地收藏（不写回网盘）

    nonisolated static func cloudFavoriteKey(mountID: UUID, path: String) -> String {
        "\(mountID.uuidString)|\(path)"
    }

    func loadCloudFavorites() {
        guard let json = metadataStore?.setting(Self.cloudFavoritesSettingKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            cloudFavorites = []
            return
        }
        cloudFavorites = Set(list)
    }

    /// 收藏 / 取消收藏云照片：仅更新本地记录与当前列表，不修改 NAS 或网盘上的文件。
    func setCloudFavorite(_ favorite: Bool, for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var list = cloudPhotos
        var changed = false
        for index in list.indices where ids.contains(list[index].id) {
            guard let mountID = list[index].cloudMountID,
                  let path = list[index].cloudPath else { continue }
            let key = Self.cloudFavoriteKey(mountID: mountID, path: path)
            if favorite {
                if cloudFavorites.insert(key).inserted { changed = true }
            } else if cloudFavorites.remove(key) != nil {
                changed = true
            }
            list[index].isFavorite = favorite
        }
        guard changed else { return }
        cloudPhotos = list
        for photo in list where ids.contains(photo.id) {
            updateCachedCloudPhoto(photo)
        }
        persistCloudFavorites()
        cloudVisibleCacheKey = nil
        showToast(favorite ? "已收藏（仅本机记录）" : "已取消收藏")
    }

    func persistCloudFavorites() {
        guard let data = try? JSONEncoder().encode(Array(cloudFavorites)),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.cloudFavoritesSettingKey, json)
    }

    /// 旧版网盘收藏存在全局 UserDefaults，仅用于一次性迁入当前图库。
    static let cloudFavoritesDefaultsKey = "cloud.favorites.v1"
    /// 当前图库自己的网盘收藏（写在该图库的 SQLite settings 表）。
    static let cloudFavoritesSettingKey = "cloud_favorites"

    // MARK: - 云照片的本地关键词（不写回网盘）

    func loadCloudKeywords() {
        guard let json = metadataStore?.setting(Self.cloudKeywordsSettingKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            cloudKeywords = [:]
            return
        }
        cloudKeywords = map
    }

    func persistCloudKeywords() {
        guard let data = try? JSONEncoder().encode(cloudKeywords),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.cloudKeywordsSettingKey, json)
    }

    /// 给一批云照片增删关键词：只更新本地记录与当前列表，不修改 NAS 或网盘上的文件。
    func updateCloudKeywords(_ ids: Set<UUID>,
                             mutate: (inout [String]) -> Bool) {
        guard !ids.isEmpty else { return }
        var changed = false
        var list = cloudPhotos
        for index in list.indices where ids.contains(list[index].id) {
            guard let mountID = list[index].cloudMountID,
                  let path = list[index].cloudPath else { continue }
            let key = Self.cloudFavoriteKey(mountID: mountID, path: path)
            var tags = cloudKeywords[key] ?? []
            guard mutate(&tags) else { continue }
            changed = true
            if tags.isEmpty {
                cloudKeywords.removeValue(forKey: key)
                list[index].keywords = nil
            } else {
                cloudKeywords[key] = tags
                list[index].keywords = tags
            }
        }
        guard changed else { return }
        cloudPhotos = list
        for photo in list where ids.contains(photo.id) {
            updateCachedCloudPhoto(photo)
        }
        persistCloudKeywords()
        cloudScopeCountsCacheKey = nil
        cloudVisibleCacheKey = nil
        cloudModel.metadataRevision += 1
    }

    /// 当前图库自己的网盘关键词（写在该图库的 SQLite settings 表）。
    static let cloudKeywordsSettingKey = "cloud_keywords"

    // MARK: - 云照片的本地评分 / 旗标 / 色标（不写回网盘）

    func loadCloudMarks() {
        guard let json = metadataStore?.setting(Self.cloudMarksSettingKey),
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: CloudMark].self, from: data) else {
            cloudMarks = [:]
            return
        }
        cloudMarks = map
    }

    func persistCloudMarks() {
        guard let data = try? JSONEncoder().encode(cloudMarks),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore?.setSetting(Self.cloudMarksSettingKey, json)
    }

    /// 给一批云照片改评分 / 旗标 / 色标：只更新本地记录与当前列表，不修改网盘上的文件。
    func updateCloudMarks(_ ids: Set<UUID>, mutate: (inout CloudMark) -> Bool) {
        guard !ids.isEmpty else { return }
        var changed = false
        var list = cloudPhotos
        for index in list.indices where ids.contains(list[index].id) {
            guard let mountID = list[index].cloudMountID,
                  let path = list[index].cloudPath else { continue }
            let key = Self.cloudFavoriteKey(mountID: mountID, path: path)
            var mark = cloudMarks[key] ?? CloudMark()
            guard mutate(&mark) else { continue }
            changed = true
            if mark.isEmpty {
                cloudMarks.removeValue(forKey: key)
            } else {
                cloudMarks[key] = mark
            }
            list[index].rating = mark.rating
            list[index].flag = mark.flag
            list[index].colorLabel = mark.colorLabel
        }
        guard changed else { return }
        cloudPhotos = list
        for photo in list where ids.contains(photo.id) {
            updateCachedCloudPhoto(photo)
        }
        persistCloudMarks()
        cloudScopeCountsCacheKey = nil
        cloudVisibleCacheKey = nil
        cloudModel.metadataRevision += 1
    }

    /// 当前图库自己的网盘评分 / 旗标 / 色标（写在该图库的 SQLite settings 表）。
    static let cloudMarksSettingKey = "cloud_marks"

    func applyCloudPixelSize(photoID: UUID, size: CGSize) {
        guard let index = cloudPhotos.firstIndex(where: { $0.id == photoID }) else { return }
        let width = Int(size.width)
        let height = Int(size.height)
        guard cloudPhotos[index].pixelWidth != width || cloudPhotos[index].pixelHeight != height else { return }
        var photo = cloudPhotos[index]
        photo.pixelWidth = width
        photo.pixelHeight = height
        enqueueCloudPhotoUpdate(photo)
    }

    /// 缩略图尺寸 / EXIF 等"非结构性"更新先入队，0.4 秒内合并成一次列表写入。
    /// 直接改 `cloudPhotos` 会触发 @Published，让整页网格、月份分桶与范围计数每张图都重算。
    func enqueueCloudPhotoUpdate(_ photo: PhotoItem) {
        cloudModel.pendingPhotoUpdates[photo.id] = photo
        updateCachedCloudPhoto(photo)
        cloudModel.metadataDirty = true
        // 批量 EXIF 扫描由扫描循环自己按批刷新，避免每张照片都排一次 0.4 秒任务。
        if !cloudModel.isScanningMetadata {
            markCloudMetadataChanged()
        }
    }

    /// 标记派生缓存需要失效，并安排一次合并刷新。
    func markCloudMetadataChanged() {
        cloudModel.metadataDirty = true
        guard cloudModel.metadataFlushTask == nil else { return }
        cloudModel.metadataFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            self.cloudModel.metadataFlushTask = nil
            self.flushCloudMetadata()
        }
    }

    /// 把排队中的元数据更新一次性写回列表：只触发一次发布与一次缓存失效。
    func flushCloudMetadata() {
        let pending = cloudModel.pendingPhotoUpdates
        cloudModel.pendingPhotoUpdates.removeAll(keepingCapacity: true)
        if !pending.isEmpty {
            var list = cloudPhotos
            var indexByID: [UUID: Int] = [:]
            indexByID.reserveCapacity(list.count)
            for (offset, photo) in list.enumerated() { indexByID[photo.id] = offset }
            var changed = false
            for (id, photo) in pending {
                guard let offset = indexByID[id] else { continue }
                list[offset] = photo
                changed = true
            }
            if changed { cloudPhotos = list }
        }
        guard cloudModel.metadataDirty else { return }
        cloudModel.metadataDirty = false
        cloudModel.metadataRevision += 1
        cloudScopeCountsCacheKey = nil
        cloudVisibleCacheKey = nil
        cloudFolderTreeCacheKey = nil
    }

    /// 预取云缩略图：只处理尚未命中内存 / 磁盘缓存的头部若干张。
    /// 单任务顺序执行，给屏幕上正在请求的格子留出网络与并发额度。
    /// 视频（尤其 WebDAV / SMB 需要 ffmpeg 抽帧）只少量预取，避免扫描结束后一次性拖垮 CPU。
    /// 返回的任务可由视图的 `.task` 取消（离开网盘 / 切换目录时停止）。
    @discardableResult
    func prefetchCloudThumbnails(for photos: [PhotoItem], limit: Int = 60) -> Task<Void, Never>? {
        cloudModel.thumbnailPrefetchTask?.cancel()
        cloudModel.thumbnailPrefetchTask = nil
        guard !photos.isEmpty, limit > 0 else { return nil }
        var targets: [PhotoItem] = []
        targets.reserveCapacity(limit)
        var videoBudget = 6
        for photo in photos.prefix(limit) {
            guard photo.isCloud else { continue }
            if photo.isVideo {
                guard videoBudget > 0 else { continue }
                // 需要 ffmpeg 抽帧的视频不预取：等滚动到可见时再按需生成。
                if let mount = cloudMount(for: photo.cloudMountID),
                   mount.kind == .webdav || mount.kind == .smb {
                    continue
                }
                videoBudget -= 1
            }
            if ImageLoader.cachedCloudThumbnail(for: photo) != nil { continue }
            if let mountID = photo.cloudMountID, let path = photo.cloudPath,
               ThumbnailFileIndex.shared.exists(path: CloudPaths.thumbnailURL(mountID: mountID,
                                                                             path: path).path) {
                continue
            }
            targets.append(photo)
        }
        guard !targets.isEmpty else { return nil }
        let task = Task { [weak self] in
            for photo in targets {
                if Task.isCancelled { return }
                _ = await self?.cloudThumbnail(for: photo)
                await Task.yield()
            }
        }
        cloudModel.thumbnailPrefetchTask = task
        return task
    }

    func applyCloudDuration(photoID: UUID, duration: Double) {
        guard let index = cloudPhotos.firstIndex(where: { $0.id == photoID }) else { return }
        guard cloudPhotos[index].duration != duration else { return }
        cloudPhotos[index].duration = duration
        updateCachedCloudPhoto(cloudPhotos[index])
    }

    func updateCachedCloudPhoto(_ photo: PhotoItem) {
        for key in cloudDirectoryCache.keys {
            guard var entry = cloudDirectoryCache[key],
                  let index = entry.photos.firstIndex(where: { $0.id == photo.id }) else { continue }
            entry.photos[index] = photo
            cloudDirectoryCache[key] = entry
        }
    }

    /// 云缩略图快速层：只读内存与磁盘，绝不发起网络请求。
    /// 目标图生成时已经顺手写了一份 192px 小图，滚动到这里时可以立即出图。
    func cloudQuickThumbnail(for photo: PhotoItem, maxPixel: CGFloat) async -> NSImage? {
        if let cached = ImageLoader.cachedCloudThumbnail(for: photo) { return cached }
        if let cached = ImageLoader.cachedGridImage(for: photo, maxPixel: maxPixel) { return cached }
        guard let mountID = photo.cloudMountID, let path = photo.cloudPath else { return nil }
        let url = CloudPaths.quickThumbnailURL(mountID: mountID, path: path)
        guard ThumbnailFileIndex.shared.exists(path: url.path) else { return nil }
        let image = await Task.detached(priority: .utility) {
            ImageLoader.decodeThumbnailFile(at: url, maxPixel: maxPixel)
        }.value
        if let image {
            ImageLoader.storeGridThumbnail(image, for: photo, maxPixel: maxPixel)
        }
        return image
    }

    /// 按需加载：优先使用服务端缩略图；WebDAV 走 EXIF 区间探测，避免整目录原图下行。
    func cloudThumbnail(for photo: PhotoItem) async -> NSImage? {
        if let cached = ImageLoader.cachedCloudThumbnail(for: photo) {
            return cached
        }
        if let remote = photo.cloudThumbnailURL, !remote.isEmpty {
            // 夸克 / 115 的缩略图地址可能在 CDN 后面，仍带上 Cookie / Referer 更稳妥。
            var headers: [String: String] = [:]
            if let mount = cloudMount(for: photo.cloudMountID) {
                if mount.kind == .quark {
                    headers = QuarkDrive.headers(cookie: cloudPassword(for: mount.id))
                } else if mount.kind == .pan115 {
                    headers = Pan115Drive.thumbnailHeaders(cookie: cloudPassword(for: mount.id))
                }
            }
            if let image = await CloudImageFetcher.thumbnail(for: photo,
                                                             urlString: remote,
                                                             headers: headers) {
                ImageLoader.cacheCloudThumbnail(image, for: photo)
                return image
            }
        }
        guard let mount = cloudMount(for: photo.cloudMountID) else { return nil }
        // 阿里 / 百度 / 夸克没有服务端缩略图：视频用 ffmpeg 读直链抽一帧，避免网格一直空白。
        if mount.kind != .webdav, mount.kind != .smb {
            guard photo.isVideo,
                  let stream = try? await cloudStreamOrThrow(for: photo) else { return nil }
            let fallback = await CloudThumbnailLoader.shared.remotePoster(
                for: photo, stream: stream, trustSelfSigned: mount.trustSelfSigned)
            if let size = fallback.size, size.width > 0, size.height > 0 {
                applyCloudPixelSize(photoID: photo.id, size: size)
            }
            if let duration = fallback.duration, duration > 0 {
                applyCloudDuration(photoID: photo.id, duration: duration)
            }
            guard let image = fallback.image else { return nil }
            ImageLoader.cacheCloudThumbnail(image, for: photo)
            return image
        }
        let result = await CloudThumbnailLoader.shared.thumbnail(for: photo,
                                                                 mount: mount,
                                                                 password: cloudPassword(for: mount.id))
        if let size = result.size, size.width > 0, size.height > 0 {
            applyCloudPixelSize(photoID: photo.id, size: size)
        }
        if let duration = result.duration, duration > 0 {
            applyCloudDuration(photoID: photo.id, duration: duration)
        }
        guard let image = result.image else { return nil }
        ImageLoader.cacheCloudThumbnail(image, for: photo)
        return image
    }

    /// 云端动图：下载完整文件后保留全部帧播放。
    /// 只对动图调用，并限制体积，避免为了播放误拉超大文件。
    func cloudAnimatedImage(for photo: PhotoItem) async -> NSImage? {
        guard photo.playsAnimation, photo.isCloud else { return nil }
        guard photo.fileSize > 0, photo.fileSize <= 80 * 1024 * 1024 else { return nil }
        guard let mount = cloudMount(for: photo.cloudMountID),
              let path = photo.cloudPath else { return nil }

        if mount.kind == .smb, let client = SMBClient(mount: mount, password: cloudPassword(for: mount.id)) {
            _ = try? await client.ensureMounted()
            guard let url = client.fileURL(path: path) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return NSImage(data: data)
            }.value
        }

        if mount.kind == .webdav, let client = CloudService.webdavClient(mount) {
            guard let data = try? await client.data(path: path) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                NSImage(data: data)
            }.value
        }

        guard let resource = await cloudStream(for: photo) else { return nil }
        var request = URLRequest(url: resource.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 60)
        for (key, value) in resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            NSImage(data: data)
        }.value
    }

    func cloudDisplayImage(for photo: PhotoItem) async -> NSImage? {
        guard let mount = cloudMount(for: photo.cloudMountID) else {
            Diagnostics.record("云端原图缺少挂载 \(photo.originalName) "
                               + "mount=\(photo.cloudMountID?.uuidString ?? "-")")
            return nil
        }
        if let cached = ImageLoader.cachedCloudFullImage(for: photo) {
            return cached
        }
        if mount.kind == .smb, let client = SMBClient(mount: mount,
                                                       password: cloudPassword(for: mount.id)) {
            _ = try? await client.ensureMounted()
            guard let url = client.fileURL(path: photo.cloudPath ?? "") else { return nil }
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoader.fullImage(from: url, maxPixel: 6000)
            }.value
            if let loaded { ImageLoader.cacheCloudFullImage(loaded, for: photo) }
            return loaded
        }
        if mount.kind == .webdav, let client = CloudService.webdavClient(mount) {
            return await ImageLoader.cloudFullImage(for: photo, client: client)
        }
        guard let resource = await cloudStream(for: photo),
              let image = await CloudImageFetcher.fullImage(photo: photo, resource: resource) else {
            Diagnostics.record("云端原图获取失败 [\(mount.kind.rawValue)] \(photo.cloudPath ?? "-")")
            return nil
        }
        ImageLoader.cacheCloudFullImage(image, for: photo)
        return image
    }

    func cloudStream(for photo: PhotoItem) async -> CloudStreamResource? {
        try? await cloudStreamOrThrow(for: photo)
    }

    /// 与 `cloudStream` 相同，但保留失败原因：播放器需要把「授权失效 / 缺少文件 ID / 直链获取失败」
    /// 之类的具体错误展示出来，而不是统一显示「无法定位视频文件」。
    func cloudStreamOrThrow(for photo: PhotoItem) async throws -> CloudStreamResource {
        guard let mount = cloudMount(for: photo.cloudMountID) else {
            throw CloudOAuthError.api("找不到对应的网盘连接，请在侧边栏重新连接")
        }
        do {
            return try await CloudService.stream(mount: mount, photo: photo)
        } catch {
            Diagnostics.record("云端直链获取失败 [\(mount.kind.rawValue)] \(photo.cloudPath ?? "-")：\(error.localizedDescription)")
            throw error
        }
    }

    func downloadCloudItem(_ photo: PhotoItem, to url: URL) async throws {
        guard let mount = cloudMount(for: photo.cloudMountID) else {
            throw CloudOAuthError.api("挂载不存在")
        }
        if mount.kind == .smb,
           let client = SMBClient(mount: mount, password: cloudPassword(for: mount.id)),
           let path = photo.cloudPath {
            _ = try await client.ensureMounted()
            guard let source = client.fileURL(path: path) else {
                throw CloudOAuthError.api("SMB 挂载点不可用，请检查共享是否已连接")
            }
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.removeItem(at: url)
            try fm.copyItem(at: source, to: url)
            return
        }
        if mount.kind == .webdav,
           let client = CloudService.webdavClient(mount),
           let path = photo.cloudPath {
            try await client.download(path: path, to: url)
            return
        }
        let resource = try await CloudService.stream(mount: mount, photo: photo)
        var request = URLRequest(url: resource.url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 120)
        for (key, value) in resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudOAuthError.api("下载失败")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try fm.moveItem(at: temp, to: url)
    }

    // MARK: - 云端写操作

    /// 授权完成后注册一个官方网盘挂载点。
    @discardableResult
    func registerOAuthMount(kind: CloudKind, name: String,
                            driveID: String?, token: CloudToken,
                            scopes: [CloudScopeRoot]? = nil,
                            excludes: [CloudScopeRoot]? = nil) -> String? {
        guard kind.usesOAuth else { return "不支持的接入方式" }
        if let existing = cloudMounts.first(where: { $0.kind == kind && $0.remoteDriveID == driveID }) {
            CloudOAuthStore.saveToken(token, mountID: existing.id)
            cloudDirectoryCache = cloudDirectoryCache.filter { !$0.key.hasPrefix(existing.id.uuidString) }
            updateCloudMountAccess(existing.id, scopes: scopes, excludes: excludes)
            navigate(to: .cloudMount(existing.id))
            showToast("已更新「\(existing.name)」的授权")
            return nil
        }
        let mount = CloudMount(kind: kind, name: name, remoteDriveID: driveID,
                               scopeRoots: scopes ?? [],
                               excludedRoots: excludes ?? [])
        CloudOAuthStore.saveToken(token, mountID: mount.id)
        cloudMounts.append(mount)
        saveCloudMounts()
        showToast("已连接「\(name)」")
        navigate(to: .cloudMount(mount.id))
        return nil
    }

    func cloudClient(for mountID: UUID) -> WebDAVClient? {
        guard let mount = cloudMounts.first(where: { $0.id == mountID }) else { return nil }
        return WebDAVClient(baseURLString: mount.baseURL,
                            username: mount.username,
                            password: cloudPassword(for: mount.id),
                            allowsSelfSignedCertificate: mount.trustSelfSigned)
    }

    func requestCloudRename(_ photoID: UUID) {
        guard isCurrentCloudWritable else { return }
        guard let photo = anyPhoto(id: photoID), photo.isCloud else { return }
        cloudNameRequest = CloudNameRequest(mode: .rename(photoID: photoID, current: photo.originalName))
    }

    func requestCloudNewFolder() {
        guard isCurrentCloudWritable else { return }
        cloudNameRequest = CloudNameRequest(mode: .newFolder)
    }

    func commitCloudName(_ request: CloudNameRequest, text: String) {
        guard isCurrentCloudWritable else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.replacingOccurrences(of: "/", with: "_")
        guard !name.isEmpty else { return }
        guard case .cloudMount(let mountID) = sidebarItem,
              let client = cloudClient(for: mountID) else { return }
        cloudNameRequest = nil

        switch request.mode {
        case .newFolder:
            let target = cloudPath.isEmpty ? name : cloudPath + "/" + name
            Task {
                do {
                    try await client.createFolder(path: target)
                    showToast("已新建文件夹「\(name)」")
                    refreshCloudDirectory()
                } catch {
                    showToast("新建失败：\(error.localizedDescription)")
                }
            }
        case .rename(let photoID, _):
            guard let photo = anyPhoto(id: photoID), let oldPath = photo.cloudPath else { return }
            var components = oldPath.split(separator: "/").map(String.init)
            components.removeLast()
            let oldExtension = (photo.originalName as NSString).pathExtension
            let typedExtension = (name as NSString).pathExtension
            let finalName: String
            if !oldExtension.isEmpty,
               typedExtension.lowercased() != oldExtension.lowercased() {
                finalName = name + "." + oldExtension
            } else {
                finalName = name
            }
            let newPath = (components + [finalName]).joined(separator: "/")
            guard newPath != oldPath else { return }
            Task {
                do {
                    try await client.move(from: oldPath, to: newPath)
                    selection.removeAll()
                    if viewerID == photoID {
                        viewerID = nil
                    }
                    showToast("已重命名为「\(finalName)」")
                    refreshCloudDirectory()
                } catch {
                    showToast("重命名失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func confirmDeleteCloud(_ ids: Set<UUID>) {
        guard isCurrentCloudWritable else {
            if case .cloudMount(let id) = sidebarItem, cloudMount(for: id)?.kind == .smb {
                showToast("SMB 共享为只读，删除请到 NAS 上操作")
            } else {
                showToast("官方网盘接入当前为只读，删除请到网盘 App")
            }
            return
        }
        let items = ids.compactMap { anyPhoto(id: $0) }.filter { $0.isCloud }
        guard !items.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = items.count == 1
            ? "从云端删除「\(items[0].originalName)」？"
            : "从云端删除 \(items.count) 项？"
        alert.informativeText = "文件会直接从 WebDAV 服务器删除，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard case .cloudMount(let mountID) = sidebarItem,
              let client = cloudClient(for: mountID) else { return }
        Task {
            var failed = 0
            for item in items {
                guard let path = item.cloudPath else { continue }
                do {
                    try await client.delete(path: path)
                    // 删除成功后再清本地缩略图缓存（磁盘 + 内存），避免残留文件与残影。
                    try? FileManager.default.removeItem(
                        at: CloudPaths.thumbnailURL(mountID: item.cloudMountID ?? mountID, path: path))
                    ImageLoader.invalidate(photo: item)
                } catch {
                    failed += 1
                }
            }
            if let viewerID, ids.contains(viewerID) {
                self.viewerID = nil
            }
            selection.removeAll()
            refreshCloudDirectory()
            showToast(failed == 0
                      ? "已从云端删除 \(items.count) 项"
                      : "已删除 \(items.count - failed) 项，\(failed) 项失败")
        }
    }

    func presentCloudUploadPanel() {
        guard isCurrentCloudWritable else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        panel.prompt = "上传"
        panel.message = "选择要上传到当前云端目录的照片或视频"
        if panel.runModal() == .OK {
            uploadToCloud(panel.urls)
        }
    }

    func uploadToCloud(_ urls: [URL]) {
        guard isCurrentCloudWritable else { return }
        guard !urls.isEmpty, case .cloudMount(let mountID) = sidebarItem,
              let client = cloudClient(for: mountID) else { return }
        let basePath = cloudPath
        Task {
            var uploaded = 0
            var failed = 0
            for (index, url) in urls.enumerated() {
                cloudBusyText = "上传 \(index + 1)/\(urls.count)"
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let target = basePath.isEmpty
                    ? url.lastPathComponent
                    : basePath + "/" + url.lastPathComponent
                do {
                    try await client.upload(path: target, from: url)
                    uploaded += 1
                } catch {
                    failed += 1
                }
            }
            cloudBusyText = nil
            refreshCloudDirectory()
            showToast(failed == 0
                      ? "已上传 \(uploaded) 项"
                      : "已上传 \(uploaded) 项，\(failed) 项失败")
        }
    }
}
