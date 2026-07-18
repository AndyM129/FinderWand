#!/bin/zsh
# gen-appicon.sh — 基于 1024px PNG 生成 macOS AppIcon.appiconset
#
# 用法：
#   ./scripts/gen-appicon.sh [源图路径]
#
# 说明：
#   - 默认使用 images/finderwand-icon-1024-v2.png 作为源图
#   - 输出目录：Sources/Assets.xcassets/AppIcon.appiconset/
#   - 同时向 project.yml 注册 Assets.xcassets（若尚未注册）
#   - 依赖：sips（macOS 内置）

set -euo pipefail

# ── 路径配置 ────────────────────────────────────────────────
SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
cd "$ROOT"

# 源图（可通过参数覆盖）
SRC="${1:-images/finderwand-icon-1024-v2.png}"

# 输出目录
ASSETS_DIR="Sources/Assets.xcassets"
ICONSET_DIR="${ASSETS_DIR}/AppIcon.appiconset"

# ── 校验源图 ─────────────────────────────────────────────────
if [[ ! -f "$SRC" ]]; then
  echo "❌ 源图不存在：$SRC"
  echo "   用法：$0 [源图路径]"
  exit 1
fi

echo "==> 源图        : $SRC"
echo "==> 输出目录    : $ICONSET_DIR"

# ── 创建目录 ─────────────────────────────────────────────────
mkdir -p "$ICONSET_DIR"

# ── 各尺寸规格（size 为逻辑点数，scale 为倍率，px = size * scale）
# 格式：size scale
typeset -a SPECS=(
  "16  1"   # 16x16   @1x
  "16  2"   # 16x16   @2x → 32px
  "32  1"   # 32x32   @1x
  "32  2"   # 32x32   @2x → 64px
  "64  1"   # 64x64   @1x  （macOS 14 不再必须但保留兼容）
  "64  2"   # 64x64   @2x → 128px
  "128 1"   # 128x128 @1x
  "128 2"   # 128x128 @2x → 256px
  "256 1"   # 256x256 @1x
  "256 2"   # 256x256 @2x → 512px
  "512 1"   # 512x512 @1x
  "512 2"   # 512x512 @2x → 1024px
)

# ── 生成各尺寸 PNG ───────────────────────────────────────────
echo "==> 生成图标切片..."

typeset -a JSON_IMAGES=()

for spec in "${SPECS[@]}"; do
  size="${spec%% *}"
  scale="${spec##* }"
  px=$(( size * scale ))

  # 文件名：icon_SIZExSIZE@SCALEx.png（@1x 省略后缀习惯上写 @1x，保持统一）
  if (( scale == 1 )); then
    filename="icon_${size}x${size}@1x.png"
  else
    filename="icon_${size}x${size}@${scale}x.png"
  fi

  dest="${ICONSET_DIR}/${filename}"

  # sips 缩放
  sips --resampleHeightWidth "$px" "$px" "$SRC" --out "$dest" > /dev/null 2>&1
  printf "    ✓ %4dpx × %4dpx  →  %s\n" "$px" "$px" "$filename"

  # 拼 JSON 片段
  JSON_IMAGES+=("    {
      \"filename\" : \"${filename}\",
      \"idiom\"    : \"mac\",
      \"scale\"    : \"${scale}x\",
      \"size\"     : \"${size}x${size}\"
    }")
done

# ── 写 Contents.json ─────────────────────────────────────────
echo "==> 写入 Contents.json..."

# 用 printf 拼接 JSON 数组（每项以逗号分隔，最后一项无逗号）
JSON_BODY=""
total=${#JSON_IMAGES[@]}
idx=0
for item in "${JSON_IMAGES[@]}"; do
  idx=$(( idx + 1 ))
  if (( idx < total )); then
    JSON_BODY+="${item},\n"
  else
    JSON_BODY+="${item}\n"
  fi
done

printf '{
  "images" : [\n%s  ],
  "info" : {
    "author"  : "xcode",
    "version" : 1
  }
}\n' "$JSON_BODY" > "${ICONSET_DIR}/Contents.json"

# ── 向 project.yml 注册 Assets.xcassets ─────────────────────
PROJECT_YML="project.yml"
if ! grep -q "Assets.xcassets" "$PROJECT_YML"; then
  echo "==> 向 project.yml 注册 Assets.xcassets..."
  # 在 FinderWand target 的 sources 列表末尾插入 Assets.xcassets
  # 找到 "- path: Shared" 后的第一行（FinderWand target 下），在其后插入
  perl -i -0pe \
    's|(  FinderWand:\n    type: application\n    platform: macOS\n    sources:\n      - path: Sources\n      - path: Shared)|$1\n      - path: Sources/Assets.xcassets|' \
    "$PROJECT_YML"

  # 检查是否成功写入
  if grep -q "Assets.xcassets" "$PROJECT_YML"; then
    echo "    ✓ project.yml 已更新"
  else
    echo "    ⚠️  自动更新 project.yml 失败，请手动在 FinderWand target 的 sources 下添加："
    echo "         - path: Sources/Assets.xcassets"
  fi
else
  echo "==> project.yml 已包含 Assets.xcassets，跳过"
fi

# ── 完成 ──────────────────────────────────────────────────────
echo ""
echo "✅ AppIcon 生成完毕：${ICONSET_DIR}"
echo "   共 ${total} 个切片"
echo ""
echo "后续步骤："
echo "  1. 运行 ./scripts/build.sh 重新生成 .xcodeproj 并编译"
echo "  2. 在 Xcode 中确认 AppIcon 图标集已显示"
