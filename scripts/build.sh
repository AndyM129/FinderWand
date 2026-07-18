#!/bin/zsh
# FinderWand 构建脚本
# 用法：
#   ./scripts/build.sh [Debug|Release]
# 说明：
#   - 默认构建 Debug（开发版），传入 Release 构建正式版
#   - DerivedData 固定到项目根目录下的 .build/DerivedData，独立维护
#   - 显式指定 Xcode.app（本机 xcode-select 指向 CommandLineTools）

set -euo pipefail

# 脚本所在目录与项目根目录
SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
cd "$ROOT"

# 构建配置：Debug(开发版) / Release(正式版)
CONFIG="${1:-Debug}"

# DerivedData 固定到项目根目录下
DERIVED_DATA="$ROOT/.build/DerivedData"

# 指定 Xcode（未显式设置 DEVELOPER_DIR 时自动探测）
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for xc in "/Applications/Xcode 26.6.app" "/Applications/Xcode 26.1.1.app" "/Applications/Xcode.app"; do
    if [[ -d "$xc" ]]; then
      export DEVELOPER_DIR="$xc/Contents/Developer"
      break
    fi
  done
fi

echo "==> DEVELOPER_DIR = ${DEVELOPER_DIR:-<default>}"
echo "==> 配置          = $CONFIG"
echo "==> DerivedData   = $DERIVED_DATA"

# 生成 .xcodeproj
echo "==> 生成 Xcode 工程"
xcodegen generate

# 编译
echo "==> 开始编译"
xcodebuild \
  -project FinderWand.xcodeproj \
  -scheme FinderWand \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED_DATA" \
  build
