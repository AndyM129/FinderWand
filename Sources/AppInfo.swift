import Foundation

/// 应用信息
/// 集中提供版本号、构建渠道、仓库地址、插件目录等只读信息。
enum AppInfo {

    /// GitHub 仓库主页
    static let repositoryURL = URL(string: "https://github.com/AndyM129/FinderWand")!

    /// GitHub 仓库归属与名称（用于 Releases API）
    static let repositoryOwner = "AndyM129"
    static let repositoryName = "FinderWand"

    /// 最新正式版 Release 的 API 地址（自动排除 prerelease）
    static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest")!
    }

    /// 插件目录：~/.config/FinderWand
    static var pluginDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/FinderWand", isDirectory: true)
    }

    /// 版本号，如 0.1.0
    static var shortVersion: String {
        infoValue("CFBundleShortVersionString") ?? "0.0.0"
    }

    /// 构建渠道：stable(正式版) / beta(测试版) / dev(本地开发构建，未注入渠道)
    static var channel: String {
        infoValue("FWBuildChannel") ?? "dev"
    }

    /// 构建时的 git 短哈希（由打包脚本注入）
    static var gitCommit: String {
        infoValue("FWGitCommit") ?? ""
    }

    /// 构建时间戳（由打包脚本注入，格式 yyyyMMddHHmmss）
    static var buildTimestamp: String {
        infoValue("FWBuildTimestamp") ?? ""
    }

    /// 供菜单显示的版本描述
    /// - 正式版：`v0.1.0`
    /// - 测试版：`v0.1.0（beta-<短哈希>-<时间戳>）`
    /// - 本地开发：`v0.1.0（dev）`
    static var displayVersion: String {
        switch channel {
        case "stable":
            return "v\(shortVersion)"
        case "beta":
            return "v\(shortVersion)（beta-\(gitCommit)-\(buildTimestamp)）"
        default:
            return "v\(shortVersion)（dev）"
        }
    }

    /// 菜单「关于」标题里括号内的版本描述（放进半角括号，内部不再嵌套括号）
    /// - 正式版：`v0.1.0`
    /// - 测试版：`v0.1.0 beta-<短哈希>`
    /// - 本地开发：`v0.1.0 dev`
    static var aboutVersion: String {
        switch channel {
        case "stable":
            return "v\(shortVersion)"
        case "beta":
            return "v\(shortVersion) beta-\(gitCommit)"
        default:
            return "v\(shortVersion) dev"
        }
    }

    /// 当前版本对应的 Release tag
    /// - 正式版：`v0.1.0`
    /// - 测试版：`v0.1.0-beta-<短哈希>-<时间戳>`（与打包脚本产出的 tag 一致）
    /// - 本地开发：无对应 Release，返回 nil
    static var releaseTag: String? {
        switch channel {
        case "stable":
            return "v\(shortVersion)"
        case "beta":
            return "v\(shortVersion)-beta-\(gitCommit)-\(buildTimestamp)"
        default:
            return nil
        }
    }

    /// 当前版本对应的 Release 页地址
    /// 有对应 tag 时打开该 tag 的 Release 页，否则打开 Releases 列表页。
    static var releaseURL: URL {
        guard let tag = releaseTag else {
            return repositoryURL.appendingPathComponent("releases")
        }

        return repositoryURL.appendingPathComponent("releases/tag/\(tag)")
    }

    /// 读取 Info.plist 中的字符串字段
    private static func infoValue(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
