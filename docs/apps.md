# 默认应用与包清单

`packages.sh` 是**应用清单**的唯一来源（DMS 的功能包与硬件相关包另有出处，见文末）。目前包含
**104 个去重后的仓库包**和 **14 个 AUR 包**，安装时不需要额外功能开关。数字可用以下命令复核：

```bash
source packages.sh
printf '%s\n' "${DAILY_APP_PACKAGES[@]}" "${CHINESE_PACKAGES[@]}" "${OFFICE_PACKAGES[@]}" \
  "${DEVELOPMENT_PACKAGES[@]}" "${MEDIA_PACKAGES[@]}" "${VIRTUALIZATION_PACKAGES[@]}" \
  "${GAMING_PACKAGES[@]}" "${SYSTEM_TOOL_PACKAGES[@]}" | wc -l   # 104
printf '%s\n' "${AUR_PACKAGES[@]}" | wc -l                       # 14
```

## 仓库包（按分组）

| 分组 | 数量 | 内容 |
| --- | ---: | --- |
| 日常 | 51 | Firefox、Thunar、Nautilus、File Roller、Transmission、Flatseal、Mission Center、GParted、LACT、EasyEffects、MPV、imv、LocalSend、Yazi、剪贴板、截图和录屏工具、`ddcutil`、`wlsunset`、Waybar、`awww` 等 |
| 中文 | 8 | Fcitx5、RIME、雾凇拼音、配置工具及 Noto 中文/Emoji 字体 |
| 办公 | 3 | LibreOffice、KeePassXC、GNOME Calendar |
| 开发 | 13 | base-devel、Git、Neovim、Code、OpenCode、Codex CLI、Claude Code、ShellCheck、Fish、Starship、eza、zoxide、Fastfetch |
| 影音 | 5 | OBS Studio、GIMP、Inkscape、Audacity、Kdenlive |
| 虚拟化 | 4 | virt-manager、QEMU、swtpm、virt-viewer，并启用 `libvirtd` |
| 游戏 | 5 | Steam、Lutris、MangoHud、Gamescope、Wine |
| 系统 | 15 | Snapper、Btrfs Assistant、Reflector、Flatpak、Paru、Yay、fzf、Ly、fprintd、pam-u2f、libfido2 等 |

完整列表直接读 [`packages.sh`](../packages.sh) 的数组；分组名与安装计划里显示的
`daily、Chinese、office、development、media、VM、gaming、tools` 对应。

## AUR 包

QQ、微信、Upscaler、CC Switch、ProtonPlus、Gearlever、Codex Desktop、Clash Verge Rev、Obsidian、
雾凇拼音、Waypaper、`nirius`、Waycorner 和 Woomer。

`niri-sidebar` 不走 AUR：安装器下载固定版本 `v0.4.0` 并校验 SHA-256 后安装。

## DMS 功能包

DMS 本身及其功能包不写在 `packages.sh` 里，而由 `install.sh` 的 `DMS_FEATURE_PACKAGES`
列出，并以“可用则装、不可用则跳过”的方式安装：

```text
networkmanager  cava  i2c-tools  matugen  qt6-multimedia  wtype  cups-pk-helper
dgop  android-tools  scrcpy  avahi  freerdp  libsecret  gnome-keyring
```

其中 `dgop`、`android-tools`、`scrcpy`、`avahi` 是随包 DMS 插件的运行依赖（本机状态、
手机连接）；`freerdp` 提供电脑 RDP，`libsecret` 与 `gnome-keyring` 提供密码保存。
`avahi` 已安装时会启用 `avahi-daemon.service`。详见
[dms-plugins.md](dms-plugins.md)。

## 硬件相关包

`hardware.sh` 负责 CPU/GPU 检测与包选择，安装器与 `verify.sh` 共用同一份逻辑：

- 公共必装：`linux-firmware`、`mesa`、`sof-firmware`、PipeWire 栈、`bluez`、`bluez-utils`。
- 公共可选：`vulkan-tools`、`fwupd`、`bolt`、`v4l-utils`、`usbutils`、`pciutils`。
- CPU 微码：Intel 装 `intel-ucode`，AMD 装 `amd-ucode`。
- GPU：按厂商合并 Mesa/Vulkan（Intel/AMD）或 NVIDIA 用户态驱动；混合显卡会合并所需包，
  无法识别的设备只装公共包并给出提示，不会错误套用其他厂商驱动。

用 `--skip-hardware` 可以跳过这一整段（包括硬件相关服务）。装完后 `verify.sh` 会把实际
驱动与预期做对比，见 [verification.md](verification.md)。

## 应用之外

默认安装还会部署：

- 桌面配置与快捷键（[desktop.md](desktop.md)、[keybindings.md](keybindings.md)）。
- 74 个本项目的命令与 7 个 Go helper（[architecture.md](architecture.md)）。
- 7 个随包 DMS 插件（[dms-plugins.md](dms-plugins.md)）。
- AI 层命令、技能与用户单元（[ai.md](ai.md)）。
- 首次登录初始化的 Firefox 主题、Code 主题、Wine 前缀（[desktop.md](desktop.md#首次登录初始化)）。
