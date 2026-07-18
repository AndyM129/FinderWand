import Foundation

/// 检查更新结果
enum UpdateCheckResult {
    /// 已是最新
    case upToDate
    /// 有新版本
    case updateAvailable(version: String, notes: String, downloadURL: URL?, pageURL: URL)
    /// 检查失败
    case failed(String)
}

/// 轻量更新检查：查询 GitHub 最新正式版 Release，与当前版本比对
/// 不做自动下载安装，仅提示并引导用户下载安装包或打开 Release 页。
final class UpdateChecker {

    static let shared = UpdateChecker()

    /// 检查更新，结果回调在主线程
    func check(completion: @escaping (UpdateCheckResult) -> Void) {
        var request = URLRequest(url: AppInfo.latestReleaseAPI)
        request.setValue("FinderWand", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Self.makeResult(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// 解析 API 响应得出结果
    private static func makeResult(data: Data?, response: URLResponse?, error: Error?) -> UpdateCheckResult {
        if let error = error {
            return .failed(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }

        if status == 404 {
            return .failed("未找到正式版发布。若仓库为私有，请将其设为公开后重试。")
        }

        guard (200 ... 299).contains(status) else {
            let message = (json?["message"] as? String) ?? "HTTP \(status)"
            return .failed("检查更新失败：\(message)")
        }

        guard let json = json, let tag = json["tag_name"] as? String else {
            return .failed("无法解析更新信息")
        }

        let latestVersion = normalizeVersion(tag)
        let currentVersion = AppInfo.shortVersion

        guard isVersion(latestVersion, newerThan: currentVersion) else {
            return .upToDate
        }

        let notes = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pageURL = (json["html_url"] as? String).flatMap { URL(string: $0) } ?? AppInfo.repositoryURL
        let downloadURL = dmgAssetURL(from: json)

        return .updateAvailable(version: latestVersion, notes: notes, downloadURL: downloadURL, pageURL: pageURL)
    }

    /// 从 assets 中取 .dmg 的下载地址
    private static func dmgAssetURL(from json: [String: Any]) -> URL? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }

        for asset in assets {
            if let name = asset["name"] as? String,
               name.hasSuffix(".dmg"),
               let urlString = asset["browser_download_url"] as? String,
               let url = URL(string: urlString) {
                return url
            }
        }

        return nil
    }

    /// 归一化版本号：去掉前导 v 与 -beta 等后缀，保留 x.y.z
    private static func normalizeVersion(_ tag: String) -> String {
        var value = tag
        if value.hasPrefix("v") { value.removeFirst() }
        if let dashIndex = value.firstIndex(of: "-") {
            value = String(value[..<dashIndex])
        }

        return value
    }

    /// 语义化比较：a 是否比 b 新
    private static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }

        for index in 0 ..< max(pa.count, pb.count) {
            let x = index < pa.count ? pa[index] : 0
            let y = index < pb.count ? pb[index] : 0
            if x != y { return x > y }
        }

        return false
    }
}
