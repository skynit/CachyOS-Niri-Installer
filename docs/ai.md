# AI 功能

这一层是**可选、全本地**的：用不用 agent、用哪一个都由你决定，桌面本身不依赖它。当前实现的能力：

| 能力 | 入口 | 默认安装 | 依赖 |
| --- | --- | --- | --- |
| 统一启动层 | ``Super+` `` → `cachyos-agent` | 是 | 至少一个 agent CLI |
| 按需提问 | `Super+\` → `cachyos-ask` | 是 | 选区/剪贴板，或 git 仓库 |
| 技能分发 | `cachyos-agent-skills` | 是 | agent 自身的技能目录 |
| 崩溃诊断 | `cachyos-crash-watch` + `cachyos-agent-crash` | 是 | `systemd-coredump` |
| OOM 诊断 | `cachyos-oom-watch` + `cachyos-agent-oom` | 是 | 内核 oom-kill、systemd-oomd、PSI 内存压力 |
| 用量统计与面板 | `cachyos-agent-usage-*` + DMS 插件 `cachyosAgents` | 是 | 本机 agent 会话记录 |
| 统一设置 | `cachyos-ai-settings` + DMS「AI 集成」面板 | 是 | 本项目命令与 DMS |
| 主题同步 | `cachyos-agent-theme-sync` | 是 | DMS 生成的配色文件 |
| 配置镜像 | `cachyos-ai-config-sync` | 是（有 CC Switch 时生效） | CC Switch 数据库 |
| 本地听写 | `cachyos-voxtype-*` | 否（可选组件，见 [voxtype.md](voxtype.md)） | Voxtype 与语音模型 |
| 跑完提醒 | `cachyos-agent-console` | 是 | 桌面通知（DMS 或 notify-send） |
| 跨工具会话续接 | `Super+Shift+\` → `cachyos-agent-resume` | 是 | 四个工具各自的会话存储 |

四条设计原则：

1. **不改 agent 本身**：只做启动包装、技能软链、状态读取与主题写入；不 patch 二进制，不改它自己的配置格式。
2. **凭据不进镜像**：写出的镜像只含非敏感的路由与路径，字段里凡匹配 token/secret/password/cookie/auth/credential/api-key 的键都会被过滤。但 `cachyos-ai-config-sync` 会**改写
   Codex 自己的 `~/.codex/auth.json`**（改前原样备份到 0700 的状态目录）——这是它唯一触碰凭据的地方。
3. **代码与状态分离**：命令在 `/usr/local/bin/cachyos-*`，随包资源在 `/usr/local/share/cachyos-desktop/assets/`，运行状态在 `~/.local/state/cachyos-desktop/`。
4. **单点失败不致命**：任一项失败只警告，不影响安装结果，也不影响桌面启动。

崩溃与 OOM 两条链路的细节见 [crash-oom.md](crash-oom.md)，用量统计见 [usage.md](usage.md)，
DMS 里的 AI 集成面板见 [dms-plugins.md](dms-plugins.md)。

## Agent 启动层

安装时会**自动确定默认 agent**：只探测到 1 个可用的 agent 就直接设为默认，按下 ``Super+` `` 立刻能用；
探测到多个则留空——第一次按会弹出选择器，选一次之后就被记住。

安装器把四个 AI 编程 agent 接成同一套入口，并自动带上各自的“无人值守”旗标——这些旗标每个
agent 都不一样，散落在快捷键里很难维护：

| agent | 包 / 形态 | 无人值守旗标 |
| --- | --- | --- |
| `opencode` | `opencode` | `--auto` |
| `claude` | `claude-code` | `--permission-mode auto` |
| `codex` | `openai-codex` | `--approve-for-me` |
| `dsh` | `dsh`（按 profile 启动的 harness） | 无——审批策略在 profile 里，命令层不掺和 |

`dsh` 的形态与前三个不同：**不带 prompt** 时进入交互 profile（默认 `dsh web`，可用
`CACHYOS_DSH_PROFILE` 换成别的，例如 `tui`）；**带 prompt** 时走 `dsh headless` 一次性模式，
答完就退出——所以它的窗口会**跑完留住**，否则答案一闪而过读不到。技能链接到 `~/.dsh/skills`。

**怎么改默认 agent**——三种方式等价，改完立刻生效（不用重启 Niri）：

```bash
cachyos-default-agent                 # 查看当前默认 agent（未设置时无输出）
cachyos-default-agent claude          # ① 直接设为某个 agent：codex / claude / opencode / dsh
cachyos-agent --pick                  # ② 弹选择器，选中即记住
$EDITOR ~/.config/cachyos-desktop/agent   # ③ 手工写文件名（0600，两端空白会被去掉）
cachyos-agent                         # 启动默认 agent；没有默认值时弹选择器
cachyos-agent --pick                  # 强制重新选择
cachyos-agent claude                  # 启动指定 agent
cachyos-agent --list                  # 列出支持的 agent 及安装状态
cachyos-agent-prompt "审查这个改动"     # 带一段 prompt 启动默认 agent
```

- 默认 agent 记在 `~/.config/cachyos-desktop/agent`（权限 0600）。这个文件可以手工改，
  读取时会去掉首尾空白；如果写的是不受支持的名字，会提示并转为重新选择，而不是直接报错。
  这个值也会被 AI 集成面板读写，与面板里的「设为默认」是同一份状态。
- 选择器在终端里就地运行；没有终端（例如快捷键触发）时开一个 Kitty 窗口跑 fzf，
  选择结果通过临时文件回传。按 `Esc` 取消则退出 1，不改动原默认值。
- 所有 agent 窗口共用 kitty class `cachyos-agent`；这样一条窗口规则或主题就能覆盖全部
  agent 窗口，不必每个 agent 各写一条（项目本身目前没有为它写规则）。
  从快捷键启动会开新窗口；在终端里加 `--inline` 直接在当前终端运行。
- 四个 agent 的 `-p`/`--help` 之类参数不会被误当成选项：`claude`、`codex`、`dsh` 的 prompt
  统一用 `--` 分隔（`opencode` 走自己的 `--prompt`）。prompt 里的换行、引号、反斜杠、
  `$`、制表符都原样传给 agent。

## 按需提问：cachyos-ask

`Super+\` 会把**手边的东西**直接交给默认 agent：选中的文字 → 主选区，复制的报错/日志 →
剪贴板，`commit` / `review` 动作在没有文本时自动改用**当前仓库的暂存改动**。选完动作就开新
Kitty 窗口，agent 带着这段上下文起来——省掉“复制 → 切窗口 → 粘贴 → 补一句要求”。

```bash
cachyos-ask                       # 弹动作选择器（解释/排查/审查/总结/翻译/提交信息/转命令）
cachyos-ask --action fix          # 直接指定动作，对剪贴板里的报错用
cachyos-ask --action shell "找出占用 8080 的进程并杀掉"
cachyos-ask --action review       # 无文本时用 git diff --cached
cachyos-ask --print --action explain "一段文字"   # 只打印将发送的 prompt，不启动 agent
cachyos-ask --agent codex --action commit         # 指定用哪个 agent
```

| 动作 | 做什么 |
| --- | --- |
| `explain` | 解释这段在做什么、关键点与坑 |
| `fix` | 定位报错原因 + 可执行的修复步骤 |
| `review` | 审查改动里的真问题，按严重程度排序 |
| `summarize` | 用中文总结，保留关键事实与数字 |
| `translate` | 翻成自然的中文技术表达 |
| `commit` | 按暂存改动写一条规范的提交信息 |
| `shell` | 把一句话转成可执行的 bash 命令 |

### 改提示词、加自己的动作

这 7 个动作的提示词都在一个用户可编辑的文件里，安装时会给你一份带内置默认值的起始副本：

```text
~/.config/cachyos-desktop/ask-actions.conf
```

格式是每行「动作名<TAB>提示词」：

```conf
# 覆盖内置动作：位置和顺序不变，只换它发出去的提示词
fix	下面这段输出出错了。先给结论，再用中文给出可直接执行的修复步骤。

# 新增动作：id 自己起，会追加到选择器末尾
security	审查下面的代码有没有安全漏洞，按可利用性排序。
```

改完重开一次 `cachyos-ask` 即生效。同样的内容也可以在 DMS「AI 集成」面板里编辑（见下文）。

| 情况 | 行为 |
| --- | --- |
| 动作名是那 7 个之一 | 覆盖它的提示词；选择器里的位置、顺序不变 |
| 动作名是新的 | 追加成新动作，可用 `--action <新名字>`，也出现在选择器末尾 |
| 文件不存在 | 完全用内置默认（删掉这个文件就是“恢复默认”） |
| 文件里某行格式不对 | 跳过那一行并提示行号，**其余行照常生效**——写坏一处不会让命令用不了 |
| 重跑安装器 | 不会覆盖这个文件（它是你的配置，不是受管文件） |

`cachyos-ask --list-actions` 会列出当前生效的全部动作（含你新增的），一行一个 id，便于脚本化核对。

**同一天复用同一个会话**（默认行为）。问一问基本都是同一上下文里的连续追问——同一个报错、同一段代码，
每次新开会话会让 agent 丢掉前文。所以它会找该 agent **当天最近的那个会话**，带着新问题继续问：

| 情况 | 行为 |
| --- | --- |
| 当天已有该 agent 的会话 | 续接它（`claude --resume` / `codex resume` / `opencode --session` / `dsh headless --session-id`） |
| 最近会话是过去的日子 | 开新会话 |
| 换了 agent，或还没设默认 agent | 开新会话（没默认值时先弹选择器） |
| 加了 `--new`，或 `CACHYOS_ASK_SESSION=new` | 强制开新会话 |

会话判断复用 `cachyos-agent-resume` 的枚举（它已经读遍四个工具的存储、且有测试），这里不重复解析任何存储格式。

`--show` 只打印将要执行的命令，便于确认它是续接还是新开：

```bash
cachyos-ask --show --action explain "这段代码什么意思"
```

文本上限 `CACHYOS_ASK_MAX_CHARS`（默认 12000）会截断并注明，避免把 agent 的上下文一次冲爆。

## 跨工具会话续接：cachyos-agent-resume

`Super+Shift+\` 把四个 agent 最近的会话按时间列成一张表——**相对时间、目录、提示数、标题**，
选中即续接。这是单个 CLI 给不了的：它们各自只看自己的会话，续接语法也各不相同。

```bash
cachyos-agent-resume                            # 弹选择器（fzf），选中直接续接
cachyos-agent-resume --list                     # 只输出表格（TAB 分隔，便于脚本与自检）
cachyos-agent-resume --agent codex --limit 5    # 只看某个 agent / 每人几条
cachyos-agent-resume --show claude <会话 id>    # 只打印将要执行的命令，不启动
cachyos-agent-resume --inline                   # 在当前终端运行（默认另开 Kitty 窗口）
```

读取的存储都是**轻量索引，绝不遍历会话正文**——codex 的 `sessions` 目录本机有 1.6GB，
扫一遍就不堪用了：

| agent | 读什么 | 提示数怎么来 |
| --- | --- | --- |
| claude | `~/.claude/projects/**/*.jsonl`（按 mtime 取前 N） | 数 `type=user` 行，并扣除工具结果行 |
| codex | `~/.codex/session_index.jsonl` + rollout 首行的 `cwd` | 数 `history.jsonl` 里属于该会话的行 |
| opencode | `~/.local/share/opencode/opencode.db`（sqlite3 只读） | `message.data` 里 `role=user` 的条数 |
| dsh | `~/.dsh/storages/session_projcache/sessions/*.json` | 解压会话文件数 `kind=user` 事件 |

续接命令由 agent 表统一构造：`claude --permission-mode auto --resume <id>`、
`codex --approve-for-me resume <id>`、`opencode --auto --session <id>`。

> **dsh 的续接（更正）**：它的 `web` profile 不接受 `--resume`，所以**选择器**里的 dsh 条目会打开
> Web UI 让你在其中挑会话；但 `headless` profile 可以用 `--session-id` **采纳既有会话**——
> `cachyos-ask` 的同天复用正是走这条路（`dsh headless --session-id <id> "<问题>"`）。
> 也就是说“dsh 没有命令行续接”只对 web profile 成立，之前那句话写窄了。

## 跑完提醒：cachyos-agent-console

agent 都在自己的 Kitty 窗口里跑，长任务时人早就切走了。`cachyos-agent` 的新窗口模式现在套一层
包装：**跑完发一条桌面通知**（长任务或失败时），**失败时窗口不关**，让你能直接读到报错。

打扰程度可配 `~/.config/cachyos-desktop/agent-notify`：

```text
auto    默认：超过 15 秒或失败才提醒
always  每次结束都提醒
off     不提醒
```

阈值可用 `CACHYOS_AGENT_NOTIFY_MIN_SECONDS` 覆盖（例如设为 0 便于自检），也可以用
`CACHYOS_AGENT_NOTIFY_MODE` 直接覆盖模式。这些值也会显示在 AI 集成面板里并可由面板改写。

## Agent 技能

安装器把三份技能软链到各 harness 的技能目录，让 agent 知道这套桌面该怎么改：

- `cachyos`：Niri、DMS、`cachyos-*` 命令的正确用法，以及“哪些配置受安装器托管、
  改前要先 `cachyos-config protect`”。
- `diagnose-crash`：如何从 `coredumpctl` 事实判断崩溃该归因于用户配置还是上游 bug。
- `diagnose-oom`：如何从内核 oom-kill、systemd-oomd 与 PSI 内存压力事实判断是谁吃光了内存，
  以及该调应用、调 systemd-oomd 还是加 swap。

只为**已存在**的技能目录建立软链（`~/.agents/skills`、`~/.claude/skills`、`~/.codex/skills`、
`~/.gemini/config/skills`、`~/.pi/agent/skills`、`~/.hermes/skills` 及每个已存在的
`~/.hermes/profiles/*/skills`、`~/.cc-switch/skills`、`~/.dsh/skills`），绝不创建 harness 目录。
安装时、首次登录以及每次 `cachyos-agent` 启动前各同步一次——最后这个时机最可靠，
因为那时 harness 目录才确实存在。手动重跑：

```bash
cachyos-agent-skills
cachyos-agent-skills --harness codex   # 只同步某一个 harness
```

技能源码在 `assets/agent-skills/`，安装后位于 `/usr/local/share/cachyos-desktop/assets/agent-skills/`；
面板里的“链接系统技能”执行的是同一个命令。

## AI 集成面板

DMS 原来的「AI agent 用量」插件现在叫 **AI 集成**，插件 ID 仍为 `cachyosAgents`，无需重新添加栏位。
弹窗默认显示用量，**顶部的调节图标切到设置**，返回箭头回到用量（不再使用「用量 / 设置」双标签）。
DMS 设置 → 插件 → AI 集成也提供完整设置。

- 默认 Agent（包括尚无用量记录的已安装工具）、DSH 启动界面。
- 任务结束通知模式与长任务阈值。
- 「问一问」的会话复用、文本上限、内置提示词编辑、自定义动作新增与删除。
- 崩溃/OOM 捕获开关及运行状态、重复通知间隔、通知中的诊断操作、程序忽略正则。
- PSI 内存压力提前预警开关、阈值和采样间隔。
- Agent 主题自动同步、后台用量采集开关，以及手动同步主题/链接系统技能。
- 应用 CC Switch 当前的 Codex 服务商配置（复用现有同步命令，写入前自动备份）。
- 原有 token、费用、模型明细与趋势图保持不变；状态栏显示选项仍在插件设置中。

设置写入 `${XDG_CONFIG_HOME:-$HOME/.config}/cachyos-desktop/ai-settings.conf`；通知模式仍用
`agent-notify`，提示词仍用 `ask-actions.conf`。这些用户配置不受安装器托管，重装不覆盖。
显式环境变量优先于面板保存值；启动/提问设置在下次执行时生效，监听设置保存后只重启对应的
运行中 watcher，不会启动已关闭的监听。开启诊断操作表示提供可点击的通知，**不会自动向 AI 发送日志**。
服务操作失败会直接显示错误，不会假装成功。

命令行接口（同一份数据）：

```bash
cachyos-ai-settings state
cachyos-ai-settings set CACHYOS_ASK_SESSION new
cachyos-ai-settings set notify-mode auto
cachyos-ai-settings service oom on
cachyos-ai-settings prompt-set explain '用三句话解释下面的内容。'
cachyos-ai-settings prompt-reset explain
```

## 配置镜像（可选）

装了 **CC Switch**（`~/.cc-switch/cc-switch.db` 存在）时，`cachyos-ai-config-sync` 会在
Codex Desktop 与 CC Switch 之间生成一份**非敏感**配置镜像，避免两边的手工配置互相覆盖：

```bash
cachyos-ai-config-sync status   # 看当前镜像状态
cachyos-ai-config-sync backup   # 手动备份
cachyos-ai-config-sync sync     # 重新生成镜像
```

| 读取 | 写入 |
| --- | --- |
| `~/.cc-switch/cc-switch.db`（仅非敏感路由字段） | `~/.config/codex-desktop/cc-switch-sync.json` |
| `~/.codex/config.toml` | `~/.cc-switch/codex-desktop-sync.json` |
| `~/.config/codex-desktop/settings.json` | `~/.local/state/cachyos-ai-config/`（状态与备份） |

写入的两个镜像文件都会**过滤敏感键**：字段名匹配 `token`/`secret`/`password`/`cookie`/`auth`/
`credential`/`api-key`/`private-key` 的键不会出现在镜像里。

需要如实说明的是：`sync` 为了切换 Codex provider，会**改写 Codex 自己的 `~/.codex/auth.json`**
（只更新其中的 provider 认证块）。改动前它会把 `cc-switch.db`、`codex-desktop/settings.json`、
`~/.codex/config.toml` 和 `~/.codex/auth.json` **原样备份**到
`~/.local/state/cachyos-ai-config/backup-*/`（目录权限 0700，用于回滚）。真实 API 凭据只写入权限
为 `600` 的 `~/.codex/auth.json`，不会写入镜像或日志。

如果你不希望脚本碰 `~/.codex/auth.json`，就不要运行 `cachyos-ai-config-sync sync`；安装器只在
`~/.cc-switch/cc-switch.db` 存在时才会调用它，不存在时跳过并提示。

Codex Desktop 使用当前系统采用的 AUR `codex-desktop-git` 包，Codex CLI 使用仓库中的
`openai-codex`。可用以下命令检查桌面包与构建来源：

```bash
pacman -Qi codex-desktop-git
codex-desktop --version 2>/dev/null || true
jq '.source' /opt/codex-desktop/.codex-linux/build-info.json
```

## 新增一个 agent

旗标集中在一处：`assets/lib/agent.sh`。加一个 agent 需要同时改三处——该文件的
`cachyos_agent_supported`/`cachyos_agent_name`/`cachyos_agent_command`
（必要时还有 `cachyos_agent_skill_relpaths`）、`packages.sh` 里的包、以及
`tests/agent-test.sh` 的断言。

技能会链到**已存在**的 harness 目录（不替用户凭空创建目录）。但全新机器上 `.claude`/`.codex` 往往还不存在
（CLI 装了、用户还没跑过），于是安装器与首次登录初始化都会带 `--create-supported`：只为**目录位置确定
且该 CLI 已安装**的 agent（claude/codex）建目录再链接；opencode 的 `.agents/skills` 是“尽力而为”位置，
不凭空创建。

## 数据、隐私与网络

本层**没有自己的服务端**，全部在本机完成。读取的内容：

| 读取 | 用途 |
| --- | --- |
| `~/.claude/projects/**`（Claude Code 会话 JSONL） | 用量统计 |
| `~/.codex/sessions/**`（Codex 会话） | 用量统计 |
| `~/.dsh/sessions/**`（zstd 压缩的会话日志） | 用量统计 |
| `~/.cache/DankMaterialShell/dms-colors.json` | 主题同步 |
| `~/.codex/auth.json`（只用于更新 provider 认证块） | 配置镜像 |
| `systemd-coredump` 的记录 | 崩溃诊断 |
| 内核 `oom-kill`、systemd-oomd 日志与 PSI 内存压力 | OOM 诊断 |

写出的内容：

| 写入 | 用途 |
| --- | --- |
| `~/.local/state/cachyos-desktop/agents/usage/*.json` | 各 agent 的用量记录与增量缓存 |
| `~/.local/state/cachyos-desktop/agents/last-crash` | 最近一次崩溃（供 `cachyos-agent-crash` 读取） |
| `~/.local/state/cachyos-desktop/agents/last-oom` | 最近一次 OOM（供 `cachyos-agent-oom` 读取） |
| `~/.local/state/cachyos-desktop/agents/crash-muted.txt` | 崩溃静音名单 |
| `~/.local/state/cachyos-desktop/post-login.log` | 首次登录初始化日志 |
| `~/.claude/themes/cachyos.json`、`~/.hermes/skins/cachyos.yaml` | 主题产物 |
| `~/.config/codex-desktop/cc-switch-sync.json`、`~/.cc-switch/codex-desktop-sync.json` | 配置镜像（敏感键已过滤） |
| `~/.codex/auth.json` | 同步时更新 provider 认证块（改前备份） |
| `~/.local/state/cachyos-ai-config/backup-*/` | 上述文件的回滚备份（0700，含 `auth.json` 原文件） |

**唯一的联网行为**是查询 Claude 的限额：

```text
https://api.anthropic.com/api/oauth/usage
```

它复用本机已有的 Claude Code OAuth 凭据做只读查询（失败不影响本地统计），Codex 与 DSH 的采集
完全不联网。可选的本地听写会在你执行 `cachyos-voxtype-model` 时下载语音模型。

用量采集的语义边界（各家 agent 的 input 是否含缓存、费用从哪来）见 [usage.md](usage.md)。

## 故障排查

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| 状态栏显示 `—` | 该 agent 还没有本地记录 | 用一次 agent 后等定时器（登录后 2 分钟、之后每 15 分钟），或手动 `cachyos-agent-usage-update --force` |
| 面板里没有我在用的 agent | 面板只登记 `claude`/`codex`/`opencode`/`dsh` | 见「新增一个 agent」 |
| ``Super+` `` 每次都弹选择器 | 没设默认 agent，或记录里的名字已失效 | `cachyos-default-agent codex` |
| agent 里没有 `cachyos` 技能 | 对应 harness 目录首次运行才生成 | `cachyos-agent-skills --create-supported` |
| 崩溃没有通知 | 总开关关闭 / 程序在静音名单 / 还在去重窗口内 | 见 [crash-oom.md](crash-oom.md) |
| OOM 没有通知 | OOM 捕获总开关关闭（`oom-capture-off`） | 见 [crash-oom.md](crash-oom.md) |
| 明暗切换后 agent 主题没变 | `theme.path` 单元未启用，或配色文件缺失 | `systemctl --user status cachyos-agent-theme.path`、`cachyos-agent-theme-sync --status` |
| 没有 `cachyos-voxtype-*` 命令 | 听写是可选组件，未安装 | 见 [voxtype.md](voxtype.md) |
| 面板设置保存后没生效 | 启动/提问设置下次执行才生效；监听设置只重启对应 watcher | 重新执行一次命令；用 `cachyos-ai-settings state` 核对 |

## AI 命令速查

| 命令 | 作用 |
| --- | --- |
| `cachyos-agent [<agent>]` | 启动默认或指定 agent；`--inline` 当前终端、`--pick` 重选、`--list` 列出、`--validate <id>` 校验 |
| `cachyos-agent-prompt [--inline] <prompt...>` | 带一段 prompt 启动默认 agent |
| `cachyos-ask [--action <名>] [--agent <id>] [--print] [--show] [--new] [--inline] [--list-actions] [<文本...>]` | 把选区/剪贴板/暂存改动交给 agent（提示词见 `~/.config/cachyos-desktop/ask-actions.conf`，可改可加） |
| `cachyos-agent-console [--hold] <agent> <命令...>` | 跑 agent 并在结束后通知（由启动器自动调用） |
| `cachyos-agent-resume [--agent <id>] [--limit <n>] [--list] [--show <agent> <id>] [--inline]` | 跨工具列出最近的会话并续接 |
| `cachyos-default-agent [<agent>]` | 查看或设置默认 agent |
| `cachyos-agent-skills [--quiet] [--harness <agent>] [--create-supported]` | 建立技能软链 |
| `cachyos-ai-settings state / set KEY VALUE / service ID on/off / prompt-set ID TEXT / prompt-reset ID` | 读写 AI 集成设置（与 DMS 面板同一份数据） |
| `cachyos-agent-usage-update [--force] [--limits-only] [--except <agent>] [agent...]` | 重算用量（`--limits-only` 只刷限额） |
| `cachyos-agent-usage-claude` / `-codex` / `-dsh` | 单个采集器，支持 `--force`、`--limits-only` |
| `cachyos-crash-watch` | 崩溃监听（由 systemd 用户单元拉起，一般不用手跑） |
| `cachyos-agent-crash <pid> [comm] [exe] [signal]` | 把一次崩溃交给 agent 分析 |
| `cachyos-crash-mute [<program>] [off]` | 静音某个程序，或取消静音 |
| `cachyos-toggle-crash-capture [toggle/off/on]` | 崩溃捕捉总开关 |
| `cachyos-oom-watch` | OOM 与内存压力监听（由 systemd 用户单元拉起，一般不用手跑） |
| `cachyos-agent-oom --latest` | 把最近一次 OOM 交给 agent 分析 |
| `cachyos-toggle-oom-capture [toggle/off/on]` | OOM 捕捉总开关 |
| `cachyos-agent-theme-sync [--dry-run] [--quiet] [--status]` | 同步明暗与完整配色 |
| `cachyos-ai-config-sync status/backup/sync` | 查看、备份或重建 AI 配置镜像 |
| `cachyos-voxtype-install` / `-model` / `-config` / `-status` / `-toggle` / `-remove` | 本地听写（见 [voxtype.md](voxtype.md)） |
