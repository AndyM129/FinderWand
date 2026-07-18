import Foundation
import AppKit
import FinderSync

/// Finder Sync 扩展主类（M3 spike 验证用）
/// 监控根目录，使右键菜单在任意路径出现；点击菜单项时向主 App 发送 Darwin 通知。
/// 说明：扩展运行在沙箱内，仅负责菜单 UI 与路径收集，真正的脚本执行后续通过 XPC 委托给非沙箱主 App。
class FinderSync: FIFinderSync {

    override init() {
        super.init()
        // 监控根目录，让右键菜单在任意路径可用
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    /// 提供右键菜单
    /// 覆盖选中项与空白处两种右键场景。
    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "Finder Wand: 测试点位",
                              action: #selector(runSpike(_:)),
                              keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// 点击菜单项：发送 Darwin 通知，主 App 收到后记录日志，验证「扩展 → 主 App」链路
    @objc func runSpike(_ sender: AnyObject?) {
        let name = "io.github.andym129.finder-wand.spike" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil,
            nil,
            true)
    }
}
