import Foundation
import LumaContentCore

/// 图库入库实现：当前图库是唯一写入会话，外部源只提交 `IngestRequest`。
@MainActor
final class LibraryIngestService: IngestService {
    private unowned let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    /// 单个本地文件的统一入库入口：系统库拷贝、剪贴板粘贴、美化 / 压缩输出都走这里。
    /// 这些调用点原先各自直接调 `ImportService.importFile`，收口后换实现只改一处。
    /// 保持在 nonisolated：解析与拷贝本身是重活，调用方通常放在后台任务里执行。
    nonisolated func importLocalFile(_ url: URL) throws -> PhotoItem {
        try ImportService.importFile(url)
    }

    func ingest(_ request: IngestRequest) async throws -> IngestResult {
        switch request.payload {
        case .localFile(let url):
            store.runImport(entries: [(url: url, folders: folderList(request))],
                            options: ImportOptions())
            return IngestResult(title: request.title ?? url.lastPathComponent)

        case .remoteClip(let media, let seconds):
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("luma-clip-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await VideoSupport.recordRemoteClip(source: media.url,
                                                    headers: media.headers,
                                                    trustSelfSigned: media.trustSelfSigned,
                                                    seconds: seconds,
                                                    destination: temp)
            var photo = try ImportService.importFile(temp)
            if let title = request.title, !title.isEmpty {
                photo.title = title
            }
            store.photos.append(photo)
            store.persistImported([photo])
            store.save()
            return IngestResult(itemID: photo.id.uuidString, title: photo.displayTitle)

        case .imageData(let data, let fileExtension):
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("luma-ingest-\(UUID().uuidString).\(fileExtension)")
            try data.write(to: temp)
            // 导入是异步流水线，临时文件交给它与系统清理；不要在这里立刻删除。
            store.runImport(entries: [(url: temp, folders: folderList(request))],
                            options: ImportOptions())
            return IngestResult(title: request.title ?? temp.lastPathComponent)

        case .remoteVideo(let media):
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("luma-ingest-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await VideoSupport.transcodeRemote(source: media.url,
                                                   headers: media.headers,
                                                   trustSelfSigned: media.trustSelfSigned,
                                                   destination: temp)
            var photo = try ImportService.importFile(temp)
            if let title = request.title, !title.isEmpty {
                photo.title = title
            }
            store.photos.append(photo)
            store.persistImported([photo])
            store.save()
            return IngestResult(itemID: photo.id.uuidString, title: photo.displayTitle)
        }
    }

    private func folderList(_ request: IngestRequest) -> [String] {
        request.folderName.map { [$0] } ?? []
    }
}
