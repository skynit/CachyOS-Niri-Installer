# 随包 DMS 插件

DMS 插件放在 `~/.config/DankMaterialShell/plugins/<目录>/`，契约是各自目录里的 `plugin.json`。
安装器随包 7 个插件（真源 <https://github.com/skynit/dms-plugins>，副本在 `assets/dms-plugins/`，
全新机器离线也能复刻）。

## 随包插件

| 插件 | 功能 | 安装目录 | helper（装在插件目录内） | 运行依赖 |
| --- | --- | --- | --- | --- |
| **AI 集成** `cachyosAgents` | 状态栏 AI 设置与用量面板（见 [ai.md](ai.md) 与 [usage.md](usage.md)） | `plugins/CachyosAgents` | `ai-settings`、`usage-json` | `python3`（用量采集器）与本机用量采集命令 |
| **本机状态** `localStatus` | IP、网络链路、CPU、负载、内存、Swap、磁盘与时间 | `plugins/LocalStatus` | 无 | `dgop`、`ip` |
| **离线翻译** `localTranslate` | 内置 CC-CEDICT，中英词条与短语双向离线查询 | `plugins/localTranslate` | `translate-lookup` | 内置 `data/dictionary.sqlite3` |
| **本地歌词** `localLyrics` | 跟随播放器进度显示音频内嵌歌词，完全离线 | `plugins/localLyrics` | `lyrics-helper` | `ffprobe`（ffmpeg） |
| **连接** `phoneConnect` | 手机无线配对、投屏与文件传输；电脑 RDP 远程桌面、自动保存和回填密码 | `plugins/PhoneConnect` | `phone-connect` | 手机：`adb`（android-tools）、`scrcpy`、`avahi-browse` + `avahi-daemon`；电脑：`xfreerdp3`（freerdp）、`secret-tool`（libsecret）和 GNOME Keyring |
| **专注** `focus` | 保持当前 niri 窗口，隔离其他应用新窗口并暂停 DMS 通知弹窗 | `plugins/Focus` | `focus-helper` | `niri` 26.04、DMS 1.6.2 |
| **Top 系统面板** `top` | 仿 ftop 的悬浮系统监视：每核占用/频率、内存、GPU、温度、进程列表；右键进程可结束整组进程；`Super+BackSpace` 呼出，点击外部关闭，不占状态栏 | `plugins/Top` | `top-helper` | 无额外命令；DMS ≥1.6.1 |

每个插件的完整说明（功能、设置项、安装与测试命令）在插件目录自带的 README 里：

- [AI 集成](../assets/dms-plugins/CachyosAgents/README.md)
- [本机状态](../assets/dms-plugins/LocalStatus/README.md)
- [离线翻译](../assets/dms-plugins/LocalTranslate/README.md)
- [本地歌词](../assets/dms-plugins/LocalLyrics/README.md)
- [连接（手机与电脑）](../assets/dms-plugins/PhoneConnect/README.md)
- [专注](../assets/dms-plugins/Focus/README.md)
- [Top 系统面板](../assets/dms-plugins/Top/README.md)

这些插件的 `requires_dms` 最高到 `>=1.6.2`（Focus；LocalTranslate、LocalLyrics 为 `>=1.6.1`），
所以安装器把 DMS 钉在 **v1.6.2**；宿主版本低于插件要求时它不会加载。版本管理见
[maintenance.md](maintenance.md#dms-版本更新)。

## 部署与启用

安装器逐个复制插件文本资产（`*.qml`、`*.js`、`plugin.json`、`README.md`，
`LocalStatus/tests/status.test.cjs` 与 `CachyosAgents/tests/usage.test.cjs` 也随包），
LocalTranslate 额外复制 `data/`（词典与许可文件）；Top 额外复制 `components/` 自绘组件。
helper 由 `tools/install-go-helpers.sh` 装进对应插件目录（0755），QML 用 `Qt.resolvedUrl`
在插件目录里找同名可执行文件。

启用状态写进 `plugin_settings.json`，但**只在该插件 ID 还没有 `enabled` 字段时**写
`enabled=true`——用户以后在 DMS 设置里手动关掉，重装不会又给打开。

## 状态栏接线

`assets/dms/add-dms-bar-widgets.jq` 只操作第一个栏（`barConfigs[0]`），把 `localTranslate`、
`phoneConnect`、`focus`、`localLyrics` 追加到左侧，把 `cachyosAgents`、`localStatus` 追加到右侧；
已有控件保持原位，只增不覆盖、幂等。**没有现成的 `barConfigs` 时它什么都不做**——DMS 的默认栏
只在键不存在时生效，凭空造一个只含插件控件的栏会把启动器、时钟、系统托盘等默认控件整个换掉。
因此全新安装不会自动出现这些控件（此时安装器会打出 `[WARN]`）：请到 **DMS 设置 → 状态栏** 里
自行添加，或先自定义状态栏后再重跑安装器。

Top 是 **daemon-only** 面板，不参与状态栏接线：装好后用 `Super+BackSpace`（配置里写作 `Mod+BackSpace`）呼出。

## 单独更新

- **helper 二进制**：`bash tools/install-go-helpers.sh`（备份旧系统命令到
  `~/.local/state/cachyos-desktop/backups/`，不跑整套安装器）。
- **插件文本资产**：已登记在 `assets/config-manifest.tsv`，用 `cachyos-config status` /
  `cachyos-config update` 管理（与其他受管配置一样可 `protect`）；上游 dms-plugins 更新后，
  先把对应目录同步进 `assets/dms-plugins/`，再重跑安装器或 `cachyos-config update`。
- **helper 刻意不进 manifest**：`cachyos-config update` 固定以 0644 安装，会丢掉可执行位。
- **构建**：`bash tools/build-go-helpers.sh` 一次构建 7 个 helper（AI 集成的 2 个 + 插件的 5 个），
  固定 `GOOS=linux GOARCH=amd64 GOAMD64=v1 CGO_ENABLED=0`；插件的 Go 源码随
  `assets/dms-plugins/<插件目录>/` 分发，不另存一份。

## 测试

安装器会为两个带纯逻辑测试的插件复制测试文件；插件源码里也有各自的测试：

```bash
node --test assets/dms-plugins/CachyosAgents/tests/usage.test.cjs
node --test assets/dms-plugins/LocalStatus/tests/status.test.cjs
(cd assets/dms-plugins/LocalTranslate && CGO_ENABLED=0 go test . -count=1)
(cd assets/dms-plugins/LocalLyrics && CGO_ENABLED=0 go test . -count=1)   # 需要 ffprobe（ffmpeg）
(cd assets/dms-plugins/PhoneConnect && CGO_ENABLED=0 go test . -count=1)
(cd assets/dms-plugins/Focus && CGO_ENABLED=0 go test . -count=1)
(cd assets/dms-plugins/Top/helper && CGO_ENABLED=0 go test . -count=1)
```

安装器层面的插件契约（7 个 `plugin.json`、随包资产、manifest 覆盖、启用规则、状态栏落位）
由 `tests/dms-plugin-test.sh` 覆盖；`verify.sh` 还会检查插件目录、helper 是否在位、是否启用与
是否接进状态栏。见 [verification.md](verification.md)。

## 许可

LocalTranslate 内置的词典来自 CC-CEDICT，按 **CC BY-SA 4.0** 分发；许可全文与 NOTICE 在插件目录的
`data/` 下（`CC-BY-SA-4.0.txt`、`NOTICE.md`）。
