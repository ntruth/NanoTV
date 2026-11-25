import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation
import Network
import NetFS

// MARK: - SMB 错误

/// SMB 递归扫描结果：媒体文件 + 目录（目录带 mtime，供下一轮增量扫描复用）。
struct SMBTreeScanResult {
    var media: [CloudEntry]
    var folders: [CloudEntry]
}

enum SMBError: LocalizedError {
    case invalidAddress
    case unreachable(String)
    case mountFailed(String)
    case listFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "SMB 地址无效，例如 smb://192.168.1.10/photo"
        case .unreachable(let host): return "无法连接 \(host):445，请检查 NAS 地址与局域网连接"
        case .mountFailed(let message): return message
        case .listFailed(let message): return "读取共享目录失败：\(message)"
        }
    }
}

// MARK: - SMB 局域网发现

/// 通过 Bonjour（_smb._tcp）发现同一局域网内开启文件共享的设备。
enum SMBDiscovery {
    static func browse(timeout: TimeInterval = 3) async -> [String] {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.baymax.luma.smb.discovery")
            let box = DiscoveryBox()
            let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
            @Sendable func finish() {
                guard box.claim() else { return }
                browser.cancel()
                continuation.resume(returning: box.snapshot())
            }
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint {
                        box.insert(name)
                    }
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish() }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }
}

private final class DiscoveryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []
    private var finished = false

    func insert(_ name: String) {
        lock.lock()
        names.insert(name)
        lock.unlock()
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return names.sorted()
    }
}

// MARK: - SMB 共享枚举

/// 使用系统 `smbutil` 列出某个账号可见的共享文件夹。
/// 密码通过伪终端写入，不进入命令行参数、环境变量或日志。
enum SMBShareDiscovery {
    static func list(host: String, username: String, password: String,
                     timeout: TimeInterval = 15) async -> (ok: Bool, shares: [String], message: String) {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else {
            return (false, [], "请先填写用户名和密码，再发现共享")
        }
        return await Task.detached(priority: .userInitiated) {
            let first = run(host: host, username: username, password: password, timeout: timeout)
            if first.ok { return first }
            // Bonjour 返回的单段主机名（如 DiskStation）常需补 .local 才能解析。
            if first.message == "无法连接到服务器",
               !host.contains("."), !host.hasSuffix(".local") {
                return run(host: host + ".local", username: username, password: password, timeout: timeout)
            }
            return first
        }.value
    }

    // MARK: 伪终端执行

    private static func run(host: String, username: String, password: String,
                            timeout: TimeInterval) -> (ok: Bool, shares: [String], message: String) {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            return (false, [], "无法创建终端")
        }
        defer { close(master) }
        guard let tty = ttyname(slave) else {
            close(slave)
            return (false, [], "无法创建终端")
        }
        let ttyPath = String(cString: tty)
        var window = winsize(ws_row: 24, ws_col: 240, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &window)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, ttyPath, O_RDWR, 0)
        posix_spawn_file_actions_addopen(&actions, 1, ttyPath, O_RDWR, 0)
        posix_spawn_file_actions_addopen(&actions, 2, ttyPath, O_RDWR, 0)
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addclose(&actions, slave)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // 通过 sh 的 exec 启动，确保 smbutil 在前台终端中弹出密码提示。
        let shellScript = "exec /usr/bin/smbutil view \"$1\""
        let url = "//\(username)@\(host)"
        var argv: [UnsafeMutablePointer<CChar>?] = ["sh", "-c", shellScript, "smbutil", url].map(cString)
        argv.append(nil)
        var envValues = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        envValues.append("LANG=C")
        envValues.append("LC_ALL=C")
        envValues.append("TERM=xterm-256color")
        var envp: [UnsafeMutablePointer<CChar>?] = envValues.map(cString)
        envp.append(nil)

        var pid = pid_t(0)
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        close(slave)
        for pointer in argv { free(pointer) }
        for pointer in envp { free(pointer) }
        guard spawned == 0 else {
            return (false, [], "无法启动共享发现（\(spawned)）")
        }
        _ = tcsetpgrp(master, pid)

        let output = readOutput(master: master, pid: pid, password: password, timeout: timeout)
        finish(pid: pid)

        let shares = parse(output)
        if !shares.isEmpty {
            return (true, shares, "发现 \(shares.count) 个共享文件夹")
        }
        let lower = output.lowercased()
        if lower.contains("authentication error") || lower.contains("rejected") {
            return (false, [], "认证失败，请检查用户名或密码")
        }
        if lower.contains("resolve") || lower.contains("connection")
            || lower.contains("timed out") || lower.contains("no route")
            || lower.contains("host is down") {
            return (false, [], "无法连接到服务器")
        }
        if !lower.contains("password") {
            return (false, [], "服务器没有返回共享列表，请检查地址与账号")
        }
        return (false, [], "未发现共享文件夹，请确认账号有访问权限")
    }

    private static func readOutput(master: Int32, pid: pid_t,
                                   password: String, timeout: TimeInterval) -> String {
        var output = ""
        var passwordSent = false
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready > 0 {
                let count = read(master, &buffer, buffer.count)
                if count <= 0 { break }
                output += String(decoding: buffer[0..<count], as: UTF8.self)
                let prompts = output.lowercased().components(separatedBy: "password").count - 1
                if prompts > 0, !passwordSent {
                    let text = password + "\r"
                    _ = text.withCString { write(master, $0, strlen($0)) }
                    passwordSent = true
                } else if prompts > 1 {
                    // 再次要求密码说明认证失败，避免反复尝试触发服务器锁定。
                    break
                }
            } else if ready == 0 {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid { break }
            }
        }
        return output
    }

    private static func finish(pid: pid_t) {
        var status: Int32 = 0
        var waited = waitpid(pid, &status, WNOHANG)
        if waited == 0 {
            kill(pid, SIGTERM)
            usleep(200_000)
            waited = waitpid(pid, &status, WNOHANG)
            if waited == 0 {
                kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
            }
        }
    }

    private static func parse(_ output: String) -> [String] {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let pattern = #"^(.+?)(?:\t+|\s{2,})(Disk|Pipe|Print)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        var shares: [String] = []
        for line in normalized.split(separator: "\n") {
            let text = String(line)
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let typeRange = Range(match.range(at: 2), in: text) else { continue }
            let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
            let type = String(text[typeRange]).lowercased()
            guard type == "disk", !name.isEmpty,
                  name != "IPC$", !name.hasSuffix("$") else { continue }
            if !shares.contains(name) { shares.append(name) }
        }
        return shares
    }

    private static func cString(_ value: String) -> UnsafeMutablePointer<CChar>? {
        value.withCString { strdup($0) }
    }
}

// MARK: - SMB 客户端

/// 通过系统 NetFS 挂载 SMB 共享（系统挂载到 /Volumes/<共享名>），再用 FileManager 读取。
/// 只用于只读浏览；凭据只保存在钥匙串，不写入命令行与日志。
struct SMBClient {
    let host: String
    let share: String
    /// `smb://host/share` 之后的子路径（可为空）。
    let subPath: String
    let username: String
    let password: String

    init?(mount: CloudMount, password: String) {
        guard let parsed = Self.parse(mount.baseURL) else { return nil }
        host = parsed.host
        share = parsed.share
        subPath = parsed.subPath
        username = mount.username
        self.password = password
    }

    init?(address: String, username: String, password: String) {
        guard let parsed = Self.parse(address) else { return nil }
        host = parsed.host
        share = parsed.share
        subPath = parsed.subPath
        self.username = username
        self.password = password
    }

    /// 拆分地址中的主机、共享名与子路径。
    static func pieces(_ raw: String) -> (host: String, share: String, subPath: String)? {
        parse(raw)
    }

    /// 规范化地址：补全 smb:// 前缀、去掉账号与查询参数、保留共享名与子路径。
    static func normalizedAddress(_ raw: String) -> String? {
        guard let parsed = parse(raw), !parsed.share.isEmpty else { return nil }
        let encodedHost = parsed.host.replacingOccurrences(of: " ", with: "%20")
        var text = "smb://" + encodedHost
        let components = ([parsed.share] + parsed.subPath.split(separator: "/").map(String.init))
            .filter { !$0.isEmpty }
        if !components.isEmpty {
            let encoded = components.map {
                $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0
            }
            text += "/" + encoded.joined(separator: "/")
        }
        return text
    }

    /// 默认显示名：主机 / 共享名（含子路径）。
    static func displayName(_ raw: String) -> String? {
        guard let parsed = parse(raw), !parsed.share.isEmpty else { return nil }
        let path = parsed.subPath.isEmpty ? parsed.share : parsed.share + "/" + parsed.subPath
        return "\(parsed.host) / \(path)"
    }

    /// 共享的挂载点（不含地址里的子路径）；未挂载时返回 nil。
    private var mountRoot: URL? {
        Self.resolvedMount(host: host, share: share)
    }

    /// 共享内的根路径（已包含地址中的子路径）；未挂载时返回 nil。
    var mountedRoot: URL? {
        guard let root = mountRoot else { return nil }
        return Self.appending(subPath, to: root)
    }

    func fileURL(path: String) -> URL? {
        guard let root = mountedRoot else { return nil }
        return Self.appending(path, to: root)
    }

    /// 确保共享已挂载，返回**共享挂载点**（不含子路径）；子路径由调用方拼接，避免重复追加。
    func ensureMounted() async throws -> URL {
        if let root = mountRoot { return root }
        guard await Self.probe(host: host) else {
            throw SMBError.unreachable(host)
        }
        let source = sourceURL
        let account = username
        let secret = password
        let targetHost = host
        let targetShare = share
        return try await Task.detached(priority: .userInitiated) {
            try Self.mountSync(shareURL: source, host: targetHost, share: targetShare,
                               username: account, password: secret)
        }.value
    }

    func list(path: String) async throws -> [CloudEntry] {
        let root = try await ensureMounted()
        let target = Self.appending(path, to: Self.appending(subPath, to: root))
        let relative = path
        do {
            return try await Task.detached(priority: .userInitiated) {
                try Self.enumerate(at: target, relativePath: relative)
            }.value
        } catch {
            throw SMBError.listFailed(error.localizedDescription)
        }
    }

    /// 递归扫描共享（或子路径）下的全部媒体文件，用于「全部照片」时间轴。
    func scanTree(path: String = "") async throws -> [CloudEntry] {
        try await scanTreeWithFolders(path: path).media
    }

    /// 递归扫描并同时返回目录（带 mtime）：全量扫描一次后，后续增量扫描就能按目录 mtime 跳过未变化的子树。
    func scanTreeWithFolders(path: String = "") async throws -> SMBTreeScanResult {
        let root = try await ensureMounted()
        let target = Self.appending(path, to: Self.appending(subPath, to: root))
        let relative = path
        do {
            return try await Task.detached(priority: .userInitiated) {
                try Self.enumerateTree(at: target, relativePath: relative)
            }.value
        } catch {
            throw SMBError.listFailed(error.localizedDescription)
        }
    }

    /// 断开共享：卸载系统中对应的 SMB 挂载点。
    static func unmount(address: String) {
        guard let parsed = parse(address), !parsed.share.isEmpty,
              let root = resolvedMount(host: parsed.host, share: parsed.share) else { return }
        _ = root.path.withCString { Darwin.unmount($0, 0) }
    }

    static func test(address: String, username: String, password: String) async -> (ok: Bool, message: String) {
        guard let parsed = parse(address) else {
            return (false, "地址格式不正确，例如 smb://192.168.1.10/photo")
        }
        guard !parsed.share.isEmpty else {
            return (false, "请填写共享名，例如 smb://192.168.1.10/photo")
        }
        guard let client = SMBClient(address: address, username: username,
                                     password: password) else {
            return (false, "地址格式不正确")
        }
        // 原本已挂载（例如 Finder 已连接）时不动它，避免把用户正在用的共享断开。
        let wasMounted = resolvedMount(host: parsed.host, share: parsed.share) != nil
        do {
            _ = try await client.ensureMounted()
            let entries = try await client.list(path: "")
            let folders = entries.filter { $0.isDirectory }.count
            let media = entries.filter { !$0.isDirectory && $0.isMedia }.count
            if !wasMounted { unmount(address: address) }
            return (true, "连接成功：\(folders) 个文件夹、\(media) 个媒体文件")
        } catch {
            if !wasMounted { unmount(address: address) }
            return (false, "连接失败：\(error.localizedDescription)")
        }
    }

    // MARK: 内部

    private var sourceURL: URL {
        let encodedHost = host.replacingOccurrences(of: " ", with: "%20")
        if share.isEmpty {
            return URL(string: "smb://\(encodedHost)/") ?? URL(fileURLWithPath: "/")
        }
        let encodedShare = share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share
        return URL(string: "smb://\(encodedHost)/\(encodedShare)") ?? URL(fileURLWithPath: "/")
    }

    private static func parse(_ raw: String) -> (host: String, share: String, subPath: String)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("//") {
            text = "smb:" + text
        } else if !text.lowercased().hasPrefix("smb://") {
            text = "smb://" + text
        }
        // 设备名可能带空格（如 Bonjour 展示的「MacBook Pro」），只转义主机段，避免给路径二次编码。
        if let prefix = text.range(of: "smb://", options: .caseInsensitive) {
            let rest = text[prefix.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                let authority = rest[..<slash].replacingOccurrences(of: " ", with: "%20")
                text = "smb://" + authority + rest[slash...]
            } else {
                text = "smb://" + rest.replacingOccurrences(of: " ", with: "%20")
            }
        }
        guard var components = URLComponents(string: text) else { return nil }
        components.user = nil
        components.password = nil
        guard let host = components.host, !host.isEmpty else { return nil }
        let parts = components.percentEncodedPath
            .split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
        return (host, parts.first ?? "", parts.dropFirst().joined(separator: "/"))
    }

    private static func appending(_ relative: String, to root: URL) -> URL {
        relative.split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .reduce(root) { $0.appendingPathComponent($1) }
    }

    private static func enumerate(at target: URL, relativePath: String) throws -> [CloudEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey,
                                      .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var entries: [CloudEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            let name = url.lastPathComponent
            guard !ignoredNames.contains(name), !name.hasPrefix("._") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let path = relativePath.isEmpty ? name : relativePath + "/" + name
            entries.append(CloudEntry(path: path,
                                      name: name,
                                      isDirectory: values?.isDirectory ?? false,
                                      size: Int64(values?.fileSize ?? 0),
                                      modifiedAt: values?.contentModificationDate,
                                      contentType: nil))
        }
        return entries
    }

    private static func enumerateTree(at target: URL, relativePath: String) throws -> SMBTreeScanResult {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey,
                                      .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: target,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return SMBTreeScanResult(media: [], folders: []) }

        let basePath = target.path.hasSuffix("/") ? target.path : target.path + "/"
        var media: [CloudEntry] = []
        var folders: [CloudEntry] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if ignoredNames.contains(name) || name.hasPrefix("._") {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let encoded = url.path
            var relative = encoded.hasPrefix(basePath) ? String(encoded.dropFirst(basePath.count)) : name
            if !relativePath.isEmpty { relative = relativePath + "/" + relative }
            if values?.isDirectory == true {
                // 目录本身也要进索引：下一轮增量扫描据此判断整棵子树是否可以跳过。
                folders.append(CloudEntry(path: relative,
                                          name: name,
                                          isDirectory: true,
                                          size: 0,
                                          modifiedAt: values?.contentModificationDate,
                                          contentType: nil))
                continue
            }
            let entry = CloudEntry(path: relative,
                                   name: name,
                                   isDirectory: false,
                                   size: Int64(values?.fileSize ?? 0),
                                   modifiedAt: values?.contentModificationDate,
                                   contentType: nil)
            if entry.isMedia { media.append(entry) }
        }
        return SMBTreeScanResult(media: media, folders: folders)
    }

    /// NAS 的系统目录与 macOS 资源叉文件不参与浏览与扫描。
    private static let ignoredNames: Set<String> = ["@eaDir", "#recycle", "#snapshot",
                                                    "$RECYCLE.BIN", "System Volume Information"]

    private static func mountSync(shareURL: URL, host: String, share: String,
                                  username: String, password: String) throws -> URL {
        mountLock.lock()
        defer { mountLock.unlock() }
        if let existing = resolvedMount(host: host, share: share) { return existing }

        // 普通用户不能在任意目录创建挂载点，交给 NetFS 挂到 /Volumes 并取回实际路径。
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
        let mountOptions = NSMutableDictionary()
        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(shareURL as CFURL,
                                       nil,
                                       username.isEmpty ? nil : username as CFString,
                                       password.isEmpty ? nil : password as CFString,
                                       openOptions,
                                       mountOptions,
                                       &mountpoints)
        guard status == 0 else {
            throw SMBError.mountFailed(message(for: status))
        }
        if let list = mountpoints?.takeRetainedValue() as? [String],
           let first = list.first {
            let root = URL(fileURLWithPath: first)
            if isSMBMount(root) { return root }
        }
        if let resolved = resolvedMount(host: host, share: share) { return resolved }
        throw SMBError.mountFailed("挂载完成但无法访问挂载点")
    }

    /// 在系统挂载表中查找同一主机下已挂载的共享，返回挂载点。
    private static func resolvedMount(host: String, share: String) -> URL? {
        var info: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&info, MNT_NOWAIT)
        guard count > 0, let info else { return nil }
        let targetShare = share.lowercased()
        let targetHost = host.lowercased()
        for index in 0..<Int(count) {
            var entry = info[index]
            guard cString(&entry.f_fstypename) == "smbfs" else { continue }
            // 形如 //user@host/share（共享名可能被百分号编码）。
            let from = cString(&entry.f_mntfromname)
            guard let at = from.firstIndex(of: "@") else { continue }
            let rest = from[from.index(after: at)...]
            guard let slash = rest.firstIndex(of: "/") else { continue }
            let fromHost = rest[..<slash].lowercased()
            let rawShare = String(rest[rest.index(after: slash)...])
            let decodedShare = (rawShare.removingPercentEncoding ?? rawShare).lowercased()
            guard decodedShare == targetShare else { continue }
            guard fromHost == targetHost
                || fromHost.hasPrefix(targetHost + ".")
                || targetHost.hasPrefix(fromHost + ".") else { continue }
            let mountPoint = cString(&entry.f_mntonname)
            return URL(fileURLWithPath: mountPoint)
        }
        return nil
    }

    private static func cString<T>(_ value: inout T) -> String {
        withUnsafeBytes(of: &value) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
    }

    private static func isSMBMount(_ root: URL) -> Bool {
        filesystemType(at: root) == "smbfs"
    }

    private static func filesystemType(at url: URL) -> String? {
        var info = statfs()
        let status = url.path.withCString { statfs($0, &info) }
        guard status == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_fstypename) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return nil }
            return String(cString: base)
        }
    }

    private static func message(for status: Int32) -> String {
        switch status {
        case 0: return ""
        case -128: return "已取消挂载"
        case -5045: return "密码已过期，请先在服务器上修改密码"
        case -5046: return "新密码不符合服务器策略"
        case -5999: return "账号被服务器限制，无法挂载"
        case -5998, -6003: return "服务器没有可用的共享文件夹"
        case -5997: return "服务器不支持本机可用的认证方式"
        case -5996: return "服务器协议版本不受支持"
        case -6004: return "服务器不允许访客访问"
        case -6602: return "挂载失败，请检查共享名与账号密码"
        case 80: return "认证失败，请检查账号与密码"
        case EACCES, EPERM: return "认证失败或没有访问该共享的权限"
        case 65: return "认证失败，或服务器不允许该账号挂载"
        case ENOENT: return "共享文件夹不存在，请检查地址中的共享名"
        case ETIMEDOUT: return "连接超时，请检查 NAS 地址与网络"
        case EHOSTDOWN, EHOSTUNREACH, ENETUNREACH: return "无法连接到 NAS"
        case EBUSY: return "挂载点被占用"
        default:
            if status < 0 { return "系统挂载失败（\(status)）" }
            return "系统挂载失败（errno \(status)）"
        }
    }

    /// 先做 DNS 解析与 445 端口连通性探测，避免地址错误时同步挂载长时间阻塞。
    private static func probe(host: String, port: UInt16 = 445, timeout: TimeInterval = 4) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            probeSync(host: host, port: port, timeout: timeout)
        }.value
    }

    private static func probeSync(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        // Synology 常以单段主机名（如 DiskStation）展示，系统解析失败时补 .local 再试。
        let resolved = resolve(host, port: port)
            ?? (host.contains(".") ? nil : resolve(host + ".local", port: port))
        guard let head = resolved else { return false }
        defer { freeaddrinfo(head) }

        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let entry = cursor {
            let fd = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let result = connect(fd, entry.pointee.ai_addr, entry.pointee.ai_addrlen)
                if result == 0 {
                    close(fd)
                    return true
                }
                if errno == EINPROGRESS {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&descriptor, 1, Int32(timeout * 1000)) > 0 {
                        var error: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                        close(fd)
                        if error == 0 { return true }
                    } else {
                        close(fd)
                    }
                } else {
                    close(fd)
                }
            }
            cursor = entry.pointee.ai_next
        }
        return false
    }

    private static func resolve(_ host: String, port: UInt16) -> UnsafeMutablePointer<addrinfo>? {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG,
                             ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0,
                             ai_canonname: nil,
                             ai_addr: nil,
                             ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0 else { return nil }
        return list
    }

    private static let mountLock = NSLock()
}
