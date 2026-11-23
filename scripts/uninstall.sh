#!/bin/zsh
# FinderWand 卸载 / 重置脚本
# 用途：清除开发调试期间产生的 App、构建产物、沙箱容器、偏好与缓存等，
#       保证下次全新安装不受历史残留（如「登录项与扩展」里的僵尸记录）影响。
#
# 用法：
#   ./scripts/uninstall.sh              # 执行清理（保留插件目录 ~/.config/FinderWand）
#   ./scripts/uninstall.sh --dry-run    # 仅打印将删除的内容，不实际删除
#   ./scripts/uninstall.sh --purge-config  # 同时删除插件目录 ~/.config/FinderWand（含你的 .sh 与日志）
#   ./scripts/uninstall.sh -h           # 帮助
#
# 说明：
#   - 默认不删除 ~/.config/FinderWand（那是你的插件与日志），需要清空请加 --purge-config。
#   - 结束会重建 LaunchServices 注册库并重启 Finder；顽固的「登录项与扩展」僵尸项见末尾提示。

set -uo pipefail
setopt NULL_GLOB

# 确保标准命令（rm 等在 /bin）可用，避免自定义环境里 PATH 缺失导致 "command not found: rm"
export PATH="/bin:/usr/bin:/sbin:/usr/sbin:$PATH"

DRY_RUN=0
PURGE_CONFIG=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --purge-config) PURGE_CONFIG=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "未知参数: $arg（用 -h 查看帮助）"
      exit 1
      ;;
  esac
done

# 相关 BundleID（App 与扩展，dev 与 release 两套）
APP_IDS=(
  io.github.andym129.dev.finder-wand
  io.github.andym129.finder-wand
)
EXT_IDS=(
  io.github.andym129.dev.finder-wand.FinderSync
  io.github.andym129.finder-wand.FinderSync
)
ALL_IDS=($APP_IDS $EXT_IDS)

# 含 v1.2.1 之前的旧名称「Finder Wand」，兼容清理旧版安装
APP_NAMES=("FinderWand" "FinderWand Dev" "Finder Wand" "Finder Wand Dev")

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"

if (( DRY_RUN )); then
  echo "🧹 FinderWand 卸载/重置（🔎 dry-run 预览，不会实际改动）"
else
  echo "🧹 FinderWand 卸载/重置"
fi

# 1. 退出正在运行的 App
for name in "${APP_NAMES[@]}"; do
  if (( DRY_RUN )); then
    echo "🔎 [预览] 退出 App: $name"
  elif killall "$name" 2>/dev/null; then
    echo "🛑✅ 已退出 App: $name"
  else
    echo "⚠️  App 未在运行(跳过): $name"
  fi
done

# 2. 收集待删除路径（用 (N) 修饰符：无匹配则忽略）
typeset -a targets

# 安装的 App
targets+=( /Applications/"FinderWand.app"(N) )
targets+=( /Applications/"FinderWand Dev.app"(N) )
targets+=( /Applications/"Finder Wand.app"(N) )
targets+=( /Applications/"Finder Wand Dev.app"(N) )

# 项目构建产物（DerivedData、dist、dmg 等）与 XcodeGen 生成的工程
targets+=( "$ROOT/.build"(N) )
targets+=( "$ROOT"/*.xcodeproj(N) )

# 各 BundleID 对应的系统级残留
for id in $ALL_IDS; do
  targets+=( "$HOME/Library/Containers/$id"(N) )
  targets+=( "$HOME/Library/Application Scripts/$id"(N) )
  targets+=( "$HOME/Library/Caches/$id"(N) )
  targets+=( "$HOME/Library/HTTPStorages/$id"(N) )
  targets+=( "$HOME/Library/HTTPStorages/$id.binarycookies"(N) )
  targets+=( "$HOME/Library/Preferences/$id.plist"(N) )
  targets+=( "$HOME/Library/Saved Application State/$id.savedState"(N) )
  targets+=( "$HOME/Library/Group Containers/"*"$id"*(N) )
done

# 插件目录（可选）
if (( PURGE_CONFIG )); then
  targets+=( "$HOME/.config/FinderWand"(N) )
fi

# 3. 执行删除
if (( ${#targets} == 0 )); then
  echo "ℹ️  未发现可删除的残留"
else
  for path in "${targets[@]}"; do
    if (( DRY_RUN )); then
      echo "🔎 [预览] 将删除: $path"
      continue
    fi

    # 沙箱容器由 containermanagerd 管理，其 metadata 带 SIP restricted 标记，
    # 命令行 rm 会报 "Operation not permitted"。这里静默尝试，删不掉再分类提示。
    /bin/rm -rf -- "$path" 2>/dev/null
    if [[ ! -e "$path" ]]; then
      echo "🗑️✅ 已删除: $path"
    elif [[ "$path" == "$HOME/Library/Containers/"* ]]; then
      echo "⚠️  系统保护无法删除(可忽略，不影响重装；如需清除可在 Finder 里拖到废纸篓): $path"
    else
      echo "🗑️❌ 删除失败: $path"
    fi
  done
fi

# 4. 注销扩展注册（best-effort）
for id in $EXT_IDS; do
  if (( DRY_RUN )); then
    echo "🔎 [预览] 忽略扩展: $id"
  elif pluginkit -e ignore -i "$id" 2>/dev/null; then
    echo "🧩✅ 已忽略扩展: $id"
  else
    echo "⚠️  忽略扩展未生效(可忽略): $id"
  fi
done

# 5. 重建 LaunchServices 注册库
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if (( DRY_RUN )); then
  echo "🔎 [预览] 重建 LaunchServices 注册库"
else
  "$LSREGISTER" -kill -r -domain local -domain system -domain user >/dev/null 2>&1
  echo "🔄✅ 已重建 LaunchServices 注册库"
fi

# 6. 重启 Finder 相关进程
if (( DRY_RUN )); then
  echo "🔎 [预览] 重启 Finder / SystemUIServer"
else
  killall Finder 2>/dev/null
  killall SystemUIServer 2>/dev/null
  echo "🔁✅ 已重启 Finder / SystemUIServer"
fi

echo "🎉 全部完成"
echo ""
echo "💡 若「系统设置 > 登录项与扩展」仍残留僵尸「FinderWand」项："
echo "   ⚠️  多为 BackgroundTaskManagement 缓存，注销重登或重启即可清除；"
echo "   ⚠️  仍不行可执行（较重，会重置所有登录项，之后合法项会重新登记）："
echo "         sfltool resetbtm   # 执行后建议重启"
