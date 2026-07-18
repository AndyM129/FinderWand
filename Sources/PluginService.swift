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

    /// 遍历插件目录执行脚本，合并解析结果
    private func buildNodes(currentDir: String, selected: [String]) -> [MenuNode] {
        let directory = FWIPC.pluginDirectory
        let scripts = ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "sh" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var all: [MenuNode] = []
        for script in scripts {
            let result = run(executable: script.path,
                             args: [currentDir] + selected,
                             currentDir: currentDir,
                             selected: selected)
            all += PluginOutputParser.parse(result.output)

            // 构建期脚本失败/超时：注入一个不可点击的错误提示项
            if result.status != 0 {
                let errorNode = MenuNode(
                    title: "⚠️ \(script.lastPathComponent)（执行失败，退出码 \(result.status)）",
                    enabled: false)
                all.append(errorNode)
            }
        }

        return all
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

    /// 在 Terminal 中运行命令：写一个临时 .command 包装脚本并用 open 打开
    private func runInTerminal(path: String, args: [String], currentDir: String, selected: [String]) {
        let wrapper = FileManager.default.temporaryDirectory
            .appendingPathComponent("finderwand-\(UUID().uuidString).command")

        var lines = ["#!/bin/bash"]
        lines.append("export FW_CURRENT_DIR=\(shellQuote(currentDir))")
        lines.append("export FW_SELECTED_PATHS=\(shellQuote(selected.joined(separator: "\n")))")
        if !currentDir.isEmpty {
            lines.append("cd \(shellQuote(currentDir))")
        }
        lines.append(([path] + args).map(shellQuote).joined(separator: " "))

        do {
            try (lines.joined(separator: "\n") + "\n").write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", "Terminal", wrapper.path]
            try open.run()
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
        environment["FW_CURRENT_DIR"] = currentDir
        environment["FW_SELECTED_PATHS"] = selected.joined(separator: "\n")
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
