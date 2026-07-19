# 1、Finder Wand 简介

Finder Wand（访达的魔杖）是一款 macOS 菜单栏 App，在 Finder 右键菜单中动态注入可执行的多级菜单项。菜单内容由插件目录 `~/.config/FinderWand/` 下的插件脚本按 xbar 精简协议输出决定，点击菜单项可执行 shell 等命令、在终端运行或打开链接。

- 技术栈：Swift + AppKit，Deployment Target macOS 14.0（推荐 15 及以上）。
- 分发：无付费 Apple 开发者账号，采用 ad-hoc 签名，通过 GitHub Releases 提供 `.dmg`。
- 仓库：https://github.com/AndyM129/FinderWand

# 2、功能特性

- 菜单栏常驻应用（不占用 Dock）：刷新、打开插件目录、新建插件、已安装插件管理、版本号、检查更新、开机自动运行、关于、退出。
- Finder 右键动态菜单：在任意路径或选中文件后呼出右键菜单，遍历已启用插件并按其输出实时生成多级菜单，支持条件显示/隐藏。
- 目录化插件：一个插件 = 一个文件夹，自带元信息、说明与资源，便于管理与后续分享。
- 插件管理：菜单栏查看插件信息、快速启用/停用、查看说明、在 Finder 中显示。
- 自动更新与开机自启：检查 GitHub 最新正式版；首次运行默认开启开机自启。

# 3、安装与首次启用

## 3.1、安装

1. 从 https://github.com/AndyM129/FinderWand/releases 下载最新 `FinderWand-vX.Y.Z.dmg`。
2. 打开 dmg，将 App 拖入「应用程序」。
3. 由于是 ad-hoc 签名且未公证，首次打开可能被 Gatekeeper 拦截：在「访达」中右键 App 选「打开」，或到「系统设置 → 隐私与安全性」允许打开。

## 3.2、启用 Finder 扩展

1. 启动一次 Finder Wand（菜单栏出现图标）。
2. 打开「系统设置 → 通用 → 登录项与扩展 → 访达扩展」，勾选「Finder Wand」。
3. 若右键菜单访问「桌面/文档/下载」等受保护目录需要，请在「系统设置 → 隐私与安全性 → 完全磁盘访问」中为 Finder Wand 授权（一次性设置，避免每次弹窗）。

# 4、使用

## 4.1、菜单栏

- 刷新：重新枚举插件并重建菜单。
- 打开插件目录：在 Finder 打开 `~/.config/FinderWand/`。
- 新建插件：从内置模板生成一个新插件文件夹并打开。
- 已安装插件：查看各插件信息，快速启用/停用、查看说明、在 Finder 中显示。
- 检查更新 / 开机自动运行 / 关于 / 退出。

## 4.2、右键菜单

在任意目录或选中若干文件后呼出 Finder 右键菜单，即可看到各已启用插件生成的菜单项。当前目录与选中项会传入插件脚本，插件可据此决定显示哪些项。

# 5、插件开发

## 5.1、目录结构

一个插件就是插件目录下的一个文件夹，文件夹名即插件 id：

```
~/.config/FinderWand/
  my-plugin/
    main.sh        # 固定入口，元信息在头部
    README.md      # 使用说明（可选，给人读）
    icon.png       # 图标、预览图等资源（可选）
    preview.png
```

只有「含 `main.sh` 的文件夹」会被加载；顶层散放的 `.sh` 不再加载。新建插件可直接用菜单栏「新建插件」。

## 5.2、元信息

在 `main.sh` 头部、紧跟 shebang，用 `# --- ... # ---` 注释块声明。因为是注释，脚本执行时会被忽略，不影响性能；App 只读取文本解析、不执行脚本。

```bash
#!/bin/bash
# ---
# schema: 1
# id: my-plugin
# title: 我的插件
# description: 一句话简介
# iconUrl: icon.png
# previewUrl: https://example.com/preview.png
# tags: [git, vcs]
# version: 1.0.0
# author: your-name
# authorUrl: https://github.com/your-name
# minAppVersion: 1.0.0
# enabled: true
# ---
```

字段说明：

| 字段 | 含义 |
| --- | --- |
| schema | 元信息格式版本（当前为 1） |
| id | 插件唯一标识，安装后即文件夹名，须为文件系统安全 slug |
| title | 插件标题（缺省用文件夹名） |
| description | 简介 |
| iconUrl | 图标，`http(s)://` 为网络图，否则为插件文件夹内相对图 |
| previewUrl | 预览效果图，规则同上 |
| tags | 标签，内联数组，如 `[git]`、`[git, vcs]` |
| version | 插件版本 |
| author | 作者 |
| authorUrl | 作者主页 |
| minAppVersion | 安装所需最低 App 版本 |
| enabled | 启用开关，仅显式为 `false` 时不加载，缺省视为启用 |

## 5.3、输出协议（xbar 精简子集）

`main.sh` 每次被调用时，把要显示的菜单项按行输出到标准输出：

- 每个非空行是一个菜单项。
- 前导 `--` 对表示层级：无前缀为一级，`--` 为二级，`----` 为三级，依此类推。
- 纯 `-` 且长度不小于 3 的行是分隔线。
- 标题与参数用 ` | ` 分隔，参数为 `key=value`（value 可用双引号包裹）：
  - `bash=<可执行>` 配合 `param0..paramN=<参数>`：点击后台执行命令。
  - `terminal=true`：改为在「终端」中运行（可见输出）。
  - `href=<url>`：点击打开链接。
  - `disabled=true`：不可点击（置灰）。
  - `sfimage=<SF Symbol 名>`：菜单项图标（随深浅色自动着色）。
- 脚本不输出任何行即不显示，可用于条件显示/隐藏。

说明：Finder Sync 右键菜单不支持文本颜色/字体与原生分隔线，分隔线以短横线模拟。

## 5.4、运行环境

脚本运行时可用：

- 位置参数：`$1` 为当前所在目录，`$2..$n` 为选中的文件路径。
- 环境变量：`FW_CURRENT_DIR`（当前目录）、`FW_SELECTED_PATHS`（选中项，每行一个）、`FW_PLUGIN_DIR`（本插件所在目录，可用于引用自带资源）。

## 5.5、说明文档

插件目录可放 `README.md` 作为面向用户的使用说明；它与 `main.sh` 头部的元信息分离，机读信息在元信息、人读说明在 README。菜单栏「已安装插件」在检测到 `README.md` 时会提供「查看说明」。

# 6、从源码构建（开发者）

- 本地编译：`./scripts/build.sh [Debug|Release]`（自动用 XcodeGen 生成工程，DerivedData 固定在 `./.build/DerivedData`）。
- 打包 `.dmg`：见 `scripts/package-dmg.sh`（本机因 TCC 限制 `hdiutil` 可能失败，正式产物以 CI 为准）。
- 发布：推送 `vX.Y.Z` tag 触发 GitHub Actions 构建并发布 Release。

# 7、文档

- `PRD.md`：项目目标与需求。
- `DESIGN.md`：架构与设计方案（持续维护）。
- `Plans & Progress.md`：任务拆解与进展。
- `CHANGELOG.md`：版本更新日志。
- `AGENT.md`：协作与开发规范。

# 8、许可证

见仓库根目录 `LICENSE`。
