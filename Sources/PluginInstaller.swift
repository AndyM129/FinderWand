import Foundation

/// 插件安装器（主 App 侧，非沙箱）
/// 支持三种来源：插件市场按 id、指定 GitHub 仓库、本地目录导入。
/// 统一产出「暂存目录中的插件文件夹」，再由调用方按「全新安装 / 备份后整体替换 / 覆盖安装」写入插件目录。
enum PluginInstaller {

    /// 插件市场仓库信息
    static let marketOwner = "AndyM129"
    static let marketRepo = "FinderWand-Plugins"
    static let marketBranch = "master"

    /// 拉取并校验的结果（尚未写入插件目录）
    enum FetchResult {
        /// 校验通过：插件已暂存到 stagedURL（其内为该插件文件夹内容），落地文件夹名为 id
        case success(stagedURL: URL, id: String, alreadyInstalled: Bool)
        /// 失败，附带面向用户的说明
        case failure(String)
    }

    // MARK: - 三种来源

    /// 从插件市场按 id 拉取
    static func fetchFromMarket(id rawId: String) -> FetchResult {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeSlug(id) else { return .failure("插件 ID 不合法") }

        guard let staging = makeStaging(id: id) else { return .failure("创建临时目录失败") }

        let tarball = staging.root.appendingPathComponent("src.tar.gz")
        if let message = downloadTarball(owner: marketOwner, repo: marketRepo, branch: marketBranch, to: tarball) {
            cleanup(staging.root)
            return .failure(message)
        }

        // 只解出根目录下的 <id> 文件夹：strip 顶层仓库目录(1) + 子目录(1) = 2
        let member = "\(marketRepo)-\(marketBranch)/\(id)"
        let status = runTool("/usr/bin/tar",
                             ["-xz", "-f", tarball.path, "-C", staging.staged.path, "--strip-components=2", member])
        if status != 0 || isEmptyDir(staging.staged) {
            cleanup(staging.root)
            return .failure("插件市场中未找到插件「\(id)」")
        }

        return validateStaged(staging.staged, id: id)
    }

    /// 从指定 GitHub 仓库拉取整仓，落地文件夹名为仓库名
    static func fetchFromRepo(input rawInput: String) -> FetchResult {
        guard let (owner, repo) = GitHubRepo.parse(rawInput) else {
            return .failure("仓库地址不合法，请输入 owner/repo 或完整 GitHub 地址")
        }

        let id = repo
        guard isSafeSlug(id) else { return .failure("仓库名不能作为插件文件夹名（含非法字符）") }

        // 取默认分支
        let branchResult = fetchDefaultBranch(owner: owner, repo: repo)
        guard let branch = branchResult.branch else {
            return .failure(branchResult.error ?? "获取仓库信息失败")
        }

        guard let staging = makeStaging(id: id) else { return .failure("创建临时目录失败") }

        let tarball = staging.root.appendingPathComponent("src.tar.gz")
        if let message = downloadTarball(owner: owner, repo: repo, branch: branch, to: tarball) {
            cleanup(staging.root)
            return .failure(message)
        }

        // 解出整个顶层目录内容：strip 顶层仓库目录(1)
        let member = "\(repo)-\(branch)"
        let status = runTool("/usr/bin/tar",
                             ["-xz", "-f", tarball.path, "-C", staging.staged.path, "--strip-components=1", member])
        if status != 0 || isEmptyDir(staging.staged) {
            cleanup(staging.root)
            return .failure("拉取仓库内容失败")
        }

        return validateStaged(staging.staged, id: id)
    }

    /// 从本地目录导入，落地文件夹名为所选目录名
    static func importFromDirectory(_ source: URL) -> FetchResult {
        let id = source.lastPathComponent
        guard isSafeSlug(id) else { return .failure("目录名不能作为插件文件夹名（含非法字符）") }

        guard let staging = makeStaging(id: id) else { return .failure("创建临时目录失败") }

        // 把所选目录的内容拷进暂存目录
        let status = runTool("/usr/bin/ditto", [source.path, staging.staged.path])
        if status != 0 || isEmptyDir(staging.staged) {
            cleanup(staging.root)
            return .failure("导入目录失败")
        }

        return validateStaged(staging.staged, id: id)
    }

    // MARK: - 写入插件目录

    /// 全新安装：把暂存目录移动到插件目录
    @discardableResult
    static func installFresh(stagedURL: URL, id: String) -> Bool {
        let dest = AppInfo.pluginDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: AppInfo.pluginDirectory, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(at: stagedURL, to: dest)
            cleanup(stagedURL.deletingLastPathComponent())
            return true
        } catch {
            NSLog("安装插件失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 备份后整体替换：现有文件夹压缩为 <id>-bak<时间戳>.zip（放插件目录根），再整体替换
    @discardableResult
    static func backupThenReplace(stagedURL: URL, id: String) -> Bool {
        let dest = AppInfo.pluginDirectory.appendingPathComponent(id, isDirectory: true)
        let backupZip = AppInfo.pluginDirectory.appendingPathComponent("\(id)-bak\(timestamp()).zip")

        let zipStatus = runTool("/usr/bin/ditto",
                                ["-c", "-k", "--sequesterRsrc", "--keepParent", dest.path, backupZip.path])
        if zipStatus != 0 {
            NSLog("备份插件失败，放弃安装")
            cleanup(stagedURL.deletingLastPathComponent())
            return false
        }

        do {
            try FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: stagedURL, to: dest)
            cleanup(stagedURL.deletingLastPathComponent())
            return true
        } catch {
            NSLog("整体替换失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 覆盖安装（overlay）：拉取到的文件覆盖同名，现有其它文件保持不动
    @discardableResult
    static func overlayInstall(stagedURL: URL, id: String) -> Bool {
        let dest = AppInfo.pluginDirectory.appendingPathComponent(id, isDirectory: true)
        let status = runTool("/usr/bin/ditto", [stagedURL.path, dest.path])
        cleanup(stagedURL.deletingLastPathComponent())
        return status == 0
    }

    /// 清理临时目录
    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 导出插件文件夹为 zip（--keepParent 使 zip 内保留插件顶层目录）
    @discardableResult
    static func exportZip(folder: URL, to destination: URL) -> Bool {
        try? FileManager.default.removeItem(at: destination)
        let status = runTool("/usr/bin/ditto",
                             ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, destination.path])
        return status == 0
    }

    // MARK: - 内部辅助

    /// 校验暂存目录：非空、含 main.sh、满足 minAppVersion；并判断是否已安装
    private static func validateStaged(_ stagedURL: URL, id: String) -> FetchResult {
        let entry = stagedURL.appendingPathComponent("main.sh")
        guard FileManager.default.fileExists(atPath: entry.path) else {
            cleanup(stagedURL.deletingLastPathComponent())
            return .failure("该内容缺少 main.sh，非合法插件")
        }

        let metadata = PluginMetadataStore.parse(entryURL: entry)
        if let required = metadata.minAppVersion, !versionAtLeast(AppInfo.shortVersion, required) {
            cleanup(stagedURL.deletingLastPathComponent())
            return .failure("该插件需要 FinderWand v\(required) 及以上")
        }

        let dest = AppInfo.pluginDirectory.appendingPathComponent(id, isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: dest.path)
        return .success(stagedURL: stagedURL, id: id, alreadyInstalled: exists)
    }

    /// 创建临时暂存目录，返回 (根目录, 暂存的 <id> 目录)
    private static func makeStaging(id: String) -> (root: URL, staged: URL)? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderwand-install-\(UUID().uuidString)", isDirectory: true)
        let staged = root.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            return (root, staged)
        } catch {
            return nil
        }
    }

    private static func isEmptyDir(_ url: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return contents.isEmpty
    }

    /// 取仓库默认分支（未鉴权 API）
    private static func fetchDefaultBranch(owner: String, repo: String) -> (branch: String?, error: String?) {
        guard let url = GitHubRepo.apiURL(owner: owner, repo: repo) else {
            return (nil, "仓库地址不合法，请输入 owner/repo 或完整 GitHub 地址")
        }

        var request = URLRequest(url: url)
        request.setValue("FinderWand", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        var branch: String?
        var message: String?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                message = "获取仓库信息失败: \(error.localizedDescription)"
                return
            }

            guard let http = response as? HTTPURLResponse else {
                message = "获取仓库信息失败: 无有效响应"
                return
            }

            guard (200..<300).contains(http.statusCode) else {
                message = "获取仓库信息失败(HTTP \(http.statusCode))：请确认仓库存在且为公开"
                return
            }

            if let data = data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = object["default_branch"] as? String {
                branch = value
            } else {
                message = "解析仓库信息失败"
            }
        }
        task.resume()
        semaphore.wait()

        return (branch, message)
    }

    /// 下载指定仓库分支的 tarball 到文件；成功返回 nil，失败返回错误说明。
    private static func downloadTarball(owner: String, repo: String, branch: String, to file: URL) -> String? {
        guard let url = GitHubRepo.tarballURL(owner: owner, repo: repo, branch: branch) else {
            return "下载失败: 仓库或分支名不合法（\(owner)/\(repo)@\(branch)）"
        }

        var request = URLRequest(url: url)
        request.setValue("FinderWand", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        var payload: Data?
        var message: String?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                message = "下载失败: \(error.localizedDescription)"
                return
            }

            guard let http = response as? HTTPURLResponse else {
                message = "下载失败: 无有效响应"
                return
            }

            guard (200..<300).contains(http.statusCode) else {
                message = "下载失败(HTTP \(http.statusCode))：请确认仓库已公开、分支为 \(branch)"
                return
            }

            payload = data
        }
        task.resume()
        semaphore.wait()

        if let message = message { return message }

        guard let payload = payload, !payload.isEmpty else { return "下载失败: 内容为空" }

        do {
            try payload.write(to: file)
        } catch {
            return "写入下载文件失败: \(error.localizedDescription)"
        }

        return nil
    }

    /// 文件系统安全 slug：字母数字与 . _ -，不以点开头，不含 ".." 或路径分隔符
    private static func isSafeSlug(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains(".."), !id.contains("/") else { return false }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 语义化版本比较：current >= required 返回 true
    private static func versionAtLeast(_ current: String, _ required: String) -> Bool {
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        let r = required.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(c.count, r.count) {
            let cv = index < c.count ? c[index] : 0
            let rv = index < r.count ? r[index] : 0
            if cv != rv { return cv > rv }
        }

        return true
    }

    /// 时间戳后缀，形如 20260719151131
    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }

    /// 运行命令行工具，返回退出码
    private static func runTool(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        // 输出不使用，直接丢弃；用未读取的 Pipe 时输出超过管道缓冲会让工具写阻塞而卡死
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            NSLog("执行 \(path) 失败: \(error.localizedDescription)")
            return -1
        }
    }
}
