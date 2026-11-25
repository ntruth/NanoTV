import SwiftUI
import CoreLocation

/// 系统图库的工具弹窗：拍摄信息、移动相簿到文件夹、新建相簿并加入、删除文件夹确认。
/// 全部走 PhotoKit 写回「照片」，不直接改 Photos.sqlite。
struct SystemToolsSheet: View {
    @EnvironmentObject private var store: LibraryStore
    let request: SystemToolsRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch request {
            case .metadata(let ids):
                MetadataEditor(ids: ids)
            case .moveAlbumsToFolder(let albumIDs):
                FolderPicker(albumIDs: albumIDs)
            case .newAlbumWithPhotos(let ids):
                NewAlbumWithPhotos(ids: ids)
            case .deleteFolder(let id, let name, let albumCount):
                DeleteFolderConfirm(id: id, name: name, albumCount: albumCount)
            case .cleanupEmptyCollections(let albumIDs, let folderIDs):
                EmptyCollectionsCleanup(albumIDs: albumIDs, folderIDs: folderIDs)
            }
        }
        .padding(22)
        .frame(width: request.isCompact ? 400 : 480)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                LinearGradient(colors: [Color.accentColor.opacity(0.06), .clear],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            }
        }
    }
}

private extension SystemToolsRequest {
    var isCompact: Bool {
        switch self {
        case .deleteFolder, .newAlbumWithPhotos: return true
        default: return false
        }
    }
}

// MARK: - 标题条

private struct ToolHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.6)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40)
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 拍摄信息

private struct MetadataEditor: View {
    @EnvironmentObject private var store: LibraryStore
    let ids: Set<UUID>

    @State private var changeDate = true
    @State private var date: Date = Date()
    @State private var changeLocation = false
    @State private var latitude: String = ""
    @State private var longitude: String = ""

    private var photos: [PhotoItem] { ids.compactMap { store.anyPhoto(id: $0) } }

    private var parsedLocation: CLLocation? {
        guard changeLocation,
              let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
    }

    private var canApply: Bool {
        (changeDate || parsedLocation != nil) && !ids.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(symbol: "clock.badge.checkmark",
                       title: "修改拍摄信息",
                       subtitle: "共 \(ids.count) 项 · 写回「照片」")

            Toggle(isOn: $changeDate) {
                Text("拍摄时间").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if changeDate {
                DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            Divider()

            Toggle(isOn: $changeLocation) {
                Text("位置").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if changeLocation {
                HStack(spacing: 8) {
                    TextField("纬度", text: $latitude)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    TextField("经度", text: $longitude)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                Text("填写十进制度数，例如 31.2304 / 121.4737。修改位置会在「照片」中同步更新。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    store.systemToolsRequest = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("应用") {
                    let location = parsedLocation
                    store.updateSystemMetadata(ids,
                                               creationDate: changeDate ? date : nil,
                                               location: location)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
            }
        }
        .onAppear {
            changeDate = true
            changeLocation = false
            if let first = photos.first {
                date = first.capturedAt
                if let lat = first.latitude, let lon = first.longitude {
                    latitude = String(format: "%.6f", lat)
                    longitude = String(format: "%.6f", lon)
                }
            }
        }
    }
}

// MARK: - 移动到文件夹

private struct FolderPicker: View {
    @EnvironmentObject private var store: LibraryStore
    let albumIDs: [Int64]

    @State private var query = ""

    private var choices: [(id: Int64, path: String)] {
        let all = store.systemFolderChoices()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
    }

    private var albumName: String {
        albumIDs.compactMap { store.systemAlbum(id: $0)?.name }.joined(separator: "、")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolHeader(symbol: "folder.badge.plus",
                       title: "移动到文件夹",
                       subtitle: albumName.isEmpty ? "\(albumIDs.count) 个相簿" : "「\(albumName)」")

            TextField("搜索文件夹", text: $query)
                .textFieldStyle(.roundedBorder)

            if choices.isEmpty {
                Text("还没有可用的文件夹。可以先在侧边栏新建文件夹。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(choices, id: \.id) { choice in
                            Button {
                                store.moveSystemAlbums(albumIDs, toFolder: choice.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.accentColor)
                                    Text(choice.path)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(Color.secondary.opacity(0.001))
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            HStack {
                Spacer()
                Button("取消") {
                    store.systemToolsRequest = nil
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - 新建相簿并加入

private struct NewAlbumWithPhotos: View {
    @EnvironmentObject private var store: LibraryStore
    let ids: Set<UUID>

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(symbol: "rectangle.stack.badge.plus",
                       title: "新建相簿并加入",
                       subtitle: "\(ids.count) 项 · 一步写回「照片」")

            TextField("相簿名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }

            Text("创建相簿与加入项目在同一个事务里完成；失败不会留下空相簿。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    store.systemToolsRequest = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("创建并加入") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private func commit() {
        store.createSystemAlbum(named: name, adding: ids)
    }
}

// MARK: - 删除文件夹确认

private struct DeleteFolderConfirm: View {
    @EnvironmentObject private var store: LibraryStore
    let id: Int64
    let name: String
    let albumCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(symbol: "folder.badge.minus",
                       title: "删除这个文件夹？",
                       subtitle: "「\(name)」",
                       tint: .red)

            Text(albumCount > 0
                 ? "文件夹及其子文件夹里的 \(albumCount) 个相簿会一起从「照片」移除；照片本身不受影响，也不会丢失。"
                 : "文件夹及其空的子文件夹会从「照片」移除；照片本身不受影响。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    store.systemToolsRequest = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    store.deleteSystemFolder(id)
                } label: {
                    Text("删除文件夹")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }
}

// MARK: - 空相簿 / 空文件夹清理

private struct EmptyCollectionsCleanup: View {
    @EnvironmentObject private var store: LibraryStore
    let albumIDs: [Int64]
    let folderIDs: [Int64]

    @State private var removeAlbums = true
    @State private var removeFolders = true

    /// 两项都不选时没有可执行的动作。
    private var canClean: Bool {
        (removeAlbums && !albumIDs.isEmpty) || (removeFolders && !folderIDs.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ToolHeader(symbol: "sparkles",
                       title: "清理空相簿与空文件夹",
                       subtitle: "只移除空容器 · 照片本身不受影响",
                       tint: .orange)

            VStack(alignment: .leading, spacing: 8) {
                if !albumIDs.isEmpty {
                    Toggle(isOn: $removeAlbums) {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.stack.badge.minus")
                                .foregroundStyle(.secondary)
                            Text("空相簿 \(albumIDs.count) 个")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                if !folderIDs.isEmpty {
                    Toggle(isOn: $removeFolders) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.minus")
                                .foregroundStyle(.secondary)
                            Text("空文件夹 \(folderIDs.count) 个（连同其中的空子文件夹）")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("清理通过「照片」的相簿接口完成，只移除相簿 / 文件夹本身；删除后无法在拾光里撤销。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    store.systemToolsRequest = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    store.cleanupEmptyCollections(albumIDs: albumIDs,
                                                  folderIDs: folderIDs,
                                                  removeAlbums: removeAlbums,
                                                  removeFolders: removeFolders)
                } label: {
                    Text("开始清理")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canClean)
            }
        }
    }
}
