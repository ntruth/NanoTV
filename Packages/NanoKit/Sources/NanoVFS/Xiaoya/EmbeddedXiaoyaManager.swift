import Foundation
import NanoCore
import Observation
#if canImport(LibXiaoya)
import LibXiaoya
#endif

/// 内置小雅服务运行状态
public enum EmbeddedXiaoyaState: String, Sendable {
    case idle = "未启动"
    case preparingAssets = "正在准备内核与索引数据包..."
    case starting = "正在拉起小雅服务..."
    case runningLocal = "本机内置运行中"
    case reusingLAN = "已复用局域网现成小雅"
    case failed = "启动异常"
}

/// 内置小雅核心配置参数（自动映射为 xiaoya-alist 标准 data/*.txt 配置文件）
public struct XiaoyaDeploymentConfig: Codable, Hashable, Sendable {
    public var listenPort: Int = 5678
    public var aliyunRefreshToken: String = ""      // mytoken.txt (32位)
    public var aliyunOpenToken: String = ""         // myopentoken.txt (280+位)
    public var tempTransferFolderID: String = ""    // temp_transfer_folder_id.txt
    public var driveFolderType: String = "r"        // folder_type.txt: "r" 资源盘 / "b" 备份盘
    public var quarkCookie: String = ""             // quark_cookie.txt
    public var cookie115: String = ""               // 115_cookie.txt
    public var dataMirrorBaseURL: String = "https://data.xiaoya.pro" // 支持切换社区镜像源
    public var autoStartOnLaunch: Bool = false

    public init() {}
}

/// 免 Docker 内置小雅 (`xiaoyaDev/xiaoya-alist`) 一键部署与守护进程管理器
@Observable
public final class EmbeddedXiaoyaManager: @unchecked Sendable {
    public static let shared = EmbeddedXiaoyaManager()

    public var config = XiaoyaDeploymentConfig()
    public private(set) var state: EmbeddedXiaoyaState = .idle
    public private(set) var activeEndpointURL: String = ""
    public private(set) var discoveredLANInstances: [DiscoveredXiaoyaInstance] = []
    public private(set) var localDataVersion: String = "未安装"
    public private(set) var consoleLogs: [String] = []
    public private(set) var isScanningLAN: Bool = false

    public let rootWorkDir: URL
    public let dataDir: URL
    public let binaryURL: URL

    #if os(macOS)
    private var daemonProcess: Process?
    #endif

    public init() {
        #if os(macOS)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.rootWorkDir = appSupport.appendingPathComponent("Nano/EmbeddedXiaoya", isDirectory: true)
        #else
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.rootWorkDir = caches.appendingPathComponent("Nano/EmbeddedXiaoya", isDirectory: true)
        #endif

        self.dataDir = rootWorkDir.appendingPathComponent("data", isDirectory: true)
        self.binaryURL = rootWorkDir.appendingPathComponent("bin/alist")

        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        loadSavedConfigFromDisk()
    }

    // MARK: - 1. 局域网优先探测与自动复用（Apple TV 安装启动后自动调用）

    /// 扫描当前局域网是否存在现成的小雅服务（NAS Docker 或 Mac 版 Nano），若存在则直接复用！
    @MainActor
    @discardableResult
    public func discoverAndReuseLANXiaoyaIfExists() async -> DiscoveredXiaoyaInstance? {
        isScanningLAN = true
        appendLog("正在扫描局域网 (5678 / 5244) 是否存在现成的小雅服务...")
        let found = await XiaoyaLanScanner.shared.scanLocalNetworkForXiaoya()
        self.discoveredLANInstances = found
        self.isScanningLAN = false

        if let best = found.first {
            self.activeEndpointURL = best.endpointURL
            if self.state != .runningLocal {
                self.state = .reusingLAN
            }
            appendLog("发现现成小雅服务：\(best.name) (\(best.endpointURL) · \(best.latencyMs)ms)，已自动挂载复用！")
            return best
        } else {
            appendLog("局域网暂未发现现成小雅服务，可在 macOS 端一键启动内置小雅。")
            return nil
        }
    }

    // MARK: - 2. 写入标准 xiaoya-alist 凭证文件与 config.json

    public func persistConfigAndWriteXiaoyaFiles() throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        func writeTrimmed(_ content: String, fileName: String) throws {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let target = dataDir.appendingPathComponent(fileName)
            try Data(trimmed.utf8).write(to: target, options: .atomic)
        }

        try writeTrimmed(config.aliyunRefreshToken, fileName: "mytoken.txt")
        try writeTrimmed(config.aliyunOpenToken, fileName: "myopentoken.txt")
        try writeTrimmed(config.tempTransferFolderID, fileName: "temp_transfer_folder_id.txt")
        try writeTrimmed(config.driveFolderType, fileName: "folder_type.txt")
        try writeTrimmed(config.quarkCookie, fileName: "quark_cookie.txt")
        try writeTrimmed(config.cookie115, fileName: "115_cookie.txt")

        // 生成标准 AList / OpenList config.json（监听 0.0.0.0:5678 允许局域网 Apple TV 共享）
        let dbFilePath = dataDir.appendingPathComponent("data.db").path
        let tempDirPath = dataDir.appendingPathComponent("temp").path
        let alistConfig: [String: Any] = [
            "force": false,
            "site_url": "",
            "cdn": "",
            "jwt_secret": "nano_embedded_xiaoya_secret",
            "token_expires_in": 48,
            "database": [
                "type": "sqlite3",
                "db_file": dbFilePath,
                "table_prefix": "x_"
            ],
            "scheme": [
                "address": "0.0.0.0",
                "http_port": config.listenPort,
                "https_port": -1,
                "force_https": false
            ],
            "temp_dir": tempDirPath,
            "log": [
                "enable": false,
                "name": dataDir.appendingPathComponent("log/alist.log").path,
                "max_size": 10,
                "max_backups": 1,
                "max_age": 1
            ],
            "delayed_start": 0,
            "max_connections": 0
        ]
        let configData = try JSONSerialization.data(withJSONObject: alistConfig, options: [.prettyPrinted])
        try configData.write(to: dataDir.appendingPathComponent("config.json"), options: .atomic)

        // 保存结构化配置快照供 UI 回显
        let uiSnapshot = try JSONEncoder().encode(config)
        try uiSnapshot.write(to: rootWorkDir.appendingPathComponent("nano_xiaoya_ui_config.json"), options: .atomic)
        appendLog("已写入 mytoken.txt / myopentoken.txt / config.json 至 \(dataDir.path)")
    }

    private func loadSavedConfigFromDisk() {
        let uiFile = rootWorkDir.appendingPathComponent("nano_xiaoya_ui_config.json")
        if let data = try? Data(contentsOf: uiFile),
           let decoded = try? JSONDecoder().decode(XiaoyaDeploymentConfig.self, from: data) {
            self.config = decoded
        }
        let verFile = dataDir.appendingPathComponent("version.txt")
        if let verText = try? String(contentsOf: verFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !verText.isEmpty {
            self.localDataVersion = verText
        }
    }

    // MARK: - 3. 阿里云盘自动创建「小雅临时转存目录」与一键清理缓存

    /// 免网页抓包！直接通过阿里云盘 OpenAPI 自动创建 `Nano_Xiaoya_Temp` 目录并回填 `temp_transfer_folder_id`
    @MainActor
    public func autoCreateAliyunTempTransferFolder() async throws -> String {
        let token = config.aliyunOpenToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw VFSError.unauthorized("请先填入阿里云盘 OpenToken 后再自动创建转存目录")
        }

        // 1. 查询用户 drive_id（优先取 resource_drive_id 资源盘）
        var driveReq = URLRequest(url: URL(string: "https://openapi.alipan.com/adrive/v1.0/user/getDriveInfo")!)
        driveReq.httpMethod = "POST"
        driveReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        driveReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        driveReq.httpBody = Data("{}".utf8)

        let (dData, _) = try await URLSession.shared.data(for: driveReq)
        guard let dJson = try JSONSerialization.jsonObject(with: dData) as? [String: Any] else {
            throw VFSError.networkFailure("获取阿里云盘 DriveInfo 失败")
        }
        let resourceDriveID = dJson["resource_drive_id"] as? String
        let defaultDriveID = dJson["default_drive_id"] as? String
        guard let targetDriveID = resourceDriveID ?? defaultDriveID else {
            throw VFSError.unauthorized("未能解析阿里云盘 drive_id，请检查 OpenToken 是否有效")
        }
        self.config.driveFolderType = (resourceDriveID != nil) ? "r" : "b"

        // 2. 在根目录创建或获取同名文件夹 `Nano_Xiaoya_Temp`
        var createReq = URLRequest(url: URL(string: "https://openapi.alipan.com/adrive/v1.0/openFile/create")!)
        createReq.httpMethod = "POST"
        createReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let createBody: [String: Any] = [
            "drive_id": targetDriveID,
            "parent_file_id": "root",
            "name": "Nano_Xiaoya_Temp",
            "type": "folder",
            "check_name_mode": "refuse" // 同名文件夹已存在时直接返回已有 file_id
        ]
        createReq.httpBody = try JSONSerialization.data(withJSONObject: createBody)

        let (cData, _) = try await URLSession.shared.data(for: createReq)
        guard let cJson = try JSONSerialization.jsonObject(with: cData) as? [String: Any],
              let folderID = cJson["file_id"] as? String, !folderID.isEmpty else {
            throw VFSError.networkFailure("创建临时转存目录失败")
        }

        self.config.tempTransferFolderID = folderID
        try persistConfigAndWriteXiaoyaFiles()
        appendLog("已自动创建阿里云盘临时转存文件夹 [Nano_Xiaoya_Temp]，ID: \(folderID)")
        return folderID
    }

    // MARK: - 4. 小雅离线索引数据包 (`update.zip`) 与 macOS 内核自动拉取更新

    @MainActor
    public func syncXiaoyaOfflineIndexBundle() async throws {
        state = .preparingAssets
        let base = config.dataMirrorBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        appendLog("正在从镜像源 \(base) 检查小雅索引数据包版本...")

        if let verURL = URL(string: "\(base)/version.txt"),
           let (vData, _) = try? await URLSession.shared.data(from: verURL),
           let remoteVer = String(data: vData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteVer.isEmpty {
            appendLog("远端最新版本：\(remoteVer)（本地：\(localDataVersion)）")
            self.localDataVersion = remoteVer
            try? Data(remoteVer.utf8).write(to: dataDir.appendingPathComponent("version.txt"))
        }

        guard let zipURL = URL(string: "\(base)/update.zip") else {
            throw VFSError.networkFailure("无效的小雅镜像源地址")
        }
        appendLog("正在下载小雅离线索引包 update.zip...")
        let (tempFileURL, resp) = try await URLSession.shared.download(from: zipURL)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VFSError.networkFailure("下载 update.zip 失败，请切换可用社区镜像源")
        }

        let targetZip = rootWorkDir.appendingPathComponent("update.zip")
        try? FileManager.default.removeItem(at: targetZip)
        try FileManager.default.moveItem(at: tempFileURL, to: targetZip)

        #if os(macOS)
        appendLog("正在解压 update.zip 至小雅数据目录...")
        try unzipArchiveOnMacOS(zipURL: targetZip, destinationDir: dataDir)
        #endif
        appendLog("小雅离线索引库更新完毕！")
        state = .idle
    }

    #if os(macOS)
    /// 确保 macOS 本地具备可执行的小雅 / OpenList 内核二进制（优先使用 App Bundle 内置，缺失时自动按芯片架构拉取）
    @MainActor
    public func ensureMacOSBinaryReady() async throws {
        if let bundled = Bundle.main.url(forResource: "alist", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            try? FileManager.default.removeItem(at: binaryURL)
            try FileManager.default.copyItem(at: bundled, to: binaryURL)
            return
        }

        if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            return
        }

        state = .preparingAssets
        #if arch(arm64)
        let archName = "arm64"
        #else
        let archName = "amd64"
        #endif

        let releaseURLStr = "https://github.com/OpenListTeam/OpenList/releases/latest/download/openlist-darwin-\(archName).tar.gz"
        appendLog("未检测到本地内核，正在自动下载 macOS (\(archName)) 原生服务内核...")
        guard let dlURL = URL(string: releaseURLStr) else { return }
        let (tmpTar, _) = try await URLSession.shared.download(from: dlURL)
        let tarDest = rootWorkDir.appendingPathComponent("kernel.tar.gz")
        try? FileManager.default.removeItem(at: tarDest)
        try FileManager.default.moveItem(at: tmpTar, to: tarDest)

        let untarProc = Process()
        untarProc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untarProc.arguments = ["-xzf", tarDest.path, "-C", binaryURL.deletingLastPathComponent().path]
        try untarProc.run()
        untarProc.waitUntilExit()

        // 兼容解压文件名为 openlist 或 alist
        let openlistBin = binaryURL.deletingLastPathComponent().appendingPathComponent("openlist")
        if FileManager.default.fileExists(atPath: openlistBin.path) {
            try? FileManager.default.removeItem(at: binaryURL)
            try FileManager.default.moveItem(at: openlistBin, to: binaryURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        appendLog("内核准备就绪：\(binaryURL.path)")
    }
    #endif

    // MARK: - 5. 启动 / 停止内置小雅守护服务

    @MainActor
    public func startEmbeddedService() async throws {
        try persistConfigAndWriteXiaoyaFiles()
        state = .starting

        #if os(macOS)
        if daemonProcess?.isRunning == true {
            state = .runningLocal
            return
        }
        try await ensureMacOSBinaryReady()

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["server", "--data", dataDir.path]
        proc.currentDirectoryURL = rootWorkDir

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendLog(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        try proc.run()
        self.daemonProcess = proc

        let lanIP = XiaoyaLanScanner.currentLANIPv4() ?? "127.0.0.1"
        self.activeEndpointURL = "http://\(lanIP):\(config.listenPort)"
        self.state = .runningLocal
        appendLog("内置小雅守护进程已启动！本机与局域网 Apple TV 共享地址：\(activeEndpointURL)")

        // 开启局域网 Bonjour 通告，让 Apple TV 端零配置发现
        await XiaoyaLanScanner.shared.startAdvertisingBonjour(port: UInt16(config.listenPort + 1))

        #elseif canImport(LibXiaoya)
        // 若编译链接了 Go C-Archive 静态库 LibXiaoya.xcframework，在 tvOS 进程内启动
        dataDir.path.withCString { cPath in
            StartEmbeddedXiaoya(UnsafeMutablePointer(mutating: cPath), Int32(config.listenPort))
        }
        self.activeEndpointURL = "http://127.0.0.1:\(config.listenPort)"
        self.state = .runningLocal
        appendLog("Apple TV 进程内嵌小雅引擎已启动：\(activeEndpointURL)")

        #else
        // tvOS 标准模式：自动查找并复用局域网内现成的小雅服务（NAS Docker 或 Mac 版 Nano）
        if let reused = await discoverAndReuseLANXiaoyaIfExists() {
            self.activeEndpointURL = reused.endpointURL
            self.state = .reusingLAN
        } else {
            self.state = .failed
            appendLog("tvOS 沙盒不支持子进程 exec；请开启局域网内的 Mac/NAS 小雅服务，或运行 scripts/build_libxiaoya_xcframework.sh 嵌入静态库。")
        }
        #endif
    }

    @MainActor
    public func stopEmbeddedService() {
        #if os(macOS)
        if let proc = daemonProcess, proc.isRunning {
            proc.terminate()
        }
        daemonProcess = nil
        Task {
            await XiaoyaLanScanner.shared.stopAdvertisingBonjour()
        }
        #endif
        state = .idle
        appendLog("内置小雅服务已停止。")
    }

    #if os(macOS)
    private func unzipArchiveOnMacOS(zipURL: URL, destinationDir: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, destinationDir.path]
        try ditto.run()
        ditto.waitUntilExit()
    }
    #endif

    @MainActor
    public func appendLog(_ line: String) {
        guard !line.isEmpty else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        consoleLogs.append("[\(fmt.string(from: Date()))] \(line)")
        if consoleLogs.count > 120 {
            consoleLogs.removeFirst(consoleLogs.count - 120)
        }
    }
}
