# cachyos-* 命令地图

所有 helper 都安装在 `/usr/local/bin/`，源码在安装器仓库的 `bin/`。安装器的
`verify.sh` 会遍历 `bin/` 逐个确认命令可用。

## AI agent

```text
cachyos-agent [--inline|--pick|--list|--validate ID] [<agent>] [--prompt 文本]
                              启动默认（或指定）AI agent，自动带无人值守旗标
cachyos-agent-prompt [--inline] <prompt...>
                              用一段 prompt 启动默认 agent
cachyos-default-agent [<agent>]  读/写默认 agent（未设置时静默）
cachyos-agent-skills [--quiet] [--harness <agent>]
                              把 agent 技能软链到各 harness 的技能目录
cachyos-agent-crash <pid>|--latest
                              把一次进程崩溃交给默认 agent 诊断
cachyos-crash-mute [<程序> [off]]     按程序静默崩溃提醒（只支持 off，没有 on）
cachyos-toggle-crash-capture [off|on]  关闭/开启崩溃捕获（关闭会跨登录保持）
cachyos-ai-config-sync status|backup|sync
                              在 CC Switch 数据库与 Codex 配置之间同步 provider
```

支持的 agent：`codex`（`openai-codex`）、`claude`（`claude-code`）、`opencode`。
默认 agent 名存放在 `~/.config/cachyos-desktop/agent`。

## 配置

```text
cachyos-config status          列出托管配置的状态：current/modified/missing/protected
cachyos-config update          用 /usr/local/share/cachyos-desktop 的版本覆盖托管配置
cachyos-config migrate         先备份再覆盖（大版本升级用）
cachyos-config protect PATH    把某个 $HOME 下的托管文件标记为用户自有
cachyos-config unprotect PATH  取消保护
```

窗口规则不归 `cachyos-config` 管（它的合法子命令只有上面五个）：用
`dms ipc call window-rules toggle`，或 `dms config windowrules`（`list`/`remove`/`reorder`/`update`）。

## 系统维护

```text
cachyos-system-update          更新 Pacman、AUR 和 Flatpak
cachyos-system-clean           清理孤立包、缓存和旧日志
cachyos-update-status          显示仓库和 AUR 更新数量
cachyos-mirror-update          更新镜像列表
cachyos-snapshot [说明]        创建 Snapper 快照
cachyos-rollback <快照编号>     准备 Snapper 回滚（重启生效）
cachyos-quick-rollback         在 Kitty 中选择并确认回滚
cachyos-pkg-install            TUI 安装软件包
cachyos-pkg-remove             TUI 卸载软件包
cachyos-track-app PKG [CMD]    跟踪某程序访问了 HOME 下哪些文件
cachyos-pkg-remove-tracked     卸载并清理跟踪到的 HOME 残留
cachyos-flatpak-install        TUI 安装 Flatpak
cachyos-flatpak-remove         TUI 卸载 Flatpak
cachyos-grub-theme             切换已安装的 GRUB 主题
cachyos-wine-setup             初始化 Wine 与字体
cachyos-firefox-setup          初始化 Firefox（主题、竖向标签、uBlock）
cachyos-code-theme             生成 VS Code 的 Matugen 主题
```

## 桌面与外设

```text
cachyos-input-toggle           切换 Fcitx5 输入法
cachyos-keybind-help           Kitty + fzf 搜索 Niri 快捷键
cachyos-niri-pick [focus]      提取窗口信息或屏幕取色并复制
cachyos-niri-force-kill-window 强制结束点选窗口（-f 连进程树）
cachyos-lock-doctor            检查 DMS 锁屏、PAM、指纹与安全密钥
cachyos-ddc-brightness [status|up|down]
                               外接显示器 DDC/CI 亮度
cachyos-nightlight             切换护眼模式（wlsunset）
cachyos-nightlight-status      Waybar 用的护眼状态 JSON
cachyos-waybar-top|bottom|toggle
                               切换 Waybar 顶栏/底栏
cachyos-enroll-fingerprint     注册指纹
cachyos-register-security-key  注册安全密钥
```

## 截图与录屏

```text
cachyos-screenshot-edit        区域截图并用 Satty 标注
cachyos-screen-record          开始/停止普通录屏（wf-recorder）
cachyos-screen-record-gif      录屏并转 GIF
cachyos-record-menu            录屏菜单（Waybar 点击入口）
cachyos-record-status          Waybar 用的录屏状态 JSON
cachyos-long-screenshot [页数] 长截图（翻页模拟 + 重叠去重拼接）
```

## 文件与媒体（Thunar 动作）

```text
cachyos-media-info FILE        MediaInfo 信息
cachyos-video-to-gif VIDEO     视频转 GIF
cachyos-image-to-png IMAGE     图片转 PNG
cachyos-paste-image DIR        粘贴剪贴板图片到目录
cachyos-paste-symlink DIR      粘贴符号链接到目录
cachyos-take-ownership PATH    取得文件所有权
terminal-here                  在当前位置打开终端
```

## 内部命令（不应直接调用）

```text
cachyos-post-login-setup       首次登录后台任务（有 marker，每个只跑一次）
wxwork-shadow-hider.py         隐藏企业微信在 XWayland 下的黑色阴影窗口
```
