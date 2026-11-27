import AppKit
import CryptoKit

/// 应用内一键更新：下载新版 dmg、校验、替换当前 App 并重新打开
///
/// 为什么能避开「已阻止打开」：浏览器下载的文件会被加上隔离属性 `com.apple.quarantine`，
/// App 只有 ad-hoc 签名、未公证，带这个属性打开就会被 Gatekeeper 拦截。
/// App 自己用 URLSession 下载的文件不带该属性（Info.plist 未开 `LSFileQuarantineEnabled`），
/// 替换后打开不会弹窗。保险起见，替换前仍对新 App 移除一次隔离属性。
///
/// 流程：下载 dmg → 按 Release 附带的 .sha256 校验 → 挂载 → 核对 BundleID、版本、签名完整性
/// → 复制到目标所在目录的临时位置 → 退出当前 App → 辅助脚本把新旧 App 换位并重新打开。
final class UpdateInstaller {

    static let shared = UpdateInstaller()

    /// 是否正在下载或准备安装（只在主线程读写）
    private(set) var isInstalling = false

    private let queue = DispatchQueue(label: "io.github.andym129.finder-wand.update")

    /// 记录「从哪个版本发起的更新」，新版本启动时据此发一条「已更新」通知
    private let updatedFromKey = "FWUpdatedFromVersion"

    /// 更新日志：辅助脚本在 App 退出后运行，输出写到这里便于排查
    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FinderWand/update.log")
    }

    // MARK: - 对外接口

    /// 开始一键更新（主线程调用）。成功时 App 会退出并由新版本重新打开；失败时在主线程回调原因。
    func install(_ update: UpdateInfo, failure: @escaping (String) -> Void) {
        guard !isInstalling else { return }

        guard let dmgURL = update.downloadURL else {
            failure("该版本没有提供安装包。")
            return
        }

        let target = Bundle.main.bundleURL.standardizedFileURL
        if let problem = Self.targetProblem(target) {
            failure(problem)
            return
        }

        isInstalling = true

        queue.async {
            do {
                let staged = try self.prepare(update, dmgURL: dmgURL, target: target)
                DispatchQueue.main.async {
                    self.relaunch(replacing: target, with: staged)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isInstalling = false
                    failure(error.localizedDescription)
                }
            }
        }
    }

    /// App 启动时调用：刚由一键更新换上的新版本，发一条「已更新」通知
    func announceIfUpdated() {
        guard let from = UserDefaults.standard.string(forKey: updatedFromKey) else { return }

        UserDefaults.standard.removeObject(forKey: updatedFromKey)
        guard from != AppInfo.shortVersion else { return }

        UserNotifier.notify(title: "FinderWand 已更新到 v\(AppInfo.shortVersion)",
                            body: "由 v\(from) 升级完成。")
    }

    // MARK: - 前置检查

    /// 当前 App 所在位置能否被替换；不能时返回给用户看的原因
    private static func targetProblem(_ target: URL) -> String? {
        if AppInfo.channel == "dev" {
            return "本地开发构建不支持一键更新。"
        }

        // 带隔离属性直接从下载目录打开时，系统会把 App 放到只读的随机路径里运行（App Translocation）
        if target.path.contains("/AppTranslocation/") {
            return "FinderWand 正运行在系统的临时隔离位置，无法替换。请先把 FinderWand.app 拖到「应用程序」文件夹，再从那里打开。"
        }

        let parent = target.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parent) {
            return "没有写入「\(parent)」的权限，无法替换 App。"
        }

        return nil
    }

    // MARK: - 下载与校验（后台队列）

    private enum InstallError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(text) = self { return text }
            return nil
        }
    }

    /// 下载、校验、挂载 dmg，把新 App 复制到目标所在目录的临时位置，返回该位置
    private func prepare(_ update: UpdateInfo, dmgURL: URL, target: URL) throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderWand-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let dmg = work.appendingPathComponent(dmgURL.lastPathComponent)
        try download(dmgURL, to: dmg)

        // Release 附带 .sha256 时必须一致；没有时跳过（旧版本发布可能没有）
        if let checksumURL = update.checksumURL {
            let checksumFile = work.appendingPathComponent("checksum.sha256")
            try download(checksumURL, to: checksumFile)
            let expected = (try? String(contentsOf: checksumFile, encoding: .utf8))?
                .split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
            let actual = try Self.sha256(of: dmg)
            guard let expected, expected == actual else {
                throw InstallError.message("安装包校验失败（SHA-256 不一致），已取消更新。")
            }
        }

        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.runTool("/usr/bin/hdiutil",
                         ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path],
                         failure: "挂载安装包失败")
        defer {
            _ = try? Self.runTool("/usr/bin/hdiutil", ["detach", mount.path, "-force"], failure: "")
        }

        let newApp = try Self.findApp(in: mount, version: update.version)

        // 复制到目标同一目录下（同一卷，后面换位用 rename，不会半途失败留下残缺 App）
        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".FinderWand-update-\(update.version).app", isDirectory: true)
        try? FileManager.default.removeItem(at: staged)
        try Self.runTool("/usr/bin/ditto", [newApp.path, staged.path], failure: "复制新版本失败")
        _ = try? Self.runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path], failure: "")

        return staged
    }

    /// 同步下载到指定位置
    private func download(_ url: URL, to destination: URL) throws {
        var request = URLRequest(url: url)
        request.setValue("FinderWand", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let done = DispatchSemaphore(value: 0)
        var failure: String?
        URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { done.signal() }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                failure = "下载失败：\(error.localizedDescription)"
            } else if !(200 ... 299).contains(status) {
                failure = "下载失败：HTTP \(status)"
            } else if let location {
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                } catch {
                    failure = "保存安装包失败：\(error.localizedDescription)"
                }
            }
        }.resume()
        done.wait()

        if let failure { throw InstallError.message(failure) }
    }

    /// 在挂载目录里找到 BundleID 与当前 App 一致、版本号为目标版本、签名完整的 .app
    private static func findApp(in mount: URL, version: String) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: {
            $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier
        }) else {
            throw InstallError.message("安装包里没有找到 FinderWand.app。")
        }

        let newVersion = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard newVersion == version else {
            throw InstallError.message("安装包版本（\(newVersion ?? "未知")）与预期的 v\(version) 不一致。")
        }

        try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                    failure: "新版本的签名校验失败")
        return app
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 运行系统工具，非 0 退出码时抛出带输出的错误
    @discardableResult
    private static func runTool(_ path: String, _ args: [String], failure: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.message(detail.isEmpty ? "\(failure)。" : "\(failure)：\(detail)")
        }
        return output
    }

    // MARK: - 替换并重启（主线程）

    /// 写辅助脚本并在后台启动，然后退出当前 App；脚本等本进程退出后换位、重新打开
    private func relaunch(replacing target: URL, with staged: URL) {
        let script = """
        #!/bin/zsh
        # FinderWand 一键更新：等旧进程退出后，用新版本替换旧版本并重新打开
        PID="$1"; TARGET="$2"; STAGED="$3"; LOG="$4"
        exec >>"$LOG" 2>&1
        echo "[$(date '+%F %T')] 开始替换 $TARGET"
        for i in {1..100}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        BACKUP="${TARGET%.app}.old-$$.app"
        if ! mv "$TARGET" "$BACKUP"; then
          echo "移走旧版本失败，放弃更新"; rm -rf "$STAGED"; open "$TARGET"; exit 1
        fi
        if ! mv "$STAGED" "$TARGET"; then
          echo "放入新版本失败，恢复旧版本"; mv "$BACKUP" "$TARGET"; open "$TARGET"; exit 1
        fi
        rm -rf "$BACKUP"
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        open "$TARGET"
        echo "[$(date '+%F %T')] 替换完成"
        """

        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FinderWand-relaunch-\(UUID().uuidString).sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path,
                                 String(ProcessInfo.processInfo.processIdentifier),
                                 target.path,
                                 staged.path,
                                 logURL.path]
            try process.run()
        } catch {
            isInstalling = false
            try? FileManager.default.removeItem(at: staged)
            UserNotifier.notify(title: "FinderWand 更新失败", body: "无法启动替换脚本：\(error.localizedDescription)")
            return
        }

        UserDefaults.standard.set(AppInfo.shortVersion, forKey: updatedFromKey)
        UserDefaults.standard.synchronize()
        NSApp.terminate(nil)
    }
}
