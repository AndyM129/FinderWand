#!/bin/zsh
# 选出用来编译的 Xcode，导出 DEVELOPER_DIR。由 build.sh、package-dmg.sh 用 source 引入。
# 顺序：
#   1. 已设置 DEVELOPER_DIR 时不改动；
#   2. xcode-select 指向某个 Xcode.app 时用它；
#   3. 否则（如指向 CommandLineTools）在 /Applications 下找版本号最高的 Xcode*.app。
# 只影响当前脚本进程，不改全局 xcode-select 设置。

fw_select_xcode() {
  [[ -n "${DEVELOPER_DIR:-}" ]] && return 0

  local selected
  selected="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$selected" == *.app/Contents/Developer ]]; then
    export DEVELOPER_DIR="$selected"
    return 0
  fi

  local best="" best_version="" app version
  for app in /Applications/Xcode*.app(N); do
    version="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
    [[ -z "$version" ]] && continue
    if [[ -z "$best" || "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -1)" == "$version" ]]; then
      best="$app"
      best_version="$version"
    fi
  done

  if [[ -n "$best" ]]; then
    export DEVELOPER_DIR="$best/Contents/Developer"
  fi
}

fw_select_xcode
