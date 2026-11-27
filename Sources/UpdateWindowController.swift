import AppKit

/// 「软件更新」窗口：左侧 App 图标，右侧标题、版本对比、更新说明，底部按钮与安装进度
/// 替代原来的 NSAlert（NSAlert 只能竖排居中，更新说明区固定大小，内容少时大片留白）。
final class UpdateWindowController: NSObject, NSWindowDelegate {

    private let update: UpdateInfo
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    private let installButton = NSButton(title: "下载并安装", target: nil, action: nil)
    private let laterButton = NSButton(title: "稍后", target: nil, action: nil)
    private let pageButton = NSButton(title: "查看发布页", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    /// 右侧内容宽度
    private let contentWidth: CGFloat = 400

    init(update: UpdateInfo) {
        self.update = update
        super.init()
    }

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = Self.label("FinderWand 有新版本可用", font: .boldSystemFont(ofSize: 15))
        let subtitle = Self.label("v\(update.version) 已发布，当前版本为 \(AppInfo.displayVersion)。",
                                  font: .systemFont(ofSize: 12), color: .secondaryLabelColor)

        let right = NSStackView(views: [title, subtitle])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 4
        right.setCustomSpacing(14, after: subtitle)
        right.addArrangedSubview(Self.label("更新说明", font: .boldSystemFont(ofSize: 12)))
        right.addArrangedSubview(notesView())

        let top = NSStackView(views: [icon, right])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 16

        let root = NSStackView(views: [top, buttonRow()])
        root.orientation = .vertical
        root.alignment = .trailing
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "软件更新"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = container
        window.defaultButtonCell = installButton.cell as? NSButtonCell
        window.setContentSize(container.fittingSize)
        window.center()
        self.window = window

        // 更新说明从顶部开始显示
        notesScrollView?.contentView.scroll(to: .zero)
        notesScrollView?.reflectScrolledClipView(notesScrollView!.contentView)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 更新说明的滚动区，窗口显示时滚回顶部
    private var notesScrollView: NSScrollView?

    // MARK: - 视图

    /// 更新说明：按内容高度显示，最高 240pt，超出可滚动；去掉 GitHub 自动附加的「Full Changelog」行
    private func notesView() -> NSView {
        let markdown = ReleaseNotesRenderer.removingChangelogLink(update.notes)
        let text = markdown.isEmpty
            ? NSAttributedString(string: "这个版本没有填写更新说明，可在发布页查看。",
                                 attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            : ReleaseNotesRenderer.attributedString(markdown: markdown)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 10))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(text)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 40
        let height = min(max(used + 16, 44), 240)
        textView.frame.size.height = max(used + 16, height)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = used + 16 > 240
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        notesScrollView = scroll

        // 圆角浅底卡片（NSBox 的颜色随深浅色自动适配）
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .quaternaryLabelColor.withAlphaComponent(0.06)
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle
        box.contentView = scroll
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        box.heightAnchor.constraint(equalToConstant: height).isActive = true
        return box
    }

    /// 底部：左侧安装进度，右侧「查看发布页」「稍后」「下载并安装」
    private func buttonRow() -> NSView {
        for (button, action) in [(installButton, #selector(install)), (laterButton, #selector(later)), (pageButton, #selector(openPage))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        installButton.keyEquivalent = "\r"
        laterButton.keyEquivalent = "\u{1b}"
        if update.downloadURL == nil {
            installButton.isEnabled = false
            installButton.toolTip = "该版本没有提供安装包，请到发布页下载。"
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 220
        statusLabel.isHidden = true

        let status = NSStackView(views: [spinner, statusLabel])
        status.orientation = .horizontal
        status.spacing = 6

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [status, spacer, pageButton, laterButton, installButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 64 + 16 + contentWidth).isActive = true
        return row
    }

    // MARK: - 动作

    @objc private func install() {
        setBusy(true, status: "正在下载并校验 v\(update.version)…")
        UpdateInstaller.shared.install(update) { [weak self] message in
            self?.setBusy(false, status: "更新失败：\(message)", isError: true)
        }
    }

    @objc private func later() {
        window?.close()
    }

    @objc private func openPage() {
        NSWorkspace.shared.open(update.pageURL)
    }

    private func setBusy(_ busy: Bool, status: String, isError: Bool = false) {
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        statusLabel.stringValue = status
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = false
        installButton.isEnabled = !busy && update.downloadURL != nil
        laterButton.isEnabled = !busy
        window?.standardWindowButton(.closeButton)?.isEnabled = !busy
    }

    /// 窗口已打开时再次检查更新：置前即可
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private static func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        return label
    }
}
