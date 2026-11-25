import SwiftUI
import LumaContentCore

/// 侧边栏底部的后台任务条：网盘扫描、影院刮削、健康检测、内容识别、导入导出等统一在这里露出进度。
/// 默认常驻：有任务时显示进度，空闲时也留一个任务记录入口；可收起成左侧的小胶囊。
struct SourceJobStatusBar: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showDetail = false
    /// 收起后只留左侧一个小胶囊，状态跨启动保留。
    @AppStorage("sidebar.taskBar.collapsed") private var collapsed = false
    @Environment(\.colorScheme) private var scheme

    /// 任务条自己叠在侧边栏材质上：暗色模式不能直接用 .secondary / .tertiary，否则和深色背景糊在一起。
    private var secondaryInk: Color {
        scheme == .dark ? Color.white.opacity(0.80) : Color.primary.opacity(0.66)
    }
    private var tertiaryInk: Color {
        scheme == .dark ? Color.white.opacity(0.58) : Color.primary.opacity(0.45)
    }

    var body: some View {
        // 读取 revision：任务进度变化（含后台线程上报）时触发重绘。
        let _ = store.sourceJobRevision
        let jobs = store.activeSourceJobs
        let recentChecks = store.recentSourceJobs(kind: .connectivity)

        Group {
            if collapsed {
                collapsedRow(jobs)
            } else {
                expandedRow(jobs: jobs, recentChecks: recentChecks)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: collapsed)
        // 收 / 展切换时浮层身份会换一个锚点：先关掉，免得之后点不开。
        .onChange(of: collapsed) { _, _ in
            showDetail = false
        }
    }

    // MARK: 展开态

    private func expandedRow(jobs: [JobProgress],
                             recentChecks: [JobProgress]) -> some View {
        HStack(spacing: 8) {
            if let job = jobs.first {
                activeButton(job: job, count: jobs.count)
                if job.isCancellable {
                    Button {
                        showDetail = false
                        store.cancelSourceJob(job.jobID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .help("取消任务")
                }
            } else {
                idleButton(recentChecks: recentChecks)
            }
            collapseButton
        }
        .modifier(SourceJobBarChrome())
    }

    private func activeButton(job: JobProgress, count: Int) -> some View {
        Button {
            showDetail.toggle()
        } label: {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    // 任务条只占一行：标题保持完整，来源与读数在剩余空间里截断。
                    HStack(spacing: 4) {
                        Text(job.title ?? job.kind.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        // 带上来源名，网盘扫描 / 读 EXIF 在收起状态也能一眼看出是哪个网盘。
                        if let source = compactSourceName(job.sourceID) {
                            Text(source)
                                .font(.system(size: 10))
                                .foregroundStyle(secondaryInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let message = job.message, !message.isEmpty {
                            Text(message)
                                .font(.system(size: 10))
                                .foregroundStyle(secondaryInk)
                                .lineLimit(1)
                        }
                    }
                    .lineLimit(1)
                    if let fraction = job.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(Color.accentColor)
                            .frame(height: 3)
                            .background {
                                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.24 : 0.10))
                            }
                    }
                }
                Spacer(minLength: 4)
                if count > 1 {
                    Text("+\(count - 1)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(tertiaryInk)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看任务详情")
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            SourceJobDetailPopover(isPresented: $showDetail)
                .environmentObject(store)
        }
    }

    /// 空闲态：默认就在，用户随时能翻任务记录、连接检查与失败重试。
    private func idleButton(recentChecks: [JobProgress]) -> some View {
        Button {
            showDetail.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryInk)
                Text("任务记录")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(secondaryInk)
                Text(idleDetail(recentChecks: recentChecks))
                    .font(.system(size: 10))
                    .foregroundStyle(tertiaryInk)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tertiaryInk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看任务记录")
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            SourceJobDetailPopover(isPresented: $showDetail)
                .environmentObject(store)
        }
    }

    private func idleDetail(recentChecks: [JobProgress]) -> String {
        // 空闲态也给最近一条记录的线索：后台补录日历这类任务结束后也能看出跑过什么。
        if let job = store.recentFinishedSourceJobs(limit: 1).first {
            return job.title ?? compactSourceName(job.sourceID) ?? job.kind.title
        }
        if let check = recentChecks.first, let name = compactSourceName(check.sourceID) {
            return name
        }
        return "后台任务会显示在这里"
    }

    private var collapseButton: some View {
        Button {
            showDetail = false
            collapsed = true
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tertiaryInk)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("收起任务栏")
    }

    // MARK: 收起态

    /// 收起后停在左下角：一个小胶囊，有任务时显示转圈与数量。
    /// 点它先展开任务栏，再打开任务记录——浮层挂在贴窗口边缘的小胶囊上会失效。
    private func collapsedRow(_ jobs: [JobProgress]) -> some View {
        HStack(spacing: 6) {
            Button {
                collapsed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !collapsed { showDetail = true }
                }
            } label: {
                HStack(spacing: 5) {
                    if jobs.isEmpty {
                        Image(systemName: "checklist")
                            .font(.system(size: 10, weight: .semibold))
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                        Text("\(jobs.count)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    }
                }
                .foregroundStyle(jobs.isEmpty ? secondaryInk : Color.accentColor)
                .frame(height: 22)
                .padding(.horizontal, 10)
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        // 暗色：ultraThinMaterial 叠在侧边栏上会发黑，补一点亮度让胶囊浮起来。
                        Capsule().fill(Color.white.opacity(scheme == .dark ? 0.10 : 0.20))
                    }
                }
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(scheme == .dark ? 0.20 : 0.10),
                                           lineWidth: 0.5)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("展开任务栏并查看任务记录")

            Button {
                collapsed = false
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tertiaryInk)
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("展开任务栏")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// 收起态给任务补一个来源名：网盘 / 影院 / 电视 / 来源接入都能看出是哪一类。
    private func compactSourceName(_ id: SourceID) -> String? {
        if id == .catalogHub { return "网络资源" }
        if id == .networkCinema { return "网络影院" }
        if id.rawValue.hasPrefix("cloud:") {
            return store.cloudMount(for: id.uuidValue)?.name
        }
        if id.rawValue.hasPrefix("cinema:mount:") {
            guard let name = store.cloudMount(for: id.uuidValue)?.name else { return nil }
            return "\(name) 影院"
        }
        // 电视画面探测：显示具体电视源，任务条上能看出在标注哪个源。
        if id.rawValue.hasPrefix("tv:") {
            guard let playlistID = id.uuidValue else { return "网络电视" }
            return store.tvModel.playlistName(for: playlistID)
        }
        if id == .search { return "全库" }
        return nil
    }
}

/// 任务条统一的边距、材质与顶部分隔线。
private struct SourceJobBarChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    // 侧边栏本身已是材质：暗色模式再叠 ultraThin 会发黑，任务条补一点亮度浮起来。
                    Rectangle().fill(Color.white.opacity(scheme == .dark ? 0.08 : 0.22))
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(scheme == .dark ? Color.white.opacity(0.12) : Color.primary.opacity(0.08))
                    .frame(height: 0.5)
            }
    }
}

/// 任务记录筛选：默认全部，进行中 / 失败 / 已取消可一键聚焦。
private enum JobRecordFilter: String, CaseIterable, Identifiable {
    case all
    case running
    case failed
    case cancelled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .running: return "进行中"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

/// 同一天的任务记录：时间线按天分组，记录行里只留时刻，避免每条都背一个完整日期。
private struct JobDayGroup: Identifiable {
    let day: Date
    let jobs: [JobProgress]
    var id: Date { day }
}

/// 后台任务浮层：顶部状态概览 → 筛选 → 进行中任务 → 按天分组的记录。
private struct SourceJobDetailPopover: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var store: LibraryStore
    @State private var pendingClear = false
    @State private var filter: JobRecordFilter = .all

    var body: some View {
        // 扫描计数等字段不在任务对象里，靠 revision 触发刷新。
        let _ = store.sourceJobRevision
        let jobs = store.activeSourceJobs
        let records = store.recentFinishedSourceJobs(limit: 200)
            .filter { $0.kind != .connectivity }
        let checks = store.recentSourceJobs(kind: .connectivity)
        let needsScroll = jobs.count + records.count + checks.count > 4

        VStack(alignment: .leading, spacing: 0) {
            header()
            Divider().opacity(0.5)
            filterBar(jobs: jobs.count, records: records)
            Divider().opacity(0.5)

            // 条目不多时按内容高度自适应；记录较多时才固定高度并滚动。
            if needsScroll {
                ScrollView {
                    content(jobs: jobs, records: records, checks: checks)
                        .padding(14)
                }
                .frame(height: 460)
            } else {
                content(jobs: jobs, records: records, checks: checks)
                    .padding(14)
            }
        }
        .frame(width: 420)
        .confirmationDialog("清理任务记录？", isPresented: $pendingClear) {
            Button("全部清理", role: .destructive) {
                store.clearSourceJobHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除任务记录，不影响刮削结果、影片文件与当前连接状态。")
        }
    }

    /// 失败记录的重试入口：所有任务都按种类重新发起，不再单独维护影院队列。
    private func retryAction(for job: JobProgress) -> (() -> Void)? {
        guard job.phase == .failed else { return nil }
        switch job.kind {
        case .scrape:
            return { Task { await store.retryCinemaTask(job) } }
        case .search:
            // 统一搜索：标题形如「搜索「上海」」，点一下用同一个关键词重搜。
            if let keyword = Self.searchKeyword(from: job.title) {
                return { rerunSearch(keyword) }
            }
            // 聚合片单：标题里带片单名，按名字找到它重新聚合。
            guard let name = Self.aggregationPlaylistName(from: job.title),
                  let playlist = store.catalogModel.smartPlaylists.first(where: { $0.name == name })
            else { return nil }
            return { store.catalogModel.refreshSmartPlaylist(playlist.id) }
        case .healthCheck:
            let domain: CatalogDomain = job.sourceID == .networkCinema ? .networkCinema : .networkResource
            return { store.catalogModel.checkHealth(force: true, domain: domain) }
        case .sync:
            guard job.title?.contains("日历") == true else { return nil }
            let domain: CatalogDomain = job.sourceID == .networkCinema ? .networkCinema : .networkResource
            return { store.catalogModel.refreshCalendarToday(force: true, domain: domain) }
        case .epg:
            return { store.tvModel.loadEPGIfNeeded(force: true) }
        default:
            return nil
        }
    }

    /// 从「聚合片单「名称」」里取出名称。
    private static func aggregationPlaylistName(from title: String?) -> String? {
        guard let title,
              let start = title.firstIndex(of: "「"),
              let end = title.lastIndex(of: "」"),
              start < end else { return nil }
        return String(title[title.index(after: start)..<end])
    }

    /// 统一搜索任务的标题里取回关键词（「搜索「上海」」→「上海」）。
    private static func searchKeyword(from title: String?) -> String? {
        guard let title, title.hasPrefix("搜索") else { return nil }
        guard let start = title.firstIndex(of: "「"),
              let end = title.lastIndex(of: "」"), start < end else { return nil }
        let keyword = String(title[title.index(after: start)..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return keyword.isEmpty ? nil : keyword
    }

    /// 用任务里记录的关键词重新发起一次全局搜索。
    private func rerunSearch(_ keyword: String) {
        // 「重新搜索」要真的重跑：先丢掉这个关键词缓存的会话，否则会直接复用旧结果。
        SearchSessionStore.shared.remove(query: keyword, scopes: AppModules.enabledSearchScopes)
        store.searchScope = .global
        store.searchText = keyword
    }

    /// 已完成的搜索任务也能点「重新搜索」：同样的关键词，直接回到统一搜索结果页。
    private func rerunSearchAction(for job: JobProgress) -> (() -> Void)? {
        guard job.kind == .search,
              let keyword = Self.searchKeyword(from: job.title) else { return nil }
        return { rerunSearch(keyword) }
    }

    @ViewBuilder
    private func content(jobs: [JobProgress],
                         records: [JobProgress],
                         checks: [JobProgress]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch filter {
            case .all:
                if !jobs.isEmpty {
                    runningSection(jobs)
                }
                recordsSection(records)
                if !checks.isEmpty {
                    checksSection(checks)
                }
            case .running:
                runningSection(jobs)
            case .failed:
                recordsSection(records.filter { $0.phase == .failed },
                               emptyText: "没有失败的记录")
            case .cancelled:
                recordsSection(records.filter { $0.phase == .cancelled },
                               emptyText: "没有已取消的记录")
            }
        }
    }

    // MARK: 进行中

    private func runningSection(_ jobs: [JobProgress]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("进行中", detail: nil)
            if jobs.isEmpty {
                emptyHint(icon: "checkmark.seal", text: "当前没有进行中的任务")
            } else {
                // 每秒刷新一次：打开浮层期间耗时与预计剩余持续走动，不会像静态读数。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 8) {
                        ForEach(jobs) { job in
                            runningCard(job, now: context.date)
                        }
                    }
                }
            }
        }
    }

    private func runningCard(_ job: JobProgress, now: Date) -> some View {
        // 网盘扫描有专门的摘要区（含预计剩余），耗时统一放在右上角。
        let usesScanSummary: Bool = {
            guard job.kind == .scan, let mountID = job.sourceID.uuidValue else { return false }
            return store.cloudModel.scanMountID == mountID
        }()
        let elapsed: String? = job.startedAt.map {
            JobDurationText.format(now.timeIntervalSince($0))
        }
        let title = (job.title ?? job.kind.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .help(title)
                        pill(job.phase == .pending ? "等待中" : "进行中", tint: .accentColor)
                        Spacer(minLength: 0)
                    }
                    sourceMeta(job)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 5) {
                    if let elapsed { elapsedLabel(elapsed) }
                    if job.isCancellable {
                        Button("取消") {
                            store.cancelSourceJob(job.jobID)
                            isPresented = false
                        }
                        .controlSize(.mini)
                        .help("取消这个后台任务")
                    }
                }
                .frame(width: 84, alignment: .trailing)
            }

            if let fraction = job.fraction {
                VStack(spacing: 4) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                    HStack(spacing: 6) {
                        if let total = job.total {
                            Text("\(job.completed.formatted()) / \(total.formatted())")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else if job.completed > 0 {
                            Text(job.kind == .analyze
                                 ? "已识别 \(job.completed.formatted())"
                                 : "已完成 \(job.completed.formatted())")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if job.phase == .running {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }

            if usesScanSummary {
                scanSummary(job)
            } else if job.kind == .analyze {
                row("识别范围", analysisScope(job.sourceID))
            }

            if let message = job.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
            }
        }
        .padding(10)
        .background(cardBackground(nil))
    }

    /// 网盘扫描的摘要：条目 / 已存在 / 新增 / 目录 / 预计剩余。
    @ViewBuilder
    private func scanSummary(_ job: JobProgress) -> some View {
        let model = store.cloudModel
        VStack(spacing: 3) {
            row("本次条目", "\(model.scanMediaCount.formatted()) 条媒体")
            if model.scanBaselineMediaCount > 0 {
                row("已存在", "\(model.scanBaselineMediaCount.formatted()) 条")
            }
            row("新增", "\(max(0, model.scanMediaCount - model.scanBaselineMediaCount).formatted()) 条")
            row("已扫描目录", "\(model.scanFolderCount.formatted()) 个")
            if model.scanIndexPersistedFolderCount > 0 {
                row("已写入索引", "\(model.scanIndexPersistedFolderCount.formatted()) 个目录")
            }
            if let started = model.scanStartedAt {
                let elapsed = Date().timeIntervalSince(started)
                let text: String = {
                    var text = durationText(elapsed)
                    if let fraction = job.fraction, fraction > 0.03, elapsed > 3 {
                        let remaining = max(0, elapsed / fraction - elapsed)
                        text += " · 预计还需 \(durationText(remaining))"
                    }
                    return text
                }()
                row("已耗时", text)
            }
            row("扫描方式", model.scanIsDeep ? "全量扫描" : "增量扫描")
            if model.scanTruncated {
                Text("已触及单次扫描上限，稍后再扫一次可继续补齐。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 任务记录

    private func recordsSection(_ records: [JobProgress],
                                emptyText: String = "还没有任务记录") -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("任务记录", detail: nil)
            if records.isEmpty {
                emptyHint(icon: "tray", text: emptyText)
            } else {
                ForEach(dayGroups(records)) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(dayTitle(group.day))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 0.5)
                            Text("\(group.jobs.count) 条")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(group.jobs) { job in
                            recordRow(job)
                        }
                    }
                }
            }
        }
    }

    /// 一条任务记录：标题 → 来源 / 种类 → 结果，右侧固定给出时刻、耗时与操作。
    private func recordRow(_ job: JobProgress, showDay: Bool = false) -> some View {
        let ok = job.phase == .finished
        let cancelled = job.phase == .cancelled
        let tint: Color = ok ? .green : LumaBrand.coral
        let symbol = ok ? "checkmark.circle.fill"
            : (cancelled ? "minus.circle.fill" : "exclamationmark.triangle.fill")
        let statusText = ok ? "已完成" : (cancelled ? "已取消" : "失败")
        let title = (job.title ?? job.kind.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = job.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skipped = job.kind == .scrape ? skippedCount(in: job.message) : nil

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(title)
                    pill(statusText, tint: tint)
                    if let skipped, skipped > 0 {
                        pill("跳过 \(skipped)", tint: .secondary)
                    }
                    Spacer(minLength: 0)
                }
                sourceMeta(job)
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(message)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 5) {
                Text(timeText(job.updatedAt, showDay: showDay))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if let elapsed = job.elapsedText {
                    elapsedLabel(elapsed)
                }
                if job.phase == .failed, let retry = retryAction(for: job) {
                    Button("重试") { retry() }
                        .controlSize(.mini)
                        .help("按同一来源重新发起这个任务")
                } else if job.phase == .finished, let rerun = rerunSearchAction(for: job) {
                    Button("重新搜索") { rerun() }
                        .controlSize(.mini)
                        .help("用这个关键词重新发起统一搜索")
                }
            }
            .frame(width: 84, alignment: .trailing)
        }
        .padding(10)
        .background(cardBackground(ok ? nil : tint))
    }

    private func checksSection(_ checks: [JobProgress]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("最近连接检测", detail: "\(checks.count) 次")
            ForEach(checks) { job in
                recordRow(job, showDay: true)
            }
        }
    }

    /// 按天分组：同一天的记录共用一个日期标题，行内只显示时刻。
    private func dayGroups(_ records: [JobProgress]) -> [JobDayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var grouped: [Date: [JobProgress]] = [:]
        for job in records {
            let day = calendar.startOfDay(for: job.updatedAt)
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(job)
        }
        return order.map { JobDayGroup(day: $0, jobs: grouped[$0] ?? []) }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return "\(calendar.component(.month, from: day)) 月 \(calendar.component(.day, from: day)) 日"
    }

    private func timeText(_ date: Date, showDay: Bool) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard showDay, !Calendar.current.isDateInToday(date) else { return time }
        let calendar = Calendar.current
        return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date)) \(time)"
    }

    /// 从「… · 跳过 N 个…」里取出跳过数量。
    private func skippedCount(in message: String?) -> Int? {
        guard let message, let range = message.range(of: "跳过 ") else { return nil }
        return Int(message[range.upperBound...].prefix { $0.isNumber })
    }

    // MARK: 顶部概览

    private func header() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("后台任务")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button("清理…") { pendingClear = true }
                    .controlSize(.mini)
                    .help("清理全部任务记录")
            }

            Rectangle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.6), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func filterBar(jobs: Int, records: [JobProgress]) -> some View {
        HStack(spacing: 6) {
            ForEach(JobRecordFilter.allCases) { item in
                filterChip(item, count: count(for: item, jobs: jobs, records: records))
            }
            Spacer(minLength: 0)
            if let average = averageElapsed(records) {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(.system(size: 8))
                    Text("平均 \(average)")
                        .font(.system(size: 9.5, design: .monospaced))
                }
                .foregroundStyle(.tertiary)
                .help("已完成任务的平均耗时")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func count(for item: JobRecordFilter, jobs: Int, records: [JobProgress]) -> Int {
        switch item {
        case .all: return jobs + records.count
        case .running: return jobs
        case .failed: return records.filter { $0.phase == .failed }.count
        case .cancelled: return records.filter { $0.phase == .cancelled }.count
        }
    }

    /// 已完成任务的平均耗时：让「快 / 慢」有个参照系。
    private func averageElapsed(_ records: [JobProgress]) -> String? {
        let values = records.compactMap { $0.phase == .finished ? $0.elapsed : nil }
        guard !values.isEmpty else { return nil }
        return JobDurationText.format(values.reduce(0, +) / Double(values.count))
    }

    private func filterChip(_ item: JobRecordFilter, count: Int) -> some View {
        let selected = filter == item
        return Button {
            filter = item
        } label: {
            HStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                Text("\(count)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected
                                       ? Color.accentColor.opacity(0.16)
                                       : Color.primary.opacity(0.05)))
            .overlay {
                Capsule().strokeBorder(selected
                                       ? Color.accentColor.opacity(0.5)
                                       : Color.clear,
                                       lineWidth: 0.8)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("只看\(item.title)的任务")
    }

    // MARK: 通用小件

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// 来源 · 种类：同一行给出「哪个来源的什么任务」。
    private func sourceMeta(_ job: JobProgress) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName(for: job))
                .font(.system(size: 9))
            Text(sourceName(job.sourceID))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·")
            Text(job.kind.title)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.14)))
            .lineLimit(1)
    }

    private func elapsedLabel(_ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "timer")
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
        }
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .help("任务耗时")
    }

    private func emptyHint(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

    private func cardBackground(_ accent: Color?) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent?.opacity(0.30) ?? Color.primary.opacity(0.06),
                                  lineWidth: 0.6)
            }
    }

    // MARK: 通用行

    /// 秒数 → 自适应单位（毫秒 / 秒 / 分 / 时）；扫描摘要里的耗时 / 预计剩余共用。
    private func durationText(_ seconds: Double) -> String {
        JobDurationText.format(seconds)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// 任务图标：优先按任务标题区分（例如「补录更新日历」用日历图标），再退回种类。
    private func symbolName(for job: JobProgress) -> String {
        if let title = job.title {
            if title.contains("日历") { return "calendar" }
            if title.contains("健康") { return "waveform.path.ecg" }
        }
        return symbolName(for: job.kind)
    }

    private func symbolName(for kind: SourceJobKind) -> String {
        switch kind {
        case .scan: return "magnifyingglass"
        case .index: return "list.bullet.rectangle"
        case .scrape: return "film.stack"
        case .epg: return "calendar"
        case .artwork: return "photo"
        case .sync: return "arrow.triangle.2.circlepath"
        case .analyze: return "sparkles"
        case .healthCheck: return "waveform.path.ecg"
        case .connectivity: return "network"
        case .probe: return "antenna.radiowaves.left.and.right"
        case .search: return "magnifyingglass"
        case .ingest: return "square.and.arrow.down"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .backup: return "externaldrive.badge.checkmark"
        case .export: return "square.and.arrow.up"
        case .download: return "arrow.down.circle"
        case .cluster: return "person.2"
        case .dedupe: return "square.on.square"
        case .beauty: return "wand.and.stars"
        case .places: return "mappin.and.ellipse"
        case .metadata: return "doc.text.magnifyingglass"
        case .assistant: return "bubble.left.and.text.bubble.right"
        case .record: return "record.circle"
        }
    }

    /// 识别任务的适用范围：网盘 / 系统图库 / 本地图库 / 影院片头。
    private func analysisScope(_ id: SourceID) -> String {
        if id.rawValue.hasPrefix("cloud:") { return "网盘 · 场景 / 图内文字" }
        if id == .localCinema || id.rawValue.hasPrefix("cinema:") { return "影院 · 片头检测" }
        let path = id.rawValue.hasPrefix("library:")
            ? String(id.rawValue.dropFirst("library:".count))
            : ""
        if let system = store.systemLibraryPath, path == system {
            return "系统图库 · 场景 / 图内文字"
        }
        return "本地图库 · 场景 / 文字 / 二维码"
    }

    /// 源 ID → 可读名称：网盘取挂载名，影院区分本地 / 网盘。
    private func sourceName(_ id: SourceID) -> String {
        if id.rawValue.hasPrefix("cloud:") {
            return store.cloudMount(for: id.uuidValue)?.name ?? "网络云盘"
        }
        if id.rawValue.hasPrefix("cinema:mount:") {
            guard let name = store.cloudMount(for: id.uuidValue)?.name else { return "网盘影院" }
            return "\(name) 影院"
        }
        if id == .localCinema { return "本地影院" }
        if id == .networkCinema { return "网络影院" }
        if id == .catalogHub { return "网络资源总览" }
        if id.rawValue.hasPrefix("catalog:") { return "网络资源" }
        if id == .search { return "全库搜索" }
        if id.rawValue.hasPrefix("tv:") {
            guard let playlistID = id.uuidValue else { return "网络电视" }
            return "网络电视 · \(store.tvModel.playlistName(for: playlistID))"
        }
        if id.rawValue.hasPrefix("library:") {
            let path = String(id.rawValue.dropFirst("library:".count))
            if let system = store.systemLibraryPath, path == system { return "系统图库" }
            return "本地图库"
        }
        return id.rawValue
    }
}
