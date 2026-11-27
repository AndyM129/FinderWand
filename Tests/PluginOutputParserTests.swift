import XCTest

/// 插件输出协议（xbar 精简子集）解析测试
final class PluginOutputParserTests: XCTestCase {

    func testEmptyOutputProducesNoItems() {
        XCTAssertTrue(PluginOutputParser.parse("").isEmpty)
        XCTAssertTrue(PluginOutputParser.parse("\n  \n").isEmpty)
    }

    func testNestedLevels() {
        let nodes = PluginOutputParser.parse("""
        一级
        --二级 A
        ----三级
        --二级 B
        另一个一级
        """)

        XCTAssertEqual(nodes.map(\.title), ["一级", "另一个一级"])
        XCTAssertEqual(nodes[0].children.map(\.title), ["二级 A", "二级 B"])
        XCTAssertEqual(nodes[0].children[0].children.map(\.title), ["三级"])
    }

    func testSeparatorsByDepth() {
        let nodes = PluginOutputParser.parse("""
        A
        --A1
        -----
        --A2
        ---
        B
        """)

        XCTAssertEqual(nodes.count, 3)
        XCTAssertTrue(nodes[1].isSeparator)
        XCTAssertEqual(nodes[0].children.count, 3)
        XCTAssertTrue(nodes[0].children[1].isSeparator)
    }

    func testBashActionWithParamsAndTerminal() {
        let nodes = PluginOutputParser.parse(#"运行 | bash="/tmp/my script.sh" param0=--flag param1="a b" terminal=true"#)

        guard case let .bash(path, args, terminal)? = nodes.first?.action else {
            return XCTFail("应解析为 bash 动作")
        }

        XCTAssertEqual(nodes.first?.title, "运行")
        XCTAssertEqual(path, "/tmp/my script.sh")
        XCTAssertEqual(args, ["--flag", "a b"])
        XCTAssertTrue(terminal)
    }

    func testShellAliasAndPositionalParamsStopAtGap() {
        let nodes = PluginOutputParser.parse("X | shell=/bin/echo param0=a param2=c")

        guard case let .bash(path, args, terminal)? = nodes.first?.action else {
            return XCTFail("应解析为 bash 动作")
        }

        XCTAssertEqual(path, "/bin/echo")
        XCTAssertEqual(args, ["a"])
        XCTAssertFalse(terminal)
    }

    func testHrefDisabledAndIcons() {
        let nodes = PluginOutputParser.parse("""
        链接 | href=https://example.com sfimage=link
        置灰 | disabled=true image=icon.png
        """)

        guard case let .href(url)? = nodes[0].action else {
            return XCTFail("应解析为 href 动作")
        }

        XCTAssertEqual(url, "https://example.com")
        XCTAssertEqual(nodes[0].sfimage, "link")
        XCTAssertTrue(nodes[0].enabled)
        XCTAssertFalse(nodes[1].enabled)
        XCTAssertEqual(nodes[1].image, "icon.png")
    }

    func testTitleWithoutParams() {
        let nodes = PluginOutputParser.parse("  只有标题  ")

        XCTAssertEqual(nodes.first?.title, "只有标题")
        XCTAssertNil(nodes.first?.action)
    }
}
