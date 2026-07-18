import Foundation
import ServiceManagement

/// 开机自启管理（基于 SMAppService，macOS 13+）
/// 将主 App 注册为登录项，使其常驻运行（Finder Sync 扩展依赖主 App 处理菜单构建与脚本执行）。
final class LoginItemManager {

    static let shared = LoginItemManager()

    private let service = SMAppService.mainApp
    private let firstRunKey = "FWDidInitLoginItem"

    /// 当前是否已启用开机自启
    var isEnabled: Bool {
        service.status == .enabled
    }

    /// 启用开机自启
    func enable() {
        do {
            try service.register()
        } catch {
            NSLog("开机自启注册失败: \(error.localizedDescription)")
        }
    }

    /// 关闭开机自启
    func disable() {
        do {
            try service.unregister()
        } catch {
            NSLog("开机自启注销失败: \(error.localizedDescription)")
        }
    }

    /// 切换开机自启状态
    func toggle() {
        isEnabled ? disable() : enable()
    }

    /// 首次运行时默认开启（仅执行一次）
    func enableOnFirstRunIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: firstRunKey) else { return }

        enable()
        defaults.set(true, forKey: firstRunKey)
    }
}
