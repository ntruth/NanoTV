import Foundation
import CoreServices

/// 本地目录监听：用 FSEvents 监听本机真实目录（本地图库 originals 等）。
/// 云盘没有文件系统事件，仍由「扫描 / 刷新目录」触发。
final class LocalCinemaWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.luma.cinema.watch")
    private let onChange: () -> Void
    private var pendingWork: DispatchWorkItem?

    init?(paths: [String], onChange: @escaping () -> Void) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        self.onChange = onChange

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil,
                                           release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LocalCinemaWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil,
                                     callback,
                                     &context,
                                     existing as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                     1.0,
                                     flags)
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// 目录写入常常是一次操作触发几十个事件：合并成 1.2 秒后的一次刷新。
    private func scheduleChange() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
