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
        // 配置系统通知（设置代理 + 申请权限），确保前台也能弹出横幅
        UserNotifier.shared.configure()
        // 刚由一键更新换上的新版本：提示已更新
        UpdateInstaller.shared.announceIfUpdated()
        // 首次运行默认开启开机自启
        LoginItemManager.shared.enableOnFirstRunIfNeeded()
        // 自动静默检查更新，发现新版本时通知
        UpdateChecker.shared.startAutomaticChecks()

        #if DEBUG
        // 调试：启动参数 `-FWDebugCheckUpdateOnLaunch YES` 时启动后直接检查更新，便于验证「软件更新」窗口
        if UserDefaults.standard.bool(forKey: "FWDebugCheckUpdateOnLaunch") {
            menuBarController?.checkForUpdates()
        }
        #endif
    }
}
