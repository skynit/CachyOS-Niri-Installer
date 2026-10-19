# 桌面功能

本项目的桌面是 **官方 Niri + DankMaterialShell（DMS）+ Quickshell**，周边由 Waybar、Kitty、
Fcitx5 等组件补齐。快捷键完整表见 [keybindings.md](keybindings.md)；随包 DMS 插件见
[dms-plugins.md](dms-plugins.md)；锁屏与电源见 [power.md](power.md)。

## DMS、Niri 与 Overview

- DMS 是默认面板、启动器、通知中心、剪贴板、锁屏和动态主题服务。
- DMS 仅绑定到 Niri 用户会话，不会在其他桌面会话中自动启动。
- DMS 在 Overview 中启用壁纸模糊，Niri 使用深色 backdrop；常驻模糊壁纸层保持关闭。
- DMS Overview Overlay 保持启用，并使用完整启动器样式。
- `Super+Shift+/` 打开 Kitty + fzf，可按快捷键、说明、动作或分组搜索教程。
- DMS 设置由 `assets/dms/desktop-settings.json` 合并而来；DMS 再据此生成
  `~/.config/niri/dms/` 下的配色、布局、Output、光标和模糊配置。这些自动生成文件不走项目
  的配置清单，也不会被安装器强制覆盖。

## 截图、录屏与 Waybar

- Satty 区域截图支持标注和编辑。
- 长截图会模拟翻页，检测重复帧，并按图像重叠区域去重拼接。
- 普通录屏使用 `wf-recorder`；GIF 录屏停止后自动使用 FFmpeg 转换。
- Waybar 录屏模块显示状态，点击后可选择普通录屏、GIF 录屏或正确收尾并停止。
- Waybar 提供顶栏和底栏两套布局，不会默认与 DMS 面板同时启动。
- Waybar 显示系统仓库、AUR 更新数量，点击后打开系统更新命令。
- Waybar 护眼按钮控制 `wlsunset`。
- Waybar DDC 模块可滚轮调节支持 DDC/CI 的外接显示器亮度。

DDC 权限通过 `i2c-dev`、`i2c` 用户组和 udev 规则配置。安装后必须退出并重新登录，
新组权限才会生效。内置笔记本屏幕通常不支持 DDC/CI，应使用系统亮度接口或 DMS
提供的亮度控制。

## 窗口效率工具

- `niri-sidebar`：将窗口加入或移出侧边栏、显示/隐藏侧边栏、左右翻转。
- `nirius`：窗口跟随模式，以及按应用 ID 快速聚焦或启动。
- Waycorner：提供热角动作。
- Woomer：提供手动屏幕放大镜。
- Waypaper + awww：切换壁纸，并通知 DMS 重新生成动态颜色。动态颜色取决于新机选择的壁纸。
- Thunar：媒体信息、视频转 GIF、图片转 PNG、Code 打开、粘贴剪贴板图片、粘贴符号链接和获取所有权。
- Top 系统面板（随包 DMS 插件）：`Super+BackSpace` 呼出，显示每核占用/频率、内存、GPU、
  温度与进程列表；右键进程行可结束整组进程。详见
  [dms-plugins.md](dms-plugins.md#随包插件)。

## 中文输入与 Shell

- Fcitx5 默认启用 RIME 和雾凇拼音；不安装联网大模型输入插件。
- Fish 登录 Shell 加载 Starship、eza、zoxide，并保留 Kitty 作为默认终端。

## 首次登录初始化

- Firefox 首次登录时安装固定校验的 Material 主题、启用竖向标签页，并通过企业策略强制安装
  uBlock Origin。
- Firefox 的主题颜色链接到 DMS 生成的 Matugen CSS。
- Code 首次登录时安装 DMS 自带的 Matugen VSIX 并选择动态主题。
- Wine 首次登录时初始化默认 Wine Prefix，并安装核心字体、中文字体和字体平滑设置。

首次登录任务在后台逐项执行，成功项目不会在后续登录重复覆盖。状态和日志位于：

```text
~/.local/state/cachyos-desktop/
~/.local/state/cachyos-desktop/post-login.log
```

网络下载失败时，只会在下次登录重试未完成的项目。`verify.sh` 会检查四个初始化标记
（Firefox、Code 主题、Wine、agent 技能）是否落地。

## 状态栏与 DMS 插件

安装器会把 AI 集成、本机状态、离线翻译、本地歌词、手机连接与专注插件接进 DMS 状态栏，
并把 Top 注册为 daemon-only 悬浮面板。接线的具体规则、失败时的提示与单独更新方式见
[dms-plugins.md](dms-plugins.md)。
