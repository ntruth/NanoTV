import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 手动匹配面板。

// MARK: - 手动匹配

struct CinemaMatchSheet: View {
    let entry: CinemaEntry?
    let photos: [PhotoItem]
    /// 来自文件夹匹配时的目录链：用来补季 / 剧名，比单个文件更可靠。
    let folderHint: String?
    let onApplied: () -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// 两步：先选片，再给剧集排季集（参考芝杜的批量匹配流程）。
    enum Step { case search, episodes }

    /// 手动匹配的来源：可以只查某一个，也可以全部一起查。
    enum MatchSource: String, CaseIterable, Identifiable {
        case all
        case tmdb
        case douban
        case tvdb

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .tmdb: return "TMDB"
            case .douban: return "豆瓣"
            case .tvdb: return "TVDB"
            }
        }

        var providers: [CinemaProvider]? {
            switch self {
            case .all: return nil
            case .tmdb: return [.tmdb]
            case .douban: return [.douban]
            case .tvdb: return [.tvdb]
            }
        }
    }

    /// 集号来源：文件名里的数字，或按顺序编号（同名多版本共用一集）。
    enum EpisodeMode: String, CaseIterable, Identifiable {
        case fileName
        case sequential

        var id: String { rawValue }
        var title: String {
            switch self {
            case .fileName: return "文件名数字"
            case .sequential: return "按顺序"
            }
        }
    }

    struct EpisodeRow: Identifiable {
        let photo: PhotoItem
        var text: String
        /// 从 SxxExx / 纯数字文件名里解析出的原始编号。
        var detected: Int?
        var detectedSeason: Int?
        /// 去掉清晰度 / 版本标记后的文件名主干，用来把 4K 与普通版认成同一集。
        var normalizedName: String

        var id: UUID { photo.id }
    }

    @State private var query: String
    @State private var isTV: Bool
    @State private var yearText: String
    @State private var results: [CinemaMatch] = []
    /// 匹配来源：默认全部一起查，也可以只查某一个。
    @AppStorage("cinema_match_source") private var matchSource: MatchSource = .all
    @State private var selectedKey: String?
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var step: Step = .search
    @State private var chosenMatch: CinemaMatch?
    @State private var season = 1
    /// 同目录同名（4K / 1080p 等）一次套用，省得逐个版本点。
    @State private var matchSiblings = true
    @State private var episodeMode: EpisodeMode = .fileName
    /// 集号 = 文件名数字 + 偏移；顺序模式下等于「起始集 - 1」。
    @State private var episodeOffset = 0
    @State private var rows: [EpisodeRow] = []
    /// 智能助手：补充要求、运行状态与回填结果。
    @State private var aiNote = ""
    @State private var showAIPanel = false
    @State private var aiRunning = false
    @State private var aiMessage: String?
    @State private var aiError: String?
    /// 静默自动匹配：不打开助手面板，跑完直接回填；期间整页锁住，可手动解锁。
    @State private var aiLocked = false
    @State private var aiTask: Task<Void, Never>?
    /// 应用助手结果时不要触发「按模式重算」，否则会覆盖模型给的集号。
    @State private var suppressAutoRefresh = false

    init(entry: CinemaEntry, onApplied: @escaping () -> Void) {
        self.entry = entry
        self.photos = []
        self.folderHint = entry.folderHint
        self.onApplied = onApplied
        _query = State(initialValue: entry.title)
        _isTV = State(initialValue: entry.kind == .tv)
        _yearText = State(initialValue: entry.year.map(String.init) ?? "")
    }

    /// 相簿 / 网格直接手动匹配：不必先进入影院，也不必已经刮削过。
    /// `folderHint` 传入所在目录链后，纯数字文件名也能正确补季。
    init(photos: [PhotoItem], folderHint: String? = nil, onApplied: @escaping () -> Void = {}) {
        self.entry = nil
        self.photos = photos
        self.folderHint = folderHint
        self.onApplied = onApplied
        let first = photos.first
        let parsed = CinemaScraper.parse(filename: first?.displayFilename ?? "")
        _query = State(initialValue: parsed.title)
        _isTV = State(initialValue: parsed.isTV)
        _yearText = State(initialValue: parsed.year.map(String.init) ?? "")
    }

    var targetFilename: String {
        if let entry { return entry.file.filename }
        if photos.count > 1 {
            return "\(photos.count) 个视频 · 各自按文件名解析季集"
        }
        return photos.first?.displayFilename ?? ""
    }

    var body: some View {
        ZStack {
            Group {
                switch step {
                case .search:
                    searchStep
                case .episodes:
                    episodeStep
                }
            }
            // 静默匹配期间整页不可操作，只留「手动解锁」一个出口。
            .disabled(aiLocked)

            if aiLocked {
                Color.black.opacity(0.30)
                lockCard
            }
        }
        .padding(18)
        .frame(width: step == .episodes ? 760 : 680, height: 540)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(aiLocked)
        .task {
            if !hasSearched {
                await search()
            }
        }
    }

    /// 静默匹配的锁定卡片：进度 + 解锁出口。
    var lockCard: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("智能助手正在排 \(rows.count) 个文件的季集…")
                .font(.system(size: 11.5, weight: .semibold))
            Text("完成后自动回填集号；也可以现在手动解锁，助手的结果将不再写入。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("手动解锁") { unlockAIMatching() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    var searchStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchBar
            Divider()
            resultList
            Divider()
            footer
        }
    }

    // MARK: 季集映射

    var episodeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            episodeHeader
            episodeControls
            Divider()
            episodeList
            Divider()
            episodeFooter
        }
    }

    var episodeHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                if let url = chosenMatch?.posterURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else {
                    Color.primary.opacity(0.06)
                }
            }
            .frame(width: 40, height: 60)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("季集映射")
                    .font(.system(size: 16, weight: .bold))
                Text(episodeSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("换个匹配") { step = .search }
                .controlSize(.small)
        }
    }

    var episodeSubtitle: String {
        var parts: [String] = []
        if let match = chosenMatch {
            parts.append(match.title)
            if let year = match.year { parts.append(String(year)) }
        }
        parts.append("\(photos.count) 个视频")
        parts.append("预填自文件名，可逐条改")
        return parts.joined(separator: " · ")
    }

    var episodeControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 14) {
                Stepper(value: $season, in: 1...99) {
                    Text("第 \(season) 季")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 62, alignment: .leading)
                }
                .controlSize(.small)

                Picker("", selection: $episodeMode) {
                    ForEach(EpisodeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: episodeMode) { _, _ in
                    guard !suppressAutoRefresh else { return }
                    refreshAssignments()
                }

                Stepper(value: $episodeOffset, in: -99...99) {
                    Text(episodeOffset == 0
                         ? "偏移 0"
                         : "偏移 \(episodeOffset > 0 ? "+" : "")\(episodeOffset)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 62, alignment: .leading)
                }
                .controlSize(.small)
                .onChange(of: episodeOffset) { _, _ in
                    guard !suppressAutoRefresh else { return }
                    refreshAssignments()
                }

                if episodeMode == .fileName, let minNumber = detectedNumberRange.min, minNumber > 1 {
                    Button("把 \(minNumber) 当作第 1 集") {
                        episodeOffset = 1 - minNumber
                        refreshAssignments()
                    }
                    .controlSize(.small)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text(assignmentSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("季与集号会写进影院条目，之后详情页按季集排序、自动接下一集。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)

                // 静默自动匹配：不打开助手面板，模型排完直接回填。
                Button {
                    runSilentAIPlan()
                } label: {
                    Label(aiLocked ? "自动匹配中…" : "智能助手自动匹配",
                          systemImage: "sparkles")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(LumaBrand.amber)
                .disabled(aiRunning || rows.isEmpty)
                .help("静默交给智能助手：不打开界面，排好后自动回填集号；过程中可手动解锁")

                Button {
                    showAIPanel = true
                } label: {
                    Label(aiRunning ? "助手排集中…" : "交给助手", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .disabled(aiRunning || rows.isEmpty)
                .popover(isPresented: $showAIPanel, arrowEdge: .bottom) {
                    aiPanel
                }
                .help("把剧名、季、文件和补充要求交给大模型，由它调用工具回填集号")

                Button {
                    prepareEpisodes(resetSeason: false)
                } label: {
                    Label("按文件名重新识别", systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)

                Button {
                    sortRowsByEpisode()
                } label: {
                    Label("按集号排序", systemImage: "arrow.up.arrow.down")
                }
                .controlSize(.small)
            }

            if aiRunning || aiMessage != nil || aiError != nil {
                HStack(spacing: 6) {
                    if aiRunning {
                        ProgressView().controlSize(.mini)
                    }
                    if let aiMessage {
                        Text(aiMessage)
                            .foregroundStyle(LumaBrand.amber)
                    }
                    if let aiError {
                        Text(aiError)
                            .foregroundStyle(LumaBrand.coral)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var detectedNumberRange: (min: Int?, max: Int?) {
        let values = rows.compactMap(\.detected)
        return (values.min(), values.max())
    }

    /// 多少集、多少文件、有多少文件是同集多版本。
    var assignmentSummary: String {
        let assigned = rows.filter { (Int($0.text.trimmingCharacters(in: .whitespaces)) ?? 0) > 0 }
        let groups = Dictionary(grouping: assigned, by: { $0.text }).count
        var summary = "\(groups) 集 · \(rows.count) 个文件"
        if rows.count > groups, groups > 0 {
            summary += " · \(rows.count - groups) 个同集多版本"
        }
        return summary
    }

    // MARK: 智能助手

    /// 把剧名、季、文件事实与用户要求交给大模型；模型通过工具回填集号。
    var aiPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(LumaBrand.amber)
                Text("交给智能助手")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("把剧名、第 \(season) 季、\(rows.count) 个文件和你下面的要求交给 \(store.aiConfig.model.isEmpty ? "大模型" : store.aiConfig.model)，由它调用工具回填集号。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("补充要求，例如「11 当作第 1 集」「13 之后缺一集」",
                      text: $aiNote,
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            if let aiError {
                Text(aiError)
                    .font(.system(size: 10))
                    .foregroundStyle(LumaBrand.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if aiRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在核对 \(rows.count) 个文件…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("取消") { showAIPanel = false }
                    .controlSize(.small)
                Button("开始匹配") { runAIPlan() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaBrand.amber)
                    .disabled(aiRunning || rows.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    func runAIPlan() {
        guard !aiRunning, !rows.isEmpty else { return }
        aiRunning = true
        aiError = nil
        aiMessage = nil
        showAIPanel = false
        let snapshot = rows
        let request = aiMatchRequest()
        Task { @MainActor in
            do {
                let plan = try await store.aiPlanEpisodeMapping(request)
                applyAIPlan(plan, snapshot: snapshot)
            } catch {
                aiError = error.localizedDescription
            }
            aiRunning = false
        }
    }

    /// 静默自动匹配：不打开助手面板，跑完直接把集号回填到列表；
    /// 期间整页锁住，只留「手动解锁」——解锁后到达的结果直接丢弃。
    func runSilentAIPlan() {
        guard !aiRunning, !rows.isEmpty else { return }
        aiRunning = true
        aiLocked = true
        aiError = nil
        aiMessage = nil
        let snapshot = rows
        let request = aiMatchRequest()
        aiTask = Task { @MainActor in
            defer {
                aiRunning = false
                aiLocked = false
                aiTask = nil
            }
            do {
                let plan = try await store.aiPlanEpisodeMapping(request)
                guard !Task.isCancelled else { return }
                applyAIPlan(plan, snapshot: snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                aiError = error.localizedDescription
            }
        }
    }

    /// 手动解锁：取消静默匹配，之后返回的结果不再写入。
    func unlockAIMatching() {
        aiTask?.cancel()
        aiTask = nil
        aiLocked = false
        aiRunning = false
        aiMessage = "已手动解锁，助手结果已丢弃"
    }

    /// 静默与弹窗两条路径共用同一份请求：剧名、季、文件事实与补充要求。
    func aiMatchRequest() -> CinemaAIMatchRequest {
        let note = aiNote.trimmingCharacters(in: .whitespacesAndNewlines)
        return CinemaAIMatchRequest(
            title: chosenMatch?.title ?? query,
            year: chosenMatch?.year ?? Int(yearText.trimmingCharacters(in: .whitespaces)),
            season: season,
            files: rows.enumerated().map { index, row in
                CinemaAIMatchFile(index: index + 1,
                                  filename: row.photo.displayFilename,
                                  detectedEpisode: row.detected,
                                  durationSeconds: row.photo.duration,
                                  sizeBytes: row.photo.fileSize)
            },
            note: note.isEmpty ? nil : note
        )
    }

    func applyAIPlan(_ plan: CinemaAIMatchPlan, snapshot: [EpisodeRow]) {
        suppressAutoRefresh = true
        if let mode = plan.mode {
            episodeMode = mode == "sequential" ? .sequential : .fileName
        }
        if let offset = plan.offset {
            episodeOffset = max(-99, min(99, offset))
        }
        var applied = 0
        for (index, episode) in plan.assignments {
            guard index >= 1, index <= snapshot.count else { continue }
            let id = snapshot[index - 1].photo.id
            if let rowIndex = rows.firstIndex(where: { $0.id == id }) {
                rows[rowIndex].text = String(episode)
                applied += 1
            }
        }
        sortRowsByEpisode()
        let episodeCount = Set(plan.assignments.values).count
        var message = "助手已排好 \(episodeCount) 集 · \(applied) 个文件"
        if applied < rows.count {
            message += "（\(rows.count - applied) 个未给集号）"
        }
        if let note = plan.note, !note.isEmpty {
            message += " · \(note)"
        }
        aiMessage = message
        // 等 onChange 走完再恢复，避免模式 / 偏移把模型给的集号重算掉。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            suppressAutoRefresh = false
        }
    }

    var episodeList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    episodeRow(index: index, row: row)
                }
            }
            .padding(.vertical, 2)
        }
    }

    func episodeRow(index: Int, row: EpisodeRow) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)

            PhotoThumbnailView(photo: row.photo, purpose: .cover(80))
                .frame(width: 64, height: 36)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(row.photo.displayFilename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rowSourceText(row))
                    .font(.system(size: 9))
                    .foregroundStyle(row.detected == nil && episodeMode == .fileName
                                     ? Color.secondary
                                     : LumaBrand.amber.opacity(0.85))
            }

            Spacer(minLength: 0)

            if episodeShareCount(row) > 1 {
                Text("×\(episodeShareCount(row))")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            Text("E")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("", text: episodeBinding(row.id))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.center)

            Text(episodeBadge(row))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(LumaBrand.amber)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(7)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    var episodeFooter: some View {
        HStack(spacing: 10) {
            Text("已分配 \(assignedCount)/\(rows.count) 个文件 · \(assignmentSummary) · 第 \(season) 季")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("返回") { step = .search }
                .controlSize(.small)
            Button("取消") { dismiss() }
                .controlSize(.small)
            Button("应用 \(rows.count) 个文件") { applyEpisodes() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(LumaBrand.amber)
                .disabled(assignedCount == 0)
        }
    }

    func rowSourceText(_ row: EpisodeRow) -> String {
        if episodeMode == .fileName {
            if let detected = row.detected { return "文件名数字 \(detected)" }
            return "缺号 · 已顺序补齐"
        }
        return "按顺序编号 · 同名版本共用集号"
    }

    func episodeShareCount(_ row: EpisodeRow) -> Int {
        let text = row.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 1 }
        return rows.filter { $0.text.trimmingCharacters(in: .whitespaces) == text }.count
    }

    func episodeBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { rows.first(where: { $0.id == id })?.text ?? "" },
            set: { value in
                if let index = rows.firstIndex(where: { $0.id == id }) {
                    rows[index].text = value
                }
            }
        )
    }

    func episodeBadge(_ row: EpisodeRow) -> String {
        let episode = Int(row.text.trimmingCharacters(in: .whitespaces)) ?? 0
        guard episode > 0 else { return "S\(pad(season))E—" }
        return "S\(pad(season))E\(pad(episode))"
    }

    func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }

    var assignedCount: Int {
        rows.filter { (Int($0.text.trimmingCharacters(in: .whitespaces)) ?? 0) > 0 }.count
    }

    /// 进映射页：先按文件名自然顺序排，再尝试从 SxxExx 或纯数字文件名取集号。
    /// 文件名就是数字（11.mkv / 13 4K.mkv）时按数字识别；完全没数字才退回顺序编号。
    func prepareEpisodes(resetSeason: Bool = true) {
        let sorted = photos.sorted {
            $0.displayFilename.localizedStandardCompare($1.displayFilename) == .orderedAscending
        }
        let newRows = sorted.map { photo -> EpisodeRow in
            let parsed = parseFilename(photo)
            let loose = looseEpisodeNumber(photo.displayFilename)
            return EpisodeRow(photo: photo,
                              text: "",
                              detected: parsed.episode ?? loose,
                              detectedSeason: parsed.season,
                              normalizedName: normalizedStem(photo.displayFilename))
        }
        if resetSeason {
            season = newRows.compactMap(\.detectedSeason).first ?? 1
        }
        rows = newRows
        episodeMode = newRows.contains(where: { $0.detected != nil }) ? .fileName : .sequential
        episodeOffset = 0
        refreshAssignments()
    }

    /// 按当前模式重新分配集号；同名多版本永远落到同一集。
    func refreshAssignments() {
        guard !rows.isEmpty else { return }
        if episodeMode == .fileName, rows.contains(where: { $0.detected != nil }) {
            for index in rows.indices {
                if let detected = rows[index].detected {
                    rows[index].text = String(max(1, detected + episodeOffset))
                } else {
                    rows[index].text = ""
                }
            }
            // 少数没带编号的文件：接在已有最大值之后顺序补齐。
            var next = rows.compactMap { Int($0.text) }.max() ?? 0
            for index in rows.indices where rows[index].text.isEmpty {
                next += 1
                rows[index].text = String(next)
            }
        } else {
            // 顺序模式：按文件名主干分组，4K / 1080P 等版本共用一集。
            var assigned: [String: Int] = [:]
            var next = max(1, 1 + episodeOffset)
            for index in rows.indices {
                let fallback = rows[index].photo.id.uuidString
                let key = rows[index].normalizedName.isEmpty ? fallback : rows[index].normalizedName
                if let existing = assigned[key] {
                    rows[index].text = String(existing)
                } else {
                    assigned[key] = next
                    rows[index].text = String(next)
                    next += 1
                }
            }
        }
        sortRowsByEpisode()
    }

    func sortRowsByEpisode() {
        rows.sort { lhs, rhs in
            let left = Int(lhs.text.trimmingCharacters(in: .whitespaces)) ?? Int.max
            let right = Int(rhs.text.trimmingCharacters(in: .whitespaces)) ?? Int.max
            if left != right { return left < right }
            return lhs.photo.displayFilename.localizedStandardCompare(rhs.photo.displayFilename)
                == .orderedAscending
        }
    }

    /// 去掉 4K / HDR / 编码 / 音轨等版本标记，得到用于「同名多版本」判断的主干。
    func normalizedStem(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let pattern = #"(?i)(?<![a-z0-9])(4k|8k|2160p|1080p|720p|480p|hdr10\+?|hdr|dv|dolby[ .]?vision|remux|web[- .]?dl|webrip|bluray|bdrip|x265|x264|h[ .]?265|h[ .]?264|hevc|avc|aac|ddp?[ .]?\d(?:[ .]\d)?|atmos|truehd|dts(?:-hd)?(?:[ .]?ma)?|\d{2,3}fps|高码版?|国语|国粤|双语|中字|中文字幕|简繁|英字幕)(?![a-z0-9])"#
        let stripped = base.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        let collapsed = stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return collapsed.isEmpty ? base.lowercased() : collapsed
    }

    /// `11.mkv`、`13 4K.mkv`、`谷雨 11.mkv` 这类把结尾数字当集号。
    func looseEpisodeNumber(_ filename: String) -> Int? {
        let stem = normalizedStem(filename)
        guard !stem.isEmpty else { return nil }
        if stem.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil {
            return Int(stem)
        }
        if stem.range(of: #"^.+[\s\-_\.]\d{1,3}$"#, options: .regularExpression) != nil,
           let tail = stem.split(whereSeparator: { " -_.".contains($0) }).last,
           let value = Int(tail) {
            return value
        }
        return nil
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("手动匹配")
                .font(.system(size: 16, weight: .bold))
            Text(targetFilename)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let folderHint, !folderHint.isEmpty {
                Text("目录：\(folderHint)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let entry {
                Text(entry.matched
                     ? "当前匹配：\(entry.title)\(entry.year.map { "（\($0)）" } ?? "")"
                     : "当前未识别 · 选择候选项后只改写这一批文件")
                    .font(.system(size: 9.5))
                    .foregroundStyle(entry.matched ? LumaBrand.amber.opacity(0.85) : LumaBrand.coral)
                    .lineLimit(1)
            }
        }
    }

    var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("输入片名 / 剧名", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await search() }
                    }

                Picker("", selection: $isTV) {
                    Text("电影").tag(false)
                    Text("剧集").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 118)

                TextField("年份", text: $yearText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)

                Button {
                    Task { await search() }
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).count < 2)
            }

            HStack(spacing: 8) {
                Text("匹配来源")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Picker("", selection: $matchSource) {
                    ForEach(MatchSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                .onChange(of: matchSource) { _, _ in
                    guard hasSearched else { return }
                    Task { await search() }
                }
                Spacer(minLength: 0)
                Text(matchSource == .all
                     ? "同时查全部已配置的数据源"
                     : "只查 \(matchSource.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    var resultList: some View {
        if isSearching {
            VStack(spacing: 8) {
                ProgressView()
                Text("正在搜索…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text(hasSearched ? (errorMessage ?? "没有找到候选") : "输入片名后搜索")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let errorMessage, hasSearched {
                    Text(errorMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("试试英文名、去掉季集号，或把年份清空。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(results, id: \.sourceKey) { match in
                        matchRow(match)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    func matchRow(_ match: CinemaMatch) -> some View {
        Button {
            selectedKey = match.sourceKey
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if let url = match.posterURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        Color.primary.opacity(0.06)
                    }
                }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(match.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let original = match.originalTitle, !original.isEmpty {
                        Text(original)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let year = match.year {
                            Text(String(year))
                        }
                        if let rating = match.rating, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .foregroundStyle(LumaBrand.amber)
                        }
                        if !match.genres.isEmpty {
                            Text(Array(match.genres.prefix(3)).joined(separator: " / "))
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let provider = match.provider {
                    Text(provider.title)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(provider == .tmdb ? LumaBrand.violet : LumaBrand.amber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((provider == .tmdb ? LumaBrand.violet : LumaBrand.amber).opacity(0.12)))
                }

                Image(systemName: selectedKey == match.sourceKey ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selectedKey == match.sourceKey ? LumaBrand.amber : Color.secondary)
            }
            .padding(8)
            .background(selectedKey == match.sourceKey ? LumaBrand.amber.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selectedKey == match.sourceKey ? LumaBrand.amber.opacity(0.5)
                                                                 : Color.primary.opacity(0.06),
                                  lineWidth: 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var footer: some View {
        HStack(spacing: 10) {
            if let errorMessage, !results.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !results.isEmpty {
                Text("共 \(results.count) 个候选 · \(targetCountText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Toggle("同目录同名一起匹配", isOn: $matchSiblings)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 10.5))
            }
            Spacer(minLength: 0)
            Button("取消") { dismiss() }
                .controlSize(.small)
            Button(needsEpisodeMapping ? "下一步：季集" : "应用匹配") {
                advance()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(LumaBrand.amber)
            .disabled(selectedKey == nil || isSearching)
        }
    }

    func search() async {
        guard !isSearching else { return }
        isSearching = true
        hasSearched = true
        errorMessage = nil
        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        let outcome = await store.cinemaSearchCandidates(query: query, isTV: isTV, year: year,
                                                         providers: matchSource.providers,
                                                         combineAll: matchSource == .all)
        results = outcome.matches
        errorMessage = outcome.error
        if selectedKey == nil || !results.contains(where: { $0.sourceKey == selectedKey }) {
            selectedKey = results.first?.sourceKey
        }
        isSearching = false
    }

    var targetCountText: String {
        if entry != nil || photos.count <= 1 { return "只改当前这一条" }
        if needsEpisodeMapping { return "\(photos.count) 个视频 · 下一步确认季集" }
        return "应用到 \(photos.count) 个视频"
    }

    /// 带目录链解析：文件夹名里的「Season 02 / 第 3 季」也能补进预填结果。
    func parseFilename(_ photo: PhotoItem) -> CinemaParsedName {
        let scope = store.cinemaScope(for: photo)
        let hint = store.cinemaEntries(for: scope)[photo.id]?.folderHint ?? folderHint
        return CinemaScraper.parse(filename: photo.displayFilename, folderHint: hint)
    }

    /// 多选视频 + 剧集：先选剧，再进季集映射页逐集确认。
    /// 单集只有文件名解析不出集号时才走映射页，避免每次都要多点一步。
    var needsEpisodeMapping: Bool {
        guard entry == nil,
              let match = results.first(where: { $0.sourceKey == selectedKey }),
              match.isTV else { return false }
        if photos.count > 1 { return true }
        guard let photo = photos.first else { return false }
        return parseFilename(photo).episode == nil
    }

    func advance() {
        guard let match = results.first(where: { $0.sourceKey == selectedKey }) else { return }
        if needsEpisodeMapping {
            chosenMatch = match
            prepareEpisodes()
            step = .episodes
        } else {
            applyMatch(match)
        }
    }

    func applyMatch(_ match: CinemaMatch) {
        if let entry {
            store.applyCinemaMatch(match, to: entry)
            applySiblingsIfNeeded(match, photos: [entry.file.photoItem])
        } else if photos.count > 1 {
            store.applyCinemaMatch(match, to: photos, season: nil, episodes: [:])
        } else if let photo = photos.first {
            store.applyCinemaMatch(match, to: photo)
            applySiblingsIfNeeded(match, photos: [photo])
        }
        onApplied()
        dismiss()
    }

    func applyEpisodes() {
        guard let match = chosenMatch else { return }
        var mapping: [UUID: Int] = [:]
        for row in rows {
            if let episode = Int(row.text.trimmingCharacters(in: .whitespaces)), episode > 0 {
                mapping[row.photo.id] = episode
            }
        }
        store.applyCinemaMatch(match, to: rows.map(\.photo), season: season, episodes: mapping)
        applySiblingsIfNeeded(match, photos: rows.map(\.photo))
        onApplied()
        dismiss()
    }

    /// 同目录同名多版本 / 同剧其它集：一次套用同一个候选，已匹配的不重复处理。
    func applySiblingsIfNeeded(_ match: CinemaMatch, photos: [PhotoItem]) {
        guard matchSiblings else { return }
        var extras: [PhotoItem] = []
        var seen: Set<UUID> = []
        for photo in photos {
            for sibling in store.cinemaMatchSiblings(of: photo) where seen.insert(sibling.id).inserted {
                extras.append(sibling)
            }
        }
        guard !extras.isEmpty else { return }
        store.applyCinemaMatch(match, to: extras, season: nil, episodes: [:])
    }
}
