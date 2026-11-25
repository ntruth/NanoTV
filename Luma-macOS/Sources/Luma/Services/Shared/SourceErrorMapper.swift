import Foundation
import LumaContentCore

/// 把各模块自己的错误收敛成 `SourceError`，界面只需要一套错误卡与恢复动作。
/// 现有错误类型不删除，避免一次性改所有抛错点；新界面优先读取 `SourceError`。
enum SourceErrorMapper {
    static func map(_ error: Error) -> SourceError {
        if let sourceError = error as? SourceError {
            return sourceError
        }
        if let error = error as? CloudOAuthError {
            return mapCloud(error)
        }
        if let error = error as? CatalogError {
            return mapCatalog(error)
        }
        if let error = error as? WebDAVError {
            return mapWebDAV(error)
        }
        if let error = error as? SMBError {
            return mapSMB(error)
        }
        if let error = error as? URLError {
            return mapURL(error)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return mapURL(URLError(URLError.Code(rawValue: nsError.code)))
        }
        return SourceError(kind: .unavailable,
                           message: error.localizedDescription,
                           recovery: [.retry])
    }

    private static func mapCloud(_ error: CloudOAuthError) -> SourceError {
        switch error {
        case .missingCredentials, .unsupportedProvider:
            return SourceError(kind: .unsupported,
                               message: error.localizedDescription,
                               recovery: [.reconfigureSource])
        case .notAuthorized:
            return .unauthorized(error.localizedDescription)
        case .keychainDenied:
            return SourceError(kind: .keychainDenied,
                               message: error.localizedDescription,
                               recovery: [.reauthorize, .openSystemSettings])
        case .invalidCallback, .stateMismatch:
            return SourceError(kind: .unauthorized,
                               message: error.localizedDescription,
                               recovery: [.reauthorize, .retry])
        case .cancelled:
            return SourceError(kind: .cancelled, message: error.localizedDescription)
        case .timeout:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        case .token(_), .api(_):
            // Cookie 型网盘（夸克 / 115 / 阿里云盘）的失效经常只回一句「登录已过期 / 请重新登录」，
            // 不会给出 401。这里识别这类文案，直接归到「重新登录」，避免用户只看到「重试」。
            if isCookieExpired(message: error.localizedDescription) {
                return SourceError(kind: .unauthorized,
                                   message: error.localizedDescription,
                                   recovery: [.reauthorize, .retry])
            }
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry, .reauthorize])
        }
    }

    /// Cookie / 令牌失效的文案特征：网盘接口把过期写进 message，而不是 HTTP 状态码。
    private static func isCookieExpired(message: String) -> Bool {
        let text = message.lowercased()
        let hints = ["登录", "登陆", "重新登录", "授权失效", "授权过期", "cookie",
                     "token", "expired", "unauthorized", "invalid session", "失效", "过期"]
        return hints.contains { text.contains($0) }
    }

    private static func mapCatalog(_ error: CatalogError) -> SourceError {
        switch error {
        case .unsupportedProvider:
            return .unsupported(error.localizedDescription)
        case .invalidConfig(_):
            return SourceError(kind: .parse,
                               message: error.localizedDescription,
                               recovery: [.reconfigureSource])
        case .http(let status):
            return .http(status, message: error.localizedDescription)
        case .parse(_):
            return .parse(error.localizedDescription)
        case .decryption:
            return SourceError(kind: .parse,
                               message: error.localizedDescription,
                               recovery: [.reconfigureSource, .retry])
        case .tls(let host):
            return .tls(host)
        case .unavailable(let detail):
            return SourceError(kind: .unavailable,
                               message: detail ?? error.localizedDescription,
                               recovery: [.retry])
        }
    }

    private static func mapWebDAV(_ error: WebDAVError) -> SourceError {
        switch error {
        case .invalidURL:
            return SourceError(kind: .parse,
                               message: error.localizedDescription,
                               recovery: [.reconfigureSource])
        case .unauthorized, .forbidden:
            return .unauthorized(error.localizedDescription)
        case .notFound:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [])
        case .unsupported:
            return .unsupported(error.localizedDescription)
        case .exists:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [])
        case .status(let code):
            return .http(code, message: error.localizedDescription)
        case .transport(_):
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        case .invalidResponse:
            return .parse(error.localizedDescription)
        }
    }

    private static func mapSMB(_ error: SMBError) -> SourceError {
        switch error {
        case .invalidAddress:
            return SourceError(kind: .parse,
                               message: error.localizedDescription,
                               recovery: [.reconfigureSource])
        case .unreachable(_):
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        case .mountFailed(_):
            return SourceError(kind: .unauthorized,
                               message: error.localizedDescription,
                               recovery: [.reauthorize, .reconfigureSource])
        case .listFailed(_):
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        }
    }

    private static func mapURL(_ error: URLError) -> SourceError {
        switch error.code {
        case .cancelled:
            return SourceError(kind: .cancelled, message: "请求已取消")
        case .notConnectedToInternet, .networkConnectionLost, .timedOut:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            // 不少站点本身在线，只是被本地 DNS 拦成 0.0.0.0 / 无解析：
            // 直接把可执行的恢复办法写进提示，比「连不上」有用。
            return SourceError(kind: .unavailable,
                               message: "连不上站点，域名解析可能被拦截。"
                                   + "把系统 DNS 改成 223.5.5.5 或 8.8.8.8，"
                                   + "或开启代理后再重试。",
                               recovery: [.retry])
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .unauthorized(error.localizedDescription)
        case .serverCertificateUntrusted, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            return SourceError(kind: .tlsUntrusted,
                               message: error.localizedDescription,
                               recovery: [.allowInsecureTLS, .retry])
        default:
            return SourceError(kind: .unavailable,
                               message: error.localizedDescription,
                               recovery: [.retry])
        }
    }
}
