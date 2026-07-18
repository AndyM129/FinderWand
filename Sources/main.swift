import AppKit

// 应用入口
// 说明：菜单栏常驻应用，通过 Info.plist 的 LSUIElement = YES 控制不显示 Dock 图标，
// 因此这里无需再手动设置 activationPolicy。
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
