import AppKit

/// 应用委托
/// 负责在启动时创建菜单栏控制器。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 菜单栏控制器，需强引用持有
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
        // 监听 Finder Sync 扩展的菜单构建与动作请求
        PluginService.shared.start()
    }
}
