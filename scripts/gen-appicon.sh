#!/bin/zsh
# gen-appicon.sh — 基于 1024px PNG 生成 macOS AppIcon.appiconset
#
# 用法：
#   ./scripts/gen-appicon.sh [源图路径]
#
# 说明：
#   - 默认使用 Resources/finderwand-icon-1024.png 作为源图
#   - 输出目录：Sources/Assets.xcassets/AppIcon.appiconset/
#   - 同时向 project.yml 注册 Assets.xcassets（若尚未注册）
#   - 依赖：sips（macOS 内置）

set -euo pipefail

# ── 路径配置 ────────────────────────────────────────────────
SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
cd "$ROOT"

# 源图（可通过参数覆盖）
SRC="${1:-Resources/finderwand-icon-1024.png}"

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

# 逐行输出，使用真实换行与逗号，生成合法 JSON（切勿用字面量 \n）
total=${#JSON_IMAGES[@]}
{
  echo '{'
  echo '  "images" : ['
  idx=0
  for item in "${JSON_IMAGES[@]}"; do
    idx=$(( idx + 1 ))
    if (( idx < total )); then
      printf '%s,\n' "$item"
    else
      printf '%s\n' "$item"
    fi
  done
  echo '  ],'
  echo '  "info" : {'
  echo '    "author" : "xcode",'
  echo '    "version" : 1'
  echo '  }'
  echo '}'
} > "${ICONSET_DIR}/Contents.json"

# ── 确保 Asset Catalog 根 Contents.json 存在 ────────────────
if [[ ! -f "${ASSETS_DIR}/Contents.json" ]]; then
  cat > "${ASSETS_DIR}/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF
  echo "==> 已创建 ${ASSETS_DIR}/Contents.json"
fi

# 说明：Assets.xcassets 位于 Sources/ 下，已随 `- path: Sources` 自动纳入构建，
# 无需再单独向 project.yml 注册。

# ── 完成 ──────────────────────────────────────────────────────
echo ""
echo "✅ AppIcon 生成完毕：${ICONSET_DIR}"
echo "   共 ${total} 个切片"
echo ""
echo "后续步骤："
echo "  1. 运行 ./scripts/build.sh 重新生成 .xcodeproj 并编译"
echo "  2. 在 Xcode 中确认 AppIcon 图标集已显示"
