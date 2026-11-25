import Foundation
import Combine
import LumaContentCore

/// 统一搜索的调度中心：并发调度各来源的 `SearchProviding`，
/// 汇总分区、计数与加载状态，并把这一轮检索登记到左下角后台任务。
///
/// 页面只声明自己需要哪些来源：
/// - 全局搜索：`SearchSourceKind.allCases`
/// - 某个模块内搜索：只传对应的来源（例如 `[.cinema]`）
@MainActor
final class SearchCenter: ObservableObject {
    let scopes: [SearchSourceKind]

    @Published private(set) var query = ""
    @Published private(set) var sections: [SearchSection] = []
    @Published private(set) var counts: [SearchSourceKind: Int] = [:]
    @Published private(set) var searchingSources: Set<SearchSourceKind> = []
    @Published private(set) var isSearching = false
    /// nil = 全部来源；否则只展示该来源。
    @Published var activeSource: SearchSourceKind?
    /// nil = 该来源内全部类型。
    @Published var activeKind: SearchHitKind?
    /// 当前来源内选中的「源」（网盘 / 影院范围 / 电视播放列表 / 资源站点）；nil = 全部源。
    @Published var activeOrigin: String?
    /// 当前来源内选中的分类（电视频道分组、资源分类、网盘目录）；nil = 全部分类。
    @Published var activeCategory: String?

    private let providers: [SearchSourceKind: any SearchProviding]
    /// 任务中心的落点：搜索结果登记到侧边栏底部的后台任务，结束进「任务记录」。
    private weak var store: LibraryStore?
    private let limit: Int
    private let debounceMilliseconds: Int
    private var task: Task<Void, Never>?
    /// 同一页面复用同一个任务 ID：连续输入不会在任务记录里刷出一堆「搜索」。
    private let jobID = UUID()

    init(scopes: [SearchSourceKind] = SearchSourceKind.allCases,
         providers: [any SearchProviding],
         store: LibraryStore? = nil,
         limit: Int = 40,
         debounceMilliseconds: Int = 260) {
        self.scopes = scopes
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.source, $0) })
        self.store = store
        self.limit = limit
        self.debounceMilliseconds = debounceMilliseconds
    }

    var totalCount: Int {
        sections.reduce(0) { $0 + $1.total }
    }

    func section(for source: SearchSourceKind) -> SearchSection? {
        sections.first { $0.source == source }
    }

    func count(for source: SearchSourceKind) -> Int {
        counts[source] ?? section(for: source)?.total ?? 0
    }

    /// 搜索框每次变化都调用；内部做防抖，连续输入只跑最后一轮。
    func setQuery(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        query = trimmed
        task?.cancel()
        activeOrigin = nil
        activeCategory = nil
        guard !trimmed.isEmpty else {
            clearResults()
            return
        }
        // 防抖窗口内也先进入「检索中」，避免结果区闪一下空态。
        sections = []
        counts = [:]
        searchingSources = Set(scopes)
        isSearching = true
        // 搜索一开始（含防抖等待）就登记任务：左下角任务条立刻能看到这一轮检索。
        beginJob(keyword: trimmed, total: scopes.count)
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounceMilliseconds) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self.run(trimmed)
        }
    }

    func setActiveSource(_ source: SearchSourceKind?) {
        // 模块关闭的来源不在本轮调度里，不要切到一个永远不会出结果的分区。
        if let source, !scopes.contains(source) { return }
        activeSource = source
        // 图库默认落在「全部」：图片可能为 0，而相簿 / 文件夹有内容，
        // 停在图片会让人以为整轮搜索都没结果。
        activeKind = nil
        activeOrigin = nil
        activeCategory = nil
    }

    /// 离开页面 / 清空搜索：停掉检索，并把任务条上的搜索收尾。
    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
        searchingSources = []
        // 取消不写记录：连续输入会自动打断上一次检索，任务记录里不该堆一串「已取消」。
        if let store, store.sourceJobCenter.progress[jobID] != nil {
            store.abandonSourceJob(jobID)
        }
    }

    func clearResults() {
        sections = []
        counts = [:]
        searchingSources = []
        isSearching = false
        activeSource = nil
        activeKind = nil
        activeOrigin = nil
        activeCategory = nil
        cancel()
    }

    // MARK: - 执行

    private func run(_ keyword: String) async {
        let running = scopes.compactMap { providers[$0] }
        guard !running.isEmpty else {
            isSearching = false
            searchingSources = []
            store?.finishSourceJob(jobID, message: "没有可用的搜索来源")
            return
        }

        sections = []
        counts = [:]
        searchingSources = Set(running.map(\.source))
        isSearching = true
        store?.updateSourceJob(jobID,
                               completed: 0,
                               total: running.count,
                               message: "正在检索 \(running.count) 个来源")

        var collected: [SearchSection] = []
        await withTaskGroup(of: SearchSection.self) { group in
            for provider in running {
                group.addTask { await provider.search(query: keyword, limit: self.limit) }
            }
            for await section in group {
                guard !Task.isCancelled, query == keyword else {
                    group.cancelAll()
                    return
                }
                collected.append(section)
                collected.sort { order($0.source) < order($1.source) }
                sections = collected
                counts[section.source] = section.total
                searchingSources.remove(section.source)
                let done = running.count - searchingSources.count
                store?.updateSourceJob(jobID,
                                       completed: done,
                                       total: running.count,
                                       message: "已检索 \(section.source.title) · 共 \(totalCount) 项")
            }
        }

        guard !Task.isCancelled, query == keyword else { return }
        isSearching = false
        searchingSources = []
        store?.finishSourceJob(jobID,
                               message: "共 \(totalCount) 项 · \(sections.count) 个来源")
    }

    private func beginJob(keyword: String, total: Int) {
        guard let store else { return }
        store.beginSourceJob(SourceJob(id: jobID,
                                       sourceID: .search,
                                       kind: .search,
                                       title: "搜索「\(keyword)」"),
                             cancel: { [weak self] in
                                 Task { @MainActor in self?.cancel() }
                             })
        store.updateSourceJob(jobID,
                              completed: 0,
                              total: total,
                              message: "正在准备检索 \(total) 个来源")
    }

    private func order(_ source: SearchSourceKind) -> Int {
        scopes.firstIndex(of: source) ?? scopes.count
    }
}
