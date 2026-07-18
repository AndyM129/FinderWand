> 本文档记录 Finder Wand 各版本的更新内容。
>
> 格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
>
> 变更类型：`新增`（新功能）、`变更`（现有功能改动）、`修复`（问题修复）、`移除`（删除功能）、`废弃`（即将移除）、`安全`（安全相关）。

# 1、未发布（Unreleased）

## 1.1、新增

- 初始化项目文档：`PRD.md`、`Plans & Progress.md`、`AGENT.md`、`CHANGELOG.md`。

## 1.2、变更

- 暂无。

## 1.3、修复

- 打包脚本 `package-dmg.sh` 签名问题：此前用 `codesign --deep` 重签会清空内嵌 Finder Sync 扩展的 entitlements（含 app-sandbox），导致扩展无法加载、右键无菜单。改为构建期即 ad-hoc 签名（去掉 `CODE_SIGNING_ALLOWED=NO`），并在注入版本信息后从内到外重签（先带 entitlements 重签扩展，再签 App），保证扩展沙箱权限完整且签名有效。

# 2、历史版本

尚无正式发布版本。首个版本发布后，在此按版本号从新到旧记录，条目格式示例如下：

```markdown
# 2.1、v0.1.0（2026-07-18）

## 2.1.1、新增
- 菜单栏图标与基础菜单。
```
