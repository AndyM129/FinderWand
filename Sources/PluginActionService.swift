import Foundation

/// 插件动作服务（主 App 侧，非沙箱）
/// 监听扩展发来的 Darwin 通知，读取 IPC 请求，执行对应 `.sh`，并记录到运行日志。
final class PluginActionService {

    static let shared = PluginActionService()

    /// 串行队列，避免并发处理请求
    private let queue = DispatchQueue(label: "io.github.andym129.finder-wand.plugin-action")

    /// 插件目录变更监听源
    private var directoryWatcher: DispatchSourceFileSystemObject?

    /// 开始监听扩展的 Darwin 通知，并首次生成插件清单、监听插件目录变化
    func start() {
        addObserver(name: FWIPC.darwinActionName) {
            PluginActionService.shared.handleActionNotification()
        }
        addObserver(name: FWIPC.darwinRefreshName) {
            PluginActionService.shared.refreshManifest()
        }

        refreshManifest()
        startWatchingPluginDirectory()
    }

    /// 注册一个 Darwin 通知观察者
    private func addObserver(name: String, handler: @escaping () -> Void) {
        // 用静态分发避免在 C 回调里捕获上下文
        DarwinObserverRegistry.shared.register(name: name, handler: handler)
    }

    /// 收到动作通知：在后台队列处理所有待处理请求
    private func handleActionNotification() {
        queue.async { [weak self] in
            self?.processPendingRequests()
        }
    }

    /// 扩展容器 Data 目录：由主 App 的 BundleID 推导扩展 BundleID（主 BundleID + ".FinderSync"）
    private var extensionContainerData: URL? {
        guard let mainID = Bundle.main.bundleIdentifier else { return nil }

        let extensionID = "\(mainID).FinderSync"
        return URL(fileURLWithPath: FWIPC.realHomeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Containers/\(extensionID)/Data", isDirectory: true)
    }

    /// 扩展容器内的 IPC 请求目录
    private var requestsDirectory: URL? {
        extensionContainerData.map { FWIPC.requestsDirectory(containerDataDirectory: $0) }
    }

    // MARK: - 插件清单

    /// 重新枚举插件目录并把清单写入扩展容器，供扩展读取构建菜单
    func refreshManifest() {
        queue.async { [weak self] in
            self?.writeManifest()
        }
    }

    private func writeManifest() {
        guard let containerData = extensionContainerData else { return }

        let manifestURL = FWIPC.manifestFile(containerDataDirectory: containerData)
        let directory = FWIPC.pluginDirectory

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)) ?? []

        let entries = contents
            .filter { $0.pathExtension == "sh" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                ["name": url.deletingPathExtension().lastPathComponent, "path": url.path]
            }

        do {
            try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted])
            try data.write(to: manifestURL)
        } catch {
            NSLog("写入插件清单失败: \(error.localizedDescription)")
        }
    }

    /// 监听插件目录变化，变动时刷新清单
    private func startWatchingPluginDirectory() {
        let directory = FWIPC.pluginDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue)
        source.setEventHandler { [weak self] in
            self?.writeManifest()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatcher = source
    }

    /// 处理请求目录下所有 `.json` 请求
    private func processPendingRequests() {
        guard let requestsDir = requestsDirectory else { return }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: requestsDir,
            includingPropertiesForKeys: nil)) ?? []

        for file in files where file.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: file) }

            guard
                let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let scriptPath = object["script"] as? String
            else { continue }

            let currentDir = object["currentDir"] as? String ?? ""
            let selected = object["selected"] as? [String] ?? []
            executeScript(atPath: scriptPath, currentDir: currentDir, selected: selected)
        }
    }

    /// 执行脚本并记录结果
    private func executeScript(atPath scriptPath: String, currentDir: String, selected: [String]) {
        // 确保可执行位，尊重脚本自身的 shebang
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: scriptPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        process.arguments = [currentDir] + selected

        var environment = ProcessInfo.processInfo.environment
        environment["FW_CURRENT_DIR"] = currentDir
        environment["FW_SELECTED_PATHS"] = selected.joined(separator: "\n")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var output = ""
        var status: Int32 = -1
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            status = process.terminationStatus
            output = String(data: data, encoding: .utf8) ?? ""
        } catch {
            output = "执行失败: \(error.localizedDescription)"
        }

        appendRunLog(scriptPath: scriptPath, currentDir: currentDir,
                     selected: selected, status: status, output: output)
    }

    /// 追加运行日志到 ~/.config/FinderWand/run.log
    private func appendRunLog(scriptPath: String, currentDir: String,
                              selected: [String], status: Int32, output: String) {
        let directory = FWIPC.pluginDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let logURL = directory.appendingPathComponent("run.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let snippet = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = """
        [\(timestamp)] script=\(scriptPath) exit=\(status)
          currentDir=\(currentDir)
          selected=\(selected.joined(separator: ", "))
          output=\(snippet)

        """
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
