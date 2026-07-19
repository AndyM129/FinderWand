import Foundation
import UserNotifications

/// 轻量系统通知封装
/// 用于在菜单栏操作（如安装插件、切换启用态）后给出非打扰式的提示。
/// 两个关键处理：
///   1. 菜单栏 App 被点击后即为「活跃 App」，系统默认会把通知直接收进通知中心而不弹横幅；
///      通过 `UNUserNotificationCenterDelegate` 的 willPresent 回调强制前台也弹横幅。
///   2. 系统对同一 App 短时间连发的横幅有节流，会把后一条折叠进通知中心；
///      因此用串行队列 + 最小间隔错开投递，保证连续的「进度 → 结果」两条都能弹出。
final class UserNotifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = UserNotifier()

    /// 串行投递队列，保证按序且可插入间隔
    private let queue = DispatchQueue(label: "io.github.andym129.finder-wand.notifier")

    /// 上一条通知的投递时间
    private var lastDeliveredAt = Date.distantPast

    /// 两条通知之间的最小间隔（秒），避免被系统节流折叠
    private let minInterval: TimeInterval = 0.8

    /// 在 App 启动时调用：设置通知代理并申请权限
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 发送一条系统通知（未授权时系统会静默忽略）
    /// 若与上一条间隔过近，会自动延迟到满足最小间隔后再投递。
    static func notify(title: String, body: String) {
        shared.enqueue(title: title, body: body)
    }

    private func enqueue(title: String, body: String) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let elapsed = Date().timeIntervalSince(self.lastDeliveredAt)
            if elapsed < self.minInterval {
                Thread.sleep(forTimeInterval: self.minInterval - elapsed)
            }
            self.lastDeliveredAt = Date()

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body

            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    /// App 处于前台时也以横幅 + 声音展示，避免通知被直接收进通知中心
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
