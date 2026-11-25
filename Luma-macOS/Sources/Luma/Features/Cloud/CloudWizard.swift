import SwiftUI
import AppKit

// MARK: - 统一接入向导
//
// 根视图只负责流程选择、步骤切换与底部动作；各接入方式的步骤视图与动作
// 按类型拆到 CloudWizard+OAuth / +SMB / +WebDAV / +AList 中。

/// 向导里的目录勾选模式：接入这些目录 / 排除这些目录。
enum CloudScopeMode: String, CaseIterable, Identifiable {
    case include
    case exclude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .include: return "接入目录"
        case .exclude: return "排除目录"
        }
    }
}

struct CloudSetupWizardView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var cloud: CloudBrowserModel

    @State var flow: CloudWizardFlow?
    @State var step = 0

    // OAuth
    @State var clientID = ""
    @State var clientSecret = ""
    /// 百度网盘：AppID，仅用于授权链接的 device_id。
    @State var clientAppID = ""
    @State var isBusy = false
    @State var isAuthorizing = false
    @State var showManualCode = false
    @State var manualCode = ""
    /// 百度授权成功后暂存令牌：等用户在「接入范围」里选完目录再注册挂载。
    @State var baiduToken: CloudToken?

    // SMB / WebDAV
    @State var address = ""
    @State var username = ""
    @State var password = ""
    @State var trustSelfSigned = false
    @State var networkVerified = false
    @State var smbAddress = ""
    @State var smbUsername = ""
    @State var smbPassword = ""
    @State var smbVerified = false
    @State var discoveredServers: [String] = []
    @State var isDiscoveringSMB = false
    @State var smbDiscoveryTask: Task<Void, Never>?
    @State var availableShares: [String] = []
    @State var isDiscoveringShares = false
    @State var shareDiscoveryToken = 0
    /// 复用了哪一条已保存 SMB 连接的账号（用于界面提示）。
    @State var reusedSMBMountName: String?
    /// 双击共享后进入的目录浏览状态（第二层及更深）。
    @State var smbBrowseHost: String?
    @State var smbBrowseShare: String?
    @State var smbBrowsePath = ""
    @State var smbBrowseFolders: [String] = []
    @State var isLoadingBrowseFolders = false
    @State var browseFoldersError: String?
    @State var browseToken = 0

    // WebDAV 子目录筛选
    /// 选中接入的子目录层级（相对测试地址的根），为空表示接入当前全部。
    @State var webdavSubPath = ""
    @State var webdavBrowseFolders: [String] = []
    @State var isLoadingWebDAVFolders = false
    @State var webdavBrowseError: String?
    @State var webdavBrowseToken = 0
    @State var webdavFiltersFolders = false

    // 浏览器 Cookie（阿里云盘 / 夸克网盘 / 115 网盘）
    @State var cookieText = ""
    @State var cookieVerified = false

    // Cookie / SMB 的接入范围：读取目录后可勾选一个或多个子目录
    @State var scopePicks: [CloudScopePick] = []
    @State var scopeExcludePicks: [CloudScopePick] = []
    @State var scopeMode: CloudScopeMode = .include
    @State var scopeBrowseTrail: [CloudScopeRoot] = []
    @State var scopeBrowseFolders: [CloudEntry] = []
    @State var scopeBrowseError: String?
    @State var isLoadingScopeFolders = false
    @State var scopeBrowseToken = 0
    @State var scopeTouched = false
    @State var excludeTouched = false

    /// 从「编辑接入范围」进入时携带的挂载 ID：确认页直接保存回该挂载。
    @State var editingMountID: UUID?

    /// 添加到侧边栏时显示的名称；留空则用各接入方式的默认名。
    @State var mountName = ""

    /// 钥匙串里已有同类型连接：首屏直接作为候选，点一下带入地址、账号与密码。
    @State var credentialCandidates: [CloudCredentialCandidate] = []

    // AList
    @State var alistProvider: AlistProvider = .aliyun
    @State var alistAddress = "http://127.0.0.1:5244"
    @State var alistUser = "admin"
    @State var alistPassword = ""
    @State var alistVerified = false
    @State var addedInAlist = false

    // 状态
    @State var status: String?
    @State var statusIsError = false

    private var isLastStep: Bool {
        guard let flow else { return false }
        return step >= flow.steps.count - 1
    }

    private var canContinue: Bool {
        guard let flow else { return false }
        switch flow {
        case .baidu:
            if step == 0 {
                return !clientID.trimmingCharacters(in: .whitespaces).isEmpty
                    && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return true
        case .smb:
            return step == 0 ? smbVerified : true
        case .webdav:
            return step == 0 ? networkVerified : true
        case .aliyunCookie, .quark, .pan115:
            return step == 0 ? cookieVerified : true
        case .alist:
            switch step {
            case 1: return alistVerified
            case 2: return addedInAlist
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                    if let status {
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(statusIsError ? Color.red : Color.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 680)
        .onAppear {
            if let editingID = cloud.wizardEditingMountID,
               let mount = store.cloudMounts.first(where: { $0.id == editingID }) {
                cloud.wizardEditingMountID = nil
                cloud.wizardInitialFlow = nil
                openForEditing(mount)
                return
            }
            cloud.wizardEditingMountID = nil
            if let initial = cloud.wizardInitialFlow {
                cloud.wizardInitialFlow = nil
                select(initial)
            }
        }
        .onDisappear {
            cancelSMBDiscovery()
            OAuthLoopbackServer.shared.cancel()
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("网盘接入向导")
                    .font(.system(size: 15, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let flow {
                Text("第 \(step + 1) / \(flow.steps.count) 步 · \(flow.steps[step])")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                close()
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

    private var headerSubtitle: String {
        guard let flow else {
            return "统一入口：Cookie 直连、官方 OAuth、SMB、WebDAV、AList 聚合"
        }
        switch flow {
        case .baidu:
            return "首次需要在开放平台创建一个应用，之后只需在浏览器登录"
        case .smb:
            return "群晖 / TrueNAS / Windows 共享，只读浏览"
        case .webdav:
            return "群晖 / TrueNAS / 任意 WebDAV 服务"
        case .aliyunCookie:
            return "用浏览器登录凭据换取令牌，不需要开发者资质"
        case .quark:
            return "粘贴浏览器 Cookie，不需要开发者资质"
        case .pan115:
            return "粘贴浏览器 Cookie，不需要开发者资质"
        case .alist:
            return "不需要开发者资质，由 AList 完成各网盘授权"
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let flow {
            switch flow {
            case .baidu:
                oauthContent(flow: flow)
            case .smb:
                smbContent
            case .webdav:
                webdavContent
            case .aliyunCookie, .quark, .pan115:
                cookieContent
            case .alist:
                alistContent
            }
        } else {
            flowSelection
        }
    }

    private var flowSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择接入方式")
                .font(.system(size: 13, weight: .semibold))
            Text("百度网盘走官方 OAuth，需要一次性创建应用；阿里云盘、夸克与 115 直接用浏览器 Cookie 接入，SMB、WebDAV 与 AList 同样不需要开发者资质。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(CloudWizardFlow.allCases) { item in
                    Button {
                        select(item)
                    } label: {
                        HStack(spacing: 10) {
                            if let brand = item.brand {
                                CloudBrandIcon(brand: brand, size: 26)
                            } else {
                                Image(systemName: item.icon)
                                    .font(.system(size: 20))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 26)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                Text(item.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(height: 74)
                        .background {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.primary.opacity(0.05))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            if flow != nil {
                Button(step == 0 ? "返回" : "上一步") {
                    back()
                }
            }
            Spacer()
            Button("取消") { close() }
                .keyboardShortcut(.cancelAction)

            if let flow {
                if isLastStep {
                    Button(primaryTitle(flow)) {
                        primaryAction(flow)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue || isBusy)
                } else if flow.requiresDeveloperApp {
                    if step == 0 {
                        Button("保存并继续") {
                            saveCredentials(flow: flow)
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                    } else if step == 2 {
                        // 百度：授权完成后先在「接入范围」里选目录，再进完成页。
                        Button("下一步") {
                            step = 3
                            status = nil
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue || isBusy)
                    }
                } else {
                    Button("下一步") {
                        step += 1
                        status = nil
                        if flow.usesCookie || flow == .smb {
                            prepareAccessScopeStep()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func primaryTitle(_ flow: CloudWizardFlow) -> String {
        if editingMountID != nil { return "保存" }
        switch flow {
        case .baidu: return "完成"
        case .smb, .webdav, .quark, .pan115, .aliyunCookie: return "添加"
        case .alist: return "测试并添加"
        }
    }

    private func primaryAction(_ flow: CloudWizardFlow) {
        switch flow {
        case .baidu:
            finishBaiduSetup()
        case .smb:
            addSMB()
        case .webdav:
            addWebDAV()
        case .quark:
            addQuark()
        case .pan115:
            addPan115()
        case .aliyunCookie:
            addAliyunCookie()
        case .alist:
            addAList()
        }
    }

    // MARK: 流程切换

    func select(_ flow: CloudWizardFlow) {
        self.flow = flow
        editingMountID = nil
        step = 0
        status = nil
        statusIsError = false
        networkVerified = false
        smbVerified = false
        cookieVerified = false
        mountName = ""
        if !flow.usesCookie { cookieText = "" }
        if flow.usesCookie || flow == .smb { resetAccessScope(for: flow) }
        if flow == .smb {
            // 已有 SMB 连接时复用账号与钥匙串密码，不必再输一次。
            prefillSMBAccount()
            startSMBDiscovery()
            if let host = SMBClient.pieces(smbAddress)?.host, !host.isEmpty,
               !smbUsername.trimmingCharacters(in: .whitespaces).isEmpty,
               !smbPassword.isEmpty {
                // 账号齐全就直接列出共享，省去再点「发现共享」。
                discoverShares(host: host)
            }
        } else {
            cancelSMBDiscovery()
        }
        resetWebDAVBrowse()
        refreshCredentialCandidates(for: flow)
        if let kind = flow.kind, let saved = CloudOAuthStore.credentials(for: kind) {
            clientID = saved.clientID
            clientSecret = saved.clientSecret
            clientAppID = saved.appID ?? ""
        }
    }

    private func back() {
        status = nil
        if step > 0 {
            step -= 1
        } else {
            flow = nil
            cancelSMBDiscovery()
            if isAuthorizing {
                OAuthLoopbackServer.shared.cancel()
                isAuthorizing = false
            }
        }
    }

    func close() {
        cancelSMBDiscovery()
        if isAuthorizing {
            OAuthLoopbackServer.shared.cancel()
            isAuthorizing = false
        }
        cloud.showWizard = false
    }

    // MARK: 通用组件

    func bullet(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func labeledField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    func labeledSecureField(_ label: String, text: Binding<String>, prompt: String,
                            onSubmit: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit?() }
        }
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func open(_ raw: String) {
        if let url = URL(string: raw), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else if let url = WebDAVClient.normalizedBaseURL(raw) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 钥匙串候选

/// 向导首屏的「从钥匙串带入」候选：来自已保存的同类连接（地址 + 账号 + 密码）。
struct CloudCredentialCandidate: Identifiable {
    let mount: CloudMount
    let hasPassword: Bool

    var id: UUID { mount.id }

    var host: String {
        URLComponents(string: mount.baseURL)?.host ?? mount.baseURL
    }

    var detail: String {
        let account = mount.username.isEmpty ? "无账号" : mount.username
        return "\(host) · \(account)"
    }
}

extension CloudSetupWizardView {
    /// 按当前流程读取同类已保存连接；密码状态走 `CloudCredentials` 的进程内缓存，不会反复读钥匙串。
    func refreshCredentialCandidates(for flow: CloudWizardFlow) {
        guard let kind = flow.kind, kind == .webdav || kind == .smb else {
            credentialCandidates = []
            return
        }
        credentialCandidates = store.cloudMounts
            .filter { $0.kind == kind && !$0.baseURL.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
            .map { mount in
                CloudCredentialCandidate(mount: mount,
                                         hasPassword: !store.cloudPassword(for: mount.id).isEmpty)
            }
    }

    /// 候选列表：点一下把地址、账号与钥匙串密码填进当前流程。
    @ViewBuilder
    func credentialCandidateSection(_ candidates: [CloudCredentialCandidate],
                                    noun: String,
                                    apply: @escaping (CloudCredentialCandidate) -> Void) -> some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(LumaBrand.amber)
                    Text("从钥匙串带入")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("\(noun) · 已保存 \(candidates.count) 个连接")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 8)], spacing: 8) {
                    ForEach(candidates) { candidate in
                        credentialCandidateChip(candidate, apply: apply)
                    }
                }
                Text("单击候选即可带入地址、账号与钥匙串密码。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LumaBrand.amber.opacity(0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LumaBrand.amber.opacity(0.22), lineWidth: 1)
            }
        }
    }

    private func credentialCandidateChip(_ candidate: CloudCredentialCandidate,
                                         apply: @escaping (CloudCredentialCandidate) -> Void) -> some View {
        Button {
            apply(candidate)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(LumaBrand.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.mount.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(candidate.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: candidate.hasPassword ? "checkmark.seal.fill" : "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(candidate.hasPassword ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(candidate.hasPassword
              ? "带入「\(candidate.mount.name)」的地址、账号与钥匙串密码"
              : "带入「\(candidate.mount.name)」的地址与账号，钥匙串里没有密码")
    }
}
