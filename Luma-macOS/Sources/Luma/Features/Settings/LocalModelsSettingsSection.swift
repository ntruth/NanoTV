import AppKit
import SwiftUI
import LumaContentCore

/// 设置 › 模型 › 本地能力：逐个开关本机模型，默认全部关闭。
struct LocalModelsSettingsSection: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var installer = ModelInstaller.shared
    @AppStorage(SettingsKeys.modelManifestURL) private var manifestURL = ModelInstaller.defaultManifestURL
    @State private var pendingRemoval: ModelComponentDescriptor?
    @State private var checkingManifest = false
    @State private var runtimeCandidates: [LocalRuntimeCandidate] = []
    @State private var selectedModels: [String: String] = [:]
    @State private var scanningRuntime = false
    @State private var runtimeMessage: String?
    /// 模型下载在统一任务中心里的登记 id：下载期间切走设置页也能看到进度。
    @State private var installJobID: UUID?
    @State private var installJobModel: ModelComponentID?
    @State private var installJobSawBusy = false

    var body: some View {
        Group {
            Section("本地能力") {
                ForEach(ModelRegistry.catalog) { descriptor in
                    row(descriptor)
                }
                Text("安装在本机 \(ModelRegistry.modelsRoot.path)，不随图库迁移或备份；关闭开关只停用。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("本地运行时") {
                HStack(spacing: 8) {
                    Button(scanningRuntime ? "检测中…" : "检测本机运行时") {
                        detectRuntime()
                    }
                    .disabled(scanningRuntime)
                    if let runtimeMessage {
                        Text(runtimeMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                ForEach(runtimeCandidates) { candidate in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title)
                                .font(.system(size: 12, weight: .medium))
                            Text(candidate.baseURL)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Picker("模型", selection: modelBinding(candidate)) {
                            ForEach(candidate.models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Button("使用") { use(candidate) }
                            .controlSize(.small)
                    }
                }
                Text("通过 OpenAI 兼容接口连接本机服务（Ollama 11434 / LM Studio 1234），数据不出本机。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("下载源") {
                TextField("留空使用 App 内置清单", text: $manifestURL)
                    .font(.system(size: 12, design: .monospaced))
                HStack(spacing: 8) {
                    Button(checkingManifest ? "检查中…" : "检查更新") {
                        checkingManifest = true
                        Task {
                            await installer.refreshManifest()
                            checkingManifest = false
                        }
                    }
                    .disabled(checkingManifest)
                    if let error = installer.manifestError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else if let manifest = installer.manifest {
                        Text("清单版本 \(manifest.version) · \(manifest.components.count) 个组件")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("默认使用 App 内置清单，模型文件走 hf-mirror 国内镜像。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text("留空使用内置清单；图像 / 文本编码器走 hf-mirror，词表随 App 内置。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .alert("删除本地模型？", isPresented: removalBinding) {
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("删除", role: .destructive) {
                if let descriptor = pendingRemoval {
                    installer.uninstall(descriptor.id)
                }
                pendingRemoval = nil
            }
        } message: {
            Text("会删除本机文件，之后需要重新下载；随 App 内置的模型只会停用，不会被删除。")
        }
        .onChange(of: installer.states) { _, _ in
            syncInstallJob()
        }
    }

    // MARK: - 模型下载任务

    /// 把模型安装进度映射到统一任务中心：开始下载时登记，结束 / 失败时收尾。
    private func syncInstallJob() {
        guard let jobID = installJobID, let modelID = installJobModel else { return }
        let state = installer.state(for: modelID)
        switch state.phase {
        case .preparing, .downloading, .verifying, .installing:
            installJobSawBusy = true
            store.updateSourceJob(jobID,
                                  message: "\(phaseText(state.phase)) \(Int((state.progress * 100).rounded()))%",
                                  fraction: state.progress)
        case .failed(let message):
            store.failSourceJob(jobID, message: message)
            resetInstallJob()
        case .idle:
            // 刚开始安装时 installer 还没进入 busy 阶段，不能立刻判定为结束。
            guard installJobSawBusy else { return }
            if ModelRegistry.isInstalled(modelID) {
                store.finishSourceJob(jobID, message: "已安装")
            } else {
                store.cancelSourceJob(jobID)
            }
            resetInstallJob()
        }
    }

    private func startInstall(_ descriptor: ModelComponentDescriptor) {
        installJobID = store.beginSourceJob(
            SourceJob(sourceID: .library((LibraryPaths.containerLibraryURL ?? LibraryPaths.root)
                .standardizedFileURL.path),
                      kind: .download,
                      title: "下载模型 \(descriptor.title)"),
            cancel: { ModelInstaller.shared.cancel(descriptor.id) }
        )
        installJobModel = descriptor.id
        installJobSawBusy = false
        installer.install(descriptor.id)
    }

    private func resetInstallJob() {
        installJobID = nil
        installJobModel = nil
        installJobSawBusy = false
    }

    private func phaseText(_ phase: ModelInstaller.Phase) -> String {
        switch phase {
        case .preparing: return "准备中"
        case .downloading: return "下载中"
        case .verifying: return "校验中"
        case .installing: return "安装中"
        case .idle, .failed: return "下载"
        }
    }

    // MARK: - 行

    private func row(_ descriptor: ModelComponentDescriptor) -> some View {
        let installed = ModelRegistry.isInstalled(descriptor.id)
        let enabled = ModelRegistry.isEnabled(descriptor.id)
        let state = installer.state(for: descriptor.id)
        let busy = state.phase.isBusy
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(descriptor.title)
                    .font(.system(size: 12, weight: .medium))
                Text(statusText(descriptor, installed: installed, enabled: enabled, state: state))
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor(state: state, enabled: enabled))
                Spacer(minLength: 0)
                if descriptor.installable {
                    Toggle("", isOn: toggleBinding(descriptor))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!ModelRegistry.isInstallable(descriptor.id))
                } else {
                    // 没有内置运行时：不给一个永远打不开的开关，直接引导到下方「本地运行时」。
                    Button(scanningRuntime ? "检测中…" : "连接本地运行时") {
                        detectRuntime()
                    }
                    .controlSize(.small)
                    .disabled(scanningRuntime)
                }
            }
            Text(descriptor.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if state.phase == .downloading {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                Text("\(Int(state.progress * 100))% · \(byteText(state.received)) / \(byteText(state.total))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let note = descriptor.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if descriptor.installable, !busy {
                HStack(spacing: 12) {
                    Button("从本地导入…") {
                        pickLocalDirectory(descriptor)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    if installed {
                        if ModelRegistry.isRemovable(descriptor.id) {
                            Button("删除本地文件（\(byteText(ModelRegistry.sizeOnDisk(descriptor.id)))）") {
                                pendingRemoval = descriptor
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        } else {
                            Text("随 App 内置，无法在此删除；关闭开关即可停用。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func toggleBinding(_ descriptor: ModelComponentDescriptor) -> Binding<Bool> {
        Binding(
            get: { ModelRegistry.isEnabled(descriptor.id) || installer.isBusy(descriptor.id) },
            set: { on in
                if on {
                    if ModelRegistry.isInstalled(descriptor.id) {
                        ModelRegistry.setEnabled(true, for: descriptor.id)
                    } else {
                        startInstall(descriptor)
                    }
                } else {
                    if installer.isBusy(descriptor.id) {
                        installer.cancel(descriptor.id)
                    }
                    ModelRegistry.setEnabled(false, for: descriptor.id)
                }
            }
        )
    }

    private func statusText(_ descriptor: ModelComponentDescriptor,
                            installed: Bool,
                            enabled: Bool,
                            state: ModelInstaller.InstallState) -> String {
        switch state.phase {
        case .preparing: return "准备中…"
        case .downloading: return "下载中"
        case .verifying: return "校验中…"
        case .installing: return "安装中…"
        case .failed(let message): return "失败：\(message)"
        case .idle:
            guard installed else {
                if !descriptor.installable {
                    return "由外部运行时提供（Ollama / LM Studio）"
                }
                return ModelRegistry.isInstallable(descriptor.id)
                    ? "未安装 · \(descriptor.approxSize)"
                    : "当前系统不支持（需要 macOS 15 以上）"
            }
            let version = ModelRegistry.installedVersion(descriptor.id) ?? ""
            let suffix = version.isEmpty ? "" : " · v\(version)"
            return enabled ? "已启用\(suffix)" : "已停用\(suffix)"
        }
    }

    private func statusColor(state: ModelInstaller.InstallState, enabled: Bool) -> Color {
        switch state.phase {
        case .failed: return .red
        case .preparing, .downloading, .verifying, .installing: return .secondary
        case .idle: return enabled ? .green : .secondary
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 本地导入

    private func pickLocalDirectory(_ descriptor: ModelComponentDescriptor) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择包含 \(descriptor.requiredEntries.joined(separator: "、")) 的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            installer.importLocalDirectory(url, for: descriptor.id)
        }
    }

    // MARK: - 本地运行时

    private func detectRuntime() {
        scanningRuntime = true
        runtimeMessage = nil
        let configured = store.aiConfig.baseURL
        Task {
            let candidates = await LocalRuntimeScanner.scan(extra: configured)
            runtimeCandidates = candidates
            scanningRuntime = false
            if candidates.isEmpty {
                runtimeMessage = "没有检测到本机服务，请先启动 Ollama 或 LM Studio。"
            }
        }
    }

    private func modelBinding(_ candidate: LocalRuntimeCandidate) -> Binding<String> {
        Binding(
            get: { selectedModels[candidate.baseURL] ?? candidate.models.first ?? "" },
            set: { selectedModels[candidate.baseURL] = $0 }
        )
    }

    private func use(_ candidate: LocalRuntimeCandidate) {
        let model = selectedModels[candidate.baseURL] ?? candidate.models.first ?? ""
        guard !model.isEmpty else { return }
        store.aiConfig.provider = .local
        store.aiConfig.baseURL = candidate.baseURL
        store.aiConfig.model = model
        store.saveAIConfig()
        runtimeMessage = "已切换到 \(candidate.title) · \(model)"
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } })
    }
}
