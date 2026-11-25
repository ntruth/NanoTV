import Foundation
import LumaContentCore

/// 统一任务中心在 `LibraryStore` 上的便捷入口。
/// 现有各模块的 Task 字段可以继续保留；先把进度与取消收口到一处，后续再逐个替换。
extension LibraryStore {
    /// 任务历史只有一套：影院刮削、网盘扫描、导入、录制都写这里。
    private static let sourceJobHistoryKey = "source_job_history"

    @discardableResult
    func beginSourceJob(_ job: SourceJob, cancel: (() -> Void)? = nil) -> UUID {
        let id = sourceJobCenter.begin(job, cancel: cancel)
        sourceJobRevision &+= 1
        return id
    }

    func updateSourceJob(_ id: UUID,
                         completed: Int? = nil,
                         total: Int? = nil,
                         message: String? = nil,
                         fraction: Double? = nil) {
        sourceJobCenter.update(id, completed: completed, total: total, message: message, fraction: fraction)
        sourceJobRevision &+= 1
    }

    func finishSourceJob(_ id: UUID, message: String? = nil) {
        sourceJobCenter.finish(id, message: message)
        archiveSourceJob(id)
    }

    func failSourceJob(_ id: UUID, message: String? = nil) {
        sourceJobCenter.fail(id, message: message)
        archiveSourceJob(id)
    }

    func cancelSourceJob(_ id: UUID) {
        sourceJobCenter.cancel(id)
        archiveSourceJob(id)
    }

    /// 取消但不留记录：搜索这类会被下一次输入立刻打断的任务，
    /// 不该在任务记录里堆一串「已取消」，只需要让任务条收起。
    func abandonSourceJob(_ id: UUID) {
        guard sourceJobCenter.progress[id] != nil else { return }
        sourceJobCenter.discard(id)
        sourceJobRevision &+= 1
    }

    // MARK: 历史

    /// 读回上次运行留下的任务记录。
    func loadSourceJobHistory() {
        guard let metadataStore,
              let json = metadataStore.setting(Self.sourceJobHistoryKey),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([JobProgress].self, from: data) else { return }
        sourceJobHistory = list
    }

    func persistSourceJobHistory() {
        if sourceJobHistory.count > 200 {
            sourceJobHistory = Array(sourceJobHistory.sorted { $0.updatedAt > $1.updatedAt }.prefix(200))
        }
        guard let metadataStore,
              let data = try? JSONEncoder().encode(sourceJobHistory),
              let json = String(data: data, encoding: .utf8) else { return }
        metadataStore.setSetting(Self.sourceJobHistoryKey, json)
    }

    /// 任务结束即归档：内存里的任务中心只保留本次运行，历史落盘保证重启后仍可回看。
    func archiveSourceJob(_ id: UUID) {
        guard let item = sourceJobCenter.progress[id] else { return }
        if let index = sourceJobHistory.firstIndex(where: { $0.jobID == id }) {
            sourceJobHistory[index] = item
        } else {
            sourceJobHistory.append(item)
        }
        persistSourceJobHistory()
        sourceJobRevision &+= 1
    }

    func sourceJobs(for sourceID: SourceID) -> [JobProgress] {
        sourceJobCenter.progress.values
            .filter { $0.sourceID == sourceID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeSourceJobs: [JobProgress] {
        sourceJobCenter.progress.values
            .filter { $0.phase == .running || $0.phase == .pending }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 某类已结束任务的最近记录：任务浮层用它展示「连接检测」等一次性结果。
    func recentSourceJobs(kind: SourceJobKind, limit: Int = 4) -> [JobProgress] {
        mergedFinishedSourceJobs(limit: 200)
            .filter { $0.kind == kind }
            .prefix(limit)
            .map { $0 }
    }

    /// 已结束的各类任务：本次运行与历史合并成一条时间线。
    func recentFinishedSourceJobs(limit: Int = 6) -> [JobProgress] {
        mergedFinishedSourceJobs(limit: limit)
    }

    /// 统一任务中心 + 持久化历史，按 jobID 去重后按时间排序。
    private func mergedFinishedSourceJobs(limit: Int) -> [JobProgress] {
        var merged: [JobProgress] = []
        var seen = Set<UUID>()
        let live = sourceJobCenter.progress.values
            .filter { $0.phase != .running && $0.phase != .pending }
            .sorted { $0.updatedAt > $1.updatedAt }
        for job in live {
            seen.insert(job.jobID)
            merged.append(job)
        }
        for job in sourceJobHistory.sorted(by: { $0.updatedAt > $1.updatedAt })
        where !seen.contains(job.jobID) {
            merged.append(job)
        }
        return Array(merged.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    func clearFinishedSourceJobs(kind: SourceJobKind) {
        sourceJobCenter.clearFinished(kind: kind)
        sourceJobHistory.removeAll { $0.kind == kind }
        persistSourceJobHistory()
        sourceJobRevision &+= 1
    }

    /// 清空全部历史（含本次运行已结束的任务），进行中的不动。
    func clearSourceJobHistory() {
        sourceJobHistory = []
        persistSourceJobHistory()
        sourceJobCenter.clearFinished()
        sourceJobRevision &+= 1
    }

    /// 影院作用域 → 统一源 ID。
    func sourceID(for scope: CinemaScope) -> SourceID {
        switch scope {
        case .local:
            return .localCinema
        case .mount(let id):
            return .mountCinema(id)
        }
    }
}
