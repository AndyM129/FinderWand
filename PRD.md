# 1、项目目标

我想通过 AI Coding，从零开发一款 Mac APP，说明如下：

- APP 名称：Finder Wand
- 意思：访达的魔杖
- 作用：

  - 支持在 Finder 的右键菜单中，添加任意个一级菜单项，每个一级/子级菜单项 都支持添加任意个子级菜单项

  - 每个菜单项 都支持点击时 执行指定动作，如 执行指定的 shell / python / nodejs 等命令
- 架构：

  - 基于 Swift + AppKit 实现

- 功能设计：
  - 先不用实现配置页，APP 启动后，会在系统 菜单栏中显示 APP 的图标，点击后显示子菜单，包括：

    - 刷新：重新加载相关配置，以便在有配置更新时 立即生效

    - 打开插件目录：点击后，自动在 Finder 中打开插件目录，即 `~/.config/FinderWand`

    - —————— （分割线）

    - 当前版本号：
      - 正式版 如 v0.1.0
      - 测试版 如 v0.1.0（beta-fb4fdff-20260718165322）  —— 大致是这些信息，你可以再优化下显示格式/效果
      - 点击时，在浏览器中打开当前版本对应的 Release 页（`.../releases/tag/vX.Y.Z`）

    - 检查更新：点击后 立即查看当前 GitHub 代码库中是否有新的安装包，如果有，则弹窗提示，包括：
      - 新版的 版本号
      - 更新说明
      - 立即安装按钮
      - PS：该功能 可以复用开源的 通用组件来实现

    - 开机自动运行：点击时 可以切换「开机自动运行」的状态，默认在 APP 首次运行时，自动开启该配置&功能

    - 关于 Finder Wand：点击时，直接在浏览器中 打开当前项目的 GitHub 仓库主页

    - —————— （分割线）

    - 退出 Finder Wand：点击后，直接退出当前 APP

  - 在任意路径下，每次呼出 Finder 的右键菜单时，都遍历插件目录下的 `.sh` 文件，并将当前所在路径，以及所有选中的文件的路径传入 `.sh` 文件
    - 每个 `.sh` 文件，为一个一级菜单项，其内容的具体规则，请参考 xbar 的设计&文档 https://github.com/matryer/xbar-plugins/blob/main/CONTRIBUTING.md
    - 在上述文档&设计的基础上，支持：
      - 在每次呼出 Finder 的右键菜单时，都能基于传入的当前所在路径，以及所有选中的文件的路径传入 `.sh` 文件，自行处理 要显示的 一级或子级的菜单项（或不显示）
- 附加说明：
  - 我是个人开发者，没有任何付费的 Apple 开发者账号，后续仅通过三方平台，直接提供`.dmg` 安装包进行分发
  - 在该 APP 使用的过程中，涉及文件夹权限时，不要有文件夹授权弹窗或提示
  - 我需要该 APP 是可以在每个「阶段/版本」完成开发后，进行打包为 `.dmg` 安装包，并可以在该项目的 GitHub 代码库的 releases 页下载、安装的
    - 具体可以参考 同为 MacOS APP 的开源项目  EdgeMark 的配置
      - 其代码库地址为 https://github.com/Ender-Wang/EdgeMark/tree/main
      - 其 `.github/workflows` 配置地址为 https://github.com/Ender-Wang/EdgeMark/tree/main/.github/workflows




# 2、工程配置

- 系统兼容性：
  - Deployment Target：macOS 14.0（最低支持版本）。
  - 推荐运行环境：macOS 15 及以上。
- 编译、构建缓存路径：
  - 指定到当前项目根路径下的特定文件夹中（如 `./.build` / `./DerivedData`），独立维护，避免使用 Xcode 默认全局 DerivedData 而受其他项目影响或被清理删除。
- Target 与 BundleID：
  - 开发版：
    - target：Debug
    - BundleID：`io.github.andym129.dev.finder-wand`
    - APP Name：Finder Wand Dev
  - 正式版：
    - target：Release
    - BundleID：`io.github.andym129.finder-wand`
    - APP Name：Finder Wand




# 3、AI Coding 说明

- `PRD.md` 是整个项目的目标 & 需求文档
- `Plans & Progress.md` 是对`PRD.md` 中任务的拆解：
  - 以便后续逐个任务推进
  - 并在各子任务下 记录、维护当前的：
    - 计划/开发/测试进展&进度，
    - 相关决定、结论，避免后面遗忘 或反复改
- `AGENT.md` 是 AI Coding 中要遵守的要求，包括但不限于：
  - 先检查，再汇报
  - 一次只改当前任务
  - 禁止：擅自删除或覆盖
- `CHANGELOG.md` 是发版日志，包括每个版本的 版本号、日期、更新内容等（具体可参考行业规范）



