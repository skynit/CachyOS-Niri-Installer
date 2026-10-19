# 安装后验收与测试

安装完成后（安装器不会自动重启）按以下顺序验收。验收覆盖的是“这台机器装对了没有”，
与模块文档里的功能说明互补：安装见 [install.md](install.md)，设计边界见 [design.md](design.md)。

## 手动验收

1. 重启，在 Ly 中选择 Niri 会话。
2. 至少退出并重新登录一次，使 Fish、Fcitx5、`libvirt` 和 `i2c` 组权限生效。
3. 等待首次登录的 Firefox、Code、Wine 与 agent 技能初始化完成（状态见
   `~/.local/state/cachyos-desktop/post-login.log`）。
4. 在本项目目录执行：

```bash
bash tests/run-all.sh
./verify.sh
dms doctor
cachyos-lock-doctor
cachyos-agent --list        # 确认四个 agent 的安装状态
```

`verify.sh` 以 `[PASS]`/`[WARN]`/`[FAIL]` 输出，最后打印通过/警告/失败计数；有失败时退出码非 0。
它检查：CachyOS 与硬件、包清单、Niri 配置的 include 与 `niri validate`、DMS 与 Niri 的绑定、
桌面组件与受管配置清单、Firefox 策略、首次登录标记、CC Switch 镜像、Codex Desktop 构建信息、
AI 命令与技能、6 个用户单元、7 个插件目录/helper/启用/状态栏落位、DMS 版本下限、听写组件与
锁屏状态。`adb`、`scrcpy`、`avahi-browse`、`dgop`、`xfreerdp3`、`secret-tool`、
`gnome-keyring-daemon` 等运行依赖缺失只记 `WARN`。

## 自动化测试

`tests/run-all.sh` 跑 `tests/` 下所有 `*-test.sh`，单个文件失败不阻断其余文件，最后汇总。
它们都是纯函数与 stub 测试，不需要桌面环境、不需要先安装，也不会有桌面副作用（不弹通知、
不启动真实 agent）：

| 测试 | 覆盖 |
| --- | --- |
| `tests/agent-test.sh` | agent 表、argv 逐字保真（含换行/引号）、launcher 与选择器的端到端往返 |
| `tests/ask-test.sh` | 问一问：文本来源优先级（参数 > 主选区 > 剪贴板）、commit/review 的 git 回退、prompt 内容、截断、跑完提醒的三种模式与退出码、console 包装缺失时的退化 |
| `tests/resume-test.sh` | 跨工具会话枚举：四种存储格式、提示数排除工具结果、dsh 时间取最后消息、空字段占位、逐 agent 续接语法 |
| `tests/crash-test.sh` | 崩溃字段解析（含缺失字段的对齐）与静音名单的名字截断 |
| `tests/oom-test.sh` | OOM 事件解析与去重（内核两条消息只提醒一次），与崩溃测试对称 |
| `tests/usage-test.sh` | 用量采集：同日多条用量累加、缓存与全量结果一致、缓存版本失配作废、两种 input 语义下的计费 |
| `tests/usage-edge-test.sh` | 用量边界：同 message.id 多行只算一次、重复 token 快照跳过、读不了的文件不缓存成 0、畸形字段不崩、限额端点异常不拖垮统计 |
| `tests/dsh-usage-test.sh` | DSH 采集器：v4/v0 两种事件格式、token 语义（input 不含缓存读、reasoning 不重复计）、只认 `source.kind == "user"` 的提示、命中缓存与全量重扫一致 |
| `tests/ai-settings-test.sh` | AI 集成设置的校验/原子写入/服务开关/提示词编辑（入口是 Python 用例 `tests/ai_settings_test.py`） |
| `tests/dms-plugin-test.sh` | DMS 插件：jq 接线的参数化/只增不覆盖/幂等/左栏与右栏落位/**无 barConfigs 时不造栏**、7 个 `plugin.json` 契约、随包资产与 manifest 覆盖、“用户关掉后重装不重新打开” |
| `tests/tui-test.sh` | 终端界面：非终端退化为纯文本（无 ANSI/无 `\r`，保留 `[INFO]`/`[WARN]`）、真终端上色、`NO_COLOR`/`TERM=dumb`/`CACHYOS_TUI=plain`、中文两列宽、框线等宽、截断不超宽，以及 `install.sh` 的集成 |
| `tests/fresh-install-test.sh` | **全新安装彩排**：把 `install.sh` 真跑一遍（临时 HOME + 假系统根），逐项断言命令、资产、单元、7 个插件与 helper、`plugin_settings.json` 启用、niri 接线、技能链接；全新 HOME 没有 `barConfigs` 时安装器**不会凭空造栏** |
| `tests/agent-theme-test.sh` | 主题同步生成 Claude 自定义主题与 Hermes skin，校验格式与幂等 |
| `tests/voxtype-test.sh` | 听写状态机、未安装时的提示、快捷键文件写入与卸载、配置备份 |
| `tests/hardware-test.sh` | CPU/GPU 检测与包选择 |
| `tests/qml-chart-test.sh` | 折线图在真实 QML 里的绘制（V4Sequence 兼容）；没有 `qml6` 时跳过 |
| `tests/integration-qml-test.sh` | 可选的真实 DMS QML 导入回归；没有 `qs` 或 DMS 时跳过 |

> 为什么折线图必须单独测：node 测试只能喂真数组，而 QML 把 Repeater delegate 里的数组交给
> JS 时用的是 V4Sequence（有 length、能下标，但 `Array.isArray()` 为 false）。这个差异只在
> QML 里出现，曾导致折线图一个点都画不出来而且**不报错**。

插件自身的纯逻辑另有独立测试（在插件目录里）：

```bash
node --test assets/dms-plugins/CachyosAgents/tests/usage.test.cjs
node --test assets/dms-plugins/LocalStatus/tests/status.test.cjs
(cd assets/dms-plugins/LocalTranslate && CGO_ENABLED=0 go test . -count=1)
(cd assets/dms-plugins/LocalLyrics && CGO_ENABLED=0 go test . -count=1)   # 需要 ffprobe（ffmpeg）
(cd assets/dms-plugins/PhoneConnect && CGO_ENABLED=0 go test . -count=1)
(cd assets/dms-plugins/Focus && CGO_ENABLED=0 go test . -count=1)
(cd assets/dms-plugins/Top/helper && CGO_ENABLED=0 go test . -count=1)
```

## 硬件进一步检查

```bash
lspci -nnk
vulkaninfo --summary
wpctl status
powerprofilesctl
bluetoothctl show
ddcutil detect
```

## 出问题先看哪里

| 现象 | 先看 |
| --- | --- |
| 某个命令不存在 | 安装日志里的 `[WARN]`；`ls /usr/local/bin/` 与 `verify.sh` 的 `command missing` |
| 快捷键或配置不符合预期 | [keybindings.md](keybindings.md#配置归谁管)、`cachyos-config status` |
| DMS 不启动或没绑定 Niri | `systemctl --user status dms.service`、`verify.sh` 的 DMS binding 检查 |
| AI agent 起不来、技能缺失 | [ai.md](ai.md#故障排查) |
| 崩溃/OOM 没有通知 | [crash-oom.md](crash-oom.md) |
| 用量面板没数字 | [usage.md](usage.md) |
| 插件没出现或没接到状态栏 | [dms-plugins.md](dms-plugins.md) |
| 听写快捷键没反应 | [voxtype.md](voxtype.md#快捷键按了没反应) |
