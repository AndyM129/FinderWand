import Foundation
import AppKit

/// 插件服务（主 App 侧，非沙箱）
/// 两大职责：
///   1. 构建菜单：收到扩展的 build 通知后，遍历插件目录执行每个 `.sh`，解析输出为菜单规格返回给扩展。
///   2. 执行动作：收到扩展的 action 通知后，按 actionId 执行对应命令或打开链接。
final class PluginService {

    static let shared = PluginService()

    private let queue = DispatchQueue(label: "io.github.andym129.finder-wand.plugin")

    /// 构建期并行执行各插件的队列
    private let buildRunQueue = DispatchQueue(label: "io.github.andym129.finder-wand.plugin.run",
                                              attributes: .concurrent)

    /// 执行菜单动作的队列：与构建分开，耗时动作不阻塞后续右键菜单的构建
    private let actionQueue = DispatchQueue(label: "io.github.andym129.finder-wand.plugin.action",
                                            attributes: .concurrent)

    /// 串行写 run.log，避免并发动作的日志交错
    private let logQueue = DispatchQueue(label: "io.github.andym129.finder-wand.plugin.log")

    private static let logDateFormatter = ISO8601DateFormatter()

    /// 运行日志文件名（位于插件目录）
    static let logFileName = "run.log"

    /// 运行日志超过该大小时轮转为 run.log.1（只保留 1 份旧日志）
    private let logRotationSize = 1024 * 1024

    /// 构建期默认的单脚本超时（秒）；插件可用元信息 `timeout` 覆盖
    private let scriptTimeout: TimeInterval = 1.5

    /// 构建响应相对扩展等待上限的余量（秒）：到点仍未返回的插件按超时处理
    private let responseMargin: TimeInterval = 0.2

    /// 超时后发 SIGTERM 到强杀之间的宽限时间（秒）
    private let terminateGrace: TimeInterval = 0.2

    /// 脚本退出后等待输出读完的最长时间（秒）
    /// 脚本在后台派生的子进程会继承输出管道，管道迟迟不关闭时不再等待，避免卡住调用方。
    private let outputDrainTimeout: TimeInterval = 0.2

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

        // 新请求优先：连续右键时，Finder 只在等最新的那次
        let files = jsonFiles(in: requestsDir).sorted { $0.created > $1.created }
        for (file, created) in files {
            defer { try? FileManager.default.removeItem(at: file) }

            // 扩展已超时放弃等待的请求，跑插件也无人接收，直接丢弃
            guard Date().timeIntervalSince(created) < FWIPC.buildTimeout else { continue }

            guard
                let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let requestId = object["id"] as? String
            else { continue }

            let currentDir = object["currentDir"] as? String ?? ""
            let selected = object["selected"] as? [String] ?? []

            // 响应须在扩展放弃等待前写出，留出序列化与 IPC 的余量
            let deadline = created.addingTimeInterval(FWIPC.buildTimeout - responseMargin)
            let nodes = buildNodes(currentDir: currentDir, selected: selected, deadline: deadline)
            let items = serialize(nodes, currentDir: currentDir, selected: selected)

            let response: [String: Any] = ["items": items]
            if let data = try? JSONSerialization.data(withJSONObject: response, options: []) {
                // 原子写入：扩展轮询到文件存在即读取，非原子写可能读到半截 JSON 而误判为无响应
                try? data.write(to: responsesDir.appendingPathComponent("\(requestId).json"), options: .atomic)
            }
        }

        removeExpiredResponses(in: responsesDir)
    }

    /// 列出目录下的 .json 文件及其创建时间
    private func jsonFiles(in directory: URL) -> [(url: URL, created: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                return (url, created)
            }
    }

    /// 清理扩展超时后未被取走的响应文件，避免在扩展容器内堆积
    private func removeExpiredResponses(in directory: URL) {
        for (file, created) in jsonFiles(in: directory)
        where Date().timeIntervalSince(created) > FWIPC.buildTimeout * 2 {
            try? FileManager.default.removeItem(at: file)
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
    /// 到 deadline 仍未返回的插件按超时处理，保证扩展在等待上限内拿到其余插件的菜单。
    private func buildNodes(currentDir: String, selected: [String], deadline: Date) -> [MenuNode] {
        // 仅加载启用的插件
        let plugins = installedPlugins().filter { $0.metadata.enabled }

        guard !plugins.isEmpty else { return [] }

        // 每个插件对应一段节点，按下标回填以保序；nil 表示尚未返回
        var perPluginNodes = [[MenuNode]?](repeating: nil, count: plugins.count)
        let lock = NSLock()
        let group = DispatchGroup()

        for (index, plugin) in plugins.enumerated() {
            group.enter()
            buildRunQueue.async { [weak self] in
                defer { group.leave() }
                guard let self = self else { return }

                let result = self.run(executable: plugin.entryURL.path,
                                      args: [currentDir] + selected,
                                      currentDir: currentDir,
                                      selected: selected,
                                      timeout: plugin.metadata.timeout ?? self.scriptTimeout)

                var nodes = PluginOutputParser.parse(result.output)
                self.resolveImages(in: nodes, pluginFolder: plugin.entryURL.deletingLastPathComponent())

                // 构建期脚本失败/超时：写日志，并注入一个点击可查看日志的提示项（以插件 id 标识）
                if result.timedOut {
                    nodes.append(self.failureNode(title: "⚠️ \(plugin.id)（执行超时）"))
                    self.appendRunLog(summary: "build plugin=\(plugin.id) 超时", status: result.status, output: result.output)
                } else if result.status != 0 {
                    nodes.append(self.failureNode(title: "⚠️ \(plugin.id)（执行失败，退出码 \(result.status)）"))
                    self.appendRunLog(summary: "build plugin=\(plugin.id)", status: result.status, output: result.output)
                }

                lock.lock()
                perPluginNodes[index] = nodes
                lock.unlock()
            }
        }

        _ = group.wait(wallTimeout: .now() + max(0, deadline.timeIntervalSinceNow))

        lock.lock()
        let snapshot = perPluginNodes
        lock.unlock()

        return snapshot.enumerated().flatMap { index, nodes in
            nodes ?? [failureNode(title: "⚠️ \(plugins[index].id)（执行超时）")]
        }
    }

    /// 构建期失败提示项：点击打开 run.log
    private func failureNode(title: String) -> MenuNode {
        let logURL = FWIPC.pluginDirectory.appendingPathComponent(Self.logFileName)
        return MenuNode(title: title, action: .href(logURL.absoluteString))
    }

    /// 把节点树中的 `image=` 解析为菜单图片数据（需在主 App 侧完成，扩展读不到插件目录）
    private func resolveImages(in nodes: [MenuNode], pluginFolder: URL) {
        for node in nodes {
            if let image = node.image {
                node.imageData = MenuImageEncoder.encode(image, pluginFolder: pluginFolder)
            }
            resolveImages(in: node.children, pluginFolder: pluginFolder)
        }
    }

    /// 把节点树序列化为 JSON，并为可执行叶子登记 actionId
    private func serialize(_ nodes: [MenuNode], currentDir: String, selected: [String]) -> [[String: Any]] {
        nodes.map { node in
            if node.isSeparator { return ["separator": true] }

            var dict: [String: Any] = ["title": node.title, "enabled": node.enabled]

            if let imageData = node.imageData {
                dict["imageData"] = imageData
            } else if let sfimage = node.sfimage {
                dict["sfimage"] = sfimage
            }

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
        for (file, _) in jsonFiles(in: actionsDir).sorted(by: { $0.created < $1.created }) {
            defer { try? FileManager.default.removeItem(at: file) }

            guard
                let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let actionId = object["actionId"] as? Int,
                let stored = actions[actionId]
            else { continue }

            // 动作表只在串行队列上读写；执行放到独立队列，避免耗时动作阻塞右键菜单构建
            actionQueue.async { [weak self] in
                self?.execute(stored)
            }
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
                // 后台动作不在右键热路径上，不设超时，运行到脚本自行结束（耗时的 AppleScript 等不会被中途杀掉）
                let result = run(executable: path,
                                 args: args,
                                 currentDir: stored.currentDir,
                                 selected: stored.selected,
                                 timeout: nil)
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

    /// 脚本执行结果
    private struct RunResult {
        /// 退出码；启动失败或超时为 -1
        let status: Int32
        /// 标准输出与标准错误的合并内容
        let output: String
        /// 是否因超时被终止
        let timedOut: Bool
    }

    /// 执行可执行文件，返回退出码与合并输出
    /// - Parameter timeout: 超时秒数，超时先 SIGTERM、宽限后 SIGKILL；为 nil 时等待脚本自行结束
    private func run(executable: String,
                     args: [String],
                     currentDir: String,
                     selected: [String],
                     timeout: TimeInterval?) -> RunResult {
        ensureExecutable(executable)

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

        // 边执行边读取输出：输出超过管道缓冲（约 64KB）时脚本不会因写阻塞而被误判超时。
        // 读取一直持续到管道关闭（含脚本派生的后台子进程），闭包持有 pipe 保证读端不被提前释放，
        // 子进程写输出不会收到 SIGPIPE；读到 EOF 后解除闭包，释放 pipe。
        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                pipe.fileHandleForReading.readabilityHandler = nil
                collector.finish()
            } else {
                collector.append(chunk)
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return RunResult(status: -1, output: "执行失败: \(error.localizedDescription)", timedOut: false)
        }

        var timedOut = false
        if let timeout = timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if exited.wait(timeout: .now() + terminateGrace) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    exited.wait()
                }
            }
        } else {
            exited.wait()
        }

        collector.waitUntilFinished(timeout: outputDrainTimeout)

        return RunResult(status: timedOut ? -1 : process.terminationStatus,
                         output: collector.text,
                         timedOut: timedOut)
    }

    /// 确保脚本有可执行权限；已可执行时不改动，避免每次右键都写文件属性
    private func ensureExecutable(_ path: String) {
        guard !FileManager.default.isExecutableFile(atPath: path) else { return }

        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    // MARK: - 日志

    private func appendRunLog(summary: String, status: Int32, output: String) {
        let timestamp = Self.logDateFormatter.string(from: Date())
        let snippet = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "[\(timestamp)] \(summary) exit=\(status)\n  output=\(snippet)\n\n"
        guard let data = line.data(using: .utf8) else { return }

        logQueue.async { [logRotationSize] in
            let directory = FWIPC.pluginDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let logURL = directory.appendingPathComponent(Self.logFileName)

            // 超过上限时整体轮转：旧日志改名为 run.log.1（覆盖更早的那份），新日志从空文件开始
            let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size]) as? Int ?? 0
            if size > logRotationSize {
                let rotatedURL = directory.appendingPathComponent(Self.logFileName + ".1")
                try? FileManager.default.removeItem(at: rotatedURL)
                try? FileManager.default.moveItem(at: logURL, to: rotatedURL)
            }

            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}

/// 线程安全的脚本输出收集器
private final class OutputCollector {

    private let lock = NSLock()
    private var data = Data()
    private let finished = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    /// 管道读到 EOF 时调用
    func finish() {
        finished.signal()
    }

    /// 等待输出读完，最多等待 timeout 秒
    func waitUntilFinished(timeout: TimeInterval) {
        if finished.wait(timeout: .now() + timeout) == .success {
            // 归还信号，重复等待时立即返回
            finished.signal()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }

        return String(decoding: data, as: UTF8.self)
    }
}
