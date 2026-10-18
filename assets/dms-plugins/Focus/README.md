# 专注插件

状态栏左键切换，右键查看状态。开始专注时记录当前 niri 窗口，其他应用随后打开的新窗口转入 `DMS Focus Inbox` 工作区且不自动获焦；辅助程序监听焦点事件，若焦点转移则请求切回原窗口。DMS 通知进入免打扰并关闭当前通知弹窗。退出时恢复原始 niri 配置和此前的免打扰状态。当前应用自己打开的对话框不受新窗口隔离规则影响，但焦点仍会切回原窗口。

插件不修改 `~/.config/niri/config.kdl`：辅助程序在 `XDG_RUNTIME_DIR/dms-focus/` 写临时配置，并调用 niri 的运行时配置加载接口。重启会话后会从原配置启动；DMS 或插件停止运行时，监听器也会尝试恢复原配置。退出专注不会自动搬回期间转入 `DMS Focus Inbox` 的窗口，可从工作区切换器访问。焦点监听是事后纠正，可能短暂看到窗口切换；非 DMS 的 layer-shell 弹窗和应用自行绘制的弹窗不受隔离规则保证。DMS 通知规则允许的紧急通知也可能穿过免打扰。niri 26.04 没有供插件直接拒绝所有这些请求的接口。

运行依赖：DMS 1.6.2、niri 26.04 和插件附带的 `focus-helper`。辅助程序使用 Go 标准库，通过参数数组调用本地 `niri`、`dms`，不执行 shell；目标机器不需要 Go 或 Python。Go 仅在构建时使用。

## 构建与验证

在当前插件目录运行：

```bash
bash ./build.sh
go test -count=1 .
go version -m ./focus-helper
```

构建脚本使用 `CGO_ENABLED=0`，即不链接 C 运行库；x86-64 产物固定为基础指令集 `GOAMD64=v1`，不受外部 `GOAMD64=v4` 影响。也可手动构建：

```bash
CGO_ENABLED=0 GOAMD64=v1 go build -trimpath -o focus-helper .
```

其他架构按实际 `GOARCH` 构建，例如 ARM64：

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o focus-helper .
```

## 本机安装

先确认当前专注模式已关闭，再构建并将 `plugin.json`、`Focus.qml`、`focus-helper` 复制到 `~/.config/DankMaterialShell/plugins/Focus/`；其中 `focus-helper` 需要可执行权限。配置根目录可由 `XDG_CONFIG_HOME` 指定。首次安装运行 `dms ipc call plugin-scan scan`，在 DMS 设置里启用插件并放置到状态栏。更新已有安装使用 `dms ipc call plugin-scan rescan focus` 与 `dms ipc call plugins reload focus`。Go 版本替换完成后删除安装目录中的旧 `focus.py`。安装不会自动开启专注。

## 辅助程序命令

辅助程序是由 QML 界面启动的本地进程，负责状态文件、窗口管理命令和焦点监听。命令仍为 `status`、`enable`、`disable`、`toggle`、`preview`、`watch`：

- `status` 返回当前状态；原窗口关闭后会尝试退出专注。
- `enable`、`disable`、`toggle` 开启、关闭或切换专注。
- `preview` 仅生成并校验临时配置，不加载到当前会话，返回 `valid/config/app_id`。
- `watch` 监听 niri 焦点事件，正常运行和退出时不输出 JSON。

普通操作输出 JSON 字段 `active/state/reason/title`；失败时仍输出相同字段，`state` 为 `unreachable`，并以退出码 1 结束。`active` 表示会话状态文件是否仍存在，`reason` 包含失败原因。状态文件仍使用 `window_id/app_id/title/old_dnd/old_until/watch_pid`，记录原窗口、原通知状态及监听进程号。
