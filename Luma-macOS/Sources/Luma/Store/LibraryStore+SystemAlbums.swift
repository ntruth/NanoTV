import Foundation
import CoreLocation
import AppKit

/// 提取相簿前的确认信息。
struct ExtractAlbumsRequest: Identifiable {
    var id: String { "extract-\(folderID)" }
    let folderID: Int64
    let folderName: String
    let albumCount: Int
    let subfolderCount: Int
}

/// 提取完成后的空文件夹清理邀请。
struct EmptyFoldersCleanupRequest: Identifiable {
    var id: String { "cleanup-\(folderID)" }
    let folderID: Int64
    let folderName: String
    /// 会被删掉的空子文件夹（顶层，删除即带走整棵空子树）。
    let folders: [SystemFolderInfo]
    var folderCount: Int { folders.count }
}

/// 系统图库文件夹整理流程：确认 → 执行中 → 清理空文件夹。
enum SystemFolderPrompt: Identifiable {
    case extract(ExtractAlbumsRequest)
    case working(title: String, message: String)
    case cleanupEmptyFolders(EmptyFoldersCleanupRequest)

    /// 固定 id：同一流程内切换内容时 sheet 保持同一个，不会反复弹出。
    var id: String { "systemFolderOrganize" }
}

/// 当前原生图库能否被 PhotoKit 写入。
enum SystemWriteTargetState {
    /// 还没拿到可校验的照片。
    case unknown
    case ready
    /// 打开的不是「照片」正在使用的图库：PhotoKit 只会写系统当前库。
    case mismatch
}

/// 系统图库的工具弹窗。
enum SystemToolsRequest: Identifiable {
    case metadata(ids: Set<UUID>)
    case moveAlbumsToFolder(albumIDs: [Int64])
    case newAlbumWithPhotos(ids: Set<UUID>)
    case deleteFolder(id: Int64, name: String, albumCount: Int)
    /// 空相簿 / 空文件夹清理：先确认再写回「照片」。
    case cleanupEmptyCollections(albumIDs: [Int64], folderIDs: [Int64])

    var id: String {
        switch self {
        case .metadata(let ids): return "metadata-\(ids.hashValue)"
        case .moveAlbumsToFolder(let albumIDs): return "move-albums-\(albumIDs)"
        case .newAlbumWithPhotos(let ids): return "new-album-\(ids.hashValue)"
        case .deleteFolder(let id, _, _): return "delete-folder-\(id)"
        case .cleanupEmptyCollections(_, _): return "cleanup-empty-collections"
        }
    }
}

/// 系统「照片」图库的相簿 / 收藏 / 隐藏写回（PhotoKit）。
/// 只有「照片」正在使用的那个图库可写；其它挂载的 .photoslibrary 完全只读。
extension LibraryStore {
    /// 挂载的其它照片图库一律只读：PhotoKit 只能定位「照片」当前库，硬写会脏库。
    var canWriteSystemLibrary: Bool {
        guard isSystemScope, isNativeContainer else { return false }
        // 还没检测过时先保留入口；真正写入前 `prepareSystemLibraryWrite` 会再校验一次。
        return systemWriteTargetState != .mismatch
    }

    var canManageSystemAlbums: Bool {
        canWriteSystemLibrary
    }

    /// 当前是原生照片图库，且已经知道它是哪个库。
    private var isNativePhotosScope: Bool {
        isNativeContainer && systemLibraryPath != nil
    }

    /// 写回前统一校验：权限 + 「当前打开的就是系统照片库」。
    /// PhotoKit 的每次写入都是单个事务：要么整体提交，要么整体失败，不会写一半。
    func prepareSystemLibraryWrite() async -> Bool {
        guard isNativeContainer else {
            showToast("只有官方「照片」图库作为当前图库时才能写回")
            return false
        }
        // 右键侧边栏树时页面可能停在「图库总览」等非系统范围：先切到系统图库，
        // 避免用户从菜单点进来后被上下文挡住。
        if !isSystemScope {
            navigate(to: .systemLibrary)
        }
        guard await PhotoKitBridge.ensureAuthorized() else {
            showToast("需要相册读写权限，请在系统设置中允许拾光访问照片")
            return false
        }
        refreshSystemWriteTargetState()
        guard systemWriteTargetState != .mismatch else {
            let name = systemLibraryName ?? "当前图库"
            showToast("「\(name)」不是「照片」正在使用的图库，已保持只读。请先在「照片」中打开它；切换后需要重启拾光才会生效")
            return false
        }
        return true
    }

    /// 检测当前打开的原生图库是不是「照片」正在使用的图库。
    /// 取 PhotoKit 能看到的少量资产，反查该库 `Photos.sqlite` 里是否存在；全程只读。
    /// - Parameter announce: 手动点「重新检测写入目标」时传 true，用 toast 说明检测结果。
    func refreshSystemWriteTargetState(announce: Bool = false) {
        defer {
            if announce { announceSystemWriteTargetState() }
        }
        guard isNativePhotosScope,
              PhotoKitBridge.hasReadWriteAuthorization,
              let path = systemLibraryPath else {
            systemWriteTargetState = .unknown
            return
        }
        // PhotoKit 一张照片都看不到时无法比对，保持「未知」，不要误判成只读。
        guard PhotoKitBridge.hasVisibleAssets else {
            systemWriteTargetState = .unknown
            return
        }
        systemWriteTargetState = PhotoKitBridge.libraryMatches(path: path) ? .ready : .mismatch
    }

    /// 检测结果的用户可读说明：手动检测后告诉用户为什么能 / 不能编辑。
    private func announceSystemWriteTargetState() {
        let name = systemLibraryName ?? "当前图库"
        switch systemWriteTargetState {
        case .ready:
            showToast("「\(name)」是「照片」正在使用的图库，已解锁新建 / 重命名 / 删除相簿")
        case .mismatch:
            showToast("「\(name)」不是「照片」正在使用的图库：先在「照片」中打开它；已经切换过的话，重启拾光即可")
        case .unknown:
            showToast("需要「照片」的读写权限，或这个图库还没有可校验的照片")
        }
    }

    /// PhotoKit 在进程启动时绑定「照片」的当前图库：在「照片」里切库之后，
    /// 拾光必须重启才能把写入目标切过去。检测到 mismatch 时给一键重启。
    func relaunchForLibraryWrite() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// 引导：在「照片」中打开当前图库，使它成为 PhotoKit 的写入目标。
    func openCurrentLibraryInPhotosForImport() {
        guard LibraryPaths.containerLibraryURL != nil else {
            showToast("请先连接一个照片图库")
            return
        }
        openContainerInPhotos()
        showToast("已在「照片」中请求打开此图库；确认切换后回到这里点「重新检测」")
    }

    /// Photos.sqlite 的 ZUUID → PhotoKit 相簿标识（由 `PhotoKitBridge` 解析 localIdentifier）。
    func systemAlbumIdentifier(_ albumID: Int64) -> String? {
        if let uuid = systemAlbum(id: albumID)?.uuid, !uuid.isEmpty {
            return uuid
        }
        // 旧快照缓存可能没有 uuid：直接回查 Photos.sqlite（只读）。
        guard let path = systemLibraryPath else { return nil }
        let databasePath = URL(fileURLWithPath: path)
            .appendingPathComponent("database/Photos.sqlite").path
        guard let db = try? SQLiteDatabase(path: databasePath, readonly: true) else { return nil }
        let row = (try? db.query("SELECT ZUUID FROM ZGENERICALBUM WHERE Z_PK = ?", [albumID]))?.first
        guard let uuid = row?["ZUUID"]?.string, !uuid.isEmpty else { return nil }
        return uuid
    }

    /// 文件夹的系统标识：和相簿共用 `ZGENERICALBUM`，同样从 ZUUID 取。
    /// `SystemFolderInfo` 不带 uuid，这里直接只读回查。
    func systemFolderIdentifier(_ folderID: Int64) -> String? {
        guard let path = systemLibraryPath else { return nil }
        let databasePath = URL(fileURLWithPath: path)
            .appendingPathComponent("database/Photos.sqlite").path
        guard let db = try? SQLiteDatabase(path: databasePath, readonly: true) else { return nil }
        let row = (try? db.query("SELECT ZUUID FROM ZGENERICALBUM WHERE Z_PK = ?", [folderID]))?.first
        guard let uuid = row?["ZUUID"]?.string, !uuid.isEmpty else { return nil }
        return uuid
    }

    /// 批量解析相簿 / 文件夹的系统标识：一次 `IN` 查询，避免提取、移动几十个相簿时反复开库。
    private func genericalAlbumUUIDs(for ids: [Int64]) -> [Int64: String] {
        guard !ids.isEmpty, let path = systemLibraryPath else { return [:] }
        let databasePath = URL(fileURLWithPath: path)
            .appendingPathComponent("database/Photos.sqlite").path
        guard let db = try? SQLiteDatabase(path: databasePath, readonly: true) else { return [:] }
        let list = ids.map(String.init).joined(separator: ",")
        let rows = (try? db.query("""
            SELECT Z_PK AS pk, ZUUID AS uuid FROM ZGENERICALBUM WHERE Z_PK IN (\(list))
            """)) ?? []
        var result: [Int64: String] = [:]
        for row in rows {
            guard let pk = row["pk"]?.int64,
                  let uuid = row["uuid"]?.string, !uuid.isEmpty else { continue }
            result[pk] = uuid
        }
        return result
    }

    func systemAlbumIdentifiers(_ ids: [Int64]) -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        var result: [Int64: String] = [:]
        var missing: [Int64] = []
        for id in ids {
            if let uuid = systemAlbum(id: id)?.uuid, !uuid.isEmpty {
                result[id] = uuid
            } else {
                missing.append(id)
            }
        }
        if !missing.isEmpty {
            result.merge(genericalAlbumUUIDs(for: missing)) { current, _ in current }
        }
        return result
    }

    func systemFolderIdentifiers(_ ids: [Int64]) -> [Int64: String] {
        genericalAlbumUUIDs(for: ids)
    }

    /// 把该文件夹下所有子目录里的相簿（递归）提取到当前文件夹；当前文件夹已有的相簿保持不变。
    /// 先弹确认，不直接改动图库。
    func requestExtractSystemFolderAlbums(_ folderID: Int64) {
        guard let plan = makeExtractAlbumsPlan(folderID) else { return }
        systemFolderPrompt = .extract(ExtractAlbumsRequest(folderID: plan.folderID,
                                                           folderName: plan.folderName,
                                                           albumCount: plan.albums.count,
                                                           subfolderCount: plan.topAffectedFolders.count))
    }

    /// 用户在确认面板点了「提取」。
    func confirmExtractSystemFolderAlbums(_ request: ExtractAlbumsRequest) {
        guard let plan = makeExtractAlbumsPlan(request.folderID) else {
            systemFolderPrompt = nil
            return
        }
        systemFolderPrompt = .working(title: "正在提取相簿",
                                      message: "把 \(plan.albums.count) 个相簿提到「\(plan.folderName)」…")
        let movingIDs = Set(plan.albums.map(\.id))
        Task {
            guard await prepareSystemLibraryWrite() else {
                systemFolderPrompt = nil
                return
            }
            do {
                let moved = try await PhotoKitBridge.extractAlbums(plan.albumIdentifiers,
                                                                   intoFolder: plan.folderIdentifier)
                systemAlbums = systemAlbums.map { album in
                    guard movingIDs.contains(album.id) else { return album }
                    return SystemAlbumInfo(id: album.id,
                                          name: album.name,
                                          parentFolder: plan.folderID,
                                          assetIDs: album.assetIDs,
                                          sortIndex: album.sortIndex,
                                          uuid: album.uuid,
                                          customSortKey: album.customSortKey,
                                          customSortAscending: album.customSortAscending)
                }
                systemAlbumIndex = Dictionary(uniqueKeysWithValues: systemAlbums.map { ($0.id, $0) })
                refreshSystemStructureAfterOrganize(affectedAlbums: Array(movingIDs))
                showToast("已把 \(moved) 个相簿提取到「\(plan.folderName)」，目录与缩略图已刷新")
                if plan.topAffectedFolders.isEmpty {
                    systemFolderPrompt = nil
                } else {
                    systemFolderPrompt = .cleanupEmptyFolders(
                        EmptyFoldersCleanupRequest(folderID: plan.folderID,
                                                   folderName: plan.folderName,
                                                   folders: plan.topAffectedFolders))
                }
            } catch {
                systemFolderPrompt = nil
                showToast("提取相簿失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    /// 用户选择「保留」或点关闭：结束整理流程。
    func dismissSystemFolderPrompt() {
        systemFolderPrompt = nil
    }

    /// 用户在清理面板确认删除空出来的子文件夹。
    func confirmEmptyFoldersCleanup(_ request: EmptyFoldersCleanupRequest) {
        let ids = request.folders.map(\.id)
        let idMap = systemFolderIdentifiers(ids)
        guard !ids.isEmpty, idMap.count == ids.count else {
            systemFolderPrompt = nil
            showToast("部分文件夹缺少系统标识，请「重新读取」系统图库后重试")
            return
        }
        let identifiers = ids.compactMap { idMap[$0] }
        systemFolderPrompt = .working(title: "正在清理空文件夹",
                                      message: "删除「\(request.folderName)」下 \(ids.count) 个空子文件夹…")
        Task {
            guard await prepareSystemLibraryWrite() else {
                systemFolderPrompt = nil
                return
            }
            do {
                try await PhotoKitBridge.deleteFolders(identifiers: identifiers)
                // 连子孙文件夹一起从内存移除：删顶层空文件夹会带走整棵空子树。
                var removed = Set(ids)
                var queue = ids
                while let current = queue.popLast() {
                    for child in systemFolders where child.parent == current && !removed.contains(child.id) {
                        removed.insert(child.id)
                        queue.append(child.id)
                    }
                }
                systemFolders.removeAll { removed.contains($0.id) }
                refreshSystemStructureAfterOrganize()
                if case .systemFolder(let current) = sidebarItem, removed.contains(current) {
                    navigate(to: .systemAlbums)
                }
                systemFolderPrompt = nil
                showToast("已清理 \(ids.count) 个空文件夹")
            } catch {
                systemFolderPrompt = nil
                showToast("清理空文件夹失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    private struct ExtractAlbumsPlan {
        let folderID: Int64
        let folderName: String
        let albums: [SystemAlbumInfo]
        let albumIdentifiers: [String]
        let folderIdentifier: String
        let topAffectedFolders: [SystemFolderInfo]
    }

    private func makeExtractAlbumsPlan(_ folderID: Int64) -> ExtractAlbumsPlan? {
        guard let folder = systemFolders.first(where: { $0.id == folderID }) else { return nil }
        // 递归收集子孙文件夹（不含目标自身）。
        var descendants: Set<Int64> = []
        var queue: [Int64] = [folderID]
        while let current = queue.popLast() {
            for child in systemFolders where child.parent == current && !descendants.contains(child.id) {
                descendants.insert(child.id)
                queue.append(child.id)
            }
        }
        let albums = systemAlbums.filter { album in
            guard let parent = album.parentFolder else { return false }
            return descendants.contains(parent)
        }
        guard !albums.isEmpty else {
            showToast("「\(folder.name)」的子目录里没有相簿")
            return nil
        }
        guard let folderIdentifier = systemFolderIdentifier(folderID) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return nil
        }
        let identifiers = systemAlbumIdentifiers(albums.map(\.id))
        guard identifiers.count == albums.count else {
            showToast("部分相簿缺少系统标识，请「重新读取」系统图库后重试")
            return nil
        }
        // 每个相簿沿父级上溯到目标文件夹下的第一层，就是这次会被腾空的子文件夹。
        let folderMap = Dictionary(uniqueKeysWithValues: systemFolders.map { ($0.id, $0) })
        var topIDs: Set<Int64> = []
        for album in albums {
            guard var node = album.parentFolder else { continue }
            while let item = folderMap[node], let parent = item.parent, parent != folderID {
                node = parent
            }
            topIDs.insert(node)
        }
        let tops = systemFolders.filter { topIDs.contains($0.id) }
        return ExtractAlbumsPlan(folderID: folderID,
                                 folderName: folder.name,
                                 albums: albums,
                                 albumIdentifiers: albums.compactMap { identifiers[$0.id] },
                                 folderIdentifier: folderIdentifier,
                                 topAffectedFolders: tops)
    }

    /// 整理后的轻量刷新：重建派生缓存并让目录 / 缩略图重新取，不整库重扫。
    private func refreshSystemStructureAfterOrganize(affectedAlbums: [Int64] = []) {
        for id in affectedAlbums {
            systemAlbumCoverCache[id] = nil
            systemAlbumCoverMisses.remove(id)
            systemAlbumCoverLoading.remove(id)
        }
        systemCountsCache = nil
        systemCountsCacheRevision = -1
        systemStructureRevision &+= 1
        contentRevision &+= 1
    }

    // MARK: - 相簿增删改

    /// ⌘⇧N「新建相簿」：官方「照片」图库范围内写回系统相簿，其它范围照旧建拾光相簿。
    /// 挂载的其它 .photoslibrary 只读，不会成为写入目标。
    func presentNewAlbumCommand() {
        if canWriteSystemLibrary, systemLibraryPath != nil {
            namePrompt = .newSystemAlbum()
        } else if isSystemScope {
            showToast("「\(systemLibraryName ?? "当前图库")」是只读挂载库，无法新建相簿")
        } else {
            showNewAlbumSheet = true
        }
    }

    /// 新建系统相簿；`inFolder` 非空时直接放进该文件夹。
    func createSystemAlbum(named name: String, inFolder parentID: Int64? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folderIdentifier = parentID.flatMap { systemFolderIdentifier($0) }
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                let identifier = try await PhotoKitBridge.createAlbum(title: trimmed)
                if let folderIdentifier {
                    try await PhotoKitBridge.addAlbum(identifier, toFolder: folderIdentifier)
                }
                showToast(parentID == nil
                          ? "已在「照片」中新建相簿「\(trimmed)」"
                          : "已在「照片」的文件夹中新建相簿「\(trimmed)」")
                // 只重读相簿/文件夹结构：不整库重扫，保留当前选区与网格窗口。
                refreshSystemStructureFromDatabase()
            } catch {
                showToast("新建相簿失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    /// 新建系统文件夹；`parentID` 非空时建在该文件夹下。
    func createSystemFolder(named name: String, parentID: Int64? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parentIdentifier = parentID.flatMap { systemFolderIdentifier($0) }
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                _ = try await PhotoKitBridge.createFolder(title: trimmed, inFolder: parentIdentifier)
                showToast(parentID == nil
                          ? "已在「照片」中新建文件夹「\(trimmed)」"
                          : "已在「照片」中新建子文件夹「\(trimmed)」")
                refreshSystemStructureFromDatabase()
            } catch {
                showToast("新建文件夹失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    func renameSystemAlbum(_ id: Int64, to name: String) {
        guard let identifier = systemAlbumIdentifier(id) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.renameAlbum(albumID: identifier, title: name)
                updateSystemAlbum(id, name: name)
                showToast("已把相簿重命名为「\(name)」")
            } catch {
                showToast("重命名失败：\(error.localizedDescription)")
            }
        }
    }

    func deleteSystemAlbum(_ id: Int64) {
        guard let identifier = systemAlbumIdentifier(id) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.deleteAlbums(albumIDs: [identifier])
                systemAlbums.removeAll { $0.id == id }
                removePinned(systemAlbumIDs: [id])
                systemAlbumIndex[id] = nil
                systemStructureRevision &+= 1
                systemCountsCache = nil
                systemCountsCacheRevision = -1
                contentRevision &+= 1
                if case .systemAlbum(let current) = sidebarItem, current == id {
                    navigate(to: .systemAlbums)
                }
                showToast("已从「照片」删除相簿（照片本身不受影响）")
            } catch {
                showToast("删除相簿失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 相簿内照片

    func addSystemPhotos(_ ids: Set<UUID>, toSystemAlbum albumID: Int64) {
        guard !ids.isEmpty, let album = systemAlbum(id: albumID) else { return }
        guard let identifier = systemAlbumIdentifier(albumID) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        let targets = Array(ids)
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.addAssets(targets, toAlbum: identifier)
                var merged = album.assetIDs
                for id in targets where !merged.contains(id) { merged.append(id) }
                updateSystemAlbum(albumID, assetIDs: merged)
                showToast("已把 \(targets.count) 张加入「\(album.name)」")
            } catch {
                showToast("加入相簿失败：\(error.localizedDescription)")
            }
        }
    }

    func removeSystemPhotos(_ ids: Set<UUID>, fromSystemAlbum albumID: Int64) {
        guard !ids.isEmpty, let album = systemAlbum(id: albumID) else { return }
        guard let identifier = systemAlbumIdentifier(albumID) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        let targets = Array(ids)
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.removeAssets(targets, fromAlbum: identifier)
                updateSystemAlbum(albumID, assetIDs: album.assetIDs.filter { !ids.contains($0) })
                showToast("已把 \(targets.count) 张移出「\(album.name)」")
            } catch {
                showToast("移出相簿失败：\(error.localizedDescription)")
            }
        }
    }

    /// 相簿内手动排序：移到最前 / 最后。
    func moveSystemPhotos(_ ids: Set<UUID>, inSystemAlbum albumID: Int64, toTop: Bool) {
        guard !ids.isEmpty, let album = systemAlbum(id: albumID) else { return }
        guard let identifier = systemAlbumIdentifier(albumID) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        let targets = Array(ids)
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.moveAssets(targets, inAlbum: identifier, toTop: toTop)
                var order = album.assetIDs
                let moving = order.filter { ids.contains($0) }
                order.removeAll { ids.contains($0) }
                if toTop {
                    order.insert(contentsOf: moving, at: 0)
                } else {
                    order.append(contentsOf: moving)
                }
                updateSystemAlbum(albumID, assetIDs: order)
                markSystemAlbumManualOrder(albumID)
                refreshSystemStructureAfterOrganize(affectedAlbums: [albumID])
                showToast(toTop ? "已把 \(targets.count) 张移到最前" : "已把 \(targets.count) 张移到最后")
            } catch {
                showToast("调整顺序失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 相册内拖拽排序

    private static let systemManualOrderSettingKey = "system_manual_order_albums"

    /// 当前是否处在可拖拽排序的系统相簿。
    var currentSystemAlbumID: Int64? {
        guard case .systemAlbum(let id) = sidebarItem, canManageSystemAlbums else { return nil }
        return id
    }

    func loadSystemManualOrderAlbums() {
        guard let json = metadataStore?.setting(Self.systemManualOrderSettingKey),
              let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Int64].self, from: data) else {
            systemManualOrderAlbums = []
            return
        }
        systemManualOrderAlbums = Set(ids)
    }

    func isSystemAlbumManualOrder(_ albumID: Int64) -> Bool {
        systemManualOrderAlbums.contains(albumID)
    }

    /// 记录「这个相簿按手动顺序展示」：只影响拾光的展示方式，不改「照片」的排序设置。
    func markSystemAlbumManualOrder(_ albumID: Int64) {
        guard systemManualOrderAlbums.insert(albumID).inserted else { return }
        persistSystemManualOrderAlbums()
        contentRevision &+= 1
    }

    /// 用户在相册里显式换了排序方式：退出拖拽产生的手动顺序。
    func clearSystemAlbumManualOrder(_ albumID: Int64) {
        guard systemManualOrderAlbums.remove(albumID) != nil else { return }
        persistSystemManualOrderAlbums()
        contentRevision &+= 1
    }

    private func persistSystemManualOrderAlbums() {
        let json = (try? JSONEncoder().encode(systemManualOrderAlbums.sorted()))
            .flatMap { String(data: $0, encoding: .utf8) }
        metadataStore?.setSetting(Self.systemManualOrderSettingKey, json)
    }

    /// 系统相簿内拖拽排序：把 moving 移到 targetID 前 / 后，经 PhotoKit 写回「照片」。
    func moveSystemPhotos(_ ids: Set<UUID>,
                          inSystemAlbum albumID: Int64,
                          before targetID: UUID,
                          after: Bool) {
        guard !ids.isEmpty, !ids.contains(targetID), systemAlbum(id: albumID) != nil else { return }
        guard let identifier = systemAlbumIdentifier(albumID) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        let targets = Array(ids)
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.moveAssets(targets,
                                                    inAlbum: identifier,
                                                    before: targetID,
                                                    after: after)
                // 写回成功后切到手动顺序展示，网格立即呈现新位置。
                markSystemAlbumManualOrder(albumID)
                refreshSystemStructureAfterOrganize(affectedAlbums: [albumID])
                showToast("已调整相簿顺序，并同步到「照片」")
            } catch {
                showToast("调整顺序失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    // MARK: - 删除到「照片」最近删除

    /// 把系统照片移到「照片」的最近删除（30 天内可在「照片」中恢复）。
    func deleteSystemToPhotosTrash(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let targets = Array(ids)
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.delete(assetIDs: targets)
                removeSystemPhotosFromMemory(ids)
                for id in ids { systemOverlays[id] = nil }
                selection.removeAll()
                if let viewerID, ids.contains(viewerID) { self.viewerID = nil }
                showToast("已移到「照片」的最近删除，30 天内可在「照片」中恢复")
            } catch {
                showToast("删除失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    // MARK: - 文件夹

    func renameSystemFolder(_ id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let identifier = systemFolderIdentifier(id) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.renameFolder(identifier: identifier, title: trimmed)
                if let index = systemFolders.firstIndex(where: { $0.id == id }) {
                    let old = systemFolders[index]
                    systemFolders[index] = SystemFolderInfo(id: old.id,
                                                            name: trimmed,
                                                            parent: old.parent,
                                                            sortIndex: old.sortIndex)
                }
                systemStructureRevision &+= 1
                showToast("已把文件夹重命名为「\(trimmed)」")
            } catch {
                showToast("重命名文件夹失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    /// 文件夹子树里的相簿数量（删除确认用）。
    func systemAlbumCountInSubtree(_ folderID: Int64) -> Int {
        var folders: Set<Int64> = [folderID]
        var queue: [Int64] = [folderID]
        while let current = queue.popLast() {
            for child in systemFolders where child.parent == current && !folders.contains(child.id) {
                folders.insert(child.id)
                queue.append(child.id)
            }
        }
        return systemAlbums.filter { album in
            guard let parent = album.parentFolder else { return false }
            return folders.contains(parent)
        }.count
    }

    func presentDeleteSystemFolder(_ id: Int64) {
        guard let folder = systemFolders.first(where: { $0.id == id }) else { return }
        systemToolsRequest = .deleteFolder(id: id,
                                           name: folder.name,
                                           albumCount: systemAlbumCountInSubtree(id))
    }

    /// 「移动到文件夹」的选择列表：全路径名 + 文件夹 ID，按名称排序。
    func systemFolderChoices() -> [(id: Int64, path: String)] {
        let map = Dictionary(uniqueKeysWithValues: systemFolders.map { ($0.id, $0) })
        func path(of id: Int64) -> String {
            var parts: [String] = []
            var current: Int64? = id
            var depth = 0
            while let cursor = current, let folder = map[cursor], depth < 64 {
                parts.insert(folder.name, at: 0)
                current = folder.parent
                depth += 1
            }
            return parts.joined(separator: " / ")
        }
        return systemFolders
            .map { (id: $0.id, path: path(of: $0.id)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func deleteSystemFolder(_ id: Int64) {
        guard systemFolders.contains(where: { $0.id == id }) else { return }
        guard let identifier = systemFolderIdentifier(id) else {
            showToast("请先在菜单里「重新读取」系统图库后再试")
            return
        }
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.deleteFolders(identifiers: [identifier])
                var removed: Set<Int64> = [id]
                var queue: [Int64] = [id]
                while let current = queue.popLast() {
                    for child in systemFolders where child.parent == current && !removed.contains(child.id) {
                        removed.insert(child.id)
                        queue.append(child.id)
                    }
                }
                let removedAlbums = Set(systemAlbums.filter { album in
                    guard let parent = album.parentFolder else { return false }
                    return removed.contains(parent)
                }.map(\.id))
                systemFolders.removeAll { removed.contains($0.id) }
                systemAlbums.removeAll { removedAlbums.contains($0.id) }
                systemAlbumIndex = Dictionary(uniqueKeysWithValues: systemAlbums.map { ($0.id, $0) })
                refreshSystemStructureAfterOrganize(affectedAlbums: Array(removedAlbums))
                if case .systemFolder(let current) = sidebarItem, removed.contains(current) {
                    navigate(to: .systemAlbums)
                }
                systemToolsRequest = nil
                showToast("已删除文件夹；里面的相簿一并移除，照片本身不受影响")
            } catch {
                systemToolsRequest = nil
                showToast("删除文件夹失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    // MARK: - 空相簿 / 空文件夹清理

    /// 图库体检里的空相簿 / 空文件夹结果。
    struct SystemEmptyCollectionsReport {
        /// 没有任何照片的相簿。
        var emptyAlbums: [SystemAlbumInfo] = []
        /// 整棵子树里都没有照片的文件夹（只留最上层：删掉它即带走整棵空树）。
        var emptyFolders: [SystemFolderInfo] = []
        var isEmpty: Bool { emptyAlbums.isEmpty && emptyFolders.isEmpty }
    }

    /// 扫描空相簿与空文件夹（只读内存里的结构 + 一次分组查询出的相簿张数）。
    func systemEmptyCollectionsReport() -> SystemEmptyCollectionsReport {
        var report = SystemEmptyCollectionsReport()
        // 一次 GROUP BY 拿到全部相簿张数，避免几千个相簿逐个 COUNT 把主线程卡住。
        let bulkCounts = systemIndex?.albumAssetCounts()
        func photoCount(_ albumID: Int64) -> Int {
            if let cached = bulkCounts?[albumID] { return cached }
            return systemAlbumPhotoCount(albumID)
        }

        report.emptyAlbums = systemAlbums.filter { photoCount($0.id) == 0 }

        // 子树里含有「非空相簿」的文件夹，连同所有上级都不算空。
        var foldersWithContent = Set<Int64>()
        var parentOf: [Int64: Int64] = [:]
        for folder in systemFolders {
            if let parent = folder.parent { parentOf[folder.id] = parent }
        }
        for album in systemAlbums where photoCount(album.id) > 0 {
            guard var cursor = album.parentFolder else { continue }
            while !foldersWithContent.contains(cursor) {
                foldersWithContent.insert(cursor)
                guard let parent = parentOf[cursor] else { break }
                cursor = parent
            }
        }
        let emptyCandidates = systemFolders.filter { !foldersWithContent.contains($0.id) }
        let candidateIDs = Set(emptyCandidates.map(\.id))
        // 只保留最上层：下面的空子文件夹会被父级一起删掉，重复列出会让数量虚高。
        report.emptyFolders = emptyCandidates.filter { folder in
            guard let parent = folder.parent else { return true }
            return !candidateIDs.contains(parent)
        }
        return report
    }

    /// 弹出清理确认；没有任何空项时只提示，不弹窗。
    func presentEmptyCollectionsCleanup() {
        let report = systemEmptyCollectionsReport()
        guard !report.isEmpty else {
            showToast("没有空相簿或空文件夹")
            return
        }
        systemToolsRequest = .cleanupEmptyCollections(albumIDs: report.emptyAlbums.map(\.id),
                                                      folderIDs: report.emptyFolders.map(\.id))
    }

    /// 清理空相簿 / 空文件夹：写回「照片」，只移除容器，照片本身不受影响。
    /// 先删相簿再删文件夹：两者分开提交，任何一步失败都会保留已完成的部分并重读结构。
    func cleanupEmptyCollections(albumIDs: [Int64], folderIDs: [Int64],
                                 removeAlbums: Bool, removeFolders: Bool) {
        let albumsToRemove = removeAlbums ? albumIDs : []
        let foldersToRemove = removeFolders ? folderIDs : []
        guard !albumsToRemove.isEmpty || !foldersToRemove.isEmpty else {
            systemToolsRequest = nil
            return
        }
        let albumIdentifiers = Array(systemAlbumIdentifiers(albumsToRemove).values)
        let folderIdentifiers = Array(systemFolderIdentifiers(foldersToRemove).values)
        Task {
            guard await prepareSystemLibraryWrite() else {
                systemToolsRequest = nil
                return
            }
            var didChange = false
            do {
                if !albumIdentifiers.isEmpty {
                    try await PhotoKitBridge.deleteAlbums(albumIDs: albumIdentifiers)
                    didChange = true
                }
                if !folderIdentifiers.isEmpty {
                    try await PhotoKitBridge.deleteFolders(identifiers: folderIdentifiers)
                    didChange = true
                }
                switch sidebarItem {
                case .systemAlbum(let id) where albumsToRemove.contains(id):
                    navigate(to: .systemAlbums)
                case .systemFolder(let id) where foldersToRemove.contains(id):
                    navigate(to: .systemAlbums)
                default:
                    break
                }
                removePinned(systemAlbumIDs: Set(albumsToRemove))
                refreshSystemStructureFromDatabase()
                systemToolsRequest = nil
                var parts: [String] = []
                if !albumIdentifiers.isEmpty { parts.append("\(albumIdentifiers.count) 个空相簿") }
                if !folderIdentifiers.isEmpty { parts.append("\(folderIdentifiers.count) 个空文件夹") }
                showToast("已从「照片」移除 " + parts.joined(separator: "、"))
            } catch {
                if didChange { refreshSystemStructureFromDatabase() }
                systemToolsRequest = nil
                showToast("清理失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    // MARK: - 相簿整理

    func presentMoveSystemAlbumsToFolder(_ albumID: Int64) {
        guard systemAlbum(id: albumID) != nil else { return }
        systemToolsRequest = .moveAlbumsToFolder(albumIDs: [albumID])
    }

    func moveSystemAlbums(_ albumIDs: [Int64], toFolder folderID: Int64) {
        guard !albumIDs.isEmpty, let folder = systemFolders.first(where: { $0.id == folderID }) else { return }
        let albumMap = systemAlbumIdentifiers(albumIDs)
        let folderMap = systemFolderIdentifiers([folderID])
        guard albumMap.count == albumIDs.count,
              let folderIdentifier = folderMap[folderID] else {
            showToast("部分相簿缺少系统标识，请「重新读取」系统图库后重试")
            return
        }
        let identifiers = albumIDs.compactMap { albumMap[$0] }
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                let moved = try await PhotoKitBridge.extractAlbums(identifiers, intoFolder: folderIdentifier)
                let moving = Set(albumIDs)
                systemAlbums = systemAlbums.map { album in
                    guard moving.contains(album.id) else { return album }
                    return SystemAlbumInfo(id: album.id,
                                          name: album.name,
                                          parentFolder: folderID,
                                          assetIDs: album.assetIDs,
                                          sortIndex: album.sortIndex,
                                          uuid: album.uuid,
                                          customSortKey: album.customSortKey,
                                          customSortAscending: album.customSortAscending)
                }
                systemAlbumIndex = Dictionary(uniqueKeysWithValues: systemAlbums.map { ($0.id, $0) })
                refreshSystemStructureAfterOrganize()
                systemToolsRequest = nil
                showToast("已把 \(moved) 个相簿移到「\(folder.name)」")
            } catch {
                systemToolsRequest = nil
                showToast("移动相簿失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    func presentNewSystemAlbumWithPhotos(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        systemToolsRequest = .newAlbumWithPhotos(ids: ids)
    }

    /// 新建相簿并把所选项目一起加进去（创建与加入在同一个 PhotoKit 事务里）。
    func createSystemAlbum(named name: String, adding ids: Set<UUID>) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let targets = Array(ids)
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                _ = try await PhotoKitBridge.createAlbum(title: trimmed, adding: targets)
                systemToolsRequest = nil
                showToast(targets.isEmpty
                          ? "已在「照片」中新建相簿「\(trimmed)」"
                          : "已新建相簿「\(trimmed)」并加入 \(targets.count) 项")
                refreshSystemStructureFromDatabase()
            } catch {
                systemToolsRequest = nil
                showToast("新建相簿失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    /// 从一个系统相簿移动到另一个系统相簿：先加入目标，再移出源（失败不会丢照片）。
    func moveSystemPhotos(_ ids: Set<UUID>, fromSystemAlbum source: Int64, toSystemAlbum target: Int64) {
        guard !ids.isEmpty, source != target,
              let sourceAlbum = systemAlbum(id: source),
              let targetAlbum = systemAlbum(id: target),
              let sourceIdentifier = systemAlbumIdentifier(source),
              let targetIdentifier = systemAlbumIdentifier(target) else { return }
        let targets = Array(ids)
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.addAssets(targets, toAlbum: targetIdentifier)
                try await PhotoKitBridge.removeAssets(targets, fromAlbum: sourceIdentifier)
                var targetIDs = targetAlbum.assetIDs
                for id in targets where !targetIDs.contains(id) { targetIDs.append(id) }
                updateSystemAlbum(target, assetIDs: targetIDs)
                updateSystemAlbum(source, assetIDs: sourceAlbum.assetIDs.filter { !ids.contains($0) })
                showToast("已把 \(targets.count) 项移到「\(targetAlbum.name)」")
            } catch {
                showToast("移动到相簿失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    // MARK: - 拍摄信息

    func presentSystemMetadataEditor(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        systemToolsRequest = .metadata(ids: ids)
    }

    /// 修改拍摄时间 / 位置；传 nil 表示该项保持不变。
    func updateSystemMetadata(_ ids: Set<UUID>, creationDate: Date?, location: CLLocation?) {
        guard !ids.isEmpty, creationDate != nil || location != nil else { return }
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.updateMetadata(assetIDs: Array(ids),
                                                        creationDate: creationDate,
                                                        location: location)
                for id in ids {
                    updateSystemPhoto(id) { photo in
                        if let creationDate { photo.capturedAt = creationDate }
                        if let location {
                            photo.latitude = location.coordinate.latitude
                            photo.longitude = location.coordinate.longitude
                        }
                    }
                }
                systemGeoCacheKey = nil
                systemToolsRequest = nil
                showToast("已更新 \(ids.count) 个项目的拍摄信息")
            } catch {
                systemToolsRequest = nil
                showToast("更新拍摄信息失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    // MARK: - 编辑写回

    /// 编辑器保存：把渲染结果作为非破坏性调整写回「照片」。
    func saveSystemEdit(photoID: UUID, jpegData: Data) {
        Task {
            guard await prepareSystemLibraryWrite() else { return }
            do {
                try await PhotoKitBridge.applyEdit(assetID: photoID, jpegData: jpegData)
                updateSystemPhoto(photoID) { $0.editVersion += 1 }
                editorID = nil
                showToast("已保存修改并同步到「照片」")
            } catch {
                showToast("保存失败：\(PhotoKitBridge.userMessage(for: error))")
            }
        }
    }

    /// 轻量重读相簿 / 文件夹结构（新建相簿后让侧边栏出现新条目，不整库重扫）。
    private func refreshSystemStructureFromDatabase() {
        guard let index = systemIndex else {
            reloadSystemLibrary()
            return
        }
        Task {
            let meta = await Task.detached(priority: .userInitiated) {
                (index.albums, index.folders)
            }.value
            systemAlbums = meta.0
            systemFolders = meta.1
            systemAlbumIndex = Dictionary(uniqueKeysWithValues: meta.0.map { ($0.id, $0) })
            refreshSystemStructureAfterOrganize()
        }
    }

    // MARK: - 内存同步

    private func updateSystemAlbum(_ id: Int64,
                                   name: String? = nil,
                                   assetIDs: [UUID]? = nil) {
        guard let index = systemAlbums.firstIndex(where: { $0.id == id }) else { return }
        let old = systemAlbums[index]
        let updated = SystemAlbumInfo(id: old.id,
                                      name: name ?? old.name,
                                      parentFolder: old.parentFolder,
                                      assetIDs: assetIDs ?? old.assetIDs,
                                      sortIndex: old.sortIndex,
                                      uuid: old.uuid,
                                      customSortKey: old.customSortKey,
                                      customSortAscending: old.customSortAscending)
        systemAlbums[index] = updated
        systemAlbumIndex[id] = updated
        systemStructureRevision &+= 1
        systemCountsCache = nil
        systemCountsCacheRevision = -1
        contentRevision &+= 1
    }
}
