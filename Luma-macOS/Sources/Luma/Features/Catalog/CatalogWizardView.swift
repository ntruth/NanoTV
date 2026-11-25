import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LumaContentCore

/// 接入网络资源：地址与文件两种方式合并在同一个面板里。
/// 地址可以混填配置与站点；文件支持拾光分享包、FongMi 配置与地址文本。
/// 无论哪种方式，都必须完成「首页 / 详情 / 封面」校验才允许添加。
struct CatalogWizardView: View {
    @EnvironmentObject private var catalog: CatalogBrowserModel
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var entryMode: SourceEntryMode = .address
    @State private var urlText = ""
    @State private var imported: [ImportedSource] = []
    @State private var isWorking = false
    @State private var progressText: String?
    @State private var errorMessage: String?
    @State private var enableAfterAdd = false
    @State private var allowInsecure = false
    /// 文件方式：已选中的文件与解析摘要，方便确认导入的是哪一份。
    @State private var pickedFile: URL?
    @State private var fileSummary: String?
    @State private var isDropTargeted = false
    /// 本次接入登记在统一任务中心里的任务：解析与校验的耗时都会计入。
    @State private var ingestJobID: UUID?
    @FocusState private var inputFocused: Bool

    /// 是否从「网络影院 / 网络存储 › 影院」进来。
    private var isCinemaEntry: Bool {
        if case .networkCinema = store.sidebarItem { return true }
        if case .cloudCinema = store.sidebarItem { return true }
        return false
    }

    /// 这次向导服务的域：显式传入优先，其次按当前页面判断。
    /// 网络影院只接收影视源，网络资源只接收网页资源站，两边绝不互串。
    private var entryDomain: CatalogDomain {
        catalog.wizardDomain ?? (isCinemaEntry ? .networkCinema : .networkResource)
    }

    // MARK: - 任务中心

    /// 任务中心里的来源：网络资源归到资源聚合源，影视源归到网络影院。
    private var ingestSourceID: SourceID {
        entryDomain == .networkCinema ? .networkCinema : .catalogHub
    }

    private var ingestJobTitle: String {
        entryDomain == .networkCinema ? "接入影视源" : "接入网络资源"
    }

    private func beginIngestJob() {
        if let ingestJobID { store.abandonSourceJob(ingestJobID) }
        ingestJobID = store.beginSourceJob(SourceJob(sourceID: ingestSourceID,
                                                     kind: .ingest,
                                                     title: ingestJobTitle,
                                                     isCancellable: false))
    }

    private func reportIngestProgress(completed: Int? = nil,
                                      total: Int? = nil,
                                      message: String? = nil) {
        guard let ingestJobID else { return }
        store.updateSourceJob(ingestJobID, completed: completed, total: total, message: message)
    }

    private func finishIngestJob(success: Bool, message: String) {
        guard let job = ingestJobID else { return }
        if success {
            store.finishSourceJob(job, message: message)
        } else {
            store.failSourceJob(job, message: message)
        }
        ingestJobID = nil
    }

    /// 逐条自动判定：FongMi 兼容配置，或直接给网页站点的地址。
    private enum AddressKind {
        case config
        case site

        var label: String {
            switch self {
            case .config: return "配置"
            case .site: return "站点"
            }
        }
        var icon: String {
            switch self {
            case .config: return "doc.text"
            case .site: return "globe"
            }
        }
    }

    private struct Check: Identifiable {
        enum State: Equatable { case ok, failed }
        let id = UUID()
        var text: String
        var state: State
    }

    /// 一次导入可能包含多个站点：每个地址保留自己的解析结果与校验项。
    private struct ImportedSource: Identifiable {
        let id = UUID()
        var address: String
        var source: CatalogSource?
        var checks: [Check] = []

        var failed: Bool { source == nil || checks.contains { $0.state == .failed } }
        var name: String { source?.name ?? "无法解析" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            entryModeBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if entryMode == .address {
                        intro
                        field
                    } else {
                        fileIntro
                        filePicker
                        if let pickedFile {
                            pickedFileRow(pickedFile)
                        }
                        progressRow
                    }
                    if !imported.isEmpty {
                        results
                    }
                    if let errorMessage {
                        callout(errorMessage, color: .red, icon: "exclamationmark.triangle.fill")
                    }
                    callout("该资源内容由第三方站点提供，App 不内置、不托管任何内容或密钥。"
                            + "启用后仅在本机展示与播放，不写入照片图库索引；请自行确认来源合规与内容分级。",
                            color: LumaBrand.amber, icon: "lock.shield")
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 700)
        .onChange(of: entryMode) { _, _ in
            imported = []
            errorMessage = nil
            progressText = nil
        }
        .onChange(of: allowInsecure) { _, value in
            guard imported.count == 1, var source = imported.first?.source else { return }
            source.allowsInsecureTLS = value
            imported[0].source = source
            CatalogTrust.setTrusted(source.host, value)
            Task {
                let checks = await validate(source)
                if !imported.isEmpty { imported[0].checks = checks }
            }
        }
        .onDisappear {
            // 面板中途关闭：未收尾的任务直接从任务条收起，不在记录里留半截。
            if let job = ingestJobID {
                store.abandonSourceJob(job)
                ingestJobID = nil
            }
            // 向导取消时清掉临时放行，只保留已保存源自己的信任设置。
            CatalogTrust.sync(sources: catalog.sources)
            catalog.wizardDomain = nil
        }
    }

    /// 顶部「地址 / 文件」分段：两种接入方式并列，切换时清掉上一轮结果。
    private var entryModeBar: some View {
        HStack(spacing: 8) {
            SourceEntryModeTab(mode: $entryMode)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entryDomain == .networkCinema ? "接入网络影院影视源" : "接入网络资源")
                    .font(.system(size: 15, weight: .semibold))
                Text(entryDomain == .networkCinema
                     ? "影视源：FongMi 配置、苹果CMS 接口、FoFo / 爱看片片 / 爱壹帆站点；可粘贴地址或导入文件"
                     : "网页资源站：站点首页、FongMi 配置里的网页站点；可粘贴地址或导入文件")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var intro: some View {
        Text(entryDomain == .networkCinema
             ? "把影视源地址粘进来：FongMi 配置（.json）与苹果CMS 接口可以混在一起，每行一条。"
                + "解析后只保留影视源；网页资源站请到「网络资源」里接入。"
             : "把网页资源站地址粘进来：站点首页与 FongMi 配置里的网页站点可以混在一起，每行一条。"
                + "解析后只保留网页资源站；影视源请到「网络影院」里接入。")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var fileIntro: some View {
        Text(entryDomain == .networkCinema
             ? "选一份拾光分享包、FongMi 配置或地址文本，解析后只保留影视源，重复的站点会自动跳过。"
             : "选一份拾光分享包、FongMi 配置或地址文本，解析后只保留网页资源站，重复的站点会自动跳过。")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 10) {
            inputCard
            progressRow
        }
    }

    /// 读取 / 校验进度：地址与文件两种方式共用同一行。
    @ViewBuilder
    private var progressRow: some View {
        if isWorking || progressText != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(progressText ?? "正在读取配置并验证站点…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// 输入卡片：一个文本域装下所有地址，底栏负责识别摘要与提交。
    private var inputCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if urlText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("粘贴配置或站点地址，每行一条")
                            .foregroundStyle(.secondary)
                        Text("https://example.com/fongmi.json")
                            .foregroundStyle(.tertiary)
                        Text("https://example.com/api.php/provide/vod/")
                            .foregroundStyle(.tertiary)
                        Text("https://example.com/  https://example.org/")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
                }

                TextEditor(text: $urlText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
                    .disabled(isWorking)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
            }
            .frame(height: 126)

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                detectionSummary
                Spacer(minLength: 8)
                if !urlText.isEmpty, !isWorking {
                    Button("清空") {
                        urlText = ""
                        imported = []
                        errorMessage = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else if urlText.isEmpty, !isWorking {
                    Button("粘贴") { pasteFromClipboard() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button {
                    runImport()
                } label: {
                    Label("解析并校验", systemImage: "wand.and.stars")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(addresses.isEmpty || isWorking)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.60))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(inputFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
                              lineWidth: inputFocused ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(inputFocused ? (scheme == .dark ? 0.30 : 0.07) : 0),
                radius: 8, y: 3)
        .animation(.easeOut(duration: 0.16), value: inputFocused)
    }

    // MARK: - 文件接入

    /// 文件选择区：拖进来或点按钮选，解析与校验沿用地址方式的同一套流程。
    private var filePicker: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "doc.badge.plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(isDropTargeted ? "松手即可读取" : "拖入配置文件，或从磁盘选择")
                .font(.system(size: 12.5, weight: .semibold))
            Text("拾光分享包（.json）· FongMi 配置（.json）· 地址文本 / M3U（.txt / .m3u）")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                chooseFile()
            } label: {
                Label(pickedFile == nil ? "选择文件…" : "重新选择…", systemImage: "folder")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isWorking)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.14),
                              style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
        }
        .animation(.easeOut(duration: 0.16), value: isDropTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !isWorking, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in handleFile(url) }
            }
            return true
        }
    }

    private func pickedFileRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(fileSummary ?? "正在读取…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                pickedFile = nil
                fileSummary = nil
                imported = []
                errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除这个文件")
        }
        .padding(10)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private static var fileTypes: [UTType] {
        var types: [UTType] = [.json, .plainText, .text]
        for ext in ["m3u", "m3u8"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.fileTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择\(entryDomain == .networkCinema ? "影视源" : "网络资源")配置文件"
        panel.message = "支持拾光分享包、FongMi 配置，以及每行一个地址的文本文件。"
        panel.prompt = "读取"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        handleFile(url)
    }

    /// 读取文件并分派：JSON 先按拾光分享包解析，不是分享包再按 FongMi 配置解析；
    /// 文本 / M3U 则从中提取地址，走与手填地址完全一致的导入与校验。
    private func handleFile(_ url: URL) {
        guard !isWorking else { return }
        pickedFile = url
        fileSummary = nil
        imported = []
        errorMessage = nil
        progressText = "正在读取 \(url.lastPathComponent)…"
        isWorking = true
        beginIngestJob()
        Task { await ingest(url) }
    }

    @MainActor
    private func ingest(_ url: URL) async {
        defer {
            isWorking = false
            progressText = nil
            // 读文件失败、格式不对等提前返回的分支不会走到 finishImport，这里兜底收尾任务。
            if let job = ingestJobID {
                store.failSourceJob(job, message: errorMessage ?? "文件里没有可接入的来源")
                ingestJobID = nil
            }
        }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "读取文件失败，请确认文件仍然可访问。"
            fileSummary = "无法读取"
            return
        }

        if url.pathExtension.lowercased() == "json" {
            // 1) 拾光分享包：带 format 标记，按范围校验。
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["format"] as? String == "luma.sources" {
                switch SourceTransferJSON.decode(CatalogSource.self,
                                                 from: data,
                                                 expecting: entryDomain.transferScope) {
                case .failure(let error):
                    fileSummary = "无法导入这个文件"
                    errorMessage = error.message
                case .success(let sources):
                    let scoped = sources.filter { $0.domain == entryDomain }
                    guard !scoped.isEmpty else {
                        fileSummary = "没有可用的来源"
                        errorMessage = "分享包里没有可接入的\(entryDomain == .networkCinema ? "影视源" : "网页资源站")。"
                        return
                    }
                    fileSummary = "拾光分享包 · \(scoped.count) 个来源"
                    await load(sources: scoped, label: url.lastPathComponent)
                }
                return
            }

            // 2) FongMi / TVBox 配置：只取本域能接的来源。
            do {
                let parsed = try MacCMSCatalogProvider.importConfig(from: data, origin: nil)
                let scoped = parsed.filter { $0.domain == entryDomain }
                guard !scoped.isEmpty else {
                    fileSummary = "没有可用的来源"
                    errorMessage = entryDomain == .networkCinema
                        ? "配置里没有影视源；网页资源站请到「网络资源」里接入。"
                        : "配置里没有网页资源站；影视源请到「网络影院」里接入。"
                    return
                }
                fileSummary = "FongMi 配置 · \(scoped.count) 个来源"
                await load(sources: scoped, label: url.lastPathComponent)
            } catch {
                fileSummary = "无法解析这个文件"
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return
        }

        // 3) 文本 / M3U：抽出其中的 http(s) 地址。
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            fileSummary = "不是文本文件"
            errorMessage = "这个文件读不出文本内容，请换一份配置或地址文本。"
            return
        }
        let addresses = Self.addresses(inText: text)
        guard !addresses.isEmpty else {
            fileSummary = "没有地址"
            errorMessage = "文件里没有可识别的地址。"
            return
        }
        fileSummary = "地址文本 · \(addresses.count) 条地址"
        await loadAddresses(addresses)
    }

    /// 从文本 / M3U 里取地址：忽略注释与 `#EXTINF` 行，只保留 http(s)。
    private static func addresses(inText text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty, !line.hasPrefix("#") else { return false }
                let lower = line.lowercased()
                guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
                return seen.insert(lower).inserted
            }
    }

    /// 底栏左侧：实时告诉用户「粘进来的内容会被当成什么」。
    @ViewBuilder
    private var detectionSummary: some View {
        if addresses.isEmpty {
            Text("配置与站点地址可混填，自动识别")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                Text("识别到 \(addresses.count) 条")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(kindCounts) { entry in
                    HStack(spacing: 3) {
                        Image(systemName: entry.kind.icon)
                            .font(.system(size: 8.5))
                        Text("\(entry.count) 个\(entry.kind.label)")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            .lineLimit(1)
        }
    }

    private var addresses: [String] { Self.splitAddresses(urlText) }

    private struct KindCount: Identifiable {
        var kind: AddressKind
        var count: Int
        var id: String { kind.label }
    }

    /// 只展示实际出现过的类型，避免「0 个站点」这类噪音。
    private var kindCounts: [KindCount] {
        var configs = 0
        var sites = 0
        for address in addresses {
            switch Self.kind(of: address) {
            case .config: configs += 1
            case .site: sites += 1
            }
        }
        return [KindCount(kind: .config, count: configs),
                KindCount(kind: .site, count: sites)]
            .filter { $0.count > 0 }
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        urlText = text
        inputFocused = true
    }

    // MARK: - 解析结果

    private var availableCount: Int {
        imported.filter { !$0.failed }.count
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("解析结果")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(availableCount) 个可添加")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            VStack(spacing: 10) {
                ForEach(imported) { entry in
                    resultRow(entry, showAllChecks: imported.count == 1)
                }
            }
            if imported.count == 1, imported.first?.source != nil {
                singleSourceOptions
            } else {
                Toggle("添加后立即启用", isOn: $enableAfterAdd)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func resultRow(_ entry: ImportedSource, showAllChecks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: entry.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.failed ? Color.red : Color.green)
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                Text(entry.source?.host ?? entry.address)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let source = entry.source, !source.categories.isEmpty {
                    Text("· \(source.categories.count) 个分类")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            let visible = showAllChecks ? entry.checks : entry.checks.filter { $0.state == .failed }
            ForEach(visible) { check in
                HStack(spacing: 6) {
                    Image(systemName: check.state == .ok ? "checkmark" : "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(check.state == .ok ? Color.secondary : Color.red)
                    Text(check.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(check.state == .ok ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                .padding(.leading, 19)
            }
        }
    }

    private var singleSourceOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 1)
            HStack(spacing: 10) {
                Text("名称")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                TextField("显示名称", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
            }
            if let source = imported.first?.source {
                HStack(spacing: 10) {
                    Text("分类")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Text(source.categories.map(\.title).joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Toggle("添加后立即启用", isOn: $enableAfterAdd)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))

            if let source = imported.first?.source {
                Divider().padding(.vertical, 1)

                Toggle("允许不受信任的证书（跳过 \(source.host) 的 HTTPS 校验）", isOn: $allowInsecure)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                Text("仅在该站点证书确实无效、但你确认站点可信时开启；开启后该主机的加密流量可能被中间人截获。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(allowInsecure ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { imported.first?.source?.name ?? "" },
            set: { value in
                guard !imported.isEmpty, var source = imported[0].source else { return }
                source.name = value
                imported[0].source = source
            }
        )
    }

    private func callout(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(imported.count > 1 ? "添加 \(availableCount) 个资源" : "添加资源") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var canAdd: Bool {
        !isWorking && imported.contains { !$0.failed }
    }

    // MARK: - 动作

    /// 逗号（中英文）、分号、空格、换行都算地址分隔符；重复地址只保留一次。
    static func splitAddresses(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，;； \t\r\n")
        var seen = Set<String>()
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func runImport() {
        let addresses = Self.splitAddresses(urlText)
        guard !addresses.isEmpty, !isWorking else { return }

        isWorking = true
        progressText = nil
        errorMessage = nil
        imported = []
        inputFocused = false
        beginIngestJob()

        Task { await loadAddresses(addresses) }
    }

    /// 逐条解析地址，再统一校验。地址 tab 与文本 / M3U 文件共用这一条路径。
    @MainActor
    private func loadAddresses(_ addresses: [String]) async {
        var results: [ImportedSource] = []
        for (index, address) in addresses.enumerated() {
            progressText = addresses.count > 1
                ? "正在解析 \(index + 1)/\(addresses.count)：\(shortHost(address))"
                : "正在读取配置并验证站点…"
            reportIngestProgress(completed: index, total: addresses.count, message: progressText)
            do {
                let parsed = try await importOne(address)
                // 只保留本域的来源：影视源与网页资源站不能在同一入口互相混入。
                let sources = parsed.filter { $0.domain == entryDomain }
                guard !sources.isEmpty else {
                    throw CatalogError.invalidConfig(
                        entryDomain == .networkCinema
                            ? "这条地址是网页资源站，请到「网络资源 › 接入资源」添加"
                            : "这条地址是影视源，请到「网络影院 › 接入影视源」添加")
                }
                for source in sources {
                    var copy = source
                    copy.allowsInsecureTLS = allowInsecure && addresses.count == 1 && sources.count == 1
                    results.append(ImportedSource(address: address, source: copy))
                    // 一次配置可能带几十个站点：上限之外的不再列出，避免面板卡住。
                    if results.count >= 60 { break }
                }
            } catch {
                results.append(ImportedSource(address: address,
                                              source: nil,
                                              checks: [Check(text: error.localizedDescription,
                                                             state: .failed)]))
            }
            if results.count >= 60 { break }
        }
        imported = await validated(results, total: addresses.count)
        finishImport()
    }

    /// 文件里直接解析出来的来源（分享包 / FongMi 配置）：同样逐个校验后再展示。
    @MainActor
    private func load(sources: [CatalogSource], label: String) async {
        let entries = Array(sources.prefix(60).map { source -> ImportedSource in
            var copy = source
            // 分享包可能带着别人机器上的本地配置路径，本机访问不到，清掉只保留站点信息。
            let config = copy.configURL?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if !config.hasPrefix("http://"), !config.hasPrefix("https://") {
                copy.configURL = nil
            }
            return ImportedSource(address: label, source: copy)
        })
        imported = await validated(entries, total: entries.count, label: label)
        finishImport()
    }

    @MainActor
    private func finishImport() {
        progressText = nil
        isWorking = false
        let usable = imported.filter { !$0.failed }.count
        guard usable > 0 else {
            let message = "没有解析出可用的站点，请检查地址或站点是否可访问。"
            errorMessage = message
            finishIngestJob(success: false, message: message)
            return
        }
        finishIngestJob(success: true, message: "解析出 \(usable) 个来源")
    }

    /// 逐项校验：普通站点继续校验首页 / 详情 / 封面；
    /// 苹果CMS 批量导入的源只做一次首页探测，否则一次会打几十个请求。
    @MainActor
    private func validated(_ entries: [ImportedSource],
                           total: Int,
                           label: String? = nil) async -> [ImportedSource] {
        var output = entries
        for index in output.indices where output[index].source != nil {
            guard var source = output[index].source else { continue }
            if total > 1 {
                progressText = "正在校验 \(index + 1)/\(total)：\(source.host)"
            } else if let label {
                progressText = "正在校验 \(label)：\(source.host)"
            } else {
                progressText = "正在读取配置并验证站点…"
            }
            reportIngestProgress(completed: index, total: total, message: progressText)
            let checks: [Check]
            if source.kind == .maccms {
                checks = await validateHomeOnly(source)
            } else {
                checks = await validate(source)
            }
            source.allowsInsecureTLS = allowInsecure && total == 1
            output[index].source = source
            output[index].checks = checks
        }
        return output
    }

    /// 按地址自身特征判断类型：JSON 配置文件或 FongMi 相关路径走配置解析，其余按站点处理。
    private static func kind(of address: String) -> AddressKind {
        let lower = address.lowercased()
        let path = URLComponents(string: address)?.path.lowercased() ?? lower
        if path.hasSuffix(".json") || lower.contains("fongmi") || path.contains("config") {
            return .config
        }
        return .site
    }

    /// 按地址挑适配器：苹果CMS 接口优先，其次按域名特征，其余按 91 站处理。
    /// 配置文件可能一次导出多个影视源，所以统一返回数组。
    private func importOne(_ address: String) async throws -> [CatalogSource] {
        if Self.kind(of: address) == .config {
            return try await MacCMSCatalogProvider.importConfig(from: address)
        }
        let lower = address.lowercased()
        // 苹果CMS 接口地址：`…/api.php/provide/vod/`，也接受站点根地址。
        if lower.contains("api.php") || lower.contains("provide/vod") {
            return [try await MacCMSCatalogProvider.importSource(from: address)]
        }
        if lower.contains("91porna") {
            return [try await NinetyOnePornaCatalogProvider.importSource(from: address)]
        } else if lower.contains("fofo") {
            return [try await FoFoCatalogProvider.importSource(from: address)]
        } else if lower.contains("ikanpp") || lower.contains("9fa9fa") {
            return [try await IKanPPCatalogProvider.importSource(from: address)]
        } else if lower.contains("iyf.tv") || lower.contains("kubb.tv") {
            return [try await IYFCatalogProvider.importSource(from: address)]
        } else if lower.contains("xsz-av") {
            return [try await XszCatalogProvider.importSource(from: address)]
        } else if lower.contains("missav") {
            return [try await MissavCatalogProvider.importSource(from: address)]
        } else if lower.contains("avple") {
            return [try await AvpleCatalogProvider.importSource(from: address)]
        } else if lower.contains("shise") {
            return [try await ShiseCatalogProvider.importSource(from: address)]
        } else if lower.contains("avgle") {
            return [try await AvgleCatalogProvider.importSource(from: address)]
        } else if lower.contains("rou.video") {
            return [try await RouVideoCatalogProvider.importSource(from: address)]
        } else if lower.contains("91quanji") || lower.contains("quanji") {
            return [try await QuanjiCatalogProvider.importSource(from: address)]
        } else if lower.contains("javcl") {
            return [try await JavClCatalogProvider.importSource(from: address)]
        } else if lower.contains("madou") {
            return [try await MadouCatalogProvider.importSource(from: address)]
        } else if lower.contains("javgg") {
            return [try await JavGGCatalogProvider.importSource(from: address)]
        } else {
            return [try await NinetyOneCatalogProvider.importSource(from: address)]
        }
    }

    private func shortHost(_ address: String) -> String {
        if let host = URLComponents(string: address)?.host { return host }
        return address
    }

    /// 三项校验：首页、详情分集、封面解密。返回的失败项会禁用该条的添加。
    private func validate(_ source: CatalogSource) async -> [Check] {
        var checks: [Check] = [
            Check(text: "配置可访问，站点：\(source.name)", state: .ok),
            Check(text: "解析到 \(source.categories.count) 个分类", state: .ok)
        ]
        CatalogTrust.setTrusted(source.host, source.trustsInsecureCertificate)

        do {
            guard let provider = CatalogProviders.provider(for: source.kind) else {
                throw CatalogError.unsupportedProvider
            }
            let home = try await provider.home(source: source)
            checks.append(Check(text: "首页解析 \(home.items.count) 条",
                                state: home.items.isEmpty ? .failed : .ok))

            // 首页第一条可能是纯图文榜单：往后找一条真正带播放器的条目来验证详情与封面。
            var checked: (item: CatalogItem, detail: CatalogDetail)?
            for candidate in home.items.prefix(5) {
                if let detail = try? await provider.detail(source: source, itemID: candidate.id),
                   !detail.episodes.isEmpty {
                    checked = (candidate, detail)
                    break
                }
            }

            if let checked {
                checks.append(Check(text: "详情页解析 \(checked.detail.episodes.count) 个视频",
                                    state: .ok))
                let cover = checked.item.coverURL.isEmpty
                    ? checked.detail.item.coverURL : checked.item.coverURL
                if cover.isEmpty {
                    checks.append(Check(text: "卡片没有封面地址", state: .failed))
                } else {
                    _ = try await provider.coverData(source: source, urlString: cover)
                    checks.append(Check(text: "封面加载成功", state: .ok))
                }
            } else if !home.items.isEmpty {
                checks.append(Check(text: "前几条都没有可播放的视频，可能站点结构已变化",
                                    state: .failed))
            }
        } catch {
            checks.append(Check(text: error.localizedDescription, state: .failed))
        }
        return checks
    }

    /// 苹果CMS 批量导入的轻量校验：只探测首页，避免一次配置打几十个详情 / 封面请求。
    private func validateHomeOnly(_ source: CatalogSource) async -> [Check] {
        CatalogTrust.setTrusted(source.host, source.trustsInsecureCertificate)
        do {
            guard let provider = CatalogProviders.provider(for: source.kind) else {
                throw CatalogError.unsupportedProvider
            }
            let home = try await provider.home(source: source)
            return [
                Check(text: "接口可访问：\(source.name)", state: .ok),
                Check(text: "首页解析 \(home.items.count) 条",
                      state: home.items.isEmpty ? .failed : .ok)
            ]
        } catch {
            return [Check(text: error.localizedDescription, state: .failed)]
        }
    }

    private func add() {
        let usable = imported.filter { !$0.failed }.compactMap(\.source)
        guard !usable.isEmpty else { return }
        var firstID: UUID?
        for var source in usable {
            // 同类型、同域名的站点已经在图库里：重新导入时不再加一份。
            if catalog.sources.contains(where: { $0.kind == source.kind && $0.host == source.host }) {
                continue
            }
            source.isEnabled = enableAfterAdd
            source.allowsInsecureTLS = imported.count == 1 ? allowInsecure : false
            catalog.addSource(source)
            if firstID == nil { firstID = source.id }
        }
        guard let firstID else {
            errorMessage = "这些站点都已经在图库里了，不需要重复添加。"
            return
        }
        // 影视源只回网络影院，网页资源站才回网络资源的频道页。
        if usable.first?.domain == .networkCinema {
            store.networkCinemaSourceID = firstID
            store.networkCinemaTab = .movies
            store.navigate(to: .networkCinema)
        } else {
            store.navigate(to: .catalogSource(firstID))
        }
        dismiss()
    }
}
