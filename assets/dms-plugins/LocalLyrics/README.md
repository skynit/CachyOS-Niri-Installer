# LocalLyrics 本地歌词

为 **DankMaterialShell（DMS）** 显示音乐文件的**内嵌歌词**。通过 MPRIS 获取当前歌曲及播放进度，用 FFmpeg 的 `ffprobe` 读取音频标签，完全离线运行。

**无需导出或放置外部 `.lrc` 文件。** 内嵌文本带有 LRC 格式的时间戳时逐句同步；没有时间戳时提供全文浏览。

## 本机使用

插件已安装并启用，名称为 **LocalLyrics 本地歌词**，ID 为 `localLyrics`。在 **DMS 设置 → 状态栏 → 组件** 中放到需要的位置即可。

已经适配本机 termusic：它没有提供歌曲文件地址时，插件会只读查询 `~/.config/termusic/library2.db`，按歌名和歌手匹配音频文件；遇到多个版本时再用专辑和时长筛选。仍无法唯一确定时显示提示，不随意选取歌词。

其他播放器需要通过 MPRIS 提供本地 `file://` 歌曲地址。在线歌曲地址不下载、不访问网络，也不会猜测本地文件路径。

## 界面与显示

横向状态栏只显示歌词文字，已移除左侧图标。默认双行分别显示当前句和下一句，也可以切换单行；长文本省略，点击展开全文。

![双行歌词，来自内嵌测试文本](docs/images/bar-double-example.png)

![单行歌词，来自内嵌测试文本](docs/images/bar-single-example.png)

![完整内嵌歌词，来自原创测试文本](docs/images/embedded-example.png)

截图为 DMS 实际组件渲染，示例歌词为原创测试文本，不是真实歌曲歌词。主题颜色跟随 DMS。

- **有歌曲才显示**：当前播放器处于播放或暂停状态，且有歌名或歌曲地址时显示；暂停时保留。
- **自动隐藏**：停止播放、播放器关闭或歌曲信息为空时，组件隐藏并收起宽度。
- **同步高亮**：暂停保持当前句，前后拖动进度后重新定位；不提供进度的播放器只能浏览全文。
- **滚动跟随**：弹窗高亮当前句；手动滚动后暂停跟随，点击“跟随当前句”恢复。
- **重新读取**：音频标签修改后，点击“重新读取”刷新，不会持续扫描音乐目录。
- **键盘操作**：Tab/Shift+Tab 切换控件，Enter/Space 打开或激活按钮；全文区支持方向键及 PageUp/PageDown，Esc 使用 DMS 原有关闭行为。
- **纵向状态栏**：保留小型歌词图标作为全文入口。

“有歌曲”依据播放器状态和歌曲信息判断，不以文件是否包含歌词为条件；MPRIS 没有统一可靠的音乐/视频分类字段。

## 设置

在 **DMS 设置 → 插件 → LocalLyrics 本地歌词** 中调整。也可右键状态栏组件，或使用弹窗中的“设置”。

| 设置 | 默认值 | 作用 |
| --- | --- | --- |
| 双行显示 | 开启 | 当前句 + 下一句，关闭后只显示当前句 |
| 状态栏歌词宽度 | 320px | 可调 120–800px，受屏幕宽度限制 |
| 歌词时间偏移 | 0ms | 可调 -10,000–10,000ms，正数延后、负数提前 |
| 复原 | — | 将偏移、滑块和已保存设置恢复为 0ms；已经归零时禁用 |

偏移设置作用于整个插件。如果内嵌歌词包含 `[offset:+500]` 标签，遵循 LRC 语义让歌词提前 500ms；界面的正偏移则表示“晚一点显示”，两者可以叠加。

原来的“歌词目录”设置已移除，不再查找外部 `.lrc`。

## 内嵌歌词支持

已用真实生成的音频文件验证 **FLAC、MP3、M4A、Ogg** 的内嵌歌词。还允许读取 Opus、WAV、WMA、AAC、APE、WV、AIFF 等常见音频文件，具体取决于 FFmpeg 能否把歌词暴露为文本标签。

读取容器和音频流中的 `LYRICS`、`lyrics-eng`、`UNSYNCEDLYRICS`、`USLT`、`©lyr` 等文本歌词字段；同时存在纯文本和带时间戳字段时优先选择同步版本。

内嵌文本支持：

- `[mm:ss]`、`[mm:ss.xx]`、`[mm:ss.xxx]` 等逐句时间标签。
- 一句多个时间标签、同时间的原文与译文、乱序时间点和文件偏移。
- 带时间戳的空行，用 `♪` 清除上一句。
- 增强 LRC 的逐字时间标记会去掉，仅进行逐句高亮。
- 无时间标签的纯文本，以明确的非同步状态展示。

单个歌词字段最多 1 MiB、最多 5,000 个时间点或纯文本行。并非所有音频标签都具有歌词，缺失时显示“这首歌没有可读取的内嵌歌词”。不解析 FFmpeg 未暴露的二进制 SYLT、QRC/KRC 或播放器私有歌词格式。

## 环境、安装与更新

运行需要 Linux、**DMS 1.6.1 或更新版本**、DMS 对应的 Quickshell/Qt 6、随插件分发的纯 Go 辅助程序和 **FFmpeg（ffprobe）**；运行时不需要 Python 或 cgo。编译辅助程序需要 Go。

源码：`/home/skynit/workspace/dms-plugins/LocalLyrics`，由 `dms-plugins` 仓库统一管理。

安装目录：`~/.config/DankMaterialShell/plugins/localLyrics`。

其他机器安装或更新：

```bash
cd /path/to/dms-plugins/LocalLyrics
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/localLyrics"
mkdir -p "$plugin_dir"
cp -a LocalLyrics.qml LyricsSource.qml LyricsPopout.qml LyricsSettings.qml \
  Timeline.js plugin.json README.md docs "$plugin_dir/"
GOAMD64=v1 CGO_ENABLED=0 go build -o "$plugin_dir/lyrics-helper" .
dms ipc call plugin-scan scan
```

插件被发现后启用：

```bash
dms ipc call plugins enable localLyrics
dms ipc call plugins list
```

更新后执行 `dms ipc call plugins reload localLyrics`。DMS 可能缓存引用的 QML，若仍显示旧界面，可在方便时重启 DMS。插件不自动改变状态栏位置。

termusic 媒体库路径遵循 `XDG_CONFIG_HOME`，默认是 `~/.config/termusic/library2.db`。如果歌曲已移动或媒体库无记录，请先在 termusic 中重新扫描媒体库。

## 实现与验证

| 文件 | 职责 |
| --- | --- |
| `LocalLyrics.qml` | 歌词组件、无歌曲隐藏及弹窗入口 |
| `LyricsSource.qml` | MPRIS 元数据与进度、异步读取、取消和超时 |
| `LyricsPopout.qml` | 全文、高亮、状态和重新读取 |
| `LyricsSettings.qml` | 单双行、宽度、时间偏移与复原 |
| `Timeline.js` | 时间匹配与进度格式化 |
| `main.go` | 本地音频定位、ffprobe 标签读取、歌词解析与 JSON 协议 |
| `main_test.go` | Go 运行时的当前包测试 |
| `lyrics.py` / `tests/test_lyrics.py` | 原实现与对照测试，只在开发时使用 |

Go 程序以 `CGO_ENABLED=0` 编译。查询通过 JSON 标准输入传递，不把歌名拼接为 shell 命令。ffprobe 只允许本地文件协议；插件不联网，不改写音频文件、媒体库或播放器状态，也不收集播放历史或访问剪贴板。

按歌曲变化读取一次标签；播放中每 100ms 读取 Quickshell 提供的进度，精度取决于播放器。旧进程被取消，旧结果不会覆盖新歌曲。

运行当前插件测试：

```bash
CGO_ENABLED=0 go test ./...
```

Go 测试覆盖实际 FLAC/MP3/M4A/Ogg 标签、纯文本和无歌词、termusic 唯一匹配与歧义、远程地址拒绝、时间格式和偏移。测试使用 FFmpeg 生成短静音文件；旧 Python 测试可用于构建阶段的对照验证，运行插件只需 Go 编译产物与 ffprobe。

本机还检查了真实 termusic 内嵌歌词读取与进度匹配，以及 DMS 实际组件的偏移复原、单双行、无图标、自动隐藏和零宽度收起。对测试播放器只进行组件内模拟，没有控制实际播放器。

本仓库不附带第三方歌曲歌词；`docs/example.lrc` 仅保存生成内嵌测试音频所用的原创测试文本，不是运行时歌词来源。
