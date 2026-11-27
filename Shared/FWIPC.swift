import Foundation

/// 主 App 与 Finder Sync 扩展共享的 IPC 常量与路径工具
/// 该文件同时编译进主 App 与扩展两个 target，避免常量不一致。
///
/// slice 2 通道说明（xbar 风格动态菜单）：
///   - 构建菜单：扩展写 build 请求并轮询 build 响应；主 App 收到 build 通知后跑脚本、解析、写响应。
///   - 执行动作：扩展写 action 请求并发 action 通知；主 App 执行对应动作。
/// 所有 IPC 文件都位于「扩展沙箱容器」内，扩展读写自己的容器无需额外权限，主 App（非沙箱）可读写该容器路径。
enum FWIPC {

    /// 扩展请求主 App 构建右键菜单的 Darwin 通知名
    static let darwinBuildName = "io.github.andym129.finder-wand.build"

    /// 扩展请求主 App 执行某个菜单动作的 Darwin 通知名
    static let darwinActionName = "io.github.andym129.finder-wand.action"

    /// 扩展同步等待菜单规格的超时时间（秒）
    /// 主 App 据此判断构建请求是否已过期（扩展已放弃等待），过期请求不再执行插件。
    static let buildTimeout: TimeInterval = 2.5

    /// 插件目录：真实 home 下的 ~/.config/FinderWand
    /// 注意：沙箱扩展中 `NSHomeDirectory()` / `homeDirectoryForCurrentUser` 返回的是容器路径，
    /// 主 App（非沙箱）用它枚举脚本；扩展不直接读该目录。
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

    /// 构建请求目录（扩展写、主 App 读）
    static func buildRequestsDirectory(containerDataDirectory: URL) -> URL {
        ipcDirectory(containerDataDirectory: containerDataDirectory)
            .appendingPathComponent("build-requests", isDirectory: true)
    }

    /// 构建响应目录（主 App 写、扩展读）
    static func buildResponsesDirectory(containerDataDirectory: URL) -> URL {
        ipcDirectory(containerDataDirectory: containerDataDirectory)
            .appendingPathComponent("build-responses", isDirectory: true)
    }

    /// 动作请求目录（扩展写、主 App 读）
    static func actionRequestsDirectory(containerDataDirectory: URL) -> URL {
        ipcDirectory(containerDataDirectory: containerDataDirectory)
            .appendingPathComponent("action-requests", isDirectory: true)
    }

    /// IPC 根目录（位于扩展容器内）
    private static func ipcDirectory(containerDataDirectory: URL) -> URL {
        containerDataDirectory
            .appendingPathComponent("Library/Application Support/FinderWandIPC", isDirectory: true)
    }
}
