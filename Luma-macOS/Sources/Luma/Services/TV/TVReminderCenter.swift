import Foundation
import UserNotifications

/// 节目预约：用系统本地通知在节目开播时提醒。
/// 通知由系统持久化，App 重启后仍然有效；这里只负责排期与取消。
@MainActor
final class TVReminderCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TVReminderCenter()

    /// 没有 App Bundle（例如命令行直接跑可执行文件）时系统通知不可用。
    private let isAvailable = Bundle.main.bundleIdentifier != nil
    private var center: UNUserNotificationCenter?

    private override init() {
        super.init()
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        self.center = center
    }

    /// 排一条开播提醒；返回是否成功排上。
    func schedule(channel: TVChannel, program: TVEPGProgram) async -> Bool {
        guard let center else { return false }
        guard await ensureAuthorization(center) else { return false }
        let fireAt = program.start
        // 已经开播的节目不排提醒（回看另有入口）。
        guard fireAt > Date().addingTimeInterval(1) else { return false }

        let content = UNMutableNotificationContent()
        content.title = "《\(program.title)》即将开始"
        content.body = "\(channel.name) · \(Self.clockFormatter.string(from: program.start))"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, fireAt.timeIntervalSinceNow),
            repeats: false)
        let request = UNNotificationRequest(identifier: Self.identifier(program.id),
                                            content: content,
                                            trigger: trigger)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func cancel(programID: String) {
        center?.removePendingNotificationRequests(withIdentifiers: [Self.identifier(programID)])
    }

    private func ensureAuthorization(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    /// 前台也把提醒显示成横幅，避免用户正在用拾光时错过。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private static func identifier(_ programID: String) -> String {
        "luma.tv.reminder.\(programID)"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
