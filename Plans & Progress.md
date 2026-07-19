> 本文档是对 `PRD.md` 中任务的拆解，用于逐个任务推进，并在各子任务下记录、维护计划、开发、测试的进展与进度，以及相关决定与结论，避免遗忘或反复修改。
>
> 状态图例：`未开始` / `进行中` / `已完成` / `已搁置`

# 1、总体说明

## 1.1、技术栈与约束

- 语言与框架：Swift + AppKit。
- 目标系统：Deployment Target macOS 14.0（最低支持），推荐运行环境 macOS 15 及以上。
- 分发方式：无付费 Apple 开发者账号，仅通过 GitHub Releases 提供 `.dmg` 安装包，不做公证（notarization）。
- 权限约束：使用过程中涉及文件夹权限时，不得出现授权弹窗或提示。
- 参考项目：EdgeMark（打包与 GitHub Actions 配置参考），xbar（插件脚本协议参考）。
- 代码仓库：github.com/andym129/FinderWand（用于 Releases 发布、检查更新、关于页跳转）。

## 1.2、里程碑划分

- 每个里程碑完成后都应可打包为 `.dmg` 并在 GitHub Releases 发布。
- 里程碑顺序：M0 工程初始化，M1 打包与发布流水线，M2 菜单栏基础功能，M3 Finder 右键菜单核心能力，M4 自动更新与开机自启，M5 插件协议完善。
- 说明：先跑通打包与发布流程（M1），再逐步叠加功能。

# 2、里程碑拆解

## 2.1、M0：工程初始化（状态：已完成）

目标：搭建可编译运行的最小 AppKit 工程骨架。

技术决策：

- 工程生成：采用 XcodeGen（`project.yml` 声明式生成 `.xcodeproj`），工程文件不纳入版本管理，避免 `pbxproj` 冲突。
- 版本区分：单 target，通过 Build Configuration（`Debug` / `Release`）加 `xcconfig` 区分 Dev 版与正式版的 BundleID、App Name。不使用两个独立 target。
- 构建缓存：通过构建脚本与 CI 统一传入 `-derivedDataPath ./.build/DerivedData`，将 DerivedData 固定到项目根目录下，独立维护。
- 签名：无付费账号，本地 ad-hoc 签名（`CODE_SIGN_IDENTITY = -`），不强制签名。
- Xcode：本机装有 Xcode 26.x，命令行通过 `DEVELOPER_DIR` 指向 Xcode.app 调用 `xcodebuild`（当前 `xcode-select` 指向 CommandLineTools，不改全局配置）。

任务：

- 创建 Xcode 工程（App 类型，AppKit 生命周期，非 Storyboard 可选）。
- 配置应用为菜单栏常驻应用（`LSUISafeElement` / `LSUIElement`，不显示 Dock 图标）。
- 配置编译、构建缓存路径到项目根目录下的特定文件夹（`./.build/DerivedData`），独立维护，避免受其他项目影响或被清理删除。
- 通过 Build Configuration 加 `xcconfig` 区分两套配置：
  - 开发版（Debug）：BundleID `io.github.andym129.dev.finder-wand`，App Name `Finder Wand Dev`。
  - 正式版（Release）：BundleID `io.github.andym129.finder-wand`，App Name `Finder Wand`。
- 建立基础目录结构与代码分层（App 入口、菜单栏控制器、插件加载、动作执行）。
- 将 Deployment Target 设为 macOS 14.0 并写入工程配置。

进展记录：

- 已完成。工程结构：`project.yml`（XcodeGen）、`Configs/{Base,Dev,Release}.xcconfig`、`Sources/{main.swift,AppDelegate.swift}`、`scripts/build.sh`。
- `main.swift` 为应用入口，`AppDelegate` 创建菜单栏 `NSStatusItem`，M0 菜单仅含「退出 Finder Wand」，占位图标用系统符号 `wand.and.stars`。
- 已验证 Debug 与 Release 两套配置均 `BUILD SUCCEEDED`：
  - Debug（开发版）：`Finder Wand Dev.app`，BundleID `io.github.andym129.dev.finder-wand`。
  - Release（正式版）：`Finder Wand.app`，BundleID `io.github.andym129.finder-wand`。
  - 两者 `LSUIElement = true`（菜单栏常驻，无 Dock 图标），`LSMinimumSystemVersion = 14.0`。
- DerivedData 已固定到 `./.build/DerivedData`；`.xcodeproj` 由 XcodeGen 生成，不纳入版本管理。
- 构建命令：`./scripts/build.sh [Debug|Release]`（脚本自动探测 Xcode.app 并设置 `DEVELOPER_DIR`）。

## 2.2、M1：打包与发布流水线（状态：已完成）

目标：实现 `.dmg` 打包与 GitHub Releases 自动发布，优先跑通打包与发布流程。

任务：

- 参考 EdgeMark 的 `.github/workflows` 配置搭建 CI。
- 构建产物打包为 `.dmg`。
- 版本号与测试版标识（beta、commit 短哈希、时间戳）注入构建流程。
- 触发策略：推送 tag（如 `v0.1.0`）时构建并发布正式版 Release，`workflow_dispatch` 手动触发构建测试版。
- 自动创建 GitHub Release 并上传 `.dmg`。

进展记录：

- 已编写打包脚本 `scripts/package-dmg.sh`：生成工程，编译 Release 通用二进制（arm64 + x86_64），注入渠道/commit/时间戳到 Info.plist（键 `FWBuildChannel`、`FWGitCommit`、`FWBuildTimestamp`，供 M2 版本显示），ad-hoc 重签后用 `hdiutil` 产出 `.dmg` 与 `.sha256`。
- 已编写 `.github/workflows/build-release.yml`：tag `v*` 触发正式版（`prerelease=false`，版本取自 tag），`workflow_dispatch` 触发测试版（`prerelease=true`，tag 形如 `v0.1.0-beta-<短哈希>-<时间戳>`）；用 `softprops/action-gh-release@v2` 创建 Release 并上传产物。CI 内通过 `setup-xcode` 与 `brew install xcodegen` 准备环境。
- 参考实现：EdgeMark 的 `.github/workflows/build.yml`（hdiutil 打包 + action-gh-release 的做法）。
- 本地已验证：编译成功、版本与元信息注入成功、ad-hoc 签名成功。`.dmg` 生成本地被阻断：本机对包含 `.app` 的目录执行 `hdiutil create` 返回「操作不被允许」（TCC/App Management 限制，普通文件夹打包正常），该步骤留待 GitHub Actions（macOS runner）首次运行验证。
- CI 已验证通过：为使 `workflow_dispatch` 可用，已将 `master`（默认分支）快进到 `dev` 并推送。网页手动触发 beta 成功产出并可正常安装使用，产物名 `FinderWand-v0.1.0-beta-71356b4-20260718112152.dmg`，测试版命名格式 `v<版本>-beta-<短哈希>-<时间戳>` 符合预期。
- 正式版已验证：推送 tag `v0.1.0` 成功触发正式版 Release，产物可正常安装。后续正式版发布方式即为推送 `vX.Y.Z` tag。

## 2.3、M2：菜单栏基础功能（状态：已完成）

目标：实现系统菜单栏图标及其下拉子菜单（不依赖 M4 的项除外）。

范围说明：「检查更新」「开机自动运行」依赖 M4 的自动更新能力，随 M4 一并开发，M2 不实现。

任务：

- 菜单栏显示 App 图标，点击弹出菜单。
- 菜单项：刷新（重新加载配置）。
- 菜单项：打开插件目录（在 Finder 中打开 `~/.config/FinderWand`，目录不存在时自动创建）。
- 分割线。
- 菜单项：当前版本号显示（区分正式版与测试版，测试版格式 `v0.1.0（beta-<短哈希>-<时间戳>）`，复用 M1 注入的 `FWBuildChannel`/`FWGitCommit`/`FWBuildTimestamp`）。
- 菜单项：关于 Finder Wand（在浏览器打开项目 GitHub 主页）。
- 分割线。
- 菜单项：退出 Finder Wand。

进展记录：

- 已新增 `Sources/AppInfo.swift`：集中提供版本号、构建渠道、仓库地址、插件目录（`~/.config/FinderWand`）、当前版本 Release 页地址。`displayVersion` 按渠道输出：正式版 `v0.1.0`，测试版 `v0.1.0（beta-<短哈希>-<时间戳>）`，本地开发 `v0.1.0（dev）`。
- 已新增 `Sources/MenuBarController.swift`：承接菜单栏 `NSStatusItem` 与菜单构建/动作（刷新、打开插件目录、版本号、关于、退出）。`AppDelegate` 精简为仅创建该控制器。
- 「打开插件目录」会先 `createDirectory(withIntermediateDirectories:)` 再用 `NSWorkspace` 打开，目录不存在时自动创建。已验证可正常创建并打开 `~/.config/FinderWand`。
- 「当前版本号」改为可点击，点击打开当前版本对应的 Release 页（`releaseTag`：正式版 `vX.Y.Z`，测试版 `vX.Y.Z-beta-<短哈希>-<时间戳>`；本地开发无对应 tag，改为打开 Releases 列表页）。
- 「关于」打开仓库主页 `https://github.com/AndyM129/FinderWand`（PRD 已同步修正为「仓库主页」）。
- Debug 配置 `BUILD SUCCEEDED`。

## 2.4、M3：Finder 右键菜单核心能力（状态：已完成）

目标：在任意路径下呼出 Finder 右键菜单时，动态生成菜单项并执行动作。

任务：

- 选型确认：Finder 右键菜单扩展实现方式（如 Finder Sync Extension 或其他方案），需满足无权限弹窗约束。
- 每次呼出右键菜单时遍历插件目录下的 `.sh` 文件，每个 `.sh` 对应一个一级菜单项。
- 将当前所在路径与所有选中文件路径传入 `.sh`。
- 菜单项点击时执行指定动作（shell / python / nodejs 等命令）。

进展记录：

- 方案调研（2026-07-18）：对比 Finder Sync Extension、Services 菜单、自建方案，结论是 Finder Sync Extension 是唯一能满足「任意路径、每次右键动态生成多级菜单」的受支持 API，倾向采用。关键事实与风险如下。
- 可行性（可行）：
  - 右键菜单入口：实现 `FIFinderSync` 子类的 `menu(for:)`，`FIMenuKindContextualMenuForItems`/`ForContainer` 覆盖「选中项/空白处」两种右键场景。
  - 覆盖任意路径：`FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]`（监控根目录）即可让菜单在任意路径出现，多方来源验证可行。
  - 获取上下文：`targetedURL()` 拿右键点击的目标，`selectedItemURLs()` 拿所有选中项（仅在 `menu(for:)` 及其 action 内有效）。
  - 动态多级菜单：`menu(for:)` 返回的 `NSMenu` 支持子菜单嵌套，可按脚本输出构建。
- 主要风险：
  - R1（高，无付费账号）：扩展必须随包分发且需签名。ad-hoc 签名（无 Developer ID）下，Gatekeeper 要求用户先手动信任并打开主 App，才能启用扩展；`.dmg` 分发会带 quarantine，需用户清除或批准。首次启用需在「系统设置 > 通用 > 登录项与扩展」手动开启。可用但有一次性手动门槛，且跨系统版本稳定性需实测。
  - R2（高，沙箱强制）：Finder Sync 扩展必须开启 App Sandbox，否则系统拒绝加载。沙箱内无法自由执行任意 `.sh` 或访问任意路径（子进程继承沙箱）。因此需架构拆分：沙箱内的扩展只负责收集路径与构建菜单，把「执行脚本」通过 XPC 委托给非沙箱的主 App 执行。
  - R3（中）：`menu(for:)` 是同步调用，若右键时同步跑脚本决定菜单项，脚本慢会卡住 Finder。需设超时与快速返回策略。
  - R4（中，与「无权限弹窗」约束冲突）：主 App（非沙箱）执行脚本访问「桌面/文档/下载」等 TCC 保护目录时，首次会触发系统授权弹窗。规避方式是让用户一次性授予「完全磁盘访问」，属一次性设置而非每次弹窗。
  - R5（低到中）：监控根目录 `/` 属非常规用法，我们只用右键菜单、不加 badge，额外开销有限，但需实测。
- 架构结论：主 App（非沙箱, LSUIElement）+ Finder Sync Extension（沙箱, appex）通过 XPC 通信；扩展负责菜单 UI 与路径收集，主 App 负责遍历 `.sh`、执行脚本与解析输出。
- 待决策：是否接受 R1/R4 的一次性手动设置（信任 App、开启扩展、授予完全磁盘访问）作为使用前提；是否先做技术验证（spike）确认 ad-hoc 扩展能在你的 macOS 26 上加载并弹出右键菜单，再正式开发 M3。
- 决策（2026-07-18）：采用 Finder Sync Extension 方案；用户接受一次性手动设置；先做 spike 验证。
- spike 已构建（2026-07-18）：
  - `project.yml` 新增 `FinderWandSync`（`app-extension`，沙箱）target 并嵌入主 App（`Contents/PlugIns/FinderWandSync.appex`）。
  - `FinderSyncExtension/FinderSync.swift`：`FIFinderSync` 子类，监控根目录 `/`，`menu(for:)` 提供「Finder Wand: 测试点位」菜单项，点击发送 Darwin 通知。
  - `Sources/SpikeMonitor.swift`：主 App 监听该 Darwin 通知，收到后向 `~/.config/FinderWand/spike.log` 追加时间戳，验证「沙箱扩展 → 非沙箱主 App」链路。
  - 构建校验：Debug `BUILD SUCCEEDED`，appex 正确嵌入；Info.plist 含 `NSExtensionPointIdentifier=com.apple.FinderSync`、`NSExtensionPrincipalClass=FinderWandSync.FinderSync`；BundleID `io.github.andym129.dev.finder-wand.FinderSync`；ad-hoc 签名且含 `app-sandbox` 权限。
  - 待用户手动验证：启动 App 注册扩展 → 系统设置开启扩展 → 任意路径右键应出现菜单项 → 点击后 `spike.log` 应追加记录。
  - spike 结论（2026-07-18，已验证）：菜单项在任意路径右键出现，点击后 `spike.log` 正常追加。证明 ad-hoc 扩展可加载、菜单可全局出现、「沙箱扩展 → 非沙箱主 App」链路成立。可进入 M3 正式实现。
- slice 1 已实现（2026-07-18，每个 `.sh` = 一级菜单项，点击经主 App 执行）：
  - IPC 方案：扩展容器文件 + Darwin 信号（不使用 App Group）。`Shared/FWIPC.swift` 为两 target 共享常量（Darwin 名、插件目录、IPC 目录推导）。
  - 扩展 `FinderSync.swift`：枚举插件目录 `.sh`（需 `temporary-exception` 读权限），每个作为一级菜单项；点击时收集当前目录与选中项，写请求 JSON 到扩展容器 IPC 目录并发 Darwin 通知。
  - 主 App `PluginActionService.swift`：监听 Darwin 通知，读取扩展容器内的请求，执行脚本（尊重 shebang，传入 argv 与 `FW_CURRENT_DIR`/`FW_SELECTED_PATHS`），结果写 `~/.config/FinderWand/run.log`。
  - 已用示例插件 `~/.config/FinderWand/hello.sh` 便于验证。
  - 构建校验：Debug `BUILD SUCCEEDED`，扩展权限含 `.config/FinderWand/` 读例外。待用户运行验证右键出现「hello」项、点击后 `run.log` 记录脚本输出。
  - 修正（2026-07-18）：沙箱扩展直接读插件目录不可行（`home` 解析为容器、`temporary-exception` 实测未生效，右键显示「无插件」）。改为「清单中转」方案：主 App 枚举 `.sh` 并把清单写入扩展容器内（`.../Data/Library/Application Support/FinderWandIPC/manifest.json`），扩展只读自己容器内的清单构建菜单，无需任何插件目录读权限。主 App 在启动、收到扩展 refresh 通知、以及插件目录变更（`DispatchSource` 监听）时刷新清单。已移除扩展的 `temporary-exception` 权限。`Sources/DarwinObserverRegistry.swift` 按通知名分发 Darwin 通知。
  - 修正（2026-07-18）：点击菜单项无反应，定位为 `NSMenuItem.representedObject` 无法跨 Finder Sync 的 XPC 存活；改用菜单项 `title` 回查清单取脚本路径（title 可靠存活）。
  - slice 1 已验证通过（2026-07-18）：右键任意路径出现 `hello`，点击后 `run.log` 记录脚本执行结果（`exit=0`、`currentDir`、`selected`、stdout 均正确）。整条链路成立：扩展菜单 → title 回查清单 → 写请求到容器 → Darwin → 主 App 执行脚本 → 写日志。诊断代码已移除。
- slice 2 已实现（2026-07-18，xbar 风格动态多级菜单，待运行验证）：
  - IPC 升级为「请求/响应」往返：扩展在 `menu(for:)` 内写 build 请求并轮询 build 响应（超时 2.5s），主 App 收到 build 通知后遍历插件目录执行每个 `.sh`、解析输出为菜单规格返回。清单机制已废弃。
  - 精简插件协议（`Sources/PluginOutputParser.swift`）：每行一个菜单项；前导 `--` 对表示层级；纯 `-`（>=3）为分隔线；`标题 | key=value`，支持 `bash=`/`paramN=`、`href=`、`disabled=true`；脚本不输出即不显示（条件显示/隐藏）。
  - 动作执行（`Sources/PluginService.swift`）：可执行叶子在构建时登记 `actionId`（含点击上下文），点击时扩展用菜单项 `tag` 携带 `actionId` 通知主 App，主 App 执行 `bash`（带 `FW_CURRENT_DIR`/`FW_SELECTED_PATHS` 与 argv）或打开 `href`，结果写 `run.log`。
  - 每脚本执行超时 1.5s，避免卡 Finder。
  - 示例插件 `~/.config/FinderWand/hello.sh` 已改写为多级 + 条件显示示例。
  - 构建校验：Debug `BUILD SUCCEEDED`。待用户运行验证：右键出现「Finder Wand 示例」及其子菜单，选中文件时出现「对所选执行」，点击子项执行成功（`run.log` 记录、终端/浏览器/默认程序被正确调起）。
  - 风险待观察：`NSMenuItem.tag` 是否跨 Finder Sync XPC 稳定存活（representedObject 已证实不存活）；若 tag 也丢失需改用其他标识。
  - slice 2 已验证通过（2026-07-18）：多级子菜单正常显示，点击子项能执行。确认 `NSMenuItem.tag` 可跨 Finder Sync XPC 存活。M3 核心能力（任意路径动态多级菜单 + 条件显示 + 脚本执行）完成。
  - 已知问题（2026-07-18，v0.1.1 正式版安装后暴露，待 fix）：
    - 现象：正式版右键仅显示置灰「Finder Wand」，且延迟一两秒。
    - 根因：Finder 实际启用的是开发版扩展（`登录项与扩展`显示为「Finder Wand Dev」，是开发期反复运行 dev 构建注册遗留），但用户运行的是正式版 App。dev 扩展把 build 请求写进 dev 容器并等 dev App 响应，而 dev App 未运行 → 2.5s 超时 → 空菜单占位。延迟与空菜单同源。
    - 成因：dev/release 用不同 BundleID（`…dev.finder-wand` vs `…finder-wand`），两套 App + 两套扩展可共存，开发期启用了 dev 那套。
    - 待做修复方向：1) 扩展的 CFBundleDisplayName 按 config 区分（「Finder Wand Dev」/「Finder Wand」），避免混淆；2) 文档说明正式使用只应安装/启用一套；3) 主 App 未运行时的占位文案改为引导（如「请先启动 Finder Wand」）；4) 结合 M4 开机自启保证主 App 常驻；5) 评估降低 `menu(for:)` 同步等待时延。
    - 已修复（2026-07-19，方向 1 落地）：扩展的 CFBundleDisplayName 改为按 config 区分（Debug「Finder Wand Dev」/ Release「Finder Wand」），系统「登录项与扩展」里可区分 dev 与正式版扩展，避免误启用另一套导致 build 请求写入非运行 App 的容器而超时空菜单。实现方式：`project.yml` 为扩展新增自定义构建设置 `FW_EXT_DISPLAY_NAME`（Debug/Release 两套取值），扩展 `Info.plist` 与 `project.yml` 的 `info.properties` 均将 `CFBundleDisplayName` 改为 `$(FW_EXT_DISPLAY_NAME)`；不改 `PRODUCT_NAME`，避免影响 `PRODUCT_MODULE_NAME` 与 `NSExtensionPrincipalClass` 解析。Debug 编译校验 `BUILD SUCCEEDED`，产物内 appex `CFBundleDisplayName` 为「Finder Wand Dev」。方向 2/3/4/5 仍待办。
    - 已优化（2026-07-19，方向 5 落地）：降低 `menu(for:)` 同步等待时延。主 App 侧 `PluginService.buildNodes` 原为串行执行插件目录下每个 `.sh`（总耗时为各脚本之和，单个慢脚本会拖累后续），改为并行执行（`DispatchQueue(concurrent)` + `DispatchGroup`），结果按文件名顺序回填保证菜单顺序稳定；总耗时从「各脚本之和」降到「最慢的单个脚本」。`serialize`/`registerAction` 仍在原串行队列上执行，无并发写 `actions` 表的风险。Debug 编译校验 `BUILD SUCCEEDED`。方向 2/3 仍待办（方向 4 已由 M4 开机自启覆盖）。
    - 已优化（2026-07-19，方向 3 落地）：主 App 未运行时右键占位文案改为引导语。采用方案 1（不引入进程探测）：扩展 `menu(for:)` 按 `requestMenuSpec` 结果区分两种占位。请求无响应/超时（返回 nil，主 App 大概率未启动）显示「请先启动 Finder Wand」；主 App 有响应但无菜单项（返回空数组，在运行但无插件输出可显示项）显示「Finder Wand（无可用菜单）」。研究过的替代方案 2a（扩展内 `NSWorkspace.runningApplications` 查进程，沙箱下返回信息受裁剪、可靠性存疑）与 2b（主 App 写心跳文件、扩展读新鲜度，最准确但引入常驻定时器与新鲜度窗口）均未采用，理由是方案 1 已覆盖绝大多数场景且零额外常驻开销。Debug 编译校验 `BUILD SUCCEEDED`。方向 2 仍待办。
  - 已修复的打包缺陷（2026-07-18，v0.1.1 正式版「右键完全无菜单项」根因）：
    - 根因：`scripts/package-dmg.sh` 注入 Info.plist 后用 `codesign --force --deep --sign -` 重签，`--deep` 连带重签内嵌 Finder Sync 扩展并丢失其 entitlements（含 `com.apple.security.app-sandbox`）。Finder Sync 扩展必须沙箱，无沙箱权限被系统拒绝加载 → 右键无任何菜单。dev 用 `build.sh`（不重签）故正常。
    - 已本地复现确认：`--deep` 重签后 appex entitlements 变空。
    - 修复：只重签外层 App（`codesign --force --sign -`，不加 `--deep`）；因仅改动了 App 顶层 Info.plist，内嵌扩展不动、签名保留。已验证重签后 appex 保留 sandbox 权限，且 app/appex 签名均校验通过。
    - 影响：已发布的 v0.1.1 受此缺陷影响，需重新出包（下个 tag 的 CI 构建即为修复版）。

## 2.5、M4：自动更新与开机自启（状态：已完成）

目标：实现版本检查更新与开机自动运行。

任务：

- 检查更新：查询 GitHub Releases 是否有新安装包，有则弹窗提示（新版本号、更新说明、立即安装按钮）。优先复用成熟开源组件（如 Sparkle，需评估无签名场景下的可用性）。菜单项插入到「版本号」与「关于」之间。
- 开机自动运行：菜单项可切换状态，App 首次运行时默认开启。菜单项插入到「检查更新」之后。
- 备注：「关于 Finder Wand」已在 M2 实现。

进展记录：

- 决策（2026-07-18）：检查更新采用自研轻量方案（不引入 Sparkle），规避 ad-hoc 无公证下的签名/appcast 负担。
- 已新增 `Sources/UpdateChecker.swift`：查询 `releases/latest`（自动排除 prerelease），归一化 tag（去 `v` 与 `-beta` 后缀）并语义化比较；有新版回调返回版本号、更新说明、`.dmg` 下载地址与 Release 页地址。
- 已新增 `Sources/LoginItemManager.swift`：基于 `SMAppService.mainApp` 实现开机自启（enable/disable/toggle/状态查询），并提供首次运行默认开启（`UserDefaults` 标记，仅执行一次）。
- `MenuBarController` 新增菜单项：「检查更新」（弹窗提示已是最新/失败/发现新版，新版可下载安装包或打开 Release 页）、「开机自动运行」（勾选态反映状态，点击切换）。菜单顺序：刷新、打开插件目录、分割线、版本号、检查更新、开机自动运行、关于、分割线、退出。
- `AppDelegate` 在启动时调用首次运行默认开启开机自启。
- 构建校验：Debug `BUILD SUCCEEDED`。待运行验证：菜单出现两项且行为正确；首次运行后「开机自动运行」默认勾选；检查更新在有/无新版/失败时提示正确。
- 注意：`SMAppService` 从非 `/Applications` 路径（如 DerivedData 的 dev 构建）注册可能受限，正式验证以安装后的 Release 包为准。
- 已验证（v0.1.4 起）：安装后启动即提示「登录项已添加」，开机自启默认开启；右键菜单正常。检查更新在仓库为公开时可用（当前仓库为私有，未鉴权 API 返回 404，已在 UpdateChecker 中给出「未找到正式版发布，若仓库为私有请设为公开」的友好提示）。

## 2.6、M5：插件协议完善（状态：已完成）

目标：在 M3 已实现的 xbar 精简子集基础上，增强 `.sh` 插件协议。

任务：

- 参考 xbar 插件协议（CONTRIBUTING 文档）扩展更多能力：如菜单项图标、`refresh=true`、`terminal=true`（真正开终端执行）、`open=`/文件打开、颜色与字体等。
- 完善错误可视化：脚本执行失败或超时在菜单中给出提示。
- 备注：基础的层级菜单、条件显示、`bash`/`param`/`href`/`disabled`、脚本自行决定显示项，已在 M3 slice 2 实现。

进展记录：

- 已实现的增强（本轮，用户选择的子集：terminal / sfimage / 颜色字体 / 错误可视化）：
  - `terminal=true`：点击时在 Terminal 中运行命令（主 App 写临时 `.command` 包装脚本并 `open -a Terminal`），默认仍后台静默执行。
  - `sfimage=<SF Symbol>`：为菜单项设置图标（扩展侧 `NSImage(systemSymbolName:)`）。
  - `color=<名或#RRGGBB>` / `font=<字体>` / `size=<字号>`：通过 `attributedTitle` 应用文本样式。
  - 错误可视化：构建期某个脚本退出码非 0（含超时）时，注入一个不可点击的「⚠️ <脚本>（执行失败，退出码 N）」提示项；动作执行结果继续写 `run.log`。
  - 涉及文件：`PluginOutputParser.swift`（新增字段与参数解析）、`PluginService.swift`（序列化新字段、terminal 执行、构建期错误节点）、`FinderSync.swift`（图标与样式渲染）。
  - 构建校验：Debug `BUILD SUCCEEDED`。待运行验证：图标/颜色显示、`terminal=true` 打开终端执行、脚本报错时出现警告项。
  - 未做：`refresh=true`（对右键菜单意义较小，用户未选）。
  - 调研结论与修正（2026-07-18，依据 Apple `FIFinderSync.h` 头文件说明）：Finder Sync 右键菜单只保留菜单项的 `title`/`action`/`image`/`enabled`/`tag`/`state`/`indentationLevel` 与子菜单，**不支持 `attributedTitle`（即无法设置文本颜色/字体），也不支持原生分隔线**（`NSMenuItem.separator()` 显示为空行）。据此修正：
    - 文本颜色/字体：确认不支持，已移除 `color`/`font`/`size`；`disabled=true` 恢复为「置灰」（`enabled` 属性受支持）。
    - 分隔线：原生不支持（顶层与子菜单皆然），统一以一条禁用的灰色横线 `──────────` 模拟。
    - 图标：`image` 受支持，但模板图在 Finder Sync 下不会随深浅色自动适配，改为在扩展内按当前系统外观（`AppleInterfaceStyle`）用 `SymbolConfiguration(paletteColors:)` 着色（暗色白、浅色黑）。
    - 示例插件 `example.sh` 已按上述能力更新（移除颜色/字体演示）。
  - 图标与外观修正（2026-07-18，随 App 图标一并处理）：
    - 右键菜单 `sfimage` 图标：Finder Sync 下模板图不自动适配深浅色，改为按 `AppleInterfaceStyle` 用 `SymbolConfiguration(paletteColors:)` 着色；禁用项图标同步降透明度，与置灰标题一致。
    - 分隔线字符由 `──────────` 调整为 `----------`。
  - App 图标 / 菜单栏图标接入（2026-07-18）：
    - 新增 `Sources/Assets.xcassets`（`AppIcon.appiconset` + `MenuBarIconTemplate.imageset`），`Base.xcconfig` 设 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`，`MenuBarController` 用 `NSImage(named: "MenuBarIconTemplate")`（模板图）。
    - 关键坑：Asset Catalog 曾因缺少根 `Contents.json` 且各 `Contents.json` 内含字面量 `\n`（非法 JSON）而完全不被 actool 编译（App 图标、菜单栏图标都不生效）。已补根 `Contents.json` 并修正为合法 JSON；`gen-appicon.sh` / `gen-menubar-icon.sh` 生成逻辑也已修复（逐行真实换行输出、去掉非标准/冲突条目、不再改 project.yml）。
  - v0.1.8 已整体验证通过：App 图标、菜单栏品牌图标、右键动态菜单（图标着色/禁用置灰/分隔线/终端执行/条件显示）均正常，未发现明显 bug。
- 备注：示例插件 `~/.config/FinderWand/hello.sh` 由用户自行维护，未覆盖其内容。

# 3、待澄清与待决策清单

- 暂无（Finder 右键菜单方案、自动更新组件选型均已确定）。

# 4、脚本说明

所有脚本在 `scripts/` 下，均以 zsh 编写，从项目根目录执行。

## 4.1、build.sh

- 用途：生成 `.xcodeproj`（XcodeGen）并本地编译。
- 用法：`./scripts/build.sh [Debug|Release]`（默认 Debug）。
- 说明：自动探测 Xcode.app 设置 `DEVELOPER_DIR`（本机 `xcode-select` 指向 CommandLineTools）；DerivedData 固定到 `./.build/DerivedData`。

## 4.2、package-dmg.sh

- 用途：编译 Release 通用二进制并打包 `.dmg`（本地/CI 通用）。
- 用法：`CHANNEL=stable MARKETING_VERSION=0.1.8 BUILD_NUMBER=N LABEL=v0.1.8 ./scripts/package-dmg.sh`；`CHANNEL=beta` 出测试版。
- 说明：注入渠道/commit/时间戳到 Info.plist；从内到外 ad-hoc 重签（先带 entitlements 签扩展，再签 App，禁用 `--deep`）；`hdiutil` 产出 `.dmg` 与 `.sha256`。本机因 TCC 限制 `hdiutil` 可能失败，实际出包以 CI 为准。

## 4.3、uninstall.sh

- 用途：清理开发调试期残留（App、构建产物、沙箱容器、偏好、缓存等），保证全新安装不受影响。
- 用法：`./scripts/uninstall.sh [--dry-run] [--purge-config]`。默认保留插件目录 `~/.config/FinderWand`，加 `--purge-config` 才一并删除。
- 说明：日志用 emoji 标识（🗑️✅ 删除成功、🗑️❌ 失败、⚠️ 警告/系统保护跳过）；会重建 LaunchServices 并重启 Finder；沙箱容器受 SIP 保护删不掉属正常（可在 Finder 里拖废纸篓）；「登录项与扩展」僵尸项可注销重登或 `sfltool resetbtm` 清除。

## 4.4、gen-appicon.sh

- 用途：基于 1024px 源图生成 macOS App 图标集。
- 用法：`./scripts/gen-appicon.sh [源图路径]`（默认 `Resources/finderwand-icon-1024.png`）。
- 说明：输出到 `Sources/Assets.xcassets/AppIcon.appiconset/`，标准 10 槽位（16/32/128/256/512 @1x/@2x）；写合法 JSON（真实换行），并确保 Asset Catalog 根 `Contents.json` 存在。

## 4.5、gen-menubar-icon.sh

- 用途：基于 1024px 源图生成菜单栏模板图标。
- 用法：`./scripts/gen-menubar-icon.sh [源图路径]`（默认 `Resources/finderwand-menubar-icon-1024-light.png`）。
- 说明：输出到 `Sources/Assets.xcassets/MenuBarIconTemplate.imageset/`，universal 1x/2x（18pt），模板渲染（`template-rendering-intent=template`），供 `NSImage(named:)` 加载后随深浅色自适应。

## 4.6、发布流程（CI）

- 触发：推送 tag `vX.Y.Z` → GitHub Actions（`.github/workflows/build-release.yml`）构建正式版并创建 Release 上传 `.dmg`；`workflow_dispatch` 手动触发出测试版。
- 便捷做法（gh 已登录）：`gh api --method POST repos/AndyM129/FinderWand/git/refs -f ref="refs/tags/vX.Y.Z" -f sha="$(git rev-parse HEAD)"` 创建 tag 触发；`gh run watch <id> --exit-status` 跟踪。
