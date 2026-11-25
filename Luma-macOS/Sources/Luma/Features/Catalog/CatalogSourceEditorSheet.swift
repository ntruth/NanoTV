import SwiftUI

/// 编辑一条网络资源：名称、站点地址、抓取参数与证书放行。
/// 只改本地配置，不会向站点提交任何东西；分类骨架与已缓存内容不受影响。
struct CatalogSourceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let source: CatalogSource
    let onSave: (CatalogSource) -> Void

    @State private var name: String
    @State private var baseURL: String
    @State private var apiBase: String
    @State private var configURL: String
    @State private var userAgent: String
    @State private var referer: String
    @State private var artworkKey: String
    @State private var artworkIV: String
    @State private var trustsInsecureCertificate: Bool
    @State private var isEnabled: Bool

    init(source: CatalogSource, onSave: @escaping (CatalogSource) -> Void) {
        self.source = source
        self.onSave = onSave
        _name = State(initialValue: source.name)
        _baseURL = State(initialValue: source.baseURL)
        _apiBase = State(initialValue: source.apiBase ?? "")
        _configURL = State(initialValue: source.configURL ?? "")
        _userAgent = State(initialValue: source.userAgent)
        _referer = State(initialValue: source.referer)
        _artworkKey = State(initialValue: source.artworkKey ?? "")
        _artworkIV = State(initialValue: source.artworkIV ?? "")
        _trustsInsecureCertificate = State(initialValue: source.trustsInsecureCertificate)
        _isEnabled = State(initialValue: source.isEnabled)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只接受 http / https 且带主机名的地址：写错协议会让整个源静默失效。
    private var baseURLIsValid: Bool {
        guard let url = URL(string: trimmedBaseURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && baseURLIsValid
    }

    private var showsAPIBase: Bool {
        source.kind == .maccms || !(source.apiBase ?? "").isEmpty
    }

    private var showsConfigURL: Bool {
        source.configURL != nil
    }

    private var showsArtworkKey: Bool {
        source.artworkKey != nil || source.artworkIV != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("名称", text: $name, placeholder: source.kind.title)
                    VStack(alignment: .leading, spacing: 5) {
                        field("站点地址", text: $baseURL, placeholder: "https://example.com")
                        if !trimmedBaseURL.isEmpty, !baseURLIsValid {
                            Text("地址需要以 http:// 或 https:// 开头，并包含主机名。")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                    }
                    if showsAPIBase {
                        field("接口地址", text: $apiBase, placeholder: "https://example.com/api.php/provide/vod/")
                    }
                    if showsConfigURL {
                        field("配置地址", text: $configURL, placeholder: "导入时使用的配置地址")
                    }
                    field("User-Agent", text: $userAgent, placeholder: "Mozilla/5.0 …")
                    field("Referer", text: $referer, placeholder: "https://example.com")
                    if showsArtworkKey {
                        HStack(alignment: .top, spacing: 12) {
                            field("封面 Key", text: $artworkKey, placeholder: "可选")
                            field("封面 IV", text: $artworkIV, placeholder: "可选")
                        }
                    }
                    Toggle(isOn: $isEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用该资源")
                                .font(.system(size: 12, weight: .medium))
                            Text("停用后不再出现在侧边栏与聚合搜索里，配置与缓存都保留。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Toggle(isOn: $trustsInsecureCertificate) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允许不受信任的证书")
                                .font(.system(size: 12, weight: .medium))
                            Text("仅在该站点证书确实无效、但你确认站点可信时开启；只影响这一条资源。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("编辑网络资源")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(source.kind.title) · \(source.host)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
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

    private var footer: some View {
        HStack(spacing: 10) {
            Text("保存后立即按新配置重新读取。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func field(_ title: String,
                       text: Binding<String>,
                       placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private func save() {
        guard canSave else { return }
        var updated = source
        updated.name = trimmedName
        updated.baseURL = trimmedBaseURL
        if showsAPIBase {
            let value = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.apiBase = value.isEmpty ? nil : value
        }
        if showsConfigURL {
            let value = configURL.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.configURL = value.isEmpty ? nil : value
        }
        updated.userAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.referer = referer.trimmingCharacters(in: .whitespacesAndNewlines)
        if showsArtworkKey {
            let key = artworkKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let iv = artworkIV.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.artworkKey = key.isEmpty ? nil : key
            updated.artworkIV = iv.isEmpty ? nil : iv
        }
        updated.allowsInsecureTLS = trustsInsecureCertificate
        updated.isEnabled = isEnabled
        onSave(updated)
        dismiss()
    }
}
