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
# 注意：使用 ad-hoc 签名（CODE_SIGN_IDENTITY=-），不加 CODE_SIGNING_ALLOWED=NO，
# 让 Xcode 在构建期就为 App 与内嵌扩展签名并带上各自的 entitlements（扩展需 app-sandbox 才能被加载）。
BUILD_SETTINGS=(
  ARCHS="arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
  CODE_SIGN_IDENTITY="-"
  CODE_SIGN_STYLE=Manual
  CODE_SIGNING_REQUIRED=NO
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

# 修改了 App 顶层 Info.plist 后需重新签名。
# 从内到外签名（禁止 --deep）：
#   1. 先重签内嵌扩展，并显式带上其 entitlements（含 app-sandbox），
#      否则扩展缺少沙箱权限会被系统拒绝加载（右键无任何菜单）。
#   2. 再签外层 App。
APPEX="$APP/Contents/PlugIns/FinderWandSync.appex"
EXT_ENTITLEMENTS="$ROOT/FinderSyncExtension/FinderWandSync.entitlements"
if [[ -f "$EXT_ENTITLEMENTS" ]]; then
  codesign --force --sign - --timestamp=none --entitlements "$EXT_ENTITLEMENTS" "$APPEX"
else
  echo "警告: 未找到扩展 entitlements（$EXT_ENTITLEMENTS），扩展可能无法加载"
  codesign --force --sign - --timestamp=none "$APPEX"
fi
codesign --force --sign - --timestamp=none "$APP"

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

# 卷图标：复用 App 编译产出的 AppIcon.icns，保证 dmg 图标与 App 图标一致
VOL_ICON_SRC="$APP/Contents/Resources/AppIcon.icns"
if [[ -f "$VOL_ICON_SRC" ]]; then
  cp "$VOL_ICON_SRC" "$STAGING/.VolumeIcon.icns"
else
  echo "警告: 未找到 $VOL_ICON_SRC，dmg 卷图标将使用默认图标"
fi

# 背景图：合成 HiDPI TIFF（@1x + @2x），避免在 Retina 屏上被按 1x 缩小、只占窗口一角。
# 来源优先级：
#   1) finderwand-dmg-bg@2x.png（@2x，权威源）：由它下采样得到 @1x，窗口点数 = @2x 尺寸 / 2。
#   2) finderwand-dmg-bg.png（@1x）：视为窗口点数尺寸，放大 2 倍得到 @2x。
BG_SRC="$ROOT/Resources/finderwand-dmg-bg.png"
BG_SRC_2X="$ROOT/Resources/finderwand-dmg-bg@2x.png"
HAS_BG=0
BG_FINDER_REF=""
BG_W=""
BG_H=""
BG_1X_FILE="$DIST/bg_1x.png"
BG_2X_FILE="$DIST/bg_2x.png"

if [[ -f "$BG_SRC_2X" ]]; then
  # 以 @2x 为权威源：窗口点数 = @2x / 2，@1x 由下采样生成
  SRC2X_W="$(sips -g pixelWidth "$BG_SRC_2X" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  SRC2X_H="$(sips -g pixelHeight "$BG_SRC_2X" 2>/dev/null | awk '/pixelHeight/{print $2}')"
  BG_W=$(( ${SRC2X_W:-1280} / 2 ))
  BG_H=$(( ${SRC2X_H:-800} / 2 ))
  cp "$BG_SRC_2X" "$BG_2X_FILE"
  sips -z "$BG_H" "$BG_W" "$BG_SRC_2X" --out "$BG_1X_FILE" >/dev/null 2>&1
elif [[ -f "$BG_SRC" ]]; then
  # 以 @1x 为源：窗口点数 = @1x 尺寸，@2x 由放大生成
  BG_W="$(sips -g pixelWidth "$BG_SRC" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  BG_H="$(sips -g pixelHeight "$BG_SRC" 2>/dev/null | awk '/pixelHeight/{print $2}')"
  BG_W="${BG_W:-640}"
  BG_H="${BG_H:-400}"
  cp "$BG_SRC" "$BG_1X_FILE"
  sips -z "$(( BG_H * 2 ))" "$(( BG_W * 2 ))" "$BG_SRC" --out "$BG_2X_FILE" >/dev/null 2>&1
fi

if [[ -f "$BG_1X_FILE" && -f "$BG_2X_FILE" ]]; then
  mkdir -p "$STAGING/.background"
  if tiffutil -cathidpicheck "$BG_1X_FILE" "$BG_2X_FILE" -out "$STAGING/.background/bg.tiff" >/dev/null 2>&1; then
    BG_FINDER_REF=".background:bg.tiff"
  else
    echo "警告: 合成 HiDPI 背景失败，回退为普通 PNG（Retina 上可能偏小）"
    cp "$BG_1X_FILE" "$STAGING/.background/bg.png"
    BG_FINDER_REF=".background:bg.png"
  fi
  HAS_BG=1
else
  echo "警告: 未找到背景图（finderwand-dmg-bg@2x.png 或 finderwand-dmg-bg.png），dmg 将不设置背景"
fi
rm -f "$BG_1X_FILE" "$BG_2X_FILE"

mkdir -p "$DIST"
DMG="$DIST/FinderWand-${LABEL}.dmg"
rm -f "$DMG"

# 先做可读写 dmg，挂载后设置卷图标与窗口布局，再转成压缩只读 dmg
RW_DMG="$DIST/rw-${LABEL}.dmg"
rm -f "$RW_DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -ov "$RW_DMG"

MOUNT_DIR="/Volumes/$APP_NAME"
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noverify -noautoopen

# 设置卷图标属性（需要 SetFile；失败不阻断打包）
if [[ -f "$MOUNT_DIR/.VolumeIcon.icns" ]]; then
  xcrun SetFile -a C "$MOUNT_DIR" 2>/dev/null || echo "警告: 设置卷图标属性失败（SetFile）"
fi

# 通过 Finder 设置窗口大小、背景图与图标位置（依赖 GUI 会话，失败不阻断打包）
if [[ "$HAS_BG" == "1" ]]; then
  BG_W="${BG_W:-640}"
  BG_H="${BG_H:-400}"

  APP_X=$(( BG_W * 28 / 100 ))
  APP_Y=$(( BG_H * 52 / 100 ))
  ALIAS_X=$(( BG_W * 72 / 100 ))
  ALIAS_Y=$(( BG_H * 52 / 100 ))
  WIN_R=$(( 100 + BG_W ))
  WIN_B=$(( 100 + BG_H ))

  osascript <<EOF 2>/dev/null || echo "警告: Finder 窗口布局设置失败（可能无 GUI 会话）"
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, $WIN_R, $WIN_B}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set background picture of theViewOptions to file "$BG_FINDER_REF"
    set position of item "$APP_NAME.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$ALIAS_X, $ALIAS_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
fi

sync
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true

# 转成压缩只读 dmg
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG"
rm -f "$RW_DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"

rm -rf "$STAGING"

echo "==> 打包完成: $DMG"
