import Foundation
import AppKit
import CoreImage
import LumaCore
import LumaContentCore
import SwiftUI

/// 一次批量美化的结果，供推荐面板与智能助手复用。
struct BeautyBatchResult {
    let applied: Int
    let skipped: Int
    let message: String
}

/// 智能美化：用缩略图做端侧分析，按「偏暗 / 偏亮 / 发灰 / 偏色 / 偏软」归类推荐，
/// 并把建议映射成编辑器同一套参数生成渲染副本。原图始终保留，可随时还原。
/// 本地图库直接生成渲染副本；系统图库与网盘只读，美化结果会作为新照片保存到拾光本地图库。
extension LibraryStore {
    /// 是否有可美化的照片：系统图库可从官方原图 / derivative 读取，因此同样可用。
    var canScanBeauty: Bool {
        !needsLibrarySetup
    }

    func resetBeautyState() {
        beautyTask?.cancel()
        beautyTask = nil
        beautyReport = nil
        isScanningBeauty = false
        beautyScanProgress = 0
        isApplyingBeauty = false
        beautyApplyProgress = 0
        showBeautyPanel = false
        cloudModel.beautyReportIsCloud = false
        beautyReportIsSystem = false
    }

    // MARK: - 推荐缓存（落库）

    /// 当前范围的推荐缓存键：本地 / 系统图库 / 网盘目录各自独立。
    var beautyReportCacheKey: String? {
        if isSystemScope {
            guard let path = systemLibraryPath else { return nil }
            return DerivedReportKey.system(path, "beauty")
        }
        if isCloudScope {
            guard let mountID = cloudModel.insightMountID ?? currentCloudMountID else { return nil }
            return DerivedReportKey.cloud(mountID, cloudPath, "beauty")
        }
        return DerivedReportKey.local("beauty")
    }

    var beautyReportSignature: String {
        if isSystemScope { return systemCacheSignature }
        if isCloudScope { return "cloud#\(cloudPhotos.count)" }
        return "local"
    }

    func persistBeautyReport(_ report: BeautyReport) {
        guard let key = beautyReportCacheKey,
              let store = metadataStore,
              let data = try? JSONEncoder().encode(report) else { return }
        store.saveDerivedReport(key: key, signature: beautyReportSignature, payload: data)
    }

    /// 打开推荐面板时回填上次结果；范围或签名不一致就丢弃旧缓存。
    func restoreCachedBeautyReportIfNeeded() {
        if beautyReport != nil {
            if isSystemScope, beautyReportIsSystem { return }
            if isCloudScope, cloudModel.beautyReportIsCloud { return }
            if !isSystemScope, !isCloudScope, !beautyReportIsSystem, !cloudModel.beautyReportIsCloud {
                return
            }
        }
        guard let key = beautyReportCacheKey,
              let store = metadataStore,
              let cached = store.loadDerivedReport(key: key),
              let report = try? JSONDecoder().decode(BeautyReport.self, from: cached.payload) else {
            return
        }
        if let signature = cached.signature, signature != beautyReportSignature {
            store.removeDerivedReport(key: key)
            return
        }
        beautyReport = report
        beautyReportIsSystem = isSystemScope
        cloudModel.beautyReportIsCloud = isCloudScope
    }

    // MARK: - 扫描与推荐

    /// 按拍摄时间从新到旧分析最多 `limit` 张照片，产出可直接批量处理的分组。
    func scanBeautyCandidates(limit: Int = 2000) {
        guard canScanBeauty else {
            showToast("智能美化需要先打开图库")
            return
        }
        guard !isScanningBeauty, !isApplyingBeauty else { return }
        if isCloudScope {
            scanCloudBeautyCandidates(limit: limit)
            return
        }
        if isSystemScope {
            scanSystemBeautyCandidates(limit: limit)
            return
        }

        let targets = photos
            .filter { $0.deletedAt == nil && !$0.isHidden && !$0.isVideo }
            .sorted { $0.capturedAt > $1.capturedAt }
        guard !targets.isEmpty else {
            showToast("图库里还没有可分析的照片")
            return
        }
        let slice = Array(targets.prefix(max(1, limit)))

        cloudModel.beautyReportIsCloud = false
        beautyReportIsSystem = false
        isScanningBeauty = true
        beautyScanProgress = 0
        let jobID = beginBeautyScanJob()
        beautyTask = Task { [weak self] in
            guard let self else { return }
            var found: [(UUID, BeautyAdvice)] = []
            found.reserveCapacity(slice.count)

            // 按小块并发：缩略图解码是主要开销，小块可以及时回报进度。
            let chunkSize = 12
            var index = 0
            while index < slice.count {
                if Task.isCancelled { break }
                let end = min(index + chunkSize, slice.count)
                let chunk = Array(slice[index..<end])
                let part = await Task.detached(priority: .utility) {
                    chunk.compactMap { photo in
                        PhotoBeauty.advice(for: photo).map { (photo.id, $0) }
                    }
                }.value
                found.append(contentsOf: part)
                index = end
                self.beautyScanProgress = Double(index) / Double(max(1, slice.count))
                self.updateSourceJob(jobID,
                                     completed: index,
                                     total: slice.count,
                                     message: "已分析 \(index) / \(slice.count) 张")
            }

            if Task.isCancelled {
                self.isScanningBeauty = false
                self.beautyScanProgress = 0
                self.beautyTask = nil
                self.cancelSourceJob(jobID)
                return
            }

            let report = self.buildBeautyReport(found: found,
                                                scannedCount: slice.count,
                                                lookup: Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) }))
            self.beautyReport = report
            self.persistBeautyReport(report)
            self.isScanningBeauty = false
            self.beautyScanProgress = 0
            self.beautyTask = nil
            self.finishSourceJob(jobID, message: "完成 · \(report.distinctCount) 张可美化")
            if report.distinctCount == 0 {
                self.showToast("分析完成：这 \(slice.count) 张画面已经比较均衡")
            } else {
                self.showToast("分析完成：\(report.distinctCount) 张可以美化")
            }
        }
    }

    func cancelBeautyScan() {
        beautyTask?.cancel()
        beautyTask = nil
        isScanningBeauty = false
        beautyScanProgress = 0
    }

    /// 网盘版推荐扫描：逐张取缩略图做端侧采样，推荐结果写入 `derived_reports`。
    private func scanCloudBeautyCandidates(limit: Int) {
        let slice = Array(cloudPhotos
            .filter { !$0.isVideo && !$0.isHidden }
            .prefix(max(1, limit)))
        guard !slice.isEmpty else {
            showToast("当前目录没有可分析的照片")
            return
        }

        isScanningBeauty = true
        beautyScanProgress = 0
        cloudModel.beautyReportIsCloud = true
        beautyReportIsSystem = false
        let jobID = beginBeautyScanJob()
        beautyTask = Task { [weak self] in
            guard let self else { return }
            var found: [(UUID, BeautyAdvice)] = []
            var done = 0
            for photo in slice {
                if Task.isCancelled { break }
                if let image = await self.cloudThumbnail(for: photo),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let advice = await Task.detached(priority: .utility) {
                        PhotoBeauty.advice(image: cgImage)
                    }.value
                    if let advice {
                        found.append((photo.id, advice))
                    }
                }
                done += 1
                self.beautyScanProgress = Double(done) / Double(slice.count)
                self.updateSourceJob(jobID,
                                     completed: done,
                                     total: slice.count,
                                     message: "已分析 \(done) / \(slice.count) 张")
                await Task.yield()
            }

            if Task.isCancelled {
                self.isScanningBeauty = false
                self.beautyScanProgress = 0
                self.beautyTask = nil
                self.cancelSourceJob(jobID)
                return
            }

            let lookup = Dictionary(uniqueKeysWithValues: slice.map { ($0.id, $0) })
            let report = self.buildBeautyReport(found: found, scannedCount: slice.count, lookup: lookup)
            self.beautyReport = report
            self.persistBeautyReport(report)
            self.isScanningBeauty = false
            self.beautyScanProgress = 0
            self.beautyTask = nil
            self.finishSourceJob(jobID, message: "完成 · \(report.distinctCount) 张可美化")
            if report.distinctCount == 0 {
                self.showToast("分析完成：这 \(slice.count) 张画面已经比较均衡")
            } else {
                self.showToast("分析完成：\(report.distinctCount) 张可以美化")
            }
        }
    }

    /// 系统图库版推荐扫描：用官方 derivative / 缓存缩略图采样，推荐结果写入 `derived_reports`。
    private func scanSystemBeautyCandidates(limit: Int) {
        let slice = Array(systemLoadedPhotos
            .filter { !$0.isVideo && !$0.isHidden }
            .prefix(max(1, limit)))
        guard !slice.isEmpty else {
            showToast("当前范围没有可分析的照片")
            return
        }

        isScanningBeauty = true
        beautyScanProgress = 0
        cloudModel.beautyReportIsCloud = false
        beautyReportIsSystem = true
        let jobID = beginBeautyScanJob()
        beautyTask = Task { [weak self] in
            guard let self else { return }
            var found: [(UUID, BeautyAdvice)] = []
            let chunkSize = 12
            var index = 0
            while index < slice.count {
                if Task.isCancelled { break }
                let end = min(index + chunkSize, slice.count)
                let chunk = Array(slice[index..<end])
                let part = await Task.detached(priority: .utility) {
                    chunk.compactMap { photo -> (UUID, BeautyAdvice)? in
                        guard let image = ImageLoader.thumbnail(for: photo),
                              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              let advice = PhotoBeauty.advice(image: cgImage) else { return nil }
                        return (photo.id, advice)
                    }
                }.value
                found.append(contentsOf: part)
                index = end
                self.beautyScanProgress = Double(index) / Double(slice.count)
                self.updateSourceJob(jobID,
                                     completed: index,
                                     total: slice.count,
                                     message: "已分析 \(index) / \(slice.count) 张")
                await Task.yield()
            }

            if Task.isCancelled {
                self.isScanningBeauty = false
                self.beautyScanProgress = 0
                self.beautyTask = nil
                self.cancelSourceJob(jobID)
                return
            }

            let lookup = Dictionary(uniqueKeysWithValues: slice.map { ($0.id, $0) })
            let report = self.buildBeautyReport(found: found, scannedCount: slice.count, lookup: lookup)
            self.beautyReport = report
            self.persistBeautyReport(report)
            self.isScanningBeauty = false
            self.beautyScanProgress = 0
            self.beautyTask = nil
            self.finishSourceJob(jobID, message: "完成 · \(report.distinctCount) 张可美化")
            if report.distinctCount == 0 {
                self.showToast("分析完成：这 \(slice.count) 张画面已经比较均衡")
            } else {
                self.showToast("分析完成：\(report.distinctCount) 张可以美化")
            }
        }
    }

    /// 把候选按偏差方向分桶，并按「偏差程度 + 收藏加权 - 已编辑降权」排序。
    @MainActor
    private func buildBeautyReport(found: [(UUID, BeautyAdvice)],
                                   scannedCount: Int,
                                   lookup: [UUID: PhotoItem]) -> BeautyReport {
        var buckets: [BeautyGroup.Kind: [(Double, BeautyCandidate)]] = [:]

        for (id, advice) in found where advice.score >= BeautyAdvisor.recommendThreshold {
            guard lookup[id] != nil else { continue }
            var rank = advice.score
            if lookup[id]?.isFavorite == true { rank += 0.08 }
            if lookup[id]?.hasEdits == true { rank -= 0.12 }
            let candidate = BeautyCandidate(photoID: id, advice: advice)
            for kind in Self.beautyKinds(for: advice) {
                buckets[kind, default: []].append((rank, candidate))
            }
        }

        let groups = BeautyGroup.Kind.allCases.compactMap { kind -> BeautyGroup? in
            guard let entries = buckets[kind], !entries.isEmpty else { return nil }
            let sorted = entries
                .sorted { $0.0 > $1.0 }
                .prefix(300)
                .map(\.1)
            return BeautyGroup(kind: kind, candidates: Array(sorted))
        }
        .sorted { $0.count > $1.count }

        return BeautyReport(scannedAt: Date(), scannedCount: scannedCount, groups: groups)
    }

    private static func beautyKinds(for advice: BeautyAdvice) -> [BeautyGroup.Kind] {
        var kinds: [BeautyGroup.Kind] = []
        if advice.exposure > 0.15 { kinds.append(.dark) }
        if advice.exposure < -0.15 { kinds.append(.bright) }
        if advice.contrast >= 0.06 { kinds.append(.flat) }
        if abs(advice.warmth) >= 0.06 || abs(advice.tint) >= 0.06 { kinds.append(.cast) }
        if advice.sharpness >= 0.15 { kinds.append(.soft) }
        return kinds
    }

    // MARK: - 批量应用

    /// 美化任务归属：网盘挂到挂载，系统图库挂系统图库，其余挂当前图库。
    private var beautyJobSourceID: SourceID {
        if isCloudScope, let mountID = currentCloudMountID { return .cloud(mountID) }
        if isSystemScope, let path = systemLibraryPath { return .library(path) }
        return .library((LibraryPaths.containerLibraryURL ?? LibraryPaths.root).standardizedFileURL.path)
    }

    private func beginBeautyScanJob() -> UUID {
        beginSourceJob(SourceJob(sourceID: beautyJobSourceID, kind: .beauty, title: "智能美化扫描"),
                       cancel: { [weak self] in
                           Task { @MainActor in self?.cancelBeautyScan() }
                       })
    }

    /// 为指定照片生成美化副本。已经是编辑过的照片会在原有编辑点上叠加，不会丢弃已有调整。
    @discardableResult
    func applyBeauty(to photoIDs: [UUID], strength: Double = 1) async -> BeautyBatchResult {
        // 批量渲染没有中断句柄：只登记任务与结果，不提供取消按钮。
        let jobID = beginSourceJob(
            SourceJob(sourceID: beautyJobSourceID,
                      kind: .beauty,
                      title: "批量美化",
                      isCancellable: false)
        )
        let result = await applyBeautyCore(to: photoIDs, strength: strength)
        finishSourceJob(jobID, message: result.message)
        return result
    }

    private func applyBeautyCore(to photoIDs: [UUID], strength: Double) async -> BeautyBatchResult {
        if isCloudScope {
            return await applyCloudBeauty(to: photoIDs, strength: strength)
        }
        if isSystemScope {
            return await applySystemBeauty(to: photoIDs, strength: strength)
        }
        guard canScanBeauty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "当前范围不支持智能美化")
        }
        guard !isApplyingBeauty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "正在美化其他照片，请稍候")
        }
        let wanted = Set(photoIDs)
        let targets = photos.filter { wanted.contains($0.id) && !$0.isVideo && $0.deletedAt == nil }
        guard !targets.isEmpty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "没有可美化的照片")
        }

        isApplyingBeauty = true
        beautyApplyProgress = 0
        var renders: [BeautyRender] = []
        renders.reserveCapacity(targets.count)

        // 原图解码与全尺寸渲染较重，逐小块放到后台，界面只更新进度。
        let chunkSize = 4
        var index = 0
        while index < targets.count {
            if Task.isCancelled { break }
            let end = min(index + chunkSize, targets.count)
            let chunk = Array(targets[index..<end])
            let part = await Task.detached(priority: .userInitiated) {
                Self.renderBeauty(checkpoint: chunk, strength: strength)
            }.value
            renders.append(contentsOf: part)
            index = end
            beautyApplyProgress = Double(index) / Double(max(1, targets.count))
        }

        commitBeautyRenders(renders)
        isApplyingBeauty = false
        beautyApplyProgress = 0

        let skipped = targets.count - renders.count
        if renders.isEmpty {
            return BeautyBatchResult(applied: 0, skipped: skipped, message: "这些照片没有可美化的调整")
        }
        showToast(skipped > 0 ? "已美化 \(renders.count) 张，\(skipped) 张跳过" : "已美化 \(renders.count) 张")
        return BeautyBatchResult(applied: renders.count, skipped: skipped, message: "已美化 \(renders.count) 张")
    }

    // MARK: - 系统图库美化：保存副本到拾光

    /// 系统图库只读：从官方原图渲染美化副本，再作为新照片导入拾光本地图库。
    /// 不修改 Apple 的原图，也不写 `Photos.sqlite`。
    private func applySystemBeauty(to photoIDs: [UUID], strength: Double) async -> BeautyBatchResult {
        guard !isApplyingBeauty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "正在美化其他照片，请稍候")
        }
        let wanted = Set(photoIDs)
        let targets = systemLoadedPhotos.filter {
            wanted.contains($0.id) && !$0.isVideo && $0.deletedAt == nil
        }
        guard !targets.isEmpty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "没有可美化的照片")
        }

        isApplyingBeauty = true
        beautyApplyProgress = 0
        var imported: [PhotoItem] = []
        var skipped = 0

        for (index, photo) in targets.enumerated() {
            if Task.isCancelled { break }
            defer { beautyApplyProgress = Double(index + 1) / Double(targets.count) }
            // 系统图库只从官方原图渲染：拿不到原始路径就跳过，避免误读本地同名文件。
            guard let originalPath = photo.systemOriginalPath else {
                skipped += 1
                continue
            }
            let sourceURL = URL(fileURLWithPath: originalPath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                skipped += 1
                continue
            }
            let advice = await Task.detached(priority: .utility) { () -> BeautyAdvice? in
                guard let image = ImageLoader.thumbnail(for: photo),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    return nil
                }
                return PhotoBeauty.advice(image: cgImage)
            }.value
            guard let advice else {
                skipped += 1
                continue
            }
            let render = await Task.detached(priority: .userInitiated) { () -> (data: Data, width: Int, height: Int)? in
                guard let base = PhotoRenderer.loadBase(url: sourceURL) else { return nil }
                let next = EditState.beautified(EditState(), advice: advice, strength: strength)
                guard let output = PhotoRenderer.renderCG(base: base, state: next, maxPixel: nil),
                      let data = Self.jpegData(from: output) else { return nil }
                return (data, output.width, output.height)
            }.value
            guard let render else {
                skipped += 1
                continue
            }

            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("luma-system-beauty-\(UUID().uuidString).jpg")
            do {
                try render.data.write(to: temp, options: .atomic)
                var item = try ingestService.importLocalFile(temp)
                try? FileManager.default.removeItem(at: temp)
                item.capturedAt = photo.capturedAt
                item.make = photo.make
                item.model = photo.model
                item.lens = photo.lens
                item.iso = photo.iso
                item.aperture = photo.aperture
                item.shutterSpeed = photo.shutterSpeed
                item.focalLength = photo.focalLength
                item.latitude = photo.latitude
                item.longitude = photo.longitude
                item.isFavorite = photo.isFavorite
                item.title = "\(photo.displayTitle)（美化）"
                imported.append(item)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                skipped += 1
            }
        }

        if !imported.isEmpty {
            photos.append(contentsOf: imported)
            persistImported(imported)
            save()
        }
        isApplyingBeauty = false
        beautyApplyProgress = 0
        let message = imported.isEmpty
            ? "没有生成美化副本"
            : "已把 \(imported.count) 张美化副本保存到拾光" + (skipped > 0 ? "，\(skipped) 张跳过" : "")
        showToast(message)
        return BeautyBatchResult(applied: imported.count, skipped: skipped, message: message)
    }

    // MARK: - 网盘美化：保存副本到拾光

    /// 网盘只读：把选中照片下载后按同一套美化参数渲染，再作为新照片导入拾光本地图库。
    /// 网盘原图保持不变。
    private func applyCloudBeauty(to photoIDs: [UUID], strength: Double) async -> BeautyBatchResult {
        guard !isApplyingBeauty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "正在美化其他照片，请稍候")
        }
        let wanted = Set(photoIDs)
        let targets = cloudPhotos.filter { wanted.contains($0.id) && !$0.isVideo }
        guard !targets.isEmpty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "没有可美化的照片")
        }

        isApplyingBeauty = true
        beautyApplyProgress = 0
        var imported: [PhotoItem] = []
        var skipped = 0

        for (index, photo) in targets.enumerated() {
            if Task.isCancelled { break }
            defer { beautyApplyProgress = Double(index + 1) / Double(targets.count) }
            var image = await cloudDisplayImage(for: photo)
            if image == nil {
                image = await cloudThumbnail(for: photo)
            }
            guard let image,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                skipped += 1
                continue
            }
            let advice = await Task.detached(priority: .utility) {
                PhotoBeauty.advice(image: cgImage)
            }.value
            guard let advice else {
                skipped += 1
                continue
            }
            let render = await Task.detached(priority: .userInitiated) { () -> (data: Data, width: Int, height: Int)? in
                let next = EditState.beautified(EditState(), advice: advice, strength: strength)
                guard let output = PhotoRenderer.renderCG(base: CIImage(cgImage: cgImage),
                                                          state: next,
                                                          maxPixel: nil),
                      let data = Self.jpegData(from: output) else { return nil }
                return (data, output.width, output.height)
            }.value
            guard let render else {
                skipped += 1
                continue
            }

            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("luma-cloud-beauty-\(UUID().uuidString).jpg")
            do {
                try render.data.write(to: temp, options: .atomic)
                var item = try ingestService.importLocalFile(temp)
                try? FileManager.default.removeItem(at: temp)
                // 继承拍摄时间与 EXIF，便于在拾光里按日期 / 地点浏览美化副本。
                item.capturedAt = photo.capturedAt
                item.make = photo.make
                item.model = photo.model
                item.lens = photo.lens
                item.iso = photo.iso
                item.aperture = photo.aperture
                item.shutterSpeed = photo.shutterSpeed
                item.focalLength = photo.focalLength
                item.latitude = photo.latitude
                item.longitude = photo.longitude
                item.isFavorite = photo.isFavorite
                item.title = "\(photo.displayTitle)（美化）"
                imported.append(item)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                skipped += 1
            }
        }

        if !imported.isEmpty {
            photos.append(contentsOf: imported)
            persistImported(imported)
            save()
        }
        isApplyingBeauty = false
        beautyApplyProgress = 0
        let message = imported.isEmpty
            ? "没有生成美化副本"
            : "已把 \(imported.count) 张美化副本保存到拾光" + (skipped > 0 ? "，\(skipped) 张跳过" : "")
        showToast(message)
        return BeautyBatchResult(applied: imported.count, skipped: skipped, message: message)
    }

    // MARK: - 系统图库真实写入（PhotoKit）

    /// 只有当前图库就是官方「照片」图库时，才通过 PhotoKit 真实写入原图。
    var canWriteSystemOriginals: Bool {
        isSystemScope && isNativeContainer
    }

    enum SystemBeautyTarget {
        case original
        case copy
        case cancel
    }

    /// 系统图库美化前询问：写回原图（可撤销）还是另存副本。
    func confirmSystemBeautyTarget(count: Int) -> SystemBeautyTarget {
        let alert = NSAlert()
        alert.messageText = "如何保存美化结果？"
        alert.informativeText = "「美化原图」会通过系统照片接口写回，并在「照片」里保留可撤销的调整记录；「保存副本」会在拾光当前图库新建 \(count) 张照片。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "美化原图")
        alert.addButton(withTitle: "保存副本")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .original
        case .alertSecondButtonReturn: return .copy
        default: return .cancel
        }
    }

    /// 通过 PhotoKit 把美化结果写回系统「照片」图库：原图与 Photos 数据库由 Photos 自己更新。
    @discardableResult
    func applyBeautyToSystemOriginals(_ photoIDs: [UUID], strength: Double = 1) async -> BeautyBatchResult {
        guard canWriteSystemOriginals else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count,
                                     message: "只有官方「照片」图库作为当前图库时才可直接改原图")
        }
        guard !isApplyingBeauty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "正在美化其他照片，请稍候")
        }
        guard await PhotoKitBridge.ensureAuthorized() else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count,
                                     message: "需要相册读写权限，请在系统设置中允许拾光访问照片")
        }
        let wanted = Set(photoIDs)
        let targets = systemLoadedPhotos.filter {
            wanted.contains($0.id) && !$0.isVideo && $0.deletedAt == nil
        }
        guard !targets.isEmpty else {
            return BeautyBatchResult(applied: 0, skipped: photoIDs.count, message: "没有可美化的照片")
        }

        isApplyingBeauty = true
        beautyApplyProgress = 0
        var applied = 0
        var skipped = 0

        for (index, photo) in targets.enumerated() {
            if Task.isCancelled { break }
            defer { beautyApplyProgress = Double(index + 1) / Double(targets.count) }
            guard let originalPath = photo.systemOriginalPath else {
                skipped += 1
                continue
            }
            let sourceURL = URL(fileURLWithPath: originalPath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                skipped += 1
                continue
            }
            let advice = await Task.detached(priority: .utility) { () -> BeautyAdvice? in
                guard let image = ImageLoader.thumbnail(for: photo),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    return nil
                }
                return PhotoBeauty.advice(image: cgImage)
            }.value
            guard let advice else {
                skipped += 1
                continue
            }
            let render = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let base = PhotoRenderer.loadBase(url: sourceURL) else { return nil }
                let next = EditState.beautified(EditState(), advice: advice, strength: strength)
                guard let output = PhotoRenderer.renderCG(base: base, state: next, maxPixel: nil) else { return nil }
                return Self.jpegData(from: output)
            }.value
            guard let render else {
                skipped += 1
                continue
            }
            do {
                try await PhotoKitBridge.applyEdit(assetID: photo.id, jpegData: render)
                applied += 1
                ImageLoader.invalidate(photo: photo)
            } catch {
                skipped += 1
            }
        }

        isApplyingBeauty = false
        beautyApplyProgress = 0
        if applied > 0 {
            contentRevision &+= 1
        }
        let message = applied == 0
            ? "没有写回任何照片"
            : "已在「照片」中美化 \(applied) 张" + (skipped > 0 ? "，\(skipped) 张跳过" : "")
        showToast(message)
        return BeautyBatchResult(applied: applied, skipped: skipped, message: message)
    }

    // MARK: - 应用前确认

    /// 批量美化会写入渲染副本，执行前统一弹一次确认（与智能助手工具的确认方式一致）。
    func confirmBeautyApply(count: Int) -> Bool {
        let alert = NSAlert()
        if isCloudScope {
            alert.messageText = "生成美化副本并保存到拾光？"
            alert.informativeText = "网盘为只读：会把 \(count) 张照片的美化结果保存为拾光本地图库的新照片，网盘上的原图不会改变。"
        } else if isSystemScope {
            alert.messageText = "生成美化副本并保存到拾光？"
            alert.informativeText = "系统图库为只读：会把 \(count) 张照片的美化结果保存为拾光本地图库的新照片，「照片」里的原图与编辑不会改变。"
        } else {
            alert.messageText = "生成美化副本？"
            alert.informativeText = "将为 \(count) 张照片生成美化副本。原图与已有编辑都保留，可随时在编辑器的「美化」页撤销。"
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "开始美化")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 渲染与落盘

    private struct BeautyRender: Sendable {
        let id: UUID
        let data: Data
        let width: Int
        let height: Int
        let recipe: String
    }

    /// 纯计算：解码原图 → 叠加美化建议 → 全尺寸渲染成 JPEG。放在后台线程执行。
    nonisolated private static func renderBeauty(checkpoint: [PhotoItem],
                                                 strength: Double) -> [BeautyRender] {
        checkpoint.compactMap { photo in
            guard let advice = PhotoBeauty.advice(for: photo) else { return nil }
            let hasRecipe = photo.hasEdits && photo.editRecipe != nil
            // 有编辑点时从原图重建，避免在已渲染的副本上反复叠加。
            let baseURL = hasRecipe ? LibraryPaths.originalURL(for: photo)
                                    : LibraryPaths.sourceURL(for: photo)
            guard let base = PhotoRenderer.loadBase(url: baseURL) else { return nil }

            var state = hasRecipe ? (photo.editRecipe.flatMap(EditState.init(jsonString:)) ?? EditState())
                                  : EditState()
            if !hasRecipe {
                state.rotation = photo.rotationAngle
            }
            let next = EditState.beautified(state, advice: advice, strength: strength)
            guard let image = PhotoRenderer.renderCG(base: base, state: next, maxPixel: nil),
                  let data = jpegData(from: image),
                  let recipe = next.jsonString else { return nil }
            return BeautyRender(id: photo.id, data: data, width: image.width,
                                height: image.height, recipe: recipe)
        }
    }

    /// 一次写入全部渲染结果与缩略图，只 `save()` 一次。
    private func commitBeautyRenders(_ renders: [BeautyRender]) {
        guard !renders.isEmpty else { return }
        LibraryPaths.prepare()
        for render in renders {
            guard let index = photos.firstIndex(where: { $0.id == render.id }) else { continue }
            let filename = render.id.uuidString + ".jpg"
            let url = LibraryPaths.edited.appendingPathComponent(filename)
            try? render.data.write(to: url, options: .atomic)

            var updated = photos[index]
            updated.editedFilename = filename
            updated.pixelWidth = render.width
            updated.pixelHeight = render.height
            updated.editRecipe = render.recipe
            // 渲染结果已经包含旋转，清掉旋转元数据避免二次旋转。
            updated.rotation = nil
            ImportService.makeImageThumbnail(url: url, destination: LibraryPaths.thumbnailURL(for: updated))
            updated.editVersion += 1
            photos[index] = updated
            ImageLoader.invalidate(photo: updated)
        }
        save()
    }

    // MARK: - 与其它范围的衔接

    /// 在网格中选中一组推荐照片，供「查看」使用：先回到「所有照片」网格再选中。
    func selectBeautyCandidates(_ ids: [UUID]) {
        showBeautyPanel = false
        if isCloudScope {
            setCloudScope(.all)
            selection = Set(ids)
            showToast("已选中 \(ids.count) 张")
            return
        }
        if isSystemScope {
            navigate(to: .systemLibrary)
            selection = Set(ids)
            showToast("已选中 \(ids.count) 张")
            return
        }
        navigate(to: .library)
        selection = Set(ids)
        showToast("已选中 \(ids.count) 张")
    }
}
