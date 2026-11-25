import Foundation

/// 用户可执行的恢复动作：界面据此显示「重试 / 重新登录 / 浏览器打开 / 重配」。
public enum RecoveryAction: Hashable, Codable, Sendable {
    case retry
    case reauthorize
    case openInBrowser(String)
    case reconfigureSource
    case allowInsecureTLS
    case openSystemSettings

    public var title: String {
        switch self {
        case .retry: return "重试"
        case .reauthorize: return "重新登录"
        case .openInBrowser: return "在浏览器中打开"
        case .reconfigureSource: return "重新配置来源"
        case .allowInsecureTLS: return "允许不受信任的证书"
        case .openSystemSettings: return "打开系统设置"
        }
    }
}

/// 统一的源错误：不再让云盘、资源、影院、电视各造一套错误模型。
public struct SourceError: Error, LocalizedError, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// 未授权 / 令牌失效。
        case unauthorized
        /// 钥匙串条目存在但无权读取。
        case keychainDenied
        /// 自签证书 / TLS 校验失败。
        case tlsUntrusted
        /// HTTP 状态码错误。
        case http
        /// 页面 / 播放列表 / JSON 解析失败。
        case parse
        /// 源不可达。
        case unavailable
        /// 用户取消。
        case cancelled
        /// 站点要求人机验证 / WAF 拦截。
        case blocked
        /// 当前源不支持这个能力。
        case unsupported
    }

    public var kind: Kind
    public var message: String
    public var statusCode: Int?
    public var recovery: [RecoveryAction]

    public init(kind: Kind,
                message: String,
                statusCode: Int? = nil,
                recovery: [RecoveryAction] = []) {
        self.kind = kind
        self.message = message
        self.statusCode = statusCode
        self.recovery = recovery
    }

    public var errorDescription: String? { message }

    public var requiresReauthorization: Bool {
        kind == .unauthorized || kind == .keychainDenied
    }

    public static func unauthorized(_ message: String = "授权已失效，请重新登录") -> SourceError {
        SourceError(kind: .unauthorized, message: message, recovery: [.reauthorize])
    }

    public static func http(_ status: Int, message: String? = nil) -> SourceError {
        SourceError(kind: .http,
                    message: message ?? "来源返回 HTTP \(status)",
                    statusCode: status,
                    recovery: status == 401 || status == 403 ? [.reauthorize, .retry] : [.retry])
    }

    public static func parse(_ message: String) -> SourceError {
        SourceError(kind: .parse, message: message, recovery: [.retry, .reconfigureSource])
    }

    public static func unavailable(_ message: String) -> SourceError {
        SourceError(kind: .unavailable, message: message, recovery: [.retry])
    }

    public static func unsupported(_ message: String) -> SourceError {
        SourceError(kind: .unsupported, message: message)
    }

    public static func tls(_ host: String) -> SourceError {
        SourceError(kind: .tlsUntrusted,
                    message: "与 \(host) 的 HTTPS 证书校验失败（可能是自签名、已过期或域名不匹配）。",
                    recovery: [.allowInsecureTLS, .retry])
    }
}
