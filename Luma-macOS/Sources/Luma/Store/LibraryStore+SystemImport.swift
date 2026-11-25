import Foundation
import AppKit
import AVFoundation
import CoreLocation
import ImageIO
import LumaContentCore

/// 系统「照片」图库导入：只经 PhotoKit 新增资产，绝不直接写 `Photos.sqlite` 或 Apple 的 originals。
/// 与拾光图库共用同一套导入面板、进度与任务中心，但目标不同：
/// - 系统侧：PhotoKit 写入文件 + 拍摄时间 / 位置；
/// - 拾光侧：在 `Luma.sqlite` 里补一份标题（第二份元数据）。
extension LibraryStore {
    func runSystemLibraryImport(entries: [(url: URL, folders: [String])], options: ImportOptions) {
        guard !entries.isEmpty else { return }
        importProgress = ImportProgress(total: entries.count,
                                        completed: 0,
                                        currentName: entries[0].url.lastPathComponent)
        isImporting = true
        importCancelled = false
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library((LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
                .standardizedFileURL.path),
                      kind: .ingest,
                      title: "导入到系统图库"),
            cancel: { [weak self] in
                Task { @MainActor in self?.cancelImport() }
            }
        )

        importTask = Task { [weak self] in
            guard let self else { return }
            // 写前统一校验：权限 + 当前打开的就是「照片」正在使用的图库。
            // 校验不过就一个字节都不写，宁可失败也不把内容写进别的库。
            guard await self.prepareSystemLibraryWrite() else {
                self.isImporting = false
                self.importProgress = nil
                self.importCancelled = false
                self.showImportSheet = false
                self.importCandidates = []
                self.failSourceJob(jobID, message: "未通过写入前校验：权限不足或当前图库不是「照片」正在使用的图库")
                return
            }

            var manifest = await Task.detached(priority: .utility) {
                NativeImportManifest.load()
            }.value
            var imported = 0
            var skipped = 0
            var failed = 0
            var verified = 0
            var createdAlbums = 0
            var createdFolders = 0
            var organizationWarning: String?
            var albumCache: [String: String] = [:]
            var folderCache: [String: String] = [:]
            var failures: [(name: String, reason: String)] = []
            var lastSave = Date()

            for (index, entry) in entries.enumerated() {
                if self.importCancelled || Task.isCancelled { break }
                let name = entry.url.lastPathComponent
                self.updateProgress { $0.currentName = name }

                if ImportService.isBlurayDisc(entry.url) {
                    failed += 1
                    failures.append((name, "蓝光原盘不能写入系统图库，请先转成视频文件"))
                    self.updateProgress {
                        $0.completed = index + 1
                        $0.importedCount = imported
                        $0.skippedDuplicates = skipped
                        $0.failedCount = failed
                    }
                    self.updateSourceJob(jobID,
                                         completed: index + 1,
                                         total: entries.count,
                                         message: "已跳过 \(name)")
                    continue
                }

                let isVideo = VideoFormats.isVideo(entry.url)
                let hash: String? = options.skipExactDuplicates
                    ? await Task.detached(priority: .userInitiated) {
                        try? PhotoHasher.sha256(of: entry.url)
                    }.value
                    : nil
                if let hash, !hash.isEmpty,
                   let cached = manifest.hashes[hash],
                   PhotoKitBridge.assetExists(localIdentifier: cached.localIdentifier) {
                    skipped += 1
                    self.updateProgress {
                        $0.completed = index + 1
                        $0.importedCount = imported
                        $0.skippedDuplicates = skipped
                        $0.failedCount = failed
                    }
                    self.updateSourceJob(jobID,
                                         completed: index + 1,
                                         total: entries.count,
                                         message: "跳过重复 \(name) · 已写入 \(imported)")
                    continue
                }
                if let hash, manifest.hashes[hash] != nil {
                    // 账本里有、但资产已经不在图库：删掉旧记录，按新文件重新写入。
                    manifest.hashes.removeValue(forKey: hash)
                }

                let meta = await NativeAssetMetadata.read(entry.url, isVideo: isVideo)
                do {
                    let created = try await PhotoKitBridge.createAsset(
                        from: entry.url,
                        isVideo: isVideo,
                        creationDate: meta.date,
                        location: meta.location,
                        pairedVideoURL: isVideo ? nil : ImportService.livePhotoCompanionURL(for: entry.url)
                    )
                    imported += 1
                    verified += 1
                    // 第二份元数据：系统侧已经写入拍摄时间 / 位置，这里补拾光自己的标题。
                    self.recordSystemImportOverlay(
                        assetID: created.id,
                        title: entry.url.deletingPathExtension().lastPathComponent
                    )
                    if let hash, !hash.isEmpty {
                        manifest.hashes[hash] = NativeImportManifest.Entry(
                            localIdentifier: created.localIdentifier,
                            filename: name,
                            importedAt: Date()
                        )
                    }
                    // 按文件夹整理成「照片」里的相簿 / 文件夹；整理失败不影响已写入的资产。
                    if options.createAlbumsFromFolders, !entry.folders.isEmpty {
                        do {
                            let albumTitle = entry.folders.last ?? "导入"
                            let parentTitles = options.preserveFolderStructure
                                ? Array(entry.folders.dropLast()) : []
                            var folderID: String?
                            if !parentTitles.isEmpty {
                                let key = parentTitles.joined(separator: "/")
                                if let cached = folderCache[key] {
                                    folderID = cached
                                } else {
                                    let folder = try await PhotoKitBridge.ensureFolderPath(parentTitles)
                                    createdFolders += folder.created
                                    if let identifier = folder.identifier {
                                        folderCache[key] = identifier
                                        folderID = identifier
                                    }
                                }
                            }
                            let albumID: String
                            if let cached = albumCache[albumTitle] {
                                albumID = cached
                            } else {
                                let album = try await PhotoKitBridge.ensureAlbum(title: albumTitle)
                                albumCache[albumTitle] = album.identifier
                                albumID = album.identifier
                                if album.created {
                                    createdAlbums += 1
                                    if let folderID {
                                        try await PhotoKitBridge.addAlbum(albumID, toFolder: folderID)
                                    }
                                }
                            }
                            try await PhotoKitBridge.addAsset(localIdentifier: created.localIdentifier,
                                                              toAlbum: albumID)
                        } catch {
                            if organizationWarning == nil {
                                let reason = PhotoKitBridge.userMessage(for: error)
                                organizationWarning = "\(name)：已写入，但相簿整理失败（\(reason)）"
                            }
                        }
                    }
                } catch {
                    failed += 1
                    let reason = PhotoKitBridge.userMessage(for: error)
                    failures.append((name, reason))
                }

                self.updateProgress {
                    $0.completed = index + 1
                    $0.importedCount = imported
                    $0.skippedDuplicates = skipped
                    $0.failedCount = failed
                    $0.verifiedCount = verified
                }
                self.updateSourceJob(jobID,
                                     completed: index + 1,
                                     total: entries.count,
                                     message: "已写入 \(imported) / \(entries.count) 项 · \(name)")

                // 账本按批落盘，导入中途崩溃也不会把已写入的项目重复写一遍。
                if Date().timeIntervalSince(lastSave) >= 2 {
                    lastSave = Date()
                    let snapshot = manifest
                    Task.detached(priority: .utility) { snapshot.save() }
                }
            }

            await Task.detached(priority: .utility) { manifest.save() }.value

            let cancelled = self.importCancelled
            self.isImporting = false
            self.importProgress = nil
            self.importCancelled = false
            self.showImportSheet = false
            self.importCandidates = []

            var summary = "已写入系统图库 \(imported) 项"
            if skipped > 0 { summary += "，跳过 \(skipped) 个重复" }
            if failed > 0 { summary += "，失败 \(failed) 个" }
            if createdAlbums > 0 { summary += "，新建 \(createdAlbums) 个相簿" }
            if createdFolders > 0 { summary += "，新建 \(createdFolders) 个文件夹" }

            if cancelled {
                self.cancelSourceJob(jobID)
                self.showToast("已取消导入，\(summary)")
            } else if failed > 0 {
                var detail = failures.prefix(3)
                    .map { "\($0.name)：\($0.reason)" }
                    .joined(separator: "；")
                if let organizationWarning {
                    detail += (detail.isEmpty ? "" : "；") + organizationWarning
                }
                self.failSourceJob(jobID, message: "\(summary) · \(detail)")
                self.showToast(imported > 0 ? "\(summary)。失败原因：\(detail)" : detail)
            } else if let organizationWarning {
                self.finishSourceJob(jobID, message: "\(summary) · \(organizationWarning)")
                self.showToast("\(summary)。\(organizationWarning)")
            } else {
                self.finishSourceJob(jobID, message: summary)
                self.showToast(summary)
            }

            // 写入完成后刷新系统图库索引，新项目立刻出现在网格里。
            // 只刷新当前原生图库，绝不触碰额外挂载的只读系统图库。
            if imported > 0, let path = LibraryPaths.containerLibraryURL?.path {
                self.loadSystemLibrary(at: URL(fileURLWithPath: path),
                                       informOnFailure: false,
                                       forceRefresh: true)
            }
        }
    }
}

/// 原生导入去重账本：SHA-256 → 已写入的系统资产标识。
/// 纯旁挂 JSON，不参与 Photos 自己的数据库，损坏时视为空账本重新开始。
private struct NativeImportManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var localIdentifier: String
        var filename: String
        var importedAt: Date
    }

    var hashes: [String: Entry] = [:]

    static func load() -> NativeImportManifest {
        guard let data = try? Data(contentsOf: LibraryPaths.systemImportManifest),
              let manifest = try? JSONDecoder().decode(NativeImportManifest.self, from: data) else {
            return NativeImportManifest()
        }
        return manifest
    }

    func save() {
        // 账本只服务于查重，没必要无限增长：保留最近 8000 条。
        var trimmed = self
        if trimmed.hashes.count > 8000 {
            let keep = trimmed.hashes
                .sorted { $0.value.importedAt > $1.value.importedAt }
                .prefix(8000)
            trimmed.hashes = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        let url = LibraryPaths.systemImportManifest
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// 从本地文件读拍摄时间与位置：写进系统图库时用，避免导入后全变成「今天」。
private enum NativeAssetMetadata {
    static func read(_ url: URL, isVideo: Bool) async -> (date: Date?, location: CLLocation?) {
        if isVideo {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return (values?.creationDate ?? values?.contentModificationDate, nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            return (values?.creationDate, nil)
        }

        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            date = exifFormatter.date(from: text)
        }

        var location: CLLocation?
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let rawLatitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let rawLongitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -rawLatitude : rawLatitude
            let longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -rawLongitude : rawLongitude
            if CoordinateValidator.isValid(latitude: latitude, longitude: longitude) {
                location = CLLocation(latitude: latitude, longitude: longitude)
            }
        }

        if date == nil {
            date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
        return (date, location)
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}
