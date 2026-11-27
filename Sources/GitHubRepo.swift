import Foundation

/// GitHub 仓库地址的解析、校验与 URL 拼接（纯逻辑，便于单元测试）
/// 用户输入的 owner/repo 和接口返回的分支名都会拼进 URL，这里统一校验和编码，
/// 不合法时返回 nil，由调用方给出错误提示，避免 `URL(string:)!` 强制解包崩溃。
enum GitHubRepo {

    /// 解析仓库输入：支持 `owner/repo` 或 `https://github.com/owner/repo(.git)`
    /// owner 或 repo 含 GitHub 不允许的字符时返回 nil。
    static func parse(_ raw: String) -> (owner: String, repo: String)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        // 去掉协议与主机
        if let range = text.range(of: "github.com/") {
            text = String(text[range.upperBound...])
        }
        // 去掉查询/锚点
        text = text.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? text

        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }

        let owner = parts[0]
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }

        guard isValidOwner(owner), isValidRepoName(repo) else { return nil }

        return (owner, repo)
    }

    /// 仓库信息接口地址；参数不合法时返回 nil
    static func apiURL(owner: String, repo: String) -> URL? {
        guard isValidOwner(owner), isValidRepoName(repo) else { return nil }

        return URL(string: "https://api.github.com/repos/\(owner)/\(repo)")
    }

    /// 分支源码 tarball 下载地址；参数不合法时返回 nil
    /// 分支名可含 `/`（如 `feature/x`），保留为路径分隔符，其余字符按路径规则百分号编码。
    static func tarballURL(owner: String, repo: String, branch: String) -> URL? {
        guard isValidOwner(owner), isValidRepoName(repo), isValidBranch(branch),
              let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }

        return URL(string: "https://codeload.github.com/\(owner)/\(repo)/tar.gz/refs/heads/\(encodedBranch)")
    }

    /// GitHub 用户名 / 组织名：字母数字与 `-`，1 到 39 个字符，不以 `-` 开头或结尾
    static func isValidOwner(_ owner: String) -> Bool {
        guard (1...39).contains(owner.count), !owner.hasPrefix("-"), !owner.hasSuffix("-") else { return false }

        return owner.unicodeScalars.allSatisfy { ownerAllowed.contains($0) }
    }

    /// GitHub 仓库名：字母数字与 `.` `_` `-`，1 到 100 个字符，不能是 `.` 或 `..`
    static func isValidRepoName(_ repo: String) -> Bool {
        guard (1...100).contains(repo.count), repo != ".", repo != ".." else { return false }

        return repo.unicodeScalars.allSatisfy { repoAllowed.contains($0) }
    }

    /// 分支名：非空，不含控制字符、空白、`?` `#` `\`，各段不为空、`.` 或 `..`
    static func isValidBranch(_ branch: String) -> Bool {
        guard !branch.isEmpty else { return false }

        let forbidden = CharacterSet.controlCharacters
            .union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "?#\\"))
        guard branch.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return false }

        let segments = branch.split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static let ownerAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

    private static let repoAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
}
