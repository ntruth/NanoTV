import SwiftUI
import LumaContentCore

/// 统一的源错误卡片：云盘、网络资源、影院（后续电视）共用同一套文案与恢复动作。
/// 调用方只负责把 `RecoveryAction` 映射到自己的重试 / 重新登录 / 打开浏览器。
struct SourceErrorView: View {
    let error: SourceError
    var onAction: (RecoveryAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(error.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            if !error.recovery.isEmpty {
                HStack(spacing: 8) {
                    ForEach(error.recovery, id: \.self) { action in
                        Button(action.title) { onAction(action) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.8)
        )
    }

    private var title: String {
        switch error.kind {
        case .unauthorized: return "需要重新授权"
        case .keychainDenied: return "无法读取保存的凭据"
        case .tlsUntrusted: return "证书校验失败"
        case .http: return error.statusCode.map { "请求被拒绝（HTTP \($0)）" } ?? "请求被拒绝"
        case .parse: return "返回内容无法解析"
        case .unavailable: return "来源暂时不可用"
        case .cancelled: return "操作已取消"
        case .blocked: return "站点要求先完成验证"
        case .unsupported: return "当前来源不支持"
        }
    }

    private var iconName: String {
        switch error.kind {
        case .unauthorized, .keychainDenied: return "lock.trianglebadge.exclamationmark"
        case .tlsUntrusted: return "lock.shield"
        case .blocked: return "hand.raised"
        case .parse: return "doc.questionmark"
        case .cancelled: return "xmark.circle"
        case .unsupported: return "nosign"
        case .http, .unavailable: return "wifi.exclamationmark"
        }
    }

    private var tint: Color {
        switch error.kind {
        case .unauthorized, .keychainDenied, .tlsUntrusted, .blocked: return .orange
        case .cancelled: return .secondary
        case .http, .parse, .unavailable, .unsupported: return .red
        }
    }
}
