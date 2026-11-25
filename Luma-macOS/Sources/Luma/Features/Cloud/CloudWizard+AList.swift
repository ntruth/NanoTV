import SwiftUI
import AppKit

// MARK: - AList 流程

extension CloudSetupWizardView {
    @ViewBuilder
    var alistContent: some View {
        switch step {
        case 0:
            alistProviderStep
        case 1:
            alistConnectStep
        case 2:
            alistProviderGuideStep
        default:
            alistConfirmStep
        }
    }

    private var alistProviderStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择要接入的网盘")
                .font(.system(size: 13, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(AlistProvider.allCases) { item in
                    Button {
                        alistProvider = item
                    } label: {
                        HStack(spacing: 10) {
                            CloudBrandIcon(brand: item.brand, size: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                Text(item.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if alistProvider == item {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(12)
                        .frame(height: 64)
                        .background {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(alistProvider == item
                                      ? Color.accentColor.opacity(0.12)
                                      : Color.primary.opacity(0.05))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var alistConnectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接 AList")
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                bullet("1", "安装 AList 或 OpenList（Docker / 群晖套件 / 桌面版任一）")
                Text("docker run -d --restart=always -v /etc/alist:/opt/alist/data -p 5244:5244 --name=alist xhofe/alist:latest")
                    .font(.system(size: 9.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                bullet("2", "首次启动后执行 docker logs alist 查看 admin 初始密码")
            }
            HStack(spacing: 8) {
                Button("打开 AList 官网") { open("https://alistgo.com/") }
                Button("打开本机后台") { open(alistAddress) }
                Spacer()
            }
            .controlSize(.small)

            Divider()
            labeledField("地址", text: $alistAddress, prompt: "http://127.0.0.1:5244")
            labeledField("用户名", text: $alistUser, prompt: "admin")
            labeledSecureField("密码", text: $alistPassword, prompt: "AList 管理员密码")

            HStack(spacing: 8) {
                Button(isBusy ? "测试中…" : "测试 AList 连接") {
                    testAList()
                }
                .disabled(isBusy || alistAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                if alistVerified {
                    Label("已连通", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
                Spacer()
            }
        }
    }

    private var alistProviderGuideStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                CloudBrandIcon(brand: alistProvider.brand, size: 18)
                Text("在 AList 中添加\(alistProvider.title)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(alistProvider.steps.enumerated()), id: \.offset) { index, text in
                    bullet("\(index + 1)", text)
                }
            }
            HStack(spacing: 8) {
                Button("打开 AList 后台") { open(alistAddress) }
                Button("查看接入文档") { open(alistProvider.docsURL) }
                if let extra = alistProvider.extraLink {
                    Button(extra.title) { open(extra.url) }
                }
                Spacer()
            }
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(alistProvider.notes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)
                        Text(note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Toggle(isOn: $addedInAlist) {
                Text("我已在 AList 中完成该网盘的添加与授权")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
        }
    }

    private var alistConfirmStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认并添加")
                .font(.system(size: 13, weight: .semibold))
            labeledField("名称", text: $mountName, prompt: "\(alistProvider.title)（AList）")
            VStack(alignment: .leading, spacing: 6) {
                infoRow("网盘类型", "\(alistProvider.title)（AList）")
                infoRow("AList 地址", alistAddress)
                infoRow("WebDAV 地址", AListProbe.webdavAddress(alistAddress) ?? "—")
                infoRow("账号", alistUser)
            }
            Text("将使用上方账号连接 AList 的 /dav；AList 中该账号的权限决定这里可读还是可写。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 动作

    private func testAList() {
        isBusy = true
        alistVerified = false
        status = nil
        let target = alistAddress
        Task {
            let result = await store.probeAList(address: target)
            isBusy = false
            status = result.message
            statusIsError = !result.ok
            alistVerified = result.ok
        }
    }

    func addAList() {
        guard let dav = AListProbe.webdavAddress(alistAddress) else {
            status = "地址格式不正确，例如 http://127.0.0.1:5244"
            statusIsError = true
            return
        }
        isBusy = true
        let trimmedName = mountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "\(alistProvider.title)（AList）" : trimmedName
        let account = alistUser
        let secret = alistPassword
        Task {
            let result = await store.testCloudConnection(address: dav,
                                                         username: account,
                                                         password: secret)
            guard result.ok else {
                isBusy = false
                status = result.message
                statusIsError = true
                return
            }
            if let error = store.saveCloudMount(existing: nil,
                                                name: name,
                                                address: dav,
                                                username: account,
                                                password: secret) {
                isBusy = false
                status = error
                statusIsError = true
                return
            }
            isBusy = false
            close()
        }
    }
}
