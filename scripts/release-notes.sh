#!/bin/zsh
# 从 CHANGELOG.md 取出指定版本的更新说明，输出为 Release 正文（Markdown）
# 用法：./scripts/release-notes.sh <版本号，如 1.4.0>
# 说明：
#   - 取「## x.y、v<版本号>（…）」到下一个「## 」标题之间的内容；
#   - 去掉小节标题里的编号（「### 2.1.1、新增」→「### 新增」）；
#   - 找不到该版本时输出为空、退出码 0，不阻断发版。

set -euo pipefail

VERSION="${1:?用法: release-notes.sh <版本号>}"
ROOT="${0:A:h:h}"

awk -v ver="v${VERSION}" '
  /^## / {
    if (found) exit
    if (index($0, ver "（") > 0 || $0 ~ ("、" ver "$")) { found = 1; next }
  }
  found {
    sub(/^### [0-9.]+、/, "### ")
    print
  }
' "$ROOT/CHANGELOG.md" | sed -e '/./,$!d'
