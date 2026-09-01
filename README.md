# CachyOS + Niri + DankMaterialShell

这是一个面向 CachyOS AMD 笔记本的完整桌面安装器，默认部署：

```text
CachyOS + 官方 Niri + DMS v1.5.3 + Quickshell + Kitty
```

应用、桌面增强和维护工具全部默认安装，不提供按功能拆分的可选开关。默认终端是
Kitty；DMS 负责主面板、启动器、通知、锁屏和动态主题，Quickshell 是 DMS 的运行基础。

## 使用前提

- 已通过 CachyOS 官方安装器完成基础系统安装。
- 使用可执行 `sudo` 的普通用户运行，不能直接使用 root。
- 网络连接正常。
- 当前仅支持 `x86_64`。
- 硬件预设面向 AMD 显卡/核显笔记本。

不要在 CachyOS Live ISO 中运行。

## 安装

先查看完整执行计划，不修改系统：

```bash
./install.sh --dry-run
```

执行安装：

```bash
./install.sh
```

常用选项：

```bash
./install.sh --terminal kitty   # 显式指定默认终端
./install.sh --skip-update      # 系统已更新时跳过 pacman -Syu
./install.sh --skip-hardware    # 跳过本项目的 AMD 硬件包
./install.sh --skip-codex       # 保留现有 Codex Desktop，不重新构建上游包
./install.sh --yes              # 跳过安装器自身的确认提示
```

默认安装过程会：

- 完整执行一次 `pacman -Syu`，除非使用 `--skip-update`。
- 安装 AMD 固件、Mesa/RADV、PipeWire、蓝牙及电源管理组件。
- 安装官方 Niri、DMS、Quickshell、Xwayland Satellite 和 Kitty。
- 下载并校验固定版本的 DMS 官方 `dankinstall` v1.5.3。
- 安装 DankSearch、DankCalendar，以及 DMS 官方 Niri/Kitty 配置。
- 安装全部日常应用、桌面增强和系统维护工具。
- 安装并启用 Ly，将其他已启用的显示管理器停用。
- 将 Fish 设置为登录 Shell，并配置 Starship、eza、zoxide 和 Fastfetch。
- 配置 Fcitx5、RIME、雾凇拼音、Waypaper、awww、Satty、录屏及双 Waybar。
- 配置 DMS 锁屏、电源策略、指纹和安全密钥辅助工具。
- 从 `ilysenko/codex-desktop-linux` 拉取最新源码，构建并安装 pacman 包；使用 `--skip-codex` 可跳过。
- 生成 CC Switch 与 Codex Desktop 的非敏感配置镜像，不复制账号、令牌、Cookie 或密钥。
- 自动清理受管理位置中的旧品牌包、路径和 Niri 配置残留。
- 不自动重启。

## 默认应用

`packages.sh` 是唯一的软件包清单。目前包含 **101 个去重后的仓库包**和 **13 个
AUR 包**，安装时不需要额外功能开关。

- 日常：Firefox、Thunar、Nautilus、File Roller、Transmission、Flatseal、Mission Center、GParted、LACT、EasyEffects、MPV、imv、LocalSend、Yazi、剪贴板、截图和录屏工具。
- 中文：Fcitx5、RIME、雾凇拼音、配置工具及 Noto 中文/Emoji 字体。
- 办公：LibreOffice、KeePassXC、GNOME Calendar、Obsidian。
- 开发：base-devel、Git、Neovim、Code、OpenCode、CC Switch、ShellCheck。
- 影音：OBS Studio、GIMP、Inkscape、Audacity、Kdenlive。
- 虚拟化：virt-manager、QEMU、swtpm、virt-viewer，并启用 `libvirtd`。
- 游戏：Steam、Lutris、MangoHud、Gamescope、Wine。
- 系统：Snapper、Btrfs Assistant、Reflector、Flatpak、Paru、Yay、fzf、Ly，以及图像放大工具 Upscaler。
- AI 与网络：Codex Desktop、Clash Verge Rev。
- 通讯：QQ、微信。
- 安全：fprintd、pam-u2f、libfido2 和 DMS 专用 U2F PAM 服务。

AUR 包包括 QQ、微信、Upscaler、CC Switch、ProtonPlus、Gearlever、Codex Desktop、
Clash Verge Rev、Obsidian、雾凇拼音、Waypaper、`nirius`、Waycorner 和 Woomer。
`niri-sidebar` 不走 AUR，由安装器下载固定版本并校验 SHA-256。

## 桌面功能

### DMS、Niri 与 Overview

- DMS 是默认面板、启动器、通知中心、剪贴板、锁屏和动态主题服务。
- DMS 仅绑定到 Niri 用户会话，不会在其他桌面会话中自动启动。
- DMS 的模糊壁纸层与 Niri 深色 backdrop 组合成暗色模糊 Overview。
- DMS Overview 设置为 2 行、5 列，用于提高窗口查找效率。
- `Super+Shift+/` 打开 Kitty + fzf，可按快捷键、说明、动作或分组搜索教程。

### 截图、录屏与 Waybar

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

### 窗口效率工具

- `niri-sidebar`：将窗口加入或移出侧边栏、显示/隐藏侧边栏、左右翻转。
- `nirius`：窗口跟随模式，以及按应用 ID 快速聚焦或启动。
- Waycorner：提供热角动作。
- Woomer：提供手动屏幕放大镜。
- Waypaper + awww：切换壁纸，并通知 DMS 重新生成动态颜色。
- Thunar：媒体信息、视频转 GIF、图片转 PNG、Code 打开、粘贴剪贴板图片、粘贴符号链接和获取所有权。

### 中文输入、Shell 与应用初始化

- Fcitx5 默认启用 RIME 和雾凇拼音；不安装联网大模型输入插件。
- Fish 登录 Shell 加载 Starship、eza、zoxide，并保留 Kitty 作为默认终端。
- Firefox 首次登录时安装固定校验的 Material 主题、启用竖向标签页，并通过企业策略强制安装 uBlock Origin。
- Firefox 的主题颜色链接到 DMS 生成的 Matugen CSS。
- Code 首次登录时安装 DMS 自带的 Matugen VSIX 并选择动态主题。
- Wine 首次登录时初始化默认 Wine Prefix，并安装核心字体、中文字体和字体平滑设置。

首次登录任务在后台逐项执行，成功项目不会在后续登录重复覆盖。状态和日志位于：

```text
~/.local/state/cachyos-desktop/
~/.local/state/cachyos-desktop/post-login.log
```

网络下载失败时，只会在下次登录重试未完成的项目。

## 默认快捷键

安装器会在 DMS 生成配置后，用 `assets/niri/binds.kdl` 覆盖
`~/.config/niri/dms/binds.kdl`，因此目标机器会获得当前系统正在使用的整套操作习惯。
`assets/niri/cachyos-extras.kdl` 继续提供 Waybar、长截图、nirius 和放大镜等补充快捷键。

### 常用应用与系统操作

```text
Super+Shift+/              搜索快捷键教程
Super+F1 / Super+Space     切换 Fcitx5 输入法
Ctrl+Space                切换 Fcitx5 输入法
Super+F2                   打开 DMS 设置
Super+F3                   打开录屏菜单
联想功能键模式下，Super+静音/音量-/音量+ 分别等价于 Super+F1/F2/F3
Super+F5                   创建 Snapper 快照（必要时打开 Kitty 请求 sudo）
Super+F8                   打开 Snapper 快速回滚选择器
Super+/                    打开 Kitty 临时终端
Super+T                    打开 Kitty 单实例终端
Super+Enter                打开独立 Kitty 终端
Super+B                    打开 Firefox
Super+Alt+O                在 Kitty 中打开 OpenCode
Super+P                    提取当前窗口信息并复制
Super+E                    打开 Thunar，失败时回退 Nautilus
Super+Alt+E                打开 Nautilus
Super+Z                    打开 DMS Spotlight，失败时回退 Fuzzel
Super+Alt+W / Super+Y      打开 DMS 壁纸选择器
Super+O / Super+G          打开或关闭 Niri Overview
Super+Q                    正常关闭当前窗口
Alt+F4                     强制结束点选窗口
Alt+Shift+F4               强制结束点选窗口及其进程树
Super+X                    打开 DMS 电源菜单
Super+Alt+V                打开 DMS 剪贴板
Super+Shift+N              打开 DMS 记事本
Super+Alt+L                锁屏
Super+Alt+P                锁屏、关闭显示器并休眠
Ctrl+Alt+Delete            打开 DMS 任务管理器
Super+Shift+W              打开 DMS 窗口规则工具
```

### Codex 与 CC Switch 配置

安装器将上游源码放在 `~/.cache/cachyos-niri-dms/codex-desktop-linux`，构建日志和
产物保留在该目录中。已安装的上游包会写入构建来源信息，可用以下命令检查：

```bash
codex-desktop --version 2>/dev/null || true
jq '.source' /opt/codex-desktop/.codex-linux/build-info.json
```

CC Switch 使用 SQLite 数据库，Codex Desktop/Codex CLI 使用独立的配置文件。脚本会迁移
CC Switch 数据库中的全部 Provider，并把当前选中的 Codex Provider 写入
`~/.codex/config.toml` 与 `~/.codex/auth.json`；镜像文件只保留非敏感字段：

```bash
cachyos-ai-config-sync status
cachyos-ai-config-sync backup
cachyos-ai-config-sync sync
```

镜像位于 `~/.config/codex-desktop/cc-switch-sync.json` 和
`~/.cc-switch/codex-desktop-sync.json`。真实 API 凭据只写入权限为 `600` 的
`~/.codex/auth.json`，不会写入镜像或日志。

### 窗口、列、显示器与工作区

```text
Super+方向键 / H J K L     切换列或列内窗口
Super+Ctrl+方向键 / HJKL   移动列或列内窗口
Super+S / Super+W          向下或向上移动列内窗口
Super+Home / End           聚焦第一列或最后一列
Super+Ctrl+Home / End      将当前列移到第一列或最后一列
Super+Shift+方向键 / HJKL  切换显示器
Super+Ctrl+Shift+方向键    将当前列移动到相邻显示器
Super+Ctrl+Shift+HJKL      将当前列移动到相邻显示器
Super+Ctrl+Shift+WASD      将当前列移动到相邻显示器
Super+Alt+Shift+方向键     将整个工作区移动到相邻显示器
Super+Alt+Shift+HJKL/WASD  将整个工作区移动到相邻显示器
Super+鼠标滚轮             左右切换列
Super+Ctrl+鼠标滚轮        左右移动列
Super+Shift+鼠标滚轮       切换工作区
Super+Ctrl+Shift+鼠标滚轮  将当前列移动到相邻工作区
Super+[ / ]                向左或向右吸收/移出窗口
Super+A / D                向左或向右吸收/移出窗口
Super+, / .                合并窗口到列或从列中移出
Super+Shift+A / D          合并窗口到列或从列中移出
Super+Shift+X              切换列标签页模式
Super+R                    切换预设列宽
Super+Shift+R              切换预设窗口高度
Super+Ctrl+R               重置窗口高度
Super+F                    最大化当前列
Super+Alt+F                当前窗口全屏
Super+Ctrl+F               扩展列到可用宽度
Super+C                    居中当前列
Super+Ctrl+C               居中全部可见列
Super+- / =                减少或增加列宽
Super+Shift+- / =          减少或增加窗口高度
Super+V                    切换当前窗口浮动状态
Super+Shift+V / Super+N    在浮动和铺排窗口间切换焦点
Alt+` / Super+Alt+N        在浮动和铺排窗口间切换焦点
Super+1 ... Super+9        切换到数字工作区
Super+Ctrl+1 ... Super+Ctrl+9  将当前列移到数字工作区
Super+U / I                切换到下一个或上一个工作区
Super+Ctrl+U / I           将当前列移到相邻工作区
Super+Shift+U / I          重新排列工作区
Ctrl+Shift+R               重命名工作区
```

### 侧边栏、截图、媒体与补充功能

```text
Super+Alt+S / Super+M      将窗口加入或移出侧边栏
Super+Alt+Z                显示或隐藏侧边栏
Super+Alt+X                翻转侧边栏
Super+Alt+R                重新排列侧边栏窗口
Print / Super+Alt+A        区域截图
Ctrl+Print                 当前窗口截图
Shift+Print                当前显示器截图
Super+Shift+S              区域截图并使用 Satty 编辑
音量、媒体、亮度功能键      通过 DMS IPC 控制
Super+Ctrl+F2/F3/F4        顶栏、底栏和 Waybar 开关
Super+Ctrl+F9              开始或停止区域录屏
Super+Shift+F9             开始或停止 GIF 录屏
Super+Ctrl+F10             打开 Waypaper
Super+Ctrl+F11             区域截图并使用 Satty 编辑
Super+Ctrl+Shift+F11       连续翻页并智能拼接长截图
Super+Ctrl+F12             立即锁屏
Super+Shift+F12            锁屏并关闭显示器
Super+Alt+F5               将当前窗口加入或移出侧边栏
Super+Alt+Shift+F5         显示或隐藏侧边栏
Super+Alt+Ctrl+F5          翻转侧边栏位置
Super+Alt+F6               切换 nirius 窗口跟随模式
Super+Alt+F7               打开 Woomer 放大镜
Super+Alt+F8               打开官方 Niri Overview
Super+Alt+1                聚焦或启动 Firefox
Super+Alt+2                聚焦或启动 Kitty
```

`Super+Escape` 用于切换应用的快捷键抑制，`Super+Shift+E` 用于退出 Niri；后者会结束当前桌面会话，使用前应保存工作。

## 锁屏与电源

DMS 默认使用密码认证，并应用以下策略：

| 电源状态 | 自动锁屏 | 关闭显示器 | 自动休眠 |
| --- | ---: | ---: | ---: |
| 接通电源 | 5 分钟 | 10 分钟 | 60 分钟 |
| 使用电池 | 3 分钟 | 5 分钟 | 30 分钟 |

- 休眠前强制锁屏，并使用 `loginctl` 集成。
- 锁屏和关闭显示器前有 5 秒渐暗时间。
- 锁屏通知仅显示数量，不显示通知内容；锁屏媒体控件默认关闭。
- 指纹和安全密钥组件默认安装，但必须注册成功后才启用。
- 安全密钥默认使用“密码或密钥”模式，不强制双因素同时通过。

```bash
cachyos-enroll-fingerprint       # 录入指纹并启用 DMS 指纹解锁
cachyos-register-security-key   # 注册 U2F/FIDO2 密钥并启用解锁
cachyos-lock-doctor             # 检查 PAM、IPC、指纹、密钥和超时设置
```

应始终先保留并验证密码解锁，再测试指纹或安全密钥。

## 配置更新、保护与迁移

安装器将受管理配置副本保存到 `/usr/local/share/cachyos-desktop`。以后可使用：

```bash
cachyos-config status                 # 查看 current/modified/missing/protected
cachyos-config update                 # 更新未保护的配置
cachyos-config migrate                # 先备份现有配置，再更新
cachyos-config protect ~/.config/...  # 保护自定义文件，阻止自动覆盖
cachyos-config unprotect ~/.config/... # 取消保护
```

迁移备份存放在 `~/.local/state/cachyos-desktop/migration-*`。

## 软件卸载与 HOME 残留

需要跟踪某个软件在 HOME 中创建的文件时，先通过 `strace` 启动一次：

```bash
cachyos-track-app PACKAGE [COMMAND ...]
```

如果省略命令，会自动选择该包安装的第一个可执行文件。正常关闭应用后，再运行：

```bash
cachyos-pkg-remove-tracked [PACKAGE]
```

脚本先卸载软件包，再通过 fzf 让用户选择要删除的 HOME 残留；不会未经选择直接删除候选文件。

## 系统维护

```text
cachyos-snapshot [说明]          创建 Snapper 快照
cachyos-rollback 快照编号        准备回滚
cachyos-mirror-update            更新 Arch 镜像列表
cachyos-system-update            更新 pacman、AUR 和 Flatpak
cachyos-system-clean             清理孤立包、缓存和旧日志
cachyos-pkg-install              TUI 安装软件包
cachyos-pkg-remove               TUI 卸载软件包
cachyos-flatpak-install          TUI 安装 Flatpak
cachyos-flatpak-remove           TUI 卸载 Flatpak
cachyos-grub-theme               选择已安装的 GRUB 主题或禁用自定义主题
```

Snapper 快照和回滚仅在根文件系统为 Btrfs 时可用。`cachyos-grub-theme` 不下载主题，
只切换 `/usr/share/grub/themes` 中已经安装的主题；每次修改都会备份 `/etc/default/grub`
并重新生成 GRUB 配置。安装器本身不会修改引导加载器。

## 安装后操作与验收

1. 重启，在 Ly 中选择 Niri 会话。
2. 至少退出并重新登录一次，使 Fish、Fcitx5、`libvirt` 和 `i2c` 组权限生效。
3. 等待首次登录的 Firefox、Code、Wine 初始化完成。
4. 在本项目目录执行：

```bash
./verify.sh
dms doctor
cachyos-lock-doctor
```

硬件进一步检查：

```bash
lspci -nnk
vulkaninfo --summary
wpctl status
powerprofilesctl
bluetoothctl show
ddcutil detect
```

## 官方 Niri 与修改版功能差异

本项目只安装官方 Niri，不安装第三方 fork，因此以下功能是中性替代，不是完全复刻：

| 目标功能 | 当前实现 | 差异 |
| --- | --- | --- |
| 网格概览 | 官方 Niri Overview + DMS 2×5 设置 | 不保证与 fork 的网格布局和交互完全一致 |
| 暗色模糊概览背景 | DMS 模糊壁纸层 + Niri 深色 backdrop | 使用官方配置能力组合实现 |
| 放大镜 | `Super+Alt+F7` 手动启动 Woomer | 不支持鼠标快速晃动自动放大 |
| 热角 | Waycorner | 独立工具实现，不依赖修改版 Niri |
| 窗口跟随/快速聚焦 | nirius | 独立辅助服务实现 |
| 侧边栏 | niri-sidebar | 独立辅助服务实现 |

不要把 DMS 的 2×5 设置理解为官方 Niri 新增了 fork 的私有网格实现。鼠标晃动放大也未实现，
当前提供的是明确快捷键触发的 Woomer。

## 明确不会自动执行的操作

本安装器不会：

- 添加 ArchLinuxCN 或其他第三方软件仓库。
- 修改 `/etc/pacman.conf` 或 CachyOS 软件源。
- 切换 NetworkManager 到 IWD，或删除现有网络连接。
- 安装、重写或自动切换 GRUB、Limine、systemd-boot。
- 修改 Secure Boot、Windows 分区或双系统设置。
- 自动安装第三方 Wi-Fi DKMS 驱动。
- 自动重启。

## DMS 版本更新

默认版本固定是为了让下载内容可复核。升级 DMS 安装器时，必须同时更新
`install.sh` 中的：

```text
PINNED_DMS_VERSION
PINNED_DMS_SHA256_AMD64
```

SHA-256 必须来自对应 GitHub Release 的 `dankinstall-amd64.gz.sha256`，并在更新后
重新执行本目录的语法、结构化配置和 dry-run 检查。
