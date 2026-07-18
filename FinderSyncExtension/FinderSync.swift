import Foundation
import AppKit
import FinderSync

/// Finder Sync 扩展主类（M3 slice 1）
/// 职责（沙箱内）：
///   1. 监控根目录，使右键菜单在任意路径出现
///   2. 读取主 App 生成的插件清单（位于扩展容器内，无需额外权限），每个 `.sh` 作为一级菜单项
///   3. 点击菜单项时，收集当前路径与选中项，写入 IPC 请求并通知主 App 执行
/// 说明：扩展不直接读插件目录、也不执行脚本，全部交由非沙箱主 App，规避沙箱限制。
class FinderSync: FIFinderSync {

    override init() {
        super.init()
        // 监控根目录，让右键菜单在任意路径可用
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        // 启动时请求主 App 生成一次清单
        postRefreshRequest()
    }

    /// 提供右键菜单：每个 `.sh` 一个一级菜单项
    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        let scripts = manifestScripts()

        guard !scripts.isEmpty else {
            // 清单为空：请求主 App 重新生成，本次先占位
            postRefreshRequest()
            let empty = NSMenuItem(title: "Finder Wand: 无插件", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for script in scripts {
            let item = NSMenuItem(title: script.name,
                                  action: #selector(runPlugin(_:)),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        return menu
    }

    /// 从扩展容器读取主 App 生成的插件清单
    private func manifestScripts() -> [(name: String, path: String)] {
        let containerData = URL(fileURLWithPath: NSHomeDirectory())
        let manifest = FWIPC.manifestFile(containerDataDirectory: containerData)

        guard
            let data = try? Data(contentsOf: manifest),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else {
            return []
        }

        return array.compactMap { entry in
            guard let name = entry["name"], let path = entry["path"] else { return nil }
            return (name, path)
        }
    }

    /// 点击插件菜单项：收集上下文写入 IPC 请求，并通知主 App 执行
    @objc func runPlugin(_ sender: NSMenuItem) {
        // 用菜单项标题回查清单获取脚本路径
        // 注意：representedObject 可能无法跨 Finder Sync 的 XPC 存活，title 可靠。
        let name = sender.title
        guard let script = manifestScripts().first(where: { $0.name == name }) else {
            NSLog("FinderWand 扩展: 未在清单中找到菜单项 \(name)")
            return
        }

        let selected = (FIFinderSyncController.default().selectedItemURLs() ?? []).map { $0.path }
        let currentDir = currentDirectoryPath()

        let request: [String: Any] = [
            "script": script.path,
            "currentDir": currentDir,
            "selected": selected
        ]

        writeRequest(request)
        postDarwinNotification(FWIPC.darwinActionName)
    }

    /// 推断「当前所在目录」：目标是目录则取目标，否则取其父目录
    private func currentDirectoryPath() -> String {
        guard let targeted = FIFinderSyncController.default().targetedURL() else { return "" }

        let isDirectory = (try? targeted.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isDirectory ? targeted.path : targeted.deletingLastPathComponent().path
    }

    /// 将请求写入扩展容器内的 IPC 目录（主 App 可读取该路径）
    private func writeRequest(_ request: [String: Any]) {
        let containerData = URL(fileURLWithPath: NSHomeDirectory())
        let requestsDir = FWIPC.requestsDirectory(containerDataDirectory: containerData)

        do {
            try FileManager.default.createDirectory(at: requestsDir, withIntermediateDirectories: true)
            let fileURL = requestsDir.appendingPathComponent("\(UUID().uuidString).json")
            let data = try JSONSerialization.data(withJSONObject: request, options: [])
            try data.write(to: fileURL)
        } catch {
            NSLog("写入 IPC 请求失败: \(error.localizedDescription)")
        }
    }

    /// 请求主 App 重新生成插件清单
    private func postRefreshRequest() {
        postDarwinNotification(FWIPC.darwinRefreshName)
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
