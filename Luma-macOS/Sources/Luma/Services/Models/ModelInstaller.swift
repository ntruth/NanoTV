import Combine
import CoreML
import CryptoKit
import Foundation

/// 本地模型下载与安装。默认全部关闭，只有用户在设置里打开开关才联网下载。
///
/// 安装流程：清单 → 断点续传下载到 `.part` → SHA256 校验 → 解压到 `.staging`
/// → 校验必备文件 → 写入 `.ready` → 原子替换正式目录，任何一步失败都不会留下半成品。
@MainActor
final class ModelInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case downloading
        case verifying
        case installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .failed: return false
            case .preparing, .downloading, .verifying, .installing: return true
            }
        }
    }

    struct InstallState: Equatable {
        var phase: Phase = .idle
        var received: Int64 = 0
        var total: Int64 = 0
        var version: String?

        var progress: Double {
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(received) / Double(total)))
        }
    }

    enum InstallError: LocalizedError {
        case manifestUnavailable
        case componentMissing
        case allSourcesFailed
        case checksumMismatch
        case extractFailed
        case payloadIncomplete(String)
        case invalidSource
        case insufficientSpace

        var errorDescription: String? {
            switch self {
            case .manifestUnavailable: return "无法获取模型清单，请检查网络或下载源"
            case .componentMissing: return "清单中没有该组件的下载地址"
            case .allSourcesFailed: return "所有下载源都失败了，请稍后重试"
            case .checksumMismatch: return "文件校验失败，已丢弃本次下载"
            case .extractFailed: return "安装包解压失败"
            case .payloadIncomplete(let name): return "安装包缺少必要文件：\(name)"
            case .invalidSource: return "下载源地址无效"
            case .insufficientSpace: return "磁盘剩余空间不足，需要约 1.5 倍安装包体积"
            }
        }
    }

    static let shared = ModelInstaller()

    /// 留空表示使用 App 内置清单（推荐）。填入地址可切换到私有镜像的清单。
    static let defaultManifestURL = ""

    static var manifestURLString: String {
        UserDefaults.standard.string(forKey: SettingsKeys.modelManifestURL) ?? defaultManifestURL
    }

    @Published private(set) var states: [ModelComponentID: InstallState] = [:]
    @Published private(set) var manifest: ModelManifest?
    @Published private(set) var manifestError: String?

    private var downloads: [ModelComponentID: Download] = [:]
    private var cancelling: Set<ModelComponentID> = []
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    func state(for id: ModelComponentID) -> InstallState {
        states[id] ?? InstallState()
    }

    func isBusy(_ id: ModelComponentID) -> Bool {
        state(for: id).phase.isBusy
    }

    // MARK: - 清单

    func refreshManifest() async {
        var configured = Self.manifestURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        // 旧版本留下的占位域名直接忽略，避免每次安装先等一次 DNS 超时。
        if configured.contains("dl.luma.app") { configured = "" }
        if !configured.isEmpty, let url = URL(string: configured) {
            do {
                var request = URLRequest(url: url)
                // 清单要能随时加源 / 改版本，不能吃 URL 缓存。
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 15
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw InstallError.manifestUnavailable
                }
                manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
                manifestError = nil
                return
            } catch {
                // 远端清单不可用：回退到 App 内置清单，模型文件仍然走国内镜像。
            }
        }

        if let data = ModelRegistry.bundledManifestData(),
           let bundled = try? JSONDecoder().decode(ModelManifest.self, from: data) {
            manifest = bundled
            manifestError = nil
            return
        }
        manifestError = InstallError.manifestUnavailable.localizedDescription
    }

    // MARK: - 安装 / 取消 / 卸载

    func install(_ id: ModelComponentID) {
        guard ModelRegistry.isInstallable(id) else { return }
        guard !isBusy(id) else { return }
        Task { await runInstall(id) }
    }

    func cancel(_ id: ModelComponentID) {
        guard isBusy(id) else { return }
        cancelling.insert(id)
        downloads[id]?.cancel()
        downloads[id] = nil
        states[id] = InstallState()
    }

    func uninstall(_ id: ModelComponentID) {
        guard let descriptor = ModelRegistry.descriptor(id), !isBusy(id) else { return }
        // 先停用再删文件：避免删到一半被分析任务读到。
        ModelRegistry.setEnabled(false, for: id)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: ModelRegistry.modelsRoot
            .appendingPathComponent(descriptor.directoryName))
        try? fileManager.removeItem(at: partURL(for: id))
        try? fileManager.removeItem(at: archiveURL(for: id))
        SigLIPEngine.shared.invalidateModels()
        states[id] = InstallState()
    }

    // MARK: - 主流程

    private func runInstall(_ id: ModelComponentID) async {
        guard let descriptor = ModelRegistry.descriptor(id) else { return }
        states[id] = InstallState(phase: .preparing)
        do {
            if manifest == nil { await refreshManifest() }
            guard let manifest else { throw InstallError.manifestUnavailable }
            guard let entry = manifest.components.first(where: { $0.id == id.rawValue }) else {
                throw InstallError.componentMissing
            }
            try ensureDiskSpace(for: entry.size)

            if let files = entry.files, !files.isEmpty {
                try await installFiles(files, descriptor: descriptor, entry: entry)
            } else {
                let part = partURL(for: id)
                states[id] = InstallState(phase: .downloading,
                                          received: fileSize(part),
                                          total: entry.size,
                                          version: entry.version)
                let archive = try await downloadArchive(entry, for: id, part: part)

                states[id] = InstallState(phase: .verifying,
                                          received: entry.size,
                                          total: entry.size,
                                          version: entry.version)
                if let expected = entry.sha256 {
                    let digest = try Self.sha256(of: archive)
                    guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
                        try? FileManager.default.removeItem(at: archive)
                        throw InstallError.checksumMismatch
                    }
                }

                states[id] = InstallState(phase: .installing,
                                          received: entry.size,
                                          total: entry.size,
                                          version: entry.version)
                try installArchive(archive, descriptor: descriptor, entry: entry)
            }

            ModelRegistry.setEnabled(true, for: id)
            // 之前可能加载失败过（例如模型还没下载），这里清掉缓存让下次重新读盘。
            SigLIPEngine.shared.invalidateModels()
            states[id] = InstallState(phase: .idle,
                                      received: entry.size,
                                      total: entry.size,
                                      version: entry.version)
            NSLog("LumaModel: installed %@ (%@)", id.rawValue, entry.version)
        } catch {
            if cancelling.remove(id) != nil {
                states[id] = InstallState()
                return
            }
            NSLog("LumaModel: install failed %@: %@", id.rawValue, error.localizedDescription)
            states[id] = InstallState(phase: .failed(error.localizedDescription))
        }
    }

    /// 按源顺序尝试；Part 文件跨源复用，已下载的字节不会被丢弃。
    private func downloadArchive(_ entry: ModelManifest.Component,
                                 for id: ModelComponentID,
                                 part: URL) async throws -> URL {
        let archive = archiveURL(for: id)
        let existing = fileSize(part)
        if entry.size > 0, existing > entry.size {
            // 清单换了新版本，旧半成品比新包还大，无法续传，直接丢弃。
            try? FileManager.default.removeItem(at: part)
        } else if entry.size > 0, existing == entry.size {
            try? FileManager.default.removeItem(at: archive)
            try FileManager.default.moveItem(at: part, to: archive)
            return archive
        }
        var lastError: Error?
        for source in entry.sources {
            guard let url = URL(string: source) else { continue }
            do {
                try await download(from: url, part: part, id: id, expectedSize: entry.size)
                try? FileManager.default.removeItem(at: archive)
                try FileManager.default.moveItem(at: part, to: archive)
                return archive
            } catch {
                lastError = error
            }
        }
        throw lastError ?? InstallError.allSourcesFailed
    }

    private func download(from url: URL,
                          part: URL,
                          id: ModelComponentID,
                          expectedSize: Int64,
                          progressBase: Int64 = 0,
                          progressTotal: Int64? = nil) async throws {
        try FileManager.default.createDirectory(at: ModelRegistry.downloadsRoot,
                                                withIntermediateDirectories: true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let download = Download(url: url,
                                    partURL: part,
                                    expectedTotal: expectedSize,
                                    progress: { received, total in
                                        Task { @MainActor in
                                            var state = self.state(for: id)
                                            state.received = progressBase + received
                                            state.total = progressTotal ?? (total > 0 ? total : expectedSize)
                                            self.states[id] = state
                                        }
                                    },
                                    completion: { result in
                                        Task { @MainActor in
                                            self.downloads[id] = nil
                                            continuation.resume(with: result)
                                        }
                                    })
            self.downloads[id] = download
            download.start(in: session)
        }
    }

    // MARK: - 多文件安装

    /// 一个组件拆成多个压缩包（图像编码器 / 文本编码器 / 分词器）时的安装流程。
    /// 每个文件单独续传、单独校验，全部解压到同一个 staging，再统一编译与落盘。
    private func installFiles(_ files: [ModelManifest.Component.File],
                              descriptor: ModelComponentDescriptor,
                              entry: ModelManifest.Component) async throws {
        let id = descriptor.id
        let fileManager = FileManager.default
        let staging = ModelRegistry.stagingRoot.appendingPathComponent(descriptor.directoryName)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ModelRegistry.downloadsRoot, withIntermediateDirectories: true)

        var base: Int64 = 0
        for file in files {
            let part = ModelRegistry.downloadsRoot
                .appendingPathComponent("\(id.rawValue)-\(file.name).part")
            states[id] = InstallState(phase: .downloading,
                                      received: base + fileSize(part),
                                      total: entry.size,
                                      version: entry.version)
            let archive = try await downloadFile(file, part: part, id: id, base: base, total: entry.size)
            states[id] = InstallState(phase: .verifying,
                                      received: base + file.size,
                                      total: entry.size,
                                      version: entry.version)
            let digest = try Self.sha256(of: archive)
            guard digest.caseInsensitiveCompare(file.sha256) == .orderedSame else {
                try? fileManager.removeItem(at: archive)
                throw InstallError.checksumMismatch
            }
            try Self.extract(archive, into: staging)
            try? fileManager.removeItem(at: archive)
            base += file.size
        }

        states[id] = InstallState(phase: .installing,
                                  received: entry.size,
                                  total: entry.size,
                                  version: entry.version)
        // 上游分发的是 .mlpackage，运行时编译成 .mlmodelc，后续加载路径保持不变。
        try Self.compilePackages(in: staging)
        // 词表、标签向量与分词器随 App 内置，安装时并入组件目录。
        try Self.copyBundledAssets(into: staging)
        for name in descriptor.requiredEntries {
            guard fileManager.fileExists(atPath: staging.appendingPathComponent(name).path) else {
                try? fileManager.removeItem(at: staging)
                throw InstallError.payloadIncomplete(name)
            }
        }
        let marker = ModelReadyMarker(version: entry.version,
                                      sha256: entry.sha256 ?? "",
                                      installedAt: Date())
        try Self.commitStaging(staging, descriptor: descriptor, marker: marker)
    }

    /// 同一文件按 urls 顺序重试，`.part` 跨源复用。
    private func downloadFile(_ file: ModelManifest.Component.File,
                              part: URL,
                              id: ModelComponentID,
                              base: Int64,
                              total: Int64) async throws -> URL {
        let archive = ModelRegistry.downloadsRoot
            .appendingPathComponent("\(id.rawValue)-\(file.name).zip")
        let existing = fileSize(part)
        if file.size > 0, existing == file.size {
            try? FileManager.default.removeItem(at: archive)
            try FileManager.default.moveItem(at: part, to: archive)
            return archive
        }
        if file.size > 0, existing > file.size {
            try? FileManager.default.removeItem(at: part)
        }
        var lastError: Error?
        for string in file.urls {
            guard let url = URL(string: string) else { continue }
            do {
                try await download(from: url,
                                   part: part,
                                   id: id,
                                   expectedSize: file.size,
                                   progressBase: base,
                                   progressTotal: total)
                try? FileManager.default.removeItem(at: archive)
                try FileManager.default.moveItem(at: part, to: archive)
                return archive
            } catch {
                lastError = error
            }
        }
        throw lastError ?? InstallError.allSourcesFailed
    }

    private nonisolated static func extract(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallError.extractFailed }
    }

    /// 把解压出来的 .mlpackage 编译成 .mlmodelc 并删除源包，安装后目录结构与旧版一致。
    private nonisolated static func compilePackages(in directory: URL) throws {
        let fileManager = FileManager.default
        let items = (try? fileManager.contentsOfDirectory(at: directory,
                                                          includingPropertiesForKeys: nil)) ?? []
        var packages: [URL] = []
        for item in items {
            if item.pathExtension == "mlpackage" {
                packages.append(item)
                continue
            }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let nested = (try? fileManager.contentsOfDirectory(at: item,
                                                               includingPropertiesForKeys: nil)) ?? []
            packages.append(contentsOf: nested.filter { $0.pathExtension == "mlpackage" })
        }
        for package in packages {
            let compiled = try MLModel.compileModel(at: package)
            let name = package.deletingPathExtension().lastPathComponent + ".mlmodelc"
            let destination = directory.appendingPathComponent(name)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: compiled, to: destination)
            try? fileManager.removeItem(at: package)
        }
    }

    private nonisolated static func copyBundledAssets(into staging: URL) throws {
        guard let assets = ModelRegistry.bundledAssetsDirectory else {
            throw InstallError.payloadIncomplete("SigLIP2Assets")
        }
        let fileManager = FileManager.default
        for item in try fileManager.contentsOfDirectory(at: assets,
                                                        includingPropertiesForKeys: nil) {
            let destination = staging.appendingPathComponent(item.lastPathComponent)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: item, to: destination)
        }
    }

    /// 下载 + 解压需要约 1.5 倍体积，空间不够时提前失败，别等写满磁盘。
    private func ensureDiskSpace(for bytes: Int64) throws {
        guard bytes > 0 else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: ModelRegistry.downloadsRoot,
                                         withIntermediateDirectories: true)
        guard let values = try? ModelRegistry.downloadsRoot
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage,
              available > 0 else { return }
        if Int64(available) < bytes * 3 / 2 {
            throw InstallError.insufficientSpace
        }
    }

    // MARK: - 解压与落盘

    private func installArchive(_ archive: URL,
                                descriptor: ModelComponentDescriptor,
                                entry: ModelManifest.Component) throws {
        let fileManager = FileManager.default
        let staging = ModelRegistry.stagingRoot.appendingPathComponent(descriptor.directoryName)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        // 约定：zip 的内容直接是组件目录（ImageEncoder.mlmodelc/...），不额外套一层文件夹。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, staging.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? fileManager.removeItem(at: staging)
            throw InstallError.extractFailed
        }
        for name in descriptor.requiredEntries {
            let url = staging.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else {
                try? fileManager.removeItem(at: staging)
                throw InstallError.payloadIncomplete(name)
            }
        }

        let marker = ModelReadyMarker(version: entry.version,
                                      sha256: entry.sha256 ?? "",
                                      installedAt: Date())
        try Self.commitStaging(staging, descriptor: descriptor, marker: marker)
        try? fileManager.removeItem(at: archive)
    }

    /// 从本地文件夹导入（离线 / 内网场景）：选组件目录本身，或包含组件目录的上一级都可以。
    func importLocalDirectory(_ url: URL, for id: ModelComponentID) {
        guard let descriptor = ModelRegistry.descriptor(id), !isBusy(id) else { return }
        states[id] = InstallState(phase: .installing)
        Task.detached(priority: .userInitiated) {
            do {
                try Self.installDirectory(url, descriptor: descriptor)
                await MainActor.run {
                    ModelRegistry.setEnabled(true, for: id)
                    SigLIPEngine.shared.invalidateModels()
                    self.states[id] = InstallState(phase: .idle,
                                                   received: 0,
                                                   total: 0,
                                                   version: "本地导入")
                }
            } catch {
                await MainActor.run {
                    self.states[id] = .init(phase: .failed(error.localizedDescription))
                }
            }
        }
    }

    private nonisolated static func installDirectory(_ source: URL,
                                                     descriptor: ModelComponentDescriptor) throws {
        let fileManager = FileManager.default
        var root = source
        let markerEntry = descriptor.requiredEntries.first ?? ""
        if !markerEntry.isEmpty,
           !fileManager.fileExists(atPath: root.appendingPathComponent(markerEntry).path) {
            let nested = source.appendingPathComponent(descriptor.directoryName)
            guard fileManager.fileExists(atPath: nested.appendingPathComponent(markerEntry).path) else {
                throw InstallError.payloadIncomplete(markerEntry)
            }
            root = nested
        }
        for entry in descriptor.requiredEntries {
            guard fileManager.fileExists(atPath: root.appendingPathComponent(entry).path) else {
                throw InstallError.payloadIncomplete(entry)
            }
        }

        let staging = ModelRegistry.stagingRoot.appendingPathComponent(descriptor.directoryName)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for item in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                try fileManager.copyItem(at: item,
                                         to: staging.appendingPathComponent(item.lastPathComponent))
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        let marker = ModelReadyMarker(version: "本地导入", sha256: "", installedAt: Date())
        try commitStaging(staging, descriptor: descriptor, marker: marker)
    }

    /// 写入 `.ready` 并把 staging 原子替换到正式目录；失败时回滚旧版本。
    private nonisolated static func commitStaging(_ staging: URL,
                                                  descriptor: ModelComponentDescriptor,
                                                  marker: ModelReadyMarker) throws {
        let fileManager = FileManager.default
        let markerData = try JSONEncoder().encode(marker)
        try markerData.write(to: staging.appendingPathComponent(".ready"))

        let target = ModelRegistry.modelsRoot.appendingPathComponent(descriptor.directoryName)
        let backup = ModelRegistry.stagingRoot.appendingPathComponent(descriptor.directoryName + ".old")
        try? fileManager.removeItem(at: backup)
        try fileManager.createDirectory(at: ModelRegistry.modelsRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.moveItem(at: target, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: target)
            try? fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: backup.path),
               !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: backup, to: target)
            }
            throw error
        }
    }

    // MARK: - 路径与工具

    private func partURL(for id: ModelComponentID) -> URL {
        ModelRegistry.downloadsRoot.appendingPathComponent("\(id.rawValue).part")
    }

    private func archiveURL(for id: ModelComponentID) -> URL {
        ModelRegistry.downloadsRoot.appendingPathComponent("\(id.rawValue).zip")
    }

    private func fileSize(_ url: URL) -> Int64 {
        Self.fileSize(url)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// 流式校验，避免把几百 MB 一次性读进内存。
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1 << 20)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 下载任务

private final class Download {
    private let url: URL
    private let partURL: URL
    private let expectedTotal: Int64
    private let progress: (Int64, Int64) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private var task: URLSessionDataTask?
    private var delegate: DownloadDelegate?

    init(url: URL,
         partURL: URL,
         expectedTotal: Int64,
         progress: @escaping (Int64, Int64) -> Void,
         completion: @escaping (Result<Void, Error>) -> Void) {
        self.url = url
        self.partURL = partURL
        self.expectedTotal = expectedTotal
        self.progress = progress
        self.completion = completion
    }

    func start(in session: URLSession) {
        var request = URLRequest(url: url)
        let existing = Self.fileSize(partURL)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let delegate = DownloadDelegate(partURL: partURL,
                                        existing: existing,
                                        expectedTotal: expectedTotal,
                                        progress: progress,
                                        completion: completion)
        self.delegate = delegate
        let task = session.dataTask(with: request)
        delegate.task = task
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}

private final class DownloadDelegate: NSObject, URLSessionDataDelegate {
    weak var task: URLSessionDataTask?

    private let partURL: URL
    private let expectedTotal: Int64
    private let progress: (Int64, Int64) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private var handle: FileHandle?
    private var received: Int64
    private var total: Int64
    private var finished = false

    init(partURL: URL,
         existing: Int64,
         expectedTotal: Int64,
         progress: @escaping (Int64, Int64) -> Void,
         completion: @escaping (Result<Void, Error>) -> Void) {
        self.partURL = partURL
        self.expectedTotal = expectedTotal
        self.progress = progress
        self.completion = completion
        self.received = existing
        self.total = expectedTotal
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
            return
        }
        let fileManager = FileManager.default
        switch http.statusCode {
        case 206:
            total = Self.totalSize(from: http) ?? expectedTotal
        case 200:
            // 服务器忽略了 Range，只能从头写。
            try? fileManager.removeItem(at: partURL)
            received = 0
            total = http.expectedContentLength > 0 ? http.expectedContentLength : expectedTotal
        case 416:
            if expectedTotal > 0, Self.fileSize(partURL) == expectedTotal {
                finish(.success(()))
            } else {
                try? fileManager.removeItem(at: partURL)
                finish(.failure(URLError(.badServerResponse)))
            }
            completionHandler(.cancel)
            return
        default:
            finish(.failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
            return
        }
        if !fileManager.fileExists(atPath: partURL.path) {
            fileManager.createFile(atPath: partURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: partURL)
        handle?.seekToEndOfFile()
        progress(received, total)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        received += Int64(data.count)
        progress(received, total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let error {
            finish(.failure(error))
            return
        }
        let size = Self.fileSize(partURL)
        if total > 0, size != total {
            finish(.failure(URLError(.cannotLoadFromNetwork)))
            return
        }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        completion(result)
    }

    private static func totalSize(from response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let slash = value.lastIndex(of: "/") else { return nil }
        let tail = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(tail)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}
