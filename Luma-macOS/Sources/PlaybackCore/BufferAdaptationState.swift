import Foundation

/// 远端播放的缓冲自适应：按实测吞吐与生成领先量，在当前档位与更低档位之间切换。
///
/// 设计约束：
/// - 只降不升超过用户所选档位：设置里的「流畅 / 均衡 / 省流」是上限，不是起点。
/// - 只在有实测吞吐（远端 Range 代理）时工作；本地盘 / SMB 不走这条链路。
/// - 带滞回与冷却时间，避免在网络抖动时来回切档。
public struct BufferAdaptationState {
    /// 连续多少轮「吞吐不够」才降档。
    public var lowThreshold = 2
    /// 连续多少轮「吞吐富余且领先充足」才升档。
    public var highThreshold = 3
    /// 两次切档之间的最小间隔（秒）。
    public let cooldown: TimeInterval

    private var lowStreak = 0
    private var highStreak = 0
    private var lastChangeAt: Date

    public init(cooldown: TimeInterval = 20) {
        self.cooldown = cooldown
        // 允许起播后第一次判定立即生效；之后才进入冷却。
        self.lastChangeAt = .distantPast
    }

    /// 返回建议的新档位；nil 表示维持当前档位。
    ///
    /// - `current`: 当前生效档位（可能已经被降过）。
    /// - `ceiling`: 用户在设置里选的档位，永远是升档上限。
    /// - `throughputBps`: Range 代理实测下载吞吐（bit/s）。
    /// - `requiredBps`: 当前生成内容的平均码率（bit/s）。
    /// - `leadSeconds`: 已生成内容领先播放位置的秒数。
    public mutating func evaluate(current: BufferProfile,
                                  ceiling: BufferProfile,
                                  throughputBps: Double,
                                  requiredBps: Double,
                                  leadSeconds: Double,
                                  now: Date = Date()) -> BufferProfile? {
        guard throughputBps > 0, requiredBps > 0 else { return nil }

        // 领先量不足时，即使吞吐看起来够，也按「不够」处理：解码/封装也可能拖慢。
        let low = leadSeconds < 5 || throughputBps < requiredBps * 0.85
        let high = leadSeconds > 120 && throughputBps > requiredBps * 1.8
        lowStreak = low ? lowStreak + 1 : 0
        highStreak = high ? highStreak + 1 : 0

        guard now.timeIntervalSince(lastChangeAt) >= cooldown else { return nil }

        if lowStreak >= lowThreshold, let lower = current.downgraded() {
            reset(now: now)
            return lower
        }
        if highStreak >= highThreshold,
           let higher = current.upgraded(),
           higher.rank <= ceiling.rank {
            reset(now: now)
            return higher
        }
        return nil
    }

    private mutating func reset(now: Date) {
        lowStreak = 0
        highStreak = 0
        lastChangeAt = now
    }
}
