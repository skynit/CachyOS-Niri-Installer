# 安装

本页覆盖：装之前的准备、CachyOS 基础系统的下载与安装、双系统、以及本项目的 `install.sh`。
装完后的验收见 [verification.md](verification.md)；桌面与 AI 层的具体功能见
[desktop.md](desktop.md) 与 [ai.md](ai.md)。

## 使用前提

- 已通过 CachyOS 官方安装器完成基础系统安装。
- 使用可执行 `sudo` 的普通用户运行，不能直接使用 root。
- 网络连接正常。
- 当前仅支持 `x86_64`。
- 自动检测 Intel/AMD CPU 与 Intel/AMD/NVIDIA 显卡，并选择对应的微码、Mesa/Vulkan 或 NVIDIA 用户态驱动包。
- 混合显卡会合并所需驱动包；无法识别的设备会显示警告，而不会错误套用其他厂商驱动。

不要在 CachyOS Live ISO 中运行。

## 下载并安装 CachyOS

本项目面向**已经安装好 CachyOS** 的系统，所以第一步是先装基础系统。

**1. 下载镜像**

打开官网 <https://cachyos.org/>，进入下载页 <https://cachyos.org/download>，选择 Desktop 版
ISO（文件名形如 `cachyos-desktop-linux-<日期>.iso`，约 3～4 GiB）。下载页会给出各镜像站的直链，
以及对应的 `.sha256` 校验文件与 `.sig` 签名；也可以直接用下面的固定版本链接。

**2. 校验下载结果**

镜像站偶尔同步不全，装之前务必校验：

```bash
# 与下载页给的 .sha256 文件放在同一目录
sha256sum --check cachyos-desktop-linux-<日期>.iso.sha256
```

想用签名验证（更严格）：

```bash
gpg --recv-keys '882D CFE4 8E20 51D4 8E25 62AB F3B6 0748 8DB3 5A47'
gpg --verify cachyos-desktop-linux-<日期>.iso.sig cachyos-desktop-linux-<日期>.iso
```

**3. 写入安装介质**

用 Ventoy 或 `dd` 写入 U 盘，做法见下一节「新电脑复刻与 Windows 双系统」。

**4. 安装 CachyOS**

CachyOS 安装器提供两种方式：图形化（Calamares）和命令行。**桌面环境任选**——选 **Niri** 最省事，
选 KDE/GNOME 等也可以，本项目会把桌面统一配置成 Niri + DMS。安装完进入系统后，再运行本项目的
`install.sh` 补齐桌面配置与 AI 层。

### 可复现的固定版本

下面这个版本是经过完整验证的固定版本，便于复刻完全相同的环境（仓库不保存镜像文件）：

```bash
curl --fail --location --continue-at - \
  --output cachyos-desktop-linux-260809.iso \
  https://cdn77.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso
```

```bash
echo '959f6577f45e25ee9fd8c220fd221b08e4ea79412c7315c0f922dd6d86d5e33c  cachyos-desktop-linux-260809.iso' \
  | sha256sum --check
```

- SHA-256：`959f6577f45e25ee9fd8c220fd221b08e4ea79412c7315c0f922dd6d86d5e33c`
- 官方校验文件：<https://cdn77.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso.sha256>
- 官方签名：<https://cdn77.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso.sig>
- 签名密钥指纹：`882D CFE4 8E20 51D4 8E25 62AB F3B6 0748 8DB3 5A47`

### 官方资源

| 资源 | 地址 |
| --- | --- |
| 官网 | <https://cachyos.org/> |
| 下载页 | <https://cachyos.org/download> |
| Wiki（文档） | <https://wiki.cachyos.org/> |
| 论坛 | <https://discuss.cachyos.org/> |
| 软件包查询 | <https://packages.cachyos.org/> |
| GitHub | <https://github.com/cachyos> |

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
- 上一节给出的 CachyOS 安装镜像。
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
Manager。双系统启动确认正常后，再运行本项目的安装器。

Windows 更新可能改变 EFI 启动顺序。条件允许时，让 Windows 与 CachyOS 分别使用独立
硬盘和各自的 EFI/启动分区会更稳妥。分区和引导器要求应以当前
[CachyOS 官方安装文档](https://wiki.cachyos.org/installation/installation_on_root/)与
[引导器说明](https://wiki.cachyos.org/installation/boot_managers/)为准。

## 运行安装器

### 先看计划，再执行

```bash
./install.sh --dry-run     # 只打印将要执行的命令，不修改系统
./install.sh               # 执行安装
```

`--dry-run` 会完整走一遍检查与计划展示，但所有写操作只打印 `[DRY-RUN]` 行，适合先核对
目标磁盘、硬件栈、终端和 DMS 版本。确认无误后去掉 `--dry-run` 再跑一次。

### 常用选项

| 选项 | 作用 |
| --- | --- |
| `--terminal NAME` | 默认终端：`kitty`（默认）、`ghostty` 或 `alacritty`；会传给 DMS 安装器。注意本项目固定的快捷键仍直接启动 Kitty |
| `--dms-version TAG` | 使用指定 DMS 版本（默认钉住 `v1.6.2`）；非钉住版本只按 GitHub Release 的校验和验证 |
| `--skip-update` | 跳过开头的完整 `pacman -Syu`（系统已更新时用） |
| `--skip-hardware` | 跳过自动检测的硬件包与硬件相关服务 |
| `--dry-run` | 只打印写操作，不执行 |
| `-y`, `--yes` | 跳过安装器自身的确认提示（不是 pacman 的） |
| `-h`, `--help` | 显示帮助 |

### 安装过程

安装器会输出一个**零依赖的终端界面**（`assets/lib/tui.sh`）：横幅、六段阶段标题、每组应用的
进度条、下载时的转圈，以及收尾的汇总框。一旦输出不是终端（管道、`> log`、CI），它会自动退化成
纯文本，并保留 `[INFO]`/`[WARN]`/`[DRY-RUN]` 标记——`verify.sh` 与 `tests/` 都依赖这些日志。
想显式关闭颜色：`NO_COLOR=1`、`TERM=dumb`，或 `CACHYOS_TUI=plain`。它不依赖 `gum`/`dialog` 之类
外部命令：安装发生在刚装好的 CachyOS 上，任何额外依赖都可能是“还没装上”的状态。

默认安装过程会：

- 完整执行一次 `pacman -Syu`，除非使用 `--skip-update`。
- 根据 CPU/GPU 自动安装微码、Mesa/Vulkan 或 NVIDIA 驱动，以及 PipeWire、蓝牙和电源管理组件。
- 安装官方 Niri、DMS、Quickshell、Xwayland Satellite 和 Kitty。
- 下载并校验固定版本的 DMS 官方 `dankinstall` v1.6.2（随包插件的最低要求：Focus 需要 ≥1.6.2，
  LocalTranslate/LocalLyrics 需要 ≥1.6.1）。
- 安装 DankSearch、DankCalendar，以及 DMS 官方 Niri/Kitty 配置。
- 部署随包的 7 个 DMS 插件并安装其 Go helper；Top 是 daemon-only 面板，装好后用
  `Super+BackSpace` 呼出，不向状态栏添加控件；补装 `dgop`、`android-tools`、`scrcpy`、`avahi`，
  以及电脑 RDP 与密码保存需要的 `freerdp`、`libsecret`、`gnome-keyring`，
  `avahi` 已安装时启用 `avahi-daemon.service`。
- 安装全部日常应用、桌面增强和系统维护工具（清单见 [apps.md](apps.md)）。
- 安装并启用 Ly，将其他已启用的显示管理器停用。
- 将 Fish 设置为登录 Shell，并配置 Starship、eza、zoxide 和 Fastfetch。
- 配置 Fcitx5、RIME、雾凇拼音、Waypaper、awww、Satty、录屏及双 Waybar。
- 配置 DMS 主题、光标、模糊、锁屏、电源策略、指纹和安全密钥辅助工具。
- 通过 CachyOS 仓库安装 Codex CLI 和 Claude Code，并通过 AUR 安装 `codex-desktop-git`。
- 生成 CC Switch 与 Codex Desktop 的配置镜像，镜像里的敏感键会被过滤。注意：同步会**改写 Codex
  自己的 `~/.codex/auth.json`**（用于切换 provider），并在改动前把原文件备份到
  `~/.local/state/cachyos-ai-config/`（权限 0700）。详见 [ai.md](ai.md#配置镜像可选)。
- 部署稳定的 Niri 主配置、快捷键和项目扩展；DMS 根据受管理的设置生成配色、布局、光标和模糊配置。
- 禁止 Niri 接管电源键（避免笔记本上的挂起循环）。
- 自动清理受管理位置中的旧品牌包、路径和 Niri 配置残留。
- 不自动重启。

安装完成后按 [verification.md](verification.md) 做重启、重新登录与验收。

### Go helper：为什么安装机不需要 Go

AI 集成的设置/用量 JSON 辅助程序（2 个），以及 5 个 DMS 插件 helper，都由 `assets/go-bin/`
中随仓库分发的 Linux x86-64 纯 Go 可执行文件提供，安装机不需要 Go 工具链。修改对应 Go 源码后，
在构建机运行：

```bash
bash tools/build-go-helpers.sh
```

构建固定为 `GOOS=linux GOARCH=amd64 GOAMD64=v1`、`CGO_ENABLED=0`，不会随构建机的指令集级别变化；
一次构建 7 个 helper（AI 集成的 2 个 + 插件的 5 个）。现有 Claude、Codex、DSH 用量采集器仍使用
Python 3，其他系统维护命令仍可能依赖 `jq`。

只在**已安装本桌面**的机器上更新辅助程序，运行：

```bash
bash tools/install-go-helpers.sh
```

它把 AI 设置/用量命令装进 `/usr/local/bin/`，把插件 helper 装进对应插件目录（0755）；脚本先备份
旧的系统命令到 `~/.local/state/cachyos-desktop/backups/`，不运行整套桌面安装器。

插件文本资产（QML/JS/`plugin.json`/README、`LocalTranslate` 的 `data/` 与插件测试）登记在
`assets/config-manifest.tsv` 里，可用 `cachyos-config status` / `cachyos-config update` 管理；
helper 二进制**刻意不进清单**——`update` 固定用 0644 安装，会丢掉可执行位。详见
[dms-plugins.md](dms-plugins.md)。
