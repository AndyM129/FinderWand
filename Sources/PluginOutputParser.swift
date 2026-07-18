import Foundation

/// 菜单项动作
enum PluginAction {
    /// 执行命令：可执行文件路径 + 参数 + 是否在终端中运行
    case bash(path: String, args: [String], terminal: Bool)
    /// 打开链接
    case href(String)
}

/// 解析后的菜单节点（构建期用引用类型，便于按深度拼装树）
final class MenuNode {
    var title: String
    var isSeparator: Bool
    var enabled: Bool
    var action: PluginAction?
    var children: [MenuNode] = []

    /// SF Symbol 图标名（sfimage=）
    var sfimage: String?

    init(title: String, isSeparator: Bool = false, enabled: Bool = true, action: PluginAction? = nil) {
        self.title = title
        self.isSeparator = isSeparator
        self.enabled = enabled
        self.action = action
    }
}

/// 插件输出解析器（xbar 风格精简子集）
///
/// 协议约定（见 docs 与 PRD）：
///   - 每个非空行是一个菜单项。
///   - 层级用前导 `--` 对表示：无前缀为一级，`--` 为二级，`----` 为三级，依此类推。
///   - 纯 `-` 且长度 ≥3 的行是分隔线；`---` 为一级分隔线，`-----` 为二级，依此类推。
///   - 标题与参数用 ` | ` 分隔，参数为 `key=value`（value 可用双引号包裹）：
///       - `bash=<可执行路径>`（或 `shell=`）与 `param0..paramN=<arg>` 表示点击执行的命令与参数。
///       - `terminal=true` 表示在终端中运行（可见输出），默认后台静默执行。
///       - `href=<url>` 表示点击打开链接。
///       - `disabled=true` 表示不可点击（置灰）。
///       - `sfimage=<SF Symbol 名>` 为菜单项加图标（图标会按当前深浅色着色）。
///   - 脚本输出为空即不贡献任何菜单项（实现条件显示/隐藏）。
///
/// Finder Sync 限制（经确认）：右键菜单仅保留 `title`/`action`/`image`/`enabled`/`tag`/`state`/
/// `indentationLevel` 与子菜单；不支持 `attributedTitle`（即无法设置文本颜色/字体），
/// 也不支持原生分隔线（`NSMenuItem.separator()` 会显示为空行）。因此本实现不提供 color/font，
/// 分隔线以一条禁用的灰色横线模拟。
enum PluginOutputParser {

    /// 解析脚本输出为菜单节点树
    static func parse(_ output: String) -> [MenuNode] {
        var flat: [(depth: Int, node: MenuNode)] = []

        for rawLine in output.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // 分隔线：全为 '-' 且长度 >= 3
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) {
                let depth = max(0, (trimmed.count - 3) / 2)
                flat.append((depth, MenuNode(title: "", isSeparator: true, enabled: false)))
                continue
            }

            // 计算层级：前导 '--' 对
            var rest = Substring(rawLine)
            while rest.first == " " { rest = rest.dropFirst() }
            var depth = 0
            while rest.hasPrefix("--") {
                depth += 1
                rest = rest.dropFirst(2)
            }
            while rest.first == " " { rest = rest.dropFirst() }

            flat.append((depth, parseItem(String(rest))))
        }

        return buildTree(flat)
    }

    /// 解析单个条目（标题 + 参数）
    private static func parseItem(_ content: String) -> MenuNode {
        let parts = content.components(separatedBy: " | ")
        let title = parts[0].trimmingCharacters(in: .whitespaces)
        let node = MenuNode(title: title)

        guard parts.count > 1 else { return node }

        let params = parseParams(parts[1])
        if params["disabled"] == "true" {
            node.enabled = false
        }

        node.sfimage = params["sfimage"]

        if let href = params["href"] {
            node.action = .href(href)
        } else if let bash = params["bash"] ?? params["shell"] {
            node.action = .bash(path: bash,
                                args: collectPositionalParams(params),
                                terminal: params["terminal"] == "true")
        }

        return node
    }

    /// 收集 param0, param1, ... 顺序参数
    private static func collectPositionalParams(_ params: [String: String]) -> [String] {
        var args: [String] = []
        var index = 0
        while let value = params["param\(index)"] {
            args.append(value)
            index += 1
        }

        return args
    }

    /// 解析参数串为键值对，支持双引号包裹的值
    private static func parseParams(_ string: String) -> [String: String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false

        for ch in string {
            if ch == "\"" {
                inQuote.toggle()
                continue
            }
            if ch == " " && !inQuote {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }

        var result: [String: String] = [:]
        for token in tokens {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
            result[key] = value
        }

        return result
    }

    /// 按深度把扁平列表拼装为树
    private static func buildTree(_ flat: [(depth: Int, node: MenuNode)]) -> [MenuNode] {
        let root = MenuNode(title: "")
        var stack: [(depth: Int, node: MenuNode)] = [(-1, root)]

        for entry in flat {
            while let last = stack.last, last.depth >= entry.depth {
                stack.removeLast()
            }
            stack.last?.node.children.append(entry.node)
            stack.append((entry.depth, entry.node))
        }

        return root.children
    }
}
