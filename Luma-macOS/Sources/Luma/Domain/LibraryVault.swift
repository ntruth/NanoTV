import Foundation

/// 图库保险库清单：记录 originals / database / renders 的相对路径、大小与 SHA-256。
/// 清单写在备份目录根部，恢复时只依赖清单，不读取任何第三方索引。
struct VaultManifest: Codable {
    var version: Int = 1
    var libraryName: String
    var createdAt: Date
    var entries: [VaultEntry]

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
}

struct VaultEntry: Codable, Identifiable, Hashable {
    /// 相对图库根目录的路径，例如 `originals/a/<uuid>.heic`。
    var path: String
    var size: Int64
    var sha256: String

    var id: String { path }
}

enum VaultIssueKind: String, Codable {
    case missing
    case modified
    case extra

    var title: String {
        switch self {
        case .missing: return "缺失"
        case .modified: return "损坏"
        case .extra: return "多余"
        }
    }
}

struct VaultIssue: Identifiable, Hashable {
    let id: String
    let kind: VaultIssueKind
    let path: String
    let detail: String

    init(kind: VaultIssueKind, path: String, detail: String) {
        self.id = "\(kind.rawValue)|\(path)"
        self.kind = kind
        self.path = path
        self.detail = detail
    }
}

struct VaultReport {
    let createdAt: Date
    let manifestCreatedAt: Date
    let checked: Int
    let issues: [VaultIssue]

    var missingCount: Int { issues.filter { $0.kind == .missing }.count }
    var modifiedCount: Int { issues.filter { $0.kind == .modified }.count }
    var extraCount: Int { issues.filter { $0.kind == .extra }.count }
    var isHealthy: Bool { issues.isEmpty }
}

struct VaultProgress {
    enum Phase: String {
        case scanning = "扫描"
        case backingUp = "备份"
        case verifying = "校验"
        case restoring = "恢复"
    }

    var phase: Phase
    var completed: Int
    var total: Int
    var bytes: Int64
    var message: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}
