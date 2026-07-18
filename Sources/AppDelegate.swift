import AppKit

/// 应用委托
/// 负责创建并管理菜单栏状态项（NSStatusItem）及其下拉菜单。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 菜单栏状态项，需强引用持有，否则会被释放导致图标消失
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
    }

    /// 创建菜单栏图标与下拉菜单
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // 暂用系统符号作为占位图标，后续里程碑替换为品牌图标
            button.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Finder Wand")
        }
        item.menu = makeMenu()
        statusItem = item
    }

    /// 构建菜单栏下拉菜单
    /// M0 仅提供退出项，其余菜单项在 M2 补全。
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let quitItem = NSMenuItem(title: "退出 Finder Wand", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// 退出应用
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
