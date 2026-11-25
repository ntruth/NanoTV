import SwiftUI
import AppKit

// MARK: - SMB 流程

extension CloudSetupWizardView {
    @ViewBuilder
    var smbContent: some View {
        if step == 0 {
            VStack(alignment: .leading, spacing: 14) {
                Text("填写 SMB 连接")
                    .font(.system(size: 13, weight: .semibold))
                Text("群晖：控制面板 → 文件服务 → 启用 SMB。选设备后填入账号密码，可自动列出共享文件夹。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                credentialCandidateSection(smbCandidates, noun: "SMB") { candidate in
                    applySMBCandidate(candidate)
                }

                discoverySection

                labeledField("地址", text: $smbAddress, prompt: "smb://192.168.1.10/photo")
                Text("也可以直接填写 smb://主机/共享名；下方的「发现共享」会读取服务器上的共享列表。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                labeledField("用户名", text: $smbUsername, prompt: "SMB 账号")
                labeledSecureField("密码", text: $smbPassword, prompt: "SMB 密码") {
                    discoverShares()
                }

                if let reused = reusedSMBMountName {
                    Label("已复用「\(reused)」的账号与密码（来自钥匙串），可直接发现共享",
                          systemImage: "key.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button(isDiscoveringShares ? "发现中…" : "发现共享") {
                        discoverShares()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDiscoveringShares || isBusy
                              || smbAddress.trimmingCharacters(in: .whitespaces).isEmpty
                              || smbUsername.trimmingCharacters(in: .whitespaces).isEmpty
                              || smbPassword.isEmpty)
                    .help("使用当前用户名和密码列出服务器上的共享文件夹")

                    Button(isBusy ? "测试中…" : "测试连接") {
                        testSMB()
                    }
                    .disabled(isBusy || smbAddress.trimmingCharacters(in: .whitespaces).isEmpty)

                    if smbVerified {
                        Label("已连通", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }

                if !availableShares.isEmpty || isDiscoveringShares {
                    shareSection
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("确认并添加")
                    .font(.system(size: 13, weight: .semibold))
                labeledField("名称", text: $mountName,
                             prompt: SMBClient.displayName(smbAddress) ?? "SMB 共享")
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("接入方式", "SMB 共享")
                    infoRow("地址", smbAddress)
                    infoRow("账号", smbUsername)
                    infoRow("浏览范围", accessScopeSummary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

                accessScopeSection

                Text("密码保存在 macOS 钥匙串。SMB 挂载为只读：可以浏览与播放，不支持上传、重命名、新建文件夹与删除。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("局域网设备")
                    .font(.system(size: 11.5, weight: .medium))
                if isDiscoveringSMB {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Button("重新发现") {
                    startSMBDiscovery()
                }
                .controlSize(.small)
                .disabled(isDiscoveringSMB)
            }
            if discoveredServers.isEmpty {
                Text(isDiscoveringSMB ? "正在发现开启 SMB 的设备…" : "未发现设备，可直接手动填写地址。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(discoveredServers, id: \.self) { server in
                        serverChip(server)
                    }
                }
            }
        }
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let browseShare = smbBrowseShare {
                browseHeader(browseShare)
                browseContent
            } else {
                sharesHeader
                sharesContent
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private var sharesHeader: some View {
        HStack(spacing: 6) {
            Text("共享文件夹")
                .font(.system(size: 11.5, weight: .medium))
            if !availableShares.isEmpty {
                Text("已找到 \(availableShares.count) 个")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if isDiscoveringShares {
                ProgressView()
                    .controlSize(.mini)
            }
            Spacer()
            Button("重新发现") {
                discoverShares()
            }
            .controlSize(.small)
            .disabled(isDiscoveringShares || isBusy
                      || smbUsername.trimmingCharacters(in: .whitespaces).isEmpty
                      || smbPassword.isEmpty)
            .help("使用当前账号重新读取共享文件夹")
        }
    }

    @ViewBuilder
    private var sharesContent: some View {
        if availableShares.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(isDiscoveringShares ? "正在读取共享列表…" : "没有可选共享，也可以直接手填 smb://主机/共享名")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                ForEach(availableShares, id: \.self) { share in
                    shareChip(share)
                }
            }
            Text("单击选中共享，双击进入共享后选择具体子目录。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func browseHeader(_ share: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    browseUp()
                } label: {
                    Label(smbBrowsePath.isEmpty ? "共享列表" : "上一级", systemImage: "chevron.left")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(smbBrowsePath.isEmpty ? "返回共享列表" : "返回上一级目录")

                Text(breadcrumb(share))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isLoadingBrowseFolders {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Button("重新读取") {
                    loadBrowseFolders()
                }
                .controlSize(.small)
                .disabled(isLoadingBrowseFolders)
                .help("重新读取当前目录的子文件夹")
            }
            Text("双击文件夹进入下一层，单击选中当前目录。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var browseContent: some View {
        if let error = browseFoldersError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(error)
                    .font(.system(size: 10.5))
                    .lineLimit(2)
            }
            .foregroundStyle(.secondary)
        } else if isLoadingBrowseFolders && smbBrowseFolders.isEmpty {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在读取目录…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else if smbBrowseFolders.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("这个目录下没有子文件夹，可直接使用当前目录。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                ForEach(smbBrowseFolders, id: \.self) { folder in
                    folderChip(folder)
                }
            }
        }
    }

    private func serverChip(_ server: String) -> some View {
        let selected = currentSMBServer?.caseInsensitiveCompare(server) == .orderedSame
        return Button {
            smbAddress = "smb://\(server)/"
            smbVerified = false
            availableShares = []
            resetBrowseState()
            prefillSMBAccount(for: server)
            if !smbUsername.trimmingCharacters(in: .whitespaces).isEmpty, !smbPassword.isEmpty {
                discoverShares(host: server)
            } else {
                status = "已选择 \(server)，请填写账号密码后点「发现共享」"
                statusIsError = false
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "network")
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(server)
                    .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.clear,
                                  lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("使用 \(server) 作为服务器地址")
    }

    private func shareChip(_ share: String) -> some View {
        let selected = currentSMBShare == share
        return HStack(spacing: 7) {
            Image(systemName: selected ? "folder.fill" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text(share)
                .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear,
                              lineWidth: 1)
        }
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded { enterShare(share) }
                .exclusively(before: TapGesture().onEnded { applySMBShare(share) })
        )
        .help("单击选择共享「\(share)」，双击进入选择子目录")
    }

    private func folderChip(_ name: String) -> some View {
        let selected = currentSMBSubPath == folderPath(name)
        return HStack(spacing: 7) {
            Image(systemName: selected ? "folder.fill" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text(name)
                .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear,
                              lineWidth: 1)
        }
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded { browse(to: folderPath(name)) }
                .exclusively(before: TapGesture().onEnded { selectFolder(name) })
        )
        .help("单击选择「\(name)」，双击进入下一层")
    }

    // MARK: 动作

    private var smbCandidates: [CloudCredentialCandidate] {
        credentialCandidates.filter { $0.mount.kind == .smb }
    }

    /// 选中钥匙串候选：带入地址、账号与密码后直接发现共享。
    private func applySMBCandidate(_ candidate: CloudCredentialCandidate) {
        smbAddress = candidate.mount.baseURL
        smbUsername = candidate.mount.username
        smbPassword = candidate.hasPassword ? store.cloudPassword(for: candidate.mount.id) : ""
        reusedSMBMountName = candidate.mount.name
        smbVerified = false
        availableShares = []
        resetBrowseState()
        guard candidate.hasPassword else {
            status = "已带入「\(candidate.mount.name)」的地址与账号，钥匙串里没有密码，请补填后点「发现共享」。"
            statusIsError = false
            return
        }
        discoverShares(host: SMBClient.pieces(candidate.mount.baseURL)?.host)
    }

    /// 复用已保存的 SMB 连接：同一主机直接沿用账号与钥匙串里的密码，免得二次输入。
    ///
    /// - Parameter host: 目标主机；为空时按当前地址推断，只有唯一一条 SMB 连接时直接用它。
    func prefillSMBAccount(for host: String? = nil) {
        let mounts = store.cloudMounts.filter { $0.kind == .smb }
        guard !mounts.isEmpty else {
            reusedSMBMountName = nil
            return
        }
        let targetHost = host ?? SMBClient.pieces(smbAddress)?.host
        let matched: CloudMount?
        if let targetHost, !targetHost.isEmpty {
            matched = mounts.first {
                SMBClient.pieces($0.baseURL)?.host.caseInsensitiveCompare(targetHost) == .orderedSame
            }
        } else {
            matched = mounts.count == 1 ? mounts[0] : nil
        }
        guard let matched else { return }

        var reused = false
        if smbUsername.trimmingCharacters(in: .whitespaces).isEmpty, !matched.username.isEmpty {
            smbUsername = matched.username
            reused = true
        }
        if smbPassword.isEmpty {
            let password = store.cloudPassword(for: matched.id)
            if !password.isEmpty {
                smbPassword = password
                reused = true
            }
        }
        // 地址还空着时补上主机，用户只需挑共享。
        if smbAddress.trimmingCharacters(in: .whitespaces).isEmpty,
           let pieces = SMBClient.pieces(matched.baseURL) {
            smbAddress = "smb://\(pieces.host)/"
        }
        if reused {
            reusedSMBMountName = matched.name
        }
    }

    private var currentSMBServer: String? {
        SMBClient.pieces(smbAddress)?.host
    }

    private var currentSMBShare: String? {
        guard let pieces = SMBClient.pieces(smbAddress), !pieces.share.isEmpty else { return nil }
        return pieces.share
    }

    /// 当前地址里的共享内子路径（不含共享名）。
    private var currentSMBSubPath: String? {
        SMBClient.pieces(smbAddress)?.subPath
    }

    private func smbAddressString(host: String, share: String, path: String) -> String {
        var text = "smb://\(host)/\(share)"
        if !path.isEmpty { text += "/" + path }
        return text
    }

    private func folderPath(_ name: String) -> String {
        smbBrowsePath.isEmpty ? name : smbBrowsePath + "/" + name
    }

    private func breadcrumb(_ share: String) -> String {
        guard !smbBrowsePath.isEmpty else { return share }
        return share + " › " + smbBrowsePath.replacingOccurrences(of: "/", with: " › ")
    }

    /// 双击共享：进入该共享的根目录并列出子文件夹。
    private func enterShare(_ share: String, host explicitHost: String? = nil) {
        guard let host = explicitHost ?? currentSMBServer else { return }
        smbBrowseHost = host
        smbBrowseShare = share
        browse(to: "")
    }

    /// 切换到共享内的某个相对路径：更新地址并重新读取子文件夹。
    private func browse(to path: String) {
        guard let host = smbBrowseHost, let share = smbBrowseShare else { return }
        smbBrowsePath = path
        smbBrowseFolders = []
        browseFoldersError = nil
        smbAddress = smbAddressString(host: host, share: share, path: path)
        smbVerified = false
        status = "正在读取 \(path.isEmpty ? share : path)…"
        statusIsError = false
        loadBrowseFolders()
    }

    /// 读取当前目录的子文件夹；同时把该目录视为可用连接。
    private func loadBrowseFolders() {
        guard let host = smbBrowseHost, let share = smbBrowseShare else { return }
        let path = smbBrowsePath
        browseToken += 1
        let token = browseToken
        guard let client = SMBClient(address: smbAddressString(host: host, share: share, path: path),
                                     username: smbUsername,
                                     password: smbPassword) else {
            browseFoldersError = "地址格式不正确，例如 smb://主机/共享名"
            return
        }
        isLoadingBrowseFolders = true
        browseFoldersError = nil
        Task {
            do {
                let entries = try await client.list(path: "")
                guard token == browseToken else { return }
                smbBrowseFolders = entries
                    .filter(\.isDirectory)
                    .map(\.name)
                    .filter { !$0.hasPrefix(".") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                isLoadingBrowseFolders = false
                smbVerified = true
                status = path.isEmpty ? "已进入共享「\(share)」" : "已进入「\(path)」"
                statusIsError = false
            } catch {
                guard token == browseToken else { return }
                isLoadingBrowseFolders = false
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                browseFoldersError = message
                status = message
                statusIsError = true
            }
        }
    }

    /// 单击子文件夹：把地址指向该目录并验证连接。
    private func selectFolder(_ name: String) {
        guard let host = smbBrowseHost, let share = smbBrowseShare else { return }
        let path = folderPath(name)
        smbAddress = smbAddressString(host: host, share: share, path: path)
        smbVerified = false
        status = "已选择「\(name)」，正在验证连接…"
        statusIsError = false
        testSMB(smbAddress)
    }

    private func browseUp() {
        if smbBrowsePath.isEmpty {
            exitBrowse()
            return
        }
        var parts = smbBrowsePath.split(separator: "/").map(String.init)
        parts.removeLast()
        browse(to: parts.joined(separator: "/"))
    }

    private func exitBrowse() {
        resetBrowseState()
        if let host = currentSMBServer {
            smbAddress = "smb://\(host)/"
        }
        smbVerified = false
        status = "请选择共享文件夹，或双击共享进入子目录"
        statusIsError = false
    }

    /// 清空目录浏览状态（不改变地址与提示文案）。
    private func resetBrowseState() {
        browseToken += 1
        smbBrowseHost = nil
        smbBrowseShare = nil
        smbBrowsePath = ""
        smbBrowseFolders = []
        browseFoldersError = nil
        isLoadingBrowseFolders = false
    }

    func discoverShares(host explicitHost: String? = nil) {
        guard !isDiscoveringShares else { return }
        let host: String?
        if let explicitHost {
            host = explicitHost
        } else {
            host = SMBClient.pieces(smbAddress)?.host
        }
        guard let host, !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = "请先选择设备或填写服务器地址"
            statusIsError = true
            return
        }
        // 该主机之前连过就直接复用账号与钥匙串密码。
        prefillSMBAccount(for: host)
        guard !smbUsername.trimmingCharacters(in: .whitespaces).isEmpty, !smbPassword.isEmpty else {
            status = "发现共享需要先填写用户名和密码"
            statusIsError = true
            return
        }

        shareDiscoveryToken += 1
        let token = shareDiscoveryToken
        isDiscoveringShares = true
        availableShares = []
        resetBrowseState()
        smbVerified = false
        status = "正在使用当前账号发现共享…"
        statusIsError = false
        let account = smbUsername
        let secret = smbPassword

        Task {
            let result = await SMBShareDiscovery.list(host: host,
                                                      username: account,
                                                      password: secret)
            guard token == shareDiscoveryToken else { return }
            isDiscoveringShares = false
            availableShares = result.shares
            status = result.message
            statusIsError = !result.ok
            if result.ok, result.shares.count == 1, let only = result.shares.first {
                // 只有一个共享时直接进入，省去再双击一次。
                enterShare(only, host: host)
            }
        }
    }

    private func applySMBShare(_ share: String, host explicitHost: String? = nil) {
        guard let host = explicitHost ?? SMBClient.pieces(smbAddress)?.host else { return }
        // 地址框展示原始名称，编码只在真正挂载时处理。
        let address = "smb://\(host)/\(share)"
        smbAddress = address
        smbVerified = false
        status = "已选择共享「\(share)」，正在验证连接…"
        statusIsError = false
        testSMB(address)
    }

    func startSMBDiscovery() {
        smbDiscoveryTask?.cancel()
        discoveredServers = []
        availableShares = []
        isDiscoveringShares = false
        shareDiscoveryToken += 1
        resetBrowseState()
        isDiscoveringSMB = true
        smbDiscoveryTask = Task {
            let servers = await SMBDiscovery.browse()
            guard !Task.isCancelled else { return }
            discoveredServers = servers
            isDiscoveringSMB = false
        }
    }

    func cancelSMBDiscovery() {
        smbDiscoveryTask?.cancel()
        smbDiscoveryTask = nil
        isDiscoveringSMB = false
        availableShares = []
        isDiscoveringShares = false
        shareDiscoveryToken += 1
        resetBrowseState()
    }

    private func testSMB(_ addressOverride: String? = nil) {
        let target = addressOverride ?? smbAddress
        // NetFS 只能挂载到具体共享，只有主机时应先让用户选择共享文件夹。
        let share = SMBClient.pieces(target)?.share ?? ""
        if share.isEmpty {
            if smbUsername.trimmingCharacters(in: .whitespaces).isEmpty || smbPassword.isEmpty {
                status = "SMB 地址需要包含共享名，请填写用户名和密码后点「发现共享」"
                statusIsError = true
            } else {
                discoverShares()
            }
            return
        }
        isBusy = true
        smbVerified = false
        status = nil
        let account = smbUsername
        let secret = smbPassword
        Task {
            let result = await SMBClient.test(address: target,
                                              username: account,
                                              password: secret)
            isBusy = false
            status = result.message
            statusIsError = !result.ok
            smbVerified = result.ok
        }
    }

    func addSMB() {
        isBusy = true
        let existing = editingMountID.flatMap { id in
            store.cloudMounts.first { $0.id == id }
        }
        let error = store.saveCloudMount(existing: existing,
                                         name: mountName,
                                         address: smbAddress,
                                         username: smbUsername,
                                         password: smbPassword,
                                         kind: .smb,
                                         scopes: resolvedScopes,
                                         excludes: resolvedExcludes)
        isBusy = false
        if let error {
            status = error
            statusIsError = true
            return
        }
        close()
    }
}
