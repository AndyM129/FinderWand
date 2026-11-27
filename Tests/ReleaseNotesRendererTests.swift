import AppKit
import XCTest

/// 更新说明 Markdown 渲染测试
final class ReleaseNotesRendererTests: XCTestCase {

    func testRemovesMarkdownSyntaxAndKeepsLink() {
        let text = ReleaseNotesRenderer.attributedString(markdown: """
        ## 新增

        - 支持 **iTerm**，见 `terminal=iterm`
        * [发布页](https://github.com/AndyM129/FinderWand)

        **Full Changelog**: https://github.com/AndyM129/FinderWand/compare/v1.2.1...v1.3.0
        """)

        XCTAssertEqual(text.string, """
        新增
        • 支持 iTerm，见 terminal=iterm
        • 发布页
        Full Changelog: https://github.com/AndyM129/FinderWand/compare/v1.2.1...v1.3.0

        """)

        let linkRange = (text.string as NSString).range(of: "发布页")
        let link = text.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://github.com/AndyM129/FinderWand")

        let boldRange = (text.string as NSString).range(of: "iTerm")
        let font = text.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testRemovesGitHubChangelogLink() {
        let notes = "### 新增\n\n- A\n\n**Full Changelog**: https://github.com/x/y/compare/v1...v2"
        XCTAssertEqual(ReleaseNotesRenderer.removingChangelogLink(notes), "### 新增\n\n- A")
        XCTAssertEqual(ReleaseNotesRenderer.removingChangelogLink("**Full Changelog**: https://x"), "")
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(ReleaseNotesRenderer.attributedString(markdown: "修复若干问题").string, "修复若干问题\n")
    }
}
