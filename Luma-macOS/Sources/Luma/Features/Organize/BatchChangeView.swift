import SwiftUI

/// 批量更改：一次修改所选项目的标题、拍摄日期与地点，对应官方「图像 › 批量更改」。
struct BatchChangeView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var editTitle = false
    @State private var title = ""
    @State private var editDate = false
    @State private var date = Date()
    @State private var editPlace = false
    @State private var place = ""

    private var targetCount: Int { store.batchChangeTargets.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("批量更改")
                    .font(.system(size: 15, weight: .semibold))
                Text("将应用到 \(targetCount) 项，未勾选的字段保持不变。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                fieldRow(isOn: $editTitle, label: "标题") {
                    TextField("留空则清除标题", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow(isOn: $editDate, label: "拍摄日期") {
                    DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                fieldRow(isOn: $editPlace, label: "地点") {
                    TextField("例如 杭州市余杭区", text: $place)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("应用") {
                    store.applyBatchChange(title: editTitle ? title : nil,
                                           date: editDate ? date : nil,
                                           place: editPlace ? place : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editTitle && !editDate && !editPlace)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let first = store.photos.first(where: { store.batchChangeTargets.contains($0.id) }) {
                title = first.title ?? ""
                date = first.capturedAt
                place = first.placeCity ?? first.placePOI ?? ""
            }
        }
    }

    private func fieldRow<Content: View>(isOn: Binding<Bool>,
                                         label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Toggle(label, isOn: isOn)
                .toggleStyle(.checkbox)
                .frame(width: 88, alignment: .leading)
            content()
                .disabled(!isOn.wrappedValue)
                .opacity(isOn.wrappedValue ? 1 : 0.5)
        }
    }
}
