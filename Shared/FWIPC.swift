import Foundation

/// 主 App 与 Finder Sync 扩展共享的 IPC 常量与路径工具
/// 该文件同时编译进主 App 与扩展两个 target，避免常量不一致。
enum FWIPC {

    /// 扩展点击菜单后，通知主 App 处理请求的 Darwin 通知名
    static let darwinActionName = "io.github.andym129.finder-wand.action"

    /// 扩展请求主 App 重新生成插件清单的 Darwin 通知名
    static let darwinRefreshName = "io.github.andym129.finder-wand.refresh"

    /// 插件目录：真实 home 下的 ~/.config/FinderWand
    /// 注意：沙箱扩展中 `NSHomeDirectory()` / `homeDirectoryForCurrentUser` 返回的是容器路径，
    /// 这里用 `getpwuid` 取真实 home，配合 `home-relative-path` 读权限例外即可访问。
    static var pluginDirectory: URL {
        URL(fileURLWithPath: realHomeDirectory, isDirectory: true)
            .appendingPathComponent(".config/FinderWand", isDirectory: true)
    }

    /// 真实 home 目录（沙箱下也返回 /Users/xxx，而非容器路径）
    static var realHomeDirectory: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }

        return NSHomeDirectory()
    }

    /// 给定「扩展容器 Data 目录」，返回 IPC 请求目录
    /// - 扩展侧：容器 Data 目录为 `NSHomeDirectory()`
    /// - 主 App 侧：为 `~/Library/Containers/<扩展BundleID>/Data`
    static func requestsDirectory(containerDataDirectory: URL) -> URL {
        ipcDirectory(containerDataDirectory: containerDataDirectory)
            .appendingPathComponent("requests", isDirectory: true)
    }

    /// 插件清单文件：由主 App 生成、扩展读取，避免沙箱扩展直接读插件目录
    static func manifestFile(containerDataDirectory: URL) -> URL {
        ipcDirectory(containerDataDirectory: containerDataDirectory)
            .appendingPathComponent("manifest.json")
    }

    /// IPC 根目录（位于扩展容器内）
    private static func ipcDirectory(containerDataDirectory: URL) -> URL {
        containerDataDirectory
            .appendingPathComponent("Library/Application Support/FinderWandIPC", isDirectory: true)
    }
}
