import Foundation
import AppKit
import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

extension LibraryStore {
    // MARK: - 缓存

    /// 目录总体积：纯文件系统遍历，故意做成 nonisolated，
    /// 让资源页这类「打开就要读数」的地方可以丢到后台算，不卡主线程。
    nonisolated static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// 画廊容器里拾光旁挂数据的体积；`container` 为空（当前不是系统图库）时为 0。
    nonisolated static func sidecarSize(in container: URL?) -> Int64 {
        guard let container else { return 0 }
        let fm = FileManager.default
        return LibraryPaths.sidecarArtifacts(in: container).reduce(Int64(0)) { total, url in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return total }
            if !isDirectory.boolValue {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return total + Int64(size)
            }
            guard let enumerator = fm.enumerator(at: url,
                                                 includingPropertiesForKeys: [.fileSizeKey]) else { return total }
            var sum = total
            for case let file as URL in enumerator {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                sum += Int64(size)
            }
            return sum
        }
    }

    func cloudThumbnailCacheSize() -> Int64 {
        Self.directorySize(at: LibraryPaths.cloudThumbs)
    }

    func clearCloudThumbnailCache() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: LibraryPaths.cloudThumbs,
                                                        includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
        cloudDirectoryCache.removeAll()
        ImageLoader.clearMemoryCaches()
        showToast("已清理网盘缩略图缓存")
    }

    func systemThumbnailCacheSize() -> Int64 {
        Self.directorySize(at: LibraryPaths.systemThumbs)
    }

    func clearSystemThumbnailCache() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: LibraryPaths.systemThumbs,
                                                        includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
        ImageLoader.clearMemoryCaches()
        showToast("已清理系统图库缩略图缓存")
    }

    // MARK: - 系统图库旁挂数据

    /// 当前打开的图库就是官方「照片」图库时，拾光写进该图库包内的数据体积。
    func systemLibrarySidecarSize() -> Int64 {
        guard isNativeContainer else { return 0 }
        return Self.sidecarSize(in: LibraryPaths.containerLibraryURL)
    }

    /// 销毁拾光写进当前系统图库容器的全部旁挂数据，并把这个系统图库重新载入。
    /// 只删拾光自己的数据库 / 索引 / 缩略图 / 缓存；Apple 的 `Photos.sqlite`、`originals`、
    /// `resources/derivatives`、`resources/renders` 一律不动。
    func destroySystemLibrarySidecar() {
        guard let container = LibraryPaths.containerLibraryURL, isNativeContainer else {
            showToast("当前打开的不是系统「照片」图库")
            return
        }
        // 先让正在进行的扫描 / 索引写入作废，避免删完又被后台任务写回来。
        systemLoadToken &+= 1
        systemAnalysisTask?.cancel()
        systemAnalysisTask = nil
        // 关掉 SQLite 连接后再删文件，否则 WAL 里的内容会继续写进已删除的 inode。
        flushMetadata()
        metadataStore = nil
        let fm = FileManager.default
        for url in LibraryPaths.sidecarArtifacts(in: container) {
            try? fm.removeItem(at: url)
        }
        libraryIndexTask?.cancel()
        libraryIndexTask = nil
        libraryIndexComplete = true
        metadataStore = try? MetadataStore(url: LibraryPaths.metadataFile)
        resetFaceClusterState()
        let data = metadataStore?.loadLibrary() ?? LibraryData()
        photos = data.photos
        albums = data.albums
        folders = data.folders
        loadSmartAlbums()
        loadPinnedItems()
        loadAnalysisIndex()
        resetCloudStateForLibrarySwitch()
        resetSystemLibraryState()
        systemLibraryPath = container.path
        systemLibraryName = container.deletingPathExtension().lastPathComponent
        metadataStore?.setSetting("system_library_path", container.path)
        reloadPerLibraryState()
        ImageLoader.clearMemoryCaches()
        loadSystemLibrary(at: container, informOnFailure: true)
        navigate(to: .systemLibrary)
        showToast("已销毁拾光在该系统图库写入的全部数据")
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
