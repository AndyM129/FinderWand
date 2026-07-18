#!/bin/zsh
# FinderWand 打包脚本：编译正式版（通用二进制）并生成 .dmg
# 用法：
#   CHANNEL=stable MARKETING_VERSION=0.1.0 BUILD_NUMBER=1 ./scripts/package-dmg.sh
#   CHANNEL=beta ./scripts/package-dmg.sh
# 环境变量：
#   CHANNEL           stable | beta（默认 stable）
#   MARKETING_VERSION 版本号，如 0.1.0（为空则用 xcconfig 默认值）
#   BUILD_NUMBER      构建号（默认 1）
# 产物：
#   .build/dist/FinderWand-<label>.dmg 及其 .sha256
#   正式版 label 形如 v0.1.0，测试版形如 v0.1.0-beta-<短哈希>-<时间戳>

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
cd "$ROOT"

CHANNEL="${CHANNEL:-stable}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

APP_NAME="Finder Wand"
DERIVED_DATA="$ROOT/.build/DerivedData"
DIST="$ROOT/.build/dist"

# 探测 Xcode（本机 xcode-select 指向 CommandLineTools）
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for xc in "/Applications/Xcode 26.6.app" "/Applications/Xcode 26.1.1.app" "/Applications/Xcode.app"; do
    if [[ -d "$xc" ]]; then
      export DEVELOPER_DIR="$xc/Contents/Developer"
      break
    fi
  done
fi

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

echo "==> 渠道           = $CHANNEL"
echo "==> 版本号         = ${MARKETING_VERSION:-<xcconfig 默认>}"
echo "==> 构建号         = $BUILD_NUMBER"
echo "==> commit         = $GIT_SHA"

# 生成工程
xcodegen generate

# 组装 xcodebuild 版本与签名覆盖参数
BUILD_SETTINGS=(
  ARCHS="arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
  CODE_SIGN_IDENTITY="-"
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
if [[ -n "$MARKETING_VERSION" ]]; then
  BUILD_SETTINGS+=(MARKETING_VERSION="$MARKETING_VERSION")
fi

# 编译正式版（通用二进制）
rm -rf "$DERIVED_DATA/Build/Products/Release"
xcodebuild \
  -project FinderWand.xcodeproj \
  -scheme FinderWand \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  "${BUILD_SETTINGS[@]}" \
  build

APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
PLIST="$APP/Contents/Info.plist"

# 注入构建渠道与元信息，供 App 内版本显示（M2 使用）
plutil -replace FWBuildChannel -string "$CHANNEL" "$PLIST"
plutil -replace FWGitCommit -string "$GIT_SHA" "$PLIST"
plutil -replace FWBuildTimestamp -string "$TIMESTAMP" "$PLIST"

# 修改 Info.plist 后重新 ad-hoc 签名
codesign --force --deep --sign - --timestamp=none "$APP"

SHORT_VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
if [[ -n "${LABEL:-}" ]]; then
  # 由调用方（如 CI）显式指定 label，保证 dmg 命名与 Release tag 一致
  LABEL="$LABEL"
elif [[ "$CHANNEL" == "beta" ]]; then
  LABEL="v${SHORT_VER}-beta-${GIT_SHA}-${TIMESTAMP}"
else
  LABEL="v${SHORT_VER}"
fi

# 组装 dmg 内容：App + 指向 /Applications 的软链
STAGING="$DIST/staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$DIST"
DMG="$DIST/FinderWand-${LABEL}.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"

rm -rf "$STAGING"

echo "==> 打包完成: $DMG"
