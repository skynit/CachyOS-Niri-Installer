# LocalStatus

LocalStatus 是一个 DankMaterialShell（DMS）状态栏插件，用于查看本机 IP、网络链路、CPU、系统负载、内存、Swap、磁盘剩余空间和时间。

支持单行和双行布局、上下按列对齐、模块独立开关、模块间距和上下内边距调节。点击状态条可打开完整详情，样式、字体和颜色跟随 DMS 主题。

## 界面预览

### 双行状态条

![双行状态条：模块按列对齐，并保留上下留白](docs/images/status-bar.png)

截图展示部分已开启模块。每列的宽度由上下两个模块中较宽的一项决定，模块数为奇数时，上排会多一个。

### 详情面板

<img src="docs/images/details-panel.png" alt="本机状态详情：网络、资源使用情况与带内边距的两列布局" width="520">

详情使用真实 QML 组件和本机采样数据。图片是采样时刻的快照；上图截取详情顶部，底部采样时间等内容可向下滚动查看。明暗配色随 DMS 主题变化。

## 环境要求

| 项目 | 要求与用途 |
| --- | --- |
| 操作系统 | Linux；当前在 CachyOS + niri/Wayland 环境验证 |
| DankMaterialShell | 插件声明要求 `>=1.5.3`，已在 DMS 1.5.3 验证 |
| Quickshell / Qt | 使用 DMS 配套运行环境，以及其 `qs.Common`、`qs.Services`、`qs.Widgets` 等模块 |
| `dgop` | 由 DMS 的 `DgopService` 提供资源采样数据 |
| `ip` | 来自 `iproute2`，用于读取网络接口和 IPv4 地址 |
| Node.js | 仅运行数据逻辑测试需要；须支持 `node --test` |

插件无需单独编译。它依赖正在运行的 DMS，不能作为独立 QML 应用直接启动。

## 安装与启用

### 1. 复制插件文件

在本仓库的 `LocalStatus/` 目录执行以下命令。默认安装路径为 `~/.config/DankMaterialShell/plugins/LocalStatus`；设置了 `XDG_CONFIG_HOME` 时使用对应目录。

```sh
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/LocalStatus"
mkdir -p "$plugin_dir"
cp plugin.json ./*.qml Status.js "$plugin_dir/"
```

这些命令复制运行必需文件，不需要将 `.git`、编辑器配置、测试或文档图片安装到 DMS。已经安装过的用户可先按下文“更新与备份”保存原目录。

### 2. 让 DMS 发现插件

```sh
dms ipc call plugin-scan scan
dms ipc call plugins list
```

扫描是异步的。如果列表还没有出现 `localStatus`，稍后再次查看列表，或重新打开 DMS 的插件页面。

### 3. 启用并放置

在 **DMS 设置 → 插件** 中启用 **LocalStatus 本机状态**，也可以执行：

```sh
dms ipc call plugins enable localStatus
```

随后在 DMS 的状态栏设置中，将 LocalStatus 添加到所需栏位。安装和启用插件不会自动改变现有状态栏组件及其位置。

插件 ID 是 `localStatus`，目录名是 `LocalStatus`，注意大小写。

## 使用方式

| 操作 | 结果 |
| --- | --- |
| 点击状态条任意位置 | 打开或关闭详情面板 |
| 右键点击状态条 | 打开 DMS 的插件设置页 |
| 点击详情中的刷新按钮 | 请求资源更新，并重新读取网络接口 |
| 点击详情中的设置按钮 | 关闭详情并进入插件设置页 |
| 点击详情中的关闭按钮或按 Esc | 关闭详情 |
| 焦点位于状态条时按 Enter / Space | 打开或关闭详情 |
| 在详情内滚动，或使滚动区获得焦点后按上下方向键 | 查看超出面板高度的内容 |

状态条没有右侧展开箭头。关闭全部显示项目后，仍会保留一个小型详情入口。竖向状态栏显示监控图标入口，不排列完整读数。

## 显示内容

| 模块 | 状态栏内容 | 详情补充信息 |
| --- | --- | --- |
| 本机 IP | 选定网络接口的 IPv4 地址 | 接口名和地址类型 |
| 有线网络 | 已连接、无载波、未连接、未知或无设备 | 接口、IPv4、异常原因 |
| 无线网络 | 已连接、未连接、未知或无设备 | 接口、IPv4、异常原因 |
| CPU 使用率 | 总使用率，保留一位小数 | 逻辑 CPU 数及使用率进度条 |
| 系统负载 | 1 分钟平均负载 | 1 / 5 / 15 分钟平均负载 |
| 内存 | 已用容量，单位 GiB | 已用 / 总容量及使用比例 |
| Swap | 已用容量，单位 GiB | 已用 / 总容量；未配置时明确标注 |
| 磁盘剩余空间 | 指定挂载点的可用容量 | 可用 / 总容量、已用比例 |
| 时间 | 本机时间，可选日期和秒数 | 日期与本机时间说明 |

**磁盘数字是可用容量，磁盘进度条是已用比例。** 内存和 Swap 的数字、进度条均表示已用量。容量采用二进制单位，`1 GiB = 1024³ 字节`。

系统负载不是 CPU 使用率。在 Linux 上，它反映运行或等待 CPU 的任务，以及处于不可中断等待状态的任务所形成的平均负载。判断时应结合逻辑 CPU 数及持续时间：负载持续高于逻辑 CPU 数，可能与 CPU 竞争或 I/O 等待有关，不能直接换算成 CPU 使用百分比。

## 配置说明

入口：**DMS 设置 → 插件 → LocalStatus 本机状态**。设置通过 DMS 保存，调整后即时作用于已加载的组件。

### 模块开关

以下项目默认全部开启，顺序固定。开关只影响状态栏展示；详情面板仍显示全部项目，隐藏模块也不会单独停止其采样。

| 显示项目 | 设置键 | 默认值 |
| --- | --- | --- |
| 本机 IP | `show_ip` | `true` |
| 有线网络 | `show_lan` | `true` |
| 无线网络 | `show_wifi` | `true` |
| CPU 使用率 | `show_cpu` | `true` |
| 系统负载 | `show_load` | `true` |
| 内存 | `show_ram` | `true` |
| Swap | `show_swap` | `true` |
| 磁盘剩余空间 | `show_disk` | `true` |
| 时间 | `show_time` | `true` |

### 布局、间距与宽度

| 设置 | 设置键 | 默认值 | 可选值或范围 |
| --- | --- | --- | --- |
| 显示布局 | `layoutMode` | `single` | `single` 单行；`double` 双行 |
| 模块间距 | `moduleSpacing` | `4` | `0–32` 逻辑像素 |
| 上下内边距 | `verticalPadding` | `2` | `0–6` 逻辑像素，顶部和底部各使用此值 |
| 状态条宽度上限 | `maxWidth` | `1200` | `160–1600` 逻辑像素，同时受屏幕宽度约束 |

- 单行按固定模块顺序从左到右排列。
- 双行先填上排，再填下排。只计算已开启的模块，上下同列左对齐，共用列宽。
- 模块间距在单行中表示相邻模块之间的距离，在双行中表示相邻列之间的距离。
- 数值使用预留宽度以减少刷新时的跳动。因此，间距设为 `0` 后仍可能有数值占位空白；状态条左右另有固定留白。
- 上下内边距作用于横向状态条内部，不改变 DMS 整栏高度。留白越大，双行可用行高越小，文字和图标会按剩余空间适配；较矮的栏建议从 `2px` 开始调整。
- 双行的上下内边距不控制两排之间的间距；详情面板的 `16px` 内边距独立且固定。
- 达到宽度上限后，超出的内容会被裁切，点击状态条仍可查看完整详情。

例如开启 IP、CPU、负载、内存、Swap 和磁盘后，双行的列关系如下：

| 第一列 | 第二列 | 第三列 |
| --- | --- | --- |
| 本机 IP | CPU 使用率 | 系统负载 |
| 内存 | Swap | 磁盘剩余空间 |

### 时间、网络与磁盘

| 设置 | 设置键 | 默认值 | 说明 |
| --- | --- | --- | --- |
| 显示日期 | `showDate` | `false` | 在状态栏时间前添加 `yyyy-MM-dd` |
| 显示秒数 | `showSeconds` | `true` | 在 `HH:mm:ss` 和 `HH:mm` 之间切换 |
| IP 来源 | `ipSource` | `auto` | `auto` 自动、`wifi` 无线、`lan` 有线 |
| 无线网卡 | `wifiInterface` | 空字符串 | 自动选择；也可填入精确接口名 |
| 有线网卡 | `lanInterface` | 空字符串 | 自动选择；也可填入精确接口名 |
| 磁盘挂载点 | `mount` | `/` | 匹配 DMS 采样中的挂载点 |
| 网络采样间隔 | `networkInterval` | `5` | `3–60` 秒，仅影响网络接口读取 |

自动 IP 来源优先使用具有可用 IPv4 的有线接口，其次使用无线接口。指定 `lan`、`wifi` 或具体接口后，如果该接口断开、消失或没有可用 IPv4，会显示相应缺失状态，不会用另一块网卡的数据替代。

可以用 `ip -j address show` 核对接口名。插件当前显示接口 IPv4，不查询公网 IP，不显示 IPv6，也不根据“已连接”判断互联网是否可达。

设置由 DMS 保存于 `~/.config/DankMaterialShell/plugin_settings.json` 的 `localStatus` 项；配置根目录遵循 `XDG_CONFIG_HOME`。建议从设置页面修改。手动编辑时只修改该插件项，并注意 DMS 正在运行时可能写回设置文件。

## 数据来源与异常状态

| 数据 | 来源 | 更新方式 |
| --- | --- | --- |
| CPU、负载、内存、Swap、磁盘 | DMS `DgopService` | 使用 DMS 的共享采样周期，插件以引用计数订阅和释放模块 |
| 接口与 IPv4 | 固定命令 `ip -j address show` | 默认每 5 秒执行一次，可配置为 3–60 秒 |
| 日期与时间 | Quickshell `SystemClock` | 每秒更新，使用本机时区 |

CPU 百分比需要差分采样，首次读数可能短暂显示 `--`。资源采样或网络采样过期后，也会隐藏旧数值，避免将历史数据当作当前状态。详情底部可查看两类采样的时间。

| 状态 | 含义 | 常见 reason |
| --- | --- | --- |
| `healthy` | 当前数据可用 | 无异常原因 |
| `degraded` | 等待采样、链路断开或部分数据不完整 | `waiting_for_sample`、`waiting_for_cpu_delta`、`no_carrier`、`ipv4_unavailable` |
| `unsupported` | 数据来源不可用，或指定设备/挂载点不存在 | `dgop_unavailable`、`device_not_found`、`mount_not_found` |
| `unreachable` | 采样已过期或网络读取失败 | `sample_stale`、`network_command_failed`、`invalid_network_data` |

`0%` CPU 和 `0 GiB` Swap 可以是真实读数；未配置 Swap 会明确显示“未配置 Swap”。缺失数据通常显示 `--`，网络模块还会使用“无设备”“无载波”等具体状态文字。

插件读取本机状态，不修改网络或磁盘配置。清单中的 `process` 权限用于上述固定网络查询，`settings_read` / `settings_write` 用于插件配置；当前实现不执行用户输入的 shell 命令，也不主动访问剪贴板或发送远程请求。

## 更新、备份与卸载

### 更新已安装副本

workspace 仓库与安装目录是两份独立文件。修改仓库不会自动同步到正在运行的插件。

如需保留旧版本，可先备份到插件扫描目录之外：

```sh
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/LocalStatus"
backup_dir="${XDG_STATE_HOME:-$HOME/.local/state}/LocalStatus/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$(dirname "$backup_dir")"
cp -a "$plugin_dir" "$backup_dir"
```

然后在仓库的 `LocalStatus/` 目录复制运行文件并重新加载：

```sh
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/LocalStatus"
cp plugin.json ./*.qml Status.js "$plugin_dir/"
dms ipc call plugins reload localStatus
```

该操作不覆盖 `plugin_settings.json`，现有模块开关、显示布局和间距配置会继续使用。

DMS 可能缓存设置页或嵌套 QML 组件。如果重新加载插件后仍显示旧界面，可重新打开设置页；仍未更新时，在方便时执行 `dms restart`，它会重启整个 DMS 界面。不要通过删除配置文件来刷新界面。

### 禁用或卸载

临时停用可在 DMS 插件页面关闭开关，或执行：

```sh
dms ipc call plugins disable localStatus
```

卸载时，先在 DMS 状态栏设置中移除 LocalStatus，再禁用插件，最后通过文件管理器删除安装目录。workspace 中的源码副本可以保留，其他插件配置无需改动。

## 常见问题

| 现象 | 检查与处理 |
| --- | --- |
| 插件列表没有 LocalStatus | 检查安装目录下是否直接存在 `plugin.json`，避免多嵌套一层目录；触发扫描后等待列表刷新 |
| 已启用但状态栏没有读数 | 启用不会自动放置组件，需要在状态栏设置中添加 LocalStatus；全部项目关闭时只显示详情入口 |
| 刚启用时 CPU 显示 `--` | 等待差分采样；持续缺失时查看详情 reason，并确认 DMS 的 dgop 数据源可用 |
| 网络显示“无载波” | 接口存在但链路没有载波，例如网线未连接；这不表示其他接口也不可用 |
| 指定网卡后 IP 不显示 | 核对接口名、链路状态和 IPv4；手动指定后不会自动切换到其他接口 |
| 磁盘显示 `mount_not_found` | 挂载点须与 DMS 采样中的条目精确匹配，普通目录不一定是独立挂载点 |
| 双行文字太小 | 减小上下内边距、改用单行，或在 DMS 中增加栏的可用高度 |
| 间距为 0 仍有空白 | 模块仍保留数值占位宽度；双行同列还会按较宽模块对齐 |
| 部分模块被截断 | 提高宽度上限、改用双行，或关闭不需要的状态栏项目；详情仍可查看全部数据 |
| 更新后仍是旧样式 | 确认已同步到安装目录，并参考上文的重新加载和 DMS 缓存说明 |

## 开发与验证

### 文件结构

```text
LocalStatus/
|-- plugin.json                 插件清单、依赖和权限
|-- LocalStatus.qml             状态栏布局与详情入口
|-- LocalStatusSettings.qml     DMS 插件设置页
|-- StatusSource.qml            采样订阅、网络读取与新鲜度
|-- Status.js                   数据解析、格式化和异常状态
|-- StatusDetails.qml           详情面板与滚动内容
|-- StatusButton.qml            详情操作按钮与键盘交互
|-- tests/status.test.cjs        数据逻辑测试
|-- docs/images/                README 截图
`-- README.md
```

### 数据逻辑测试

在仓库的 `LocalStatus/` 目录运行：

```sh
node --test tests/status.test.cjs
```

当前包含 7 项测试，覆盖零值、CPU 首次采样、部分数据缺失、采样过期、时钟回拨、网络失败、接口选择以及磁盘容量解析等情况。测试通过 Node.js 的 VM 加载 `Status.js`，不需要启动 DMS，也不依赖实际网卡或磁盘读数。

这些测试不验证 QML 布局。界面修改还应在实际 DMS 中检查单行/双行、奇偶模块数、开关后的列对齐、间距与内边距、窄宽度、详情滚动及设置持久化。

可用以下命令查看插件加载状态：

```sh
dms ipc call plugins list
dms ipc call plugin-scan status localStatus
```

QML 文件可使用与 DMS 匹配的 Qt 6 `qmlformat` 格式化。加载失败时查看 Quickshell 日志中的具体组件错误；独立 QML 工具缺少 DMS 的 `qs.*` 模块时产生的导入错误，不能单独作为插件运行结果。

当前功能聚焦即时状态展示，不包含历史曲线、网络上下行速率、温度、进程列表或告警通知。
