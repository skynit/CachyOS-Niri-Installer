---
name: cachyos
description: >
  REQUIRED for end-user customization of this CachyOS + Niri + DankMaterialShell desktop.
  Use when editing ~/.config/niri/, ~/.config/DankMaterialShell/, ~/.config/kitty/,
  ~/.config/waybar/, ~/.config/fish/, ~/.config/satty/, or ~/.config/waypaper/, or when
  running cachyos-* commands. Triggers: Niri, window rules, keybindings, monitors, gaps,
  DankMaterialShell, DMS IPC, bar, widgets, theme, wallpaper, matugen, dynamic colors,
  screenshots, screen recording, snapshots, rollback, config update, input method, fcitx5.
---

# CachyOS 桌面 skill

这套桌面是 **CachyOS + Niri + DankMaterialShell (DMS)**，由安装器 `CachyOS-Niri-Installer`
部署。本 skill 面向**已安装系统上的最终用户定制**，不用于修改安装器源码。

## 何时必须使用本 skill

准备做下列任何一件事之前，先读完本 skill：

- 编辑 `~/.config/niri/` 下的任何文件（`config.kdl`、`dms/binds.kdl`、`cachyos-extras.kdl`）
- 编辑 `~/.config/DankMaterialShell/settings.json` 或它的插件
- 编辑 `~/.config/kitty/`、`~/.config/waybar/`、`~/.config/fish/`、`~/.config/satty/`、`~/.config/waypaper/`
- 运行或建议任何 `cachyos-*` 命令
- 改主题、壁纸、快捷键、显示器、输入法、截图或录屏行为

**准备写 `~/.config/` 之前先停下来读本 skill。** 这里的配置由安装器托管，直接改会和
`cachyos-config update` 打架。

## 只读与可写边界

| 路径 | 规则 |
| --- | --- |
| `/usr/local/share/cachyos-desktop/` | **只读**。安装器每次运行都会覆盖它；读取安全且鼓励，写入无效 |
| `~/.config/**` | 可写。但要先确认目标是否在托管清单里（见下） |
| `~/.local/state/cachyos-desktop/` | 可写。安装器与首次登录任务的状态、日志 |
| `/etc/**`、`/usr/local/bin/**`、`/usr/lib/**` | 需要 root。不要直接改，走安装器或 `cachyos-*` 命令 |

`/usr/local/share/cachyos-desktop/config-manifest.tsv` 是**托管清单**：左列是安装器内的
源路径，右列是它在 `$HOME` 下的目标路径。清单内的文件会被 `cachyos-config update`
覆盖。

不属于清单的常见位置可以直接改：`~/.config/DankMaterialShell/settings.json`
（安装器只做 jq 合并，不覆盖）、`~/.config/niri/dms/*.kdl` 中由 DMS 生成的文件。

## 改托管配置的正确顺序

1. `cachyos-config status` 看目标状态：`current` / `modified` / `missing` / `protected`。
2. 用户想保住自己的改动 → `cachyos-config protect <$HOME 下的路径>`，之后 `update` 会跳过它。
3. 想拿回官方版本 → `cachyos-config unprotect <路径>` 然后 `cachyos-config update`。
4. 大改之前先 `cachyos-snapshot "说明"`（Btrfs + Snapper），需要时 `cachyos-quick-rollback`。

**示例**：想在 Niri 主配置里加自己的 include，必须先保护它，否则下次 `cachyos-config update`
会连同 include 一起冲掉：

```bash
cachyos-config protect ~/.config/niri/config.kdl
```

## 话题指南

- [`niri.md`](niri.md) —— 快捷键、窗口规则、输出、条件 include
- [`dms.md`](dms.md) —— DMS IPC、设置、插件、锁屏
- [`commands.md`](commands.md) —— `cachyos-*` 命令地图

## 需要 root 时

本项目的 helper 自己处理提权：在终端里直接用 `sudo`；从快捷键触发、没有终端时会用
Kitty 重新打开自己来问密码（见 `cachyos-snapshot` 的 `CACHYOS_SNAPSHOT_TERMINAL` 模式）。
因此：

- 优先调用现成的 `cachyos-*` 命令，不要自己拼 `sudo` 流水线。
- 确实需要新写特权命令时，效仿同一模式，不要静默失败。
- 不要用 `sudo` 去编辑 `~/.config` 下的文件——那是用户自己的文件，不需要提权。

## 报告问题

安装器自身的 bug 与改进建议提到 <https://github.com/skynit/CachyOS-Niri-Installer>。
上游问题（Niri、DMS、Quickshell）提到各自项目。
