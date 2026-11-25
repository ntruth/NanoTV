import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreImage

enum LibraryPaths {
    /// 应用自己的数据目录：设置、已下载模型、索引缓存与旧版本地库都放这里。
    /// 旧版本用的是另一个目录名，首次启动时整体搬过来，用户不会丢设置与模型。
    static let applicationRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("Luma", isDirectory: true)
        migrateLegacyApplicationRoot(in: base, to: root)
        return root
    }()

    /// 旧目录与新目录只差名字：新目录不存在时，把带启动引导或模型目录的旧目录整体搬过来。
    /// 只认这两种标志，避免误搬其他 App 在 Application Support 里的文件夹。
    private static func migrateLegacyApplicationRoot(in base: URL, to root: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path),
              let entries = try? fm.contentsOfDirectory(at: base,
                                                        includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries where entry.standardizedFileURL != root.standardizedFileURL {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let hasBootstrap = fm.fileExists(atPath: entry.appendingPathComponent("ContainerPath.txt").path)
            let hasModels = fm.fileExists(atPath: entry.appendingPathComponent("Models").path)
            guard hasBootstrap || hasModels else { continue }
            try? fm.moveItem(at: entry, to: root)
            return
        }
    }

    private static let bootstrapFile = applicationRoot.appendingPathComponent("ContainerPath.txt")

    /// 用户设置的默认图库：启动时优先打开它（按住 Option 仍会先弹出图库选择器）。
    static let defaultLibraryKey = "settings.defaultLibraryPath.v1"
    /// 只有用户主动点过「设为默认图库」才置位；旧版本自动挑出来的默认值不改变启动行为。
    static let defaultLibraryExplicitKey = "settings.defaultLibraryExplicit.v1"

    /// 读取用户显式设置的默认图库；路径已失效时退回「上次打开的图库」。
    static func storedDefaultLibrary() -> URL? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: defaultLibraryExplicitKey),
              let path = defaults.string(forKey: defaultLibraryKey) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard isLibraryContainer(url) else { return nil }
        return url
    }

    static func setStoredDefaultLibrary(_ url: URL) {
        let path = url.standardizedFileURL.path
        UserDefaults.standard.set(path, forKey: defaultLibraryKey)
        UserDefaults.standard.set(true, forKey: defaultLibraryExplicitKey)
    }

    /// 上次打开的图库（启动引导文件），仍然存在才算。
    /// 没有显式默认时，下次启动打开的就是它——界面上的「默认」标记也以它为准。
    static func lastOpenedLibraryURL() -> URL? {
        guard let path = storedLastOpenedPath() else { return nil }
        let url = URL(fileURLWithPath: path)
        return isLibraryContainer(url) ? url : nil
    }

    /// 启动引导里记录的图库路径（不校验是否仍然存在）。断开图库时要按原始路径清理，
    /// 否则失效的图库重新插上后还会被启动引导拉回来。
    static func storedLastOpenedPath() -> String? {
        guard let stored = readBootstrap(), stored != "local" else { return nil }
        return URL(fileURLWithPath: stored).standardizedFileURL.path
    }

    /// 「全部图库」与「最近打开」的全局持久化键。
    static let knownLibrariesKey = "settings.knownLibraries.v1"
    static let recentLibrariesKey = "settings.recentLibraries"

    private(set) static var containerLibraryURL: URL?
    private(set) static var root: URL = applicationRoot

    /// 拾光写进图库的所有旁挂数据都收在这个目录里：
    /// 图库根目录只保留 Apple 自己的结构（database / originals / resources / private / scopes …）。
    /// 尚未选择图库时 `root` 就是应用支持目录，此时直接用它，不再多套一层 `Luma/`。
    static var overlayRoot: URL { overlayDir(in: root) }

    /// 某个图库的旁挂数据目录；应用支持目录本身（无图库）不再嵌套 `Luma/`。
    private static func overlayDir(in library: URL) -> URL {
        library.standardizedFileURL == applicationRoot.standardizedFileURL
            ? applicationRoot
            : library.appendingPathComponent("Luma", isDirectory: true)
    }

    static var databaseDir: URL { overlayRoot.appendingPathComponent("database", isDirectory: true) }
    static var originals: URL { overlayRoot.appendingPathComponent("originals", isDirectory: true) }
    static var derivatives: URL { overlayRoot.appendingPathComponent("resources/derivatives", isDirectory: true) }
    static var edited: URL { overlayRoot.appendingPathComponent("resources/renders", isDirectory: true) }
    static var transcodes: URL { overlayRoot.appendingPathComponent("resources/transcodes", isDirectory: true) }
    static var backups: URL { overlayRoot.appendingPathComponent("resources/backups", isDirectory: true) }
    /// 用户保存的编辑预设：跟着图库走，换库不串。
    static var presetsFile: URL { overlayRoot.appendingPathComponent("resources/presets.json") }
    /// 导入的 3D LUT：复制到库内，配方里只存相对文件名，搬库不丢。
    static var lutsDir: URL { overlayRoot.appendingPathComponent("resources/luts", isDirectory: true) }
    static var cloud: URL { overlayRoot.appendingPathComponent("cloud", isDirectory: true) }
    static var cloudThumbs: URL { cloud.appendingPathComponent("thumbs", isDirectory: true) }
    /// 网络资源的图库级配置：源、续看、收藏、片单、更新日历都写在当前图库里。
    /// 换图库时不加载上一个库的配置。
    static var catalogDir: URL { overlayRoot.appendingPathComponent("resources/catalog", isDirectory: true) }
    /// 网络电视：源、频道缓存与开关都写在这个库自己的 SQLite 里。
    static var tvDir: URL { overlayRoot.appendingPathComponent("resources/tv", isDirectory: true) }
    static var tvDatabaseFile: URL { tvDir.appendingPathComponent("Television.sqlite") }
    /// 本地导入的 M3U：复制进图库再登记，原文件被移动或删除都不影响播放。
    static var tvPlaylistsDir: URL { tvDir.appendingPathComponent("playlists", isDirectory: true) }
    /// 网络电视的台标 / 预览图缓存。
    static var tvLogosDir: URL { overlayRoot.appendingPathComponent("tv-logos", isDirectory: true) }
    static var tvPreviewsDir: URL { overlayRoot.appendingPathComponent("tv-previews", isDirectory: true) }
    /// 网络源内容快照：换图库后快照跟着换。
    static var sourceSnapshotsDir: URL { overlayRoot.appendingPathComponent("source-snapshots", isDirectory: true) }
    /// 系统图库缩略图缓存：同样放本机，避免为每个格子往图库所在（可能很慢的）磁盘写文件。
    /// 官方 derivative 仍然直接复用，这里只存按格子尺寸生成的小图。
    static var systemThumbs: URL {
        applicationRoot.appendingPathComponent("resources/system-thumbs", isDirectory: true)
    }
    /// 官方「照片」图库自己生成好的 derivative 目录（缩略图与视频封面帧）。
    /// 直接复用这些 JPEG，可以避免为每个格子解码 HEIC / RAW / 视频原文件。
    static func systemDerivatives(libraryURL: URL) -> URL {
        libraryURL.appendingPathComponent("resources/derivatives", isDirectory: true)
    }

    /// 官方 derivative 的路径规则：`resources/derivatives/<UUID 首字符>/<UUID>_1_105_c.jpeg`。
    /// 视频没有 `_1_105_c`，官方只保留一张 `_1_102_o.jpeg` 封面帧。
    /// 共享相簿（scopes/cloudsharing）的项目不在库根 derivatives 下：
    /// 图片只有一张 500px 级别的 `_4_5005_c`，视频优先用本机已缓存的 `poster.JPG`。
    static func systemDerivativePath(libraryURL: URL, assetID: UUID, isVideo: Bool,
                                     directory: String? = nil) -> String {
        let key = assetID.uuidString
        if let directory, directory.contains("/") {
            let scoped = libraryURL.appendingPathComponent("scopes/cloudsharing", isDirectory: true)
            if isVideo {
                let poster = scoped.appendingPathComponent("data/\(directory)/\(key).poster.JPG")
                if FileManager.default.fileExists(atPath: poster.path) {
                    return poster.path
                }
            }
            return scoped
                .appendingPathComponent("resources/derivatives/masters", isDirectory: true)
                .appendingPathComponent(String(key.prefix(1)), isDirectory: true)
                .appendingPathComponent("\(key)_4_5005_c.jpeg")
                .path
        }
        let directory = systemDerivatives(libraryURL: libraryURL)
            .appendingPathComponent(String(key.prefix(1)), isDirectory: true)
        let name = isVideo ? "\(key)_1_102_o.jpeg" : "\(key)_1_105_c.jpeg"
        return directory.appendingPathComponent(name).path
    }
    /// 系统「照片」图库的扫描结果缓存（仅索引与元数据，不含原图），同样写进当前图库。
    static var systemLibraryCacheDir: URL {
        overlayRoot.appendingPathComponent("resources/system-cache", isDirectory: true)
    }
    /// 原生图库导入的去重账本：源文件 SHA-256 → 已写入的系统资产标识。
    /// 只记录拾光自己写进去的项目，不解读 Photos 自己的数据库。
    static var systemImportManifest: URL {
        systemLibraryCacheDir.appendingPathComponent("import-manifest.json", isDirectory: false)
    }

    /// 索引库固定写在本机应用目录，而不是图库所在磁盘：
    /// 系统图库常在外置盘上，边读几十 GB 的 Photos.sqlite 边把索引写回同一块盘，
    /// 会退化成随机读写，构建和翻页都会慢到不可用。
    static var systemIndexCacheDir: URL {
        applicationRoot.appendingPathComponent("resources/system-index", isDirectory: true)
    }

    /// 系统图库的只读索引库：百万级图库不再把整库装进内存，网格与计数按窗口查询它。
    /// 按系统图库路径哈希命名，同一 App 图库可缓存多个系统图库的索引。
    static func systemIndexFile(for libraryURL: URL) -> URL? {
        guard root != applicationRoot || containerLibraryURL != nil else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in libraryURL.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return systemIndexCacheDir
            .appendingPathComponent("SystemIndex-\(String(hash, radix: 16)).sqlite")
    }
    /// 应用自己的元数据库文件名：放在图库内 `Luma/database/` 下，与 Apple 的结构分开。
    static let metadataFileName = "Luma.sqlite"
    static var metadataFile: URL { databaseDir.appendingPathComponent(metadataFileName) }

    /// 指定图库的元数据库路径（用于「全部图库」等跨库只读统计）。
    static func metadataFile(in library: URL) -> URL {
        library.appendingPathComponent("Luma/database", isDirectory: true)
            .appendingPathComponent(metadataFileName)
    }

    /// 跨库只读时优先用新布局；旧版图库还没被打开过时退回旧位置与旧文件名。
    static func existingMetadataFile(in library: URL) -> URL? {
        let fm = FileManager.default
        let candidates = [
            metadataFile(in: library),
            library.appendingPathComponent("database", isDirectory: true)
                .appendingPathComponent(metadataFileName)
        ]
        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        // 更早的图库可能还在用旧文件名：只看 database/ 里除 Apple 的 Photos.sqlite 之外的 sqlite。
        return legacyDatabaseFile(in: library.appendingPathComponent("database", isDirectory: true))
    }

    static var libraryFile: URL { applicationRoot.appendingPathComponent("Library.json") }

    /// 拾光写进某个图库容器的旁挂数据：叠加元数据库、索引 / 快照缓存、缩略图与转码缓存。
    /// 全部位于图库内 `Luma/` 下，刻意不包含 Apple 自己的 `Photos.sqlite`、`originals`、`resources/derivatives`、`resources/renders`。
    static func sidecarArtifacts(in library: URL) -> [URL] {
        let overlay = library.appendingPathComponent("Luma", isDirectory: true)
        let database = overlay.appendingPathComponent("database", isDirectory: true)
        let resources = overlay.appendingPathComponent("resources", isDirectory: true)
        return [
            database.appendingPathComponent(metadataFileName),
            database.appendingPathComponent(metadataFileName + "-wal"),
            database.appendingPathComponent(metadataFileName + "-shm"),
            resources.appendingPathComponent("system-cache", isDirectory: true),
            resources.appendingPathComponent("transcodes", isDirectory: true),
            resources.appendingPathComponent("backups", isDirectory: true),
            resources.appendingPathComponent("catalog", isDirectory: true),
            resources.appendingPathComponent("tv", isDirectory: true),
            overlay.appendingPathComponent("cloud", isDirectory: true),
            overlay.appendingPathComponent("tv-logos", isDirectory: true),
            overlay.appendingPathComponent("tv-previews", isDirectory: true),
            overlay.appendingPathComponent("source-snapshots", isDirectory: true),
            legacySidecarPath(for: library)
        ]
    }

    private static var legacyOriginals: URL { applicationRoot.appendingPathComponent("Originals", isDirectory: true) }
    private static var legacyThumbs: URL { applicationRoot.appendingPathComponent("Thumbnails", isDirectory: true) }
    private static var legacyEdited: URL { applicationRoot.appendingPathComponent("Edited", isDirectory: true) }

    /// 拾光写进图库的旁挂数据统一收在图库内 `Luma/` 目录：
    /// 图库根目录只保留 Apple 自己的结构（database / originals / resources / private / scopes …）。
    /// 旧版（lijialong 包标识时期）的旁挂目录名，仅为升级迁移保留，不能改动。
    private static let legacySidecarSubdirectory = "com.lijialong.photosclone"

    /// 旧版把数据放在 `private/com.lijialong.photosclone/`，升级后上移到包内 `Luma/`。
    static func legacySidecarPath(for library: URL) -> URL {
        library.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent(legacySidecarSubdirectory, isDirectory: true)
    }

    /// `database/` 里除 Apple 的 `Photos.sqlite` 之外的 sqlite 文件：旧版本的应用元数据库。
    private static func legacyDatabaseFile(in directory: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return nil }
        return entries.first {
            $0.pathExtension.lowercased() == "sqlite"
                && $0.lastPathComponent != "Photos.sqlite"
                && $0.lastPathComponent != metadataFileName
        }
    }

    /// 旧版本的应用元数据库文件名不同：把主文件与 WAL / SHM 一起改名为当前文件名（幂等，只做一次）。
    static func migrateMetadataFileIfNeeded(in library: URL) {
        let fm = FileManager.default
        let directory = library.appendingPathComponent("database", isDirectory: true)
        guard fm.fileExists(atPath: directory.path),
              !fm.fileExists(atPath: directory.appendingPathComponent(metadataFileName).path),
              let legacy = legacyDatabaseFile(in: directory) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = directory.appendingPathComponent(legacy.lastPathComponent + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.moveItem(at: source,
                             to: directory.appendingPathComponent(metadataFileName + suffix))
        }
    }

    /// 旧版把旁挂数据直接摊在图库根目录；新布局统一收进图库内 `Luma/`。
    /// 幂等：目标已存在时只做合并，已迁移过的图库不会被重复搬动。
    static func migrateOverlayLayoutIfNeeded(at library: URL) {
        // 没有图库时 root 就是应用支持目录，旧数据由 migrateLegacyLayoutIfNeeded 处理。
        guard library.standardizedFileURL != applicationRoot.standardizedFileURL else { return }
        let fm = FileManager.default
        let overlay = library.appendingPathComponent("Luma", isDirectory: true)
        let native = isNativeLibrary(library)

        func move(_ source: URL, to destination: URL) {
            guard fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: destination.path) else { return }
            try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.moveItem(at: source, to: destination)
        }

        func moveOrMerge(_ source: URL, to destination: URL) {
            guard fm.fileExists(atPath: source.path) else { return }
            if !fm.fileExists(atPath: destination.path) {
                move(source, to: destination)
            } else {
                mergeDirectory(source, into: destination)
                pruneEmptyDirectories(source)
            }
        }

        // 元数据库：先把旧文件名改好，再整体搬进 Luma/database。
        migrateMetadataFileIfNeeded(in: library)
        let oldDatabase = library.appendingPathComponent("database", isDirectory: true)
        let overlayDatabase = overlay.appendingPathComponent("database", isDirectory: true)
        for suffix in ["", "-wal", "-shm"] {
            move(oldDatabase.appendingPathComponent(metadataFileName + suffix),
                 to: overlayDatabase.appendingPathComponent(metadataFileName + suffix))
        }

        let overlayResources = overlay.appendingPathComponent("resources", isDirectory: true)
        if !native {
            // 自建图库的 originals / resources 全部属于拾光，整目录搬走。
            moveOrMerge(library.appendingPathComponent("originals", isDirectory: true),
                        to: overlay.appendingPathComponent("originals", isDirectory: true))
            moveOrMerge(library.appendingPathComponent("resources", isDirectory: true),
                        to: overlayResources)
        } else {
            // 官方图库的 originals / derivatives / renders 属于 Apple，只搬拾光自己的资源。
            let oldResources = library.appendingPathComponent("resources", isDirectory: true)
            for name in ["transcodes", "backups", "luts", "catalog", "tv", "system-cache"] {
                moveOrMerge(oldResources.appendingPathComponent(name, isDirectory: true),
                            to: overlayResources.appendingPathComponent(name, isDirectory: true))
            }
            move(oldResources.appendingPathComponent("presets.json"),
                 to: overlayResources.appendingPathComponent("presets.json"))
        }

        for name in ["cloud", "catalog", "tv-logos", "tv-previews", "source-snapshots"] {
            moveOrMerge(library.appendingPathComponent(name, isDirectory: true),
                        to: overlay.appendingPathComponent(name, isDirectory: true))
        }

        // 自建图库搬空后的 Apple 风格空目录：能删就删，根目录更干净。
        if !native {
            for name in ["database", "originals", "resources"] {
                let directory = library.appendingPathComponent(name, isDirectory: true)
                if (try? fm.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                    try? fm.removeItem(at: directory)
                }
            }
        }
    }

    /// 更早版本的数据上移到图库内 `Luma/`（幂等，只移动一次）。
    static func migrateSidecarToLibraryRootIfNeeded(at library: URL) {
        let fm = FileManager.default
        let legacy = legacySidecarPath(for: library)
        guard fm.fileExists(atPath: legacy.path) else { return }
        prepareLibraryStructure(at: library)
        let overlay = overlayDir(in: library)
        // 数据库单独处理：绝不能把旧库的 -wal / -shm 搬进当前库目录，
        // 否则 SQLite 会把别的库的日志当成当前库的日志回放，直接覆盖掉现有数据。
        migrateLegacyDatabase(from: legacy.appendingPathComponent("database", isDirectory: true),
                              to: overlay.appendingPathComponent("database", isDirectory: true))
        for name in ["originals", "resources", "cloud"] {
            let source = legacy.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            mergeDirectory(source, into: overlay.appendingPathComponent(name, isDirectory: true))
            pruneEmptyDirectories(source)
        }
        if pruneEmptyDirectories(legacy) {
            pruneEmptyDirectories(library.appendingPathComponent("private", isDirectory: true))
        }
    }

    /// 旧库数据库迁移：只有目标库还没有当前元数据库时才搬；
    /// 先把旧库的三件套复制到临时目录、让 SQLite 自己合并 WAL，再只把主文件搬过去。
    private static func migrateLegacyDatabase(from sourceDir: URL, to destinationDir: URL) {
        let fm = FileManager.default
        let destination = destinationDir.appendingPathComponent(metadataFileName)
        guard !fm.fileExists(atPath: destination.path),
              let legacy = legacyDatabaseFile(in: sourceDir) else { return }

        let temp = fm.temporaryDirectory.appendingPathComponent("LumaLegacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let staged = temp.appendingPathComponent(metadataFileName)
        guard (try? fm.copyItem(at: legacy, to: staged)) != nil else { return }
        for suffix in ["-wal", "-shm"] {
            let file = sourceDir.appendingPathComponent(legacy.lastPathComponent + suffix)
            guard fm.fileExists(atPath: file.path) else { continue }
            try? fm.copyItem(at: file, to: temp.appendingPathComponent(metadataFileName + suffix))
        }
        // 在临时目录里打开一次，把旧库 WAL 里的已提交内容合并进主文件。
        if let db = try? SQLiteDatabase(path: staged.path, readonly: false) {
            _ = try? db.query("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        guard !fm.fileExists(atPath: destination.path) else { return }
        try? fm.moveItem(at: staged, to: destination)
    }

    /// 自底向上删除空目录；返回该目录最终是否已被删除。
    @discardableResult
    private static func pruneEmptyDirectories(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: []) else { return false }
        for entry in entries {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                pruneEmptyDirectories(entry)
            }
        }
        let remaining = (try? fm.contentsOfDirectory(atPath: url.path)) ?? ["?"]
        guard remaining.isEmpty else { return false }
        try? fm.removeItem(at: url)
        return true
    }

    /// 递归合并目录：目标不存在则移动，存在则继续向下合并；同名文件以目标为准。
    private static func mergeDirectory(_ source: URL, into destination: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: source,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: []) else { return }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                mergeDirectory(entry, into: target)
            } else if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: entry, to: target)
            }
        }
    }

    static func isOfficialLibrary(_ url: URL) -> Bool {
        isNativeLibrary(url)
    }

    /// 由官方「照片」创建的原生图库：带 Apple 的 Photos.sqlite。
    /// 结论不会在运行期变化，缓存起来：外置盘上一次 lstat 可能阻塞几秒，
    /// 而 SwiftUI body / 查询会高频访问这里，不能每次都碰磁盘。
    static func isNativeLibrary(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "photoslibrary" else { return false }
        let key = url.standardizedFileURL.path
        nativeLock.lock()
        if let cached = nativeCache[key] {
            nativeLock.unlock()
            return cached
        }
        nativeLock.unlock()
        let value = FileManager.default.fileExists(
            atPath: url.appendingPathComponent("database/Photos.sqlite").path)
        nativeLock.lock()
        nativeCache[key] = value
        nativeLock.unlock()
        return value
    }

    private static let nativeLock = NSLock()
    private static var nativeCache: [String: Bool] = [:]

    /// 外置盘插拔后，之前缓存的「不是官方库」结论必须作废：
    /// 盘没插时判断过一次，插回来不能还按 App 图库对待。
    static func invalidateNativeCache() {
        nativeLock.lock()
        nativeCache.removeAll()
        nativeLock.unlock()
    }

    private static var volumeObservers: [NSObjectProtocol] = []

    /// 监听卷挂载 / 卸载，清掉官方库判断的缓存。幂等，重复调用不会重复注册。
    static func observeVolumeChanges() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                invalidateNativeCache()
            })
        }
    }

    /// 任何 .photoslibrary 包（原生库或本 App 创建的库）都可作为容器。
    static func isLibraryContainer(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "photoslibrary" else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// 创建与官方同款的 .photoslibrary 包结构，并建立旁挂元数据目录。
    static func createLibrary(at library: URL) -> Bool {
        guard library.pathExtension.lowercased() == "photoslibrary" else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: library.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: library.path)) ?? []
            guard contents.isEmpty else { return false }
        }
        prepareLibraryStructure(at: library)
        return fm.fileExists(atPath: library.appendingPathComponent("Luma/database").path)
    }

    /// 读取启动配置：如果用户已经选择了 .photoslibrary，本地媒体与元数据都放进库内旁挂目录。
    /// 没有图库时不再在固定位置自动建库，只保留旧的本地库数据等待用户迁入新图库。
    static func configure() {
        let stored = readBootstrap()
        var library: URL?
        // 设过默认图库时优先进入它；目录被移走则照旧用上次打开的图库。
        if let preferred = storedDefaultLibrary() {
            library = preferred
        } else if let stored, stored != "local" {
            library = URL(fileURLWithPath: stored)
        } else if stored == nil, let legacy = readLegacySystemLibraryPath() {
            library = URL(fileURLWithPath: legacy)
        }

        // 上次打开的图库已经不在（外置盘没插 / 目录被删）：
        // 不再悄悄换一个已知图库打开——各图库互不串用，交给启动时的
        // 「创建或打开图库」界面，让用户自己挑选真正想打开的那个库。
        if let current = library, !isLibraryContainer(current) {
            library = nil
        }

        if let library, isLibraryContainer(library) {
            containerLibraryURL = library
            root = library
            migrateSidecarToLibraryRootIfNeeded(at: library)
            prepare()
            migrateLegacyLayoutIfNeeded()
            writeBootstrap(library.path)
        } else {
            containerLibraryURL = nil
            root = applicationRoot
            if hasLocalLibraryData {
                prepare()
                migrateLegacyLayoutIfNeeded()
            }
        }
        observeVolumeChanges()
    }

    /// 断开当前图库：释放容器路径并清掉启动引导，下次启动直接进入
    /// 「创建或打开图库」界面。磁盘上的图库文件不受影响。
    static func detach() {
        containerLibraryURL = nil
        root = applicationRoot
        invalidateNativeCache()
        clearBootstrap()
    }

    /// 清掉「上次打开的图库」引导文件。
    static func clearBootstrap() {
        try? FileManager.default.removeItem(at: bootstrapFile)
    }

    /// 尚未选择任何图库，启动后必须先新建或打开一个图库。
    static var requiresLibrarySetup: Bool { containerLibraryURL == nil }

    /// Application Support 里是否还残留旧版（没有图库包）的本地库数据。
    static var hasLocalLibraryData: Bool {
        let fm = FileManager.default
        let candidates = [
            applicationRoot.appendingPathComponent("originals").path,
            applicationRoot.appendingPathComponent("Originals").path
        ]
        if candidates.contains(where: { fm.fileExists(atPath: $0) }) { return true }
        // 旧版把元数据库平铺在应用支持目录或其 database/ 下：文件名可能不同，只认 sqlite 扩展名。
        for directory in [applicationRoot, applicationRoot.appendingPathComponent("database", isDirectory: true)] {
            guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: nil) else { continue }
            if entries.contains(where: { $0.pathExtension.lowercased() == "sqlite" }) { return true }
        }
        return false
    }

    static func prepare() {
        for dir in [root, overlayRoot, databaseDir, originals, derivatives, edited, transcodes, backups,
                    cloudThumbs, systemThumbs, systemLibraryCacheDir, catalogDir, tvDir,
                    tvLogosDir, tvPreviewsDir, sourceSnapshotsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        migrateOverlayLayoutIfNeeded(at: root)
    }

    static func thumbnailURL(for photo: PhotoItem) -> URL {
        if photo.isSystem {
            if let derivative = photo.systemThumbnailPath,
               FileManager.default.fileExists(atPath: derivative) {
                return URL(fileURLWithPath: derivative)
            }
            return systemThumbs.appendingPathComponent(photo.id.uuidString + ".jpg")
        }
        return derivatives
            .appendingPathComponent(shard(for: photo.id), isDirectory: true)
            .appendingPathComponent(photo.id.uuidString + "_1_105_c.jpeg", isDirectory: false)
    }

    /// 网格快速层缩略图（约 192px）：独立小文件，滚动时秒开，缺失时按需生成。
    static func quickThumbnailURL(for photo: PhotoItem) -> URL {
        if photo.isSystem {
            return systemThumbs.appendingPathComponent(photo.id.uuidString + "_q.jpg", isDirectory: false)
        }
        return derivatives
            .appendingPathComponent(shard(for: photo.id), isDirectory: true)
            .appendingPathComponent(photo.id.uuidString + "_q.jpg", isDirectory: false)
    }

    static func sourceURL(for photo: PhotoItem) -> URL {
        if let externalPath = photo.externalPath, !externalPath.isEmpty {
            return URL(fileURLWithPath: externalPath)
        }
        if photo.isSystem, let path = photo.systemOriginalPath {
            return URL(fileURLWithPath: path)
        }
        if let editedFilename = photo.editedFilename {
            return edited.appendingPathComponent(editedFilename, isDirectory: false)
        }
        return originalURL(for: photo)
    }

    /// 注意：单参数的 `appendingPathComponent` 会为了判断目录去 lstat，
    /// 图库常在外置盘上，这条路径每次打开预览都会被调用，必须显式给 isDirectory。
    static func originalURL(for photo: PhotoItem) -> URL {
        originals
            .appendingPathComponent(shard(for: photo.id), isDirectory: true)
            .appendingPathComponent(photo.filename, isDirectory: false)
    }

    static func exportURL(for photo: PhotoItem) -> URL {
        if photo.isSystem, let path = photo.systemOriginalPath {
            return URL(fileURLWithPath: path)
        }
        if let editedFilename = photo.editedFilename {
            return edited.appendingPathComponent(editedFilename, isDirectory: false)
        }
        return originalURL(for: photo)
    }

    /// 实况照片的配对视频路径（本地库或系统图库）。
    static func livePhotoURL(for photo: PhotoItem) -> URL? {
        if let path = photo.livePhotoVideoPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard let filename = photo.livePhotoFilename, !filename.isEmpty else { return nil }
        return originals
            .appendingPathComponent(shard(for: photo.id), isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    static func shard(for id: UUID) -> String {
        String(id.uuidString.prefix(1))
    }

    static func shard(forFilename filename: String) -> String {
        String(filename.prefix(1))
    }

    /// 切换容器。migratingLocalData 为 true 时把当前本地库迁入新图库的旁挂目录；
    /// 新建空图库时传 false，避免把旧库内容带进新库。
    @discardableResult
    static func switchContainer(to library: URL, migratingLocalData: Bool = true) -> Bool {
        guard isLibraryContainer(library) else { return false }
        prepareLibraryStructure(at: library)
        migrateSidecarToLibraryRootIfNeeded(at: library)
        // 只读 / 无权限的卷上切换会「成功」但之后所有写入静默失败，这里直接拒绝。
        guard FileManager.default.isWritableFile(atPath: databaseDir(for: library).path) else {
            return false
        }
        let newRoot = library
        if newRoot.standardizedFileURL.path == root.standardizedFileURL.path {
            containerLibraryURL = library
            writeBootstrap(library.path)
            return true
        }

        let oldRoot = root
        let newDatabase = metadataFile(in: newRoot)
        let needsMigration = !FileManager.default.fileExists(atPath: newDatabase.path)

        root = newRoot
        containerLibraryURL = library
        prepare()

        if needsMigration, migratingLocalData {
            // 先搬最早期的平铺目录，再搬当前的分片目录（originals / resources / database）。
            migrateLegacyLayoutIfNeeded()
            copyShardedContents(from: oldRoot, to: newRoot)
        }

        writeBootstrap(library.path)
        return true
    }

    /// 异步版切换：迁移旧图库内容（逐个文件硬链接 / 复制）放到后台线程，
    /// 几十 GB 图库也不会把主线程卡住。其余步骤与同步版一致。
    @discardableResult
    static func switchContainerAsync(to library: URL, migratingLocalData: Bool = false) async -> Bool {
        guard isLibraryContainer(library) else { return false }
        prepareLibraryStructure(at: library)
        migrateSidecarToLibraryRootIfNeeded(at: library)
        guard FileManager.default.isWritableFile(atPath: databaseDir(for: library).path) else {
            return false
        }
        let newRoot = library
        if newRoot.standardizedFileURL.path == root.standardizedFileURL.path {
            containerLibraryURL = library
            writeBootstrap(library.path)
            return true
        }

        let oldRoot = root
        let newDatabase = metadataFile(in: newRoot)
        let needsMigration = !FileManager.default.fileExists(atPath: newDatabase.path)

        root = newRoot
        containerLibraryURL = library
        prepare()

        if needsMigration, migratingLocalData {
            // 旧版平铺目录只涉及本机小目录，先同步搬完；大块内容交给后台。
            migrateLegacyLayoutIfNeeded()
            await Task.detached(priority: .userInitiated) {
                copyShardedContents(from: oldRoot, to: newRoot)
            }.value
        }

        writeBootstrap(library.path)
        return true
    }

    /// 某个图库自己的元数据库目录（用于切换前检查可写性）。
    private static func databaseDir(for library: URL) -> URL {
        library.appendingPathComponent("Luma/database", isDirectory: true)
    }

    /// 确保图库内具备 `Luma/` 旁挂目录；Apple 自己的目录一律不动。
    static func prepareLibraryStructure(at library: URL) {
        migrateOverlayLayoutIfNeeded(at: library)
        let overlay = overlayDir(in: library)
        let directories = [
            overlay,
            overlay.appendingPathComponent("database", isDirectory: true),
            overlay.appendingPathComponent("originals", isDirectory: true),
            overlay.appendingPathComponent("resources/derivatives", isDirectory: true),
            overlay.appendingPathComponent("resources/renders", isDirectory: true),
            overlay.appendingPathComponent("resources/transcodes", isDirectory: true),
            overlay.appendingPathComponent("resources/backups", isDirectory: true),
            overlay.appendingPathComponent("resources/luts", isDirectory: true),
            overlay.appendingPathComponent("resources/catalog", isDirectory: true),
            overlay.appendingPathComponent("resources/tv", isDirectory: true),
            overlay.appendingPathComponent("resources/system-cache", isDirectory: true),
            overlay.appendingPathComponent("cloud/thumbs", isDirectory: true),
            overlay.appendingPathComponent("tv-logos", isDirectory: true),
            overlay.appendingPathComponent("tv-previews", isDirectory: true),
            overlay.appendingPathComponent("source-snapshots", isDirectory: true)
        ]
        for directory in directories {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func openContainerInPhotos() {
        guard let containerLibraryURL else { return }
        NSWorkspace.shared.open(containerLibraryURL)
    }

    // MARK: - Migration

    private static func migrateLegacyLayoutIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: metadataFile.path) else { return }
        // 旧版把元数据库平铺在应用支持目录下：文件名可能不同，只认 sqlite 扩展名。
        guard let entries = try? fm.contentsOfDirectory(at: applicationRoot,
                                                        includingPropertiesForKeys: nil),
              let legacyDatabase = entries.first(where: { $0.pathExtension.lowercased() == "sqlite" })
        else { return }

        prepare()
        linkDirectory(legacyOriginals) { filename in
            originals
                .appendingPathComponent(shard(forFilename: filename), isDirectory: true)
                .appendingPathComponent(filename)
        }
        linkDirectory(legacyThumbs) { filename in
            let base = (filename as NSString).deletingPathExtension
            return derivatives
                .appendingPathComponent(shard(forFilename: base), isDirectory: true)
                .appendingPathComponent(base + "_1_105_c.jpeg")
        }
        linkDirectory(legacyEdited) { filename in
            edited.appendingPathComponent(filename)
        }

        for suffix in ["", "-wal", "-shm"] {
            let source = applicationRoot.appendingPathComponent(legacyDatabase.lastPathComponent + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = databaseDir.appendingPathComponent(metadataFileName + suffix)
            if !fm.fileExists(atPath: destination.path) {
                try? fm.copyItem(at: source, to: destination)
            }
        }
        writeBootstrap(containerLibraryURL?.path ?? "local")
    }

    private static func copyShardedContents(from oldRoot: URL, to newRoot: URL) {
        let fm = FileManager.default
        migrateOverlayLayoutIfNeeded(at: oldRoot)
        migrateOverlayLayoutIfNeeded(at: newRoot)
        let oldOverlay = overlayDir(in: oldRoot)
        let newOverlay = overlayDir(in: newRoot)
        for (sourceDir, destinationDir) in [
            (oldOverlay.appendingPathComponent("originals"),
             newOverlay.appendingPathComponent("originals")),
            (oldOverlay.appendingPathComponent("resources/derivatives"),
             newOverlay.appendingPathComponent("resources/derivatives")),
            (oldOverlay.appendingPathComponent("resources/renders"),
             newOverlay.appendingPathComponent("resources/renders"))
        ] {
            guard let enumerator = fm.enumerator(at: sourceDir,
                                                 includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator {
                let relative = file.path.replacingOccurrences(of: sourceDir.path + "/", with: "")
                let destination = destinationDir.appendingPathComponent(relative)
                linkOrCopy(file, destination)
            }
        }
        for suffix in ["", "-wal", "-shm"] {
            let source = oldOverlay.appendingPathComponent("database")
                .appendingPathComponent(metadataFileName + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = newOverlay.appendingPathComponent("database")
                .appendingPathComponent(metadataFileName + suffix)
            if !fm.fileExists(atPath: destination.path) {
                try? fm.copyItem(at: source, to: destination)
            }
        }
    }

    private static func linkDirectory(_ sourceDir: URL, destination: (String) -> URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sourceDir,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        for file in files {
            guard !file.hasDirectoryPath else { continue }
            linkOrCopy(file, destination(file.lastPathComponent))
        }
    }

    private static func linkOrCopy(_ source: URL, _ destination: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        do {
            try fm.linkItem(at: source, to: destination)
        } catch {
            try? fm.copyItem(at: source, to: destination)
        }
    }

    private static func readBootstrap() -> String? {
        guard let value = try? String(contentsOf: bootstrapFile, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func writeBootstrap(_ value: String) {
        try? FileManager.default.createDirectory(at: applicationRoot, withIntermediateDirectories: true)
        try? value.write(to: bootstrapFile, atomically: true, encoding: .utf8)
    }

    private static func readLegacySystemLibraryPath() -> String? {
        // 旧版把元数据库平铺在应用支持目录下：文件名可能不同，只认 sqlite 扩展名。
        guard let entries = try? FileManager.default.contentsOfDirectory(
                  at: applicationRoot, includingPropertiesForKeys: nil),
              let database = entries.first(where: { $0.pathExtension.lowercased() == "sqlite" }),
              let db = try? SQLiteDatabase(path: database.path, readonly: true) else { return nil }
        return try? db.query("SELECT value FROM settings WHERE key = 'system_library_path'")
            .first?["value"]?.string
    }
}
