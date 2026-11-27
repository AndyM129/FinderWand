import AppKit

/// 右键菜单图片编码器（主 App 侧）
/// 扩展处于沙箱，读不到插件目录，因此由主 App 把 `image=` 指向的图片缩放为菜单尺寸、编码为 PNG base64 传给扩展。
/// 按「插件文件夹 + 取值 + 文件 mtime」缓存，图片未变时右键不重复解码缩放。
enum MenuImageEncoder {

    /// 菜单图片边长（点），按 2x 输出
    private static let side: CGFloat = 16

    private static var cache: [String: (modificationDate: Date?, data: String?)] = [:]
    private static let lock = NSLock()

    /// 把 `image=` 的取值解析为 PNG base64；无法解析时返回 nil
    /// - 取值为插件文件夹内的相对路径时读取该文件（拒绝 `..` 与绝对路径，防穿越）；
    /// - 否则按 base64 图片数据解析（兼容 xbar 的 `image=` 写法）。
    static func encode(_ value: String, pluginFolder: URL) -> String? {
        let fileURL = relativeFile(value, in: pluginFolder)
        let modificationDate = fileURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
        }
        let key = pluginFolder.path + "\n" + value

        lock.lock()
        if let cached = cache[key], cached.modificationDate == modificationDate {
            lock.unlock()
            return cached.data
        }
        lock.unlock()

        let image: NSImage?
        if let fileURL = fileURL, modificationDate != nil {
            image = NSImage(contentsOf: fileURL)
        } else {
            image = Data(base64Encoded: value, options: .ignoreUnknownCharacters).flatMap(NSImage.init(data:))
        }
        let encoded = image.flatMap(pngBase64)

        lock.lock()
        cache[key] = (modificationDate, encoded)
        lock.unlock()

        return encoded
    }

    /// 插件文件夹内的相对文件；不合法或不在文件夹内时返回 nil
    private static func relativeFile(_ value: String, in folder: URL) -> URL? {
        guard !value.contains(".."), !value.hasPrefix("/") else { return nil }

        let fileURL = folder.appendingPathComponent(value).standardizedFileURL
        guard fileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return nil }

        return fileURL
    }

    /// 缩放到菜单尺寸（2x 像素）并编码为 PNG base64
    private static func pngBase64(_ image: NSImage) -> String? {
        let pixels = Int(side * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels,
                                         pixelsHigh: pixels,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero,
                   operation: .copy,
                   fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])?.base64EncodedString()
    }
}
