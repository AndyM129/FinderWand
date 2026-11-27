import AppKit

/// 运行 `terminal=` 命令的终端 App
enum TerminalApp: String, CaseIterable {
    /// 系统自带「终端」
    case terminal
    /// iTerm2
    case iterm

    /// 菜单栏「终端应用」设置的 UserDefaults 键
    private static let settingKey = "FWTerminalApp"

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        }
    }

    var displayName: String {
        switch self {
        case .terminal: return "终端"
        case .iterm: return "iTerm"
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// 菜单栏「终端应用」设置，缺省为系统「终端」
    static var preferred: TerminalApp {
        get {
            UserDefaults.standard.string(forKey: settingKey).flatMap(TerminalApp.init(rawValue:)) ?? .terminal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: settingKey)
        }
    }

    /// 按插件的 `terminal=` 取值决定实际使用的终端；选中的终端未安装时退回系统「终端」
    static func resolve(_ choice: TerminalChoice) -> TerminalApp {
        let app: TerminalApp
        switch choice {
        case .followSetting: app = preferred
        case .terminal: app = .terminal
        case .iterm: app = .iterm
        }

        return app.isInstalled ? app : .terminal
    }

    /// 生成在该终端新窗口 / 新标签页里执行 `commandLiteral` 的 AppleScript
    /// - Parameter commandLiteral: 已转义好的 AppleScript 字符串字面量（含两侧双引号）
    func appleScript(commandLiteral: String) -> String {
        switch self {
        case .terminal:
            // 终端未运行时，激活会自动开一个窗口，直接在该窗口执行，避免多出一个空窗口
            return """
            set commandLine to \(commandLiteral)
            if application id "com.apple.Terminal" is running then
                tell application id "com.apple.Terminal"
                    activate
                    do script commandLine
                end tell
            else
                tell application id "com.apple.Terminal"
                    activate
                    do script commandLine in window 1
                end tell
            end if
            """

        case .iterm:
            // iTerm 已有窗口时开新标签页；刚启动时等它自动开出的窗口，没有再新建
            return """
            set commandLine to \(commandLiteral)
            set wasRunning to application id "com.googlecode.iterm2" is running
            tell application id "com.googlecode.iterm2"
                activate
                if wasRunning and (count of windows) > 0 then
                    tell current window to create tab with default profile
                else
                    repeat 20 times
                        if (count of windows) > 0 then exit repeat
                        delay 0.1
                    end repeat
                    if (count of windows) = 0 then create window with default profile
                end if
                tell current session of current window to write text commandLine
            end tell
            """
        }
    }
}
