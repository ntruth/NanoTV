import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore
import PlaybackCore

extension LibraryStore {
    // MARK: - Import

    func presentImportPanel() {
        if isImporting {
            requestImportPanel()
            return
        }
        importCandidates = []
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = VideoFormats.importContentTypes + RawFormats.importContentTypes()
        panel.prompt = "继续"
        panel.message = "选择要导入的照片、RAW、视频或文件夹"
        if panel.runModal() == .OK {
            prepareImport(panel.urls)
        }
    }

    func requestImportPanel() {
        showImportSheet = true
        importPanelOpenRequest += 1
    }

    /// 通过官方 PhotosUI（PHPickerViewController）从系统「照片」挑选并导入。
    func presentPhotoPicker() {
        showPhotoPicker = true
    }

    func prepareImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                Self.buildCandidates(from: urls)
            }.value
            guard !candidates.isEmpty else {
                showToast("没有可导入的文件")
                return
            }
            importCandidates = candidates
            showImportSheet = true
            importPanelOpenRequest += 1
        }
    }

    func startImport(selectedIDs: Set<UUID>, importAll: Bool, options: ImportOptions) {
        guard !isImporting else { return }
        let chosen = importCandidates.filter { importAll || selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else {
            showToast("没有可导入的文件")
            return
        }
        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                Self.buildEntries(candidates: chosen, options: options)
            }.value
            guard !entries.isEmpty else {
                showToast("没有可导入的文件")
                return
            }
            self.runImport(entries: entries, options: options)
        }
    }

    func runImport(entries: [(url: URL, folders: [String])], options: ImportOptions) {
        guard !entries.isEmpty else { return }
        // 官方「照片」图库作为当前图库时，导入必须走 PhotoKit 新增资产：
        // 不能复制进库包里的 originals，也不能改 Photos.sqlite。
        if isNativeContainer {
            runSystemLibraryImport(entries: entries, options: options)
            return
        }
        // 磁盘空间预检：先把明显放不下的导入挡在复制之前。
        let totalBytes = entries.reduce(Int64(0)) { sum, entry in
            sum + Int64((try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        if let values = try? LibraryPaths.originals.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage,
           totalBytes > capacity {
            showToast("磁盘空间不足：需要 \(formatFileSize(totalBytes))，可用 \(formatFileSize(capacity))")
            return
        }

        importProgress = ImportProgress(total: entries.count,
                                        completed: 0,
                                        currentName: entries[0].url.lastPathComponent)
        isImporting = true
        importCancelled = false
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library((LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
                .standardizedFileURL.path),
                      kind: .ingest,
                      title: "导入媒体"),
            cancel: { [weak self] in
                Task { @MainActor in self?.cancelImport() }
            }
        )
        let albumsBefore = albums.count
        let batchID = UUID()
        // 拷贝、EXIF 解析与缩略图互不依赖，按 CPU 核数并发执行，避免逐张串行等待。
        let concurrency = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))
        let existingHashes = Set(self.metadataStore?.contentHashes().keys.map { $0 } ?? [])
        let hashGate = ImportHashGate(existingHashes)

        importTask = Task { [weak self] in
            guard let self else { return }
            var imported = 0
            var skipped = 0
            var failed = 0
            var firstFailureMessage: String?
            var verified = 0
            var albumCache: [String: UUID] = [:]
            var buffer: [PhotoItem] = []
            var nextIndex = 0
            var lastFlush = Date()

            while nextIndex < entries.count {
                if self.importCancelled || Task.isCancelled { break }
                let end = min(nextIndex + concurrency, entries.count)
                let chunk = Array(entries[nextIndex..<end])
                let base = nextIndex
                let results = await withTaskGroup(of: ImportFileResult.self,
                                                  returning: [ImportFileResult].self) { group in
                    for (offset, entry) in chunk.enumerated() {
                        group.addTask(priority: .userInitiated) {
                            // 蓝光原盘只做引用：既不能整盘哈希（几十 GB），也不能参与查重。
                            let isDisc = ImportService.isBlurayDisc(entry.url)
                            let hashes = isDisc
                                ? PhotoHasher.Result(sha256: nil, perceptualHash: nil)
                                : PhotoHasher.hashes(for: entry.url, includePerceptual: true)
                            if options.skipExactDuplicates, let hash = hashes.sha256,
                               !hashGate.claim(hash) {
                                return ImportFileResult(index: base + offset, item: nil,
                                                        outcome: .duplicate, verified: false)
                            }
                            do {
                                var item = try ImportService.importFile(entry.url)
                                item.contentHash = hashes.sha256
                                item.perceptualHash = hashes.perceptualHash
                                var didVerify = false
                                if options.verifyCopies, let sourceHash = hashes.sha256 {
                                    let destination = LibraryPaths.originalURL(for: item)
                                    if let copiedHash = try? PhotoHasher.sha256(of: destination),
                                       copiedHash == sourceHash {
                                        didVerify = true
                                    }
                                }
                                return ImportFileResult(index: base + offset, item: item,
                                                        outcome: .imported, verified: didVerify)
                            } catch {
                                let message = (error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription
                                return ImportFileResult(index: base + offset, item: nil,
                                                        outcome: .failed, verified: false,
                                                        message: message)
                            }
                        }
                    }
                    var collected: [ImportFileResult] = []
                    collected.reserveCapacity(chunk.count)
                    for await result in group { collected.append(result) }
                    return collected
                }

                // 已并发拷贝完成的文件仍要写入内存与数据库，避免取消时留下孤立文件。
                for result in results.sorted(by: { $0.index < $1.index }) {
                    switch result.outcome {
                    case .duplicate:
                        skipped += 1
                        continue
                    case .failed:
                        failed += 1
                        // 只留第一条：批量导入里同一种失败（例如同一张加密盘）重复提示没有意义。
                        if firstFailureMessage == nil { firstFailureMessage = result.message }
                        continue
                    case .imported:
                        break
                    }
                    guard var item = result.item else { continue }
                    item.importBatchID = batchID
                    buffer.append(item)
                    imported += 1
                    if result.verified { verified += 1 }
                    let folders = entries[result.index].folders
                    if options.createAlbumsFromFolders, !folders.isEmpty {
                        let key = folders.joined(separator: "/") + (options.preserveFolderStructure ? "|nested" : "|flat")
                        if let cached = albumCache[key] {
                            self.addPhotoToAlbum(item.id, albumID: cached)
                        } else if let albumID = self.ensureAlbum(path: folders,
                                                                 preserveStructure: options.preserveFolderStructure) {
                            albumCache[key] = albumID
                            self.addPhotoToAlbum(item.id, albumID: albumID)
                        }
                    } else if let target = options.targetAlbumID {
                        self.addPhotoToAlbum(item.id, albumID: target)
                    }
                }

                nextIndex = end
                let lastName = entries[end - 1].url.lastPathComponent
                self.updateProgress {
                    $0.completed = nextIndex
                    $0.currentName = lastName
                    $0.importedCount = imported
                    $0.skippedDuplicates = skipped
                    $0.failedCount = failed
                    $0.verifiedCount = verified
                }
                self.updateSourceJob(jobID,
                                     completed: nextIndex,
                                     total: entries.count,
                                     message: "已导入 \(imported) / \(entries.count) 项 · \(lastName)")

                // 批量落盘：积攒一批再写，避免上千次全量重写 SQLite。
                if buffer.count >= 80 || Date().timeIntervalSince(lastFlush) >= 2 {
                    let pending = buffer
                    buffer.removeAll(keepingCapacity: true)
                    self.photos.append(contentsOf: pending)
                    self.persistImported(pending)
                    lastFlush = Date()
                }
            }

            if !buffer.isEmpty {
                self.photos.append(contentsOf: buffer)
            }
            self.updateProgress {
                $0.completed = entries.count
                $0.importedCount = imported
                $0.skippedDuplicates = skipped
                $0.failedCount = failed
                $0.verifiedCount = verified
            }
            self.save()
            self.isImporting = false
            self.importProgress = nil

            let createdAlbums = max(0, self.albums.count - albumsBefore)
            let cancelled = self.importCancelled
            self.importCancelled = false
            self.showImportSheet = false
            self.importCandidates = []

            let summary = "已导入 \(imported) 项"
                + (skipped > 0 ? "，跳过 \(skipped) 个重复" : "")
                + (failed > 0 ? "，失败 \(failed) 个" : "")
                + (options.verifyCopies ? "，校验 \(verified) 个" : "")
            if cancelled {
                self.cancelSourceJob(jobID)
                self.showToast("已取消导入，\(summary)")
            } else if imported == 0 {
                // 具体失败原因（蓝光加密 / 结构无效等）比「导入失败」有用得多。
                if let firstFailureMessage {
                    self.showToast(firstFailureMessage)
                } else {
                    self.showToast(skipped > 0 ? "没有新照片：\(skipped) 个文件已存在" : "导入失败")
                }
            } else if createdAlbums > 0 {
                self.showToast("\(summary)，创建 \(createdAlbums) 个相簿")
            } else {
                self.showToast(summary)
            }
            if !cancelled {
                self.finishSourceJob(jobID, message: summary)
            }

            // 蓝光原盘 / ISO 只写外部引用、不进 originals，目录监听收不到变化；
            // 导入完成后主动补一次自动刮削，影院才能直接按片名把整张盘认成电影。
            if imported > 0, AppSettings.shared.cinemaAutoScrape {
                self.startCinemaScrape(for: .local)
            }
        }
    }

    nonisolated static func buildCandidates(from urls: [URL]) -> [ImportCandidate] {
        var candidates: [ImportCandidate] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let files = supportedFiles(in: url)
                guard !files.isEmpty else { continue }
                candidates.append(ImportCandidate(url: url,
                                                      name: url.lastPathComponent,
                                                      isDirectory: true,
                                                      fileCount: files.count,
                                                      cover: coverImage(for: files[0]),
                                                      previewURLs: files))
            } else if ImportService.isSupported(url) {
                candidates.append(ImportCandidate(url: url,
                                                  name: url.lastPathComponent,
                                                  isDirectory: false,
                                                  fileCount: 1,
                                                  cover: coverImage(for: url),
                                                  previewURLs: [url]))
            }
        }
        return candidates
    }

    nonisolated static func buildEntries(candidates: [ImportCandidate],
                                     options: ImportOptions) -> [(url: URL, folders: [String])] {
        var entries: [(url: URL, folders: [String])] = []
        for candidate in candidates {
            if candidate.isDirectory {
                let files = supportedFiles(in: candidate.url)
                let basePath = candidate.url.resolvingSymlinksInPath().standardizedFileURL.path
                let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
                for file in files {
                    let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
                    let relative = filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : file.lastPathComponent
                    var components = relative.split(separator: "/").dropLast().map(String.init)
                    if options.createAlbumsFromFolders {
                        components = [candidate.name] + components
                    } else {
                        components = []
                    }
                    entries.append((file, components))
                }
            } else {
                entries.append((candidate.url, []))
            }
        }
        return entries
    }

    func cancelImport() {
        importCancelled = true
    }

    func dismissImportSheet() {
        guard !isImporting else { return }
        importCandidates = []
        showImportSheet = false
    }

    func ensureAlbum(path: [String], preserveStructure: Bool) -> UUID? {
        guard let name = path.last else { return nil }
        var parentID: UUID?
        if preserveStructure {
            for folderName in path.dropLast() {
                if let existing = folders.first(where: { $0.name == folderName && $0.parentID == parentID }) {
                    parentID = existing.id
                } else {
                    let folder = AlbumFolder(name: folderName, parentID: parentID)
                    folders.append(folder)
                    parentID = folder.id
                }
            }
        }
        if let existing = albums.first(where: { $0.name == name && $0.folderID == parentID }) {
            return existing.id
        }
        let album = Album(name: name, folderID: parentID)
        albums.append(album)
        return album.id
    }

    func addPhotoToAlbum(_ photoID: UUID, albumID: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == albumID }),
              !albums[index].photoIDs.contains(photoID) else { return }
        albums[index].photoIDs.append(photoID)
    }

    func updateProgress(_ mutate: (inout ImportProgress) -> Void) {
        guard var progress = importProgress else { return }
        mutate(&progress)
        importProgress = progress
    }

    nonisolated static func supportedFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var files: [URL] = []
        // 蓝光原盘：目录里会有成百上千个 m2ts / mpls，折叠成一张盘一个条目，
        // 否则会把菜单、花絮片段当成一堆独立视频导入。
        var discs: Set<String> = []
        for case let file as URL in enumerator {
            if let disc = BluraySource.discRoot(containing: file) {
                if discs.insert(disc.path).inserted { files.append(disc) }
                continue
            }
            if ImportService.isSupported(file) { files.append(file) }
        }
        // 实况照片的 MOV 与同名图片一起导入（作为配对视频），不再单独生成视频项目。
        var imageStems: Set<String> = []
        for file in files where !VideoFormats.isVideo(file) {
            let key = file.deletingLastPathComponent().path + "/"
                + file.deletingPathExtension().lastPathComponent.lowercased()
            imageStems.insert(key)
        }
        files = files.filter { file in
            guard VideoFormats.isVideo(file) else { return true }
            let key = file.deletingLastPathComponent().path + "/"
                + file.deletingPathExtension().lastPathComponent.lowercased()
            return !imageStems.contains(key)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated static func coverImage(for url: URL) -> NSImage? {
        ImageLoader.quickThumbnail(url: url, maxPixel: 260)
    }
}

private enum ImportOutcome {
    case imported
    case duplicate
    case failed
}

private struct ImportFileResult {
    let index: Int
    let item: PhotoItem?
    let outcome: ImportOutcome
    let verified: Bool
    /// 失败原因（已翻译成用户可读文案）：蓝光加密盘等需要明确告诉用户怎么办。
    var message: String? = nil
}

/// 导入批次内的哈希闸门：已有图库哈希 + 本批次已认领哈希，避免重复复制同一文件。
private final class ImportHashGate {
    private let lock = NSLock()
    private var hashes: Set<String>

    init(_ hashes: Set<String>) {
        self.hashes = hashes
    }

    /// 返回 true 表示第一次见到这个哈希，可以继续导入。
    func claim(_ hash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hashes.contains(hash) { return false }
        hashes.insert(hash)
        return true
    }
}
