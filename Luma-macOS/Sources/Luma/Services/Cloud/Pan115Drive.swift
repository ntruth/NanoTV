import Foundation
import Security
import LumaContentCore

// MARK: - 115 网盘（浏览器 Cookie 直连）
//
// 115 面向个人的开放平台已暂停，这里沿用网页 / 115Browser 的接口：
//   - 列目录：GET  https://webapi.115.com/files
//   - 下载直链：POST https://proapi.115.com/app/chrome/downurl（表单 data 需要 115 的编码）
//   - 删除：POST https://webapi.115.com/rb/delete
// 都需要浏览器登录后的 Cookie（UID / CID / SEID / KID），因此 Cookie 存钥匙串（CloudCredentials）。
//
// 直链接口是 115 独有的「RSA + XOR」编码：请求用内置公钥做 RSA 填充加密，
// 响应用同一公钥按原始 RSA 还原（服务器侧用私钥签名），再由随机密钥做 XOR 还原。

enum Pan115Drive {
    /// 允许本地联调时指向模拟服务。
    static var apiBase: String {
        ProcessInfo.processInfo.environment["LUMA_115_API_BASE"]
            ?? "https://webapi.115.com"
    }
    static var downloadBase: String {
        ProcessInfo.processInfo.environment["LUMA_115_DOWNLOAD_BASE"]
            ?? "https://proapi.115.com"
    }

    /// 网页接口用普通浏览器 UA 即可。
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// 直链接口与 CDN 认 115Browser 的 UA：版本过旧会被 115 侧拒绝，启动时从官方接口刷新。
    static let fallbackAppVersion = "36.0.1"
    static let referer = "https://115.com/"
    /// 115 的根目录 ID。
    static let rootID = "0"

    private static let versionLock = NSLock()
    private static var appVersion = fallbackAppVersion
    private static var appVersionFetchedAt: Date?
    private static var versionTask: Task<String, Never>?

    /// 当前 115Browser UA（下载接口与 CDN 必须与申请直链时一致）。
    static var downloadUserAgent: String {
        versionLock.lock()
        defer { versionLock.unlock() }
        return "Mozilla/5.0 115Browser/\(appVersion)"
    }

    /// 从官方接口取当前客户端版本；失败时沿用内置版本。
    @discardableResult
    static func refreshAppVersion() async -> String {
        versionLock.lock()
        if let fetchedAt = appVersionFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 6 * 3600 {
            let value = appVersion
            versionLock.unlock()
            return value
        }
        if let task = versionTask {
            versionLock.unlock()
            return await task.value
        }
        let task = Task { await fetchAppVersion() }
        versionTask = task
        versionLock.unlock()

        let value = await task.value
        versionLock.lock()
        appVersion = value
        appVersionFetchedAt = Date()
        versionTask = nil
        versionLock.unlock()
        return value
    }

    private static func fetchAppVersion() async -> String {
        guard let url = URL(string: "https://appversion.115.com/1/web/1.0/api/chrome") else {
            return fallbackAppVersion
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let versions = object["data"] as? [String: Any] else {
            return fallbackAppVersion
        }
        for key in ["win", "mac", "mac_arc", "android"] {
            if let item = versions[key] as? [String: Any],
               let value = item["version_code"] as? String, !value.isEmpty {
                return value
            }
        }
        return fallbackAppVersion
    }

    /// 直链请求头：与申请直链时保持一致（同 UA + Cookie），不要额外加 Referer。
    static func downloadHeaders(cookie: String, userAgent: String? = nil) -> [String: String] {
        [
            "Cookie": normalizedCookie(cookie),
            "User-Agent": userAgent ?? downloadUserAgent,
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
    }

    /// 直链是否真的能取到数据：115 CDN 会按 UA / 风控拒绝部分链接，
    /// 先探一次 HEAD（失败再试 2 字节 Range），避免播放器拿到 403 才开始报错。
    static func isReachable(url: URL, headers: [String: String]) async -> Bool {
        if await probe(url: url, headers: headers, method: "HEAD", range: nil) {
            return true
        }
        return await probe(url: url, headers: headers, method: "GET", range: "bytes=0-1")
    }

    private static func probe(url: URL, headers: [String: String],
                              method: String, range: String?) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// 网页接口 / 缩略图请求头。
    static func thumbnailHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": normalizedCookie(cookie),
            "User-Agent": browserUserAgent,
            "Referer": referer
        ]
    }

    /// 用户从 DevTools 复制的 Cookie 可能带 "Cookie:" 前缀或换行，统一整理成一行。
    static func normalizedCookie(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") {
            text = String(text.dropFirst("cookie:".count))
        }
        let parts = text
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: "; ")
    }

    // MARK: 目录

    static func list(cookie: String, folderID: String) async throws -> [CloudEntry] {
        var entries: [CloudEntry] = []
        var offset = 0
        let limit = 100
        let container = folderID.isEmpty ? rootID : folderID

        while true {
            var components = URLComponents(string: apiBase + "/files")
            components?.queryItems = [
                URLQueryItem(name: "aid", value: "1"),
                URLQueryItem(name: "cid", value: container),
                URLQueryItem(name: "o", value: "user_ptime"),
                URLQueryItem(name: "asc", value: "0"),
                URLQueryItem(name: "offset", value: "\(offset)"),
                URLQueryItem(name: "show_dir", value: "1"),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "snap", value: "0"),
                URLQueryItem(name: "natsort", value: "0"),
                URLQueryItem(name: "record_open_time", value: "1"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "fc_mix", value: "0"),
                URLQueryItem(name: "source", value: "")
            ]
            guard let url = components?.url else { throw CloudOAuthError.api("地址无效") }
            let object = try await get(url, cookie: cookie)
            try check(object)

            let list = object["data"] as? [[String: Any]] ?? []
            entries.append(contentsOf: list.compactMap { parseEntry($0) })
            let total = (object["count"] as? NSNumber)?.intValue
                ?? (object["count"] as? String).flatMap(Int.init)
                ?? entries.count
            offset += list.count
            // 目录可能很多；单层超过 5000 项时停在当前页，避免无限翻页。
            if list.count < limit || offset >= total || offset >= 5000 { break }
        }
        return entries
    }

    // MARK: 直链

    static func downloadURL(pickCode: String, cookie: String,
                            userAgent overrideUA: String? = nil) async throws -> URL {
        guard !pickCode.isEmpty else {
            throw CloudOAuthError.api("缺少 115 文件标识（pickcode），请刷新该目录后重试")
        }
        if overrideUA == nil {
            // 直链与会话 UA 绑定：先用当前客户端版本，避免过旧版本被 CDN 拒绝。
            await refreshAppVersion()
        }
        let key = Pan115Crypto.randomKey()
        let payload = (try? JSONSerialization.data(withJSONObject: ["pickcode": pickCode])) ?? Data()
        guard let encoded = Pan115Crypto.encode(payload, key: key) else {
            throw CloudOAuthError.api("115 直链参数编码失败")
        }

        var components = URLComponents(string: downloadBase + "/app/chrome/downurl")
        components?.queryItems = [
            URLQueryItem(name: "t", value: "\(Int(Date().timeIntervalSince1970 * 1000))")
        ]
        guard let url = components?.url else { throw CloudOAuthError.api("地址无效") }
        let object = try await sendForm(url: url,
                                        form: ["data": encoded],
                                        cookie: cookie,
                                        userAgent: overrideUA ?? downloadUserAgent)
        guard let dataString = object["data"] as? String,
              let decoded = Pan115Crypto.decode(dataString, key: key),
              let json = (try? JSONSerialization.jsonObject(with: decoded)) as? [String: Any] else {
            throw CloudOAuthError.api("115 直链响应解析失败，请稍后重试")
        }
        for value in json.values {
            guard let info = value as? [String: Any],
                  let urlBox = info["url"] as? [String: Any],
                  let raw = urlBox["url"] as? String, !raw.isEmpty,
                  let result = URL(string: raw) else { continue }
            return result
        }
        throw CloudOAuthError.api("未获取到 115 下载地址")
    }

    // MARK: 删除

    /// 删除文件：网页端 / PC 客户端的 `rb/delete`，fid[n] 传文件 ID。
    /// 115 若开启了「安全码」保护，会返回需要密码的提示，这里原样转成中文错误。
    static func delete(fids: [String], cookie: String) async throws {
        guard !fids.isEmpty else { return }
        var form: [String: String] = [:]
        for (index, fid) in fids.enumerated() {
            form["fid[\(index)]"] = fid
        }
        guard let url = URL(string: apiBase + "/rb/delete") else {
            throw CloudOAuthError.api("地址无效")
        }
        let object = try await sendForm(url: url, form: form, cookie: cookie)
        try check(object)
    }

    // MARK: 内部

    private static func parseEntry(_ item: [String: Any]) -> CloudEntry? {
        guard let name = item["n"] as? String, !name.isEmpty else { return nil }
        let fid = stringValue(item["fid"])
        let cid = stringValue(item["cid"])
        // 文件条目带 fid；目录条目没有 fid（或为 0），用自己的 cid 作为 ID。
        let isDirectory = fid.isEmpty || fid == "0" || (item["ico"] as? String) == "folder"
        let id = isDirectory ? cid : fid
        guard !id.isEmpty else { return nil }

        var entry = CloudEntry(path: id,
                               name: name,
                               isDirectory: isDirectory,
                               size: int64Value(item["s"]) ?? 0,
                               modifiedAt: updatedAt(item["t"]),
                               contentType: nil)
        if !isDirectory {
            entry.remoteID = (item["pc"] as? String)
            entry.thumbnailURL = thumbnailURL(item["u"])
        }
        return entry
    }

    private static func thumbnailURL(_ raw: Any?) -> String? {
        guard var text = raw as? String, !text.isEmpty else { return nil }
        if text.hasPrefix("//") {
            text = "https:" + text
        } else if text.hasPrefix("/") {
            text = "https://thumb.115.com" + text
        }
        return text
    }

    /// 更新时间：文件是 "2024-01-02 15:04"，目录是 Unix 秒。
    private static func updatedAt(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let text = raw as? String, !text.isEmpty else { return nil }
        if let seconds = Double(text), seconds > 0 {
            return Date(timeIntervalSince1970: seconds > 1_000_000_000_000 ? seconds / 1000 : seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)
    }

    private static func stringValue(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return ""
    }

    private static func int64Value(_ raw: Any?) -> Int64? {
        if let number = raw as? NSNumber { return number.int64Value }
        if let text = raw as? String { return Int64(text) }
        return nil
    }

    private static func check(_ object: [String: Any]) throws {
        let state = (object["state"] as? Bool)
            ?? (object["state"] as? NSNumber)?.boolValue
            ?? true
        guard !state else { return }
        let message = (object["error"] as? String)
            ?? (object["msg"] as? String)
            ?? "115 接口返回失败"
        if message.contains("登录") || message.contains("登陆") || message.contains("超时") {
            throw CloudOAuthError.notAuthorized
        }
        throw CloudOAuthError.api(message)
    }

    private static func get(_ url: URL, cookie: String) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(normalizedCookie(cookie), forHTTPHeaderField: "Cookie")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    private static func sendForm(url: URL,
                                 form: [String: String],
                                 cookie: String,
                                 userAgent: String = browserUserAgent,
                                 contentType: String = "application/x-www-form-urlencoded") async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(normalizedCookie(cookie), forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw CloudOAuthError.notAuthorized }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard !object.isEmpty else {
            throw CloudOAuthError.api("返回内容不是 JSON（HTTP \(status)）")
        }
        guard status == 200 else {
            throw CloudOAuthError.api((object["error"] as? String) ?? "HTTP \(status)")
        }
        return object
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~[]")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static let session = HTTPSessionPool.shared.session(.cloud)
}

// MARK: - 115 直链编码

/// 115 下载接口的参数编码：RSA 原始运算 + 双向 XOR + 字节反转。
/// 算法与 AList / 115driver 的 `crypto/m115` 一致；只在直链接口使用。
enum Pan115Crypto {
    private static let modulusHex = "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021"
        + "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633"
        + "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1"
        + "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"
    private static let exponentBytes: [UInt8] = [0x01, 0x00, 0x01]
    private static let blockSize = 128
    private static let keyLength = 16

    private static let xorKeySeed: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
        0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
        0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
        0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
        0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
        0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
        0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
        0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
        0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
        0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5
    ]
    private static let xorClientKey: [UInt8] = [
        0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18,
        0x4c, 0x01, 0x3f, 0x46
    ]

    static func randomKey() -> [UInt8] {
        var key = [UInt8](repeating: 0, count: keyLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, key.count, &key)
        return key
    }

    static func encode(_ input: Data, key: [UInt8]) -> String? {
        guard key.count == keyLength else { return nil }
        var buffer = key
        buffer.append(contentsOf: input)
        xorTransform(&buffer, deriveKey(key, size: 4), offset: keyLength)
        reverseTail(&buffer, from: keyLength)
        xorTransform(&buffer, xorClientKey, offset: keyLength)
        guard let encrypted = rsaEncrypt(buffer) else { return nil }
        return Data(encrypted).base64EncodedString()
    }

    static func decode(_ base64: String, key: [UInt8]) -> Data? {
        guard key.count == keyLength, let data = Data(base64Encoded: base64) else { return nil }
        guard let decrypted = rsaDecrypt([UInt8](data)), decrypted.count > keyLength else { return nil }
        let seed = Array(decrypted[0..<keyLength])
        var output = Array(decrypted[keyLength...])
        xorTransform(&output, deriveKey(seed, size: 12))
        reverseTail(&output, from: 0)
        xorTransform(&output, deriveKey(key, size: 4))
        return Data(output)
    }

    // MARK: RSA

    private static let rsaKey: SecKey? = makePublicKey()

    private static func makePublicKey() -> SecKey? {
        var modulus: [UInt8] = []
        var index = modulusHex.startIndex
        while index < modulusHex.endIndex {
            let next = modulusHex.index(index, offsetBy: 2)
            guard let byte = UInt8(modulusHex[index..<next], radix: 16) else { return nil }
            modulus.append(byte)
            index = next
        }
        while modulus.first == 0 { modulus.removeFirst() }
        if let first = modulus.first, first & 0x80 != 0 {
            modulus.insert(0, at: 0)
        }
        var body = derInteger(modulus) + derInteger(exponentBytes)
        body = [0x30] + derLength(body.count) + body
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: blockSize * 8
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(Data(body) as CFData, attributes as CFDictionary, &error)
    }

    /// 原始 RSA 运算（无填充）：x^e mod n，输出固定 128 字节。
    private static func rawRSA(_ block: [UInt8]) -> [UInt8]? {
        guard block.count == blockSize, let rsaKey else { return nil }
        var error: Unmanaged<CFError>?
        guard let output = SecKeyCreateEncryptedData(rsaKey,
                                                     .rsaEncryptionRaw,
                                                     Data(block) as CFData,
                                                     &error) else { return nil }
        let bytes = [UInt8](output as Data)
        guard bytes.count == blockSize else { return nil }
        return bytes
    }

    /// 请求方向：按 PKCS#1 v1.5 的填充结构逐段做原始 RSA。
    private static func rsaEncrypt(_ input: [UInt8]) -> [UInt8]? {
        var output: [UInt8] = []
        var index = 0
        let sliceSize = blockSize - 11
        while index < input.count {
            let size = min(sliceSize, input.count - index)
            let slice = Array(input[index..<(index + size)])
            var block = [UInt8](repeating: 0, count: blockSize)
            block[0] = 0x00
            block[1] = 0x02
            let paddingSize = blockSize - size - 3
            if paddingSize > 0 {
                var padding = [UInt8](repeating: 0, count: paddingSize)
                _ = SecRandomCopyBytes(kSecRandomDefault, paddingSize, &padding)
                for offset in 0..<paddingSize {
                    block[2 + offset] = padding[offset] % 0xff + 0x01
                }
            }
            block[2 + paddingSize] = 0x00
            block[(3 + paddingSize)...] = slice[...]
            guard let encrypted = rawRSA(block) else { return nil }
            output.append(contentsOf: encrypted)
            index += size
        }
        return output
    }

    /// 响应方向：服务器用私钥签名，这里用公钥还原后去掉填充头。
    private static func rsaDecrypt(_ input: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty, input.count % blockSize == 0 else { return nil }
        var output: [UInt8] = []
        var index = 0
        while index < input.count {
            let block = Array(input[index..<(index + blockSize)])
            guard let decrypted = rawRSA(block) else { return nil }
            // 填充头是 0x00 0x02 … 0x00：取第一个非首字节的 0 之后的内容。
            if let separator = decrypted.indices.dropFirst().first(where: { decrypted[$0] == 0 }) {
                output.append(contentsOf: decrypted[(separator + 1)...])
            }
            index += blockSize
        }
        return output
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func derInteger(_ content: [UInt8]) -> [UInt8] {
        [0x02] + derLength(content.count) + content
    }

    // MARK: XOR

    private static func deriveKey(_ seed: [UInt8], size: Int) -> [UInt8] {
        guard seed.count >= size else { return [UInt8](repeating: 0, count: size) }
        var key = [UInt8](repeating: 0, count: size)
        for index in 0..<size {
            var value = (Int(seed[index]) + Int(xorKeySeed[size * index])) & 0xff
            value ^= Int(xorKeySeed[size * (size - index - 1)])
            key[index] = UInt8(value)
        }
        return key
    }

    private static func xorTransform(_ data: inout [UInt8], _ key: [UInt8], offset: Int = 0) {
        guard !key.isEmpty else { return }
        let count = data.count - offset
        guard count > 0 else { return }
        let remainder = count % 4
        if remainder > 0 {
            for index in 0..<remainder {
                data[offset + index] ^= key[index % key.count]
            }
        }
        var index = remainder
        while index < count {
            data[offset + index] ^= key[(index - remainder) % key.count]
            index += 1
        }
    }

    private static func reverseTail(_ data: inout [UInt8], from start: Int) {
        var left = start
        var right = data.count - 1
        while left < right {
            data.swapAt(left, right)
            left += 1
            right -= 1
        }
    }
}
