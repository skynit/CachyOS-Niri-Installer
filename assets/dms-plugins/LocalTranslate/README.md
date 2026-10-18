# LocalTranslate 离线翻译

为 **DankMaterialShell（DMS）** 提供中文、英文双向离线查词。点击状态栏中的“翻译”，输入词条或短语即可查询；自带 **125,061 条 CC-CEDICT 记录**，无需 API Key、账号、网络或模型下载。

这是词典查询工具：**只返回词库收录的词条与短语，不进行任意整句翻译**。英文释义反查可能返回多个中文候选，请结合释义选择。

## 界面

以下图片来自本机 DMS 实际 QML 渲染，结果来自随插件分发的词库。颜色会跟随 DMS 主题。

| 英文 → 中文 | 中文 → 英文 |
| --- | --- |
| ![输入 computer，查到电脑和计算机](docs/images/english-to-chinese.png) | ![输入你好，查到 hello 和 hi](docs/images/chinese-to-english.png) |

<details>
<summary>建议词条、未收录提示与紧凑布局</summary>

![translat 的前缀建议](docs/images/suggestions.png)

![未收录的句子](docs/images/not-found.png)

![400px 宽度下的弹窗](docs/images/compact.png)

</details>

## 功能

- **自动识别方向**：包含汉字时查询中文索引，否则查询英文索引；也可手动选择“中 → 英”或“英 → 中”。
- **简体中文结果**：中文词头统一展示简体，不再并列繁体写法；输入简体或繁体均可查询。拼音可选，本机已关闭。
- **词条与短语**：支持 `你好`、`电脑`、`computer`、`good morning` 等。
- **输入归一化**：英文不区分大小写，支持全角字母、合并空白、忽略首尾常见标点。
- **前缀建议**：没有精确匹配时，最多显示 8 个同前缀建议，点击即可查询。
- **自动或手动查询**：默认输入停顿 300ms 后查询；可关闭自动查询，改用 Enter 或“查询”按钮。中文输入法组词时暂停自动查询。
- **多候选释义**：最多显示 20 条结果，超出时明确提示；结果区支持滚动。
- **明确复制/粘贴**：点击“复制”复制该项译文；“粘贴”从当前剪贴板插入输入框。“清空”同时清除输入与结果。
- **键盘操作**：Tab/Shift+Tab 切换控件，Enter 查询，Enter/Space 激活按钮；结果区支持方向键与 PageUp/PageDown 滚动；实际 DMS 弹窗由 Esc 关闭。
- **原生主题**：使用 DMS 的颜色、字体、按钮与状态栏组件，支持横向和纵向状态栏。

## 安装与放置

运行环境：Linux 上的 **DMS 1.6.1 或更新版本**、DMS 使用的 Quickshell/Qt 6、随插件分发的词典和纯 Go 查询程序；运行时不需要 Python 或 cgo。源码构建时需要 Go，重新生成词典时才需要 Python 3。

本机源码位于：

```text
/home/skynit/workspace/dms-plugins/LocalTranslate
```

安装目录：

```text
~/.config/DankMaterialShell/plugins/localTranslate
```

本机已安装并启用。打开 **DMS 设置 → 状态栏 → 组件**，在想要的位置添加 **LocalTranslate 离线翻译**。插件列表中可通过此名称或 ID `localTranslate` 找到它。安装只注册插件，状态栏位置由你选择。

在其他机器安装，或从源码更新：

```bash
cd /path/to/dms-plugins/LocalTranslate
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/localTranslate"
mkdir -p "$plugin_dir"
cp -a LocalTranslate.qml TranslatePopout.qml TranslateSettings.qml Lookup.qml plugin.json data "$plugin_dir/"
GOAMD64=v1 CGO_ENABLED=0 go build -o "$plugin_dir/translate-lookup" .
dms ipc call plugin-scan scan
```

等待插件列表出现 `localTranslate` 后，在设置中启用，或执行：

```bash
dms ipc call plugin-scan list
dms ipc call plugins enable localTranslate
dms ipc call plugins list
```

更新后可尝试 `dms ipc call plugins reload localTranslate`。DMS 热重载可能缓存引用的 QML 文件；若界面仍为旧版，可在方便时重新启动 DMS 使所有 QML 更新生效。

## 使用示例

| 输入 | 自动方向 | 典型结果 |
| --- | --- | --- |
| `你好` | 中文 → 英文 | `hello; hi` |
| `谢谢` | 中文 → 英文 | `to thank; thanks; thank you` |
| `電腦` | 中文 → 英文 | `computer`，保留原始量词说明 |
| `computer` | 英文 → 中文 | 电脑、计算机 |
| `good morning` | 英文 → 中文 | 早、早安、早上好等 |
| `translat` | 英文 → 中文 | 未精确匹配，提供 `translate` 等建议 |

中文查询复制该词条的全部英文释义；英文查询复制所选的简体中文词条。拼音中的 `1`–`5` 为声调编号；`CL:` 为量词说明，`(Tw)` 等为上游词库的地区或用法标注。

## 设置

在 **DMS 设置 → 插件 → LocalTranslate 离线翻译** 中调整：

| 项目 | 默认值 | 作用 |
| --- | --- | --- |
| 默认翻译方向 | 自动识别 | 弹窗的初始查询方向 |
| 在状态栏显示“翻译”文字 | 开启 | 横向栏显示图标和文字，关闭后仅显示图标 |
| 显示拼音 | 开启 | 结果中展示上游的数字声调拼音 |
| 输入后自动查询 | 开启 | 输入停顿后查询；关闭后按 Enter 或点击查询 |

弹窗中的方向按钮用于当前弹窗的查询；默认方向通过设置页保存。

## 词库、匹配规则与边界

默认词库是 MDBG 发布的 **CC-CEDICT** 快照，时间为 **2026-09-14T05:30:59Z**。125,061 是原始记录数，同一汉字词条可以有多个读音或释义记录，并不表示拥有同等数量的独立英文单词。

中文查询精确匹配简体或繁体词头。英文查询匹配英文释义建立的反向索引；为了便于查词，索引也包含去掉括号注释、部分冠词或 `to ` 前缀的形式，以及分号分隔的短释义。原始释义完整保留在结果中。

结果按匹配形式、中文词头长度和稳定词序排列，**不是按语境或常用程度排序**。本插件不提供词形还原、拼写纠正、语音、全文检索、逐词拼接、句子理解或生成式翻译。没有匹配时，可以缩短词条、输入原形或尝试建议词。

输入最多 200 个字符；系统错误和未收录是不同状态，错误时保留输入并提供重试。快速输入或切换方向时会取消旧查询，旧结果不会覆盖新输入。

## 离线与隐私

运行时只读随插件分发的 SQLite 字典，不发送网络请求。查询通过 JSON 标准输入传给固定的 `translate-lookup` Go 程序，用户文本不作为 shell 命令执行。

插件只保存方向、显示开关等设置，不将查询历史写入文件。复制和粘贴仅由用户操作触发，不轮询剪贴板；系统或其他应用自行提供的剪贴板历史不受本插件控制。

## 目录结构

```text
LocalTranslate/
├── plugin.json              # DMS 清单
├── LocalTranslate.qml       # 状态栏入口
├── TranslatePopout.qml      # 输入、方向和结果弹窗
├── TranslateSettings.qml    # 设置页
├── Lookup.qml               # 本地进程、取消及超时处理
├── main.go / main_test.go   # 运行时查询与当前包测试
├── lookup.py                # 只供构建词典及旧查询对照，不随运行版安装
├── build_dictionary.py      # 构建时从随附原始词库建立索引
├── data/
│   ├── cedict.txt.gz         # 原始 CC-CEDICT 快照
│   ├── dictionary.sqlite3   # 可直接使用的双向索引
│   ├── manifest.json        # 版本、数量与 SHA-256
│   ├── NOTICE.md            # 词库署名与派生说明
│   └── CC-BY-SA-4.0.txt     # 词库完整许可
├── tests/test_lookup.py     # 词典构建器与旧查询对照测试（需 Python）
└── docs/images/             # 真实 QML 界面截图
```

原始压缩词库约 3.8 MiB，索引约 23 MiB。运行时不需要解压、重建或 Python。

## 开发与验证

仅运行此插件的测试：

```bash
CGO_ENABLED=0 go test ./...
```

测试覆盖双向查询、简繁匹配、短语、输入归一化、方向强制选择、非法与超长请求、缺失/损坏词库、建议词、结果上限、原始数据校验，以及 JSON 命令行协议。

可直接调用查询程序：

```bash
printf '%s\n' '{"text":"computer","direction":"auto"}' | "${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/localTranslate/translate-lookup"
```

响应 `status` 为 `idle`、`ready`、`empty` 或 `error`；`entries` 是精确匹配结果，`suggestions` 是建议列表。`direction` 的 `zh` 表示中译英，`en` 表示英译中。查询时使用只读数据库连接。

从随附的原始快照重新建立索引：

```bash
python3 build_dictionary.py
python3 -m unittest discover -s tests -v
```

构建器会生成临时数据库，完成后替换 `dictionary.sqlite3` 并更新 `manifest.json`。运行构建器不会下载词库。更新快照时，请同步本页数量、日期、署名说明及安装目录中的数据。

本机还通过临时 QA 组件在 DMS 1.6.1 中加载了真实状态栏入口、弹窗与设置页，检查了自动/手动查询、连续输入、清空、建议、未收录状态和 400px 布局。截图由真实组件生成。中文 IME 的实体键盘输入、系统剪贴板及读屏器未自动化端到端测试。

## 词库许可

CC-CEDICT 原始数据及本插件的派生索引遵循 **CC BY-SA 4.0**。分发时保留 [署名、来源及变更说明](data/NOTICE.md) 和 [完整许可](data/CC-BY-SA-4.0.txt)。词库由 CC-CEDICT 社区维护、MDBG 发布；词库许可不替插件源码指定许可。
