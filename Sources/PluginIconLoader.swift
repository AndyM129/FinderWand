import AppKit
import CryptoKit

/// 插件图标 / 预览图加载器
/// - 相对路径：从插件文件夹内读取（限制在文件夹内，防穿越）。
/// - 网络图（http/https）：磁盘缓存。菜单场景同步返回缓存、未命中后台下载；详情窗口场景异步等待下载。
enum PluginIconLoader {

    /// 菜单图标边长（点）
    private static let menuSide: CGFloat = 16

    // MARK: - 菜单图标（同步）

    /// 菜单用图标：命中缓存/本地则返回圆角图，网络未命中则后台下载、下次打开显示
    static func menuIcon(for plugin: PluginService.InstalledPlugin) -> NSImage? {
        guard let raw = plugin.metadata.iconUrl?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }

        let folder = plugin.entryURL.deletingLastPathComponent()
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            guard let url = URL(string: raw) else { return nil }

            let cacheFile = cacheURL(for: raw)
            if FileManager.default.fileExists(atPath: cacheFile.path), let image = NSImage(contentsOf: cacheFile) {
                return rounded(image, side: menuSide)
            }

            downloadToCache(url: url, cacheFile: cacheFile, completion: nil)
            return nil
        }

        guard let image = relativeImage(folder: folder, relativePath: raw) else { return nil }
        return rounded(image, side: menuSide)
    }

    // MARK: - 详情窗口图片（异步）

    /// 解析图标/预览图为原始图片（未加圆角、原始尺寸）。相对图同步、网络图异步（等待下载）。
    /// completion 一律回主线程。
    static func resolveImage(raw: String?, pluginFolder: URL, completion: @escaping (NSImage?) -> Void) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            guard let url = URL(string: raw) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let cacheFile = cacheURL(for: raw)
            if FileManager.default.fileExists(atPath: cacheFile.path), let image = NSImage(contentsOf: cacheFile) {
                DispatchQueue.main.async { completion(image) }
                return
            }

            downloadToCache(url: url, cacheFile: cacheFile) { image in
                DispatchQueue.main.async { completion(image) }
            }
            return
        }

        let image = relativeImage(folder: pluginFolder, relativePath: raw)
        DispatchQueue.main.async { completion(image) }
    }

    // MARK: - 圆角

    /// 缩放到指定边长并加圆角（圆角比例参考 Apple macOS 图标规范，约 22.37% 边长）
    static func rounded(_ image: NSImage, side: CGFloat) -> NSImage {
        let target = NSSize(width: side, height: side)
        let radius = side * 0.2237

        let result = NSImage(size: target, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        result.isTemplate = false
        return result
    }

    // MARK: - 内部

    private static func relativeImage(folder: URL, relativePath: String) -> NSImage? {
        guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else { return nil }

        let fileURL = folder.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.path.hasPrefix(folder.standardizedFileURL.path) else { return nil }

        return NSImage(contentsOf: fileURL)
    }

    private static func downloadToCache(url: URL, cacheFile: URL, completion: ((NSImage?) -> Void)?) {
        var request = URLRequest(url: url)
        request.setValue("FinderWand", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard
                let data = data, !data.isEmpty,
                let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                let image = NSImage(data: data)
            else {
                completion?(nil)
                return
            }

            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: cacheFile)
            completion?(image)
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
}
