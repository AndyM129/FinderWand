import AppKit

/// 插件详情窗口：展示图标、标题、版本、作者、标签、简介、预览图，并提供作者主页/说明/定位入口。
final class PluginDetailWindowController: NSObject, NSWindowDelegate {

    private let plugin: PluginService.InstalledPlugin
    private let contentWidth: CGFloat = 420
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    init(plugin: PluginService.InstalledPlugin) {
        self.plugin = plugin
        super.init()
    }

    /// 展示窗口，关闭时回调 onClose（便于外部释放引用）
    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose

        let folder = plugin.entryURL.deletingLastPathComponent()
        let metadata = plugin.metadata

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // 头部：图标 + 标题/副标题
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)

        let titleLabel = Self.label(metadata.title ?? plugin.id, font: .boldSystemFont(ofSize: 15))
        var subParts: [String] = []
        if let version = metadata.version { subParts.append("v\(version)") }
        if let author = metadata.author { subParts.append(author) }
        let subtitleLabel = Self.label(subParts.joined(separator: " · "),
                                       font: .systemFont(ofSize: 12), color: .secondaryLabelColor)

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4

        let header = NSStackView(views: [iconView, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        stack.addArrangedSubview(header)

        // ID 与标签
        stack.addArrangedSubview(Self.label("ID: \(plugin.id)", font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        if !metadata.tags.isEmpty {
            stack.addArrangedSubview(Self.label("标签: " + metadata.tags.joined(separator: ", "),
                                                font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        }

        // 简介
        if let description = metadata.pluginDescription {
            stack.addArrangedSubview(Self.wrappingLabel(description, width: contentWidth - 40))
        }

        // 预览图（异步加载后显示）
        let previewView = NSImageView()
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.widthAnchor.constraint(equalToConstant: contentWidth - 40).isActive = true
        previewView.heightAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        previewView.isHidden = true
        stack.addArrangedSubview(previewView)

        // 操作按钮
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        if metadata.authorUrl != nil {
            buttons.addArrangedSubview(Self.button("作者主页", target: self, action: #selector(openAuthor)))
        }
        let readmeURL = folder.appendingPathComponent("README.md")
        if FileManager.default.fileExists(atPath: readmeURL.path) {
            buttons.addArrangedSubview(Self.button("查看说明", target: self, action: #selector(openReadme)))
        }
        buttons.addArrangedSubview(Self.button("在 Finder 中显示", target: self, action: #selector(openFolder)))
        stack.addArrangedSubview(buttons)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: contentWidth)
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 200),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "插件详情"
        window.contentView = container
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        resizeToFit()
        window.center()

        // 异步加载图标与预览
        PluginIconLoader.resolveImage(raw: metadata.iconUrl, pluginFolder: folder) { image in
            if let image = image {
                iconView.image = PluginIconLoader.rounded(image, side: 64)
            }
        }
        PluginIconLoader.resolveImage(raw: metadata.previewUrl, pluginFolder: folder) { [weak self] image in
            guard let image = image else { return }

            previewView.image = image
            previewView.isHidden = false
            self?.resizeToFit()
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func resizeToFit() {
        guard let window = window, let content = window.contentView else { return }

        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        window.setContentSize(NSSize(width: contentWidth, height: height))
    }

    // MARK: - 操作

    @objc private func openAuthor() {
        if let string = plugin.metadata.authorUrl, let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openReadme() {
        let url = plugin.entryURL.deletingLastPathComponent().appendingPathComponent("README.md")
        NSWorkspace.shared.open(url)
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(plugin.entryURL.deletingLastPathComponent())
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: - 视图辅助

    private static func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        return field
    }

    private static func wrappingLabel(_ text: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.preferredMaxLayoutWidth = width
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }
}
