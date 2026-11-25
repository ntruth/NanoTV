import Foundation
import CryptoKit

/// 图库保险库：对 originals / database / renders 做清单与 SHA-256 校验，
/// 备份到用户选择的外置盘 / NAS 挂载点，并支持按清单恢复缺失或损坏的文件。
/// 不复制缩略图、转码、系统图库缓存等可重建数据。
enum LibraryVaultService {
    private static let manifestName = "vault-manifest.json"
    /// 旁挂数据统一在 `Luma/` 下；旧备份清单里的路径会在读取时自动映射到这里。
    private static let includedRoots = ["Luma/originals", "Luma/database", "Luma/resources/renders"]

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func makeManifest(libraryRoot: URL,
                             progress: ((Int, Int, Int64) -> Void)? = nil) throws -> VaultManifest {
        let files = includedFiles(in: libraryRoot)
        var entries: [VaultEntry] = []
        entries.reserveCapacity(files.count)
        var bytes: Int64 = 0
        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            let relative = relativePath(url, in: libraryRoot)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let hash = try sha256(of: url)
            entries.append(VaultEntry(path: relative, size: size, sha256: hash))
            bytes += size
            progress?(index + 1, files.count, bytes)
        }
        return VaultManifest(libraryName: libraryRoot.deletingPathExtension().lastPathComponent,
                             createdAt: Date(),
                             entries: entries)
    }

    /// 在 destination 下创建独立备份目录，复制清单内文件并写入 `vault-manifest.json`。
    static func createBackup(libraryRoot: URL,
                             destination: URL,
                             progress: ((VaultProgress) -> Void)? = nil) throws -> URL {
        let folderName = "LumaVault-\(safeName(libraryRoot.deletingPathExtension().lastPathComponent))-\(timestamp())"
        let backupRoot = destination.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let manifest = try makeManifest(libraryRoot: libraryRoot) { done, total, bytes in
            progress?(VaultProgress(phase: .scanning, completed: done, total: total,
                                    bytes: bytes, message: "正在计算校验和"))
        }
        try writeManifest(manifest, to: backupRoot)

        var copiedBytes: Int64 = 0
        for (index, entry) in manifest.entries.enumerated() {
            try Task.checkCancellation()
            let source = libraryRoot.appendingPathComponent(entry.path)
            let target = backupRoot.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
            copiedBytes += entry.size
            progress?(VaultProgress(phase: .backingUp, completed: index + 1,
                                    total: manifest.entries.count, bytes: copiedBytes,
                                    message: entry.path))
        }
        return backupRoot
    }

    static func loadManifest(from backupRoot: URL) throws -> VaultManifest {
        let url = backupRoot.appendingPathComponent(manifestName)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VaultManifest.self, from: data)
    }

    /// 对照备份清单检查当前图库；只检查清单内文件，另外报告 originals 下的多余文件。
    static func verify(libraryRoot: URL,
                       backupRoot: URL,
                       progress: ((VaultProgress) -> Void)? = nil) throws -> VaultReport {
        let manifest = try loadManifest(from: backupRoot)
        var issues: [VaultIssue] = []
        for (index, entry) in manifest.entries.enumerated() {
            try Task.checkCancellation()
            let url = libraryRoot.appendingPathComponent(resolvedPath(entry.path))
            if !FileManager.default.fileExists(atPath: url.path) {
                issues.append(VaultIssue(kind: .missing, path: entry.path, detail: "文件不存在"))
            } else {
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if size != entry.size {
                    issues.append(VaultIssue(kind: .modified, path: entry.path,
                                             detail: "大小 \(size) ≠ 清单 \(entry.size)"))
                } else if let hash = try? sha256(of: url), hash != entry.sha256 {
                    issues.append(VaultIssue(kind: .modified, path: entry.path,
                                             detail: "SHA-256 与清单不一致"))
                }
            }
            progress?(VaultProgress(phase: .verifying, completed: index + 1,
                                    total: manifest.entries.count, bytes: 0,
                                    message: entry.path))
        }

        let expected = Set(manifest.entries.map { resolvedPath($0.path) })
        let originals = libraryRoot.appendingPathComponent("Luma/originals", isDirectory: true)
        if let enumerator = FileManager.default.enumerator(at: originals,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = relativePath(url, in: libraryRoot)
                if !expected.contains(relative) {
                    issues.append(VaultIssue(kind: .extra, path: relative, detail: "备份中没有这个文件"))
                }
            }
        }

        return VaultReport(createdAt: Date(), manifestCreatedAt: manifest.createdAt,
                           checked: manifest.entries.count, issues: issues)
    }

    /// 只恢复缺失 / 损坏的文件；损坏文件先移入 `resources/vault-quarantine/`，不直接覆盖。
    @discardableResult
    static func restore(libraryRoot: URL,
                        backupRoot: URL,
                        report: VaultReport,
                        progress: ((VaultProgress) -> Void)? = nil) throws -> Int {
        let targets = report.issues.filter { $0.kind == .missing || $0.kind == .modified }
        guard !targets.isEmpty else { return 0 }
        let quarantineRoot = libraryRoot
            .appendingPathComponent("Luma/resources/vault-quarantine", isDirectory: true)
            .appendingPathComponent(timestamp(), isDirectory: true)
        var restored = 0
        for (index, issue) in targets.enumerated() {
            try Task.checkCancellation()
            let source = backupRoot.appendingPathComponent(issue.path)
            let target = libraryRoot.appendingPathComponent(resolvedPath(issue.path))
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                let quarantine = quarantineRoot.appendingPathComponent(issue.path)
                try FileManager.default.createDirectory(at: quarantine.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: quarantine.path) {
                    try FileManager.default.removeItem(at: quarantine)
                }
                try FileManager.default.moveItem(at: target, to: quarantine)
            }
            try FileManager.default.copyItem(at: source, to: target)
            restored += 1
            progress?(VaultProgress(phase: .restoring, completed: index + 1,
                                    total: targets.count, bytes: 0, message: issue.path))
        }
        return restored
    }

    // MARK: - Helpers

    private static func includedFiles(in libraryRoot: URL) -> [URL] {
        var files: [URL] = []
        for root in includedRoots {
            let url = libraryRoot.appendingPathComponent(root, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? true
            if isDirectory {
                guard let enumerator = FileManager.default.enumerator(at: url,
                                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                                      options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in enumerator {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    // 跳过 SQLite 的临时日志：它们不是可独立恢复的内容。
                    if file.lastPathComponent.hasSuffix("-shm") { continue }
                    files.append(file)
                }
            } else {
                files.append(url)
            }
        }
        return files.sorted { relativePath($0, in: libraryRoot) < relativePath($1, in: libraryRoot) }
    }

    private static func relativePath(_ url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 旧备份清单的路径以图库根目录为基准；新布局统一收在 `Luma/` 下，读取时自动补前缀。
    private static func resolvedPath(_ path: String) -> String {
        path.hasPrefix("Luma/") ? path : "Luma/" + path
    }

    private static func writeManifest(_ manifest: VaultManifest, to backupRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: backupRoot.appendingPathComponent(manifestName), options: .atomic)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "Library" : value
    }
}
