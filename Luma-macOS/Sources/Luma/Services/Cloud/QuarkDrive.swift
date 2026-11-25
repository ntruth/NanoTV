import Foundation
import LumaContentCore

// MARK: - 夸克网盘（浏览器 Cookie 直连）
//
// 夸克没有面向个人的公开 OAuth，这里沿用网页 / PC 客户端的接口：
//   - 列目录：GET  /1/clouddrive/file/sort
//   - 视频播放：POST /1/clouddrive/file/v2/play/project
//   - 文件直链：POST /1/clouddrive/file/download
// 三者都要求携带浏览器登录后的完整 Cookie，因此 Cookie 存钥匙串（CloudCredentials）。

enum QuarkDrive {
    /// 允许本地联调时指向模拟服务。
    static var apiBase: String {
        ProcessInfo.processInfo.environment["LUMA_QUARK_API_BASE"]
            ?? "https://drive.quark.cn"
    }
    /// 必须伪装成夸克 PC 客户端：浏览器 UA 会被限制下载体积，转码播放接口也会返回 plf_invalid。
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 "
        + "Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    static let referer = "https://pan.quark.cn"

    /// 受限内容（risk_type ≠ 0）在夸克侧已被打码并禁止播放 / 下载，任何第三方客户端都拿不到地址。
    static let restrictedFileMessage = "该文件已被夸克标记为受限内容（risk_type ≠ 0），"
        + "转码与下载接口都返回 invalid file；可打开夸克网页端确认文件状态"

    /// 直链 / 缩略图请求都要带上的头。
    static func headers(cookie: String) -> [String: String] {
        [
            "Cookie": normalizedCookie(cookie),
            "User-Agent": userAgent,
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

    static func list(cookie: String, folderID: String, mountID: UUID? = nil) async throws -> [CloudEntry] {
        var entries: [CloudEntry] = []
        var page = 1
        let pageSize = 100
        var loggedMissingThumbnails = false

        while true {
            var components = URLComponents(string: apiBase + "/1/clouddrive/file/sort")
            components?.queryItems = [
                URLQueryItem(name: "pr", value: "ucpro"),
                URLQueryItem(name: "fr", value: "pc"),
                URLQueryItem(name: "uc_param_str", value: ""),
                URLQueryItem(name: "pdir_fid", value: folderID.isEmpty ? "0" : folderID),
                URLQueryItem(name: "_page", value: "\(page)"),
                URLQueryItem(name: "_size", value: "\(pageSize)"),
                URLQueryItem(name: "_fetch_total", value: "1"),
                URLQueryItem(name: "_fetch_sub_dirs", value: "0"),
                URLQueryItem(name: "_sort", value: "file_type:asc,updated_at:desc")
            ]
            guard let url = components?.url else { throw CloudOAuthError.api("地址无效") }

            let object = try await get(url, cookie: cookie, mountID: mountID)
            let data = object["data"] as? [String: Any] ?? [:]
            let list = data["list"] as? [[String: Any]] ?? []
            let parsed = list.compactMap { parseEntry($0) }
            entries.append(contentsOf: parsed)

            // 有些账号的列表接口不返回缩略图字段，记录一次字段名便于排查（不记录具体值）。
            if !loggedMissingThumbnails,
               !list.isEmpty,
               parsed.allSatisfy({ $0.thumbnailURL == nil }) {
                loggedMissingThumbnails = true
                let keys = list.first.map { $0.keys.sorted().joined(separator: ",") } ?? "-"
                Diagnostics.record("Quark 列表未返回缩略图字段，首条字段：\(keys)")
            }

            // metadata 可能挂在根节点，也可能在 data 里。
            let metadata = (data["metadata"] as? [String: Any])
                ?? (object["metadata"] as? [String: Any])
            let total = (metadata?["_total"] as? NSNumber)?.intValue
                ?? (metadata?["_total"] as? String).flatMap(Int.init)
                ?? entries.count
            if list.count < pageSize || entries.count >= total { break }
            page += 1
            if page > 50 { break }
        }
        return entries
    }

    // MARK: 视频播放

    /// 夸克网页播放器走转码播放接口，返回的 URL 可以直接交给 AVPlayer。
    static func videoPlayURL(fid: String, cookie: String, mountID: UUID?) async throws -> URL? {
        guard let url = URL(string: apiBase + "/1/clouddrive/file/v2/play/project?pr=ucpro&fr=pc") else {
            return nil
        }
        let body: [String: Any] = [
            "fid": fid,
            "resolutions": "low,normal,high,super,2k,4k",
            "supports": "fmp4_av,m3u8,dolby_vision"
        ]
        let object = try await post(url, body: body, cookie: cookie, mountID: mountID)
        let data = object["data"] as? [String: Any] ?? [:]
        let list = data["video_list"] as? [[String: Any]] ?? []
        for item in list {
            guard let info = item["video_info"] as? [String: Any],
                  let raw = info["url"] as? String, !raw.isEmpty,
                  let result = URL(string: raw) else { continue }
            return result
        }
        return nil
    }

    // MARK: 直链

    static func downloadURL(fid: String, cookie: String, mountID: UUID? = nil) async throws -> URL {
        guard let url = URL(string: apiBase + "/1/clouddrive/file/download?pr=ucpro&fr=pc") else {
            throw CloudOAuthError.api("地址无效")
        }
        do {
            let object = try await post(url, body: ["fids": [fid]], cookie: cookie, mountID: mountID)
            if let raw = downloadLink(in: object), let result = URL(string: raw) {
                return result
            }
            // 大文件可能返回异步任务：轮询完成后再取直链。
            if let taskID = taskID(in: object),
               let raw = try await waitForTask(taskID: taskID, cookie: cookie, mountID: mountID),
               let result = URL(string: raw) {
                return result
            }
            let keys = object.keys.sorted().joined(separator: ",")
            let dataKeys = (object["data"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "-"
            Diagnostics.record("Quark 下载响应缺少直链，字段：\(keys)；data：\(dataKeys)")
            throw CloudOAuthError.api(message(in: object) ?? "未获取到下载地址")
        } catch {
            Diagnostics.record("Quark 直链获取失败 fid=\(fid)：\(error.localizedDescription)")
            // 22001 invalid file：文件在列表里存在，但被夸克判为风险内容而拒绝下发。
            if case .api(let message)? = error as? CloudOAuthError,
               message.contains("invalid file") {
                throw CloudOAuthError.api(restrictedFileMessage)
            }
            throw error
        }
    }

    private static func waitForTask(taskID: String, cookie: String,
                                    mountID: UUID?) async throws -> String? {
        for index in 0..<8 {
            if index > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard var components = URLComponents(string: apiBase + "/1/clouddrive/task") else { return nil }
            components.queryItems = [
                URLQueryItem(name: "pr", value: "ucpro"),
                URLQueryItem(name: "fr", value: "pc"),
                URLQueryItem(name: "task_id", value: taskID),
                URLQueryItem(name: "retry_index", value: "\(index)")
            ]
            guard let url = components.url,
                  let object = try? await get(url, cookie: cookie, mountID: mountID) else { continue }
            let data = object["data"] as? [String: Any] ?? [:]
            let status = (data["status"] as? NSNumber)?.intValue ?? 0
            if status == 2 {
                if let raw = downloadLink(in: object) { return raw }
                if let raw = data["download_url"] as? String { return raw }
                if let list = data["list"] as? [[String: Any]],
                   let raw = list.first?["download_url"] as? String { return raw }
                return nil
            }
            if status == 3 { return nil }
        }
        return nil
    }

    // MARK: 删除

    /// 删除文件：网页端 / PC 客户端的 `file/delete`，fid_list 传文件 ID。
    static func delete(fids: [String], cookie: String, mountID: UUID? = nil) async throws {
        guard !fids.isEmpty else { return }
        guard let url = URL(string: apiBase + "/1/clouddrive/file/delete?pr=ucpro&fr=pc") else {
            throw CloudOAuthError.api("地址无效")
        }
        let object = try await post(url,
                                    body: ["fid_list": fids, "action_type": 2],
                                    cookie: cookie,
                                    mountID: mountID)
        let status = (object["status"] as? NSNumber)?.intValue ?? 0
        let code = (object["code"] as? NSNumber)?.intValue ?? 0
        guard status == 200, code == 0 else {
            throw CloudOAuthError.api(message(in: object) ?? "夸克拒绝删除（\(status)）")
        }
    }

    // MARK: 内部

    private static func parseEntry(_ item: [String: Any]) -> CloudEntry? {
        let fid: String
        if let value = item["fid"] as? String {
            fid = value
        } else if let value = item["fid"] as? NSNumber {
            fid = value.stringValue
        } else {
            return nil
        }
        guard let name = item["file_name"] as? String else { return nil }
        let fileType = (item["file_type"] as? NSNumber)?.intValue ?? 0
        let isDirectory = fileType == 0
        let size = (item["size"] as? NSNumber)?.int64Value ?? 0
        let category = (item["category"] as? NSNumber)?.intValue
        let objCategory = ((item["obj_category"] as? String)
            ?? (item["format_type"] as? String)
            ?? "").lowercased()
        let isVideo = category == 1 || objCategory == "video"

        var entry = CloudEntry(path: fid,
                               name: name,
                               isDirectory: isDirectory,
                               size: size,
                               modifiedAt: millisecondDate(item["updated_at"] ?? item["created_at"]),
                               contentType: isVideo ? "video/mp4" : nil)
        entry.remoteID = fid
        entry.thumbnailURL = (item["big_thumbnail"] as? String)
            ?? (item["thumbnail"] as? String)
            ?? (item["l_thumbnail"] as? String)
        entry.pixelWidth = (item["width"] as? NSNumber)?.intValue
        entry.pixelHeight = (item["height"] as? NSNumber)?.intValue
        if let raw = (item["duration"] as? NSNumber)?.doubleValue, raw > 0 {
            // 夸克列表里的时长单位是秒。
            entry.duration = raw
        }
        // risk_type 非 0（常见为 3）表示夸克已把文件判为风险内容：文件名会被打码，
        // 转码播放接口返回 plf_invalid，直链接口返回 22001 invalid file。
        let riskType = (item["risk_type"] as? NSNumber)?.intValue ?? 0
        let banned = (item["ban"] as? Bool) ?? false
        entry.isRestricted = riskType != 0 || banned
        return entry
    }

    private static func millisecondDate(_ raw: Any?) -> Date? {
        let value: Double?
        if let number = raw as? NSNumber {
            value = number.doubleValue
        } else if let text = raw as? String {
            value = Double(text)
        } else {
            value = nil
        }
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }

    private static func downloadLink(in object: [String: Any]) -> String? {
        if let list = object["data"] as? [[String: Any]],
           let raw = list.first?["download_url"] as? String, !raw.isEmpty {
            return raw
        }
        if let data = object["data"] as? [String: Any],
           let raw = data["download_url"] as? String, !raw.isEmpty {
            return raw
        }
        if let raw = object["download_url"] as? String, !raw.isEmpty {
            return raw
        }
        return nil
    }

    private static func taskID(in object: [String: Any]) -> String? {
        if let data = object["data"] as? [String: Any],
           let raw = data["task_id"] as? String, !raw.isEmpty {
            return raw
        }
        if let list = object["data"] as? [[String: Any]],
           let raw = list.first?["task_id"] as? String, !raw.isEmpty {
            return raw
        }
        return nil
    }

    private static func message(in object: [String: Any]) -> String? {
        (object["message"] as? String) ?? (object["error"] as? String)
    }

    private static func get(_ url: URL, cookie: String, mountID: UUID?) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(normalizedCookie(cookie), forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        return try await send(request, cookie: cookie, mountID: mountID)
    }

    private static func post(_ url: URL, body: [String: Any], cookie: String,
                             mountID: UUID?) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(normalizedCookie(cookie), forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, cookie: cookie, mountID: mountID)
    }

    private static func send(_ request: URLRequest, cookie: String,
                             mountID: UUID?) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            persistRenewedCookie(from: http, original: cookie, mountID: mountID)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (object["code"] as? NSNumber)?.intValue
            ?? (object["status"] as? NSNumber)?.intValue
        // 31001：登录失效；31003 / 31023：参数错误（多见于 Cookie 已过期）。
        if status == 401 || status == 403 || code == 31001 || code == 31003 {
            throw CloudOAuthError.notAuthorized
        }
        guard status == 200 else {
            throw CloudOAuthError.api(message(in: object) ?? "HTTP \(status)")
        }
        if let code, code != 0 {
            throw CloudOAuthError.api(message(in: object) ?? "code \(code)")
        }
        if object.isEmpty {
            throw CloudOAuthError.api("返回内容不是 JSON（HTTP \(status)）")
        }
        return object
    }

    /// 夸克会通过 Set-Cookie 轮换 __puus / __pus，写回钥匙串避免后续请求失效。
    private static func persistRenewedCookie(from response: HTTPURLResponse,
                                             original: String,
                                             mountID: UUID?) {
        guard let mountID,
              let url = response.url else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, element in
            if let key = element.key as? String, let value = element.value as? String {
                result[key] = value
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            .filter { $0.name == "__puus" || $0.name == "__pus" }
        guard !cookies.isEmpty else { return }
        var updated = normalizedCookie(original)
        for cookie in cookies {
            updated = merge(cookie: cookie.name, value: cookie.value, into: updated)
        }
        guard updated != normalizedCookie(original) else { return }
        CloudCredentials.setPassword(updated, for: mountID)
    }

    private static func merge(cookie name: String, value: String, into cookie: String) -> String {
        var pairs: [(String, String)] = cookie.split(separator: ";").compactMap { part in
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { return nil }
            let comps = piece.split(separator: "=", maxSplits: 1)
            return (String(comps[0]), comps.count > 1 ? String(comps[1]) : "")
        }
        if let index = pairs.firstIndex(where: { $0.0 == name }) {
            pairs[index] = (name, value)
        } else {
            pairs.append((name, value))
        }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    /// 会话统一由 `HTTPSessionPool` 建：超时 / 缓存 / Cookie 策略只在一处维护。
    static let session = HTTPSessionPool.shared.session(.cloud)
}
