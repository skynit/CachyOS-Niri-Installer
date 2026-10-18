# Top 系统面板

DankMaterialShell（DMS）的悬浮系统监视插件，界面参考 macOS 上的 [ftop](https://github.com/Nongfsq/ftop)：一块深色圆角面板，默认居中显示，用 `Mod+BackSpace` 呼出，浮在所有窗口之上，再次按下或按 `Esc` 收起。面板显示每个核心的占用与当前频率、内存压力与可用/缓存、网络速率、磁盘活动、GPU 与显存、供电、温度、负载与运行时间，以及按应用聚合的进程列表（CPU 与内存占用，可按两者排序）。插件只通过热键呼出，不占用状态栏；隐藏后 3 秒停止采样，待机不消耗 CPU。

![Top 系统面板](docs/images/top.png)

图片由实际 DMS 组件渲染，颜色随 DMS 当前主题（壁纸配色）变化。

## 界面

- **每核一列**：柱高是整机占比形式的核心占用，白刻度是该核心的当前频率；核心按性能核（P）与能效核（E）分组，颜色分别取主题的 primary 与 tertiary。
- **GPU 列**：独立一列，刻度下方显示 GPU 频率；GPU 不可用时整列隐藏。
- **内存**：已用/总量、压力等级（`/proc/pressure/memory`）、压缩内存与 Swap；缺失的数值显示 `—`。
- **指标**：下行、上行、磁盘读写、功耗/供电、温度、电池，共六项，2×3 排列。
- **应用列表**：显示每个应用的整机 CPU 占比与常驻内存（如 `2.6G`、`161M`）；点击表头的「内存 / CPU」即可切换排序（也可在设置里选）；同一可执行文件的多个进程（例如浏览器子进程）折叠为一行并标注 `×N`；宽面板自动分成两列。
- **系统信息**：标题栏中间显示 1 分钟负载与系统运行时间；GPU 标题下显示显存占用；内存区显示可用与缓存、压缩内存和 Swap 总量。
- **尺寸自适应**：面板可拖动、可缩放；高度决定核心柱高度，宽度决定应用列表列数与柱宽；位置与尺寸写入插件设置，下次呼出保持不变。
- **只在可见时采样**：打开面板才启动 Go helper，关闭 3 秒后停止；再次打开会先显示上一次的快照，采样在 1 秒内刷新。
- **点击外部关闭**：面板打开时铺满整个输出的透明层会接住面板外的点击并关闭面板，因此点击其他窗口/状态栏时不需要先按 `Esc`；代价是该次点击被面板吞掉，不会同时传给下层窗口。
- **动效**：柱高与刻度用 340ms `OutCubic` 缓动，面板淡入缩放 130–170ms；不使用第三方动效或图表库。

## 交互

| 操作 | 行为 |
| --- | --- |
| `Mod+BackSpace` | 开关面板（niri 绑定，见下文） |
| 左键或右键拖动面板 | 移动；位置会自动保存 |
| 拖动右下角 | 调整面板大小（最小 560×360，最大 1200×700） |
| 点击面板外的任意位置 | 关闭面板；这一下点击不会传给下层窗口 |
| `Esc` | 关闭面板（打开时面板持有键盘焦点） |
| 再次按热键 | 关闭面板 |

## 数据来源

| 指标 | 来源 |
| --- | --- |
| CPU 占用 | `/proc/stat` 差分（整机与每核） |
| 核心频率 | `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq`；最大频率用于分组与刻度归一化 |
| CPU 温度 | `/sys/class/hwmon/*` 中的 `k10temp` / `coretemp` / `zenpower` / `cpu_thermal` |
| 内存、Swap | `/proc/meminfo`；压缩内存取 `/sys/block/zram*/mm_stat` |
| 负载、运行时间 | `/proc/loadavg`、`/proc/uptime` |
| 内存压力 | `/proc/pressure/memory` 的 `some avg10` |
| 网络 | `/proc/net/dev` 差分，默认路由网卡优先（`/proc/net/route`） |
| 磁盘活动 | `/proc/diskstats` 差分，排除分区、loop、dm 等 |
| GPU | `/sys/class/drm/card*/device` 的 `gpu_busy_percent`、`hwmon/{temp1_input,power1_average,freq1_input}`、`mem_info_vram_*` |
| 功耗 | `/sys/class/powercap/intel-rapl:*/energy_uj` 差分；多数内核只允许 root 读取时，退回电池功率或显示 `AC` |
| 电池 | `/sys/class/power_supply/BAT*` 的容量、状态与功率 |
| 应用与图标 | `/proc/<pid>/{stat,exe}`，再用 `/usr/share/applications` 等目录的 `.desktop` 条目匹配名称与 `Icon` |

所有数值由 Go 辅助程序 `top-helper` 采集，以每行一个 JSON 对象写到标准输出，QML 侧解析。缺失的测量保持 `null`，界面显示 `—`，不会把不可用显示成 0。

## 组成

| 文件 | 作用 |
| --- | --- |
| `plugin.json` | DMS 清单：daemon 插件（只有后台界面，不注册状态栏组件） |
| `TopDaemon.qml` | 后台界面：启动/重启 helper、解析采样、IPC、悬浮 `PanelWindow`、位置与尺寸持久化 |
| `TopPanel.qml` | 面板布局与视觉 |
| `components/` | 自绘组件：`GaugeBadge`（圆环仪表）、`CoreBar`（核心柱）、`MetricPill`、`ProcessRow` |
| `TopSettings.qml` | DMS 设置页 |
| `helper/` | Go 采样器（仅标准库），输出 NDJSON |

采样输出示例（省略部分字段）：

```json
{"ts":1792272019899,"intervalMs":1000,
 "cpu":{"name":"AMD Ryzen AI 7 H 450","usage":12.3,"temp":58.2,
        "cores":[{"i":0,"use":44.5,"freq":5142.5,"max":5157.9,"kind":"P"}]},
 "mem":{"total":31984368,"used":9705284,"swapTotal":50331640,"swapUsed":2364436,
        "compressed":716081,"pressure":"normal","pressureAvg10":0.02},
 "net":{"iface":"wlan0","rx":9941.2,"tx":6948.3},
 "disk":{"read":0,"write":0},
 "gpu":{"name":"AMD GPU","usage":10,"freq":758,"temp":47,"power":16.1},
 "battery":{"percent":98,"status":"discharging"},
 "load1":2.31,"uptimeSec":7588,
 "procs":[{"name":"Firefox","icon":"firefox","cpu":6.0,"memKB":4828256,"count":12}]}
```

## 安装

需要 Go 构建辅助程序；运行时只需要构建产物和 DMS。从本目录安装：

```bash
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/Top"
mkdir -p "$plugin_dir/components"
cp plugin.json TopDaemon.qml TopPanel.qml TopSettings.qml "$plugin_dir/"
cp components/*.qml "$plugin_dir/components/"
(cd helper && GOAMD64=v1 CGO_ENABLED=0 go build -trimpath -o "$plugin_dir/top-helper" .)
dms ipc call plugin-scan scan
dms ipc call plugins enable top
```

`XDG_CONFIG_HOME` 用于指定用户配置根目录，未设置时使用 `~/.config`；`GOAMD64=v1` 选择基础 x86-64 指令集，`CGO_ENABLED=0` 关闭 C 运行库链接。不需要在状态栏添加组件；插件启用后直接用热键呼出。

源码目录与安装目录是独立副本；更新后重新复制并重扫：

```bash
dms ipc call plugin-scan rescan top
dms ipc call plugins reload top
```

修改 `TopPanel.qml` 或 `components/` 里的文件后，`reload` 可能复用缓存中的嵌套组件；此时重启 DMS：

```bash
systemctl --user restart dms.service
dms ipc call plugins enable top
```

## 热键

niri 的绑定文件受安装器托管，先保护再改：

```bash
cachyos-config protect ~/.config/niri/dms/binds.kdl
```

在 `~/.config/niri/dms/binds.kdl` 的 `binds { }` 中加入（`Mod+BackSpace` 已确认空闲）：

```kdl
Mod+BackSpace hotkey-overlay-title="Top 系统面板" { spawn "dms" "ipc" "call" "top" "toggle"; }
```

```bash
niri validate
```

`Mod` 与 `Super` 等价。若与其他绑定冲突，`niri validate` 会直接报重复绑定。

## IPC

```bash
dms ipc call top toggle          # 开关
dms ipc call top open
dms ipc call top close
dms ipc call top status          # 返回 open/closed、面板尺寸、helper 状态
dms ipc call top resize 900 480  # 脚本用：调整尺寸并持久化
dms ipc call top move 640 48     # 脚本用：移动并持久化
```

`top` 目标由插件的 `IpcHandler` 注册；`dms ipc list` 可确认它已出现。

## 设置

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `intervalMs` | 1000 | 面板可见时的采样间隔，500–3000ms；隐藏后 3 秒停止 helper |
| `rows` | 24 | 应用行数，6–40（实际显示行数还受面板高度限制） |
| `showProcs` | true | 显示右侧应用列表 |
| `showFreq` | true | 显示每核频率 |
| `groupCores` | true | 按性能核/能效核分组 |
| `glass` | 100 | 背景不透明度（%） |
| `anchor` | `center` | 默认位置：`center`、`top-right`、`top-left`、`bottom-right`；首次加载或改这个设置时生效 |
| `sortBy` | `cpu` | 应用列表排序：`cpu` 或 `mem` |

位置与尺寸（`panelX`、`panelY`、`panelW`、`panelH`）由面板自身写入，不在设置页展示。

## 设计与实现取舍

- **不引入第三方 UI 库**：界面只用 Qt Quick 基础类型、Quickshell（图层窗口、`Process`、`IpcHandler`、`BackgroundEffect`）和 DMS 自带的 `qs.Common` / `qs.Widgets`。这样主题色、圆角、字体跟随 DMS，插件保持纯文件部署，不引入 QML 模块依赖。
- **Go 只做数据层**：柱状图、圆环、动效都在 QML 自绘；Go 负责读 `/proc` `/sys`、差分与进程聚合，避免 QML 里写采样逻辑。
- **圆角面板**：面板背景使用固定 24px 圆角。窗口本身铺满整个输出（`exclusiveZone: -1`，透明背景），这样才能接住面板外的点击；面板外的透明区域用全屏 `MouseArea` 关闭面板，不启用合成器背景模糊（niri 的 `background-effect` 会把矩形 layer 表面填成直角）。实际可见表面用主题色的实心 `Rectangle`（`glass` 默认 100，可在设置里调低），四角保持真正的圆角。
- **不伪造数据**：温度、功耗、GPU 频率等取不到时显示 `—`；RAPL 计数通常仅 root 可读，插件不请求提权。

## 已知限制

- 功耗优先读 RAPL；内核限制普通用户读取时显示电池放电功率，接电源时显示 `电源`（表示正在用电源适配器供电），不是整机功耗。
- GPU 目前读取 AMD / Intel 的 sysfs 接口；NVIDIA 只显示温度与名称（不依赖 `nvidia-smi`），未在 NVIDIA 机器上验证。
- 应用按可执行文件路径聚合；同一二进制承载的多个应用会合并成一行。内核线程（`kthreadd` 的子进程）不计入应用列表。
- CPU 百分比是整机占比（各核之和为 100%），与应用内显示的「单核 100%」口径不同。
- 进程列表会隐藏 CPU < 0.05% 且常驻内存 < 32MiB 的空闲噪声。
- 面板隐藏 3 秒后 helper 停止；再次打开的最初 1 秒内显示上一次的快照。
- 在 DMS 1.6.2、Quickshell 0.3.2、niri 26.04 上验证；更旧的 DMS 可能不支持浮动 `PanelWindow` 所需的接口。

## 开发验证

```bash
cd helper
gofmt -l . && go vet ./... && go test ./... -count=1
CGO_ENABLED=0 go build -trimpath -o ../top-helper .
../top-helper -once | python3 -m json.tool | head -40

dms ipc call plugin-scan rescan top
dms ipc call plugins reload top
dms ipc call top status
```

`helper` 的单元测试覆盖 `/proc`、`/proc/net/dev`、`/proc/diskstats`、`/proc/<pid>/stat`、压力、RAPL、负载/运行时间与桌面条目解析；`-once` 用于快速检查真实机器上的字段，`-sort mem` 可按内存排序输出。QML 修改后还需要在真实 DMS 中确认悬浮位置、拖动、缩放与主题切换。
