import Foundation
import LumaContentCore

// MARK: - 阿里云盘 Cookie / 令牌登录
//
// 官方 OAuth 需要自己创建开发者应用，很多人只想快速接入。
// 这里用网页登录后得到的 refresh_token（通常夹在浏览器 Cookie / 本地存储的 token 里），
// 通过 AList 的公共换 token 服务换取开放平台 access_token，不需要申请应用。

enum AliyunCookieAuth {
    static var authBase: String {
        ProcessInfo.processInfo.environment["LUMA_ALIYUN_TOKEN_BASE"]
            ?? "https://api.alistgo.com"
    }

    /// 从用户粘贴的 Cookie / token 文本里找出 refresh_token 并换取访问令牌。
    static func token(from input: String) async throws -> CloudToken {
        guard let refresh = extractRefreshToken(input) else {
            throw CloudOAuthError.api(
                "没找到可用的 refresh_token。请打开 https://alist.nn.ci/tool/aliyundrive/request，"
                + "用阿里云盘 App 扫码授权，把页面上的 refresh_token（eyJ 开头）整段复制过来。"
                + "网页 localStorage 里的 token 是网页登录令牌，开放平台接口不接受。"
            )
        }
        return try await exchange(refreshToken: refresh)
    }

    static func exchange(refreshToken: String) async throws -> CloudToken {
        guard let url = URL(string: authBase + "/alist/ali_open/token") else {
            throw CloudOAuthError.token("地址无效")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200,
              let access = object["access_token"] as? String,
              !access.isEmpty else {
            let message = (object["message"] as? String)
                ?? (object["error"] as? String)
                ?? (object["error_description"] as? String)
                ?? "HTTP \(status)"
            // 换 token 服务只认开放平台令牌；网页登录令牌会被明确拒绝。
            if message.contains("aliyundrive open") {
                throw CloudOAuthError.token(
                    "这是阿里云盘网页登录令牌，换 token 服务只接受开放平台令牌。"
                    + "请用 https://alist.nn.ci/tool/aliyundrive/request 扫码获取 refresh_token（eyJ 开头）"
                )
            }
            throw CloudOAuthError.token(message)
        }
        let expires = (object["expires_in"] as? NSNumber)?.doubleValue
            ?? (object["expires_in"] as? String).flatMap(Double.init)
            ?? 7200
        return CloudToken(accessToken: access,
                          refreshToken: (object["refresh_token"] as? String) ?? refreshToken,
                          expiresAt: Date().addingTimeInterval(max(300, expires - 60)))
    }

    /// 支持两种粘贴内容：
    /// 1. JSON / 表单里的 refresh_token（含 Cookie 中的 refresh_token=…）
    /// 2. 整段就是 refresh_token（以 eyJ 开头的一长串）
    static func extractRefreshToken(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let patterns = [
            #""refresh_token"\s*:\s*"([^"]+)""#,
            #"refresh_token\s*=\s*([^;"\s&]+)"#
        ]
        for pattern in patterns {
            if let value = match(pattern, in: text), !value.isEmpty {
                return value
            }
        }

        // 直接粘贴了一整个 refresh_token：阿里云盘的 refresh_token 是 JWT，以 eyJ 开头。
        // 不能只按长度判断，否则用户误粘贴 sgcookie 之类的 Cookie 值也会被当成凭据。
        let compact = text.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        if compact.hasPrefix("ey"),
           compact.count > 40,
           !compact.contains(" "),
           !compact.contains(";"),
           !compact.contains("=") {
            return compact
        }

        return nil
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: range),
              result.numberOfRanges > 1,
              let valueRange = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    static let session = HTTPSessionPool.shared.session(.cloud)
}
