import Foundation

/// 新版本信息
struct UpdateInfo {
    /// 版本号，如 1.4.0
    let version: String
    /// 更新说明（Markdown）
    let notes: String
    /// dmg 安装包下载地址
    let downloadURL: URL?
    /// dmg 对应的 .sha256 校验文件地址
    let checksumURL: URL?
    /// Release 页地址
    let pageURL: URL
}

/// 检查更新结果
enum UpdateCheckResult {
    /// 已是最新
    case upToDate
    /// 有新版本
    case updateAvailable(UpdateInfo)
    /// 检查失败
    case failed(String)
}

/// 更新检查：查询 GitHub 最新正式版 Release，与当前版本比对。
/// 有新版本时可交给 `UpdateInstaller` 一键下载安装。
final class UpdateChecker {

    static let shared = UpdateChecker()

    /// 启动后首次自动检查的延迟（秒），避开开机时网络尚未就绪
    private let initialCheckDelay: TimeInterval = 30

    /// 自动检查的间隔（秒）：App 常驻菜单栏，每天检查一次
    private let checkInterval: TimeInterval = 24 * 60 * 60

    /// 已提醒过的最新版本（UserDefaults 键），同一版本只提醒一次
    private let notifiedVersionKey = "FWLastNotifiedUpdateVersion"

    private var timer: Timer?

    /// 开始自动静默检查：发现新版本时发一条系统通知（点击后弹出更新窗口），已是最新或失败时不打扰
    /// 本地开发构建（channel 为 dev）版本号不代表发布版本，不做自动检查。
    func startAutomaticChecks() {
        guard AppInfo.channel != "dev" else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + initialCheckDelay) { [weak self] in
            guard let self = self else { return }

            self.checkSilently()
            self.timer = Timer.scheduledTimer(withTimeInterval: self.checkInterval, repeats: true) { [weak self] _ in
                self?.checkSilently()
            }
        }
    }

    private func checkSilently() {
        check { [weak self] result in
            guard let self = self, case let .updateAvailable(update) = result else { return }
            guard UserDefaults.standard.string(forKey: self.notifiedVersionKey) != update.version else { return }

            UserDefaults.standard.set(update.version, forKey: self.notifiedVersionKey)
            UserNotifier.notify(title: "FinderWand 有新版本 v\(update.version)",
                                body: "点击查看更新说明，可一键安装。",
                                action: Self.showUpdateAction)
        }
    }

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

        var notes = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #if DEBUG
        // 调试：`defaults write <开发版 BundleID> FWDebugReleaseNotes -string "<Markdown>"` 覆盖更新说明，便于看排版
        if let debugNotes = UserDefaults.standard.string(forKey: "FWDebugReleaseNotes") { notes = debugNotes }
        #endif
        let pageURL = (json["html_url"] as? String).flatMap { URL(string: $0) } ?? AppInfo.repositoryURL
        let assets = assetURLs(from: json)
        let dmgName = assets.keys.first { $0.hasSuffix(".dmg") }

        return .updateAvailable(UpdateInfo(version: latestVersion,
                                           notes: notes,
                                           downloadURL: dmgName.flatMap { assets[$0] },
                                           checksumURL: dmgName.flatMap { assets[$0 + ".sha256"] },
                                           pageURL: pageURL))
    }

    /// 通知点击动作：弹出检查更新窗口（由菜单栏控制器注册处理）
    static let showUpdateAction = "showUpdate"

    /// assets 的「文件名 → 下载地址」
    private static func assetURLs(from json: [String: Any]) -> [String: URL] {
        let assets = json["assets"] as? [[String: Any]] ?? []
        var result: [String: URL] = [:]
        for asset in assets {
            if let name = asset["name"] as? String,
               let urlString = asset["browser_download_url"] as? String,
               let url = URL(string: urlString) {
                result[name] = url
            }
        }

        return result
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
