import Foundation

/// 命令可用性：把「按钮什么时候能点」从视图里的零散判断收敛成一份策略。
/// 视图只提供上下文（当前源、选中数量、是否只读、是否在最近删除），策略给出结论。
public enum SourceCommand: String, CaseIterable, Sendable {
    /// 导出所选：只要求有选中项，只读源也能导出。
    case exportSelection
    /// 压缩所选：需要可写。
    case compressSelection
    /// 复制一份：需要可写。
    case duplicate
    /// 粘贴到当前视图：需要可写。
    case paste
    /// 批量更改：需要可写。
    case batchChange
    /// 打印：只要求有命令目标。
    case printSelection
    /// 复制：只要求有命令目标。
    case copy
    /// 移到最近删除：需要可写且不在最近删除。
    case deleteToTrash
    /// 永久删除：需要可写。
    case deletePermanently
    /// 收藏：需要支持收藏且当前视图允许。
    case favorite
    /// 播放当前内容条目：影视源 / 影院这类只读条目。
    case playItem
    /// 加入或移出稍后看：只读条目也允许。
    case watchlist
    /// 在浏览器打开原站：只读来源的兜底出口。
    case openSourceSite
}

/// 命令上下文：当前浏览会话 + 选择状态的一次快照。
public struct CommandContext: Sendable, Equatable {
    public var kind: SourceKind
    public var hasSelection: Bool
    public var hasCommandTargets: Bool
    public var isReadOnlyScope: Bool
    public var isTrash: Bool
    public var canFavorite: Bool
    /// 只读源里仍然允许删除的例外（例如「照片」当前图库可经 PhotoKit 移到最近删除）。
    public var canDelete: Bool
    /// 内容条目（影视源 / 影院）的可用性：与照片选择互不影响。
    public var canPlayItem: Bool
    public var canWatchlistItem: Bool
    public var canOpenSourceSite: Bool

    public init(kind: SourceKind,
                hasSelection: Bool,
                hasCommandTargets: Bool,
                isReadOnlyScope: Bool,
                isTrash: Bool,
                canFavorite: Bool,
                canDelete: Bool = false,
                canPlayItem: Bool = false,
                canWatchlistItem: Bool = false,
                canOpenSourceSite: Bool = false) {
        self.kind = kind
        self.hasSelection = hasSelection
        self.hasCommandTargets = hasCommandTargets
        self.isReadOnlyScope = isReadOnlyScope
        self.isTrash = isTrash
        self.canFavorite = canFavorite
        self.canDelete = canDelete
        self.canPlayItem = canPlayItem
        self.canWatchlistItem = canWatchlistItem
        self.canOpenSourceSite = canOpenSourceSite
    }

    /// 照片类命令只属于图库 / 云盘；电视、影院、资源站不该出现这些命令。
    public var supportsPhotoCommands: Bool {
        switch kind {
        case .library, .cloudMount:
            return true
        case .cinemaFeed, .catalogSite, .iptv:
            return false
        }
    }
}

/// 命令策略：视图只读它，不再各自拼 `.disabled(...)` 条件。
public struct CommandPolicy: Sendable, Equatable {
    public let context: CommandContext

    public init(context: CommandContext) {
        self.context = context
    }

    public func isEnabled(_ command: SourceCommand) -> Bool {
        // 内容条目命令与照片命令互斥：先按内容上下文判断，再进照片分支。
        switch command {
        case .playItem:
            return context.canPlayItem
        case .watchlist:
            return context.canWatchlistItem
        case .openSourceSite:
            return context.canOpenSourceSite
        default:
            break
        }
        guard context.supportsPhotoCommands else { return false }
        switch command {
        case .exportSelection:
            return context.hasSelection
        case .compressSelection:
            return context.hasSelection && !context.isReadOnlyScope
        case .duplicate, .batchChange:
            return context.hasCommandTargets && !context.isReadOnlyScope
        case .paste:
            return !context.isReadOnlyScope
        case .printSelection, .copy:
            return context.hasCommandTargets
        case .deleteToTrash:
            return context.hasCommandTargets && (context.canDelete || !context.isReadOnlyScope) && !context.isTrash
        case .deletePermanently:
            return context.hasCommandTargets && !context.isReadOnlyScope
        case .favorite:
            return context.hasCommandTargets && context.canFavorite
        case .playItem, .watchlist, .openSourceSite:
            // 内容条目命令已在上面处理；照片上下文不支持。
            return false
        }
    }
}
