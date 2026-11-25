import Foundation

/// 侧边栏层级折叠状态的本地持久化：退出后下次启动仍按上次的展开 / 收起展示。
enum SidebarStateStorage {
    enum Key {
        static let collapsedSections = "sidebar.state.collapsedSections"
        /// 默认收起的分区（媒体类型 / 场景）被用户主动展开后记录在这里。
        static let expandedSections = "sidebar.state.expandedSections"
        static let expandedFolders = "sidebar.state.expandedFolders"
        static let expandedSystemFolders = "sidebar.state.expandedSystemFolders"
        static let collapsedSystemLibraries = "sidebar.state.collapsedSystemLibraries"
        static let expandedCloudMounts = "sidebar.state.expandedCloudMounts"
        /// 每个网盘的「媒体类型 / 更多项目 / 场景 / 相簿」折叠状态按网盘 ID 分开保存。
        /// v3：网盘里默认只露出「影院」，四个分类分区全部收起，旧版本保存的展开态不再沿用。
        static func cloudDetailSections(_ mountID: UUID?) -> String {
            "sidebar.state.cloudDetail.v3.\(mountID?.uuidString ?? "none")"
        }
    }

    private static var defaults: UserDefaults { .standard }

    static func stringSet(_ key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    /// 是否已经保存过该键：用于区分「首次打开用默认收起」与「用户主动全部展开」。
    static func hasValue(_ key: String) -> Bool {
        defaults.object(forKey: key) != nil
    }

    static func save(_ key: String, _ values: Set<String>) {
        defaults.set(values.sorted(), forKey: key)
    }

    static func uuidSet(_ key: String) -> Set<UUID> {
        Set(stringSet(key).compactMap { UUID(uuidString: $0) })
    }

    static func save(_ key: String, _ values: Set<UUID>) {
        save(key, Set(values.map(\.uuidString)))
    }

    static func int64Set(_ key: String) -> Set<Int64> {
        Set(stringSet(key).compactMap { Int64($0) })
    }

    static func save(_ key: String, _ values: Set<Int64>) {
        save(key, Set(values.map(String.init)))
    }
}
