#!/bin/zsh
# gen-menubar-icon.sh — 基于 1024px PNG 生成菜单栏模板图标并写入 Assets.xcassets
#
# 用法：
#   ./scripts/gen-menubar-icon.sh [源图路径]
#
# 说明：
#   - 默认使用 Resources/finderwand-menubar-icon-1024-light.png 作为源图
#   - 生成 MenuBarIconTemplate.imageset（universal，1x/2x，模板渲染）：
#       18x18 @1x → 18px（菜单栏最佳视觉尺寸）
#       18x18 @2x → 36px
#   - 模板图（template-rendering-intent=template）：NSStatusBar 会自动按深浅色 tint
#   - 输出目录：Sources/Assets.xcassets/MenuBarIconTemplate.imageset/
#   - 依赖：sips（macOS 内置）
#
# 注意：imageset 不能出现「同 idiom+scale 重复」，故仅用 universal 1x/2x；
#       写 JSON 用真实换行（禁止字面量 \n），否则 Contents.json 非法、actool 不会编译。

set -euo pipefail

# ── 路径配置 ────────────────────────────────────────────────
SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
cd "$ROOT"

SRC="${1:-Resources/finderwand-menubar-icon-1024-light.png}"

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

# ── 重建输出目录（清理历史残留切片，避免未引用文件告警）────────
rm -rf "$IMAGESET_DIR"
mkdir -p "$IMAGESET_DIR"

# ── 各尺寸规格（size 逻辑点数，scale 倍率，px = size*scale）────
typeset -a SPECS=(
  "18 1"   # 18x18 @1x → 18px
  "18 2"   # 18x18 @2x → 36px
)

echo "==> 生成菜单栏图标切片..."

typeset -a JSON_IMAGES=()

for spec in "${SPECS[@]}"; do
  size="${spec%% *}"
  scale="${spec##* }"
  px=$(( size * scale ))

  filename="MenuBarIconTemplate_${size}x${size}@${scale}x.png"
  dest="${IMAGESET_DIR}/${filename}"

  sips --resampleHeightWidth "$px" "$px" "$SRC" --out "$dest" > /dev/null 2>&1
  printf "    ✓ %4dpx × %4dpx  →  %s\n" "$px" "$px" "$filename"

  # 多行片段本身即真实换行；idiom 用 universal，仅带 scale
  JSON_IMAGES+=("    {
      \"filename\" : \"${filename}\",
      \"idiom\" : \"universal\",
      \"scale\" : \"${scale}x\"
    }")
done

# ── 写 Contents.json（逐行输出，真实换行与逗号）───────────────
echo "==> 写入 Contents.json..."
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
  echo '  },'
  echo '  "properties" : {'
  echo '    "template-rendering-intent" : "template"'
  echo '  }'
  echo '}'
} > "${IMAGESET_DIR}/Contents.json"

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

# 说明：Assets.xcassets 位于 Sources/ 下，已随 `- path: Sources` 自动纳入构建，无需单独注册 project.yml。

echo ""
echo "✅ 菜单栏图标生成完毕：${IMAGESET_DIR}（universal 1x/2x 模板图）"
echo ""
echo "后续步骤："
echo "  1. 运行 ./scripts/build.sh 重新生成 .xcodeproj 并编译"
echo "  2. MenuBarController 已用 NSImage(named: \"MenuBarIconTemplate\") 加载该图标"
