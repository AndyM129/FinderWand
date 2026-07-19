> 本文档记录 Finder Wand 各版本的更新内容。
>
> 格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
>
> 变更类型：`新增`（新功能）、`变更`（现有功能改动）、`修复`（问题修复）、`移除`（删除功能）、`废弃`（即将移除）、`安全`（安全相关）。

# 1、未发布（Unreleased）

## 1.1、变更

- Finder Sync 扩展的显示名（CFBundleDisplayName）按构建配置区分：开发版为「Finder Wand Dev」，正式版为「Finder Wand」。系统「登录项与扩展」里可区分两套扩展，避免误启用开发版扩展导致右键菜单空白或延迟。
- 右键菜单构建性能优化：主 App 由串行执行插件目录下各 `.sh` 改为并行执行（保序），呼出右键菜单的等待时延从「各脚本耗时之和」降到「最慢的单个脚本」。

# 2、历史版本

## 2.1、v0.1.8（2026-07-18，当前）

### 2.1.1、新增

- 菜单栏常驻应用（LSUIElement）：刷新、打开插件目录、当前版本号（点击打开对应 Release 页）、检查更新、开机自动运行（首次默认开启，基于 SMAppService）、关于、退出。
- Finder 右键动态菜单（Finder Sync 扩展）：在任意路径遍历 `~/.config/FinderWand/*.sh`，按 xbar 精简协议生成多级菜单，支持条件显示/隐藏、`bash`/`paramN`、`terminal=true`、`href`、`disabled`、`sfimage` 图标；脚本执行由非沙箱主 App 承担（沙箱扩展经容器文件 + Darwin 通知与主 App 通信）。
- App 图标与菜单栏品牌模板图标（随深浅色自适应）。
- 打包发布流水线：推送 tag 由 GitHub Actions 构建 `.dmg` 并发布 GitHub Release。

### 2.1.2、修复

- 打包脚本 `package-dmg.sh` 用 `codesign --deep` 重签会清空内嵌 Finder Sync 扩展的 entitlements（含 app-sandbox），导致扩展无法加载、右键无菜单。改为构建期 ad-hoc 签名并从内到外带 entitlements 重签。
- Asset Catalog 因缺少根 `Contents.json` 且各 `Contents.json` 含字面量 `\n`（非法 JSON），导致 App 图标与菜单栏图标完全不被编译。已修复，并修正 `gen-appicon.sh` / `gen-menubar-icon.sh` 生成逻辑。
- 右键菜单：`sfimage` 图标按深浅色着色、禁用项图标同步置灰、分隔线字符调整为 `----------`。

### 2.1.3、说明

- Finder Sync 右键菜单不支持文本颜色/字体与原生分隔线（仅 `title`/`action`/`image`/`enabled`/`tag`/`state`/`indentationLevel`/子菜单），分隔线以短横线模拟。
- 「检查更新」依赖仓库为公开：当前仓库为私有，未鉴权 API 返回 404，会提示「若仓库为私有请设为公开」。

## 2.2、v0.1.0 至 v0.1.7（2026-07-18）

- 开发与验证过程中的迭代构建，均已被 v0.1.8 取代。其中早期包存在扩展签名/加载缺陷（`--deep` 重签问题），相关 Release/tag 已删除，请勿使用。
