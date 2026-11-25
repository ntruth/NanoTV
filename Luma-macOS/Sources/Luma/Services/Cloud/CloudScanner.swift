import Foundation

/// 网盘全盘扫描：从挂载根目录广度优先遍历，按目录回调媒体条目，
/// 供图库式浏览边扫边显示（不下载原图，缩略图与 EXIF 仍按需读取）。
enum CloudScanner {
    /// 一个目录的扫描结果：目录下的媒体、子目录，以及这批媒体所在的目录路径。
    struct Batch {
        var media: [CloudEntry]
        var folders: [CloudEntry]
        var container: String
    }

    struct Result {
        var folderCount: Int
        var mediaCount: Int
        var truncated: Bool
        /// 本次扫描实际见到的媒体路径：用于刷新时剔除网盘上已删除的项目。
        var mediaPaths: Set<String>
        /// 读取失败的目录数：大于 0 时不能据此判断「哪些文件已被删除」。
        var failedFolders: Int
        /// 是否有目录因为授权 / 钥匙串问题失败：界面据此提示重新登录。
        var sawAuthError: Bool
        /// 第一条目录错误，便于在没有扫到任何媒体时把原因展示出来。
        var firstErrorDescription: String?
        /// 上一轮存在、这一轮已从父目录列表消失的文件夹：调用方据此清理目录树。
        var removedFolderPaths: Set<String> = []
    }

    /// 增量扫描依据：上一轮完整扫描的目录树与媒体归属。
    /// 只对「父目录列表里的修改时间没变」的子树跳过，任何不确定都会退回正常扫描。
    struct IncrementalPlan {
        let foldersByPath: [String: CloudScanFolder]
        let childrenByParent: [String: [String]]
        let mediaByFolder: [String: [String]]
    }

    /// 系统 / 回收站类目录不参与扫描，避免把 NAS 的 @eaDir 缩略图当成照片。
    private static let skippedFolderNames: Set<String> = [
        "#recycle", "@recycle", "@eadir", ".trashes", ".trash", ".ds_store",
        ".thumbnails", ".cache", ".baidunetdisk", ".photoslibrary",
        "$recycle.bin", "system volume information", "__macosx"
    ]

    static func shouldSkipFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        return skippedFolderNames.contains(lower) || lower.hasPrefix(".")
    }

    /// 广度优先扫描。`onBatch` 每读完一个目录回调一次（主线程），便于立即刷新界面。
    /// - Parameters:
    ///   - maxFolders: 目录数上限，防止超大网盘一次扫到底。
    ///   - maxMedia: 媒体数上限，达到后标记 `truncated` 并结束。
    static func scan(mount: CloudMount,
                     incremental: IncrementalPlan? = nil,
                     maxFolders: Int = 1_200,
                     maxMedia: Int = 20_000,
                     onBatch: @MainActor @escaping (_ batch: Batch,
                                                    _ folderCount: Int,
                                                    _ mediaCount: Int) -> Void) async -> Result {
        if mount.kind == .smb, incremental == nil {
            // 全量 SMB 扫描用一次递归枚举（比逐目录往返快），同时收集目录与 mtime，
            // 写进索引后，下一轮就能走下面的通用 BFS 做目录级增量。
            let excluded = mount.excludedRoots.map(\.path).filter { !$0.isEmpty }
            func isExcluded(_ path: String) -> Bool {
                excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            var scopeSeen: Set<String> = []
            let scopes = mount.scopeRoots
                .map(\.path)
                .filter { !$0.isEmpty && !isExcluded($0) }
                .filter { scopeSeen.insert($0).inserted }
            let scopeFolders = scopes.map { path in
                CloudEntry(path: path,
                           name: (path as NSString).lastPathComponent,
                           isDirectory: true,
                           size: 0,
                           modifiedAt: nil,
                           contentType: nil)
            }

            var media: [CloudEntry] = []
            var folders: [CloudEntry] = scopeFolders
            var mediaSeen: Set<String> = []
            var folderSeen: Set<String> = Set(scopeFolders.map(\.path))
            var failedFolders = 0
            var firstErrorDescription: String?
            for root in (scopes.isEmpty ? [""] : scopes) {
                if Task.isCancelled { break }
                let tree: SMBTreeScanResult
                do {
                    tree = try await CloudService.scanTree(mount: mount, path: root)
                } catch {
                    failedFolders += 1
                    if firstErrorDescription == nil {
                        firstErrorDescription = error.localizedDescription
                    }
                    continue
                }
                for entry in tree.media where entry.isMedia
                    && !isExcluded(entry.path)
                    && mediaSeen.insert(entry.path).inserted {
                    media.append(entry)
                }
                for entry in tree.folders where !entry.path.isEmpty
                    && !isExcluded(entry.path)
                    && !shouldSkipFolder(entry.name)
                    && folderSeen.insert(entry.path).inserted {
                    folders.append(entry)
                }
            }

            var childrenByParent: [String: [CloudEntry]] = [:]
            for folder in folders {
                childrenByParent[Self.parentPath(of: folder.path), default: []].append(folder)
            }
            var mediaByParent: [String: [CloudEntry]] = [:]
            for entry in media {
                mediaByParent[Self.parentPath(of: entry.path), default: []].append(entry)
            }
            let containers = Set(childrenByParent.keys)
                .union(mediaByParent.keys)
                .sorted()
            var folderCount = 0
            var mediaCount = 0
            for container in containers {
                if Task.isCancelled { break }
                let childFolders = childrenByParent[container] ?? []
                folderCount += childFolders.count
                let items = mediaByParent[container] ?? []
                mediaCount += items.count
                await onBatch(Batch(media: items, folders: childFolders, container: container),
                              folderCount,
                              mediaCount)
            }
            return Result(folderCount: max(folderCount, folders.count),
                          mediaCount: media.count,
                          truncated: false,
                          mediaPaths: Set(media.map(\.path)),
                          failedFolders: failedFolders,
                          sawAuthError: false,
                          firstErrorDescription: firstErrorDescription)
        }

        let root = mount.kind == .baidu ? "/" : ""
        let excludedPaths = Set(mount.excludedRoots.map(\.path).filter { !$0.isEmpty })
        // 向导里选过接入范围：只扫描这些目录，并把它们直接挂成侧边栏的顶层相簿。
        let scopeCandidates = mount.scopeRoots.filter {
            !$0.path.isEmpty && $0.path != root && !excludedPaths.contains($0.path)
        }
        var scopeSeen: Set<String> = []
        let scopes = scopeCandidates.filter { scopeSeen.insert($0.path).inserted }
        var queue: [String] = scopes.isEmpty ? [root] : scopes.map(\.path)
        if !scopes.isEmpty {
            let scopeFolders = scopes.map {
                CloudEntry(path: $0.path,
                           name: $0.name,
                           isDirectory: true,
                           size: 0,
                           modifiedAt: nil,
                           contentType: nil)
            }
            await onBatch(Batch(media: [], folders: scopeFolders, container: root), 0, 0)
        }
        // 阿里云盘的媒体经常放在「资源库」而不是默认盘，只扫默认盘会几乎为空；
        // 这里把账号下的每个盘都挂成一个虚拟根目录，扫描器按普通目录遍历即可。
        if scopes.isEmpty, mount.kind == .aliyun,
           let token = try? await CloudService.accessToken(for: mount),
           let drives = try? await AliyunOAuth.drives(accessToken: token),
           !drives.isEmpty {
            let virtualRoots = drives.map {
                CloudEntry(path: "\($0.id)|root",
                           name: $0.label,
                           isDirectory: true,
                           size: 0,
                           modifiedAt: nil,
                           contentType: nil)
            }
            await onBatch(Batch(media: [], folders: virtualRoots, container: root), 0, 0)
            queue = virtualRoots.map(\.path)
        }
        var visited: Set<String> = Set(queue)
        var seenFolders: Set<String> = []
        var seenMedia: Set<String> = []
        var removedFolderPaths: Set<String> = []
        var folderCount = 0
        var newFolderCount = 0
        var mediaCount = 0
        var newMediaCount = 0
        var truncated = false
        var failedFolders = 0
        var sawAuthError = false
        var firstErrorDescription: String?

        while !queue.isEmpty {
            if Task.isCancelled { break }
            let folder = queue.removeFirst()
            let entries: [CloudEntry]
            do {
                entries = try await CloudService.list(mount: mount, containerID: folder)
            } catch {
                // 单个目录失败（权限 / 已删除）不影响整盘扫描，继续其它目录。
                failedFolders += 1
                if firstErrorDescription == nil {
                    firstErrorDescription = error.localizedDescription
                }
                if let oauth = error as? CloudOAuthError, oauth.requiresReauth {
                    sawAuthError = true
                }
                continue
            }
            if seenFolders.insert(folder).inserted { folderCount += 1 }
            newFolderCount += 1

            var batch: [CloudEntry] = []
            var childFolders: [CloudEntry] = []
            var actualChildren: Set<String> = []
            for entry in entries {
                if entry.isDirectory {
                    guard !entry.path.isEmpty,
                          !excludedPaths.contains(entry.path),
                          !shouldSkipFolder(entry.name) else { continue }
                    actualChildren.insert(entry.path)
                    // 增量：父目录列表里的修改时间未变，直接复用上一轮这棵子树的目录与媒体。
                    if let incremental, Self.canReuse(entry, plan: incremental) {
                        let subtree = Self.subtree(of: entry.path, plan: incremental)
                        for path in subtree.folders where seenFolders.insert(path).inserted {
                            folderCount += 1
                        }
                        for path in subtree.media where seenMedia.insert(path).inserted {
                            mediaCount += 1
                        }
                        childFolders.append(entry)
                        continue
                    }
                    guard visited.insert(entry.path).inserted else { continue }
                    queue.append(entry.path)
                    childFolders.append(entry)
                } else if entry.isMedia, seenMedia.insert(entry.path).inserted {
                    batch.append(entry)
                    mediaCount += 1
                    newMediaCount += 1
                }
            }
            // 上一轮有、这一轮父目录列表里已不存在的子目录：调用方需要把它们从目录树里移除。
            if let incremental {
                for previous in incremental.childrenByParent[folder] ?? []
                where !actualChildren.contains(previous) {
                    removedFolderPaths.insert(previous)
                }
            }

            await onBatch(Batch(media: batch, folders: childFolders, container: folder),
                          folderCount,
                          mediaCount)
            if newMediaCount >= maxMedia { truncated = true }
            if truncated || newFolderCount >= maxFolders {
                if newFolderCount >= maxFolders { truncated = true }
                break
            }
        }

        return Result(folderCount: folderCount,
                      mediaCount: mediaCount,
                      truncated: truncated,
                      mediaPaths: seenMedia,
                      failedFolders: failedFolders,
                      sawAuthError: sawAuthError,
                      firstErrorDescription: firstErrorDescription,
                      removedFolderPaths: removedFolderPaths)
    }

    /// 父目录列表里子目录的修改时间与上一轮一致时才允许复用。
    private static func canReuse(_ entry: CloudEntry, plan: IncrementalPlan) -> Bool {
        guard let previous = plan.foldersByPath[entry.path],
              let previousDate = previous.modifiedAt,
              let currentDate = entry.modifiedAt else { return false }
        return abs(previousDate.timeIntervalSince(currentDate)) < 1
    }

    /// 取上一轮某棵子树里的全部目录与媒体路径。
    private static func subtree(of path: String,
                                plan: IncrementalPlan) -> (folders: [String], media: [String]) {
        var folders: [String] = []
        var media: [String] = []
        var stack = [path]
        var seen: Set<String> = []
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            folders.append(next)
            media.append(contentsOf: plan.mediaByFolder[next] ?? [])
            stack.append(contentsOf: plan.childrenByParent[next] ?? [])
        }
        return (folders, media)
    }

    /// 取父目录路径（SMB 的相对路径，例如 `a/b/c.jpg` → `a/b`）。
    static func parentPath(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "" }
        let parent = String(path[..<index])
        return parent.isEmpty ? "/" : parent
    }
}
