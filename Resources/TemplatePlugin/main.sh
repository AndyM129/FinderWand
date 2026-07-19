#!/bin/bash
# ---
# schema: 1
# id: my-plugin
# title: 我的插件
# description: 在这里填写插件简介
# iconUrl: icon.png
# previewUrl: preview.png
# tags: [demo]
# version: 1.0.0
# author: your-name
# authorUrl: https://github.com/your-name
# minAppVersion: 0.1.9
# enabled: true
# ---
#
# 这是「新建插件」生成的模板。请按需修改上面的元信息与下面的菜单逻辑。
#
# 运行环境（由主 App 传入）：
#   $1            当前所在目录
#   $2..$n        选中的文件路径
#   FW_CURRENT_DIR      当前目录
#   FW_SELECTED_PATHS   选中项（每行一个）
#   FW_PLUGIN_DIR       本插件所在目录（可用于引用插件自带资源）
#
# 输出协议（精简 xbar 子集）：
#   1. 每行一个菜单项；前导 `--` 对表示层级：无=一级，`--`=二级 ...
#   2. 纯 `-`（>=3 个）为分隔线
#   3. `标题 | key=value ...`：bash=<可执行> paramN=<参数> / terminal=true / href=<url> / disabled=true / sfimage=<SF Symbol>
#   4. 脚本不输出任何行即不显示（可用于条件显示/隐藏）

echo "我的插件 | sfimage=wand.and.stars"
echo "--示例：后台执行 echo | bash=/bin/echo param0=hello sfimage=play.fill"
echo "--示例：打开主页 | href=https://github.com/AndyM129/FinderWand sfimage=safari"
