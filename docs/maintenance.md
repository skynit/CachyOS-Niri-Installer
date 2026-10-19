# 配置更新、卸载与系统维护

本页覆盖长期使用中的四件事：受管配置怎么更新与保护、软件卸载与 HOME 残留、系统维护命令、
以及 DMS 版本如何升级。安装选项见 [install.md](install.md)，装后验收见 [verification.md](verification.md)。

## 配置更新、保护与迁移

安装器将受管配置副本保存到 `/usr/local/share/cachyos-desktop`，清单是
`config-manifest.tsv`。以后可使用：

```bash
cachyos-config status                 # 查看 current/modified/missing/protected
cachyos-config update                 # 更新未保护的配置
cachyos-config migrate                # 先备份现有配置，再更新
cachyos-config protect ~/.config/...  # 保护自定义文件，阻止自动覆盖
cachyos-config unprotect ~/.config/... # 取消保护
```

`status` 的四种状态：

| 状态 | 含义 |
| --- | --- |
| `current` | 与随包版本一致 |
| `modified` | 用户改过；`update` 会覆盖它（除非已 protect） |
| `missing` | 目标文件不存在；`update` 会补装 |
| `protected` | 在 `~/.local/state/cachyos-desktop/protected-configs.txt` 里，`update` 跳过 |

迁移备份存放在 `~/.local/state/cachyos-desktop/migration-*`。

清单覆盖：Niri 主配置/扩展、安装器写入的 `dms/binds.kdl`、Waybar、Kitty、Fcitx5、Satty、Thunar、
Waypaper、Waycorner、6 个 systemd 用户单元，以及 7 个 DMS 插件的文本资产（QML/JS/
`plugin.json`/README/测试，LocalTranslate 的 `data/`）。**不在清单里**的：Go helper 二进制
（`cachyos-config update` 固定 0644 会丢可执行位）、`ask-actions.conf`、`ai-settings.conf`、
DMS 自己生成的 `~/.config/niri/dms/{colors,layout,alttab,outputs,cursor,wpblur}.kdl`、默认 agent
文件——这些是用户或 DMS 的状态，重装不覆盖。

### 用户单元

| 单元 | 作用 |
| --- | --- |
| `cachyos-crash-watch.service` | 崩溃监听（[crash-oom.md](crash-oom.md)） |
| `cachyos-oom-watch.service` | OOM 与内存压力监听（[crash-oom.md](crash-oom.md)） |
| `cachyos-agent-theme.path` | 盯 DMS 配色文件，变化时触发同步 |
| `cachyos-agent-theme.service` | 执行主题同步 |
| `cachyos-agent-usage.timer` / `.service` | 登录后 2 分钟、之后每 15 分钟重算用量（[usage.md](usage.md)） |

`cachyos-crash-watch`、`cachyos-oom-watch` 与 `dms.service` 都绑定到 `niri.service`；DMS 只在
Niri 会话中启动。对应开关用 `cachyos-toggle-crash-capture` / `cachyos-toggle-oom-capture`。

### 更新本仓库后的推荐流程

```bash
git pull
./install.sh --dry-run     # 先看这次计划
./install.sh               # 重跑安装器（不覆盖你的 ask-actions.conf / ai-settings.conf）
cachyos-config status      # 确认受管配置状态
```

只想刷新配置与插件文本资产、不重装软件包时，用 `cachyos-config update`；只想更新 Go helper 时用
`bash tools/install-go-helpers.sh`。

## 软件卸载与 HOME 残留

需要跟踪某个软件在 HOME 中创建的文件时，先通过 `strace` 启动一次：

```bash
cachyos-track-app PACKAGE [COMMAND ...]
```

如果省略命令，会自动选择该包安装的第一个可执行文件。正常关闭应用后，路径清单会写到
`~/.local/state/cachyos-removals/<package>.paths`。再运行：

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

## DMS 版本更新

默认版本固定是为了让下载内容可复核。当前 `PINNED_DMS_VERSION` 是 **v1.6.2**——随包插件的下限
（Focus 需要 ≥1.6.2，LocalTranslate/LocalLyrics 需要 ≥1.6.1；见
[dms-plugins.md](dms-plugins.md)）。升级 DMS 安装器时，必须同时更新
`install.sh` 中的：

```text
PINNED_DMS_VERSION
PINNED_DMS_SHA256_AMD64
```

SHA-256 必须来自对应 GitHub Release 的 `dankinstall-amd64.gz.sha256`，并在更新后
重新执行本目录的语法、结构化配置和 dry-run 检查：

```bash
bash -n install.sh
./install.sh --dry-run
bash tests/run-all.sh
```

临时试验其他版本可以用 `./install.sh --dms-version vX.Y.Z`：非钉住版本只按 GitHub Release
自带的校验和验证，安装器会打印警告；低于插件 `requires_dms` 的版本会让对应插件不加载。
