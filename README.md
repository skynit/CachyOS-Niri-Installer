# CachyOS + Niri + DankMaterialShell

这是一个面向已安装 CachyOS 的 x86_64 设备的完整桌面配置安装器，默认部署：

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
- 自动检测 Intel/AMD CPU 与 Intel/AMD/NVIDIA 显卡，并选择对应的微码、Mesa/Vulkan 或 NVIDIA 用户态驱动包。
- 混合显卡会合并所需驱动包；无法识别的设备会显示警告，而不会错误套用其他厂商驱动。

不要在 CachyOS Live ISO 中运行。

## 获取 CachyOS 安装镜像

基础系统尚未安装时，可从 CachyOS 官方 CDN 下载桌面版 ISO。仓库不保存镜像文件：

```bash
curl --fail --location --continue-at - \
  --output cachyos-desktop-linux-260809.iso \
  https://cdn77.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso
```

校验下载结果：

```bash
echo '959f6577f45e25ee9fd8c220fd221b08e4ea79412c7315c0f922dd6d86d5e33c  cachyos-desktop-linux-260809.iso' \
  | sha256sum --check
```

- SHA-256：`959f6577f45e25ee9fd8c220fd221b08e4ea79412c7315c0f922dd6d86d5e33c`
- 官方校验文件：<https://cdn77.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso.sha256>
- 官方签名：<https://cdn77.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso.sig>
- 签名密钥指纹：`882D CFE4 8E20 51D4 8E25 62AB F3B6 0748 8DB3 5A47`

使用该镜像完成 CachyOS 基础安装并进入已安装的系统后，再运行本项目的安装脚本。

## 新电脑复刻与 Windows 双系统

本项目不是整盘镜像，不能恢复本机文档、账号或应用私有数据；它用于在新的 CachyOS
基础系统上重新部署本项目管理的软件、Niri 配置、快捷键、DMS 设置和辅助脚本。包括
`Alt+F4` 强制关闭窗口在内的项目快捷键会随安装器一同部署。

如果新电脑需要 Windows 与 CachyOS 双系统，建议先安装 Windows，再安装 CachyOS，最后
运行本项目。Windows 的详细安装、驱动和首次开机步骤见
[Windows-Installer](https://github.com/skynit/Windows-Installer)。

### 准备安装介质

Ventoy 数据分区可以同时保存 Windows ISO、CachyOS ISO 和离线网卡驱动。只有首次把
Ventoy 安装到 U 盘时会清空该 U 盘；之后向 Ventoy 数据分区复制 ISO 或驱动文件不会
自动格式化 U 盘。制作或更新安装盘前仍应核对设备型号、容量和分区，避免选错磁盘。

至少准备以下内容：

- Windows 安装镜像。
- 本 README 上方给出的 CachyOS 安装镜像。
- 新电脑厂商提供的 Windows 芯片组、有线网卡、Wi-Fi 和蓝牙驱动。
- 重要数据的独立备份；全新安装时只清除确认无误的目标系统盘。

### 同一块硬盘：Windows 使用 256 GiB

下面按 UEFI/GPT 安装，并假设目标系统盘上的原有数据可以全部清除：

1. 从 Windows 安装盘的 UEFI 启动项进入安装程序，选择自定义安装。
2. 只删除目标系统盘上的原有分区，直到整块目标盘显示为未分配空间。不要按“磁盘 0”
   猜测目标，应同时核对磁盘容量和型号。
3. 在未分配空间中点击新建，输入 `262144 MB`。这对应 256 GiB；让 Windows 安装程序
   自动在这一区域内创建 EFI、MSR、Windows 和恢复分区。
4. 将 Windows 安装到刚创建的主分区，剩余空间保持为未分配，不要在 Windows 安装阶段
   新建第二个 NTFS 分区。
5. 进入 Windows 后先安装网络、芯片组和设备驱动，完成 Windows Update。准备让两套系统
   读写同一 NTFS 数据分区时，以管理员身份关闭休眠和快速启动：

```powershell
powercfg /hibernate off
```

6. 从 CachyOS 安装盘的 UEFI 启动项进入 Live 系统。运行 `efibootmgr -v`；如果提示 EFI
   variables 不受支持，说明当前不是以 UEFI 模式启动，应退出并重新选择 UEFI 启动项。
7. 启动 CachyOS 安装器并选择手动分区。不要使用“Install alongside”或“Replace
   partition”，也不要删除或格式化 Windows 创建的 EFI、MSR、NTFS 和恢复分区。
8. 在剩余未分配空间中为 Limine 创建以下分区：

| 用途 | 大小 | 文件系统 | 挂载点 | 标记 |
| --- | ---: | --- | --- | --- |
| CachyOS 启动分区 | 4096 MiB | FAT32 | `/boot` | `boot` |
| CachyOS 根分区 | 剩余空间 | Btrfs | `/` | 无 |

9. 在安装器中选择 Limine，并再次确认引导器目标和上述 `/boot` 分区位于目标系统盘。
   Limine 支持 Btrfs 快照启动，并可扫描 Windows Boot Manager。安装摘要中一旦出现格式化
   Windows 分区的操作，应立即返回修改。
10. CachyOS 安装完成后重启。若 Limine 菜单未显示 Windows，在 CachyOS 中运行：

```bash
sudo limine-scan
```

即使引导菜单暂时没有 Windows，也可以先通过主板 UEFI 启动菜单选择 Windows Boot
Manager。双系统启动确认正常后，再按下方“安装”章节运行本项目。

Windows 更新可能改变 EFI 启动顺序。条件允许时，让 Windows 与 CachyOS 分别使用独立
硬盘和各自的 EFI/启动分区会更稳妥。分区和引导器要求应以当前
[CachyOS 官方安装文档](https://wiki.cachyos.org/installation/installation_on_root/)与
[引导器说明](https://wiki.cachyos.org/installation/boot_managers/)为准。

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
./install.sh --skip-hardware    # 跳过自动识别的硬件包
./install.sh --yes              # 跳过安装器自身的确认提示
```

默认安装过程会：

- 完整执行一次 `pacman -Syu`，除非使用 `--skip-update`。
- 根据 CPU/GPU 自动安装微码、Mesa/Vulkan 或 NVIDIA 驱动，以及 PipeWire、蓝牙和电源管理组件。
- 安装官方 Niri、DMS、Quickshell、Xwayland Satellite 和 Kitty。
- 下载并校验固定版本的 DMS 官方 `dankinstall` v1.5.3。
- 安装 DankSearch、DankCalendar，以及 DMS 官方 Niri/Kitty 配置。
- 安装全部日常应用、桌面增强和系统维护工具。
- 安装并启用 Ly，将其他已启用的显示管理器停用。
- 将 Fish 设置为登录 Shell，并配置 Starship、eza、zoxide 和 Fastfetch。
- 配置 Fcitx5、RIME、雾凇拼音、Waypaper、awww、Satty、录屏及双 Waybar。
- 配置 DMS 主题、光标、模糊、锁屏、电源策略、指纹和安全密钥辅助工具。
- 通过 CachyOS 仓库安装 Codex CLI 和 Claude Code，并通过 AUR 安装 `codex-desktop-git`。
- 生成 CC Switch 与 Codex Desktop 的非敏感配置镜像，不复制账号、令牌、Cookie 或密钥。
- 部署稳定的 Niri 主配置、快捷键和项目扩展；DMS 根据受管理的设置生成配色、布局、光标和模糊配置。
- 禁止 Niri 接管电源键，并自动隐藏企业微信在 XWayland 下产生的黑色阴影窗口。
- 自动清理受管理位置中的旧品牌包、路径和 Niri 配置残留。
- 不自动重启。

## 默认应用

`packages.sh` 是**应用清单**的唯一来源（DMS 的功能包与硬件相关包另有出处）。目前包含
**104 个去重后的仓库包**和 **14 个
AUR 包**，安装时不需要额外功能开关。

- 日常：Firefox、Thunar、Nautilus、File Roller、Transmission、Flatseal、Mission Center、GParted、LACT、EasyEffects、MPV、imv、LocalSend、Yazi、剪贴板、截图和录屏工具。
- 中文：Fcitx5、RIME、雾凇拼音、配置工具及 Noto 中文/Emoji 字体。
- 办公：LibreOffice、KeePassXC、GNOME Calendar、Obsidian。
- 开发：base-devel、Git、Neovim、Code、OpenCode、Codex CLI、Claude Code、CC Switch、ShellCheck。
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
- DMS 在 Overview 中启用壁纸模糊，Niri 使用深色 backdrop；常驻模糊壁纸层保持关闭。
- DMS Overview Overlay 保持启用，并使用完整启动器样式。
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
- Waypaper + awww：切换壁纸，并通知 DMS 重新生成动态颜色。动态颜色取决于新机选择的壁纸。
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

安装器直接管理 `assets/niri/config.kdl`、`assets/niri/binds.kdl` 和
`assets/niri/cachyos-extras.kdl`。DMS 根据 `assets/dms/desktop-settings.json` 生成
配色、布局、输出、光标和模糊配置，因此这些自动生成文件不会被项目强制覆盖。

新机可以复刻稳定的 Niri 行为、窗口规则、Overview 设置和整套快捷键。动态配色仍取决于
所选壁纸；项目不复制本机个人壁纸、账号、令牌、Cookie、密钥或应用私有状态，因此不承诺
像素级复刻当前桌面。

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
Super+Alt+O                用 OpenCode 启动 AI agent（自动带无人值守旗标）
Super+Alt+C                用 Claude Code 启动 AI agent
Super+`                    启动默认 AI agent（未设置时弹出选择器）
Super+Alt+B                打开 Obsidian
Super+P                    提取当前窗口信息并复制
Super+E                    打开 Thunar，失败时回退 Nautilus
Super+Alt+E                打开 Nautilus
Super+Z                    打开 DMS Spotlight，失败时回退 Fuzzel
Super+Alt+W / Super+Y      打开 DMS 壁纸选择器
Super+O / Super+G          打开或关闭 Niri Overview
Super+Q                    正常关闭当前窗口
Alt+4 / Alt+F4             强制结束点选窗口
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

Codex Desktop 使用当前系统采用的 AUR `codex-desktop-git` 包，Codex CLI 使用仓库中的
`openai-codex`。可用以下命令检查桌面包与构建来源：

```bash
pacman -Qi codex-desktop-git
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

### AI Agent

安装时会**自动确定默认 agent**：只探测到 1 个可用的 agent（`claude`/`codex`/`opencode`）就直接设为默认，
按下 `Super+\`` 立刻能用；探测到多个则留空——第一次按会弹出选择器，选一次之后就被记住。


安装器把三个 AI 编程 agent 接成同一套入口，并自动带上各自的"无人值守"旗标——这些旗标
每个 agent 都不一样，散落在快捷键里很难维护：

| agent | 包 | 无人值守旗标 |
| --- | --- | --- |
| `opencode` | `opencode` | `--auto` |
| `claude` | `claude-code` | `--permission-mode auto` |
| `codex` | `openai-codex` | `--approve-for-me` |

```bash
cachyos-default-agent                 # 查看当前默认 agent（未设置时无输出）
cachyos-default-agent codex           # 设为默认
cachyos-agent                         # 启动默认 agent；没有默认值时弹选择器
cachyos-agent --pick                  # 强制重新选择
cachyos-agent claude                  # 启动指定 agent
cachyos-agent --list                  # 列出支持的 agent 及安装状态
cachyos-agent-prompt "审查这个改动"     # 带一段 prompt 启动默认 agent
```

- 默认 agent 记在 `~/.config/cachyos-desktop/agent`（权限 0600）。这个文件可以手工改，
  读取时会去掉首尾空白；如果写的是不受支持的名字，会提示并转为重新选择，而不是直接报错。
- 选择器在终端里就地运行；没有终端（例如快捷键触发）时开一个 Kitty 窗口跑 fzf，
  选择结果通过临时文件回传。按 `Esc` 取消则退出 1，不改动原默认值。
- 所有 agent 窗口共用 kitty class `cachyos-agent`；这样一条窗口规则或主题就能覆盖全部
  agent 窗口，不必每个 agent 各写一条（项目本身目前没有为它写规则）。
  从快捷键启动会开新窗口；在终端里加 `--inline` 直接在当前终端运行。
- 三个 agent 的 `-p`/`--help` 之类参数不会被误当成选项：`claude` 与 `codex` 的 prompt
  统一用 `--` 分隔（`opencode` 走自己的 `--prompt`）。prompt 里的换行、引号、反斜杠、
  `$`、制表符都原样传给 agent。

#### Agent 技能

安装器把两份技能软链到各 harness 的技能目录，让 agent 知道这套桌面该怎么改：

- `cachyos`：Niri、DMS、`cachyos-*` 命令的正确用法，以及"哪些配置受安装器托管、
  改前要先 `cachyos-config protect`"。
- `diagnose-crash`：如何从 `coredumpctl` 事实判断崩溃该归因于用户配置还是上游 bug。

只为**已存在**的技能目录建立软链（`~/.agents/skills`、`~/.claude/skills`、`~/.codex/skills`、
`~/.gemini/config/skills`、`~/.pi/agent/skills`、`~/.hermes/skills` 及每个已存在的
`~/.hermes/profiles/*/skills`、`~/.cc-switch/skills`），绝不创建 harness 目录。
安装时、首次登录以及每次 `cachyos-agent` 启动前各同步一次——最后这个时机最可靠，
因为那时 harness 目录才确实存在。手动重跑：

```bash
cachyos-agent-skills
cachyos-agent-skills --harness codex   # 只同步某一个 harness
```

#### 崩溃诊断

`cachyos-crash-watch.service` 常驻监听 systemd-coredump。`cachyos-toggle-crash-capture` 可以整体关掉它：
关闭时写一个标记文件（单元里的 `ConditionPathExists=!` 让它在下次登录时也不启动），并立刻停掉当前会话的
监听——所以"关掉"是一次性动作，不用每次登录再关一遍。

进程崩溃后会：

1. 把 `pid`/`comm`/`exe`/`signal`/时间写入
   `~/.local/state/cachyos-desktop/agents/last-crash`；
2. 发一条通知。同一程序 60 秒内**只记录并提醒一次**——去重判断在写记录之前，所以窗口内的
   第二次崩溃既不记录也不提醒（`CACHYOS_CRASH_DEDUPE_SECONDS` 可调）。

诊断入口：

```bash
cachyos-agent-crash --latest        # 用默认 agent 诊断最近一次记录到的崩溃
cachyos-agent-crash 1516893         # 指定 PID（PID 见 coredumpctl list）
cachyos-crash-mute                  # 列出已静音的程序
cachyos-crash-mute SomeApp          # 不再提醒该程序
cachyos-crash-mute SomeApp off      # 恢复提醒
```

通知默认就是**可点击的动作式**：点通知上的「用 AI 诊断」会把崩溃的四个字段
（进程 / PID / 程序 / 信号）一并交给默认 agent（已在真实桌面会话上验证通知服务会回发
动作）。想要只提示、不等待点击，就设 `CACHYOS_CRASH_ACTION=0` 启动 watcher；动作式
通知发不出去时也会自动退回提示式。

几个刻意的设计：

- **同一个程序最多保留一条待处理通知。** 动作式通知会一直等到用户处理（`-t 0` 不自动
  过期），若每次都新起一个，崩溃循环会让通知和等待进程无上界堆积。
- **通知在后台发送**，不阻塞检测循环——否则用户还没点的那段时间里发生的崩溃都不会被记录。
- **静音按内核的程序名长度对齐**：内核只记录 `comm` 的前 15 字节，所以
  `cachyos-crash-mute gnome-keyring-daemon` 会按 `gnome-keyring-d` 静音（并给出提示）。
  静音只是不再提醒，程序该崩还是会崩。
- **`cachyos-agent-crash` 只把事实交给 agent**，诊断方法本身写在 `diagnose-crash` 技能里，
  因此换任何默认 agent 都适用，方法也只维护一份。

#### 用量统计

安装器会装上 DMS 面板插件 **CachyOS Agents 用量**：**状态栏只显示 token 用量**（没有图标、
没有金额），点开是每个 agent 的明细（今天/累计的 token 与费用、会话与提示数、按费用排序的
模型、最近 7 天的**折线图**）。默认登记 Claude Code、Codex、OpenCode 与 **DSH（DeepSeek Harness）**，
每个都能在插件设置里单独关掉。

```bash
cachyos-agent-usage-update            # 刷新所有 agent 的用量记录（面板每 15 分钟自己调一次）
cachyos-agent-usage-update claude     # 只跑某一个 agent
cachyos-agent-usage-update --limits-only   # 只刷新限额，不动本地统计
cachyos-agent-usage-claude            # 每个 agent 一个采集器，各自输出一条 JSON 记录
cachyos-agent-usage-codex
cachyos-agent-usage-dsh
```

安装时会**先算一次**，并启用 `cachyos-agent-usage.timer`（登录后 2 分钟 + 此后每 15 分钟，
`Persistent=true`，所以关机期间错过的刷新会在开机后补上）。没有这个定时器，面板只会停在
安装那一刻的数字。

数据链路：采集器 → `~/.local/state/cachyos-desktop/agents/usage/<agent>.json` → 面板读取。
面板只读目录；加一个 agent 需要两处：加一个采集器，并把它登记进面板的 agent 表
（`Usage.js` 顶部的 `agents` 数组——`summarise()` 只遍历那张表，只加 JSON 文件不会显示）。

> **DSH 的金额**：它的事件流里没有花费，cc-switch 的定价库里也没有 deepseek 条目，所以 DSH
> 默认只统计 token。想看到金额就在 `~/.config/cachyos-desktop/agents/dsh.json` 里给单价
> （美元/百万 token）：`{"pricing": {"deepseek-v4-flash": {"input": 0.28, "output": 1.1, "cacheRead": 0.028}}}`。

- 全部在本机取数，**不联网**：Claude 读 `~/.claude/projects/**` 的转录，Codex 读
  `~/.codex/sessions/**` 的 rollout，DSH 读 `~/.dsh/sessions/**` 下 zstd 压缩的事件流
  （v4/v2/v0 三种格式都兼容；提示数只认 `source.kind == "user"`，合成条目不算）。
- **费用**取自 cc-switch 的 `model_pricing` 表（装了 cc-switch 才有）；没有定价时只显示
  token，未定价的模型会标注「未定价」。
- **token 语义按各家对齐**：Claude 与 DSH 的 input 都**不含**缓存读，Codex 的已含缓存。记录里用
  `inputTokenSemantics` 标明，总量与费用都据此拆分，避免缓存被重复计算。DSH 的 `reasoningTokens`
  已含在 `outputTokens` 里，不会被再加一遍。
- **缓存按源文件 `(mtime, size)` 增量**，并带 `CACHE_VERSION`：解析逻辑一变缓存整体作废，
  否则会出现"代码修好了、屏幕上的数字还是旧的"。
- 缺数据显示「未采集 / 无数据」，绝不把没采到渲染成 0；今天没有用量时回落到最近有数据的
  一天并标出日期（例如 `10-01 12.0M`）——金额只在弹窗里看。

插件的源码真源在 <https://github.com/skynit/dms-plugins>，安装器里放的是随包副本
（`assets/dms-plugins/CachyosAgents/`），这样全新机器离线也能复刻。面板纯逻辑由
`node --test` 覆盖；接线用的两个 jq 程序（只增不覆盖、幂等、尊重用户已关掉的开关）由
`tests/dms-plugin-test.sh` 覆盖。

#### 本地听写（可选）

基于 [Voxtype](https://github.com/peteonrails/voxtype)，本地 Whisper 推理，不上传音频。
**刻意不装进默认安装**：语音模型约 150MB，听写也不是所有人的需求。

```bash
cachyos-voxtype-install    # 装 voxtype-bin + wtype、下载模型、按需开 GPU、写好快捷键
cachyos-voxtype-toggle     # 开始/结束听写（快捷键绑的就是它）
cachyos-voxtype-config     # 打开 voxtype 的交互式配置
cachyos-voxtype-model      # 换模型 / 重新下载
cachyos-voxtype-status     # 输出 Waybar 的 JSON 状态（栏上那个"听写中"）
cachyos-voxtype-remove     # 卸载：删快捷键、备份配置、移除模型
```

安装后快捷键是 **`Super+Ctrl+X`** 与 **`Super+F9`**（都是开始/结束切换）。这两个键
写在 `~/.config/niri/cachyos-voxtype.kdl`，由主配置用 `include optional=true` 引入——
Niri 没有条件绑定，用可选 include 才能做到"**装了听写才有这几个键**"，而不是让没用听写的人
白白失去它们。

> **已知限制（实测）**：上游 Omarchy 在 Hyprland 上用 `F9` 的"按下开始 / 松开结束"实现
> 按住说话。**Niri 不支持按键释放绑定**——`F9 release { }` 会让 `niri validate` 直接解析
> 报错——所以本项目只能做 toggle：按一次开始，再按一次结束。裸 `F9` 也没有被占用，
> 它仍然是应用自己的功能键。

栏上的状态控件空闲时不显示文字（自动收起），只在录音/转写时出现；状态从
`$XDG_RUNTIME_DIR/voxtype/state` 读取，由 `voxtype` 自己维护。用 `cachyos-voxtype-remove`
卸载时会先把 `~/.config/voxtype` 备份成带时间戳的目录，不会静默丢掉你调过的设备或采样率。

#### 主题同步

DMS 换壁纸或切明暗后，把当前的**明暗模式**同步给各 agent，省得每次都要手动去各家设置里改：

```bash
cachyos-agent-theme-sync            # 同步一次（生成 Claude 自定义主题 + Hermes skin 并接线）
cachyos-agent-theme-sync --status   # 只看当前模式与各 agent 状态，不写文件
cachyos-agent-theme-sync --dry-run  # 只显示会改什么
```

- 数据源是 DMS 生成的 `~/.cache/DankMaterialShell/dms-colors.json`（里面直接带 `mode`）。
- 已同步：**Claude Code** —— 写 `~/.claude/settings.json` 的 `theme`（`dark` / `light`），
  只改这一个键，其余原样保留。
- 未同步：**Codex**（`config.toml` 与 `codex --help` 都没有主题配置项，TUI 自行适配明暗）、
  **OpenCode**（主题是内置名，名表无法在本机核实，写错会静默不生效）。两者都会被明确列出，
  不会假装同步成功。
- 触发方式：`cachyos-agent-theme.path` 盯着配色文件，DMS 每次重写它就同步一次；安装时也会
  先同步一次。装好可用 `systemctl --user status cachyos-agent-theme.path` 查看。

**为什么不做完整配色主题**：Claude Code 支持自定义主题文件，但它的 schema 无法在本机可靠
核实（发行的是打包过的二进制，从中提取只会拿到 minified JS 的噪声）。本项目宁可少做，
也不写一份"看起来对、实际不生效"的主题文件——这正是审核阶段反复出现的问题类型。
同步做两件事：把 DMS 的 Material 3 调色板渲染成 **Claude Code 自定义主题**
（`~/.claude/themes/cachyos.json`，键集取自 Omarchy 的 `claude.json.tpl`）与 **Hermes skin**
（`~/.hermes/skins/cachyos.yaml`，装了 Hermes 才写），再把 `settings.json` 的 `theme` 指向它。
渲染与校验都在 `assets/lib/agent_theme.py`：校验不过就完全不写、并且不改 `settings.json`——
宁可不换主题，也不能让 agent 去读一个它认不出的文件。

想补的话，只需要在 `bin/cachyos-agent-theme-sync` 的取值表里加一行。

#### 新增一个 agent

旗标集中在一处：`assets/lib/agent.sh`。加一个 agent 需要同时改三处——该文件的
`cachyos_agent_supported`/`cachyos_agent_name`/`cachyos_agent_command`
（必要时还有 `cachyos_agent_skill_relpaths`）、`packages.sh` 里的包、以及
`tests/agent-test.sh` 的断言。

技能会链到**已存在**的 harness 目录（不替用户凭空创建目录）。但全新机器上 `.claude`/`.codex` 往往还不存在
（CLI 装了、用户还没跑过），于是安装器与首次登录初始化都会带 `--create-supported`：只为**目录位置确定
且该 CLI 已安装**的 agent（claude/codex）建目录再链接；opencode 的 `.agents/skills` 是"尽力而为"位置，
不凭空创建。

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
| 接通电源 | 20 分钟 | 20 分钟 | 60 分钟 |
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
3. 等待首次登录的 Firefox、Code、Wine 与 agent 技能初始化完成。
4. 在本项目目录执行：

```bash
bash tests/run-all.sh
./verify.sh
dms doctor
cachyos-lock-doctor
cachyos-agent --list        # 确认三个 agent 的安装状态
```

`tests/run-all.sh` 跑 `tests/` 下所有 `*-test.sh`，都是纯函数与 stub 测试，不需要桌面环境、
不需要先安装，也不会有桌面副作用（不会弹通知）：

- `tests/agent-test.sh` —— agent 表、argv 逐字保真、以及 launcher 与选择器的端到端往返。
- `tests/crash-test.sh` —— 崩溃字段解析（含缺失字段的对齐）与静音名单的名字截断。
- `tests/usage-test.sh` —— 用量采集：同日多条用量必须累加、缓存与全量结果一致、
  缓存版本失配要作废、两种 input 语义下的计费。
- `tests/dms-plugin-test.sh` —— 状态栏接线：只增不覆盖、幂等、尊重用户关掉的插件开关。
- `tests/dsh-usage-test.sh` —— DSH 采集器：v4/v0 两种事件格式、token 语义（input 不含缓存读、
  reasoning 不重复计）、只认 `source.kind == "user"` 的提示，以及**命中缓存与全量重扫一致**
  （包含"只有会话元数据、没有任何用量"的文件——这里曾经丢过会话数）。
- `tests/fresh-install-test.sh` —— **全新安装彩排**：把 `install.sh` 真跑一遍（临时 HOME + 假系统根），
  然后逐项断言 AI 系统是否完整（命令、资产、单元、插件、状态栏、niri 接线、技能链接）。这才是
  "任何人跑一遍就能用"的证据，`--dry-run` 给不了。
- `tests/agent-theme-test.sh` —— 主题同步生成 Claude 自定义主题与 Hermes skin，并校验格式与幂等。
- `tests/voxtype-test.sh` —— 听写状态机、未安装时的提示、快捷键文件的写入与卸载、配置备份。
- `tests/hardware-test.sh` —— CPU/GPU 检测与包选择。

插件自身的纯逻辑另有独立测试（在插件目录里）：

```bash
node --test assets/dms-plugins/CachyosAgents/tests/usage.test.cjs
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

## 与 Omarchy 的关系

AI Agent 这一层是**借鉴 [Omarchy](https://omarchy.org/) 的设计**做的。Omarchy 是 DHH 主导
的 Arch + Hyprland 发行版，它把 AI 编程 agent 当作一等公民集成；本项目在
**CachyOS + Niri + DMS** 上重新实现了同样的思路，并按本项目的约定改写。

### 直接借鉴的做法

| Omarchy 的做法 | 本项目的实现 | 为什么照搬 |
| --- | --- | --- |
| `bin/omarchy-agent` 用一张 `case` 表统一各 agent 的"无人值守"旗标 | `assets/lib/agent.sh` 的 `cachyos_agent_command` | 每个 agent 的旗标都不同（`--auto` / `--permission-mode auto` / `--approve-for-me`…），散落在快捷键里必然漂移。本项目把它抽成**纯函数库**，因此可以单测 |
| 固定 app-id，让所有 agent 窗口共用一类 | kitty `--class cachyos-agent` | 一条窗口规则或主题即可覆盖全部 agent 窗口 |
| prompt 单独成一条命令（裸 prompt 会遮蔽子命令） | `cachyos-agent-prompt` | 上游注释里写明了这个理由 |
| prompt 前放 `--`，避免以横线开头的内容被当成选项 | 三个 agent 全部处理 | 上游为 `cursor-agent` 的子命令歧义专门解释过 |
| 从 `$HOME` 启动时切到工作目录 | 仅在 `~/Work` 已存在时才切 | agent 不记忆 `$HOME` 的信任，否则每次都要重新确认 |
| 用固定 MESSAGE_ID 订阅 systemd-coredump | `bin/cachyos-crash-watch` | 结构化字段比核心文件名信息更多 |
| 崩溃记录先写、通知后发 | 同 | 通知可能丢（无 D-Bus、勿扰、通知服务刚死），记录是诊断入口的唯一依赖 |
| 崩溃详情以独立 argv 传参，绝不拼命令字符串 | 同 | 进程名是攻击者可控的 |
| 崩溃去重 + 按程序静音 | 同，另加"每程序最多一条待处理通知" | 崩溃循环会反复转储 |
| 诊断方法只写一份（skill），prompt 里只放事实 | `assets/agent-skills/diagnose-crash/` | 换任何 agent 都适用，方法也只维护一份 |
| 把系统知识做成技能并软链给各 harness | `cachyos-agent-skills` + `cachyos` 技能 | 让 agent 知道哪些配置受托管、改前先 `protect` |
| 在脚注里写清"为什么"与被否决的替代方案 | 本项目沿用同一风格 | 这是 Omarchy 最值得学的一点 |

### 没有照搬的部分

| Omarchy 的做法 | 本项目的选择 | 原因 |
| --- | --- | --- |
| `pacman` pre-transaction guard + `omarchy update` 更新管线 | 用 CachyOS 自己的 `pacman -Syu` / `cachyos-system-update` | 与 CachyOS 现有机制直接冲突，且会接管不属于本项目的更新路径 |
| 每用户迁移系统（数百个时间戳脚本） | `cachyos-config update` + manifest | 本项目规模不需要那套机器 |
| 470 个命令的 CLI 路由器（元数据头 + 最长前缀匹配） | 显式 `cachyos-*` 命令 + `verify.sh` 遍历 | 48 个命令用不上路由层 |
| mise stub 按需安装 agent | 用 pacman / AUR 安装 | 不引入第二套包管理器 |
| `omarchy-shell` 的 QML 插件 | DMS 插件（`plugin.json`） | 宿主不同，插件 API 完全不同 |
| `omarchy-theme-set-hermes` | `cachyos-agent-theme-sync` 的 Hermes 分支 | skin 格式相同（`name`/`description`/`colors` 44 键），配色来自 DMS 而不是静态主题 |
| `omarchy-toggle-crash-capture` | `cachyos-toggle-crash-capture` | 同样用"标记文件 + 单元条件"实现跨登录关闭 |
| 用 `--exec` 绕开"shell 不回发 ActionInvoked" | 直接用 `notify-send -A -w` | 在本项目实测 DMS（quickshell）**会**回发 `ActionInvoked`，不需要绕 |

### 已知限制

- 崩溃监听只在服务运行期间生效：服务重启（例如更新）窗口内的崩溃不会被补报——
  `journalctl -f -n 0` 有意不重播历史。
- 诊断会话被刻意设置为**不随服务重启被 SIGTERM**（`KillMode=process`：systemd 只杀主进程，
  同 cgroup 里的 kitty/agent 继续跑）。代价是重启 watcher 时会短暂留下一个空闲的 `journalctl`
  进程，它在下次有匹配输出时因 SIGPIPE 自行退出。
- 选择器需要终端或 Kitty；两者都没有时只能用 `cachyos-default-agent <agent>` 直接指定。

## 官方 Niri 与修改版功能差异

本项目只安装官方 Niri，不安装第三方 fork，因此以下功能是中性替代，不是完全复刻：

| 目标功能 | 当前实现 | 差异 |
| --- | --- | --- |
| 概览 | 官方 Niri Overview + DMS Overlay | 不提供 fork 的私有网格布局和交互 |
| 暗色模糊概览背景 | DMS Overview 模糊 + Niri 深色 backdrop | 常驻模糊壁纸层保持关闭 |
| 放大镜 | `Super+Alt+F7` 手动启动 Woomer | 不支持鼠标快速晃动自动放大 |
| 热角 | Waycorner | 独立工具实现，不依赖修改版 Niri |
| 窗口跟随/快速聚焦 | nirius | 独立辅助服务实现 |
| 侧边栏 | niri-sidebar | 独立辅助服务实现 |

DMS Overlay 不会为官方 Niri 增加 fork 的私有网格实现。鼠标晃动放大也未实现，当前提供的是
明确快捷键触发的 Woomer。

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
