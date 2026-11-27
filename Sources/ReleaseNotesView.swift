import AppKit

/// 把 Release 的 Markdown 更新说明渲染成富文本
/// 只处理更新说明里常见的写法：标题（`#`）、列表（`-` / `*` / `1.`）、引用（`>`），
/// 以及行内的粗体、斜体、代码与链接；其余按普通文本显示。
enum ReleaseNotesRenderer {

    /// 去掉 GitHub 自动生成的「**Full Changelog**: <对比链接>」行（对用户没有信息量）
    static func removingChangelogLink(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n")
            .filter { !$0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces).hasPrefix("Full Changelog:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func attributedString(markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")


        // 空行不输出，段落间距由段落样式控制；标题前留出较大间距（第一行除外）
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 2
        bodyStyle.paragraphSpacing = 4
        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacing = 4
        headingStyle.paragraphSpacingBefore = 10

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            var text = line
            var font = bodyFont
            var prefix = ""
            var style = bodyStyle

            if let level = headingLevel(of: line) {
                style = result.length == 0 ? bodyStyle : headingStyle
                text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                font = NSFont.boldSystemFont(ofSize: bodyFont.pointSize + (level <= 2 ? 2 : 0))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                text = String(line.dropFirst(2))
                prefix = "• "
                // 列表项换行后与圆点后的文字对齐
                let listStyle = bodyStyle.mutableCopy() as! NSMutableParagraphStyle
                listStyle.headIndent = 12
                style = listStyle
            } else if line.hasPrefix(">") {
                text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                prefix = "┃ "
            }

            let indent = rawLine.prefix { $0 == " " }.count / 2
            let lineString = NSMutableAttributedString(string: String(repeating: "    ", count: indent) + prefix,
                                                       attributes: [.font: font])
            lineString.append(inline(text, font: font))
            lineString.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            lineString.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: lineString.length))
            result.append(lineString)
        }

        result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// `#` 开头且后跟空格时返回标题级别
    private static func headingLevel(of line: String) -> Int? {
        let level = line.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(level), line.dropFirst(level).first == " " else { return nil }

        return level
    }

    /// 行内 Markdown：粗体、斜体、代码、链接；解析失败时原样显示
    private static func inline(_ text: String, font: NSFont) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font])
        }

        let output = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.font: font]

            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                } else {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                        attributes[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                    }
                }
            }
            if let link = run.link {
                attributes[.link] = link
            }

            output.append(NSAttributedString(string: piece, attributes: attributes))
        }

        return output
    }
}
