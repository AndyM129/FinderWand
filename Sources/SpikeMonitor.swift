import Foundation

/// M3 spike 验证：监听 Finder Sync 扩展发来的 Darwin 通知
/// 收到后向插件目录写入日志，证明「沙箱扩展 → 非沙箱主 App」的跨进程链路可用。
final class SpikeMonitor {

    static let shared = SpikeMonitor()

    private let notificationName = "io.github.andym129.finder-wand.spike"

    /// 开始监听 Darwin 通知
    func start() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in SpikeMonitor.shared.handleNotification() },
            notificationName as CFString,
            nil,
            .deliverImmediately)
    }

    /// 收到通知：向 ~/.config/FinderWand/spike.log 追加一行时间戳记录
    private func handleNotification() {
        let directory = AppInfo.pluginDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let logURL = directory.appendingPathComponent("spike.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] 已收到 Finder Sync 扩展菜单点击\n"
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
