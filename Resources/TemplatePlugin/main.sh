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
# 使用说明见同目录 README.md；输出协议参考项目文档 DESIGN.md。
#
# 运行环境（由主 App 传入）：$1 当前目录，$2.. 选中项；
# FW_CURRENT_DIR / FW_SELECTED_PATHS / FW_PLUGIN_DIR。

echo "我的插件 | sfimage=wand.and.stars"
echo "--示例：后台执行 echo | bash=/bin/echo param0=hello sfimage=play.fill"
echo "--示例：打开主页 | href=https://github.com/AndyM129/FinderWand sfimage=safari"
