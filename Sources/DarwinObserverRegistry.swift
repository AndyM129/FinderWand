import Foundation

/// Darwin 通知观察者注册表
/// 用单一无捕获的 C 回调按通知名分发到对应处理闭包，避免在 C 回调中捕获上下文。
final class DarwinObserverRegistry {

    static let shared = DarwinObserverRegistry()

    private var handlers: [String: () -> Void] = [:]
    private let lock = NSLock()

    /// 注册一个 Darwin 通知的处理闭包
    func register(name: String, handler: @escaping () -> Void) {
        lock.lock()
        handlers[name] = handler
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, name, _, _ in
                guard let rawName = name?.rawValue as String? else { return }
                DarwinObserverRegistry.shared.dispatch(rawName)
            },
            name as CFString,
            nil,
            .deliverImmediately)
    }

    /// 按名分发
    private func dispatch(_ name: String) {
        lock.lock()
        let handler = handlers[name]
        lock.unlock()
        handler?()
    }
}
