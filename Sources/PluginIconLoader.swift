import AppKit
import CryptoKit

/// 已安装插件的图标加载器（用于「已安装插件」菜单展示）
/// - 相对路径：从插件文件夹内读取（限制在文件夹内，防穿越）。
/// - 网络图（http/https）：磁盘缓存；命中则同步返回，未命中则后台下载到缓存，下次打开菜单即显示。
/// 说明：菜单每次打开都会同步构建，故网络图不做同步下载以免卡住菜单。
enum PluginIconLoader {

    /// 菜单图标边长（点）
    private static let side: CGFloat = 16

    /// 获取插件图标，无 iconUrl 或加载失败返回 nil
    static func icon(for plugin: PluginService.InstalledPlugin) -> NSImage? {
        guard let raw = plugin.metadata.iconUrl?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }

        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return networkIcon(urlString: raw)
        }

        let folder = plugin.entryURL.deletingLastPathComponent()
        return relativeIcon(folder: folder, relativePath: raw)
    }

    // MARK: - 相对图

    private static func relativeIcon(folder: URL, relativePath: String) -> NSImage? {
        // 防路径穿越：不允许 ".." 或绝对路径
        guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else { return nil }

        let fileURL = folder.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.path.hasPrefix(folder.standardizedFileURL.path) else { return nil }

        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        return sized(image)
    }

    // MARK: - 网络图（磁盘缓存）

    private static func networkIcon(urlString: String) -> NSImage? {
        guard let url = URL(string: urlString) else { return nil }

        let cacheFile = cacheURL(for: urlString)
        if FileManager.default.fileExists(atPath: cacheFile.path), let image = NSImage(contentsOf: cacheFile) {
            return sized(image)
        }

        downloadToCache(url: url, cacheFile: cacheFile)
        return nil
    }

    private static func downloadToCache(url: URL, cacheFile: URL) {
        var request = URLRequest(url: url)
        request.setValue("FinderWand", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard
                let data = data, !data.isEmpty,
                let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                NSImage(data: data) != nil
            else { return }

            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: cacheFile)
        }
        task.resume()
    }

    private static func cacheURL(for urlString: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("FinderWand/PluginIcons", isDirectory: true)

        let digest = SHA256.hash(data: Data(urlString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name)
    }

    // MARK: - 尺寸与圆角

    /// 缩放到菜单图标尺寸并加圆角（圆角比例参考 Apple macOS 图标规范，约 22.37% 边长）
    private static func sized(_ image: NSImage) -> NSImage {
        let target = NSSize(width: side, height: side)
        let radius = side * 0.2237

        // 用 drawingHandler 版本，随分辨率重绘，Retina 下清晰
        let result = NSImage(size: target, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        result.isTemplate = false
        return result
    }
}
