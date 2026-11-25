import Foundation
import LumaContentCore

/// 30 秒片段：从当前直播地址录一小段并收进图库。
/// 录制本身交给 `VideoSupport`，落库交给统一的 `IngestService`，进度统一登记到任务中心。
/// 源不支持时移时，「最近 30 秒」拿不到，这里按约定录「接下来 30 秒」。
@MainActor
final class TVClipRecorder {
    static let shared = TVClipRecorder()

    private var isRecording = false

    func record(channel: TVChannel, completion: @escaping (String) -> Void) {
        guard !isRecording else {
            completion("正在录制上一个片段，请稍候")
            return
        }
        guard let url = URL(string: channel.streamURL) else {
            completion("频道地址无效")
            return
        }
        guard let store = LibraryStore.current else {
            completion("当前没有可写入的图库")
            return
        }
        isRecording = true
        completion("开始录制 30 秒片段…")

        let title = "电视录制·\(channel.name)-\(Self.stampFormatter.string(from: Date()))"
        // 录制会跑 30 秒左右：登记到统一任务中心，左下角能看到进度并留下记录。
        let jobID = store.beginSourceJob(
            SourceJob(sourceID: .television(channel.playlistID),
                      kind: .record,
                      title: "录制 \(channel.name)",
                      isCancellable: false)
        )
        store.updateSourceJob(jobID, message: "正在抓取直播流…")

        let request = IngestRequest(
            payload: .remoteClip(RemoteMedia(url: url, headers: channel.headers),
                                 seconds: 30),
            title: title
        )
        Task { [weak self] in
            defer { self?.isRecording = false }
            do {
                let result = try await store.ingestService.ingest(request)
                store.finishSourceJob(jobID, message: "已保存到图库：\(result.title)")
                completion("已保存到图库：\(result.title)")
            } catch {
                store.failSourceJob(jobID, message: error.localizedDescription)
                completion("片段录制失败：\(error.localizedDescription)")
            }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
