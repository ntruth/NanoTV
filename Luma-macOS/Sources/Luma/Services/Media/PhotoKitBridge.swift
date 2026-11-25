import Foundation
import AVFoundation
import CoreLocation
import Photos

/// 系统「照片」图库的真实写入（PhotoKit）。
/// 由 Photos 自己更新原图与它自己的数据库，不直接改 `Photos.sqlite`。
/// 仅当当前图库就是官方「照片」图库时可用。
enum PhotoKitBridge {
    enum BridgeError: LocalizedError {
        case unauthorized
        case assetNotFound
        case editInputFailed
        case saveFailed(String)
        /// 源文件不可读 / 为空：写入前就停下，不把半截文件塞进图库。
        case sourceUnreadable(String)
        /// PhotoKit 返回成功但回读不到：如实报告，绝不假装写入成功。
        case verifyFailed(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "没有照片图库读写权限，请在「系统设置 › 隐私与安全性 › 照片」中允许拾光访问"
            case .assetNotFound:
                return "在系统「照片」图库中找不到这些项目"
            case .editInputFailed:
                return "无法读取照片原图，可能仍在 iCloud 中下载"
            case .saveFailed(let message):
                return "写回「照片」失败：\(message)"
            case .sourceUnreadable(let name):
                return "无法读取源文件：\(name) 可能已移动、加密或为空"
            case .verifyFailed(let message):
                return "写入校验未通过：\(message)"
            }
        }
    }

    /// 新建资产的结果：`localIdentifier` 用于回读校验，`id` 用于拾光侧的元数据映射。
    struct CreatedAsset {
        let localIdentifier: String
        let id: UUID
    }

    static let adjustmentFormatIdentifier = "com.baymax.luma.beauty"

    /// 还没有做过选择（首次使用）：此时申请权限才会弹出系统授权框。
    static var isAuthorizationUndetermined: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
    }

    /// 已经拿到相册读写权限。只读查询，绝不会弹系统授权框：
    /// 浏览网络资源 / 网络电视等与相册无关的页面只能用它做前置判断。
    static var hasReadWritePermission: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return true
        default: return false
        }
    }

    /// 申请 / 检查相册读写权限。
    static func ensureAuthorized() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
        default:
            return false
        }
    }

    /// 把一帧画面作为可撤销的调整写回系统照片（原图与 Photos 数据库由 Photos 自己更新）。
    static func applyEdit(assetID: UUID, jpegData: Data) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        let asset = try fetchAsset(assetID)
        let input = try await requestEditingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: adjustmentFormatIdentifier,
                                                 formatVersion: "1.0",
                                                 data: Data())
        do {
            try jpegData.write(to: output.renderedContentURL, options: .atomic)
        } catch {
            throw BridgeError.saveFailed(error.localizedDescription)
        }
        try await performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.contentEditingOutput = output
        }
    }

    // MARK: - 新增资产（导入）

    /// 把本地文件新增到系统「照片」图库。
    /// - 只做新增：不修改、不删除任何已有资产；调用方必须先用 `targetsSystemLibrary` 校验目标库。
    /// - 实况照片同时带 `.pairedVideo`，由 Photos 自己配对；失败时整条回滚（performChanges 原子）。
    static func createAsset(from url: URL,
                            isVideo: Bool,
                            creationDate: Date?,
                            location: CLLocation?,
                            pairedVideoURL: URL? = nil) async throws -> CreatedAsset {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard FileManager.default.isReadableFile(atPath: url.path), size > 0 else {
            throw BridgeError.sourceUnreadable(url.lastPathComponent)
        }
        var identifier: String?
        do {
            try await performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                options.shouldMoveFile = false
                request.addResource(with: isVideo ? .video : .photo,
                                    fileURL: url,
                                    options: options)
                if !isVideo, let pairedVideoURL {
                    let liveOptions = PHAssetResourceCreationOptions()
                    liveOptions.originalFilename = pairedVideoURL.lastPathComponent
                    liveOptions.shouldMoveFile = false
                    request.addResource(with: .pairedVideo,
                                        fileURL: pairedVideoURL,
                                        options: liveOptions)
                }
                if let creationDate { request.creationDate = creationDate }
                if let location { request.location = location }
                identifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw BridgeError.saveFailed(userMessage(for: error))
        }
        guard let identifier else {
            throw BridgeError.verifyFailed("未能取得新建资产的标识")
        }
        // 回读校验：正常权限下必须能查到；仅「受限访问」允许查不到（新项目未必进入授权选集）。
        if await waitForAsset(identifier: identifier) == false,
           PHPhotoLibrary.authorizationStatus(for: .readWrite) != .limited {
            throw BridgeError.verifyFailed("已提交写入，但未能在图库中回读校验")
        }
        let key = identifier.split(separator: "/").first.map(String.init) ?? ""
        return CreatedAsset(localIdentifier: identifier,
                            id: UUID(uuidString: key) ?? UUID())
    }

    /// 轮询回读：Photos 提交后偶尔要几十毫秒才出现在查询结果里。
    private static func waitForAsset(identifier: String) async -> Bool {
        for attempt in 0..<3 {
            if PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject != nil {
                return true
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return false
    }

    /// 去重前确认旧资产还在（用户可能已在「照片」里删掉它）。
    static func assetExists(localIdentifier: String) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject != nil
    }

    // MARK: - 相簿 / 文件夹（导入整理）

    /// 确保相簿存在：优先复用同名相簿，没有才新建。返回标识与是否新建。
    static func ensureAlbum(title: String) async throws -> (identifier: String, created: Bool) {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        if let existing = findAlbum(title: title) {
            return (existing.localIdentifier, false)
        }
        var identifier: String?
        try await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            identifier = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier else { throw BridgeError.saveFailed("未能取得新相簿标识") }
        return (identifier, true)
    }

    /// 确保文件夹链存在：逐层复用 / 新建，返回最末级文件夹标识与新建数量。
    static func ensureFolderPath(_ titles: [String]) async throws -> (identifier: String?, created: Int) {
        guard !titles.isEmpty else { return (nil, 0) }
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        var parent: PHCollectionList?
        var lastIdentifier: String?
        var created = 0
        for title in titles {
            if let existing = findFolder(title: title) {
                parent = existing
                lastIdentifier = existing.localIdentifier
                continue
            }
            var identifier: String?
            try await performChanges {
                let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
                identifier = request.placeholderForCreatedCollectionList.localIdentifier
            }
            guard let identifier, let folder = fetchFolder(identifier: identifier) else {
                throw BridgeError.saveFailed("未能创建文件夹「\(title)」")
            }
            // 新建的子文件夹要挂到上一层，否则会全部摊在顶层。
            if let parent {
                try await performChanges {
                    PHCollectionListChangeRequest(for: parent)?.addChildCollections([folder] as NSArray)
                }
            }
            parent = folder
            lastIdentifier = identifier
            created += 1
        }
        return (lastIdentifier, created)
    }

    /// 把刚写入的资产加入相簿。
    static func addAsset(localIdentifier: String, toAlbum albumIdentifier: String) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              let album = fetchAlbum(albumIdentifier) else {
            throw BridgeError.assetNotFound
        }
        try await performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
        }
    }

    /// 把新建的相簿放进文件夹；只对这次新建的相簿调用，避免移动用户已有的相簿。
    static func addAlbum(_ albumIdentifier: String, toFolder folderIdentifier: String) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let album = fetchAlbum(albumIdentifier),
              let folder = fetchFolder(identifier: folderIdentifier) else {
            throw BridgeError.assetNotFound
        }
        try await performChanges {
            PHCollectionListChangeRequest(for: folder)?.addChildCollections([album] as NSArray)
        }
    }

    /// 把一组相簿移进目标文件夹（相簿只能有一个父级，add 即移动）。
    /// 用于「把这个文件夹及子目录里的相簿提取到当前目录」。
    static func extractAlbums(_ albumIdentifiers: [String],
                              intoFolder folderIdentifier: String) async throws -> Int {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let folder = fetchFolder(identifier: folderIdentifier) else {
            throw BridgeError.assetNotFound
        }
        let fetched = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIdentifiers,
                                                              options: nil)
        var albums: [PHAssetCollection] = []
        fetched.enumerateObjects { album, _, _ in albums.append(album) }
        guard !albums.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHCollectionListChangeRequest(for: folder)?.addChildCollections(albums as NSArray)
        }
        return albums.count
    }

    /// 删除空文件夹（只删相簿容器，不碰任何照片）。
    static func deleteFolders(identifiers: [String]) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        var folders: [PHCollectionList] = []
        for identifier in identifiers {
            if let folder = fetchFolder(identifier: identifier) {
                folders.append(folder)
            }
        }
        guard !folders.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHCollectionListChangeRequest.deleteCollectionLists(folders as NSArray)
        }
    }

    private static func findAlbum(title: String) -> PHAssetCollection? {
        let albums = PHAssetCollection.fetchAssetCollections(with: .album,
                                                             subtype: .albumRegular,
                                                             options: nil)
        var match: PHAssetCollection?
        albums.enumerateObjects { album, _, stop in
            if album.localizedTitle == title {
                match = album
                stop.pointee = true
            }
        }
        return match
    }

    /// 找同名文件夹。PhotoKit 在 macOS 上没有公开「按父文件夹列出子项」的查询，
    /// 这里按全局标题匹配复用；同一导入批次内会先查本地缓存，避免同名目录互相串。
    private static func findFolder(title: String) -> PHCollectionList? {
        let folders = PHCollectionList.fetchCollectionLists(with: .folder,
                                                            subtype: .regularFolder,
                                                            options: nil)
        var match: PHCollectionList?
        folders.enumerateObjects { folder, _, stop in
            if folder.localizedTitle == title {
                match = folder
                stop.pointee = true
            }
        }
        return match
    }

    private static func fetchFolder(identifier: String) -> PHCollectionList? {
        if let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [identifier],
                                                              options: nil).firstObject {
            return folder
        }
        let all = PHCollectionList.fetchCollectionLists(with: .folder,
                                                        subtype: .regularFolder,
                                                        options: nil)
        var match: PHCollectionList?
        all.enumerateObjects { folder, _, stop in
            if folder.localIdentifier.hasPrefix(identifier) {
                match = folder
                stop.pointee = true
            }
        }
        return match
    }

    /// PhotoKit / 文件系统的错误 → 用户看得懂的中文原因。
    static func userMessage(for error: Error) -> String {
        if let bridge = error as? BridgeError, let text = bridge.errorDescription {
            return text
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "磁盘空间不足，无法写入系统图库"
        }
        let text = ns.localizedDescription
        let lower = text.lowercased()
        if lower.contains("network") || lower.contains("icloud") {
            return "系统「照片」需要访问 iCloud：\(text)"
        }
        if lower.contains("space") || lower.contains("disk full") {
            return "磁盘空间不足，无法写入系统图库"
        }
        if lower.contains("format") || lower.contains("unsupported") {
            return "系统「照片」不支持这个文件格式：\(text)"
        }
        return "写入系统「照片」图库失败：\(text)"
    }

    /// 移入「照片」的最近删除（30 天内可在「照片」中恢复）。
    static func delete(assetIDs: [UUID]) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        let assets = assetIDs.compactMap { try? fetchAsset($0) }
        guard !assets.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    // MARK: - 校验目标库

    /// 当前打开的系统图库是否就是 PhotoKit 指向的系统「照片」图库。
    /// 用几张真实照片的 localIdentifier 能否取到来判断；取不到说明不是同一个库，禁止写回。
    static func targetsSystemLibrary(sampleAssetIDs: [UUID]) -> Bool {
        sampleAssetIDs.prefix(3).contains { (try? fetchAsset($0)) != nil }
    }

    /// 是否有照片读写权限（同步查询，供 UI 判断显示）。
    static var hasReadWriteAuthorization: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return true
        default: return false
        }
    }

    /// PhotoKit 当前能看到任何资产：没有资产时无法判断写目标，不能直接判成「不是当前库」。
    static var hasVisibleAssets: Bool {
        PHAsset.fetchAssets(with: nil).count > 0
    }

    /// PhotoKit 指向的系统图库是不是 `path` 这个 `.photoslibrary`。
    /// 取几张 PhotoKit 能看到的真实资产，反查该库 `Photos.sqlite` 里是否存在它们的 UUID；
    /// 只读判断，不修改任何一侧。
    static func libraryMatches(path: String) -> Bool {
        let options = PHFetchOptions()
        options.fetchLimit = 8
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)
        var uuids: [String] = []
        assets.enumerateObjects { asset, _, stop in
            let uuid = asset.localIdentifier.split(separator: "/").first.map(String.init) ?? ""
            if !uuid.isEmpty { uuids.append(uuid) }
            if uuids.count >= 8 { stop.pointee = true }
        }
        guard !uuids.isEmpty else { return false }
        let databasePath = URL(fileURLWithPath: path)
            .appendingPathComponent("database/Photos.sqlite").path
        guard let db = try? SQLiteDatabase(path: databasePath, readonly: true) else { return false }
        let list = uuids.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ",")
        // UUID 大小写不敏感：不同系统版本写库时可能不是全大写。
        let rows = try? db.query("""
            SELECT COUNT(*) AS matched FROM ZASSET
            WHERE ZUUID COLLATE NOCASE IN (\(list))
            """)
        return (rows?.first?["matched"]?.int ?? 0) > 0
    }

    // MARK: - 收藏 / 隐藏

    static func setFavorite(_ favorite: Bool, assetIDs: [UUID]) async throws {
        try await setFlag(assetIDs: assetIDs) { $0.isFavorite = favorite }
    }

    static func setHidden(_ hidden: Bool, assetIDs: [UUID]) async throws {
        try await setFlag(assetIDs: assetIDs) { $0.isHidden = hidden }
    }

    private static func setFlag(assetIDs: [UUID],
                                apply: @escaping (PHAssetChangeRequest) -> Void) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        let assets = assetIDs.compactMap { try? fetchAsset($0) }
        guard !assets.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            for asset in assets {
                apply(PHAssetChangeRequest(for: asset))
            }
        }
    }

    // MARK: - 元数据 / 文件夹

    /// 修改拍摄时间与位置（单事务；传 nil 表示该项不变）。
    static func updateMetadata(assetIDs: [UUID],
                               creationDate: Date?,
                               location: CLLocation?) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard creationDate != nil || location != nil else { return }
        let assets = assetIDs.compactMap { try? fetchAsset($0) }
        guard !assets.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            for asset in assets {
                let request = PHAssetChangeRequest(for: asset)
                if let creationDate { request.creationDate = creationDate }
                if let location { request.location = location }
            }
        }
    }

    /// 重命名文件夹。
    static func renameFolder(identifier: String, title: String) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let folder = fetchFolder(identifier: identifier) else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHCollectionListChangeRequest(for: folder)?.title = title
        }
    }

    /// 新建相簿并把一组照片加进去：创建与加入在同一个事务里完成。
    static func createAlbum(title: String, adding assetIDs: [UUID]) async throws -> String {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        let assets = assetIDs.compactMap { try? fetchAsset($0) }
        var identifier: String?
        try await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            if !assets.isEmpty {
                request.addAssets(assets as NSArray)
            }
            identifier = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier else { throw BridgeError.saveFailed("未能取得新相簿标识") }
        return identifier
    }

    /// 读取原图数据（编辑器用；iCloud 资源允许走网络）。
    static func originalImageData(assetID: UUID) async -> Data? {
        guard await ensureAuthorized(), let asset = try? fetchAsset(assetID) else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.version = .current
        return await withCheckedContinuation { continuation in
            var resumed = false
            let lock = NSLock()
            PHImageManager.default().requestImageDataAndOrientation(for: asset,
                                                                   options: options) { data, _, _, _ in
                lock.lock()
                if resumed {
                    lock.unlock()
                    return
                }
                resumed = true
                lock.unlock()
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - 相簿

    /// 新建用户相簿，返回它的 localIdentifier。
    static func createAlbum(title: String) async throws -> String {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        var identifier: String?
        try await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            identifier = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier else { throw BridgeError.saveFailed("未能取得新相簿标识") }
        return identifier
    }

    static func renameAlbum(albumID: String, title: String) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let album = fetchAlbum(albumID) else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHAssetCollectionChangeRequest(for: album)?.title = title
        }
    }

    /// 新建用户文件夹（相簿容器）；`inFolder` 非空时挂到该文件夹下。
    /// 只创建容器，不碰任何照片。
    static func createFolder(title: String, inFolder parentIdentifier: String?) async throws -> String {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        var identifier: String?
        try await performChanges {
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
            identifier = request.placeholderForCreatedCollectionList.localIdentifier
        }
        guard let identifier, let folder = fetchFolder(identifier: identifier) else {
            throw BridgeError.saveFailed("未能创建文件夹「\(title)」")
        }
        // 不挂到上一层的话，新文件夹会摊在顶层，和用户在侧边栏看到的位置对不上。
        if let parentIdentifier, let parent = fetchFolder(identifier: parentIdentifier) {
            try await performChanges {
                PHCollectionListChangeRequest(for: parent)?.addChildCollections([folder] as NSArray)
            }
        }
        return identifier
    }

    static func deleteAlbums(albumIDs: [String]) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        let albums = albumIDs.compactMap { fetchAlbum($0) }
        guard !albums.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections(albums as NSArray)
        }
    }

    static func addAssets(_ assetIDs: [UUID], toAlbum albumID: String) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let album = fetchAlbum(albumID) else { throw BridgeError.assetNotFound }
        let assets = assetIDs.compactMap { try? fetchAsset($0) }
        guard !assets.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
        }
    }

    static func removeAssets(_ assetIDs: [UUID], fromAlbum albumID: String) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let album = fetchAlbum(albumID) else { throw BridgeError.assetNotFound }
        let assets = assetIDs.compactMap { try? fetchAsset($0) }
        guard !assets.isEmpty else { throw BridgeError.assetNotFound }
        try await performChanges {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets as NSArray)
        }
    }

    /// 相簿内手动排序：把指定照片移到最前 / 最后（macOS 13+ 的 moveAssets）。
    static func moveAssets(_ assetIDs: [UUID], inAlbum albumID: String, toTop: Bool) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let album = fetchAlbum(albumID) else { throw BridgeError.assetNotFound }
        let moving = assetIDs.compactMap { try? fetchAsset($0) }
        guard !moving.isEmpty else { throw BridgeError.assetNotFound }
        let all = PHAsset.fetchAssets(in: album, options: nil)
        let movingIDs = Set(moving.map(\.localIdentifier))
        var indexes = IndexSet()
        all.enumerateObjects { asset, index, _ in
            if movingIDs.contains(asset.localIdentifier) { indexes.insert(index) }
        }
        guard !indexes.isEmpty else { throw BridgeError.assetNotFound }
        let destination = toTop ? 0 : max(0, all.count - indexes.count)
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album, assets: all) else { return }
            request.moveAssets(at: indexes, to: destination)
        }
    }

    /// 相簿内拖拽排序：把指定照片移到 `targetID` 之前 / 之后。
    /// 目标位置按「移除被拖拽项后的顺序」计算，与 `moveAssets(at:to:)` 的语义一致。
    static func moveAssets(_ assetIDs: [UUID],
                           inAlbum albumID: String,
                           before targetID: UUID,
                           after: Bool) async throws {
        guard await ensureAuthorized() else { throw BridgeError.unauthorized }
        guard let album = fetchAlbum(albumID) else { throw BridgeError.assetNotFound }
        let moving = assetIDs.compactMap { try? fetchAsset($0) }
        guard !moving.isEmpty else { throw BridgeError.assetNotFound }
        let all = PHAsset.fetchAssets(in: album, options: nil)
        let movingKeys = Set(moving.map(\.localIdentifier))
        let targetKey = targetID.uuidString

        var sourceIndexes = IndexSet()
        var targetPosition: Int?
        var remainingIndex = 0
        all.enumerateObjects { asset, index, _ in
            if movingKeys.contains(asset.localIdentifier) {
                sourceIndexes.insert(index)
                return
            }
            if targetPosition == nil, asset.localIdentifier.hasPrefix(targetKey) {
                targetPosition = remainingIndex
            }
            remainingIndex += 1
        }
        guard !sourceIndexes.isEmpty, let targetPosition else { throw BridgeError.assetNotFound }
        let insertAt = after ? targetPosition + 1 : targetPosition
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album, assets: all) else { return }
            request.moveAssets(at: sourceIndexes, to: insertAt)
        }
    }

    // MARK: - 媒体类型
    //
    // 长曝光 / 电影效果在 Photos.sqlite 里没有稳定字段，只能通过 PhotoKit 的智能相簿取 ID。

    /// 读取「长曝光」与「电影效果」智能相簿里的项目 ID；没有照片权限时返回 nil。
    /// 只做静默读取：授权只应由「打开系统图库」这类明确的相册动作触发。
    static func specialMediaTypeAssetIDs() async -> (longExposure: Set<UUID>, cinematic: Set<UUID>)? {
        guard hasReadWritePermission else { return nil }
        let longExposure = await smartAlbumAssetIDs(.smartAlbumLongExposures)
        let cinematic = await smartAlbumAssetIDs(.smartAlbumCinematic)
        return (longExposure ?? [], cinematic ?? [])
    }

    private static func smartAlbumAssetIDs(_ subtype: PHAssetCollectionSubtype) async -> Set<UUID>? {
        let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                                  subtype: subtype,
                                                                  options: nil)
        guard let album = collections.firstObject else { return [] }
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var ids = Set<UUID>()
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            let key = asset.localIdentifier.split(separator: "/").first.map(String.init) ?? ""
            if let id = UUID(uuidString: key) { ids.insert(id) }
        }
        return ids
    }

    // MARK: - 视频素材

    /// 从系统「照片」取回可播放的视频素材。
    /// 共享相簿与仅存 iCloud 的视频在本机没有原图文件，必须由 Photos 自己按需下载。
    /// 返回的 URL 只是本地缓存路径，流式素材可能为 nil。
    static func videoAsset(id: UUID) async -> (asset: AVAsset, url: URL?)? {
        guard await ensureAuthorized() else { return nil }
        // 共享相簿要逐本枚举才能找到项目，大图库上很慢：不能占用主线程。
        let source = await Task.detached(priority: .userInitiated) {
            videoPHAsset(id: id)
        }.value
        guard let source else { return nil }
        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            PHImageManager.default().requestAVAsset(forVideo: source, options: options) { asset, _, _ in
                continuation.resume(returning: asset)
            }
        }
        guard let avAsset else { return nil }
        return (avAsset, (avAsset as? AVURLAsset)?.url)
    }

    /// 先按 localIdentifier 找；共享相簿里的项目不在主图库的全局集合里，需要逐个共享相簿查。
    private static func videoPHAsset(id: UUID) -> PHAsset? {
        let key = id.uuidString
        for identifier in ["\(key)/L0/001", "\(key)/L0/000"] {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
                return asset
            }
        }
        let albums = PHAssetCollection.fetchAssetCollections(with: .album,
                                                             subtype: .albumCloudShared,
                                                             options: nil)
        var match: PHAsset?
        albums.enumerateObjects { album, _, stopAlbums in
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            assets.enumerateObjects { asset, _, stopAssets in
                if asset.localIdentifier.hasPrefix(key) {
                    match = asset
                    stopAssets.pointee = true
                }
            }
            if match != nil { stopAlbums.pointee = true }
        }
        return match
    }

    // MARK: - 内部

    private static func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BridgeError.saveFailed(error?.localizedDescription ?? "未知错误"))
                }
            }
        }
    }

    private static func requestEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHContentEditingInput, Error>) in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, _ in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: BridgeError.editInputFailed)
                }
            }
        }
    }

    /// 系统图库的照片 ID 就是 `Photos.sqlite` 的 ZUUID，`localIdentifier` 形如 `UUID/L0/001`。
    private static func fetchAsset(_ id: UUID) throws -> PHAsset {
        let candidates = ["\(id.uuidString)/L0/001", "\(id.uuidString)/L0/000"]
        for identifier in candidates {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
                return asset
            }
        }
        // 少数项目的后缀不同：按前缀兜底匹配一次。
        let all = PHAsset.fetchAssets(with: nil)
        var match: PHAsset?
        all.enumerateObjects { asset, _, stop in
            if asset.localIdentifier.hasPrefix(id.uuidString) {
                match = asset
                stop.pointee = true
            }
        }
        guard let match else { throw BridgeError.assetNotFound }
        return match
    }

    /// 相簿标识：可能是 ZUUID，也可能是完整的 localIdentifier，这里统一解析。
    private static func fetchAlbum(_ identifier: String) -> PHAssetCollection? {
        var candidates = [identifier]
        if !identifier.contains("/") {
            candidates += ["\(identifier)/L0/001", "\(identifier)/L0/000"]
        }
        for candidate in candidates {
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [candidate],
                                                                   options: nil).firstObject {
                return album
            }
        }
        // 后缀不同的少数项目：按前缀兜底匹配。
        let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var match: PHAssetCollection?
        all.enumerateObjects { album, _, stop in
            if album.localIdentifier.hasPrefix(identifier) {
                match = album
                stop.pointee = true
            }
        }
        return match
    }
}
