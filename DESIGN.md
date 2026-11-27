# 1、文档说明

> 本文档是 FinderWand 的设计方案文档，持续更新维护。记录整体架构现状，以及各项功能的设计结论与关键取舍，作为实现时的依据。需求与目标见 `PRD.md`，任务拆解与进展见 `Plans & Progress.md`。

# 2、整体架构（现状）

## 2.1、两进程模型

- 主 App（非沙箱，`LSUIElement` 菜单栏应用）：负责菜单栏 UI、遍历并执行插件脚本、解析输出、执行动作、检查更新与开机自启。
- Finder Sync 扩展（沙箱 appex）：监控根目录 `/`，在 `menu(for:)` 内构建右键菜单；扩展不读插件目录、不执行脚本，全部委托主 App。
- 选型原因：只有 Finder Sync Extension 能满足「任意路径、每次右键动态生成多级菜单」，而该扩展被系统强制沙箱。

## 2.2、IPC 通道

- 所有 IPC 文件位于「扩展沙箱容器」内（扩展读写自己容器无需额外权限，非沙箱主 App 可读写该路径）。
- 构建菜单：扩展写 build 请求并轮询 build 响应（超时 `FWIPC.buildTimeout` = 2.5s，轮询间隔 5ms），主 App 收到 Darwin 通知后跑脚本、解析、写响应。扩展超时后撤回未被取走的请求；主 App 新请求优先处理，丢弃已超过 2.5s 的过期请求，并清理无人取走的响应。
- 执行动作：扩展写 action 请求并发 Darwin 通知，主 App 在独立并发队列执行对应动作（bash / terminal / href），不阻塞后续菜单构建；结果串行写 `~/.config/FinderWand/run.log`。
- 请求与响应文件一律原子写入，避免对方读到半截 JSON。
- 共享常量与路径推导集中在 `Shared/FWIPC.swift`，同时编入两个 target。

## 2.3、右键菜单构建流程

- 扩展 `menu(for:)` 同步向主 App 请求菜单规格并构建 `NSMenu`。
- 主 App `PluginService.buildNodes` 遍历插件目录执行脚本，`PluginOutputParser` 按 xbar 精简协议解析为菜单规格。
- 脚本执行为并行（`DispatchQueue(concurrent)` + `DispatchGroup`），结果按文件名顺序回填保序；构建期单脚本超时默认 1.5s，插件可用元信息 `timeout` 改为 0.1 ~ 2.0s（先 SIGTERM，0.2s 后仍未退出则 SIGKILL）。主 App 在请求创建后 2.3s 截止，到点仍未返回的插件按超时处理，保证扩展 2.5s 内拿到其余插件的菜单。
- 构建期失败提示：超时显示「⚠️ <插件 id>（执行超时）」，非 0 退出码显示「⚠️ <插件 id>（执行失败，退出码 N）」，并把输出写入 `run.log`；点击提示项打开 `run.log`。
- 运行日志 `run.log` 超过 1MB 时改名为 `run.log.1`（覆盖更早的那份），只保留 1 份旧日志，总大小不超过约 2MB。
- 后台动作（`bash=` 且未设 `terminal=`）不设超时，运行到脚本自行结束；退出码非 0 时发系统通知（标题含插件名与菜单项标题，正文为输出首行，点击打开 `run.log`），菜单项写 `notify=false` 时不通知。
- 终端动作：`terminal=true` 按菜单栏「终端应用」设置（UserDefaults `FWTerminalApp`，缺省系统「终端」）；`terminal=iterm` / `terminal=terminal` 固定终端；选中的终端未安装时用系统「终端」。主 App 用 `/usr/bin/osascript` 发 AppleScript：「终端」用 `do script`，iTerm 用 `create tab` + `write text`；osascript 的退出码与输出写入 `run.log`。
- 脚本输出边执行边读取，输出超过管道缓冲（约 64KB）不会写阻塞；脚本退出后最多再等 0.2s 读完输出，后台子进程继续持有管道时不阻塞菜单构建。
- 入口脚本已有执行权限时不再改写权限。
- 占位文案：请求无响应/超时显示「请先启动 FinderWand（点击启动）」，点击后扩展用 `NSWorkspace.openApplication` 启动宿主 App（扩展所在的 `<App>.app`）；有响应但无菜单项显示「FinderWand（无可用菜单）」。

## 2.4、Finder Sync 菜单能力约束

- 右键菜单仅保留 `title` / `action` / `image` / `enabled` / `tag` / `state` / `indentationLevel` / 子菜单。
- `representedObject` 不跨 XPC 存活，改用 `tag` 携带 actionId；`attributedTitle` 不支持，无法设文本颜色/字体；原生分隔线显示为空行（2026-11 复查 Apple 开发者论坛仍无官方方案），用禁用的 `-------------------`（19 个短横线）模拟；模板图不自动适配深浅色，按 `AppleInterfaceStyle` 着色。

## 2.5、插件协议（xbar 精简子集，现状）

- 每行一个菜单项；前导 `--` 对表示层级；纯 `-`（>=3）为分隔线；`标题 | key=value`。
- 支持参数：`bash=` / `paramN=`、`terminal=true|iterm|terminal`、`notify=false`、`href=`、`disabled=true`、`sfimage=`、`image=`。
- `image=`：插件文件夹内的相对路径（拒绝 `..` 与绝对路径），或 base64 图片数据（兼容 xbar）。扩展在沙箱里读不到插件目录，由主 App 缩放为 16pt（2x 像素）PNG、base64 传给扩展，按「文件夹 + 取值 + mtime」缓存；原样显示不着色，与 `sfimage=` 同时给出时用 `image=`。
- 脚本不输出任何行即不显示，可用于条件显示/隐藏。

# 3、插件元信息、目录化与分享安装（2026-07-19 定稿）

## 3.1、目标与背景

- 为后续「插件分享与一键安装」打基础，让每个插件自带展示信息（标题、简介、图标、预览图、版本、作者等）与安装约束。
- 约束：元信息要可读，且不影响脚本执行效率。核心手段是「元信息以注释承载（执行时被 shell 跳过）」且「读取路径与执行路径分离、按 mtime 缓存」。

## 3.2、插件目录结构

- 一个插件 = 一个文件夹，位于 `~/.config/FinderWand/` 下。
- 文件夹名即插件 id，作为运行期身份与去重标识。
- 入口脚本固定 `main.sh`；资源（图标、预览图等）放在同一文件夹内。

```
~/.config/FinderWand/
  git-helper/            # 文件夹名 = 插件 id
    main.sh              # 固定入口，元信息在头部
    README.md            # 该插件的使用说明（可选，给人读）
    preview.png          # 相对资源，随插件分发
    icon.png
```

- README.md（可选）：作为该插件面向用户的使用说明，支持 Markdown，分享/安装时可作为详情展示。它只写「这个插件是干嘛的、怎么用、注意事项」。
- 通用的「输出协议/开发指南」属项目级文档（本文件第 2.5 节），不在每个插件的 README 里重复。
- 说明与元信息分离：机器读的元信息块留在 `main.sh` 头部；人读的说明放 `README.md`。

## 3.3、元信息块格式

- 位置：`main.sh` 头部，紧跟 shebang，以 `# ---` 开启、`# ---` 闭合的注释块。
- 因为是注释，脚本执行时被 shell 跳过，执行开销为零。

```bash
#!/bin/bash
# ---
# schema: 1
# id: git-helper
# title: Git 助手
# description: 常用 Git 快捷操作
# iconUrl: preview.png
# previewUrl: https://example.com/preview.png
# tags: [git, vcs]
# version: 1.0.0
# author: AndyM129
# authorUrl: https://github.com/AndyM129
# minAppVersion: 0.1.9
# enabled: true
# ---

echo "Git 助手 | sfimage=arrow.triangle.branch"
```

## 3.4、受限解析规则

- 定位为「看起来像 YAML 的受限 `key: value` 子集」，自研解析，不引入 YAML 依赖。
- 块必须从文件最顶部（shebang 之后）开始；解析器读到闭合 `# ---` 即停，不读全文。
- 每行 `# key: value`，先去掉行首 `#` 与空白，再取第一个 `:` 前后为 key/value；value 单行。
- `tags` 支持简单内联数组 `[a, b, c]`，按逗号切分去空格，不支持嵌套、不支持带逗号的引号值。
- 未知 key 一律忽略（向后兼容）；缺失字段给兜底（如 `title` 缺省用文件夹名）。

## 3.5、字段规范

| 字段 | 含义 | 说明 |
| --- | --- | --- |
| schema | 元信息格式版本 | 当前为 1，便于以后平滑升级格式 |
| id | 插件唯一标识 | 安装后即文件夹名；须为文件系统安全 slug |
| title | 插件标题 | 缺失兜底用文件夹名 |
| description | 插件简介 | 单行 |
| iconUrl | 图标地址 | 网络图或插件文件夹内相对图 |
| previewUrl | 预览效果图地址 | 网络图或插件文件夹内相对图 |
| tags | 标签 | 内联数组，如 `[git]`、`[git, vcs]` |
| version | 插件版本 | 语义化，如 `1.0.0` |
| author | 作者 | 单行 |
| authorUrl | 作者主页 | 单行 |
| minAppVersion | 最低 App 版本 | 安装时语义化比较，低于则拒绝安装 |
| enabled | 启用开关 | `true` / `false`，缺省视为启用 |
| timeout | 构建右键菜单时的超时（秒） | 缺省 1.5；取值限制在 0.1 ~ 2.0，上限受扩展整体等待 2.5s 约束 |

## 3.6、enabled 语义

- 命名为 `enabled`（是否启用），与「值为 false 则不加载」的语义一致（避免用 `disabled` 造成取值反直觉）。
- 当且仅当存在 `enabled` 且值为 `false` 时，右键菜单逻辑不加载该插件：既不执行 `main.sh`，也不出现在菜单。
- 缺省（未声明）视为 `true`，照常加载。
- 该判断在右键热路径上，靠「路径 + mtime」缓存兜住性能（见 3.9）。

## 3.7、图片路径解析

- 判定：值以 `http://` 或 `https://` 开头视为网络图；否则视为相对路径，基准是该插件文件夹。
- `preview.png` 与 `./preview.png` 均解析到插件文件夹内同名文件。
- 安全：相对路径限制在插件文件夹范围内，拒绝 `..`、绝对路径与任何路径穿越；不满足者当作无图忽略。

## 3.8、id 与安全校验

- `id` 决定安装后落盘文件夹名，必须为文件系统安全 slug（建议小写、`[a-z0-9-_]`、无斜杠无空格）。
- 安装前强制校验：拒绝 `..`、`/`、绝对路径等，防止路径穿越覆盖任意文件。
- 运行期身份以文件夹名为准；若头部 `id` 与文件夹名不一致，以文件夹名为准（`id` 主要用于打包/安装时命名）。

## 3.9、枚举与缓存

- 枚举：列插件目录顶层子文件夹 → 含 `main.sh` 者视为插件 → 读 `main.sh` 头部（按 路径+mtime 缓存）判 `enabled` → 启用者并行执行 `main.sh` → 解析输出构建菜单，按文件夹名排序。
- 顶层散放 `.sh` 静默忽略（不加载）。
- 缓存：元信息与 `enabled` 按「路径 + mtime」缓存，文件未变直接命中，仅新文件或改动文件才重新读头部。

## 3.10、性能影响分析

- 执行成本不变：右键耗时大头是并行执行各 `main.sh`，目录化不改变「跑几个、跑多久」。
- 枚举差异极小：采用固定入口名 `main.sh`，枚举 = 一次列顶层文件夹 + 每个文件夹一次 `stat`（微秒级），与平铺同量级。
- 解析可忽略：`enabled` 与元信息解析按 mtime 缓存，稳定态命中缓存，右键热路径近乎零新增。
- 结论：目录化对执行性能的影响可忽略，取舍应基于架构清晰度与分享体验，而非性能。

## 3.11、兼容性与迁移

- 破坏性变更：只加载插件文件夹，现有顶层 `example.sh` / `demo-*.sh` / `hello.sh` 将停止加载。
- 迁移方式：静默忽略顶层散放 `.sh` 并在文档说明，由用户把脚本迁入各自文件夹（如 `example/main.sh`）。App 不做自动迁移（避免擅自改动用户文件）。

## 3.12、插件管理与新建（菜单栏，已实现）

- 「已安装插件」子菜单：枚举插件文件夹并展示每个插件的标题、id、版本、作者、标签、状态、简介；提供「查看详情」（弹出详情窗口：图标、标题、版本、作者、标签、简介、`previewUrl` 预览图，及作者主页/说明/定位入口）、「启用/停用」（改写 `main.sh` 头部 `enabled`）、「查看说明」（存在 `README.md` 时打开）、「在 Finder 中显示」、「导出为 zip…」（`NSSavePanel` 选位置，`ditto -c -k --keepParent` 打包该插件文件夹，用于分享）、「卸载插件…」（确认后 `FileManager.trashItem` 移到废纸篓，可恢复）。菜单项图标取 `iconUrl`（文件夹内相对图或网络图，网络图磁盘缓存、后台下载），缩放 16pt 并加圆角（约 22.37% 边长，参考 Apple 图标规范）。
- 「新建插件」：优先从插件市场拉取最新 `TemplatePlugin`（`fetchFromMarket`），失败则回退到 App 内置模板（`Resources/TemplatePlugin`，以文件夹引用打入 App 资源）；放入插件目录时同名加时间戳后缀，随后通知并打开该文件夹。
- 菜单栏菜单采用持久 `NSMenu` + `NSMenuDelegate.menuNeedsUpdate`，每次打开前重新枚举，保证启用态等动态信息实时。右键菜单每次右键都实时构建，因此不提供「刷新」菜单项（2026-11-27 移除）。
- 检查更新：除菜单栏手动「检查更新」外，启动 30s 后及之后每 24 小时静默检查一次；发现新版本时发系统通知（点击打开「软件更新」窗口），同一版本只通知一次；已是最新或失败时不打扰。本地开发构建（channel 为 dev）不自动检查。
- 一键更新（`UpdateInstaller`）：URLSession 下载 dmg（不带 `com.apple.quarantine`，因此新版本打开不被 Gatekeeper 拦截）→ 按 Release 资产 `<dmg>.sha256` 校验 → `hdiutil attach` 只读挂载 → 核对 BundleID、`CFBundleShortVersionString`、`codesign --verify --deep --strict` → `ditto` 到目标同目录的 `.FinderWand-update-<版本>.app` → 主 App 退出，辅助 zsh 脚本等进程退出后把旧 App 改名备份、新 App 改名就位、`open` 重新打开，失败时恢复旧 App；日志 `~/Library/Logs/FinderWand/update.log`。运行在 App Translocation 路径、所在目录不可写、本地开发构建时不提供一键更新。
- Release 正文由 CI 用 `scripts/release-notes.sh <版本>` 从 `CHANGELOG.md` 截取对应版本一节。
- 切换启用态、新建插件等操作以系统通知反馈（`UNUserNotificationCenter`，前台通过 willPresent 强制横幅展示）。

## 3.13、待定与后续

- 分享/安装的具体形态（导出为文件夹或压缩包、安装来源、更新策略）待后续设计。
- 元信息多语言（如 `title.zh` / `title.en`）暂不做，`key` 命名给它留扩展空间。
- 是否引入插件级 `order` 字段控制菜单顺序，暂不做，当前按文件夹名排序。

# 4、安装插件（2026-07-19 定稿）

## 4.1、目标与入口

- 支持三种来源安装插件到本地插件目录，统一产出「暂存目录中的插件文件夹」，再按冲突策略写入。
- 菜单栏「已安装插件」子菜单之后为「安装插件」子菜单，含三项：
  - 从插件市场安装：输入 id，从市场仓库 `AndyM129/FinderWand-Plugins`(默认分支 `master`)拉取根目录下 `<id>` 文件夹。
  - 从指定插件仓库安装：输入 `owner/repo` 或完整 GitHub 地址，拉取整仓，落地文件夹名为仓库名。
  - 从指定目录导入并安装：`NSOpenPanel` 选择本地目录，拷贝到插件目录，落地文件夹名为所选目录名。
- 输入对话框用 `NSAlert` + `EditableTextField`(支持粘贴，见下)；目录选择用 `NSOpenPanel`。

## 4.2、拉取方案

- 只取市场仓库根目录下的 `<id>` 文件夹,不落 git 历史、无需鉴权(依赖仓库公开)。
- 实现:下载 codeload tarball 后用 `tar` 只解出目标子目录:
  - 下载 `https://codeload.github.com/AndyM129/FinderWand-Plugins/tar.gz/refs/heads/master` 到临时文件。
  - `tar -xz -f <tarball> -C <tmp> --strip-components=2 "FinderWand-Plugins-master/<id>"`(顶层 `FinderWand-Plugins-master` 占 1 层 + 子目录 1 层 = strip 2),得到干净的 `<id>` 内容。
  - 为避免 shell 注入,`id` 先做安全校验,tar 以参数数组方式调用(不拼 shell)。
- 拉取为空/失败 → 提示「插件市场中未找到插件 <id>」。

## 4.3、安装校验

- `id`:文件系统安全 slug(小写,`[a-z0-9-_]`,拒绝 `..`/`/`/空格),否则提示非法。
- 合法性:拉取内容须含 `main.sh`,否则提示「非合法插件」。
- 版本:读取拉取到的 `main.sh` 元信息 `minAppVersion`,与当前 App 版本做语义化比较,过低则拒绝安装并提示(校验在实际写入插件目录之前完成,避免无谓备份/覆盖)。

## 4.4、已存在时的冲突处理

目标插件文件夹已存在时,弹窗给三个选项:

- 取消:放弃本次安装。
- 备份后安装(整体替换):先把现有 `<id>` 文件夹用 `ditto -c -k` 压缩为 `~/.config/FinderWand/<id>-bak<yyyyMMddHHmmss>.zip`(与插件同级,便于用户解压对比或再次启用),再删除现有文件夹、放入新拉取的完整版本。
- 覆盖安装(overlay):把拉取到的文件逐一覆盖到现有文件夹(同名覆盖),现有的其它文件保持不动,不做备份。

## 4.5、线程与反馈

- 下载/解压/写盘在后台线程执行;冲突弹窗与结果提示回主线程。
- 结果以系统通知反馈(成功/失败/未找到/版本过低),安装成功后刷新「已安装插件」列表。
- 安全:拉取内容为用户主动安装的插件脚本,沿用现有插件信任模型;写入前完成 id 与合法性校验,备份/覆盖仅作用于该插件自己的文件夹。

## 4.6、指定仓库与本地目录来源

- 从指定仓库：解析输入为 `owner/repo`(兼容完整 URL 与 `.git` 后缀)；调用 GitHub API 取 `default_branch`；下载该分支 tarball，用 `tar --strip-components=1 "<repo>-<branch>"` 解出整仓内容到暂存 `<repoName>` 目录；随后走 4.3 校验。落地文件夹名 = 仓库名(须为安全 slug)。
- 从本地目录：`NSOpenPanel` 选目录后，用 `ditto <src> <staged/<dirName>>` 拷贝到暂存，再走 4.3 校验。落地文件夹名 = 所选目录名。
- 三种来源产出的暂存目录一致，之后复用同一套「全新安装 / 备份后整体替换 / 覆盖安装」写入与冲突处理逻辑（4.4）。
- 粘贴支持：菜单栏 App 无主菜单，`NSAlert` 内普通 `NSTextField` 收不到 Cmd+V，改用 `EditableTextField`(重写 `performKeyEquivalent` 派发剪切/复制/粘贴/全选)。

# 5、文档维护约定

- 本文档随设计演进持续更新；每次重要设计决策落定后，同步更新对应章节，并在 `Plans & Progress.md` 记录进展。
- 与实现产生偏差时，以本文档的最新结论为准，并及时回写差异。
