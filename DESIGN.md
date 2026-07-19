# 1、文档说明

> 本文档是 Finder Wand 的设计方案文档，持续更新维护。记录整体架构现状，以及各项功能的设计结论与关键取舍，作为实现时的依据。需求与目标见 `PRD.md`，任务拆解与进展见 `Plans & Progress.md`。

# 2、整体架构（现状）

## 2.1、两进程模型

- 主 App（非沙箱，`LSUIElement` 菜单栏应用）：负责菜单栏 UI、遍历并执行插件脚本、解析输出、执行动作、检查更新与开机自启。
- Finder Sync 扩展（沙箱 appex）：监控根目录 `/`，在 `menu(for:)` 内构建右键菜单；扩展不读插件目录、不执行脚本，全部委托主 App。
- 选型原因：只有 Finder Sync Extension 能满足「任意路径、每次右键动态生成多级菜单」，而该扩展被系统强制沙箱。

## 2.2、IPC 通道

- 所有 IPC 文件位于「扩展沙箱容器」内（扩展读写自己容器无需额外权限，非沙箱主 App 可读写该路径）。
- 构建菜单：扩展写 build 请求并轮询 build 响应（超时 2.5s），主 App 收到 Darwin 通知后跑脚本、解析、写响应。
- 执行动作：扩展写 action 请求并发 Darwin 通知，主 App 执行对应动作（bash / terminal / href），结果写 `~/.config/FinderWand/run.log`。
- 共享常量与路径推导集中在 `Shared/FWIPC.swift`，同时编入两个 target。

## 2.3、右键菜单构建流程

- 扩展 `menu(for:)` 同步向主 App 请求菜单规格并构建 `NSMenu`。
- 主 App `PluginService.buildNodes` 遍历插件目录执行脚本，`PluginOutputParser` 按 xbar 精简协议解析为菜单规格。
- 脚本执行为并行（`DispatchQueue(concurrent)` + `DispatchGroup`），结果按文件名顺序回填保序；单脚本执行超时 1.5s。
- 占位文案：请求无响应/超时显示「请先启动 Finder Wand」；有响应但无菜单项显示「Finder Wand（无可用菜单）」。

## 2.4、Finder Sync 菜单能力约束

- 右键菜单仅保留 `title` / `action` / `image` / `enabled` / `tag` / `state` / `indentationLevel` / 子菜单。
- `representedObject` 不跨 XPC 存活，改用 `tag` 携带 actionId；`attributedTitle` 不支持，无法设文本颜色/字体；原生分隔线显示为空行，用禁用的 `----------` 模拟；模板图不自动适配深浅色，按 `AppleInterfaceStyle` 着色。

## 2.5、插件协议（xbar 精简子集，现状）

- 每行一个菜单项；前导 `--` 对表示层级；纯 `-`（>=3）为分隔线；`标题 | key=value`。
- 支持参数：`bash=` / `paramN=`、`terminal=true`、`href=`、`disabled=true`、`sfimage=`。
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

## 3.12、待定与后续

- 分享/安装的具体形态（导出为文件夹或压缩包、安装来源、更新策略）待后续设计。
- 元信息多语言（如 `title.zh` / `title.en`）暂不做，`key` 命名给它留扩展空间。
- 是否引入插件级 `order` 字段控制菜单顺序，暂不做，当前按文件夹名排序。

# 4、文档维护约定

- 本文档随设计演进持续更新；每次重要设计决策落定后，同步更新对应章节，并在 `Plans & Progress.md` 记录进展。
- 与实现产生偏差时，以本文档的最新结论为准，并及时回写差异。
