import SwiftUI
import AppKit

// MARK: - WebDAV 流程

extension CloudSetupWizardView {
    @ViewBuilder
    var webdavContent: some View {
        if step == 0 {
            VStack(alignment: .leading, spacing: 14) {
                Text("填写 WebDAV 连接")
                    .font(.system(size: 13, weight: .semibold))
                Text("群晖：套件中心安装 WebDAV Server，地址填 http://NAS地址:5005/photo（HTTPS 为 5006）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                credentialCandidateSection(webdavCandidates, noun: "WebDAV") { candidate in
                    applyWebDAVCandidate(candidate)
                }

                labeledField("地址", text: $address, prompt: "http://192.168.1.10:5005/photo")
                labeledField("用户名", text: $username, prompt: "WebDAV 账号")
                labeledSecureField("密码", text: $password, prompt: "WebDAV 密码")

                if address.lowercased().hasPrefix("https://") {
                    Toggle("信任自签名证书（NAS 自建 HTTPS 常用）", isOn: $trustSelfSigned)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                }

                HStack(spacing: 8) {
                    Button(isBusy ? "测试中…" : "测试连接") {
                        testWebDAV()
                    }
                    .disabled(isBusy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    if networkVerified {
                        Label("已连通", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("确认并添加")
                    .font(.system(size: 13, weight: .semibold))
                labeledField("名称", text: $mountName, prompt: URL(string: address)?.host ?? "WebDAV")
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("接入方式", "WebDAV")
                    infoRow("地址", address)
                    if !webdavSubPath.isEmpty {
                        infoRow("接入目录", webdavSubPath)
                    }
                    infoRow("账号", username)
                }
                webdavScopeSection
                Text("密码保存在 macOS 钥匙串。WebDAV 支持上传、重命名、新建文件夹与删除。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 接入范围（全部 / 筛选子目录）

    private var webdavScopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("接入范围")
                .font(.system(size: 11.5, weight: .medium))
            Picker("接入范围", selection: $webdavFiltersFolders) {
                Text("当前全部").tag(false)
                Text("筛选子目录").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: webdavFiltersFolders) { _, filtering in
                if filtering {
                    if webdavBrowseFolders.isEmpty, webdavBrowseError == nil {
                        loadWebDAVFolders()
                    }
                } else {
                    // 切回「当前全部」时清掉子目录选择，避免地址仍指向上次的子目录。
                    webdavBrowseToken += 1
                    webdavSubPath = ""
                    webdavBrowseFolders = []
                    webdavBrowseError = nil
                    isLoadingWebDAVFolders = false
                }
            }

            if webdavFiltersFolders {
                webdavBrowser
            } else {
                Text("接入当前地址下的全部文件夹与照片。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var webdavBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    webdavBrowseUp()
                } label: {
                    Label(webdavSubPath.isEmpty ? "根目录" : "上一级", systemImage: "chevron.left")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(webdavSubPath.isEmpty || isLoadingWebDAVFolders)
                .help(webdavSubPath.isEmpty ? "当前就是地址根目录" : "返回上一级目录")

                Text(webdavScopeTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isLoadingWebDAVFolders {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                Button("重新读取") {
                    loadWebDAVFolders()
                }
                .controlSize(.small)
                .disabled(isLoadingWebDAVFolders)
                .help("重新读取当前目录的子文件夹")
            }
            Text("点击文件夹进入下一层，当前所在目录即为接入范围。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            webdavBrowseContent
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    @ViewBuilder
    private var webdavBrowseContent: some View {
        if let error = webdavBrowseError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(error)
                    .font(.system(size: 10.5))
                    .lineLimit(2)
            }
            .foregroundStyle(.secondary)
        } else if isLoadingWebDAVFolders && webdavBrowseFolders.isEmpty {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在读取目录…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else if webdavBrowseFolders.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("这个目录下没有子文件夹，可直接添加当前目录。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                ForEach(webdavBrowseFolders, id: \.self) { folder in
                    webdavFolderChip(folder)
                }
            }
        }
    }

    private func webdavFolderChip(_ name: String) -> some View {
        Button {
            enterWebDAVFolder(name)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                Text(name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
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
        .help("进入「\(name)」并以该目录接入")
    }

    /// 当前浏览到地址根目录以下第几层（仅用于展示）。
    private var webdavScopeTitle: String {
        guard !webdavSubPath.isEmpty else { return "根目录" }
        return webdavSubPath.replacingOccurrences(of: "/", with: " › ")
    }

    /// 实际接入地址：测试通过的根地址 + 选中的子目录层级。
    private var webdavEffectiveAddress: String {
        guard webdavFiltersFolders, !webdavSubPath.isEmpty,
              let base = WebDAVClient.normalizedBaseURL(address) else { return address }
        let escaped = webdavSubPath
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        var text = base.absoluteString
        if !text.hasSuffix("/") { text += "/" }
        return text + escaped
    }

    // MARK: 动作

    private var webdavCandidates: [CloudCredentialCandidate] {
        credentialCandidates.filter { $0.mount.kind == .webdav }
    }

    /// 选中钥匙串候选：带入地址、账号与密码后直接测试连接。
    private func applyWebDAVCandidate(_ candidate: CloudCredentialCandidate) {
        address = candidate.mount.baseURL
        username = candidate.mount.username
        trustSelfSigned = candidate.mount.trustSelfSigned
        password = candidate.hasPassword ? store.cloudPassword(for: candidate.mount.id) : ""
        resetWebDAVBrowse()
        if candidate.hasPassword {
            testWebDAV()
        } else {
            networkVerified = false
            status = "已带入「\(candidate.mount.name)」的地址与账号，钥匙串里没有密码，请补填后再测试。"
            statusIsError = false
        }
    }

    /// 重新测试连接时回到「当前全部」，避免上一次选中的子目录继续生效。
    func resetWebDAVBrowse() {
        webdavBrowseToken += 1
        webdavSubPath = ""
        webdavBrowseFolders = []
        webdavBrowseError = nil
        isLoadingWebDAVFolders = false
        webdavFiltersFolders = false
    }

    private func testWebDAV() {
        resetWebDAVBrowse()
        isBusy = true
        networkVerified = false
        status = nil
        let target = address
        let account = username
        let secret = password
        let trust = trustSelfSigned
        Task {
            let result = await store.testCloudConnection(address: target,
                                                         username: account,
                                                         password: secret,
                                                         trustSelfSigned: trust)
            isBusy = false
            status = result.message
            statusIsError = !result.ok
            networkVerified = result.ok
        }
    }

    /// 读取当前子目录下的文件夹（根地址已在「测试连接」时验证过）。
    private func loadWebDAVFolders() {
        guard let client = WebDAVClient(baseURLString: address,
                                        username: username,
                                        password: password,
                                        allowsSelfSignedCertificate: trustSelfSigned) else {
            webdavBrowseError = "地址格式不正确，请填写 http(s)://主机:端口/路径"
            return
        }
        webdavBrowseToken += 1
        let token = webdavBrowseToken
        let path = webdavSubPath
        isLoadingWebDAVFolders = true
        webdavBrowseError = nil
        Task {
            do {
                let entries = try await client.list(path: path)
                guard token == webdavBrowseToken else { return }
                webdavBrowseFolders = entries
                    .filter(\.isDirectory)
                    .map(\.name)
                    .filter { !$0.hasPrefix(".") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                isLoadingWebDAVFolders = false
            } catch {
                guard token == webdavBrowseToken else { return }
                isLoadingWebDAVFolders = false
                webdavBrowseFolders = []
                webdavBrowseError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func enterWebDAVFolder(_ name: String) {
        webdavSubPath = webdavSubPath.isEmpty ? name : webdavSubPath + "/" + name
        webdavBrowseFolders = []
        loadWebDAVFolders()
    }

    private func webdavBrowseUp() {
        var parts = webdavSubPath.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        parts.removeLast()
        webdavSubPath = parts.joined(separator: "/")
        webdavBrowseFolders = []
        loadWebDAVFolders()
    }

    func addWebDAV() {
        isBusy = true
        let target = webdavEffectiveAddress
        let error = store.saveCloudMount(existing: nil,
                                         name: mountName,
                                         address: target,
                                         username: username,
                                         password: password,
                                         trustSelfSigned: trustSelfSigned)
        isBusy = false
        if let error {
            status = error
            statusIsError = true
            return
        }
        close()
    }
}
