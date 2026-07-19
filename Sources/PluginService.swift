import Foundation
import AppKit

/// 插件服务（主 App 侧，非沙箱）
/// 两大职责：
///   1. 构建菜单：收到扩展的 build 通知后，遍历插件目录执行每个 `.sh`，解析输出为菜单规格返回给扩展。
///   2. 执行动作：收到扩展的 action 通知后，按 actionId 执行对应命令或打开链接。
final class PluginService {

    static let shared = PluginService()

    private let queue = DispatchQueue(label: "io.github.andym129.finder-wand.plugin")

    /// 每个脚本执行的超时时间（秒）
    private let scriptTimeout: TimeInterval = 1.5

    /// actionId 计数与动作表（含点击时的上下文）
    private var nextActionId = 1
    private var actions: [Int: StoredAction] = [:]

    private struct StoredAction {
        let action: PluginAction
        let currentDir: String
        let selected: [String]
    }

    /// 开始监听扩展的 Darwin 通知
    func start() {
        DarwinObserverRegistry.shared.register(name: FWIPC.darwinBuildName) {
            PluginService.shared.handleBuildNotification()
        }
        DarwinObserverRegistry.shared.register(name: FWIPC.darwinActionName) {
            PluginService.shared.handleActionNotification()
        }
    }

    // MARK: - 容器路径

    /// 扩展容器 Data 目录：由主 App BundleID 推导扩展 BundleID（主 BundleID + ".FinderSync"）
    private var containerData: URL? {
        guard let mainID = Bundle.main.bundleIdentifier else { return nil }

        let extensionID = "\(mainID).FinderSync"
        return URL(fileURLWithPath: FWIPC.realHomeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Containers/\(extensionID)/Data", isDirectory: true)
    }

    // MARK: - 构建菜单

    private func handleBuildNotification() {
        queue.async { [weak self] in
            self?.processBuildRequests()
        }
    }

    private func processBuildRequests() {
        guard let base = containerData else { return }

        let requestsDir = FWIPC.buildRequestsDirectory(containerDataDirectory: base)
        let responsesDir = FWIPC.buildResponsesDirectory(containerDataDirectory: base)
        try? FileManager.default.createDirectory(at: responsesDir, withIntermediateDirectories: true)

        let files = (try? FileManager.default.contentsOfDirectory(at: requestsDir,
                                                                   includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: file) }

            guard
                let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let requestId = object["id"] as? String
            else { continue }

            let currentDir = object["currentDir"] as? String ?? ""
            let selected = object["selected"] as? [String] ?? []

            let nodes = buildNodes(currentDir: currentDir, selected: selected)
            let items = serialize(nodes, currentDir: currentDir, selected: selected)

            let response: [String: Any] = ["items": items]
            if let data = try? JSONSerialization.data(withJSONObject: response, options: []) {
                try? data.write(to: responsesDir.appendingPathComponent("\(requestId).json"))
            }
        }
    }

    // MARK: - 插件枚举

    /// 已安装插件（目录化）
    struct InstalledPlugin {
        /// 插件 id（即文件夹名）
        let id: String
        /// 入口脚本 main.sh
        let entryURL: URL
        /// 插件元信息
        let metadata: PluginMetadata
    }

    /// 枚举已安装插件：列插件目录下含 main.sh 的子文件夹，按文件夹名排序，读元信息（含禁用者）
    func installedPlugins() -> [InstalledPlugin] {
        let directory = FWIPC.pluginDirectory

        let folders = ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return folders.compactMap { folder in
            let entry = folder.appendingPathComponent("main.sh")
            guard FileManager.default.fileExists(atPath: entry.path) else { return nil }

            return InstalledPlugin(id: folder.lastPathComponent,
                                   entryURL: entry,
                                   metadata: PluginMetadataStore.metadata(forEntry: entry))
        }
    }

    // MARK: - 构建菜单

    /// 遍历插件目录构建菜单（目录化插件）
    /// 说明：一个插件 = 一个文件夹，文件夹名即插件 id，入口固定 `main.sh`。
    /// 只加载「含 main.sh 的插件文件夹」，顶层散放的 `.sh` 忽略；`enabled=false` 的插件跳过。
    /// 各插件相互独立，改为并行执行以降低 `menu(for:)` 的同步等待时延，结果按文件夹名顺序回填保序。
    private func buildNodes(currentDir: String, selected: [String]) -> [MenuNode] {
        // 仅加载启用的插件
        let plugins = installedPlugins().filter { $0.metadata.enabled }

        guard !plugins.isEmpty else { return [] }

        // 每个插件对应一段节点，按下标回填以保序
        var perPluginNodes = [[MenuNode]](repeating: [], count: plugins.count)
        let lock = NSLock()
        let group = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "io.github.andym129.finder-wand.plugin.run",
                                            attributes: .concurrent)

        for (index, plugin) in plugins.enumerated() {
            group.enter()
            concurrentQueue.async { [weak self] in
                defer { group.leave() }
                guard let self = self else { return }

                let result = self.run(executable: plugin.entryURL.path,
                                      args: [currentDir] + selected,
                                      currentDir: currentDir,
                                      selected: selected)

                var nodes = PluginOutputParser.parse(result.output)

                // 构建期脚本失败/超时：注入一个不可点击的错误提示项（以插件 id 标识）
                if result.status != 0 {
                    nodes.append(MenuNode(
                        title: "⚠️ \(plugin.id)（执行失败，退出码 \(result.status)）",
                        enabled: false))
                }

                lock.lock()
                perPluginNodes[index] = nodes
                lock.unlock()
            }
        }

        group.wait()

        return perPluginNodes.flatMap { $0 }
    }

    /// 把节点树序列化为 JSON，并为可执行叶子登记 actionId
    private func serialize(_ nodes: [MenuNode], currentDir: String, selected: [String]) -> [[String: Any]] {
        nodes.map { node in
            if node.isSeparator { return ["separator": true] }

            var dict: [String: Any] = ["title": node.title, "enabled": node.enabled]

            if let sfimage = node.sfimage { dict["sfimage"] = sfimage }

            if !node.children.isEmpty {
                dict["children"] = serialize(node.children, currentDir: currentDir, selected: selected)
            } else if let action = node.action, node.enabled {
                dict["actionId"] = registerAction(action, currentDir: currentDir, selected: selected)
            }

            return dict
        }
    }

    private func registerAction(_ action: PluginAction, currentDir: String, selected: [String]) -> Int {
        let id = nextActionId
        nextActionId += 1
        actions[id] = StoredAction(action: action, currentDir: currentDir, selected: selected)

        // 简单裁剪，避免无限增长
        if actions.count > 500 {
            let cutoff = id - 500
            actions = actions.filter { $0.key > cutoff }
        }

        return id
    }

    // MARK: - 执行动作

    private func handleActionNotification() {
        queue.async { [weak self] in
            self?.processActionRequests()
        }
    }

    private func processActionRequests() {
        guard let base = containerData else { return }

        let actionsDir = FWIPC.actionRequestsDirectory(containerDataDirectory: base)
        let files = (try? FileManager.default.contentsOfDirectory(at: actionsDir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: file) }

            guard
                let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let actionId = object["actionId"] as? Int,
                let stored = actions[actionId]
            else { continue }

            execute(stored)
        }
    }

    private func execute(_ stored: StoredAction) {
        switch stored.action {
        case .href(let urlString):
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            appendRunLog(summary: "href=\(urlString)", status: 0, output: "")

        case .bash(let path, let args, let terminal):
            if terminal {
                runInTerminal(path: path, args: args, currentDir: stored.currentDir, selected: stored.selected)
                appendRunLog(summary: "terminal bash=\(path) args=\(args.joined(separator: " "))",
                             status: 0,
                             output: "已在终端中打开")
            } else {
                let result = run(executable: path,
                                 args: args,
                                 currentDir: stored.currentDir,
                                 selected: stored.selected)
                appendRunLog(summary: "bash=\(path) args=\(args.joined(separator: " "))",
                             status: result.status,
                             output: result.output)
            }
        }
    }

    /// 在 Terminal 中运行命令：对齐旧版实现，用独立的 /usr/bin/osascript 进程发送
    /// `tell application "Terminal" ... do script <命令行>`，把真实命令行直接送进终端执行。
    ///
    /// 相比临时 .command 包装脚本的优点：
    /// - 终端里显示并执行的就是真实命令行（含环境变量与脚本调用），而非一个临时脚本路径；
    /// - `do script` 执行完命令后 shell 仍是交互式，用户可继续输入，无需再 `exec` 顶替；
    /// - 用独立 osascript 二进制而非进程内 NSAppleScript，规避 ad-hoc 签名下自动化静默失败。
    private func runInTerminal(path: String, args: [String], currentDir: String, selected: [String]) {
        // 组装命令行：先 cd 到目标目录，再以「环境变量前缀 + 脚本调用」形式执行。
        // 各段用 " \\\n"（空格 + 反斜杠 + 换行）连接成 shell 续行，便于在终端里分行展示。
        var segments: [String] = []
        if !currentDir.isEmpty {
            segments.append("cd \(shellQuote(currentDir)) &&")
        }
        segments.append("FW_CURRENT_DIR=\(shellQuote(currentDir))")
        segments.append("FW_SELECTED_PATHS=\(shellQuote(selected.joined(separator: "\n")))")
        segments.append("FW_PLUGIN_DIR=\(shellQuote(URL(fileURLWithPath: path).deletingLastPathComponent().path))")
        segments.append(([path] + args).map(shellQuote).joined(separator: " "))
        let commandLine = segments.joined(separator: " \\\n")

        // 把「清屏」与「真实命令」作为同一段脚本发给终端：先 clear 再执行，避免两次
        // do script 异步返回导致清屏时机错乱。clear 清可见区，printf \e[3J 清回滚缓冲。
        let fullScript = "clear && printf '\\e[3J'\n" + commandLine

        // 转义为 AppleScript 字符串字面量：AppleScript 支持 \\ \" \n 转义，
        // 需把真实反斜杠、双引号、换行分别转义，使 do script 收到含续行与换行的多行命令。
        let asStringLiteral = "\"" + fullScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            + "\""

        let appleScript = """
        set commandLine to \(asStringLiteral)
        if application "Terminal" is running then
            tell application "Terminal"
                activate
                do script commandLine
            end tell
        else
            tell application "Terminal"
                activate
                do script commandLine in window 1
            end tell
        end if
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        do {
            try process.run()
        } catch {
            NSLog("在终端运行失败: \(error.localizedDescription)")
        }
    }

    /// shell 单引号安全转义
    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 执行脚本

    /// 执行可执行文件，返回退出码与合并输出（带超时）
    private func run(executable: String, args: [String], currentDir: String, selected: [String]) -> (status: Int32, output: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        var environment = ProcessInfo.processInfo.environment
        // 兜底 UTF-8 locale：LaunchServices 启动的 GUI 应用通常不带 LANG/LC_*，
        // 子进程继承后，pbcopy 等依赖 locale 的工具会按 C/POSIX 处理输入，
        // 遇到中文等非 ASCII 字节会被丢弃（如复制含中文的路径会得到空剪贴板）。
        // 仅在调用方未显式设置时补默认值，不覆盖用户既有配置。
        if environment["LC_ALL"] == nil, environment["LC_CTYPE"] == nil, environment["LANG"] == nil {
            environment["LC_CTYPE"] = "UTF-8"
        }
        environment["FW_CURRENT_DIR"] = currentDir
        environment["FW_SELECTED_PATHS"] = selected.joined(separator: "\n")
        // 插件所在目录，便于目录化插件引用自身携带的资源（如相对图片、辅助脚本）
        environment["FW_PLUGIN_DIR"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        process.environment = environment

        if !currentDir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDir)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return (-1, "执行失败: \(error.localizedDescription)")
        }

        if semaphore.wait(timeout: .now() + scriptTimeout) == .timedOut {
            process.terminate()
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.isRunning ? -1 : process.terminationStatus, output)
    }

    // MARK: - 日志

    private func appendRunLog(summary: String, status: Int32, output: String) {
        let directory = FWIPC.pluginDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let logURL = directory.appendingPathComponent("run.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let snippet = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "[\(timestamp)] \(summary) exit=\(status)\n  output=\(snippet)\n\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
