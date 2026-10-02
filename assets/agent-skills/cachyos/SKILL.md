---
name: cachyos
description: >
  REQUIRED for end-user customization of this CachyOS + Niri + DankMaterialShell desktop.
  Use when editing ~/.config/niri/, ~/.config/DankMaterialShell/, ~/.config/kitty/,
  ~/.config/waybar/, ~/.config/fish/, ~/.config/satty/, ~/.config/waypaper/,
  ~/.config/fcitx5/, ~/.config/Thunar/, or when running any cachyos-* command.
  Triggers: Niri, window rules, keybindings, monitors, gaps, DankMaterialShell, DMS IPC,
  bar, widgets, plugins, theme, wallpaper, matugen, dynamic colors, screenshots, recording,
  snapshots, rollback, config update, protect, input method, fcitx5, waybar, lock screen,
  AI agent, cachyos commands, installer-managed config.
---

# CachyOS 桌面 skill

一套 **CachyOS + 官方 Niri + DankMaterialShell (DMS)** 桌面，由安装器
`CachyOS-Niri-Installer` 部署。本 skill 面向**已安装系统上的最终用户定制**，
不用于修改安装器源码本身。

判断标准很简单：**只要你要动 `~/.config/` 下的东西，或要跑 `cachyos-*`，先读完本 skill。**
这里的配置大多由安装器托管，直接改会和下一次 `cachyos-config update` 打架。

## 何时必须使用本 skill

- 编辑 `~/.config/niri/` 下任何文件（`config.kdl`、`dms/binds.kdl`、`cachyos-extras.kdl`）
- 编辑 `~/.config/DankMaterialShell/settings.json` 或它的插件
- 编辑 `~/.config/kitty/`、`waybar/`、`fish/`、`satty/`、`waypaper/`、`fcitx5/`、`Thunar/`
- 运行或建议任何 `cachyos-*` 命令
- 改主题、壁纸、快捷键、显示器、输入法、截图/录屏、锁屏、快照/回滚行为

## 系统架构

```
Ly (显示管理器, ly@tty2.service)
 └─ niri.service (user unit, 由 niri 包提供)      ← 会话锚点
     ├─ quickshell → DMS (面板/启动器/通知/剪贴板/锁屏/动态配色)
     │              挂在 ~/.config/systemd/user/niri.service.wants/dms.service
     ├─ cachyos-crash-watch.service (监听 coredump，崩溃→AI 诊断)
     └─ Kitty / Firefox / 其余用户应用
```

四个位置的职责，别搞混：

| 路径 | 是什么 | 能不能改 |
| --- | --- | --- |
| `/usr/local/share/cachyos-desktop/` | 随包资源：`assets/**` + `config-manifest.tsv`（托管清单） | **只读**。重跑安装器会覆盖 |
| `/usr/local/bin/cachyos-*` | 命令本体（都是可读的小 bash 脚本） | **不要改**：重跑安装器会覆盖。要定制就另写一个命令 |
| `~/.config/**` | 用户配置。其中一部分在托管清单里，会被 `cachyos-config update` 覆盖 | 可改，但受管文件要先 `protect` |
| `~/.local/state/cachyos-desktop/` | 状态：首次登录 marker、`post-login.log`、崩溃记录、agent 用量记录 | 可改（调试用），删掉 marker 会让首次登录任务重跑 |

## 命令发现

**不要凭记忆猜命令，也不要猜参数。** 三层手段：

```bash
# 1. 命令清单：/usr/local/bin/cachyos-*，一个个都是可读脚本
ls /usr/local/bin/cachyos-*
sed -n '1,20p' /usr/local/bin/cachyos-<名字>     # 多数脚本开头就有 Usage

# 2. 真源在安装器仓库里（比已安装副本更好读，注释里还写着"为什么这么做"）
#    仓库结构：bin/（命令）、assets/（配置与技能）、verify.sh（验收）、README.md

# 3. 本项目的验收脚本会列出它期望什么
./verify.sh           # 从仓库目录跑；PASS/WARN/FAIL 三态，看 FAIL 就知道缺什么
bash tests/run-all.sh # 纯函数测试，不需要桌面环境
```

组件自带的查询命令：`niri msg --help`、`dms ipc --help`、`dms doctor`、
`cachyos-lock-doctor`、`cachyos-keybind-help`、`cachyos-config status`。

## 只读与可写边界

- `/usr/local/share/cachyos-desktop/` **只读**。读取安全且鼓励——`config-manifest.tsv`
  就是判断"这个文件受不受管"的权威依据。
- **不要用 `sudo` 编辑 `~/.config` 下的文件**：那是用户自己的文件，不需要提权；
  提权只会留下 root 属主的文件，之后 Niri 和 DMS 反而写不进去。
- `/etc/**`、`/usr/lib/**`、`/usr/local/bin/**` 需要 root，但**不要直接改**：走
  `cachyos-*` 命令，或者改安装器仓库再重跑。

## 配置地图

**改之前先查这张表。** "受管"= 出现在
`/usr/local/share/cachyos-desktop/config-manifest.tsv` 的右列，会被
`cachyos-config update` 覆盖。

| 想改什么 | 动哪个文件 | 怎么生效 | 受管 |
| --- | --- | --- | --- |
| 快捷键 | `~/.config/niri/dms/binds.kdl` | Niri **保存即热重载**；改完 `niri validate` | 是 |
| 窗口规则 / 项目扩展 | `~/.config/niri/cachyos-extras.kdl` | 同上（**这个文件必需，删了 Niri 起不来**） | 是 |
| Niri 主配置（输入、布局、include） | `~/.config/niri/config.kdl` | 同上 | 是 |
| 动态配色 / 布局 / 光标 / 模糊 | `~/.config/niri/dms/{colors,layout,alttab,outputs,cursor,wpblur}.kdl` | **DMS 生成，不要手改**（会被重写） | 否 |
| 面板、启动器、锁屏等 DMS 行为 | `~/.config/DankMaterialShell/settings.json`（或用设置界面） | 界面改自动生效；手工改后可能要 `dms restart` | 否 |
| agent 主题产物 | `~/.claude/themes/cachyos.json`、`~/.hermes/skins/cachyos.yaml` | 由 `cachyos-agent-theme-sync` 从 DMS 调色板生成；不要手改，重跑同步即可 |
| DMS 插件 | `~/.config/DankMaterialShell/plugins/<id>/` | `dms ipc call plugin-scan scan`（重扫全部）或 `rescan <插件 id>` | 否 |
| Waybar 顶/底栏与样式 | `~/.config/waybar/{top,bottom}.jsonc`、`style.css` | `cachyos-waybar-top` / `-bottom` / `-toggle`（内部 `pkill -x waybar` 再启动） | 是 |
| Kitty 字体等 | `~/.config/kitty/cachyos-font.conf`（由 `kitty.conf` include） | 开新窗口生效 | 是 |
| 输入法 / RIME | `~/.config/fcitx5/profile`、`~/.local/share/fcitx5/rime/default.custom.yaml` | `cachyos-input-toggle` 或重新登录 | 是 |
| 截图标注 | `~/.config/satty/config.toml` | 下次截图生效 | 是 |
| Waypaper（独立壁纸路径） | `~/.config/waypaper/config.ini` | 下次打开生效 | 是 |
| 侧边栏 / 热角 / Thunar 动作 | `niri-sidebar/config.toml`、`waycorner/config.toml`、`Thunar/uca.xml` | 重启对应组件 | 是 |
| 崩溃监听服务 | `~/.config/systemd/user/cachyos-crash-watch.service` | `systemctl --user daemon-reload && systemctl --user restart cachyos-crash-watch.service` | 是 |

## 安全配方

### 任何托管配置的改动，都走这四步

```bash
# 1. 先看状态：current（与随包一致）/ modified（你改过）/ missing / protected
cachyos-config status

# 2. 生效保护，让 cachyos-config update 从此跳过它
cachyos-config protect ~/.config/niri/dms/binds.kdl

# 3. 改，然后就地校验
niri validate                                            # Niri 配置
dms doctor                                               # DMS 健康
systemctl --user status cachyos-crash-watch.service       # 服务类

# 4. 改坏了：拿回官方版本，或用快照回滚
cachyos-config unprotect ~/.config/niri/dms/binds.kdl && cachyos-config update
cachyos-snapshot "改快捷键前"        # 大改之前先快照（需要 Btrfs + Snapper）
cachyos-quick-rollback              # 从快照列表里选一个回滚（重启后生效）
```

### 加一个快捷键

1. `cachyos-config protect ~/.config/niri/dms/binds.kdl`
2. **先查空闲键**（见"常见坑"：26 个字母键全被占用）
3. 在 `binds { }` 里加一行，缩进与邻居一致：

   ```kdl
   Mod+Alt+J hotkey-overlay-title="说明" { spawn "命令" "参数"; }
   ```

   `hotkey-overlay-title=null` 表示不在快捷键浮层里显示这一条。
4. `niri validate`；Niri 保存即加载，不必重启会话
5. 用 `cachyos-keybind-help`（Kitty + fzf，可按快捷键/说明/动作/分组搜索）确认生效

### 换主题 / 换壁纸

- 壁纸：`Super+Alt+W`、`Super+Y`、`Super+Shift+F10` 都是
  `dms ipc call dankdash wallpaper`；换完 DMS 会重新生成配色。
  Waypaper（`Super+Ctrl+F10`）是另一条独立路径，登录时 `--restore`。
- 明暗模式：`dms ipc call theme toggle`。
- Firefox 与 VS Code 的颜色分别由 `cachyos-firefox-setup`、`cachyos-code-theme`
  链接到生成的配色，不要手改它们的目标文件。

### 出问题时先取第一手材料

```bash
cat ~/.local/state/cachyos-desktop/post-login.log          # 首次登录任务日志
journalctl --user -u niri.service -n 50 --no-pager
journalctl --user -u dms.service -n 50 --no-pager
systemctl --user status cachyos-crash-watch.service        # 崩溃监听
```

## 常见坑（都是实测出来的）

- **`Mod` 与 `Super` 是同一个键**，两种拼写等价。
- **26 个字母键全部已被占用**，`Mod+X` 也不行（`Super+X` 是 DMS 电源菜单）。
  **`Mod+grave`（`` Super+` ``）已被本项目占用**为"启动默认 AI agent"。
  实测空闲的非字母键：`Mod+BackSpace`、`Mod+Delete`、`Mod+Backslash`、`Mod+Insert`、
  `Mod+F4/F6/F7/F10/F11/F12`。
  **注意 `Mod+F9` 与 `Mod+Ctrl+X` 不是空闲的**：装了本地听写（Voxtype）后它们被
  `~/.config/niri/cachyos-voxtype.kdl` 占用；Niri 遇到重复绑定会**直接加载失败**，
  所以在这台机器上加键前先确认听写是否已安装。
- **重复绑定是硬错误**：`niri validate` 会报 `duplicate keybind`，配置加载失败。
- **`cachyos-extras.kdl` 是必需的**：主配置里的 `include "cachyos-extras.kdl"` **没有**
  `optional=true`。optional 的包括 DMS 生成的那批，以及 `cachyos-voxtype.kdl`（装了听写才有）；
  删掉或改名 `cachyos-extras.kdl` 会让 Niri 直接起不来，
  `niri validate` 报 `failed to read included config`。
- **DMS 生成的文件不要手改**：`~/.config/niri/dms/` 下除 `binds.kdl` 外基本都是生成的。
- **`config.kdl` 里的 `@HOME@`** 是安装期模板占位符，运行时文件里不应再出现。
- **不要用 `dms plugins list` / `dms plugins install`**：它们会去上游 registry 拉网络数据，
  离线或受限网络下会长时间挂住。插件一律文件部署 + `dms ipc call plugin-scan scan`
  （`rescan` **必须带插件 id**，不带参数是静默空操作）。
- **`cachyos-config` 只有五个子命令**：`status|update|migrate|protect|unprotect`。
  窗口规则不归它管——用 `dms ipc call window-rules toggle` 或 `dms config windowrules`。
- **`cachyos-config migrate` 是破坏性操作**（先备份再整体覆盖），动手前必须取得用户确认。
- **首次登录任务有 marker**：`~/.local/state/cachyos-desktop/*-v1`。删掉对应 marker 会让该
  任务在下次登录重跑——排查首次登录问题很有用，但仅限调试。
- **崩溃记录的静音按内核 15 字节对齐**：`comm` 被内核截断，所以
  `cachyos-crash-mute gnome-keyring-daemon` 实际按 `gnome-keyring-d` 静音。

## 决策框架

| 情形 | 该怎么做 |
| --- | --- |
| 用户说"我想要 X 效果" | 先在本 skill 的配置地图里找落点；找不到再读仓库 README 或命令源码 |
| 目标文件受管，且用户想保留自己的改动 | **先 `protect`**，再改 |
| 需要"重置为默认"或整体覆盖 | **先问用户**（`cachyos-config migrate` 会丢改动），并建议先 `cachyos-snapshot` |
| 需要 root | 优先用现成 `cachyos-*` 命令；必须自己提权时，有终端用 `sudo`，无终端（快捷键/通知触发）走 Kitty 重开（`cachyos-snapshot` 就是这个模式） |
| 改动可能影响登录/显示/网络等基础能力 | 先 `cachyos-snapshot`，并把回滚命令一并告诉用户 |
| 需求超出本桌面范围（换发行版、改内核、改分区） | 明说不在本 skill 范围，不要硬凑 |

## 话题指南

- [`niri.md`](niri.md) —— 文件布局、快捷键、窗口规则、输出、条件 include
- [`dms.md`](dms.md) —— DMS IPC、设置、插件契约、锁屏
- [`commands.md`](commands.md) —— `cachyos-*` 命令地图（按用途分组）

## 需要 root 时

本项目的 helper 自己处理提权：在终端里直接 `sudo`；从快捷键触发、没有终端时会用 Kitty
重新打开自己来问密码（见 `/usr/local/bin/cachyos-snapshot` 的
`CACHYOS_SNAPSHOT_TERMINAL` 模式）。

因此：优先调用现成的 `cachyos-*` 命令，不要自己拼 `sudo` 流水线；确实要新写特权命令时
效仿同一模式，不要静默失败。**不要用 `sudo` 去编辑 `~/.config` 下的文件。**

## 明确不做的事

- 不修改 `/usr/local/share/cachyos-desktop/` 与 `/usr/local/bin/cachyos-*`（重跑安装器即失效）
- 不直接改 `/etc/**`、`/usr/lib/**`（走命令或安装器）
- 不用 `sudo` 编辑 `~/.config`
- 不在没有 `protect` 的情况下"顺手改一下"托管文件
- 不跑 `dms plugins install`
- 不把"重置为默认"当第一手段——先定位，再最小改动

## 示例请求与应对

| 用户说 | 你会做什么 |
| --- | --- |
| "把终端字体调大" | 改 `~/.config/kitty/cachyos-font.conf`（受管 → 先 protect），开新窗口验证 |
| "加个快捷键打开计算器" | 查空闲键 → protect `binds.kdl` → 加绑定 → `niri validate` → `cachyos-keybind-help` 确认 |
| "壁纸颜色太暗" | 换壁纸让 DMS 重新生成配色，或切明暗模式；**不是**手改 `niri/dms/colors.kdl` |
| "顶部栏想显示网速" | 改 `~/.config/waybar/top.jsonc`（受管 → 先 protect），用 `cachyos-waybar-top` 重启 |
| "DMS 面板想换布局" | 走 DMS 设置界面或 `cachyos-dms-setting`，不要手改 `niri/dms/layout.kdl` |
| "刚才有个程序崩了" | 用 `diagnose-crash` 技能，先读 `~/.local/state/cachyos-desktop/agents/last-crash` |

## 报告问题

安装器自身的 bug 与改进建议提到 <https://github.com/skynit/CachyOS-Niri-Installer>。
上游问题（Niri、DankMaterialShell、Quickshell、Kitty）提到各自项目；崩溃类先用
`diagnose-crash` 技能判断责任方，再决定提到哪里。
