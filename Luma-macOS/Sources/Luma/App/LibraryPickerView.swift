import AppKit
import SwiftUI

struct LibraryEntry: Identifiable {
    let id: String
    let url: URL
    let name: String
    let modifiedAt: Date?
    let isCurrent: Bool
    var isDefault: Bool = false

    var title: String {
        var tags: [String] = []
        if isCurrent { tags.append("当前") }
        if isDefault { tags.append("默认") }
        return tags.isEmpty ? name : "\(name)（\(tags.joined(separator: "·"))）"
    }
}

/// 图库选择器（独立窗口，对齐系统「照片」的选取图库）：按住 Option 启动时自动弹出，
/// 打开期间主窗口整窗隐藏；由 RootView 监听 `showLibraryPicker` 负责开窗与恢复。
struct LibraryPickerView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var entries: [LibraryEntry] = []
    @State private var selection: String?

    private var selectedEntry: LibraryEntry? {
        entries.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text("选取图库")
                        .font(.system(size: 15, weight: .semibold))
                    Text("从列表中选取照片图库、在电脑上查找其他图库，或创建新图库。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有最近的图库")
                        .font(.system(size: 13, weight: .medium))
                    Text("点「其他图库…」选择一个 .photoslibrary，或新建一个图库。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 168)
            } else {
                Table(entries, selection: $selection) {
                    TableColumn("图库名称") { entry in
                        Text(entry.title)
                    }
                    TableColumn("上次修改时间") { entry in
                        Text(Self.format(entry.modifiedAt))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 168)
            }

            HStack(spacing: 8) {
                Text(selectedEntry?.url.path ?? " ")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let url = selectedEntry?.url {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("在访达中显示")
                }
                Button {
                    disconnectSelected()
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(selectedEntry == nil)
                .help("断开选中的图库（不会删除磁盘上的图库文件）")
            }

            HStack(spacing: 10) {
                Button("其他图库…") {
                    store.presentLibraryContainerPanel()
                }
                Text("按住 Option 启动可再次打开此面板")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button("新建…") {
                    // 先收起选择器窗口（恢复主窗口），等窗口真正回到前台再挂建库向导，
                    // 否则 sheet 可能挂到已被隐藏的主窗口上而看不见。
                    store.showLibraryPicker = false
                    store.libraryPickerOnLaunch = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        store.beginNewLibraryFlow()
                    }
                }
                Button("选取图库") {
                    choose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedEntry == nil)
            }
        }
        .padding(20)
        .frame(width: 600, height: 400)
        .onAppear {
            reload()
        }
        .onDisappear {
            // 直接关闭窗口（红叉）等价于「取消」：此时标志仍为 true，走取消分支。
            // 正常的选取 / 取消路径都会先清 `showLibraryPicker`，不会落到这里。
            if store.showLibraryPicker {
                close()
            }
        }
    }

    private func reload() {
        entries = store.knownLibraryEntries()
        if selection == nil || !entries.contains(where: { $0.id == selection }) {
            selection = entries.first { $0.isCurrent }?.id ?? entries.first?.id
        }
    }

    private func choose() {
        guard let entry = selectedEntry else { return }
        // 先收起窗口（清标志会让 RootView 关掉本窗口并恢复主窗口），再把切换放到下一帧：
        // 图库切换里的同步读写不会拖住关闭动作。`activateLibrary` 会解除启动占位。
        store.showLibraryPicker = false
        DispatchQueue.main.async {
            store.activateLibrary(entry.url)
        }
    }

    /// 断开选中的图库。选择器是独立窗口，确认卡片放在主窗口上会被隐藏，
    /// 这里直接用系统弹窗；断开的若是当前图库，store 会退回「创建或打开图库」。
    private func disconnectSelected() {
        guard let entry = selectedEntry else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "断开「\(entry.name)」？"
        alert.informativeText = entry.isCurrent
            ? "会退出当前图库并回到「创建或打开图库」；磁盘上的图库文件与照片不会被删除。"
            : "只会从图库列表移除这条记录，不会删除磁盘上的图库文件，之后可以重新打开。"
        alert.addButton(withTitle: "断开连接")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.disconnectLibrary(entry.url.path)
        selection = nil
        reload()
        // 一个图库都不剩：收起选择器，回到主窗口的「创建或打开图库」。
        if store.knownLibraryEntries().isEmpty {
            store.showLibraryPicker = false
            store.libraryPickerOnLaunch = false
        }
    }

    private func close() {
        // 启动时弹出的面板被取消：回到原来的图库；普通面板只关闭自己。
        let reopen = store.libraryPickerOnLaunch ? LibraryPaths.containerLibraryURL : nil
        store.showLibraryPicker = false
        if let reopen {
            DispatchQueue.main.async {
                store.activateLibrary(reopen)
            }
        } else {
            store.libraryPickerOnLaunch = false
        }
    }

    private static func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'今天' HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'昨天' HH:mm"
        } else {
            formatter.dateFormat = "yyyy/M/d HH:mm"
        }
        return formatter.string(from: date)
    }
}
