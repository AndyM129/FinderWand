import XCTest

/// GitHub 仓库地址解析、校验与 URL 拼接测试
final class GitHubRepoTests: XCTestCase {

    // MARK: - parse

    func testParsesOwnerRepoShorthand() {
        let result = GitHubRepo.parse("AndyM129/FinderWand-Plugins")
        XCTAssertEqual(result?.owner, "AndyM129")
        XCTAssertEqual(result?.repo, "FinderWand-Plugins")
    }

    func testParsesFullURLWithGitSuffixQueryAndWhitespace() {
        let result = GitHubRepo.parse("  https://github.com/AndyM129/FinderWand.git?tab=readme#top \n")
        XCTAssertEqual(result?.owner, "AndyM129")
        XCTAssertEqual(result?.repo, "FinderWand")
    }

    func testParsesURLWithExtraPathSegments() {
        let result = GitHubRepo.parse("https://github.com/AndyM129/FinderWand/tree/master/Sources")
        XCTAssertEqual(result?.owner, "AndyM129")
        XCTAssertEqual(result?.repo, "FinderWand")
    }

    func testRejectsMalformedInput() {
        let inputs = [
            "",
            "   ",
            "FinderWand",
            "Andy M129/FinderWand",
            "AndyM129/Finder Wand",
            "AndyM129/中文",
            "-AndyM129/FinderWand",
            "AndyM129-/FinderWand",
            "AndyM129/..",
            "../FinderWand",
            "Andy%2F/FinderWand",
            "AndyM129/Finder\\Wand",
        ]
        for input in inputs {
            XCTAssertNil(GitHubRepo.parse(input), "应拒绝: \(input.debugDescription)")
        }
    }

    // MARK: - URL 拼接

    func testBuildsAPIURL() {
        XCTAssertEqual(GitHubRepo.apiURL(owner: "AndyM129", repo: "FinderWand")?.absoluteString,
                       "https://api.github.com/repos/AndyM129/FinderWand")
        XCTAssertNil(GitHubRepo.apiURL(owner: "a b", repo: "c"))
    }

    func testBuildsTarballURLKeepingSlashInBranch() {
        XCTAssertEqual(GitHubRepo.tarballURL(owner: "o", repo: "r", branch: "feature/x")?.absoluteString,
                       "https://codeload.github.com/o/r/tar.gz/refs/heads/feature/x")
    }

    func testPercentEncodesNonASCIIBranch() {
        XCTAssertEqual(GitHubRepo.tarballURL(owner: "o", repo: "r", branch: "修复")?.absoluteString,
                       "https://codeload.github.com/o/r/tar.gz/refs/heads/%E4%BF%AE%E5%A4%8D")
    }

    func testRejectsUnsafeBranch() {
        let branches = ["", "a b", "a?b", "a#b", "a\\b", "../x", "a//b", "a/", "a\u{0}b"]
        for branch in branches {
            XCTAssertNil(GitHubRepo.tarballURL(owner: "o", repo: "r", branch: branch),
                         "应拒绝分支: \(branch.debugDescription)")
        }
    }
}
