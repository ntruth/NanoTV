import SwiftUI
import AppKit
import LumaCore
import LumaContentCore

/// 影院内搜索、观看记录与提示条。

// MARK: - 影院内搜索

struct CinemaSearchPanel: View {
    let onOpen: (CinemaEntry) -> Void
    let onOpenSeries: (CinemaSeries) -> Void
    let onPlay: (CinemaEntry) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// 防抖后的关键词：每次按键先等 180ms，避免每敲一个字符都遍历全库。
    @State private var debouncedQuery = ""
    /// 搜索范围：默认只看已入库，可切到含未识别文件名。
    @State private var includeUnmatched = false
    @State private var personTarget: CinemaCastMember?
    @FocusState private var focused: Bool
    /// 键盘游标：↑↓ 在电影 / 剧集 / 人物三组之间移动，⏎ 详情、⌘⏎ 播放。
    @State private var cursor = 0
    @State private var keyMonitor: Any?

    /// 把三组结果拍平，便于键盘顺序选择。
    enum SearchRow: Equatable {
        case entry(UUID)
        case series(String)
        case person(String)
    }

    var flatRows: [SearchRow] {
        results.entries.map { .entry($0.id) }
            + results.series.map { .series($0.id) }
            + results.people.map { .person($0.name) }
    }

    var results: (entries: [CinemaEntry], series: [CinemaSeries], people: [CinemaCastMember]) {
        store.cinemaSearchResults(debouncedQuery, includeUnmatched: includeUnmatched)
    }

    var totalCount: Int {
        results.entries.count + results.series.count + results.people.count
    }
    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            scopeBar
            Divider()
            content
            if isSearching {
                Divider()
                crossSearchBar
            }
        }
        .frame(width: 660, height: 560)
        .background(cinemaSheetBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            focused = true
            installKeyMonitor()
            // 从网络资源 / 全局搜索跳过来时带上关键词，打开就能看到结果。
            if let seed = store.cinemaSearchSeed {
                query = seed
                debouncedQuery = seed
                store.cinemaSearchSeed = nil
            }
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: query) { _, _ in cursor = 0 }
        .task(id: query) {
            // 输入框每变一次就重排一次任务：只有停手 180ms 才真正查询。
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { return }
            }
            debouncedQuery = query
        }
        .sheet(item: $personTarget) { member in
            CinemaPersonSheet(member: member)
                .environmentObject(store)
        }
    }

    // MARK: 键盘

    /// 搜索框聚焦时，SwiftUI 的 ↑↓ 会被文本编辑器吃掉；用本地监听保证结果之间能顺着选。
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 人物页弹出时把键盘交还给那个 sheet。
            guard personTarget == nil else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 125:   // ↓
                guard !modifiers.contains(.command) else { return event }
                moveCursor(1)
                return nil
            case 126:   // ↑
                guard !modifiers.contains(.command) else { return event }
                moveCursor(-1)
                return nil
            case 36, 76: // Return / 小键盘 Enter
                guard isSearching, !flatRows.isEmpty else { return event }
                if modifiers.contains(.command) {
                    playCursorRow()
                } else {
                    openCursorRow()
                }
                return nil
            default:
                return event
            }
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    func moveCursor(_ delta: Int) {
        let count = flatRows.count
        guard count > 0 else { return }
        cursor = min(max(cursor + delta, 0), count - 1)
    }

    func cursorRow() -> SearchRow? {
        let rows = flatRows
        guard rows.indices.contains(cursor) else { return nil }
        return rows[cursor]
    }

    func openCursorRow() {
        guard let row = cursorRow() else { return }
        switch row {
        case .entry(let id):
            if let entry = results.entries.first(where: { $0.id == id }) { onOpen(entry) }
        case .series(let id):
            if let item = results.series.first(where: { $0.id == id }) { onOpenSeries(item) }
        case .person(let name):
            if let person = results.people.first(where: { $0.name == name }) { personTarget = person }
        }
    }

    func playCursorRow() {
        guard let row = cursorRow() else { return }
        switch row {
        case .entry(let id):
            if let entry = results.entries.first(where: { $0.id == id }) { onPlay(entry) }
        case .series(let id):
            if let item = results.series.first(where: { $0.id == id }),
               let latest = item.latestEpisode {
                onPlay(latest)
            }
        case .person:
            break
        }
    }

    /// 范围说明：让用户知道搜的是本库还是包含未识别文件名。
    var scopeBar: some View {
        HStack(spacing: 6) {
            Text("范围")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            scopeChip("仅本库", active: !includeUnmatched) {
                includeUnmatched = false
            }
            scopeChip("含未识别文件名", active: includeUnmatched) {
                includeUnmatched = true
            }
            Spacer(minLength: 0)
            Text("↑↓ 选择 · ⏎ 详情 · ⌘⏎ 播放")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text("在「\(store.cinemaScopeName(store.cinemaActiveScope))」里检索")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    func scopeChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(active ? LumaBrand.amber : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(active ? LumaBrand.amber.opacity(0.14)
                                                  : Color.primary.opacity(0.05)))
                .overlay {
                    Capsule().strokeBorder(active ? LumaBrand.amber.opacity(0.32)
                                                  : Color.primary.opacity(0.08), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
    }

    /// 三套搜索互通：影院里没有的，一键带去网络资源继续找。
    var crossSearchBar: some View {
        HStack(spacing: 8) {
            Text("没找到？")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Button {
                let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keyword.isEmpty else { return }
                store.catalogModel.globalQuery = keyword
                store.navigate(to: .catalogSources)
                dismiss()
            } label: {
                Label("在网络资源里搜索", systemImage: "arrow.up.right.square")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LumaBrand.amber)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索片名、演员、导演、类型或文件名", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !query.isEmpty {
                Button {
                    store.startModuleSearch(.cinema, query: query)
                    dismiss()
                } label: {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("在统一搜索中查找（含其它来源）")
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
            Divider().frame(height: 16)
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    var content: some View {
        if !isSearching {
            VStack(alignment: .leading, spacing: 8) {
                Text("在「\(store.cinemaScopeName(store.cinemaActiveScope))」里检索")
                    .font(.system(size: 12, weight: .medium))
                Text("支持片名、原名、文件名、类型，以及补全后的演员与导演。示例：诺兰、科幻、S01E02.mkv。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.cinemaParentalLocked {
                    Label("家长控制已启用，受限分级内容不会出现在结果里。",
                          systemImage: "lock.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LumaBrand.coral)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if totalCount == 0 {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("没有找到匹配内容")
                    .font(.system(size: 12, weight: .medium))
                Text("试试更短的关键词，或先在详情页重新匹配 / 补全演职员。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !results.entries.isEmpty {
                        sectionTitle("电影", count: results.entries.count)
                        ForEach(Array(results.entries.enumerated()), id: \.element.id) { index, entry in
                            movieRow(entry, highlighted: cursor == index)
                        }
                    }
                    if !results.series.isEmpty {
                        sectionTitle("剧集", count: results.series.count)
                        let offset = results.entries.count
                        ForEach(Array(results.series.enumerated()), id: \.element.id) { index, item in
                            seriesRow(item, highlighted: cursor == offset + index)
                        }
                    }
                    if !results.people.isEmpty {
                        sectionTitle("人物", count: results.people.count)
                        let offset = results.entries.count + results.series.count
                        ForEach(Array(results.people.enumerated()), id: \.offset) { index, person in
                            personRow(person, highlighted: cursor == offset + index)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    func movieRow(_ entry: CinemaEntry, highlighted: Bool = false) -> some View {
        HStack(spacing: 10) {
            Button {
                onOpen(entry)
            } label: {
                HStack(spacing: 10) {
                    poster(url: entry.posterURL, photo: entry.file.photoItem, width: 44, height: 66)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        if let original = entry.originalTitle, !original.isEmpty {
                            Text(original)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(detailLine(entry))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(sourceLabel(entry))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.05)))

            Button {
                onPlay(entry)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(LumaBrand.amber, in: Circle())
            }
            .buttonStyle(.plain)
            .help("播放 \(entry.title)")
        }
        .padding(8)
        .background(highlighted ? LumaBrand.amber.opacity(0.12) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(highlighted ? LumaBrand.amber.opacity(0.40) : Color.clear, lineWidth: 0.8)
        }
    }

    func seriesRow(_ item: CinemaSeries, highlighted: Bool = false) -> some View {
        Button {
            onOpenSeries(item)
        } label: {
            HStack(spacing: 10) {
                poster(url: item.posterURL, photo: item.episodes.first?.file.photoItem, width: 44, height: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let genres = item.episodes.first?.genres, !genres.isEmpty {
                        Text(genres.prefix(3).joined(separator: " / "))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(sourceLabel(item.episodes.first))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(highlighted ? LumaBrand.amber.opacity(0.12) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(highlighted ? LumaBrand.amber.opacity(0.40) : Color.clear,
                                  lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    func personRow(_ person: CinemaCastMember, highlighted: Bool = false) -> some View {
        Button {
            personTarget = person
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if let url = person.profileURL {
                        CinemaArtwork(urlString: url, contentMode: .fill)
                    } else {
                        Circle().fill(Color.secondary.opacity(0.18))
                        Image(systemName: "person.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(person.character ?? "演职员")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("人物页 ›")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LumaBrand.amber)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(highlighted ? LumaBrand.amber.opacity(0.12) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(highlighted ? LumaBrand.amber.opacity(0.40) : Color.clear,
                                  lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    func poster(url: String?, photo: PhotoItem?, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if let url {
                CinemaArtwork(urlString: url, contentMode: .fill)
            } else if let photo {
                PhotoThumbnailView(photo: photo, purpose: .cover(height * 2))
            } else {
                Color.secondary.opacity(0.12)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// 结果来源：本地图库标「本库」，网盘标挂载名。
    func sourceLabel(_ entry: CinemaEntry?) -> String {
        guard let entry, let id = entry.file.cloudMountID else { return "本库" }
        return store.cloudMounts.first { $0.id == id }?.name ?? "网盘"
    }

    func detailLine(_ entry: CinemaEntry) -> String {
        var parts: [String] = []
        if let year = entry.year { parts.append(String(year)) }
        if let genres = entry.genres, !genres.isEmpty {
            parts.append(genres.prefix(2).joined(separator: " / "))
        }
        if let cast = entry.cast, let first = cast.first {
            parts.append(first.name)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 观看记录

struct CinemaHistoryPanel: View {
    let scope: CinemaScope
    let onResume: (CinemaEntry) -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingClear = false
    @State private var pendingRemoval: CinemaProgressRecord?
    /// 文档约定：观看记录可按「全部 / 进行中 / 已看完」分段，并按今天 / 本周 / 更早分组。
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, inProgress, finished
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .inProgress: return "进行中"
            case .finished: return "已看完"
            }
        }
    }

    var records: [CinemaProgressRecord] {
        store.cinemaHistory(for: scope)
    }

    var filteredRecords: [CinemaProgressRecord] {
        switch filter {
        case .all: return records
        case .inProgress: return records.filter { !$0.isFinished }
        case .finished: return records.filter(\.isFinished)
        }
    }

    /// 今天 / 本周 / 更早三段；空段不显示。
    var groupedRecords: [(title: String, records: [CinemaProgressRecord])] {
        let calendar = Calendar.current
        let now = Date()
        var today: [CinemaProgressRecord] = []
        var week: [CinemaProgressRecord] = []
        var earlier: [CinemaProgressRecord] = []
        for record in filteredRecords {
            if calendar.isDateInToday(record.updatedAt) {
                today.append(record)
            } else if calendar.isDate(record.updatedAt, equalTo: now, toGranularity: .weekOfYear) {
                week.append(record)
            } else {
                earlier.append(record)
            }
        }
        return [("今天", today), ("本周", week), ("更早", earlier)]
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, records: $0.1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if records.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有观看记录")
                        .font(.system(size: 12, weight: .medium))
                    Text("从影院播放任意影片后，进度会出现在这里。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRecords.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: filter == .finished ? "checkmark.circle" : "play.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(filter == .finished ? "还没有看完的影片" : "没有进行中的影片")
                        .font(.system(size: 12, weight: .medium))
                    Button("查看全部") { filter = .all }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groupedRecords, id: \.title) { group in
                            HStack(spacing: 6) {
                                Text(group.title)
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("\(group.records.count)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 4)
                            ForEach(group.records) { record in
                                row(record)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("清除全部观看记录？", isPresented: $pendingClear) {
            Button("清除", role: .destructive) { store.clearCinemaProgress() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清空继续观看与所有进度，影片文件不受影响。")
        }
        .confirmationDialog("移出这条观看记录？",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { record in
            Button("移出记录", role: .destructive) {
                store.removeCinemaProgress(record.id)
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: { record in
            Text("「\(record.title)」的进度会被移除，影片文件不受影响。")
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Text("观看记录")
                .font(.system(size: 15, weight: .semibold))
            Text("\(filteredRecords.count) 条")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            Spacer(minLength: 0)
            if !records.isEmpty {
                Button("清除全部…") { pendingClear = true }
                    .controlSize(.small)
            }
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    func row(_ record: CinemaProgressRecord) -> some View {
        let entry = store.cinemaEntries(for: scope)[record.photoID]
        return HStack(spacing: 10) {
            ZStack {
                if let url = record.artworkURL {
                    CinemaArtwork(urlString: url, contentMode: .fill)
                } else if let entry {
                    PhotoThumbnailView(photo: entry.file.photoItem, purpose: .cover(120))
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 96, height: 54)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let subtitle = record.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                    }
                    Text(record.isFinished ? "已看完" : "剩余 \(remainingText(record))")
                        .foregroundStyle(record.isFinished ? Color.secondary : LumaBrand.amber)
                }
                .font(.system(size: 10))
                .lineLimit(1)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(record.isFinished ? Color.secondary.opacity(0.5) : LumaBrand.amber)
                            .frame(width: max(3.0, geo.size.width * record.fraction))
                    }
                }
                .frame(height: 3)
            }

            Spacer(minLength: 0)

            if let entry {
                if !record.isFinished {
                    Button {
                        onResume(entry)
                    } label: {
                        Label("继续", systemImage: "play.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .controlSize(.small)
                }
                Button {
                    pendingRemoval = record
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.borderless)
                .help("移出观看记录")
            } else {
                Text("文件已不在影院")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    func remainingText(_ record: CinemaProgressRecord) -> String {
        let minutes = Int((record.remainingSeconds / 60).rounded())
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return "\(max(1, minutes)) 分钟"
    }
}


// MARK: - 右上角 Toast 栈（F4）

struct CinemaToastStack: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(store.cinemaToasts) { toast in
                card(toast)
            }
        }
        .frame(width: 340, alignment: .trailing)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(.snappy(duration: 0.2), value: store.cinemaToasts.map(\.id))
    }

    func card(_ toast: CinemaToast) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon(toast.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint(toast.kind))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button(actionTitle) {
                    action()
                    store.dismissCinemaToast(toast.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LumaBrand.amber)
            }

            Button {
                store.dismissCinemaToast(toast.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(tint(toast.kind).opacity(0.28), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    func icon(_ kind: CinemaToastKind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .progress: return "arrow.down.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    func tint(_ kind: CinemaToastKind) -> Color {
        switch kind {
        case .success: return .green
        case .failure: return LumaBrand.coral
        case .progress: return LumaBrand.amber
        case .info: return LumaBrand.violet
        }
    }
}

// MARK: - 人物页（B4）
