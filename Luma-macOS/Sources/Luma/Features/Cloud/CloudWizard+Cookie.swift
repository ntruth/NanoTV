import SwiftUI
import AppKit

// MARK: - 浏览器 Cookie 流程（阿里云盘 / 夸克网盘）

extension CloudSetupWizardView {
    @ViewBuilder
    var cookieContent: some View {
        if step == 0 {
            cookieInputStep
        } else {
            cookieConfirmStep
        }
    }

    private var isAliyunCookie: Bool { flow == .aliyunCookie }
    private var isPan115Cookie: Bool { flow == .pan115 }
    private var cookieProviderName: String {
        if isAliyunCookie { return "阿里云盘" }
        return isPan115Cookie ? "115 网盘" : "夸克网盘"
    }

    private var cookieSiteURL: String {
        if isAliyunCookie { return "https://alist.nn.ci/tool/aliyundrive/request" }
        return isPan115Cookie ? "https://115.com" : "https://pan.quark.cn"
    }

    private var cookieSiteTitle: String {
        if isAliyunCookie { return "打开令牌工具" }
        return isPan115Cookie ? "打开 115 网盘" : "打开夸克网盘"
    }

    private var cookieInputStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. 从浏览器复制\(cookieProviderName)登录凭据")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                if isAliyunCookie {
                    bullet("1", "打开阿里云盘令牌工具（AList 提供，扫码授权即可，不需要开发者资质）")
                    bullet("2", "用阿里云盘手机 App 扫码并在手机上确认授权")
                    bullet("3", "页面会显示 refresh_token=…，复制整行（令牌以 eyJ 开头）")
                    bullet("4", "粘贴到下面测试；网页 localStorage 里的 token 不能用，网页令牌会被开放平台接口拒绝")
                } else if isPan115Cookie {
                    bullet("1", "用 Chrome / Edge / Safari 打开并登录 115.com")
                    bullet("2", "按 ⌥⌘I 打开开发者工具，切到「网络」，刷新页面")
                    bullet("3", "点任意一条请求，在「请求标头」里找到 Cookie，整段复制（需包含 UID / CID / SEID / KID）")
                    bullet("4", "粘贴到下面，点「测试 Cookie」；通过后即可添加")
                } else {
                    bullet("1", "用 Chrome / Edge / Safari 打开并登录 pan.quark.cn")
                    bullet("2", "按 ⌥⌘I 打开开发者工具，切到「网络」，刷新页面")
                    bullet("3", "点任意一条请求，在「请求标头」里找到 Cookie，整段复制")
                    bullet("4", "粘贴到下面，点「测试 Cookie」；通过后即可添加")
                }
            }

            HStack(spacing: 8) {
                Button(cookieSiteTitle) {
                    open(cookieSiteURL)
                }
                Button("从剪贴板粘贴") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        cookieText = text
                    }
                }
                Spacer()
            }
            .controlSize(.small)

            Divider()

            TextEditor(text: $cookieText)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.10))
                }
                .onChange(of: cookieText) { _, _ in
                    cookieVerified = false
                }

            HStack(spacing: 8) {
                Button(isBusy ? "测试中…" : (isAliyunCookie ? "测试凭据" : "测试 Cookie")) {
                    testCookie()
                }
                .disabled(isBusy || cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if cookieVerified {
                    Label("已连通", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
                Spacer()
                if isAliyunCookie {
                    Text(AliyunCookieAuth.extractRefreshToken(cookieText) == nil
                         ? "未识别到 refresh_token（应以 eyJ 开头）"
                         : "已识别 refresh_token")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(AliyunCookieAuth.extractRefreshToken(cookieText) == nil
                                         ? Color.orange : Color.green)
                } else {
                    Text("\(normalizedCookieCount) 字符")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Text("凭据只保存在本机 macOS 钥匙串；过期后（提示需要登录）重新复制一次即可。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cookieConfirmStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认并添加")
                .font(.system(size: 13, weight: .semibold))
            labeledField("名称", text: $mountName, prompt: cookieProviderName)
            VStack(alignment: .leading, spacing: 6) {
                infoRow("接入方式", isAliyunCookie
                        ? "阿里云盘（Cookie / 令牌）"
                        : "\(cookieProviderName)（Cookie）")
                if isAliyunCookie {
                    infoRow("登录凭据", "refresh_token，已保存到钥匙串")
                    infoRow("令牌", "过期后自动用 refresh_token 续期")
                } else {
                    infoRow("Cookie", "已保存 \(normalizedCookieCount) 字符")
                }
                infoRow("浏览范围", accessScopeSummary)
                infoRow("视频", isAliyunCookie ? "优先官方转码，失败时走直链" : "官方直链流式播放")
                infoRow("写操作", "当前为只读；上传/删除请到网盘 App")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            accessScopeSection

            Text("添加后可在侧边栏「网络存储」找到它；右击可更新 Cookie 或断开连接。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 接入范围（读取目录 + 多选 / 排除子目录）

    var accessScopeSummary: String {
        let excluded = scopeExcludePicks.isEmpty ? "" : "；排除 \(scopeExcludePicks.count) 个目录"
        guard !scopePicks.isEmpty else {
            return scopeExcludePicks.isEmpty
                ? "整个网盘；支持「相册」与「文件夹」两种视图"
                : "整个网盘\(excluded)"
        }
        let names = scopePicks.prefix(3).map(\.root.name).joined(separator: "、")
        let more = scopePicks.count > 3 ? " 等 \(scopePicks.count) 个目录" : ""
        return "仅扫描 \(names)\(more)\(excluded)"
    }

    var accessScopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("接入范围")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Toggle("整个网盘", isOn: Binding(
                    get: { scopePicks.isEmpty },
                    set: { whole in
                        guard whole else { return }
                        scopeTouched = true
                        scopePicks = []
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }

            if scopePicks.isEmpty {
                Text("默认扫描整个网盘；也可以在下面勾选一个或多个子目录。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                scopePickChips(scopePicks, tint: Color.accentColor) { pick in
                    scopeTouched = true
                    scopePicks.removeAll { $0.id == pick.id }
                }
            }

            if !scopeExcludePicks.isEmpty {
                Text("排除目录（始终跳过）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                scopePickChips(scopeExcludePicks, tint: Color.orange) { pick in
                    excludeTouched = true
                    scopeExcludePicks.removeAll { $0.id == pick.id }
                }
            }

            Picker("勾选模式", selection: $scopeMode) {
                ForEach(CloudScopeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            scopeBrowser
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private func scopePickChips(_ picks: [CloudScopePick],
                                tint: Color,
                                remove: @escaping (CloudScopePick) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
            ForEach(picks) { pick in
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(tint)
                    Text(pick.root.name)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                    Button {
                        remove(pick)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("移出列表")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(0.10))
                }
            }
        }
    }

    private var scopeBrowser: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    scopeBrowseUp()
                } label: {
                    Label(scopeBrowseTrail.isEmpty ? "根目录" : "上一级", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(scopeBrowseTrail.isEmpty || isLoadingScopeFolders)

                Text(scopeBrowseTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isLoadingScopeFolders {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Button("重新读取") {
                    loadAccessScopeFolders()
                }
                .controlSize(.small)
                .disabled(isLoadingScopeFolders)
            }

            Text(scopeMode == .include
                 ? "勾选文件夹可多选接入；点文件夹名进入下一层。"
                 : "勾选文件夹会排除整棵子树；点文件夹名进入下一层。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            scopeBrowserContent
        }
    }

    @ViewBuilder
    private var scopeBrowserContent: some View {
        if let error = scopeBrowseError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(error)
                    .font(.system(size: 10.5))
                    .lineLimit(3)
            }
            .foregroundStyle(.secondary)
        } else if isLoadingScopeFolders && scopeBrowseFolders.isEmpty {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在读取目录…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else if scopeBrowseFolders.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("这个目录下没有子文件夹；可直接选择整个网盘。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(scopeBrowseFolders) { folder in
                        scopeFolderRow(folder)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    private func scopeFolderRow(_ entry: CloudEntry) -> some View {
        let currentPicks = scopeMode == .include ? scopePicks : scopeExcludePicks
        let selected = currentPicks.contains { $0.root.path == entry.path }
        let contained = currentPicks.contains { $0.ancestors.contains(entry.path) }
        let otherPicks = scopeMode == .include ? scopeExcludePicks : scopePicks
        let otherBadge = otherPicks.contains { $0.root.path == entry.path }
            ? (scopeMode == .include ? "已排除" : "已接入")
            : nil
        return HStack(spacing: 8) {
            Button {
                toggleScope(entry)
            } label: {
                Image(systemName: selected
                      ? "checkmark.square.fill"
                      : (contained ? "checkmark.square" : "square"))
                    .font(.system(size: 13))
                    .foregroundStyle(selected && !contained ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(contained)
            .help(contained
                  ? "已被上级目录包含"
                  : (selected ? "取消勾选该目录" : "勾选这个目录"))

            Button {
                enterScopeFolder(entry)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(entry.name)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    if let otherBadge {
                        Text(otherBadge)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background {
                                Capsule().fill(Color.primary.opacity(0.08))
                            }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("进入「\(entry.name)」查看下一层")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }

    private var scopeBrowseTitle: String {
        guard !scopeBrowseTrail.isEmpty else { return "根目录" }
        return scopeBrowseTrail.map(\.name).joined(separator: " › ")
    }

    /// 重新授权 / 编辑时把已保存的接入范围与排除目录带入，避免误重置。
    func resetAccessScope(for flow: CloudWizardFlow) {
        scopeBrowseToken += 1
        scopeBrowseTrail = []
        scopeBrowseFolders = []
        scopeBrowseError = nil
        isLoadingScopeFolders = false
        scopeMode = .include
        scopeTouched = false
        excludeTouched = false
        scopePicks = []
        scopeExcludePicks = []
        let kind = flow == .aliyunCookie ? .aliyun : flow.kind
        // SMB 的目录路径属于具体共享，添加新连接时不继承其它共享的范围。
        guard kind != .smb else { return }
        guard let kind,
              let mount = store.cloudMounts.first(where: { $0.kind == kind }) else { return }
        scopePicks = mount.scopeRoots.map { CloudScopePick(root: $0, ancestors: []) }
        scopeExcludePicks = mount.excludedRoots.map { CloudScopePick(root: $0, ancestors: []) }
    }

    /// 进入「确认添加 / 编辑」时读取根目录，供勾选接入范围。
    func prepareAccessScopeStep() {
        if flow == .smb {
            normalizeSMBScopeAddress()
        }
        scopeBrowseTrail = []
        scopeBrowseFolders = []
        scopeBrowseError = nil
        loadAccessScopeFolders()
    }

    /// 百度范围浏览用的 access_token：新接入用向导里的临时令牌，编辑已有挂载走钥匙串并自动续期。
    private func baiduScopeAccessToken() async throws -> String {
        if let token = baiduToken?.accessToken { return token }
        guard let id = editingMountID,
              let mount = store.cloudMounts.first(where: { $0.id == id }) else {
            throw CloudOAuthError.notAuthorized
        }
        return try await CloudService.accessToken(for: mount)
    }

    /// SMB 地址若已指到某个子目录，把它转成一个「接入目录」，共享根仍作为挂载地址。
    private func normalizeSMBScopeAddress() {
        guard let pieces = SMBClient.pieces(smbAddress), !pieces.share.isEmpty else { return }
        guard !pieces.subPath.isEmpty else { return }
        let path = pieces.subPath
        let name = (path as NSString).lastPathComponent
        if !scopePicks.contains(where: { $0.root.path == path }) {
            scopePicks.append(CloudScopePick(root: CloudScopeRoot(path: path, name: name),
                                             ancestors: []))
        }
        scopeTouched = true
        smbAddress = "smb://\(pieces.host)/\(pieces.share)"
    }

    private func loadAccessScopeFolders() {
        guard let flow else { return }
        let container = scopeBrowseTrail.last?.path ?? ""
        scopeBrowseToken += 1
        let token = scopeBrowseToken
        isLoadingScopeFolders = true
        scopeBrowseError = nil

        if flow == .smb {
            guard let pieces = SMBClient.pieces(smbAddress), !pieces.share.isEmpty else {
                isLoadingScopeFolders = false
                scopeBrowseError = "请先在上一步选择共享文件夹"
                return
            }
            guard let client = SMBClient(address: "smb://\(pieces.host)/\(pieces.share)",
                                         username: smbUsername,
                                         password: smbPassword) else {
                isLoadingScopeFolders = false
                scopeBrowseError = "SMB 地址格式不正确"
                return
            }
            Task {
                do {
                    let entries = try await client.list(path: container)
                    guard token == scopeBrowseToken else { return }
                    isLoadingScopeFolders = false
                    applyScopeFolders(entries)
                } catch {
                    guard token == scopeBrowseToken else { return }
                    isLoadingScopeFolders = false
                    scopeBrowseFolders = []
                    scopeBrowseError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
            return
        }

        if flow == .baidu {
            Task {
                do {
                    let accessToken = try await baiduScopeAccessToken()
                    let entries = try await CloudSetupBrowser.folders(flow: flow,
                                                                      cookie: accessToken,
                                                                      containerID: container)
                    guard token == scopeBrowseToken else { return }
                    isLoadingScopeFolders = false
                    applyScopeFolders(entries)
                } catch {
                    guard token == scopeBrowseToken else { return }
                    isLoadingScopeFolders = false
                    scopeBrowseFolders = []
                    scopeBrowseError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
            return
        }

        guard flow.usesCookie else {
            isLoadingScopeFolders = false
            return
        }
        let cookie = cookieText
        Task {
            do {
                let entries = try await CloudSetupBrowser.folders(flow: flow,
                                                                  cookie: cookie,
                                                                  containerID: container)
                guard token == scopeBrowseToken else { return }
                isLoadingScopeFolders = false
                applyScopeFolders(entries)
            } catch {
                guard token == scopeBrowseToken else { return }
                isLoadingScopeFolders = false
                scopeBrowseFolders = []
                scopeBrowseError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func applyScopeFolders(_ entries: [CloudEntry]) {
        scopeBrowseFolders = entries
            .filter { $0.isDirectory && !CloudScanner.shouldSkipFolder($0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func enterScopeFolder(_ entry: CloudEntry) {
        scopeBrowseTrail.append(CloudScopeRoot(path: entry.path, name: entry.name))
        scopeBrowseFolders = []
        loadAccessScopeFolders()
    }

    private func scopeBrowseUp() {
        guard !scopeBrowseTrail.isEmpty else { return }
        scopeBrowseTrail.removeLast()
        scopeBrowseFolders = []
        loadAccessScopeFolders()
    }

    /// 勾选时保持最小集合：新选的目录会顶掉它的祖先与后代选择；同一目录不能同时接入与排除。
    private func toggleScope(_ entry: CloudEntry) {
        let ancestors = scopeBrowseTrail.map(\.path)
        if scopeMode == .include {
            scopeTouched = true
            // 排除列表里与本次勾选冲突的祖先目录会被顶掉；子目录排除保留。
            scopeExcludePicks.removeAll { pick in
                pick.root.path == entry.path || ancestors.contains(pick.root.path)
            }
            if scopePicks.contains(where: { $0.root.path == entry.path }) {
                scopePicks.removeAll { $0.root.path == entry.path }
                return
            }
            scopePicks.removeAll { pick in
                ancestors.contains(pick.root.path) || pick.ancestors.contains(entry.path)
            }
            scopePicks.append(CloudScopePick(root: CloudScopeRoot(path: entry.path, name: entry.name),
                                             ancestors: ancestors))
        } else {
            excludeTouched = true
            // 排除目录会顶掉它自己或它子树里的接入目录；上层接入目录保留。
            scopePicks.removeAll { pick in
                pick.root.path == entry.path || pick.ancestors.contains(entry.path)
            }
            if scopeExcludePicks.contains(where: { $0.root.path == entry.path }) {
                scopeExcludePicks.removeAll { $0.root.path == entry.path }
                return
            }
            scopeExcludePicks.removeAll { pick in
                ancestors.contains(pick.root.path) || pick.ancestors.contains(entry.path)
            }
            scopeExcludePicks.append(CloudScopePick(root: CloudScopeRoot(path: entry.path,
                                                                        name: entry.name),
                                                    ancestors: ancestors))
        }
    }

    /// 用户没动过选择时返回 nil：保留已有挂载的范围；新挂载则用整盘 / 不排除。
    var resolvedScopes: [CloudScopeRoot]? {
        scopeTouched ? scopePicks.map(\.root) : nil
    }

    var resolvedExcludes: [CloudScopeRoot]? {
        excludeTouched ? scopeExcludePicks.map(\.root) : nil
    }

    /// 从侧边栏「编辑接入范围」进入：直接停在确认页，凭据从钥匙串带入。
    func openForEditing(_ mount: CloudMount) {
        guard mount.kind.supportsAccessScope else { return }
        select(mount.kind.wizardFlow)
        editingMountID = mount.id
        mountName = mount.name
        scopePicks = mount.scopeRoots.map { CloudScopePick(root: $0, ancestors: []) }
        scopeExcludePicks = mount.excludedRoots.map { CloudScopePick(root: $0, ancestors: []) }

        switch mount.kind {
        case .smb:
            smbAddress = mount.baseURL
            smbUsername = mount.username
            smbPassword = store.cloudPassword(for: mount.id)
            smbVerified = !smbPassword.isEmpty
            if smbPassword.isEmpty {
                status = "钥匙串里没有保存的 SMB 密码，请补填后重新进入"
                statusIsError = false
            } else {
                step = 1
                prepareAccessScopeStep()
            }
        case .quark, .pan115:
            cookieText = store.cloudPassword(for: mount.id)
            cookieVerified = !cookieText.isEmpty
            if cookieText.isEmpty {
                status = "钥匙串里没有保存的 Cookie，请重新粘贴"
                statusIsError = false
            } else {
                step = 1
                prepareAccessScopeStep()
            }
        case .aliyun:
            let stored = store.cloudPassword(for: mount.id)
            cookieText = stored.isEmpty
                ? (CloudOAuthStore.token(mountID: mount.id)?.refreshToken ?? "")
                : stored
            cookieVerified = !cookieText.isEmpty
            if cookieText.isEmpty {
                status = "钥匙串里没有保存的登录凭据，请重新粘贴 refresh_token"
                statusIsError = false
            } else {
                step = 1
                prepareAccessScopeStep()
            }
        case .baidu:
            // 百度：直接用钥匙串里的令牌浏览目录，停在「接入范围」页。
            step = 2
            prepareAccessScopeStep()
        case .webdav:
            // WebDAV 的范围在填写连接页维护，保留流程选择页避免误改。
            break
        }
    }

    // MARK: 动作

    private var normalizedCookieCount: Int {
        let normalized = isPan115Cookie
            ? Pan115Drive.normalizedCookie(cookieText)
            : QuarkDrive.normalizedCookie(cookieText)
        return normalized.count
    }

    private func testCookie() {
        isBusy = true
        cookieVerified = false
        status = nil
        let text = cookieText
        let aliyun = isAliyunCookie
        let pan115 = isPan115Cookie
        Task {
            let result: (ok: Bool, message: String)
            if aliyun {
                result = await store.testAliyunCookie(text)
            } else if pan115 {
                result = await store.testPan115Cookie(text)
            } else {
                result = await store.testQuarkCookie(text)
            }
            isBusy = false
            status = result.message
            statusIsError = !result.ok
            cookieVerified = result.ok
        }
    }

    func addQuark() {
        if let error = store.registerQuarkMount(cookie: cookieText,
                                                name: mountName,
                                                scopes: resolvedScopes,
                                                excludes: resolvedExcludes) {
            status = error
            statusIsError = true
            return
        }
        close()
    }

    func addPan115() {
        if let error = store.registerPan115Mount(cookie: cookieText,
                                                 name: mountName,
                                                 scopes: resolvedScopes,
                                                 excludes: resolvedExcludes) {
            status = error
            statusIsError = true
            return
        }
        close()
    }

    func addAliyunCookie() {
        guard !isBusy else { return }
        isBusy = true
        status = "正在验证并保存…"
        statusIsError = false
        let text = cookieText
        Task {
            let error = await store.registerAliyunCookieMount(input: text,
                                                              name: mountName,
                                                              scopes: resolvedScopes,
                                                              excludes: resolvedExcludes)
            isBusy = false
            if let error {
                status = error
                statusIsError = true
            } else {
                close()
            }
        }
    }
}
