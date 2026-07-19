import Foundation
import UserNotifications

/// 轻量系统通知封装
/// 用于在菜单栏操作（如切换插件启用态）后给出非打扰式的结果提示。
/// 关键点：菜单栏 App 在被点击后即为「活跃 App」，此时系统默认会把通知直接收进通知中心而不弹横幅；
/// 通过实现 `UNUserNotificationCenterDelegate` 的 willPresent 回调，强制在前台也弹出横幅。
final class UserNotifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = UserNotifier()

    /// 在 App 启动时调用：设置通知代理并申请权限
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 发送一条系统通知（未授权时系统会静默忽略）
    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// App 处于前台时也以横幅 + 声音展示，避免通知被直接收进通知中心
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
