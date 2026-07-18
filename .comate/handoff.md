> Finder Wand 开发交接文档。供新会话快速接手继续开发。最后更新：2026-07-18（对应 Release v0.1.8）。

# 1、项目概述

- 目标：一款 macOS 菜单栏 App「Finder Wand」，在 Finder 右键菜单动态注入可执行的多级菜单项，菜单内容由 `~/.config/FinderWand/` 下的 `.sh` 插件按 xbar 精简协议输出决定。
- 技术栈：Swift + AppKit，Deployment Target macOS 14.0（推荐 15+）。
- 分发：无付费 Apple 开发者账号，ad-hoc 签名，经 GitHub Releases 提供 `.dmg`。
- 仓库：`github.com/AndyM129/FinderWand`（当前为私有，见 6、待办）。开发分支 `dev`，默认分支 `master`。
- 关键文档：`PRD.md`（需求）、`Plans & Progress.md`（任务拆解与全部关键结论，最重要）、`AGENT.md`（协作规范）、`CHANGELOG.md`。

# 2、架构与目录

- 主 App（非沙箱, LSUIElement 菜单栏应用）：`Sources/`
  - `main.swift` 入口；`AppDelegate.swift` 启动 `MenuBarController` + `PluginService` + 首次开机自启。
  - `MenuBarController.swift` 菜单栏图标与菜单（刷新/打开插件目录/版本号/检查更新/开机自启/关于/退出）。
  - `AppInfo.swift` 版本/渠道/仓库/插件目录/Release 页；`UpdateChecker.swift` 查 GitHub releases/latest；`LoginItemManager.swift` SMAppService 开机自启。
  - `PluginService.swift` 核心：收扩展请求 → 遍历执行 `.sh` → 解析为菜单规格返回；执行动作（bash/terminal/href）；写 `~/.config/FinderWand/run.log`。
  - `PluginOutputParser.swift` xbar 精简协议解析；`DarwinObserverRegistry.swift` Darwin 通知分发。
  - `Assets.xcassets`：`AppIcon.appiconset` + `MenuBarIconTemplate.imageset`。
- Finder Sync 扩展（沙箱 appex）：`FinderSyncExtension/FinderSync.swift`
  - 监控根目录 `/`，`menu(for:)` 内同步向主 App 请求菜单规格并构建 NSMenu；点击经 `tag` 携带 actionId 通知主 App 执行。
- 共享：`Shared/FWIPC.swift`（两 target 共用的 Darwin 名、插件目录、IPC 目录推导），同时编入主 App 与扩展。
- 工程生成：`project.yml`（XcodeGen，`.xcodeproj` 不入库）；`Configs/{Base,Dev,Release}.xcconfig`。

# 3、关键架构决策与踩坑（务必先读，避免重走弯路）

## 3.1、Finder Sync 是唯一可行方案且限制多

- 只有 Finder Sync Extension 能满足「任意路径动态多级右键菜单」。扩展必须沙箱。
- 沙箱扩展不能读插件目录、不能执行脚本 → 全部委托非沙箱主 App。
- IPC：扩展写请求 JSON 到「自己的沙箱容器」（`~/Library/Containers/<扩展BundleID>/Data/Library/Application Support/FinderWandIPC/`），发 Darwin 通知；主 App 读该路径处理、写回响应。`menu(for:)` 同步轮询响应文件（超时 2.5s）。
- Finder Sync 右键菜单仅保留 `title`/`action`/`image`/`enabled`/`tag`/`state`/`indentationLevel`/子菜单：
  - `representedObject` 不跨 XPC 存活 → 用菜单项 `title`/`tag` 标识。
  - `attributedTitle` 不支持 → 无法设文本颜色/字体（协议不提供 color/font）。
  - 原生分隔线显示为空行 → 用禁用的 `----------` 短横线模拟。
  - `image` 支持但模板图不自动适配深浅色 → 按 `AppleInterfaceStyle` 用 `SymbolConfiguration(paletteColors:)` 着色。

## 3.2、打包签名

- `package-dmg.sh` 严禁 `codesign --deep`（会清空扩展 entitlements 致其无法加载、右键无菜单）。须从内到外、扩展带自身 entitlements 重签。

## 3.3、Asset Catalog

- `.xcassets` 必须有根 `Contents.json`；各 `Contents.json` 必须是合法 JSON（历史 bug：生成脚本写了字面量 `\n`）。缺任一都会导致 actool 不编译、图标不生效。
- App 图标需 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`（在 `Base.xcconfig`）。

## 3.4、开发环境

- 本机 `xcode-select` 指向 CommandLineTools，脚本用 `DEVELOPER_DIR` 指向 Xcode.app。
- 本机 `hdiutil` 因 TCC 限制对含 `.app` 目录打包会失败，`.dmg` 以 CI 产出为准。
- dev 与 release 是两套 BundleID（`io.github.andym129.dev.finder-wand` / `io.github.andym129.finder-wand`）与两套扩展，容易在「登录项与扩展」里混淆；正式验证只装一套，调试残留用 `uninstall.sh` 清。

# 4、构建与发布

- 本地编译：`./scripts/build.sh [Debug|Release]`。
- 出包（正式版）：提交并推送到 `dev` 后，打 tag 触发 CI：
  - `gh` 已登录（AndyM129）。创建 tag：`gh api --method POST repos/AndyM129/FinderWand/git/refs -f ref="refs/tags/vX.Y.Z" -f sha="$(git rev-parse HEAD)"`
  - 跟踪：`gh run watch <runId> --repo AndyM129/FinderWand --exit-status`
  - 产物在 Release `vX.Y.Z`：`FinderWand-vX.Y.Z.dmg` + `.sha256`。
- 脚本清单与用法见 `Plans & Progress.md` 的「4、脚本说明」。
- 安全约束：未经用户同意不 push/不打 tag；删除已发布 Release/tag 属破坏性操作（自动审查会拦截），需用户自行执行。

# 5、当前进度（里程碑）

- M0 工程初始化：已完成。
- M1 打包与发布流水线：已完成（tag 触发出 `.dmg` + Release）。
- M2 菜单栏基础功能：已完成。
- M3 Finder 右键菜单核心（动态多级菜单 + 条件显示 + 脚本执行）：已完成。
- M4 自动更新与开机自启：已完成（检查更新受仓库私有限制，见下）。
- M5 插件协议完善（terminal/sfimage/错误可视化 + 图标外观修正）：已完成。
- 最新发布：v0.1.8，已整体验证通过，无已知 bug。

# 6、待办 / 可选项

- 仓库设为 Public：否则「检查更新」未鉴权 API 返回 404（PRD 要求公开分发，建议设为 Public；用户自行决定与操作）。
- M3 遗留体验优化（用户曾选「以后再说」）：扩展 CFBundleDisplayName 按 dev/正式区分（避免「登录项与扩展」混淆）；主 App 未运行时右键占位文案改为引导语。
- 旧的坏包 Release/tag（v0.1.0–v0.1.2 等）已按用户要求删除，仅保留可用版本。

# 7、协作与规范要点

- 回复用中文；Markdown 文档不写一级文档名标题，章节用「数字 + 顿号」（如 `# 1、`、`## 1.1、`）；禁用破折号，用逗号句号冒号。
- 代码注释用中文；iOS/Swift 方法中间 `return` 后留空行。
- 用户明确要求「全局记住」的偏好应存为个人级 Rule（`~/.comate/rules/*.mdr`），不写工程 memory。
- 插件目录 `~/.config/FinderWand/` 是用户数据（`hello.sh`、`example.sh`、日志），不要覆盖用户手改的内容；`example.sh` 是功能演示，覆盖当前全部支持能力。
