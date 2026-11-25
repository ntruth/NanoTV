import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import LumaContentCore

extension LibraryStore {
    // MARK: - Compression

    func presentCompression(for ids: Set<UUID>) {
        guard !isCompressing else {
            showToast("正在压缩，请稍候")
            return
        }
        let valid = ids.filter { id in
            guard let photo = photo(id: id) else { return false }
            return !photo.isVideo && !photo.isSystem && !photo.isCloud && !photo.isDeleted
        }
        guard !valid.isEmpty else {
            showToast("所选项目中没有可压缩的照片")
            return
        }
        compressionEstimateTask?.cancel()
        compressionTargets = valid
        compressionEstimates = [:]
        compressionEstimating = false
        compressionProgress = nil
        showCompressionSheet = true
    }

    func refreshCompressionEstimates() {
        compressionEstimateTask?.cancel()
        let targets = compressionTargets
            .compactMap { photo(id: $0) }
            .sorted { $0.capturedAt > $1.capturedAt }
        guard !targets.isEmpty else {
            compressionEstimates = [:]
            compressionEstimating = false
            return
        }
        let settings = compressionSettings
        compressionEstimating = true
        compressionEstimates = [:]

        compressionEstimateTask = Task { [weak self] in
            var results: [UUID: CompressionEstimate] = [:]
            for photo in targets {
                if Task.isCancelled { return }
                let estimate = await Task.detached(priority: .utility) {
                    PhotoCompressor.estimate(photo: photo, settings: settings)
                }.value
                if Task.isCancelled { return }
                guard let self else { return }
                results[photo.id] = estimate
                self.compressionEstimates = results
            }
            guard let self, !Task.isCancelled else { return }
            self.compressionEstimating = false
        }
    }

    func startCompression() {
        guard !isCompressing else { return }
        let settings = compressionSettings
        let targets = compressionTargets
            .compactMap { photo(id: $0) }
            .sorted { $0.capturedAt > $1.capturedAt }
        guard !targets.isEmpty else { return }

        compressionEstimateTask?.cancel()
        isCompressing = true
        compressionCancelled = false
        var progress = CompressionProgress(total: targets.count,
                                          completed: 0,
                                          currentName: targets[0].originalName)
        compressionProgress = progress
        let jobID = beginSourceJob(
            SourceJob(sourceID: .library((LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
                .standardizedFileURL.path),
                      kind: .compress,
                      title: "批量压缩"),
            cancel: { [weak self] in
                Task { @MainActor in self?.cancelCompression() }
            }
        )

        compressionTask = Task { [weak self] in
            guard let self else { return }
            for (index, photo) in targets.enumerated() {
                if self.compressionCancelled || Task.isCancelled { break }
                progress.currentName = photo.originalName
                self.compressionProgress = progress

                let outcome = await Task.detached(priority: .userInitiated) {
                    Result { try PhotoCompressor.compress(photo: photo, settings: settings) }
                }.value

                switch outcome {
                case .success(let result):
                    if result.skipped {
                        progress.skipped += 1
                    } else {
                        progress.compressed += 1
                        progress.savedBytes += result.savedBytes
                        self.applyCompressionResult(photoID: photo.id, result: result)
                    }
                case .failure:
                    progress.failed += 1
                }

                progress.completed = index + 1
                self.compressionProgress = progress
                self.updateSourceJob(jobID,
                                     completed: progress.completed,
                                     total: progress.total,
                                     message: "已处理 \(progress.completed) / \(progress.total) 项 · \(photo.originalName)")
                if progress.completed % 10 == 0 {
                    self.save()
                }
            }

            self.save()
            self.isCompressing = false
            let cancelled = self.compressionCancelled
            self.compressionCancelled = false
            self.compressionProgress = nil
            self.compressionEstimates = [:]
            self.compressionTargets = []
            self.showCompressionSheet = false

            if cancelled {
                self.cancelSourceJob(jobID)
            } else {
                self.finishSourceJob(jobID,
                                     message: "已压缩 \(progress.compressed) 张 · 节省 \(formatFileSize(progress.savedBytes))")
            }
            if cancelled {
                self.showToast("已取消压缩，已节省 \(formatFileSize(progress.savedBytes))")
            } else if progress.compressed == 0 {
                self.showToast(progress.failed > 0
                    ? "压缩失败 \(progress.failed) 项"
                    : "未产生更小的文件")
            } else if progress.failed > 0 {
                self.showToast("已压缩 \(progress.compressed) 张，失败 \(progress.failed) 项，节省 \(formatFileSize(progress.savedBytes))")
            } else {
                self.showToast("已压缩 \(progress.compressed) 张，节省 \(formatFileSize(progress.savedBytes))")
            }
        }
    }

    func cancelCompression() {
        compressionCancelled = true
        compressionTask?.cancel()
    }

    func applyCompressionResult(photoID: UUID, result: CompressionResult) {
        guard let index = photos.firstIndex(where: { $0.id == photoID }) else { return }
        var updated = photos[index]
        updated.filename = result.filename
        updated.fileSize = result.bytes
        if result.width > 0 { updated.pixelWidth = result.width }
        if result.height > 0 { updated.pixelHeight = result.height }
        if !updated.hasEdits {
            ImportService.makeImageThumbnail(url: LibraryPaths.originalURL(for: updated),
                                             destination: LibraryPaths.thumbnailURL(for: updated))
        }
        updated.editVersion += 1
        photos[index] = updated
        ImageLoader.invalidate(photo: updated)
    }

    func revertCompression(_ photoID: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == photoID }) else { return }
        guard let restored = PhotoCompressor.restoreBackup(for: photos[index]) else {
            showToast("没有可还原的备份")
            return
        }
        var updated = photos[index]
        updated.filename = restored.filename
        updated.fileSize = restored.bytes
        if restored.width > 0 { updated.pixelWidth = restored.width }
        if restored.height > 0 { updated.pixelHeight = restored.height }
        if !updated.hasEdits {
            ImportService.makeImageThumbnail(url: LibraryPaths.originalURL(for: updated),
                                             destination: LibraryPaths.thumbnailURL(for: updated))
        }
        updated.editVersion += 1
        photos[index] = updated
        ImageLoader.invalidate(photo: updated)
        save()
        showToast("已还原压缩前的原图")
    }

    // MARK: - Export

    func presentBatchExport() {
        let ids = commandTargetIDs
        guard !ids.isEmpty else {
            showToast("请先选择要导出的项目")
            return
        }
        exportTargets = ids
        showExportSheet = true
    }

    /// 按当前导出设置，把所选项目写入指定文件夹。
    func performExport(to folder: URL) {
        let items = exportTargets.compactMap { anyPhoto(id: $0) }
        guard !items.isEmpty else {
            showExportSheet = false
            return
        }
        let options = exportOptions
        showExportSheet = false
        exportTargets = []
        Task {
            var exported = 0
            var failed = 0
            for (index, photo) in items.enumerated() {
                let name = exportFilename(for: photo, index: index, options: options)
                let destination = uniqueDestination(folder.appendingPathComponent(name))
                do {
                    if photo.isCloud {
                        try await downloadCloudItem(photo, to: destination)
                    } else if options.exportOriginal,
                              let original = unmodifiedOriginalURL(for: photo) {
                        try copyFile(original, to: destination)
                    } else if photo.isVideo {
                        // 视频保持原文件，避免重新编码损失画质。
                        try ImageTransform.export(photo: photo, to: destination)
                    } else if options.format != .original || options.maxDimension > 0 {
                        try exportRendered(photo: photo, to: destination, options: options)
                    } else {
                        try ImageTransform.export(photo: photo, to: destination)
                    }
                    exportLivePhotoCompanion(for: photo, alongside: destination)
                    exported += 1
                } catch {
                    failed += 1
                }
            }
            showToast(failed == 0 ? "已导出 \(exported) 项" : "已导出 \(exported) 项，\(failed) 项失败")
        }
    }

    /// 未修改的原片（本地库指向 originals，官方库指向包内文件）。
    func unmodifiedOriginalURL(for photo: PhotoItem) -> URL? {
        if let path = photo.systemOriginalPath {
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let url = LibraryPaths.originalURL(for: photo)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func copyFile(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func exportRendered(photo: PhotoItem, to url: URL, options: ExportOptions) throws {
        let maxPixel: CGFloat? = options.maxDimension > 0 ? CGFloat(options.maxDimension) : nil
        guard let image = ImageTransform.uprightImage(for: photo, maxPixel: maxPixel) else {
            throw NSError(domain: "Luma.Export", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法渲染照片"])
        }
        let type = options.format.utType
            ?? Self.imageType(forExtension: url.pathExtension)
            ?? .jpeg
        try ImageTransform.write(image, to: url, type: type,
                                 quality: options.format.supportsQuality ? options.quality : 0.95)
    }

    static func imageType(forExtension ext: String) -> UTType? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        case "png": return .png
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        case "webp": return .webP
        default: return nil
        }
    }

    func exportFilename(for photo: PhotoItem, index: Int, options: ExportOptions) -> String {
        if options.exportOriginal { return photo.originalName }
        let originalExtension = (photo.originalName as NSString).pathExtension
        let extensionName = options.format.fileExtension ?? originalExtension
        let ext = extensionName.isEmpty ? "jpg" : extensionName
        let sequence = String(format: "%03d", index + 1)
        switch options.filenameRule {
        case .original:
            guard options.format != .original else { return photo.originalName }
            let stem = (photo.originalName as NSString).deletingPathExtension
            return "\(stem).\(ext)"
        case .title:
            let stem = photo.displayTitle.isEmpty ? sequence : photo.displayTitle
            return "\(stem).\(ext)"
        case .dateSequence:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return "\(formatter.string(from: photo.capturedAt))-\(sequence).\(ext)"
        case .sequence:
            return "IMG-\(sequence).\(ext)"
        }
    }

    func uniqueDestination(_ url: URL) -> URL {
        var candidate = url
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            candidate = folder.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    /// 实况照片导出时，把配对视频复制到导出图片旁（跟图片同名的 .MOV）。
    func exportLivePhotoCompanion(for photo: PhotoItem, alongside destination: URL) {
        guard photo.isLivePhoto, !photo.isVideo, !photo.isCloud else { return }
        guard let video = LibraryPaths.livePhotoURL(for: photo),
              FileManager.default.fileExists(atPath: video.path) else { return }
        let ext = video.pathExtension.isEmpty ? "mov" : video.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        let target = uniqueDestination(destination.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension(ext))
        try? copyFile(video, to: target)
    }

    func export(_ photoID: UUID) {
        guard let photo = anyPhoto(id: photoID) else { return }
        let panel = NSSavePanel()
        let base = (photo.originalName as NSString).deletingPathExtension
        panel.nameFieldStringValue = photo.hasEdits ? base + ".jpg" : photo.originalName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            if photo.isCloud {
                Task {
                    do {
                        try await downloadCloudItem(photo, to: url)
                        showToast("已导出「\(url.lastPathComponent)」")
                    } catch {
                        showToast("导出失败：\(error.localizedDescription)")
                    }
                }
                return
            }
            do {
                try ImageTransform.export(photo: photo, to: url)
                exportLivePhotoCompanion(for: photo, alongside: url)
                showToast("已导出「\(url.lastPathComponent)」")
            } catch {
                showToast("导出失败：\(error.localizedDescription)")
            }
        }
    }

    func revealInFinder(_ photoID: UUID) {
        guard let photo = anyPhoto(id: photoID) else { return }
        if photo.isCloud {
            Task {
                guard let url = await cloudLocalFileURL(photo) else {
                    showToast("云端项目请使用「导出」保存到本地")
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([LibraryPaths.exportURL(for: photo)])
    }

    /// 在访达中显示多张照片（多选右键菜单使用）；云端项目需要先导出。
    func revealInFinder(ids: Set<UUID>) {
        let urls = ids.compactMap { anyPhoto(id: $0) }
            .filter { !$0.isCloud }
            .map { LibraryPaths.exportURL(for: $0) }
        guard !urls.isEmpty else {
            showToast("云端项目请使用「导出」保存到本地")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// SMB 已由系统挂载为本地文件系统，直接返回文件 URL；其它网盘返回 nil。
    func cloudLocalFileURL(_ photo: PhotoItem) async -> URL? {
        guard photo.isCloud,
              let mount = cloudMount(for: photo.cloudMountID), mount.kind == .smb,
              let client = SMBClient(mount: mount, password: cloudPassword(for: mount.id)),
              (try? await client.ensureMounted()) != nil else { return nil }
        return client.fileURL(path: photo.cloudPath ?? "")
    }

    func revealLibraryInFinder() {
        guard let library = LibraryPaths.containerLibraryURL else {
            showToast("请先创建或打开一个图库")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([library])
    }

    /// 用系统默认应用打开（SMB 可直接打开挂载文件，其它网盘走 App 内查看器）。
    func openInSystemApp(_ id: UUID) {
        guard let photo = anyPhoto(id: id) else { return }
        if photo.isCloud {
            Task {
                guard let url = await cloudLocalFileURL(photo) else {
                    showToast("云端项目请使用 App 内查看器打开")
                    openViewer(id)
                    return
                }
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(LibraryPaths.exportURL(for: photo))
    }

    /// 把照片设为桌面背景。
    func setAsDesktopBackground(_ id: UUID) {
        guard let photo = anyPhoto(id: id), !photo.isVideo else { return }
        if photo.isCloud {
            Task {
                let folder = LibraryPaths.applicationRoot
                    .appendingPathComponent("Wallpapers", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(photo.originalName)
                do {
                    try await downloadCloudItem(photo, to: target)
                } catch {
                    showToast("设置桌面失败：\(error.localizedDescription)")
                    return
                }
                applyDesktopImage(target)
            }
            return
        }
        let url = LibraryPaths.sourceURL(for: photo)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("找不到原始文件")
            return
        }
        applyDesktopImage(url)
    }

    private func applyDesktopImage(_ url: URL) {
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        showToast("已设为桌面背景")
    }

    /// 从访达双击 / 拖到 App 图标打开的图库。
    func handleOpenedLibrary(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              url.pathExtension.lowercased() == "photoslibrary" else { return }
        activateLibrary(url)
    }
}
