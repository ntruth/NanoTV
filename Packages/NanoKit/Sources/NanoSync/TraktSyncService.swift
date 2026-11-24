import Foundation
import NanoCore
import Observation

/// Trakt.tv OAuth 设备码授权会话
public struct TraktDeviceAuthSession: Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: String
    public let intervalSec: Int
}

/// Infuse Pro 招牌功能：Trakt.tv 双向观看进度 Scrobble 实时打点与已看记录云同步服务
@Observable
public final class TraktSyncService: @unchecked Sendable {
    public static let shared = TraktSyncService()

    public var clientID: String = ""
    public var clientSecret: String = ""
    public private(set) var accessToken: String = ""
    public private(set) var connectedUsername: String = ""
    public var isScrobbleEnabled: Bool = true

    private let tokenKeychainKey = "nano_trakt_access_token"
    private let clientIDKey = "nano_trakt_client_id"

    public init() {
        self.accessToken = iCloudKeychainVault.shared.readSecret(forKey: tokenKeychainKey) ?? ""
        self.clientID = iCloudKeychainVault.shared.readSecret(forKey: clientIDKey) ?? ""
    }

    public var isAuthorized: Bool {
        !accessToken.isEmpty
    }

    public func saveClientAppCredentials(clientID: String, clientSecret: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        iCloudKeychainVault.shared.saveSecret(self.clientID, forKey: clientIDKey, syncOverICloud: true)
    }

    /// 第一步：获取 Trakt 电视/桌面端扫码设备码（`https://trakt.tv/activate`）
    public func requestDeviceCode() async throws -> TraktDeviceAuthSession {
        guard !clientID.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        var req = URLRequest(url: URL(string: "https://api.trakt.tv/oauth/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID])

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verifyURL = json["verification_url"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        let interval = (json["interval"] as? Int) ?? 5
        return TraktDeviceAuthSession(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verifyURL,
            intervalSec: interval
        )
    }

    /// 第二步：轮询用户是否在手机上完成授权，成功后将 AccessToken 存入 iCloud Keychain 双端共享
    @MainActor
    public func pollForAccessToken(deviceCode: String) async throws -> Bool {
        var req = URLRequest(url: URL(string: "https://api.trakt.tv/oauth/device/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "code": deviceCode,
            "client_id": clientID,
            "client_secret": clientSecret
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["access_token"] as? String {
            self.accessToken = token
            iCloudKeychainVault.shared.saveSecret(token, forKey: tokenKeychainKey, syncOverICloud: true)
            await fetchCurrentProfile()
            return true
        }
        return false
    }

    @MainActor
    public func disconnect() {
        accessToken = ""
        connectedUsername = ""
        iCloudKeychainVault.shared.deleteSecret(forKey: tokenKeychainKey)
    }

    /// 实时向 Trakt 发送观影状态（`start` / `pause` / `stop`，进度 ≥80% 时 Trakt 自动标记为已看完）
    public func reportScrobble(
        action: String, // "start" | "pause" | "stop"
        tmdbID: Int?,
        isMovie: Bool,
        progressPercent: Double
    ) async {
        guard isScrobbleEnabled, isAuthorized, !clientID.isEmpty, let tmdbID else { return }
        guard let url = URL(string: "https://api.trakt.tv/scrobble/\(action)") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2", forHTTPHeaderField: "trakt-api-version")
        req.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let clampedProgress = max(0.0, min(100.0, progressPercent))
        var payload: [String: Any] = ["progress": clampedProgress]
        if isMovie {
            payload["movie"] = ["ids": ["tmdb": tmdbID]]
        } else {
            payload["show"] = ["ids": ["tmdb": tmdbID]]
        }

        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: req)
    }

    @MainActor
    private func fetchCurrentProfile() async {
        guard isAuthorized, let url = URL(string: "https://api.trakt.tv/users/settings") else { return }
        var req = URLRequest(url: url)
        req.setValue("2", forHTTPHeaderField: "trakt-api-version")
        req.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let user = json["user"] as? [String: Any],
           let username = user["username"] as? String {
            self.connectedUsername = username
        }
    }
}
