import SwiftUI

enum NamePromptKind {
    case newAlbum(folderID: UUID?)
    case newFolder(parentID: UUID?)
    case renameAlbum(UUID)
    case renameFolder(UUID)
    /// 官方「照片」图库的相簿 / 文件夹写回（PhotoKit）。
    case newSystemAlbum(folderID: Int64?)
    case newSystemFolder(parentID: Int64?)
    case renameSystemAlbum(Int64)
    case renameSystemFolder(Int64)
}

struct NamePromptPayload: Identifiable {
    let id = UUID()
    let kind: NamePromptKind
    let title: String
    let actionTitle: String
    let initialText: String

    static func newAlbum(folderID: UUID?) -> NamePromptPayload {
        NamePromptPayload(kind: .newAlbum(folderID: folderID),
                          title: "新建相簿", actionTitle: "创建", initialText: "")
    }

    static func newFolder(parentID: UUID?) -> NamePromptPayload {
        NamePromptPayload(kind: .newFolder(parentID: parentID),
                          title: "新建文件夹", actionTitle: "创建", initialText: "")
    }

    static func renameAlbum(_ id: UUID, current: String) -> NamePromptPayload {
        NamePromptPayload(kind: .renameAlbum(id),
                          title: "重命名相簿", actionTitle: "重命名", initialText: current)
    }

    static func renameFolder(_ id: UUID, current: String) -> NamePromptPayload {
        NamePromptPayload(kind: .renameFolder(id),
                          title: "重命名文件夹", actionTitle: "重命名", initialText: current)
    }

    static func newSystemAlbum(folderID: Int64? = nil) -> NamePromptPayload {
        NamePromptPayload(kind: .newSystemAlbum(folderID: folderID),
                          title: folderID == nil ? "新建相簿（写入「照片」）" : "新建相簿（放进此文件夹）",
                          actionTitle: "创建", initialText: "")
    }

    static func newSystemFolder(parentID: Int64? = nil) -> NamePromptPayload {
        NamePromptPayload(kind: .newSystemFolder(parentID: parentID),
                          title: parentID == nil ? "新建文件夹（写入「照片」）" : "新建子文件夹",
                          actionTitle: "创建", initialText: "")
    }

    static func renameSystemAlbum(_ id: Int64, current: String) -> NamePromptPayload {
        NamePromptPayload(kind: .renameSystemAlbum(id),
                          title: "重命名相簿（写入「照片」）", actionTitle: "重命名", initialText: current)
    }

    static func renameSystemFolder(_ id: Int64, current: String) -> NamePromptPayload {
        NamePromptPayload(kind: .renameSystemFolder(id),
                          title: "重命名文件夹（写入「照片」）", actionTitle: "重命名", initialText: current)
    }
}

struct NamePromptSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let payload: NamePromptPayload
    @State private var text: String

    init(payload: NamePromptPayload) {
        self.payload = payload
        _text = State(initialValue: payload.initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(payload.title)
                .font(.headline)
            TextField("名称", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(payload.actionTitle) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func commit() {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch payload.kind {
        case .newAlbum(let folderID):
            store.createAlbum(named: name, folderID: folderID)
        case .newFolder(let parentID):
            store.createFolder(named: name, parentID: parentID)
        case .renameAlbum(let id):
            store.renameAlbum(id, to: name)
        case .renameFolder(let id):
            store.renameFolder(id, to: name)
        case .newSystemAlbum(let folderID):
            store.createSystemAlbum(named: name, inFolder: folderID)
        case .newSystemFolder(let parentID):
            store.createSystemFolder(named: name, parentID: parentID)
        case .renameSystemAlbum(let id):
            store.renameSystemAlbum(id, to: name)
        case .renameSystemFolder(let id):
            store.renameSystemFolder(id, to: name)
        }
        dismiss()
    }
}
