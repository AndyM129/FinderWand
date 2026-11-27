import XCTest

/// 插件元信息解析与 enabled 写回测试
final class PluginMetadataTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderWandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeEntry(_ content: String) throws -> URL {
        let url = directory.appendingPathComponent("main.sh")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParsesAllFields() throws {
        let entry = try writeEntry("""
        #!/bin/bash
        # ---
        # schema: 1
        # id: git-helper
        # title: Git 助手
        # description: 常用 Git 快捷操作
        # iconUrl: icon.png
        # previewUrl: https://example.com/preview.png
        # tags: [git, vcs]
        # version: 1.0.0
        # author: AndyM129
        # authorUrl: https://github.com/AndyM129
        # minAppVersion: 0.1.9
        # enabled: false
        # timeout: 1.8
        # unknownKey: ignored
        # ---
        echo hi
        """)

        let metadata = PluginMetadataStore.parse(entryURL: entry)

        XCTAssertEqual(metadata.schema, 1)
        XCTAssertEqual(metadata.id, "git-helper")
        XCTAssertEqual(metadata.title, "Git 助手")
        XCTAssertEqual(metadata.pluginDescription, "常用 Git 快捷操作")
        XCTAssertEqual(metadata.iconUrl, "icon.png")
        XCTAssertEqual(metadata.previewUrl, "https://example.com/preview.png")
        XCTAssertEqual(metadata.tags, ["git", "vcs"])
        XCTAssertEqual(metadata.version, "1.0.0")
        XCTAssertEqual(metadata.author, "AndyM129")
        XCTAssertEqual(metadata.authorUrl, "https://github.com/AndyM129")
        XCTAssertEqual(metadata.minAppVersion, "0.1.9")
        XCTAssertFalse(metadata.enabled)
        XCTAssertEqual(metadata.timeout, 1.8)
    }

    func testDefaultsWithoutBlock() throws {
        let metadata = PluginMetadataStore.parse(entryURL: try writeEntry("#!/bin/bash\necho hi\n"))

        XCTAssertNil(metadata.title)
        XCTAssertTrue(metadata.enabled)
        XCTAssertNil(metadata.timeout)
    }

    func testBlockStopsAtClosingMarker() throws {
        let metadata = PluginMetadataStore.parse(entryURL: try writeEntry("""
        #!/bin/bash
        # ---
        # title: 前
        # ---
        # version: 9.9.9
        """))

        XCTAssertEqual(metadata.title, "前")
        XCTAssertNil(metadata.version)
    }

    func testTimeoutIsClampedAndInvalidIgnored() throws {
        let tooLarge = PluginMetadataStore.parse(entryURL: try writeEntry("# ---\n# timeout: 10\n# ---\n"))
        XCTAssertEqual(tooLarge.timeout, PluginMetadata.allowedTimeout.upperBound)

        let tooSmall = PluginMetadataStore.parse(entryURL: try writeEntry("# ---\n# timeout: 0.01\n# ---\n"))
        XCTAssertEqual(tooSmall.timeout, PluginMetadata.allowedTimeout.lowerBound)

        let invalid = PluginMetadataStore.parse(entryURL: try writeEntry("# ---\n# timeout: abc\n# ---\n"))
        XCTAssertNil(invalid.timeout)
    }

    func testSetEnabledUpdatesExistingLine() throws {
        let entry = try writeEntry("#!/bin/bash\n# ---\n# title: T\n# enabled: true\n# ---\necho hi\n")

        XCTAssertTrue(PluginMetadataStore.setEnabled(false, forEntry: entry))

        let content = try String(contentsOf: entry, encoding: .utf8)
        XCTAssertEqual(content, "#!/bin/bash\n# ---\n# title: T\n# enabled: false\n# ---\necho hi\n")
    }

    func testSetEnabledInsertsIntoBlockOrCreatesBlock() throws {
        let withBlock = try writeEntry("#!/bin/bash\n# ---\n# title: T\n# ---\necho hi\n")
        XCTAssertTrue(PluginMetadataStore.setEnabled(false, forEntry: withBlock))
        XCTAssertEqual(try String(contentsOf: withBlock, encoding: .utf8),
                       "#!/bin/bash\n# ---\n# title: T\n# enabled: false\n# ---\necho hi\n")

        let withoutBlock = try writeEntry("#!/bin/bash\necho hi\n")
        XCTAssertTrue(PluginMetadataStore.setEnabled(false, forEntry: withoutBlock))
        XCTAssertEqual(try String(contentsOf: withoutBlock, encoding: .utf8),
                       "#!/bin/bash\n# ---\n# enabled: false\n# ---\necho hi\n")
    }

    func testSetEnabledRefusesUnclosedBlock() throws {
        let entry = try writeEntry("#!/bin/bash\n# ---\n# title: T\n")

        XCTAssertFalse(PluginMetadataStore.setEnabled(false, forEntry: entry))
    }
}
