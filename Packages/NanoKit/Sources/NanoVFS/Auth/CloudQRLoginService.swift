import CryptoKit
import Foundation
import NanoCore

/// 115 / 夸克 / 百度网盘 双轨扫码登录服务（方案 A OpenAPI 设备码优先 + 方案 B TV/Web 扫码抓 Cookie 自动降级）
public actor CloudQRLoginService {
    public static let shared = CloudQRLoginService()

    private struct PendingContext {
        let driveType: StorageSourceType
        let track: CloudAuthTrack
        var extraParams: [String: String]
    }

    private var activeContexts: [String: PendingContext] = [:]

    public init() {}

    /// 发起扫码会话：若配置了 OpenAPI ClientID 且该网盘支持方案 A 则优先走方案 A，否则自动走方案 B
    public func createQRSession(
        for driveType: StorageSourceType,
        openAPIClientID: String? = nil,
        openAPIClientSecret: String? = nil
    ) async throws -> CloudQRAuthSession {
        switch driveType {
        case .drive115:
            if let clientID = openAPIClientID, !clientID.isEmpty {
                do {
                    return try await start115OpenAPISchemeA(clientID: clientID)
                } catch {
                    return try await start115TVSchemeB()
                }
            }
            return try await start115TVSchemeB()

        case .quark, .aliyun:
            // 夸克不支持个人官方直链 OpenAPI，自动启用方案 B 扫码登录
            return try await startQuarkSchemeB()

        case .baidu:
            if let clientID = openAPIClientID, !clientID.isEmpty,
               let clientSecret = openAPIClientSecret, !clientSecret.isEmpty {
                return try await startBaiduOpenAPISchemeA(clientID: clientID, clientSecret: clientSecret)
            }
            return try await startBaiduPassportSchemeB()

        default:
            throw VFSError.unauthorized("该存储类型使用直接地址挂载，无需网盘二维码登录")
        }
    }

    /// 轮询扫码状态：一旦手机端点击「确认登录」，自动提取 AccessToken (方案A) 或 Cookie (方案B)
    public func pollQRStatus(sessionID: String) async throws -> CloudQRPollState {
        guard let ctx = activeContexts[sessionID] else {
            return .expiredOrFailed(reason: "扫码会话不存在或已过期")
        }

        switch (ctx.driveType, ctx.track) {
        case (.drive115, .openAPISchemeA):
            return try await poll115OpenAPISchemeA(sessionID: sessionID, ctx: ctx)
        case (.drive115, .cookieSchemeB):
            return try await poll115TVSchemeB(sessionID: sessionID, ctx: ctx)
        case (.quark, _), (.aliyun, _):
            return try await pollQuarkSchemeB(sessionID: sessionID, ctx: ctx)
        case (.baidu, .openAPISchemeA):
            return try await pollBaiduOpenAPISchemeA(sessionID: sessionID, ctx: ctx)
        case (.baidu, _):
            return try await pollBaiduPassportSchemeB(sessionID: sessionID, ctx: ctx)
        default:
            return .expiredOrFailed(reason: "不支持的轮询通道")
        }
    }

    // MARK: - 1. 115 网盘：方案 A (PKCE 设备码) & 方案 B (TV 端二维码抓 Cookie)

    private func start115OpenAPISchemeA(clientID: String) async throws -> CloudQRAuthSession {
        let verifier = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = challengeData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var req = URLRequest(url: URL(string: "https://passportapi.115.com/open/authDeviceCode")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "client_id=\(clientID)&code_challenge=\(challenge)&code_challenge_method=sha256".data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let uid = dataObj["uid"] as? String,
              let qrcode = dataObj["qrcode"] as? String else {
            throw VFSError.schemeAUnsupportedFallbackRequired("115 OpenAPI 设备码申请失败")
        }

        let timeVal = String((dataObj["time"] as? Int) ?? Int(Date().timeIntervalSince1970))
        let sign = (dataObj["sign"] as? String) ?? ""
        activeContexts[uid] = PendingContext(
            driveType: .drive115,
            track: .openAPISchemeA,
            extraParams: ["uid": uid, "time": timeVal, "sign": sign, "verifier": verifier]
        )
        return CloudQRAuthSession(sessionID: uid, qrCodeContentOrURL: qrcode, resolvedTrack: .openAPISchemeA)
    }

    private func poll115OpenAPISchemeA(sessionID: String, ctx: PendingContext) async throws -> CloudQRPollState {
        let uid = ctx.extraParams["uid"] ?? ""
        let timeVal = ctx.extraParams["time"] ?? ""
        let sign = ctx.extraParams["sign"] ?? ""
        let statusURL = URL(string: "https://qrcodeapi.115.com/get/status/?uid=\(uid)&time=\(timeVal)&sign=\(sign)")!
        let (sData, _) = try await URLSession.shared.data(from: statusURL)
        guard let sJson = try JSONSerialization.jsonObject(with: sData) as? [String: Any],
              let d = sJson["data"] as? [String: Any] else {
            return .waitingScan
        }
        let status = (d["status"] as? Int) ?? 0
        if status == 0 { return .waitingScan }
        if status == 1 { return .scannedPendingConfirm }
        if status == 2 {
            var tokenReq = URLRequest(url: URL(string: "https://passportapi.115.com/open/deviceCodeToToken")!)
            tokenReq.httpMethod = "POST"
            tokenReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let verifier = ctx.extraParams["verifier"] ?? ""
            tokenReq.httpBody = "uid=\(uid)&code_verifier=\(verifier)".data(using: .utf8)
            let (tData, _) = try await URLSession.shared.data(for: tokenReq)
            if let tJson = try JSONSerialization.jsonObject(with: tData) as? [String: Any],
               let tokenData = tJson["data"] as? [String: Any],
               let accessToken = tokenData["access_token"] as? String {
                activeContexts.removeValue(forKey: sessionID)
                return .authorized(credentialPayload: accessToken, resolvedTrack: .openAPISchemeA)
            }
        }
        return .expiredOrFailed(reason: "115 二维码已过期，请刷新重试")
    }

    private func start115TVSchemeB() async throws -> CloudQRAuthSession {
        let tokenURL = URL(string: "https://qrcodeapi.115.com/api/1.0/tv/1.0/token")!
        let (data, _) = try await URLSession.shared.data(from: tokenURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let uid = dataObj["uid"] as? String,
              let qrcode = dataObj["qrcode"] as? String else {
            throw VFSError.networkFailure("获取 115 扫码二维码失败")
        }
        let timeVal = String((dataObj["time"] as? Int) ?? 0)
        let sign = (dataObj["sign"] as? String) ?? ""
        activeContexts[uid] = PendingContext(
            driveType: .drive115,
            track: .cookieSchemeB,
            extraParams: ["uid": uid, "time": timeVal, "sign": sign]
        )
        return CloudQRAuthSession(sessionID: uid, qrCodeContentOrURL: qrcode, resolvedTrack: .cookieSchemeB)
    }

    private func poll115TVSchemeB(sessionID: String, ctx: PendingContext) async throws -> CloudQRPollState {
        let uid = ctx.extraParams["uid"] ?? ""
        let timeVal = ctx.extraParams["time"] ?? ""
        let sign = ctx.extraParams["sign"] ?? ""
        let statusURL = URL(string: "https://qrcodeapi.115.com/get/status/?uid=\(uid)&time=\(timeVal)&sign=\(sign)")!
        let (sData, _) = try await URLSession.shared.data(from: statusURL)
        guard let sJson = try JSONSerialization.jsonObject(with: sData) as? [String: Any],
              let d = sJson["data"] as? [String: Any] else {
            return .waitingScan
        }
        let status = (d["status"] as? Int) ?? 0
        if status == 0 { return .waitingScan }
        if status == 1 { return .scannedPendingConfirm }
        if status == 2 {
            var loginReq = URLRequest(url: URL(string: "https://passportapi.115.com/app/1.0/tv/1.0/login_qrcode/")!)
            loginReq.httpMethod = "POST"
            loginReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            loginReq.httpBody = "account=\(uid)&app=tv".data(using: .utf8)
            let (lData, resp) = try await URLSession.shared.data(for: loginReq)
            var extractedCookies = extractCookies(from: resp, forURL: loginReq.url!)
            if extractedCookies.isEmpty,
               let lJson = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
               let lDataObj = lJson["data"] as? [String: Any],
               let cookieDict = lDataObj["cookie"] as? [String: String] {
                extractedCookies = cookieDict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            }
            if !extractedCookies.isEmpty {
                activeContexts.removeValue(forKey: sessionID)
                return .authorized(credentialPayload: extractedCookies, resolvedTrack: .cookieSchemeB)
            }
        }
        return .expiredOrFailed(reason: "115 扫码超时，请重新生成二维码")
    }

    // MARK: - 2. 夸克网盘：方案 B (uop.quark.cn 扫码提取 Cookie)

    private func startQuarkSchemeB() async throws -> CloudQRAuthSession {
        let url = URL(string: "https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=532&v=1.2")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let members = dataObj["members"] as? [String: Any],
              let token = members["token"] as? String else {
            throw VFSError.networkFailure("获取夸克网盘登录二维码 Token 失败")
        }
        let qrContent = "https://su.quark.cn/4_eMHBJ?token=\(token)&client_id=532&ssb=weblogin&uc_param_str=&uc_biz_str=S%3Acustom%7CC%3Atitlebar_hover_2"
        activeContexts[token] = PendingContext(driveType: .quark, track: .cookieSchemeB, extraParams: ["token": token])
        return CloudQRAuthSession(sessionID: token, qrCodeContentOrURL: qrContent, resolvedTrack: .cookieSchemeB)
    }

    private func pollQuarkSchemeB(sessionID: String, ctx: PendingContext) async throws -> CloudQRPollState {
        let token = ctx.extraParams["token"] ?? sessionID
        let pollURL = URL(string: "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=532&v=1.2&token=\(token)")!
        let (data, _) = try await URLSession.shared.data(from: pollURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .waitingScan
        }
        let status = (json["status"] as? Int) ?? 0
        if status == 2000000,
           let dataObj = json["data"] as? [String: Any],
           let members = dataObj["members"] as? [String: Any],
           let serviceTicket = members["service_ticket"] as? String {
            let infoURL = URL(string: "https://pan.quark.cn/account/info?st=\(serviceTicket)&lw=scan")!
            var infoReq = URLRequest(url: infoURL)
            infoReq.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
            let (_, resp) = try await URLSession.shared.data(for: infoReq)
            let cookies = extractCookies(from: resp, forURL: infoURL)
            if !cookies.isEmpty {
                activeContexts.removeValue(forKey: sessionID)
                return .authorized(credentialPayload: cookies, resolvedTrack: .cookieSchemeB)
            }
        }
        if status == 50004001 {
            return .waitingScan
        }
        if status == 50004002 {
            return .expiredOrFailed(reason: "夸克二维码已失效，请点击刷新")
        }
        return .waitingScan
    }

    // MARK: - 3. 百度网盘：方案 A (官方 OAuth 设备码) & 方案 B (Passport 扫码)

    private func startBaiduOpenAPISchemeA(clientID: String, clientSecret: String) async throws -> CloudQRAuthSession {
        var comps = URLComponents(string: "https://openapi.baidu.com/oauth/2.0/device/code")!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "device_code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: "basic,netdisk")
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verificationURL = json["verification_url"] as? String else {
            throw VFSError.schemeAUnsupportedFallbackRequired("百度网盘开放平台设备码获取失败")
        }
        let qrURL = "\(verificationURL)?code=\(userCode)"
        activeContexts[deviceCode] = PendingContext(
            driveType: .baidu,
            track: .openAPISchemeA,
            extraParams: ["device_code": deviceCode, "client_id": clientID, "client_secret": clientSecret]
        )
        return CloudQRAuthSession(
            sessionID: deviceCode,
            qrCodeContentOrURL: qrURL,
            userCodeHint: "手机扫码并确认授权码：\(userCode)",
            resolvedTrack: .openAPISchemeA
        )
    }

    private func pollBaiduOpenAPISchemeA(sessionID: String, ctx: PendingContext) async throws -> CloudQRPollState {
        var comps = URLComponents(string: "https://openapi.baidu.com/oauth/2.0/token")!
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "device_token"),
            URLQueryItem(name: "code", value: ctx.extraParams["device_code"]),
            URLQueryItem(name: "client_id", value: ctx.extraParams["client_id"]),
            URLQueryItem(name: "client_secret", value: ctx.extraParams["client_secret"])
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accessToken = json["access_token"] as? String {
            activeContexts.removeValue(forKey: sessionID)
            return .authorized(credentialPayload: accessToken, resolvedTrack: .openAPISchemeA)
        }
        return .waitingScan
    }

    private func startBaiduPassportSchemeB() async throws -> CloudQRAuthSession {
        let gid = UUID().uuidString
        let url = URL(string: "https://passport.baidu.com/v2/api/getqrcode?lp=pc&qrloginfrom=pc&gid=\(gid)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sign = json["sign"] as? String else {
            throw VFSError.networkFailure("获取百度网盘扫码会话失败")
        }
        let qrLoginContent = "https://wappass.baidu.com/wp/?qrlogin&t=\(Int(Date().timeIntervalSince1970))&sign=\(sign)"
        activeContexts[sign] = PendingContext(driveType: .baidu, track: .cookieSchemeB, extraParams: ["sign": sign])
        return CloudQRAuthSession(sessionID: sign, qrCodeContentOrURL: qrLoginContent, resolvedTrack: .cookieSchemeB)
    }

    private func pollBaiduPassportSchemeB(sessionID: String, ctx: PendingContext) async throws -> CloudQRPollState {
        let sign = ctx.extraParams["sign"] ?? sessionID
        let pollURL = URL(string: "https://passport.baidu.com/channel/unicast?channel_id=\(sign)&callback=")!
        let (data, resp) = try await URLSession.shared.data(from: pollURL)
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.contains("\"status\":1") {
            return .scannedPendingConfirm
        }
        if text.contains("\"v\":") {
            let cookies = extractCookies(from: resp, forURL: pollURL)
            if !cookies.isEmpty {
                activeContexts.removeValue(forKey: sessionID)
                return .authorized(credentialPayload: cookies, resolvedTrack: .cookieSchemeB)
            }
        }
        return .waitingScan
    }

    private func extractCookies(from response: URLResponse, forURL url: URL) -> String {
        var collected: [HTTPCookie] = []
        if let http = response as? HTTPURLResponse,
           let fields = http.allHeaderFields as? [String: String] {
            collected.append(contentsOf: HTTPCookie.cookies(withResponseHeaderFields: fields, for: url))
        }
        if let stored = HTTPCookieStorage.shared.cookies(for: url) {
            collected.append(contentsOf: stored)
        }
        var unique: [String: String] = [:]
        for c in collected {
            unique[c.name] = c.value
        }
        return unique.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}
