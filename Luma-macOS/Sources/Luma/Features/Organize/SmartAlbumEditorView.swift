import SwiftUI

/// 智能相簿编辑器：条件可自由组合，实时显示匹配数量。
struct SmartAlbumEditorView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SmartAlbum
    @State private var matchCount = 0

    init(album: SmartAlbum) {
        _draft = State(initialValue: album)
    }

    private var rulesSignature: String {
        "\(draft.matchAll)|" + draft.rules.map { "\($0.field.rawValue)=\($0.value)" }.joined(separator: ",")
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.rules.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                Text(draft.name.isEmpty ? "智能相簿" : draft.name)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            TextField("相簿名称", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            Picker("", selection: $draft.matchAll) {
                Text("满足全部条件").tag(true)
                Text("满足任一条件").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(spacing: 8) {
                    if draft.rules.isEmpty {
                        Text("添加条件后会自动收集符合条件的照片。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }
                    ForEach($draft.rules) { $rule in
                        ruleRow(rule: $rule)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 180)

            Button {
                draft.rules.append(SmartRule(field: .keyword, value: ""))
            } label: {
                Label("添加条件", systemImage: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Divider()

            HStack(spacing: 10) {
                Label("将匹配 \(matchCount) 项", systemImage: "photo.stack")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.saveSmartAlbum(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .task(id: rulesSignature) {
            // 条件变化后稍作延迟再统计，避免连续输入时反复遍历整个图库。
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            matchCount = store.smartAlbumCount(draft)
        }
        .onDisappear {
            if store.editingSmartAlbum != nil {
                store.editingSmartAlbum = nil
            }
        }
    }

    private func ruleRow(rule: Binding<SmartRule>) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(SmartAlbumField.allCases) { field in
                    Button {
                        rule.wrappedValue.field = field
                        rule.wrappedValue.value = field.defaultValue
                    } label: {
                        Label(field.title, systemImage: field.icon)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: rule.wrappedValue.field.icon)
                        .font(.system(size: 10))
                    Text(rule.wrappedValue.field.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 168, alignment: .leading)

            valueEditor(rule)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                draft.rules.removeAll { $0.id == rule.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除条件")
        }
        .padding(9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func valueEditor(_ rule: Binding<SmartRule>) -> some View {
        switch rule.wrappedValue.field.valueKind {
        case .choice(let options):
            Picker("", selection: rule.value) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 120)

        case .toggle:
            Toggle("", isOn: Binding(
                get: { rule.wrappedValue.value != "否" },
                set: { rule.wrappedValue.value = $0 ? "是" : "否" }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

        case .date:
            DatePicker("", selection: Binding(
                get: { SmartAlbumDate.date(from: rule.wrappedValue.value) ?? Date() },
                set: { rule.wrappedValue.value = SmartAlbumDate.string(from: $0) }
            ), displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)

        case .number:
            TextField(rule.wrappedValue.field.placeholder, text: rule.value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)

        case .text:
            TextField(rule.wrappedValue.field.placeholder, text: rule.value)
                .textFieldStyle(.roundedBorder)
        }
    }
}
