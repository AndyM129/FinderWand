import Foundation

/// 插件市场安装器（主 App 侧，非沙箱）
/// 从公开市场仓库按 id 拉取插件文件夹到本地插件目录，无需鉴权。
enum PluginInstaller {

    /// 市场仓库信息
    static let owner = "AndyM129"
    static let repo = "FinderWand-Plugins"
    static let branch = "master"

    /// 拉取并校验的结果（尚未写入插件目录）
    enum FetchResult {
        /// 校验通过，插件已暂存到临时目录 stagedURL（其内为该 <id> 文件夹的内容）
        case success(stagedURL: URL, alreadyInstalled: Bool)
        /// id 非法
        case invalidId
        /// 市场中未找到该插件
        case notFound
        /// 拉取内容缺少 main.sh，非合法插件
        case notAPlugin
        /// 当前 App 版本低于插件要求
        case appVersionTooLow(required: String)
        /// 其它失败
        case failed(String)
    }

    /// 冲突处理策略
    enum ConflictStrategy {
        case backupThenReplace  // 备份现有为 zip，再整体替换
        case overlay            // 覆盖式：同名覆盖，保留其它文件
    }

    // MARK: - 拉取并校验

    /// 下载市场仓库并解出 <id> 文件夹到临时目录，做合法性与版本校验；不写入插件目录。
    static func fetchAndValidate(id rawId: String) -> FetchResult {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeSlug(id) else { return .invalidId }

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderwand-install-\(UUID().uuidString)", isDirectory: true)
        // 暂存目录：tmpRoot/<id>，tar 解压后其内直接是插件文件
        let stagedURL = tmpRoot.appendingPathComponent(id, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: true)
        } catch {
            return .failed("创建临时目录失败: \(error.localizedDescription)")
        }

        // 下载 tarball
        let tarballFile = tmpRoot.appendingPathComponent("src.tar.gz")
        if let message = downloadTarball(to: tarballFile) {
            cleanup(tmpRoot)
            return .failed(message)
        }

        // 只解出根目录下的 <id> 文件夹：strip 顶层仓库目录(1) + 子目录本身(1) = 2
        let member = "\(repo)-\(branch)/\(id)"
        let status = runTool("/usr/bin/tar",
                             ["-xz", "-f", tarballFile.path, "-C", stagedURL.path,
                              "--strip-components=2", member])

        // 解压后目录为空 → 市场中无此插件（tar 对不存在的 member 会报错或产出空目录）
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: stagedURL.path)) ?? []
        if status != 0 || contents.isEmpty {
            cleanup(tmpRoot)
            return .notFound
        }

        // 合法性：须含 main.sh
        let entry = stagedURL.appendingPathComponent("main.sh")
        guard FileManager.default.fileExists(atPath: entry.path) else {
            cleanup(tmpRoot)
            return .notAPlugin
        }

        // 版本校验：按 minAppVersion 比较
        let metadata = PluginMetadataStore.parse(entryURL: entry)
        if let required = metadata.minAppVersion, !versionAtLeast(AppInfo.shortVersion, required) {
            cleanup(tmpRoot)
            return .appVersionTooLow(required: required)
        }

        let dest = AppInfo.pluginDirectory.appendingPathComponent(id, isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: dest.path)
        return .success(stagedURL: stagedURL, alreadyInstalled: exists)
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
        let backupZip = AppInfo.pluginDirectory
            .appendingPathComponent("\(id)-bak\(timestamp()).zip")

        // ditto 压缩现有文件夹（--keepParent 使 zip 内保留 <id> 顶层目录）
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
        // ditto 将 stagedURL 内容合并进 dest：同名覆盖、新增补齐、不删除 dest 已有的其它文件
        let status = runTool("/usr/bin/ditto", [stagedURL.path, dest.path])
        cleanup(stagedURL.deletingLastPathComponent())
        return status == 0
    }

    // MARK: - 辅助

    /// 清理临时目录
    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 下载市场仓库 tarball 到指定文件；成功返回 nil，失败返回错误说明。
    private static func downloadTarball(to file: URL) -> String? {
        let url = URL(string: "https://codeload.github.com/\(owner)/\(repo)/tar.gz/refs/heads/\(branch)")!
        var request = URLRequest(url: url)
        request.setValue("FinderWand", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

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
                message = "下载失败(HTTP \(http.statusCode))：请确认市场仓库已设为公开、分支为 \(branch)"
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

    /// 文件系统安全的插件 id：字母数字与 . _ -，不以点开头，不含 ".." 或路径分隔符
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
        process.standardOutput = Pipe()
        process.standardError = Pipe()
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
