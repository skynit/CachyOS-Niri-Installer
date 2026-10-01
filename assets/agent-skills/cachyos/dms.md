# DankMaterialShell (DMS)

DMS 是这套桌面的外壳：面板、启动器、通知、剪贴板、锁屏、动态主题都由它提供，运行在
Quickshell 之上，并且只绑定到 Niri 用户会话（`~/.config/systemd/user/niri.service.wants/dms.service`）。

## IPC 是主要控制接口

```bash
dms ipc call <target> <method> [参数...]
```

常用 target（完整列表见 `dms ipc --help`）：

| target | 常用方法 | 用途 |
| --- | --- | --- |
| `settings` | `focusOrToggle`、`get`、`set`、`open`、`tabs` | 打开或操纵设置界面 |
| `spotlight` | `toggle`、`openQuery` | 应用启动器 |
| `clipboard` | `toggle` | 剪贴板历史 |
| `notepad` | `toggle`、`openFile` | 记事本 |
| `lock` | `lock` | 锁屏 |
| `powermenu` | `toggle` | 电源菜单 |
| `processlist` | `focusOrToggle` | 任务管理器 |
| `window-rules` | `toggle`、`getFocusedWindow` | 窗口规则工具 |
| `workspace-rename` | `open` | 重命名工作区 |
| `audio` | `increment`、`decrement`、`mute`、`micmute` | 音量 |
| `brightness` | `increment`、`decrement` | 内屏亮度 |
| `mpris` | `playPause`、`next`、`previous` | 媒体控制 |
| `wallpaper` | `set`、`next`、`get` | 壁纸 |
| `theme` | `dark`、`light`、`toggle`、`getMode` | 明暗模式 |
| `plugins` | `list`、`enable`、`disable`、`reload` | 插件开关 |
| `plugin-scan` | `rescan`、`reload`、`status` | 重新扫描插件目录 |
| `notifications` | `toggleDoNotDisturb`、`clearAll` | 通知 |
| `settings` / `widget` | `dump`、`list` | 调试 |

`dms ipc call plugins list` 可以离线列出已加载插件及其状态。

## 改设置

单键改动用项目提供的 helper，它是 jq 校验 + 原子写入 + 0600 权限：

```bash
cachyos-dms-setting <KEY> <JSON_VALUE>
cachyos-dms-setting showSeconds true
cachyos-dms-setting maxWidth 318
```

`~/.config/DankMaterialShell/settings.json` **不在托管清单里**——安装器只把自己那份
`assets/dms/desktop-settings.json` 用 `jq --slurp '.[0] * .[1]'` 合并进去，用户的键
不会丢。所以直接编辑它也是安全的，但改动前先备份。

## 插件

插件是 `~/.config/DankMaterialShell/plugins/<目录>/`，契约在 `plugin.json`：

```json
{
  "id": "localStatus",
  "name": "LocalStatus 本机状态",
  "type": "widget",
  "capabilities": ["dankbar-widget"],
  "component": "./LocalStatus.qml",
  "settings": "./LocalStatusSettings.qml",
  "requires_dms": ">=1.5.3",
  "permissions": ["settings_read", "settings_write", "process"]
}
```

新增或修改插件后让它生效：

```bash
dms ipc call plugin-scan rescan
dms ipc call plugins list        # 确认 [loaded]
```

**不要用 `dms plugins list` / `dms plugins install`**：它们会去上游 registry 拉网络数据，
在离线或网络受限时会长时间挂住。插件一律用文件部署。

## 锁屏与认证

```bash
cachyos-lock-doctor      # 检查 DMS 锁屏、PAM、指纹与安全密钥配置
dms auth resolve-lock --quiet
```

## 主题与动态配色

- 主题颜色由 **matugen** 依据当前壁纸生成，输出到 `~/.config/niri/dms/colors.kdl` 等文件。
- 换壁纸用 Waypaper（`Super+Alt+W` / `Super+Y`）；它会通知 DMS 重新生成配色。
- Firefox 与 VS Code 的主题分别由 `cachyos-firefox-setup`、`cachyos-code-theme` 链接到
  生成的配色。
- 明暗模式：`dms ipc call theme toggle`。

## 常见坑

- DMS 生成的文件（`~/.config/niri/dms/` 下的多数文件）不要手改，会被覆盖。
- 任何 `dms ipc call` 在 DMS 未运行时都会失败；先确认 `systemctl --user is-active dms.service`。
