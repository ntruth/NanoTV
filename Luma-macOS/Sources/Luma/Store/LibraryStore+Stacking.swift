import Foundation

/// 一次堆叠计算的结果：谁归到谁、每堆的成员，以及这堆是否来自「照片」的连拍组。
struct StackPlan {
    struct Group {
        /// 代表图（连拍优先用「照片」里的键照片）。
        let representative: PhotoItem
        /// 整组成员，按当前显示顺序排列（含代表图本身）。
        let members: [PhotoItem]
        /// 连拍组双击打开查看器做整组浏览；同场景堆叠双击在原地展开。
        let isBurst: Bool
    }

    /// 代表图 id → 整组。
    var groups: [UUID: Group] = [:]
    /// 成员 id → 代表图 id（代表图自身也映射到自己）。
    var representativeID: [UUID: UUID] = [:]

    var isEmpty: Bool { groups.isEmpty }
}

/// 网格的堆叠浏览：把连拍组与同场景连拍收成一张代表图，角标显示张数，展开后原地铺开整组。
extension LibraryStore {
    /// 同场景归并参数：相邻两张间隔 ≤ 2 秒、一组最多 10 张、整组跨度 ≤ 8 秒。
    /// 与「照片」的堆叠一致：宁可少并，也不要把一段连续拍摄全部吞成一大摞。
    private static let sceneGap: TimeInterval = 2
    private static let sceneMaxCount = 10
    private static let sceneMaxSpan: TimeInterval = 8

    var isStackingEnabled: Bool { stackMode != .off }

    /// 网格实际显示的照片：堆叠关闭时原样返回。
    /// 收起时只保留代表图；已展开的堆叠把整组成员按显示顺序铺在代表图后面。
    func stackedPhotos(_ items: [PhotoItem]) -> [PhotoItem] {
        guard stackMode != .off else { return items }
        let plan = stackPlan()
        guard !plan.isEmpty else { return items }
        let available = Set(items.map(\.id))
        var result: [PhotoItem] = []
        result.reserveCapacity(items.count)
        var emitted = Set<UUID>()
        for item in items {
            // 代表图不在本段里（分段 / 窗口边界）时按普通照片显示，不能把成员吞掉。
            guard let representative = plan.representativeID[item.id],
                  available.contains(representative) else {
                result.append(item)
                continue
            }
            // 成员只跟着代表图出现一次。
            guard item.id == representative else { continue }
            guard emitted.insert(representative).inserted else { continue }
            result.append(item)
            guard expandedStackIDs.contains(representative),
                  let group = plan.groups[representative] else { continue }
            for member in group.members where member.id != representative {
                result.append(member)
            }
        }
        return result
    }

    /// 当前可见集合的堆叠计划：按可见集合指纹与模式缓存，滚动 / 选中不重算。
    func stackPlan() -> StackPlan {
        guard stackMode != .off else { return StackPlan() }
        let key = visibleStateKey + "\u{1F}" + stackMode.rawValue
        if stackPlanCacheKey == key, let cached = stackPlanCache { return cached }
        let plan = buildStackPlan(visiblePhotos, mode: stackMode)
        stackPlanCacheKey = key
        stackPlanCache = plan
        return plan
    }

    /// 一张照片所在堆叠的张数：不是堆叠时返回 1。
    func stackCount(for photoID: UUID) -> Int {
        guard stackMode != .off else { return 1 }
        let plan = stackPlan()
        guard let representative = plan.representativeID[photoID],
              let group = plan.groups[representative] else { return 1 }
        return group.members.count
    }

    /// 网格一次算好的堆叠角标表：代表图 id → 张数与是否连拍。
    /// 单元格只查字典，不再逐格计算可见集合指纹。
    struct StackBadge {
        let count: Int
        let isBurst: Bool
    }

    func stackBadges() -> [UUID: StackBadge] {
        guard stackMode != .off else { return [:] }
        let plan = stackPlan()
        var badges: [UUID: StackBadge] = [:]
        badges.reserveCapacity(plan.groups.count)
        for (id, group) in plan.groups {
            badges[id] = StackBadge(count: group.members.count, isBurst: group.isBurst)
        }
        return badges
    }

    /// 这张照片所在的堆叠是否来自连拍组（决定双击是打开查看器还是原地展开）。
    func stackIsBurst(_ photoID: UUID) -> Bool {
        guard stackMode != .off else { return false }
        let plan = stackPlan()
        guard let representative = plan.representativeID[photoID] else { return false }
        return plan.groups[representative]?.isBurst ?? false
    }

    func isStackExpanded(_ photoID: UUID) -> Bool {
        expandedStackIDs.contains(photoID)
    }

    /// 展开 / 收起同一堆照片；传代表图或任意成员都可以。
    func toggleStackExpansion(_ photoID: UUID) {
        guard stackMode != .off else { return }
        let plan = stackPlan()
        let representative = plan.representativeID[photoID] ?? photoID
        guard (plan.groups[representative]?.members.count ?? 0) > 1 else { return }
        if expandedStackIDs.contains(representative) {
            expandedStackIDs.remove(representative)
        } else {
            expandedStackIDs.insert(representative)
        }
        stackRevision &+= 1
    }

    /// 一键收起所有已展开的堆叠（切换范围后也用它重置视野）。
    func collapseAllStacks() {
        guard !expandedStackIDs.isEmpty else { return }
        expandedStackIDs.removeAll()
        stackRevision &+= 1
    }

    // MARK: - 内部

    private func buildStackPlan(_ items: [PhotoItem], mode: StackMode) -> StackPlan {
        var plan = StackPlan()
        guard !items.isEmpty else { return plan }

        // 1. 连拍组：同一连拍组 ID 收成一堆，代表图优先用「照片」里的键照片。
        var burstBuckets: [String: [PhotoItem]] = [:]
        for item in items {
            guard let group = item.burstGroupID, !group.isEmpty else { continue }
            burstBuckets[group, default: []].append(item)
        }
        for members in burstBuckets.values {
            guard members.count > 1 else { continue }
            let representative = members.first(where: { $0.isBurstKeyPhoto }) ?? members[0]
            register(StackPlan.Group(representative: representative,
                                     members: members,
                                     isBurst: true), into: &plan)
        }

        guard mode == .scenes else { return plan }
        // 同场景只在按拍摄时间排序时有意义；其它排序下「相邻」不代表同一场景。
        guard sortKey == .capturedAt else { return plan }

        // 2. 同场景：按显示顺序把时间上紧邻的照片串成一堆。
        //    连拍成员已归堆，视频不作为同场景成员（避免把长视频卷进照片堆里）。
        let calendar = Calendar.current
        var run: [PhotoItem] = []
        func flush() {
            let group = run
            run.removeAll(keepingCapacity: true)
            guard group.count > 1 else { return }
            register(StackPlan.Group(representative: group[0],
                                     members: group,
                                     isBurst: false), into: &plan)
        }
        for item in items {
            if item.isVideo || (item.burstGroupID?.isEmpty == false) {
                flush()
                continue
            }
            guard let last = run.last else {
                run = [item]
                continue
            }
            let gap = abs(item.capturedAt.timeIntervalSince(last.capturedAt))
            let span = abs(item.capturedAt.timeIntervalSince(run[0].capturedAt))
            let sameDay = calendar.isDate(item.capturedAt, inSameDayAs: last.capturedAt)
            // gap > 0：批量导入时大量素材可能共用同一个时间戳，不能把它们卷成一摞。
            if gap > 0, gap <= Self.sceneGap, span <= Self.sceneMaxSpan,
               run.count < Self.sceneMaxCount, sameDay {
                run.append(item)
            } else {
                flush()
                run = [item]
            }
        }
        flush()
        return plan
    }

    private func register(_ group: StackPlan.Group, into plan: inout StackPlan) {
        guard group.members.count > 1 else { return }
        plan.groups[group.representative.id] = group
        for member in group.members {
            plan.representativeID[member.id] = group.representative.id
        }
    }
}
