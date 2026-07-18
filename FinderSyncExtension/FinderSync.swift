import Foundation
import AppKit
import FinderSync

/// Finder Sync 扩展主类（M3 slice 2：xbar 风格动态多级菜单）
/// 职责（沙箱内）：
///   1. 监控根目录，使右键菜单在任意路径出现
///   2. 右键时同步向主 App 请求「菜单规格」（主 App 跑脚本、解析输出后返回），据此构建多级菜单
///   3. 点击可执行项时，携带 actionId 通知主 App 执行对应动作
/// 说明：扩展不读插件目录、不执行脚本，全部交由非沙箱主 App，规避沙箱限制。
class FinderSync: FIFinderSync {

    /// 同步等待菜单规格的超时时间（秒），避免慢脚本卡住 Finder
    private let buildTimeout: TimeInterval = 2.5

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    /// 右键菜单：向主 App 请求菜单规格并构建
    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")

        let selected = (FIFinderSyncController.default().selectedItemURLs() ?? []).map { $0.path }
        let currentDir = currentDirectoryPath()

        guard let items = requestMenuSpec(currentDir: currentDir, selected: selected), !items.isEmpty else {
            let placeholder = NSMenuItem(title: "Finder Wand", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            return menu
        }

        appendItems(items, to: menu)
        return menu
    }

    // MARK: - 请求菜单规格

    /// 写构建请求、通知主 App、轮询响应，返回菜单项数组
    private func requestMenuSpec(currentDir: String, selected: [String]) -> [[String: Any]]? {
        let containerData = URL(fileURLWithPath: NSHomeDirectory())
        let requestId = UUID().uuidString

        let requestsDir = FWIPC.buildRequestsDirectory(containerDataDirectory: containerData)
        let responsesDir = FWIPC.buildResponsesDirectory(containerDataDirectory: containerData)
        let responseURL = responsesDir.appendingPathComponent("\(requestId).json")

        let request: [String: Any] = [
            "id": requestId,
            "currentDir": currentDir,
            "selected": selected
        ]

        do {
            try FileManager.default.createDirectory(at: requestsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: responsesDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: request, options: [])
            try data.write(to: requestsDir.appendingPathComponent("\(requestId).json"))
        } catch {
            NSLog("FinderWand 扩展: 写构建请求失败 \(error.localizedDescription)")
            return nil
        }

        postDarwinNotification(FWIPC.darwinBuildName)

        return waitForResponse(at: responseURL)
    }

    /// 轮询等待主 App 写出的响应文件
    private func waitForResponse(at responseURL: URL) -> [[String: Any]]? {
        let deadline = Date().addingTimeInterval(buildTimeout)
        let interval: useconds_t = 20_000 // 20ms

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: responseURL.path) {
                defer { try? FileManager.default.removeItem(at: responseURL) }
                guard
                    let data = try? Data(contentsOf: responseURL),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return nil
                }

                return object["items"] as? [[String: Any]]
            }
            usleep(interval)
        }

        return nil
    }

    // MARK: - 构建菜单

    /// 递归把菜单项数组添加到菜单
    private func appendItems(_ items: [[String: Any]], to menu: NSMenu) {
        for item in items {
            if item["separator"] as? Bool == true {
                menu.addItem(.separator())
                continue
            }

            let title = item["title"] as? String ?? ""
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")

            if let children = item["children"] as? [[String: Any]], !children.isEmpty {
                let submenu = NSMenu(title: title)
                appendItems(children, to: submenu)
                menuItem.submenu = submenu
            } else if let actionId = item["actionId"] as? Int {
                menuItem.action = #selector(runAction(_:))
                menuItem.target = self
                menuItem.tag = actionId
            } else {
                menuItem.isEnabled = false
            }

            if item["enabled"] as? Bool == false {
                menuItem.isEnabled = false
            }

            menu.addItem(menuItem)
        }
    }

    // MARK: - 执行动作

    /// 点击可执行项：携带 actionId 通知主 App 执行
    @objc func runAction(_ sender: NSMenuItem) {
        let actionId = sender.tag
        guard actionId != 0 else { return }

        let containerData = URL(fileURLWithPath: NSHomeDirectory())
        let actionsDir = FWIPC.actionRequestsDirectory(containerDataDirectory: containerData)

        do {
            try FileManager.default.createDirectory(at: actionsDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["actionId": actionId], options: [])
            try data.write(to: actionsDir.appendingPathComponent("\(UUID().uuidString).json"))
        } catch {
            NSLog("FinderWand 扩展: 写动作请求失败 \(error.localizedDescription)")
            return
        }

        postDarwinNotification(FWIPC.darwinActionName)
    }

    // MARK: - 辅助

    /// 推断「当前所在目录」：目标是目录则取目标，否则取其父目录
    private func currentDirectoryPath() -> String {
        guard let targeted = FIFinderSyncController.default().targetedURL() else { return "" }

        let isDirectory = (try? targeted.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isDirectory ? targeted.path : targeted.deletingLastPathComponent().path
    }

    /// 发送 Darwin 通知
    private func postDarwinNotification(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true)
    }
}
