# 待办日历

将 Pluggable Desktop Service 的月历、日期记录、Markdown 正文和待办清单抽取为独立 DMS 插件。DMS（DankMaterialShell）是用户安装的桌面外壳，负责状态栏、主题和插件加载；本插件由状态栏按钮打开可编辑的日历窗口，数据独立保存在本机，运行时无需原应用常驻。

## 安装与打开

环境：Linux、DMS 1.6.2 或更高版本，以及 DMS 配套的 Quickshell / Qt 6。Quickshell 是 DMS 的界面运行框架，负责加载插件作者编写的 QML 界面文件。Go 1.25 或更高版本仅用于构建，不是运行时依赖；SQLite 驱动随辅助程序构建，运行时无需安装 sqlite3 命令或 Python。

```bash
cd ~/workspace/dms-plugins/TodoCalendar
bash build.sh
bash install.sh
dms ipc call plugin-scan scan
```

首次扫描存在短暂的防抖延迟；用 `dms ipc call plugins list` 确认出现 `todoCalendar` 后，再启用并添加状态栏入口：

```bash
dms ipc call plugins enable todoCalendar
dms ipc call todoCalendar addToBar
dms ipc call todoCalendar open
dms ipc call todoCalendar status
```

插件 ID 是 DMS 用于识别插件的名称，由 `plugin.json` 声明；本插件为 `todoCalendar`，与安装目录的大小写不同。`plugin.json` 同时声明界面入口、运行依赖与实际使用的进程、状态栏设置读写权限。

默认安装目录为 `~/.config/DankMaterialShell/plugins/TodoCalendar`；设置了 `XDG_CONFIG_HOME` 时改用该目录下的 `DankMaterialShell/plugins/TodoCalendar`。安装脚本先核对已有副本的校验清单；发现用户修改时停止覆盖。更新会先在相邻的临时目录准备全部运行文件，再切换目录，并保留打印出的上一版备份。安装清单指向按内容摘要区分的运行子目录，避免 DMS 继续复用旧 QML 组件缓存；只需定向重载本插件，不必重启整个桌面外壳。

更新后定向重扫、重载：

```bash
dms ipc call plugin-scan rescan todoCalendar
dms ipc call plugins reload todoCalendar
```

重载会销毁插件的内存草稿，先在窗口中保存。启用插件和将按钮加入状态栏是两个独立步骤；`addToBar` 只向第一个启用的状态栏添加一次，不重复放置。横向栏、纵向栏均提供可访问的图标入口。

## 使用

- 月历按周一开始，固定六周，共 42 个日期；支持前后月份、今天、刷新，以及方向键选择日期。
- 选择日期后，右侧显示当天记录；存在多条记录时通过下拉框选择。点击新增记录，编辑标题和正文。
- 正文使用 Markdown 文本；例如输入 `- [ ] 待办事项`，再切换“待办”即可勾选。代码块中的示例清单不作为实际待办。
- 状态支持草稿、记录中、已完成、已归档，也可置顶。保存后的完成状态会同时出现在日历与列表中。
- 列表展示当前六周范围内的记录，以及无日期记录，按置顶和更新时间排列。日期和列表共享同一份数据。
- 点击“保存”或按窗口内的 `Ctrl+S` 保存；点击关闭或按 `Esc` 关闭窗口。全局 Mod / Super 快捷键不是核心流程的一部分。
- 删除需要在右侧明确确认，采用保留记录内容的软删除；软删除是给记录登记删除时间，并从普通视图隐藏，而不是立刻从存储文件清除内容。当前没有回收站界面。

**草稿保留边界：**切换日期、关闭再打开窗口时，尚未保存的输入保留在插件内存中；退出、禁用或重载 DMS 插件会结束这块内存。底部会显示未保存草稿数量，退出前请点击保存。当前采用明确保存，不自动保存到磁盘。

窗口跟随 DMS 明暗主题，最低支持 960×640。空数据、读取中、权限不足、存储失败、内容过期和版本冲突分别显示真实状态；不会用空列表掩盖失败，也不生成示例记录。

## 导入旧记录

点击“导入旧记录”，选择下列任意一种文件：

| 来源 | 要求 |
| --- | --- |
| 原应用 JSON 导出 | 文件的 `schema` 为 `localdesk.notes.export.v1` |
| 原应用数据库 | `notes.sqlite3`，数据库 `user_version` 为已核对的版本 3 |
| 本插件数据文件的副本 | 文件的 `schema` 为 `dms.todo.calendar.v1` |

原应用数据库的默认位置是 `~/.local/state/localdesk/notes.sqlite3`；设置 `XDG_STATE_HOME` 时使用该目录下的 `localdesk/notes.sqlite3`。文件选择器可显示隐藏目录，必要时在位置栏输入完整路径。

数据库通过只读连接读取，不修改原数据库，不接管原应用后台服务。导入保留记录编号、日期、正文、标签、状态、置顶、创建/更新时间、删除标记和记录版本；不迁移原应用的历史修订表或 AI 工作总结缓存。

记录编号是创建者为一条记录分配的 UUID，即用来区别不同记录的唯一编号；同一条记录的不同版本仍使用同一个编号。导入时，同编号、内容相同的记录会跳过；同编号、内容不同会使整次导入停止，保留原有插件数据，不自动覆盖，也不偷偷复制成新记录。单个记录无效、文件格式不符或源文件读取失败，同样不会写入半批数据。

单次导入及插件存储上限为 64 MiB、20,000 条记录；正文单条最多 4 MiB，标题最多 512 个字，最多 64 个标签，每个标签最多 64 个字。未知版本的原数据库需要先使用原应用导出 JSON。

## 数据与保存过程

默认数据文件是 `~/.local/state/dms-todo-calendar/notes.json`；设置 `XDG_STATE_HOME` 时改用该目录下的 `dms-todo-calendar/notes.json`。数据目录权限为 0700，数据与锁文件权限为 0600，仅当前用户访问。备份或移动时，先保存草稿并关闭日历，复制整个插件数据目录。

`CalendarSource.qml` 是界面调用后台的统一入口，由插件创建；它把操作编码成 JSON，通过标准输入传给 `todo-calendar-helper`，不将正文或路径拼入 shell 命令。辅助程序是随插件构建的本地 Go 进程，负责数据校验、读取、保存和导入；它与 DMS 常驻的界面入口不同，每次操作完成后就退出。

保存过程如下：

1. 新建草稿时，界面先分配稳定的记录编号。保存超时后用同编号、同内容重试，会回到第一次创建的记录，不重复新建；同编号携带不同内容会被拒绝。
2. 辅助程序取得 `flock` 文件锁。它是 Linux 提供的进程间锁，由每次调用的辅助程序取得，避免两个保存进程同时替换数据文件；等待最多两秒。
3. 读取当前磁盘内容并检查记录版本。版本是每次成功修改后递增的整数，由辅助程序维护，用于拒绝过期草稿覆盖最新内容；它与整个文件格式的 `schema` 版本不同。
4. 校验修改后的全部记录，将结果写到同目录临时文件、同步文件内容，再原子替换 `notes.json`，最后同步目录。原子替换表示读取者看到完整旧文件或完整新文件，不会看到写到一半的 JSON。
5. 若文件已替换但最后的目录同步失败，返回 `durability_unconfirmed` 与 `data.committed=true`，表示内容已可见，但断电后的持久性尚未确认。界面保留草稿并要求重新核对，避免把这种情况说成“确定未写入”或“已可靠保存”。

后台返回的能力状态保留 `healthy`、`degraded`、`unsupported`、`unreachable`，并附 `reason` 和中文说明。这里的状态描述当前操作能力；“记录中／已完成”等则是记录自身的业务状态，两者分别展示。

## 开发验证

只在本插件目录运行检查，不执行仓库其他插件的测试：

```bash
CGO_ENABLED=0 go test . -count=1
go vet .
node --test tests/calendar.test.cjs
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
  -input tests/tst_editor.qml -import tests/imports -o -,txt
bash -n build.sh install.sh
```

`main_test.go` 使用临时存储验证保存、冲突、删除、并发、导入原子性、只读 SQLite、重试去重、时间回拨、版本上限、损坏文件、符号链接和特殊文件输入。JavaScript 测试验证真实日期计算、清单标记与对象字段比较；QML 测试使用隔离的主题/图标和后台替身，验证实际编辑器组件的草稿切换、输入保留与保存回执。主题替身仅用于测试，不被安装脚本复制到用户插件目录。

构建脚本在 x86-64 下强制 `GOAMD64=v1 CGO_ENABLED=0`，其他架构沿用目标 `GOARCH`。可验证外部环境未将最低指令集抬高：

```bash
GOAMD64=v4 bash build.sh
go version -m todo-calendar-helper
```

QML 静态检查应使用 Qt 6 的 `/usr/lib/qt6/bin/qmllint`。独立检查器可能无法解析 DMS 运行时提供的 `qs.*` 模块；这些导入告警不等于实际加载失败，须同时核对 `dms ipc call plugin-scan status todoCalendar`、实际窗口和用户服务日志。

原实现参考 `pluggable-desktop-service/apps/desktop-ui/src/views/MemosView.vue`、`crates/notes/src/model.rs`、`crates/notes/src/migration.rs`、`crates/notes/src/export.rs`，以及 `journal_fetch.rs`、`journal_ai.rs` 和总结提示词资源。


## AI 工作总结

右侧“AI 总结”标签迁移了原应用的会话采集和日总结功能。这里的总结来源是当天的 AI 编程会话，生成内容包括今日工作、学到的知识、待办与风险、会话覆盖。运行它需要本机已安装并登录 Codex，以及 cc-switch 已同步的本地会话索引；日历、编辑、保存和导入不依赖这些 AI 环境。

1. 选择日期，点击“AI 总结”，先加载该日期已有缓存。
2. 点击“采集当天会话”，检查来源状态、纳入与忽略数量，以及 Token 用量。Token 是模型处理文本的计量单位；这些数值来自 cc-switch，不由模型估算。未知数值显示“未知”。
3. 点击“生成总结”。插件重新采集该日期语料，调用本机 Codex，沿用本机模型、提供商和登录配置。语料会发送给当前配置的模型提供商；调用最长约 8 分钟，可取消。生成期间仍可编辑笔记或切换日期，任务结果始终属于启动时的日期。
4. 检查总结，点击“追加到当天日志”。已有正文后添加分隔线和总结，不覆盖自定义标题，也不自动保存；最后在“正文”中检查并保存。多条当天记录时先打开需要追加的那条。

cc-switch 是用户安装的模型配置与会话索引工具；本插件仅以只读连接访问 `~/.cc-switch/cc-switch.db`。索引指向的 Codex 会话位于 `~/.codex/sessions`，Claude 会话位于 `~/.claude/projects`，OpenCode 数据库位于 `~/.local/share/opencode/opencode.db`。缺失来源保留 `unsupported`、`degraded` 等状态及原始原因，不自动搜索其他目录。

按系统本地 IANA 时区确定一天的开始和结束；IANA 时区是系统设置的地区规则名称，例如 `Asia/Shanghai`，包含夏令时变更规则。会话根据索引的更新时间归入当天，可能含跨日会话较早的上下文，与原功能一致。至少 4 条有效消息或 1,200 字才纳入总结；24 条或 12,000 字视为长会话。单条文本最多 16,000 字、单会话最多 64,000 字（超限优先保留最近消息和更正）、总语料最多 1,000,000 字、最多 64 个会话；截断会显示警告。生成前还会计算包含总结规则、会话元数据和 JSON 转义的完整输入长度，控制在 1,000,000 字符内，为 Codex 的单次 1,048,576 字符限制留出空间；超限时从较长会话的较早内容开始裁剪，保留最近更正，并更新覆盖状态及警告。路径必须位于固定来源目录，属于当前用户，不能是符号链接或特殊文件。对已知敏感字段逐行隐藏，但这不能替代用户对待发送内容的保密判断。

`CalendarJournal.qml` 是与笔记存储调用分开的 AI 任务入口，由日历窗口创建；它管理当前进程、按日期保留结果、超时与取消。`journal_collect.go` 负责只读采集和归一化来源；`journal_ai.go` 负责 Codex 调用与输出校验；`journal.go` 定义传递的数据结构和独立缓存。调用使用参数数组和标准输入，正文不会被拼入 shell 命令。Codex 使用结构化事件输出和独立的最终结果文件，避免普通模式回显整份语料。诊断只在内存保留最后 64 KiB，超量不会中断生成；错误按输入超限、认证、限流、额度、模型、输出格式和连接问题显示固定中文说明，不把原始服务端错误或凭据回显到界面。Codex 使用临时工作目录、只读沙箱、临时会话，禁用 shell、应用连接、已配置的 MCP 连接器、钩子、浏览器和多代理能力。MCP 连接器是用户为 Codex 配置的外部工具服务；它与发送文本给模型的模型提供商不同，总结流程保留后者的配置。

模型返回后，辅助程序校验日期、所有会话引用、结构化工作条目，且要求来源覆盖与完整 Token 对象与输入一致。移除用量正文后再次校验，并根据通过校验的结构化条目生成日志；“会话覆盖”段落由本地来源事实构建，无效输出不会追加进日志。知识条目可以作为总结内容和建议显示，但本插件不执行知识库写入。

AI 缓存位于插件数据目录下的 `journal/`，按日期和时区区分，文件权限 0600，目录 0700；它保存会话概览和通过校验的总结，不缓存完整对话。不同于日志正文，这些缓存可由重新采集替换。重新采集保留上次成功总结及其对应的来源快照，并显示旧结果的生成时间；只有新总结成功后才替换它，生成失败保留上次有效结果。AI 任务锁与笔记锁相互独立，长时间生成不会占用保存笔记的锁。

可直接打开 AI 标签并检查状态：

```bash
dms ipc call todoCalendar openAI
dms ipc call todoCalendar aiStatus
```

Go 的现有 `main_test.go` 还覆盖夏令时、来源缺失、敏感文本清洗、真实 SQLite 会话索引、语料截断与事实计数、缓存不包含原始消息、模型输出事实和引用校验、标准输入传递、进程取消。真实 Codex 生成验证仅在显式设置 `TODO_CALENDAR_LIVE_AI=1` 时运行，用隔离语料验证调用，不写业务日志：

```bash
TODO_CALENDAR_LIVE_AI=1 go test -run '^TestJournalLiveCodex$' -count=1 -v .
```
