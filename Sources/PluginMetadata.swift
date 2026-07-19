import Foundation

/// 插件元信息（解析自 `main.sh` 头部紧跟 shebang 的 `# --- ... # ---` 注释块）
/// 用于分享、安装、管理时的信息显示与校验。因为是注释，脚本执行时会被 shell 跳过，不影响执行效率。
struct PluginMetadata {

    /// 元信息格式版本
    var schema: Int?

    /// 插件唯一标识（安装后即文件夹名）
    var id: String?

    /// 插件标题
    var title: String?

    /// 插件简介
    var pluginDescription: String?

    /// 图标地址（网络图或插件文件夹内相对图）
    var iconUrl: String?

    /// 预览效果图地址（网络图或插件文件夹内相对图）
    var previewUrl: String?

    /// 标签
    var tags: [String] = []

    /// 插件版本
    var version: String?

    /// 作者
    var author: String?

    /// 作者主页
    var authorUrl: String?

    /// 安装该插件所需的最低 App 版本
    var minAppVersion: String?

    /// 启用开关：缺省视为 true，仅显式为 false 时禁用
    var enabled: Bool = true
}

/// 插件元信息解析与缓存
/// 解析策略：只读文件头文本、受限 `key: value` 子集、读到闭合 `# ---` 即停，绝不执行脚本。
/// 缓存策略：按「路径 + mtime」缓存，文件未变直接命中，避免每次右键重复解析。
enum PluginMetadataStore {

    private struct CacheEntry {
        let modificationDate: Date
        let metadata: PluginMetadata
    }

    private static var cache: [String: CacheEntry] = [:]
    private static let lock = NSLock()

    /// 获取入口脚本（main.sh）的元信息，按 mtime 命中缓存
    static func metadata(forEntry entryURL: URL) -> PluginMetadata {
        let path = entryURL.path
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date

        lock.lock()
        if let cached = cache[path], let mtime = modificationDate, cached.modificationDate == mtime {
            lock.unlock()
            return cached.metadata
        }
        lock.unlock()

        let parsed = parse(entryURL: entryURL)

        if let mtime = modificationDate {
            lock.lock()
            cache[path] = CacheEntry(modificationDate: mtime, metadata: parsed)
            lock.unlock()
        }

        return parsed
    }

    /// 从文件头解析元信息（无块或无法读取时返回默认值）
    static func parse(entryURL: URL) -> PluginMetadata {
        var metadata = PluginMetadata()

        guard let content = try? String(contentsOf: entryURL, encoding: .utf8) else {
            return metadata
        }

        var insideBlock = false
        for rawLine in content.components(separatedBy: "\n") {
            // 跳过 shebang
            if rawLine.hasPrefix("#!") { continue }

            // 只认注释行；块内遇到非注释行视为块结束（容错）
            guard let comment = strippedCommentLine(rawLine) else {
                if insideBlock { break }

                continue
            }

            // 边界标记 `# ---`
            if comment == "---" {
                if insideBlock { break }

                insideBlock = true
                continue
            }

            guard insideBlock else { continue }

            apply(commentLine: comment, to: &metadata)
        }

        return metadata
    }

    /// 去掉行首 `#` 与随后的空白，非注释行返回 nil
    private static func strippedCommentLine(_ line: String) -> String? {
        let trimmedLeading = line.drop { $0 == " " || $0 == "\t" }
        guard trimmedLeading.first == "#" else { return nil }

        var rest = trimmedLeading.dropFirst()
        while rest.first == " " || rest.first == "\t" { rest = rest.dropFirst() }

        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    /// 解析一行 `key: value` 并写入元信息
    private static func apply(commentLine: String, to metadata: inout PluginMetadata) {
        guard let colon = commentLine.firstIndex(of: ":") else { return }

        let key = String(commentLine[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(commentLine[commentLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if key.isEmpty || value.isEmpty { return }

        switch key {
        case "schema": metadata.schema = Int(value)
        case "id": metadata.id = value
        case "title": metadata.title = value
        case "description": metadata.pluginDescription = value
        case "iconUrl": metadata.iconUrl = value
        case "previewUrl": metadata.previewUrl = value
        case "tags": metadata.tags = parseTags(value)
        case "version": metadata.version = value
        case "author": metadata.author = value
        case "authorUrl": metadata.authorUrl = value
        case "minAppVersion": metadata.minAppVersion = value
        case "enabled": metadata.enabled = (value.lowercased() != "false")
        default: break // 未知 key 忽略，保证向后兼容
        }
    }

    /// 解析内联数组 `[a, b, c]`，逗号切分去空格；不支持嵌套与带逗号的引号值
    private static func parseTags(_ value: String) -> [String] {
        var inner = value
        if inner.hasPrefix("[") { inner = String(inner.dropFirst()) }
        if inner.hasSuffix("]") { inner = String(inner.dropLast()) }

        return inner
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
