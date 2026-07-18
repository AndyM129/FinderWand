#!/bin/zsh
# gen-menubar-icon.sh — 基于 1024px PNG 生成菜单栏图标并写入 Assets.xcassets
#
# 用法：
#   ./scripts/gen-menubar-icon.sh [源图路径]
#
# 说明：
#   - 默认使用 images/finderwand-icon-1024-v2.png 作为源图
#   - 菜单栏图标规格（macOS 标准）：
#       模板图片（template image）：NSStatusBar 会自动应用 tint，
#       文件名加 "Template" 后缀即可让 AppKit 识别为模板图标。
#       尺寸：16pt / 18pt（Retina 常用）/ 32pt 的 @1x + @2x：
#         16x16   @1x →  16px
#         16x16   @2x →  32px
#         18x18   @1x →  18px（建议尺寸，显示效果最佳）
#         18x18   @2x →  36px
#         32x32   @1x →  32px（可选，高分辨率备用）
#         32x32   @2x →  64px
#   - 输出目录：Sources/Assets.xcassets/MenuBarIconTemplate.imageset/
#   - 若 Assets.xcassets 尚未在 project.yml 中注册，会自动追加
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
IMAGESET_DIR="${ASSETS_DIR}/MenuBarIconTemplate.imageset"

# ── 校验源图 ─────────────────────────────────────────────────
if [[ ! -f "$SRC" ]]; then
  echo "❌ 源图不存在：$SRC"
  echo "   用法：$0 [源图路径]"
  exit 1
fi

echo "==> 源图        : $SRC"
echo "==> 输出目录    : $IMAGESET_DIR"

# ── 创建目录 ─────────────────────────────────────────────────
mkdir -p "$IMAGESET_DIR"

# ── 各尺寸规格（size 为逻辑点数，scale 为倍率，px = size * scale）
# 格式：size scale
# 菜单栏模板图标推荐：18pt 是 macOS 菜单栏最常用视觉尺寸
typeset -a SPECS=(
  "16 1"   # 16x16 @1x →  16px
  "16 2"   # 16x16 @2x →  32px
  "18 1"   # 18x18 @1x →  18px（菜单栏最佳视觉尺寸）
  "18 2"   # 18x18 @2x →  36px
  "32 1"   # 32x32 @1x →  32px
  "32 2"   # 32x32 @2x →  64px
)

# ── 生成各尺寸 PNG ───────────────────────────────────────────
echo "==> 生成菜单栏图标切片..."

typeset -a JSON_IMAGES=()

for spec in "${SPECS[@]}"; do
  size="${spec%% *}"
  scale="${spec##* }"
  px=$(( size * scale ))

  # 文件名：menubar_SIZExSIZE@SCALEx.png
  # 注意：文件名含 "Template" 关键字让 AppKit 自动识别为模板图
  if (( scale == 1 )); then
    filename="MenuBarIconTemplate_${size}x${size}@1x.png"
  else
    filename="MenuBarIconTemplate_${size}x${size}@${scale}x.png"
  fi

  dest="${IMAGESET_DIR}/${filename}"

  # sips 缩放
  sips --resampleHeightWidth "$px" "$px" "$SRC" --out "$dest" > /dev/null 2>&1
  printf "    ✓ %4dpx × %4dpx  →  %s\n" "$px" "$px" "$filename"

  # 拼 JSON 片段
  JSON_IMAGES+=("    {
      \"filename\" : \"${filename}\",
      \"idiom\"    : \"mac\",
      \"scale\"    : \"${scale}x\"
    }")
done

# ── 写 Contents.json ─────────────────────────────────────────
echo "==> 写入 Contents.json..."

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
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}\n' "$JSON_BODY" > "${IMAGESET_DIR}/Contents.json"

# ── 向 project.yml 注册 Assets.xcassets ─────────────────────
PROJECT_YML="project.yml"
if ! grep -q "Assets.xcassets" "$PROJECT_YML"; then
  echo "==> 向 project.yml 注册 Assets.xcassets..."
  perl -i -0pe \
    's|(  FinderWand:\n    type: application\n    platform: macOS\n    sources:\n      - path: Sources\n      - path: Shared)|$1\n      - path: Sources/Assets.xcassets|' \
    "$PROJECT_YML"

  if grep -q "Assets.xcassets" "$PROJECT_YML"; then
    echo "    ✓ project.yml 已更新"
  else
    echo "    ⚠️  自动更新 project.yml 失败，请手动在 FinderWand target 的 sources 下添加："
    echo "         - path: Sources/Assets.xcassets"
  fi
else
  echo "==> project.yml 已包含 Assets.xcassets，跳过"
fi

# ── 提示后续使用方式 ─────────────────────────────────────────
echo ""
echo "✅ 菜单栏图标生成完毕：${IMAGESET_DIR}"
echo "   共 ${total} 个切片（均为模板图，AppKit 自动适配深色/浅色模式）"
echo ""
echo "后续步骤："
echo "  1. 运行 ./scripts/build.sh 重新生成 .xcodeproj 并编译"
echo "  2. 在 MenuBarController.swift 中替换图标加载逻辑，示例："
echo '     let img = NSImage(named: "MenuBarIconTemplate")'
echo '     img?.isTemplate = true'
echo '     button.image = img'
