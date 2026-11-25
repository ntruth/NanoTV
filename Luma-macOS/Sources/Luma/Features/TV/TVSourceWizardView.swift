import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumaContentCore

/// 接入电视源：地址与文件两种方式合并在同一个面板里。
/// 地址可一次粘贴多条 M3U / M3U8；文件支持本地 M3U 与拾光分享包，保存前逐条拉取校验。
/// 本地文件会复制进图库，之后原文件被移动或删除都不影响播放。
struct TVSourceWizardView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var tv: IPTVBrowserModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var entryMode: SourceEntryMode = .address
    @State private var urlText = ""
    @State private var isSaving = false
    @State private var progressText: String?
    @State private var errorMessage: String?
    /// 底部一行临时反馈（例如「这些地址已经在电视源里」），几秒后自动消失。
    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?
    /// 文件方式：选中的本地文件；json 分享包会额外保留原始数据，保存时整包登记。
    @State private var pickedFile: URL?
    @State private var bundleData: Data?
    @State private var fileSummary: String?
    @State private var isDropTargeted = false
    /// 本次接入登记在统一任务中心里的任务：读取、拉取与校验的耗时都会计入。
    @State private var ingestJobID: UUID?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 8) {
                SourceEntryModeTab(mode: $entryMode)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if entryMode == .address {
                        addressTab
                    } else {
                        fileTab
                    }
                    if isSaving, let progressText {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text(progressText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if let errorMessage {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(TVBrand.danger)
                            Text(errorMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(TVBrand.danger)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(TVBrand.danger.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    hintRow
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onChange(of: entryMode) { _, _ in
            errorMessage = nil
            note = nil
            progressText = nil
        }
        .onExitCommand { dismiss() }
        .onDisappear {
            // 面板中途关闭：未收尾的任务直接从任务条收起，不在记录里留半截。
            if let job = ingestJobID {
                store.abandonSourceJob(job)
                ingestJobID = nil
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("接入电视源")
                    .font(.system(size: 15, weight: .semibold))
                Text("M3U / M3U8 播放列表地址，或本地播放列表与拾光分享包；保存前会逐条拉取校验")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(entryMode == .address ? "保存" : "导入") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var canSave: Bool {
        guard !isSaving else { return false }
        if entryMode == .address { return !addresses.isEmpty }
        return bundleData != nil || pickedFile != nil
    }

    // MARK: - 地址

    private var addressTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("支持 M3U / M3U8 播放列表地址，可一次粘贴多条（每行一条，或用逗号、空格分隔）。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            inputCard
        }
    }

    private var inputCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if urlText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("粘贴 M3U / M3U8 地址，每行一条")
                            .foregroundStyle(.secondary)
                        Text("https://example.com/list.m3u")
                            .foregroundStyle(.tertiary)
                        Text("https://example.com/cctv.m3u8")
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
                    .disabled(isSaving)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
            }
            .frame(height: 150)

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                Text(note ?? (addresses.isEmpty ? "每行一条，自动去重" : "识别到 \(addresses.count) 条地址"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(note != nil ? Color.accentColor
                                     : (addresses.isEmpty ? Color.secondary.opacity(0.55) : Color.secondary))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !urlText.isEmpty, !isSaving {
                    Button("清空") { urlText = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
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

    private var hintRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 9.5, weight: .semibold))
            Text(entryMode == .address
                 ? "地址需以 http / https 开头；也可以切到「文件」导入本地播放列表或拾光分享包。"
                 : "本地播放列表会复制进当前图库；原文件之后被移动或删除，都不影响播放。")
                .font(.system(size: 10.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 文件

    private var fileTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("支持本地 M3U / M3U8 / TXT 播放列表，以及从其他设备导出的拾光分享包（.json）。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            filePicker
            if let pickedFile {
                pickedFileRow(pickedFile)
            }
        }
    }

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
            Text(isDropTargeted ? "松手即可读取" : "拖入播放列表，或从磁盘选择")
                .font(.system(size: 12.5, weight: .semibold))
            Text("M3U / M3U8 / TXT 播放列表 · 拾光分享包（.json）")
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
            .disabled(isSaving)
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
            guard !isSaving, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in handleFile(url) }
            }
            return true
        }
    }

    private func pickedFileRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: bundleData == nil ? "list.bullet.rectangle" : "shippingbox.fill")
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
                bundleData = nil
                fileSummary = nil
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
        panel.title = "选择电视源文件"
        panel.message = "支持本地 M3U / M3U8 / TXT 播放列表，以及拾光导出的电视源分享包。"
        panel.prompt = "读取"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        handleFile(url)
    }

    /// JSON 先按拾光分享包解析；其余文件按本地播放列表处理，保存时复制进图库。
    private func handleFile(_ url: URL) {
        pickedFile = url
        bundleData = nil
        fileSummary = nil
        errorMessage = nil
        note = nil

        guard url.pathExtension.lowercased() == "json" else {
            fileSummary = "本地播放列表 · 导入后复制到图库"
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            fileSummary = "无法读取"
            errorMessage = "读取文件失败，请确认文件仍然可访问。"
            return
        }
        switch SourceTransferJSON.decode(TVPlaylist.self, from: data, expecting: .television) {
        case .failure(let error):
            fileSummary = "无法导入这个文件"
            errorMessage = error.message
        case .success(let items):
            guard !items.isEmpty else {
                fileSummary = "没有电视源"
                errorMessage = "分享包里没有电视源。"
                return
            }
            bundleData = data
            fileSummary = "拾光分享包 · \(items.count) 个电视源"
        }
    }

    // MARK: - 动作

    private var addresses: [String] { Self.splitAddresses(urlText) }

    private func showNote(_ text: String) {
        noteTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { note = text }
        noteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { note = nil }
        }
    }

    // MARK: - 任务中心

    private func beginIngestJob() {
        if let job = ingestJobID { store.abandonSourceJob(job) }
        ingestJobID = store.beginSourceJob(SourceJob(sourceID: SourceID("tv:hub"),
                                                     kind: .ingest,
                                                     title: "接入电视源",
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

    private func save() {
        switch entryMode {
        case .address:
            saveAddresses()
        case .file:
            saveFile()
        }
    }

    private func saveAddresses() {
        let list = addresses
        guard !list.isEmpty, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        inputFocused = false
        beginIngestJob()
        Task { @MainActor in
            let result = await tv.addPlaylists(urlStrings: list) { index, total, host in
                progressText = "正在校验 \(index)/\(total)：\(host)"
                reportIngestProgress(completed: index, total: total, message: progressText)
            }
            isSaving = false
            progressText = nil
            if result.added == 0, result.failures.isEmpty {
                showNote("这些地址都已经在电视源里了，没有新增")
                finishIngestJob(success: true, message: "没有新增：地址都已存在")
                return
            }
            if result.added == 0, !result.failures.isEmpty {
                errorMessage = "没有可用源：\n" + result.failures.joined(separator: "\n")
                finishIngestJob(success: false, message: "没有可用源（\(result.failures.count) 个地址失败）")
                return
            }
            if !result.failures.isEmpty {
                // 部分成功：留下失败清单，方便改地址后重试。
                errorMessage = "已添加 \(result.added) 个源；以下地址失败：\n"
                    + result.failures.joined(separator: "\n")
                finishIngestJob(success: true,
                                message: "已接入 \(result.added) 个，\(result.failures.count) 个失败")
                return
            }
            finishIngestJob(success: true, message: "已接入 \(result.added) 个电视源")
            tv.setHubTab(.channels)
            dismiss()
        }
    }

    private func saveFile() {
        guard let url = pickedFile, !isSaving else { return }
        errorMessage = nil

        // 分享包：整包登记，重复地址自动跳过，频道交给正常的刷新流程补齐。
        if let data = bundleData {
            beginIngestJob()
            reportIngestProgress(message: "正在导入 \(url.lastPathComponent)")
            let outcome = tv.importPlaylistBundle(data)
            if let message = outcome.error {
                errorMessage = message
                finishIngestJob(success: false, message: message)
                return
            }
            guard outcome.added > 0 else {
                showNote(outcome.summary)
                finishIngestJob(success: true, message: outcome.summary)
                return
            }
            finishIngestJob(success: true, message: "已导入 \(outcome.added) 个电视源")
            tv.setHubTab(.channels)
            dismiss()
            return
        }

        // 本地播放列表：复制进图库后按正常流程校验并登记。
        isSaving = true
        progressText = "正在读取 \(url.lastPathComponent)…"
        beginIngestJob()
        reportIngestProgress(message: progressText)
        Task { @MainActor in
            do {
                let playlist = try await tv.importPlaylistFile(at: url)
                progressText = "已接入 \(playlist.name)"
                isSaving = false
                finishIngestJob(success: true, message: "已接入 \(playlist.name)")
                tv.setHubTab(.channels)
                dismiss()
            } catch {
                isSaving = false
                progressText = nil
                let message = (error as? SourceError)?.message ?? error.localizedDescription
                errorMessage = message
                finishIngestJob(success: false, message: message)
            }
        }
    }

    /// 按行 / 逗号 / 空格拆地址，并去掉重复项。
    private static func splitAddresses(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，;； \t\r\n")
        var seen = Set<String>()
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
