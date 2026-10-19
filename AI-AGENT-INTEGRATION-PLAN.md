# 说明

本文是**设计与移植计划**，记录当时为什么这么决定。实现过程中若干细节已经演进：

- 文档里的**行号引用**是写计划时的快照，后续改动会让它们偏移，以代码为准。
- 被列为“本轮不做”的条目（用量面板、voxtype 听写、主题同步）后来都做了，见根 `README.md` 与 `docs/` 模块文档。
- 少数假设已被实测推翻，正文与实施记录里都标注了，例如：Niri 不支持按键释放绑定，
  所以按住说话改成了 toggle；无参数的 dms ipc call plugin-scan rescan 是空操作。

# AI Agent 集成移植计划（P0）

把 Omarchy 的 AI agent 集成层移植到本项目。本轮只做 **P0：启动层 + 技能层 + 诊断层**，不交付任何 UI。

- 状态：**待实施**（决策已全部确认，见附录 B；自审见附录 C）
- 范围：P0
- 上游参考：`omacom/omarchy`（`bin/omarchy-agent`、`bin/omarchy-default-agent`、`bin/omarchy-agent-prompt`、`bin/omarchy-crash-watch`、`bin/omarchy-agent-crash`、`default/agents/skills/**`）
- 设计原则：不引入第二套包管理器、不引入 Omarchy 的更新管线、不改变本项目现有行为，只做增量。

## 1. 目标

让本项目安装出的系统具备三个能力：

1. **一个入口启动任意 AI 编程 agent**，并自动带上各自的"无人值守"旗标（现在这些旗标散落在快捷键、别名和个人记忆里）。
2. **把本项目自身的知识交给 agent**：niri/DMS/`cachyos-*` 的用法作为 agent skill 自动分发到各 harness 的技能目录。
3. **崩溃可诊断**：进程 segfault 后能一键把核心转储信息交给默认 agent 分析。

## 2. 范围

### 2.1 本轮交付（P0）

| 编号 | 交付物 | 说明 |
| --- | --- | --- |
| P0-1 | 默认 agent 选择 + 权限模式映射 | `cachyos-agent` / `cachyos-default-agent` / `cachyos-agent-prompt` |
| P0-2 | agent skill 软链分发 | `cachyos-agent-skills` + `assets/agent-skills/**` |
| P0-3 | 崩溃 → agent | `cachyos-crash-watch` / `cachyos-agent-crash` / `cachyos-crash-mute` + systemd user unit |

### 2.2 已决策但不在本轮

| 决策 | 内容 | 影响本轮的部分 |
| --- | --- | --- |
| 命名空间 | 配置 `~/.config/cachyos-desktop/`，状态 `~/.local/state/cachyos-desktop/` | 立即生效 |
| agents 用量 UI | **以 DMS 插件形式实现**（不是 Waybar 模块），后续阶段交付 | 本轮不建任何 UI；但数据目录、命令前缀、插件 id 预留命名，避免将来改名 |

预留命名（本轮不实现，只登记）：

- 插件目录：`~/.config/DankMaterialShell/plugins/cachyos-agents/`，`plugin.json` 的 `id` 为 `cachyosAgents`
- 用量采集命令：`cachyos-agent-usage-<agent>`、聚合命令 `cachyos-agent-usage-update`
- 用量记录目录：`~/.local/state/cachyos-desktop/agents/usage/<agent>.json`
- 插件契约参照已装的 `~/.config/DankMaterialShell/plugins/LocalStatus/plugin.json`（`type: widget`、`capabilities: ["dankbar-widget"]`、`requires_dms: ">=1.5.3"`）

### 2.3 明确不做

| 不做 | 原因 |
| --- | --- |
| Omarchy 的 `pacman` pre-transaction guard、`omarchy update` 管线 | 与本项目 `cachyos-system-update`、`cachyos-config migrate` 冲突 |
| Omarchy 的每用户迁移系统 | 本项目已有 `cachyos-config migrate` + marker 模式 |
| Omarchy CLI 路由器（元数据头 + 最长前缀 + 470 命令） | 本项目 48 个显式 helper + `verify.sh` 循环是更合适的规模 |
| mise stub 机制 | 本项目已用 pacman/AUR 装 agent，不引入第二套包管理器 |
| voxtype 听写、主题同步到 agent、用量面板 | 属 P2/P3，本轮不做 |

## 3. 已核实的事实

以下结论均由实测得出，实施时不必重新验证。

### 3.1 三个 agent 的无人值守旗标（本机实测）

| agent | 包（本项目 `packages.sh`） | 旗标 | 实测证据 |
| --- | --- | --- | --- |
| `opencode` | `opencode` | `--auto` | `--auto  Auto-approve permissions that are not explicitly denied`；prompt 用 `--prompt string` |
| `claude` | `claude-code` | `--permission-mode auto` | `--permission-mode <mode>`，choices 为 `acceptEdits / auto / bypassPermissions / manual / dontAsk / plan` |
| `codex` | `openai-codex` | `--approve-for-me` | `Route approval requests through automatic review using the workspace-write sandbox` |

prompt 传递方式实测：

- `claude` 与 `codex` 接受位置参数 prompt，且 `--` 分隔**已验证可用**；`opencode` 只接受 `--prompt`。
- `codex -- <prompt>` 的证据（用非法旗标当探针，`--` 之后它被当作 prompt 消费）：

  ```
  $ codex --approve-for-me --bogus-flag-xyz
    error: unexpected argument '--bogus-flag-xyz' found
      tip: to pass '--bogus-flag-xyz' as a value, use '-- --bogus-flag-xyz'
    exit=2
  $ codex --approve-for-me -- --bogus-flag-xyz
    Error: stdin is not a terminal
    exit=1
  ```

  第二条越过了参数解析、直接到 TTY 检查，说明 `--` 生效。

- `codex` 还有 `--dangerously-bypass-approvals-and-sandbox`，本项目**不使用**：`--approve-for-me` 保留沙箱，是更合适的档位。
- 实测 `opencode --help` 需要可写的 `$HOME`（要写 `~/.local/share/opencode/log/`），验证时用临时 HOME。

### 3.2 DMS 插件机制（本机实测，DMS 1.6.2）

| 事实 | 证据 | 对计划的影响 |
| --- | --- | --- |
| 插件以目录形式存在于 `~/.config/DankMaterialShell/plugins/<dirname>/` | 已装 `LocalStatus`、`localTranslate`、`localLyrics` | 插件用文件部署，不依赖 registry |
| `plugin.json` 字段 | `LocalStatus/plugin.json`：`type`、`capabilities`、`component`、`settings`、`requires_dms`、`permissions` | 未来插件的契约模板 |
| 运行时热加载 | `dms ipc call plugin-scan rescan`（`dms ipc --help` 列出 `plugin-scan: list/reload/rescan/scan/status`，`plugins: disable/enable/list/reload/status/toggle`） | 部署后无需重启 shell |
| 离线查询已加载插件 | `dms ipc call plugins list` → `localLyrics [loaded]` 等 | 可直接用于 `verify.sh` 断言 |
| `dms plugins list` / `dms plugins install` | 实测 60 秒未返回（依赖上游 registry 网络） | **安装器禁止调用**，一律文件部署 |

### 3.3 桌面会话的 systemd 事实（决定了 P0-3 的挂载方式）

| 事实 | 证据 | 结论 |
| --- | --- | --- |
| `niri.service` 由 niri 包提供 | `pacman -Ql niri` → `/usr/lib/systemd/user/niri.service` | 用户会话的锚点是 `niri.service` |
| DMS 挂到 niri 上，**不是** `graphical-session.target` | `~/.config/systemd/user/niri.service.wants/dms.service` 存在；该 wants 由 `install.sh:657` 的 `add-wants niri.service dms.service` 创建 | 新 unit 必须沿用同一模式 |
| 未见 `graphical-session.target` 被本桌面使用 | 沙箱内无法查询 bus；仓库内无任何引用 | 不用 `WantedBy=graphical-session.target` |

### 3.4 快捷键事实（决定默认 agent 的按键）

niri 里 **`Mod` 和 `Super` 是同一个键**，两种拼写等价。`assets/niri/binds.kdl` 中：

- 26 个字母**全部被占用**（`A`–`Z`）。特别注意 `Super+X`（第 240 行，电源菜单）等价于 `Mod+X`，所以 `Mod+X` **不空闲**——这是最容易误判的一个键。
- 数字 `1`–`9`、方向键、`Space`、`Slash`、`Return`、`Escape`、`Comma`、`Period`、`Minus`、`Equal`、`Home`、`End`、`Page_Up`、`Page_Down`、`BracketLeft/Right`、`Mouse*`、`WheelScroll*`、`XF86*`、`F1/F2/F3/F5/F8` 均已被 plain `Mod+` 占用。
- 实测空闲的两键组合：`Mod+grave`、`Mod+BackSpace`、`Mod+Delete`、`Mod+Tab`、`Mod+Backslash`、`Mod+apostrophe`、`Mod+semicolon`、`Mod+Insert`、`Mod+Menu`、`Mod+F4/F6/F7/F9/F10/F11/F12`。

**已选：`Mod+grave`（`Super` + `` ` ``）**。理由：单手可及、无任何现有绑定、不冲突 fcitx5（输入法用的是 `Mod+Space` / `Ctrl+Space`）。
**备选：`Mod+BackSpace`**。
**避开 `Mod+F9`**：留给 P3 的 voxtype 按住说话（与上游 Omarchy 的 F9 一致）。

### 3.5 本项目既有约定与接线点（行号已核对）

| 约定 | 位置 | 约束 |
| --- | --- | --- |
| `bin/*` 全量安装到 `/usr/local/bin` | `install.sh:434-437`（`install_desktop_assets`） | 新增 helper 不能是私有库文件 |
| `verify.sh` 遍历 `bin/*` 逐个检查命令存在 | `verify.sh:217-220` | 新 helper 上不了 PATH 即 FAIL |
| `assets/**` 全量安装到 `/usr/local/share/cachyos-desktop/assets/**` | `install.sh:504-513` | 静态资源（含 skill、lib）无需新增安装路径 |
| `$HOME` 文件在 `install_desktop_assets` 中**按名字逐条**安装 | `install.sh:439-482` | **只加 manifest 行不会把文件装进 `$HOME`**，必须同时加显式 `install` 行 |
| `assets/config-manifest.tsv` 是 `$HOME` 配置清单 | `cachyos-config`（`status`/`update`/`migrate`/`protect`） | 落 `$HOME` 的新文件必须登记；登记后 `verify.sh:252` 会自动检查其存在 |
| manifest 本身只被复制到 share 目录，安装期不读它 | `install.sh:514` | 见上一条 |
| 变更命令走 `run()` 才受 `--dry-run` 保护 | `install.sh:91-97` | 所有新命令必须走 `run` |
| 安装步骤在 `main()` 中串行 | `install.sh:663-713`；`install_desktop_assets`=692、`sync_ai_configs`=694 | 新步骤插在 692 之后、694 之前 |
| 用户态服务在 `post_install()` 启用 | `install.sh:649-661`（`daemon-reload` + `add-wants niri.service dms.service`，失败只 warn） | 新 unit 的挂载加在这里，沿用 warn 模式 |
| `preflight` 在装包**之前**运行 | `install.sh:143-171` | 不能把非基础系统的命令（如 `jq`）加进必需列表 |
| 硬件判定是纯函数 + `CACHYOS_*` 数组 | `hardware.sh`，测试 `tests/hardware-test.sh` | 纯逻辑必须可单测 |
| 幂等用 marker 文件 | `bin/cachyos-post-login-setup` | 新的一次性步骤沿用此模式 |
| niri 条件引入 | `assets/niri/config.kdl:270-277`（`include optional=true`） | 将来条件生效的配置用这个机制 |
| 现有 agent 快捷键 | `assets/niri/binds.kdl`：`Mod+Alt+O` → `kitty --class opencode -e opencode`；`Mod+Alt+C` → `kitty --class claude -e claude` | 本轮改这两个的入口与 class |
| binds 引用的校验模式 | `verify.sh:227` `grep -Fq "spawn \"$helper\"" .../binds.kdl` | 新校验照抄这个模式 |
| 已安装的 niri 资产必须与源文件逐字节一致 | `verify.sh:262-275`（`cmp -s`） | 改 `binds.kdl` 后必须重跑 `install.sh` 或 `cachyos-config update` |
| 无窗口规则引用 agent 的 kitty class | `grep -iE 'opencode\|claude\|class' assets/niri/config.kdl` 无匹配 | 统一 class 不会破坏现有规则 |
| 仓库风格 | `#!/usr/bin/env bash`、`set -Eeuo pipefail`、4 空格、中文提示 | Omarchy 脚本是 `#!/bin/bash` + 2 空格 + 英文，**不可直接拷贝** |

### 3.6 依赖与现状

| 项 | 状态 |
| --- | --- |
| `jq`、`python`、`libnotify`、`fzf`、`shellcheck` | 均在 `packages.sh`（`DAILY_APP_PACKAGES` / `SYSTEM_TOOL_PACKAGES` / `DEVELOPMENT_PACKAGES`） |
| `journalctl`、`coredumpctl` | 本机可用；`systemd-coredump.socket` 为 `static` |
| `~/Work` | **本项目不创建**（`grep -rn Work` 仅命中注释与 "Rename Workspace"），因此 `cachyos-agent` 只在 `~/Work` 已存在时才 `cd` |
| `~/.config/cachyos-desktop` | 本机尚不存在，无冲突 |
| 本机 harness 技能目录 | 存在：`~/.claude/skills`（1 项）、`~/.codex/skills`（54 项）、`~/.cc-switch/skills`（36 项）；不存在：`~/.agents/skills`、`~/.gemini/config/skills`、`~/.pi/agent/skills`、`~/.hermes/skills` |
| 测试运行器 | **无**。`tests/hardware-test.sh` 没有被任何脚本或文档引用，属于未接线状态（见附录 C 修复 5） |

## 4. 命名空间与路径约定

| 用途 | 路径 |
| --- | --- |
| 默认 agent 名 | `~/.config/cachyos-desktop/agent` |
| 崩溃静音名单 | `~/.local/state/cachyos-desktop/agents/crash-muted.txt` |
| 最近一次崩溃（降级入口用） | `~/.local/state/cachyos-desktop/agents/last-crash` |
| 幂等标记 | `~/.local/state/cachyos-desktop/<name>-v1` |
| 随包静态资源 | `/usr/local/share/cachyos-desktop/assets/**` |
| 共享函数库 | `/usr/local/share/cachyos-desktop/assets/lib/agent.sh` |
| systemd user unit | `~/.config/systemd/user/cachyos-crash-watch.service` |

约定：状态一律在 `~/.local/state/cachyos-desktop/`（与既有 `post-login-setup` 一致），只有用户可版本化的配置才进 `~/.config/cachyos-desktop/`。

## 5. 详细设计

### 5.1 P0-1：agent 表与启动层

#### `assets/lib/agent.sh`（纯函数库，无 I/O）

单一事实来源，经 `install.sh:504-513` 的既有循环自动落位到 `/usr/local/share/cachyos-desktop/assets/lib/agent.sh`。定义：

```bash
# 窗口 class：所有 agent 共用一个，便于窗口规则与主题统一命中
readonly CACHYOS_AGENT_WINDOW_CLASS="cachyos-agent"

# 支持的 agent id，每行一个
cachyos_agent_supported()

# 人类可读名，如 claude → "Claude Code"
cachyos_agent_name <agent>

# argv 生成：每行一个参数，便于测试逐字断言
cachyos_agent_command <agent> [prompt]

# 该 agent 对应的 harness 技能目录（供 cachyos-agent-skills --harness 使用）
cachyos_agent_skill_dir <agent>
```

`cachyos_agent_command` 映射（对应上游 `bin/omarchy-agent` 的 `case` 表，按本项目三个 agent 裁剪）：

| agent | 无 prompt | 带 prompt |
| --- | --- | --- |
| `opencode` | `opencode --auto` | `opencode --auto --prompt <p>` |
| `claude` | `claude --permission-mode auto` | `claude --permission-mode auto -- <p>` |
| `codex` | `codex --approve-for-me` | `codex --approve-for-me -- <p>` |

注释必须写明的经验（来自上游，都是踩过的坑）：

1. prompt 前放 `--`，否则以 `-` 开头的 prompt 会被当成选项（上游为此专门解释过 `cursor-agent` 的子命令歧义）。
2. 上游 `crush` 的 `--yolo` 只属于交互子命令、`cursor-agent` 的 workspace trust 是另一个 flag——本项目暂不接这两个 agent，但保留这条注释，接入时照抄上游表。
3. **窗口 class 统一为 `cachyos-agent`**（已决策）：上游的理由是"固定 app-id 让窗口规则和主题能一次命中"。本项目原来的 `Mod+Alt+O` / `Mod+Alt+C` 用的是裸 `opencode` / `claude` class，本轮一并统一。已确认仓库内没有任何窗口规则引用这两个 class，因此无破坏；但这是对既有行为的可见改变，需要写进 README。

#### `bin/cachyos-agent`

```
Usage: cachyos-agent [--inline] [--pick] [--list] [--validate <id>] [--prompt <text>] [<agent>]
```

- 无参数：启动默认 agent；未设置默认时，报错并提示 `cachyos-default-agent <name>`。
- `--pick`：`[[ -t 0 && -t 1 ]]` 时直接用 `fzf`，否则 `kitty --class cachyos-agent-pick sh -lc '...'`；选定后写默认值并启动。复用仓库既有的 fzf 用法（见 `bin/cachyos-keybind-help`）。
- `--inline`：在当前终端 `exec` agent。
- 默认（非 `--inline`）：`exec kitty --class "$CACHYOS_AGENT_WINDOW_CLASS" -e "${command[@]}"`（沿用 `binds.kdl` 硬编码 kitty 的现状，不引入终端抽象）。
- 启动前 `command -v "$agent"` 检查，缺失时给出换一个 agent 的提示。
- 启动前静默调用 `cachyos-agent-skills --quiet --harness "$agent"`（见 5.2，解决"安装时 harness 目录还不存在"）。
- 仅当 `~/Work` 已存在且 `$PWD == $HOME` 时 `cd ~/Work`（复刻上游理由：agent 不记忆 `$HOME` 的信任，否则每次重问）。

#### `bin/cachyos-default-agent`

```
Usage: cachyos-default-agent [<agent>]
```

- 无参数：打印当前默认；未设置时**静默退出 0**（复刻上游"不为用户选边"的行为）。
- 有参数：用 `cachyos_agent_supported` 校验 + `command -v` 检查，原子写入 `~/.config/cachyos-desktop/agent`（临时文件 + `mv`）。
- 不做安装动作（agent 由 `packages.sh` 安装，不学上游的按需安装）。

#### `bin/cachyos-agent-prompt`

```
Usage: cachyos-agent-prompt [--inline] <prompt...>
```

`exec cachyos-agent "${inline[@]}" --prompt "$*"`。存在的理由（复刻上游注释）：裸 prompt 不能挂在 `cachyos-agent` 下，否则会遮蔽 `--pick` 等子命令语义。

#### `tests/agent-test.sh`

照 `tests/hardware-test.sh` 的 `assert_contains` 风格：source `assets/lib/agent.sh`，对每个 agent 断言 `cachyos_agent_command` 的逐行输出精确匹配（含带 prompt 的分支），并断言未知 agent 返回非 0。**不依赖已安装环境**，纯函数测试。

### 5.2 P0-2：skills 分发

#### 资源

```
assets/agent-skills/
├── cachyos/
│   ├── SKILL.md         # 入口：门禁 + 主题索引 + 安全边界
│   ├── niri.md          # 快捷键、窗口规则、输出、条件 include
│   ├── dms.md           # DMS IPC 常用调用、设置、插件、锁屏
│   └── commands.md      # cachyos-* 命令地图与 cachyos-config 用法
└── diagnose-crash/
    └── SKILL.md         # P0-3 依赖
```

不进 `config-manifest.tsv`（它们不是 `$HOME` 配置，而是 share 目录资源）；`install.sh:504-513` 的循环会自动把它们放到 `/usr/local/share/cachyos-desktop/assets/agent-skills/**`。

`cachyos/SKILL.md` 必须包含（对应上游 `default/agents/skills/omarchy/SKILL.md` 的门禁）：

- frontmatter `name` + `description`，description 列出触发条件（编辑 `~/.config/niri/`、`~/.config/DankMaterialShell/`、`~/.config/kitty/`、`cachyos-*` 命令、主题、快捷键）。
- 「改 `~/.config/` 前先读本 skill」的硬门禁。
- `/usr/local/share/cachyos-desktop/` **只读**（包所有，重跑 `install.sh` 会覆盖），读取安全且鼓励。
- 安全边界：受管文件先 `cachyos-config protect <path>` 再改。

`diagnose-crash/SKILL.md` 要点：从 `coredumpctl info <pid>` 取事实、区分本项目组件与上游程序、何时值得上报、不要在被诊断程序的环境里顺手改配置。

#### `bin/cachyos-agent-skills`

```
Usage: cachyos-agent-skills [--quiet] [--harness <agent>]
```

- **只为已存在的目录**建软链，绝不创建 harness 目录。目标列表：

  | 目标 | 说明 |
  | --- | --- |
  | `~/.agents/skills` | 通用位置 |
  | `~/.claude/skills` | Claude Code |
  | `~/.codex/skills` | Codex |
  | `~/.gemini/config/skills` | Antigravity |
  | `~/.pi/agent/skills` | Pi |
  | `~/.hermes/skills` 及每个 `~/.hermes/profiles/*/skills` | Hermes（nullglob 展开 profiles） |
  | `~/.cc-switch/skills` | **已决策纳入**（本机 36 项；cc-switch 会把它分发给各 harness） |

- `--harness <agent>`：只处理该 agent 对应的目录（供 `cachyos-agent` 启动前调用）。
- 每个 skill 用 `ln -sfn "$ASSET_DIR/agent-skills/<name>" "<dir>/<name>"`，幂等；软链而非拷贝，使重跑 `install.sh` 后立即生效。
- `--quiet` 抑制输出（供启动路径调用）。
- 输出被处理的与跳过的目录，便于排错。

#### 三个触发点（关键设计）

安装时几乎必然找不到 harness 目录（全新系统上 `~/.codex/skills` 要等 codex 跑过一次才出现），因此**不能只在安装时链接**。三处触发：

| 触发点 | 时机 | 作用 |
| --- | --- | --- |
| `install_agent_skills()`（新增步骤） | 安装时 | 尽力而为，链接当下已存在的目录 |
| `bin/cachyos-post-login-setup` | 首次登录 | 复刻上游 `provision-first-run` 的时机 |
| `cachyos-agent` 启动前 | 用户第一次真正运行某个 agent | **最可靠**：此刻 harness 目录必然存在或即将由该次运行创建 |

### 5.3 P0-3：崩溃 → agent

#### `bin/cachyos-crash-watch`

- 数据源：`journalctl -f -n 0 -o json MESSAGE_ID=fc2e22bc6ee647b6b90729ab34a250b1`（systemd-coredump 的固定 MESSAGE_ID）。
- 用 `jq` 提取 `COREDUMP_PID` / `COREDUMP_COMM` / `COREDUMP_EXE` / `COREDUMP_SIGNAL`。
- **运行时**检查 `jq`（不在 `preflight` 里要求，见附录 C 修复 3）：缺失时打印一条明确错误并以非 0 退出，由 systemd 记录。
- 去重：同一 `comm` 在 60 秒内只通知一次（`CACHYOS_CRASH_DEDUPE_SECONDS` 可覆盖）。
- 静音：读取 `agents/crash-muted.txt` 跳过。
- **总是**把记录写入 `agents/last-crash`（保证降级入口始终可用）。
- 通知：见 6.1 Spike A。
- 上游注释里必须保留的两条教训：
  1. 崩溃详情以**独立 argv** 传给处理命令，不拼接进命令行（进程名攻击者可控）。
  2. shell 崩溃会带走通知服务器——上游为此先 `omarchy-notification-wait`。本项目对应"等 `dms.service` 就绪"（`systemctl --user is-active dms.service` + 短重试）；丢失的正是最该送达的那条通知。

#### `bin/cachyos-agent-crash`

```
Usage: cachyos-agent-crash <pid> [comm] [exe] [signal]
       cachyos-agent-crash --latest
```

- 校验 pid 为数字。
- 收集 5 个事实：`process` / `PID` / `binary` / `signal` / `time`（时间从 `coredumpctl list <pid>` 取，取不到记为 unknown，不因此失败）。
- 构造 prompt：说明这是本机崩溃、给出事实、**指向 `diagnose-crash` skill**，附"若你的 harness 没有 skill 机制，直接读该文件并照做"的兜底路径 + 绝对路径。
- `exec cachyos-agent --prompt "$prompt"`。
- `--latest` 从 `agents/last-crash` 读取，供无动作通知的降级路径使用。

#### `bin/cachyos-crash-mute`

```
Usage: cachyos-crash-mute [<program>] [on|off]
```

- 无参数：列出已静音项。
- `<program>`：静音（接受名称或 `/usr/bin/xxx` 路径，按 basename 归一）。
- `<program> off`：解除。
- 输出里说明：静音只是隐藏提醒，不修复崩溃。

#### `assets/systemd/user/cachyos-crash-watch.service`

```ini
[Unit]
Description=Watch systemd-coredump and offer an AI diagnosis
After=dms.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cachyos-crash-watch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=niri.service
```

- `WantedBy=niri.service`（而**不是** `graphical-session.target`）：与仓库既有的 `add-wants niri.service dms.service`（`install.sh:657`）保持同一挂载点。见附录 C 修复 1。
- `After=dms.service` 而不是 `graphical-session.target`，保证通知服务器已启动。

## 6. 待解决的未知

### 6.1 Spike A：DMS 通知能否回发动作 —— **已解决（通过）**

上游用 `--exec` 是因为它自己的 shell 不发 `ActionInvoked`。本项目 `dms notify` 只有 `--file` 的 Open/Open Folder 动作，**不能执行任意命令**。

实测（2026-10-01，真实桌面会话，`dbus-monitor` 抓原始信号）：

```
notify-send 返回: diagnose   exit=0
member=Notify            → actions 数组 ["diagnose", "用 AI 诊断"] 已送达
member=ActionInvoked     → uint32 11, string "diagnose"   ← quickshell(:1.27) 回发了动作
member=NotificationClosed → uint32 11
```

另外实测：

- 通知服务 capabilities 含 `"actions"`、`"action-icons"`。
- `-t 0`（不自动过期）被 DMS 接受：13 秒内零 `NotificationClosed`（默认 10 秒早就该关了）。

**结论**：`ACTION_NOTIFY` 默认值改为 1（动作式），`CACHYOS_CRASH_ACTION=0` 退回提示式；动作式发不出去时自动退回提示式。原始 Spike A 的验证步骤保留在下方作为复现方式。

```bash
notify-send -A diagnose=用AI诊断 -w "崩溃测试" "点我"
# 在 DMS 通知里点击「用AI诊断」，观察 stdout 是否输出 diagnose
```

- 通过 → `cachyos-crash-watch` 用 `notify-send -A diagnose=… -w`，读 stdout 后 `exec cachyos-agent-crash <pid> …`。
- 不通过 → 通知只作提示，点击入口改为 `cachyos-agent-crash --latest`，并绑定快捷键 + 写进 `cachyos-keybind-help`。
- **实施顺序**：先按"不通过"方案落地（零风险、始终可用），Spike A 通过后再升级为动作式通知。P0-3 因此不被未知阻塞。

## 7. 文件清单

### 新增

| 文件 | 说明 |
| --- | --- |
| `assets/lib/agent.sh` | agent 表纯函数库（被 `bin/cachyos-agent`、`bin/cachyos-default-agent`、`tests/agent-test.sh` 复用） |
| `bin/cachyos-agent` | 启动入口 + 权限映射 |
| `bin/cachyos-default-agent` | 默认 agent 读写 |
| `bin/cachyos-agent-prompt` | 带 prompt 启动 |
| `bin/cachyos-agent-skills` | skill 软链分发 |
| `bin/cachyos-crash-watch` | coredump 监听与通知 |
| `bin/cachyos-agent-crash` | 崩溃事实收集 + 交给 agent |
| `bin/cachyos-crash-mute` | 单程序静音 |
| `assets/agent-skills/cachyos/{SKILL,niri,dms,commands}.md` | 本项目知识 skill |
| `assets/agent-skills/diagnose-crash/SKILL.md` | 崩溃诊断 skill |
| `assets/systemd/user/cachyos-crash-watch.service` | 崩溃监听 unit |
| `tests/agent-test.sh` | 纯函数单测 |
| `tests/run-all.sh` | 测试运行器（见附录 C 修复 5） |

### 修改

| 文件 | 改动 |
| --- | --- |
| `assets/niri/binds.kdl` | `Mod+Alt+O` → `spawn "cachyos-agent" "opencode"`；`Mod+Alt+C` → `spawn "cachyos-agent" "claude"`；**新增 `Mod+grave`** → `spawn "cachyos-agent" --pick`（两键，见 3.4）。原有 `--class opencode` / `--class claude` 不再由 binds 指定，统一由 `cachyos-agent` 用 `cachyos-agent` class 打开 |
| `assets/config-manifest.tsv` | 追加 `systemd/user/cachyos-crash-watch.service<TAB>.config/systemd/user/cachyos-crash-watch.service` |
| `install.sh` | ① `install_desktop_assets()` 的 `install -d` 列表加 `$HOME/.config/systemd/user`；② 同函数加一行显式 `install -D -m 0644 assets/systemd/user/cachyos-crash-watch.service → $HOME/.config/systemd/user/`；③ 新增 `install_agent_skills()`，`main()` 中插在 692 与 694 之间；④ `post_install()` 加 `systemctl --user daemon-reload` 后的 `enable --now cachyos-crash-watch.service`（沿用 warn 模式）；⑤ **不改 `preflight`** |
| `bin/cachyos-post-login-setup` | 命令循环加 `cachyos-agent-skills` |
| `verify.sh` | `check_desktop_extras()` 增加：软链指向正确、binds 引用 `cachyos-agent`、崩溃 unit 存在（manifest 循环已自动覆盖 unit 文件本身） |
| `packages.sh` | 无新增包 |
| `README.md` | 新增「AI Agent」章节（含 kitty class 变化说明）+ 把 `bash tests/run-all.sh` 加入验收命令 |
| `安装流程与美化应用清单.md` | 同步「AI Agent」章节与验收命令 |

## 8. 验收标准

自动化：

1. `bash tests/run-all.sh` 通过（含既有的 `hardware-test.sh` 与新增的 `agent-test.sh`）。
2. `shellcheck` 对新增/修改的所有 shell 文件无告警。
3. `./install.sh --dry-run` 输出包含全部新命令，且无遗漏 `run` 的裸特权命令。
4. 实跑后 `./verify.sh` 退出码 0（0 FAIL）——特别注意 `verify.sh:252` 的 manifest 循环会检查新 unit 已落 `$HOME`，这是修复 2 的回归关口。
5. `dms ipc call plugins list` 不含任何本轮新增项（本轮不装插件）。

手动：

6. `cachyos-default-agent` 无参数时静默；设成 `codex` 后能返回 `codex`。
7. `cachyos-agent claude` 打开的进程带 `--permission-mode auto`（`pgrep -a claude` 核对），窗口 class 为 `cachyos-agent`。
8. `cachyos-agent --pick` 弹出 fzf 选择器；`Mod+grave` 能触发同一条路径。
9. 跑过一次 `cachyos-agent codex` 后，`~/.codex/skills/cachyos` 与 `~/.codex/skills/diagnose-crash` 是指向 `/usr/local/share/cachyos-desktop/assets/agent-skills/...` 的软链；`~/.gemini/config/skills` 等不存在的目录**未被创建**。
10. `cachyos-agent-skills` 重复执行不产生重复项、不报错（幂等）。
11. `kill -SEGV` 一个测试进程后收到通知；按 6.1 的结论点击或执行 `cachyos-agent-crash --latest`，确认 prompt 含 `process/PID/binary/signal/time` 五个字段。
12. `cachyos-crash-mute <程序>` 后不再收到该程序通知，`... off` 后恢复。
13. 重启后 `systemctl --user is-active cachyos-crash-watch.service` 为 active，且 `ls ~/.config/systemd/user/niri.service.wants/` 含它。

## 9. 风险与回滚

| 风险 | 缓解 |
| --- | --- |
| 改 `binds.kdl` 影响既有快捷键习惯 | 保留 `Mod+Alt+O` / `Mod+Alt+C` 的按键组合，只改 spawn 目标；新增键选了空闲的 `Mod+grave` |
| 统一 kitty class 后，个人在仓库外写的窗口规则若匹配 `opencode`/`claude` 会失效 | 仓库内已确认无此类规则；变化写进 README |
| `verify.sh:262-275` 的逐字节 `cmp` 因 binds 改动而 FAIL | 改完必须重跑 `install.sh` 或 `cachyos-config update`（binds 在 manifest 内，两者都会刷新） |
| 崩溃通知风暴 | 60 秒同程序去重 + 静音名单 |
| 安装时用户 systemd 管理器不可达 | 沿用 `post_install` 既有 warn 模式，并在 README 后置步骤给出手动命令 |
| 软链指向 share 目录内容被覆盖 | 软链指向目录本身；skill 不在 manifest 中，`cachyos-config update` 不触碰它们 |
| agent 旗标随上游版本变化 | 旗标集中在 `assets/lib/agent.sh` 一处；`tests/agent-test.sh` 保证"改一处即改全部" |

回滚：

- 动手前 `cachyos-snapshot "AI-agent-P0"`。
- 受管配置文件用 `cachyos-config protect <path>` 保护。
- 撤销顺序：`systemctl --user disable --now cachyos-crash-watch.service` → 删软链 → `git checkout -- assets/ install.sh verify.sh bin/cachyos-post-login-setup README.md` → 重跑 `./install.sh --skip-update --yes`。

## 10. 实施顺序

| 步骤 | 内容 | 依赖 |
| --- | --- | --- |
| 1 | `assets/lib/agent.sh` + `bin/cachyos-agent` + `bin/cachyos-default-agent` + `bin/cachyos-agent-prompt` + `tests/agent-test.sh` + `tests/run-all.sh` | 无 |
| 2 | `assets/agent-skills/**` + `bin/cachyos-agent-skills` + `install.sh` 接线 + `post-login-setup` 接线 | 步骤 1 |
| 3 | Spike A（6.1）→ `bin/cachyos-crash-watch` + `bin/cachyos-agent-crash` + `bin/cachyos-crash-mute` + unit + manifest + `install_desktop_assets` 显式安装行 + `post_install` | 步骤 1 |
| 4 | `assets/niri/binds.kdl` + `verify.sh` + 两份文档 | 步骤 1–3 |

每步完成后跑：`shellcheck` → `bash tests/run-all.sh` → `./install.sh --dry-run` → 实跑 → `./verify.sh` → 手动验收项。全部通过再进入下一步。

## 11. 实施记录

### 步骤 1：agent 表与启动层（完成）

新增 6 个文件：`assets/lib/agent.sh`、`bin/cachyos-agent`、`bin/cachyos-default-agent`、`bin/cachyos-agent-prompt`、`tests/run-all.sh`、`tests/agent-test.sh`。

验证（全部在本机实跑）：

| 项 | 方法 | 结果 |
| --- | --- | --- |
| 静态检查 | `shellcheck -x` 六个新文件 | 零告警 |
| 单元测试 | `bash tests/run-all.sh` | 18 项新检查 + 既有 `hardware-test.sh` 全通过 |
| 端到端 argv | stub agent 置于 PATH，`--inline` 启动 | `codex --approve-for-me`；`codex --approve-for-me -- -p`；`opencode --auto --prompt 审查` 全部逐字正确 |
| prompt 转发 | `cachyos-agent-prompt --inline '-p'` | 得到 `--approve-for-me` / `--` / `-p` |
| 默认 agent 解析 | `cachyos-agent --inline` 无参数 | 正确读取 `~/.config/cachyos-desktop/agent` |
| 未设置时静默 | `cachyos-default-agent` | 无输出、退出 0 |
| 落盘权限 | 设置默认后 `stat` | 目录 700、文件 600 |
| 未安装分支 | 只保留基础命令的 PATH | `--list` 标注"(未安装)"；设置与启动都拒绝并退出 1 |
| 未支持 id | `--validate bogus` / 设置 `bogus` | 分别退出 1 / 2 |

补充实测（3.1、3.4 的结论来源）：

- `opencode --auto` 在顶层被接受（对照 `--bogus-flag-xyz` 报 `Unrecognized flag`）。
- `claude --permission-mode auto -- <prompt>` 生效：`-- --bogus-xyz` 走到登录检查，而未加 `--` 时 `--bogus-xyz` 报 `unknown option`，说明单个位置参数被当作 prompt 而非子命令。

### 一个风格决策：shellcheck 基线

仓库既有状态不一致：`install.sh`、`verify.sh`、`hardware.sh`、`tests/hardware-test.sh` 带 SC2155 / SC2034 / SC1091，而 `bin/` 下的 helper（`cachyos-config`、`cachyos-update-status`、`cachyos-post-login-setup`）是零告警的。本轮新增文件按 **`bin/` 的零告警标准**写：

- `readonly X="$(cmd)"` 一律拆成先赋值再 `readonly`——SC2155 掩盖命令替换失败，会让 `$SELF_DIR` 静默变空、后续路径拼到根目录。
- 库文件加 `# shellcheck shell=bash`；公开常量加 `disable=SC2034` 并注明由谁使用。
- 测试里的 source 指令写 `source=assets/lib/agent.sh`（相对仓库根）：shellcheck 按 CWD 解析该指令，从仓库根运行才能跟随到库并获得跨文件分析。

### 步骤 1 未覆盖的部分

- `cachyos-agent --pick` 的两条分支（TTY 下 fzf、非 TTY 下 kitty）无法在本环境交互验证，留到步骤 4 的手动验收。
- `bin/cachyos-post-login-setup` 尚未接线 `cachyos-agent-skills`（属步骤 2，已在步骤 2 完成）。
- `install.sh` / `verify.sh` 尚未改动，因此当前还不能跑 `./verify.sh` 验收新命令（属步骤 2、4）。

### 步骤 2：skills 分发（完成）

新增：`assets/agent-skills/cachyos/{SKILL,niri,dms,commands}.md`、`assets/agent-skills/diagnose-crash/SKILL.md`、`bin/cachyos-agent-skills`。

修改：`install.sh`（新增 `install_agent_skills()` 并接入 `main()` 的 `install_desktop_assets` 之后；完成语补上 agent 技能）、`bin/cachyos-post-login-setup`（首次登录循环加入 `cachyos-agent-skills`，两处通知文案同步）。

验证：

| 项 | 方法 | 结果 |
| --- | --- | --- |
| 静态检查 | `shellcheck -x` 全部新文件与改动文件 | 新文件零告警；`install.sh` 仅剩既有 3 条（行 7/160/216） |
| 单元测试 | `bash tests/run-all.sh` | 全通过 |
| 链接器：空环境 | 临时 `$HOME`，无任何 harness 目录 | 7 个候选目录全部"跳过"，**未创建任何目录** |
| 链接器：正常 | 建 `.claude/skills`、`.codex/skills` | 各链接 2 个技能，软链可解析到仓库内真实文件 |
| 链接器：幂等 | 重复执行 + `--quiet` | 条目数不变，`--quiet` 无输出 |
| 链接器：harness 隔离 | `--harness claude` | 只动 `.claude/skills`，`.codex/skills` 条目数不变 |
| 链接器：回落 | `--harness opencode` | 落到 `.agents/skills`；目录不存在则跳过，退出 0 |
| 链接器：未支持 id | `--harness bogus` | 退出 2 并给出提示 |
| 安装期集成 | `./install.sh --dry-run --skip-update --skip-hardware -y`（临时 `$HOME` + os-release fixture） | 退出 0、无 ERROR；`bin/cachyos-agent*` 进 `/usr/local/bin`；5 个 skill 文件进 share 目录；步骤 `/usr/local/bin/cachyos-agent-skills` 出现且仅出现一次 |

关键设计（三处触发，解决"安装时 harness 目录还不存在"）：

| 触发点 | 位置 | 作用 |
| --- | --- | --- |
| 安装期 | `install.sh` 的 `install_agent_skills()` | 尽力而为，链接当下已存在的目录；失败只 warn |
| 首次登录 | `bin/cachyos-post-login-setup` 的命令循环 | 复刻上游 `provision-first-run` 的时机；带 marker，只跑一次 |
| agent 启动前 | `bin/cachyos-agent` 的 `launch()` | **最可靠**：此刻 harness 目录必然存在或即将由该次运行创建；`--quiet` 且失败不影响启动 |

`assets/agent-skills/**` 与 `assets/lib/**` 都不进 `config-manifest.tsv`：它们不是 `$HOME` 配置，而由 `install.sh` 的 `find assets` 循环统一投放到 `/usr/local/share/cachyos-desktop/assets/`。

本步骤未做（属步骤 4）：`README.md` 与 `安装流程与美化应用清单.md` 的「AI Agent」章节、`verify.sh` 的软链与 binds 断言。

### 步骤 3：崩溃 → agent（完成）

新增：`bin/cachyos-crash-watch`、`bin/cachyos-agent-crash`、`bin/cachyos-crash-mute`、`assets/systemd/user/cachyos-crash-watch.service`。

修改：`assets/config-manifest.tsv`（+1 行）、`install.sh`（`install -d` 列表加 `$HOME/.config/systemd/user`；显式安装 unit 到 `$HOME`；`post_install()` 启用 unit 并沿用既有 warn 模式）。

实现期发现并修掉的两个问题：

1. `read` 用默认 IFS 会把空字段（例如缺失的 `COREDUMP_EXE`）折叠掉，导致后面各列整体错位——改为 `IFS=$'\t' read`。
2. `for attempt in 1 2 3 4 5` 的循环变量未使用，触发 SC2034——改为 `for _ in ...`。

验证：

| 项 | 方法 | 结果 |
| --- | --- | --- |
| 静态检查 | `shellcheck -x` 三个新命令 | 零告警 |
| 真实崩溃检测 | 后台跑 watcher，再对 `sleep` 发 `SIGSEGV` | `last-crash` 写入五个字段，`exe=/usr/bin/sleep` 正确（同时证明了 IFS 修复） |
| 去重 | 60 秒窗口内同一程序崩两次 | 记录仍是第一次的 PID |
| 静音生效 | `CACHYOS_CRASH_DEDUPE_SECONDS=0`，静音 `sleep` 后崩溃 | 记录不变 |
| 解除静音 | 同上，`off` 后崩溃 | 记录更新为新 PID |
| 崩溃入口 | 无记录 `--latest` / 无参数 / 非法 PID / 指定 PID | 分别退出 1 / 2 / 1 / 0，prompt 含四个事实字段与 skill 绝对路径 |
| 静音命令 | 列出、路径归一、重复添加、解除、解除不存在、含换行的非法名 | 全部符合预期 |
| 通知路径 | — | **未实测**：沙箱没有 D-Bus 会话。记录写入与 agent 入口都不依赖通知 |

**Spike A 尚未验证。** 6.1 的动作式通知必须在有桌面会话的机器上点一次。已按"不通过"方案落地（提示式通知 + `cachyos-agent-crash --latest` 入口，始终可用），动作式通知用 `CACHYOS_CRASH_ACTION=1` 显式开启，实测通过后把默认值改成 1 即可，不需要改结构。

### 步骤 4：快捷键、验收与文档（完成）

修改：`assets/niri/binds.kdl`、`bin/cachyos-agent`、`verify.sh`、`README.md`、`安装流程与美化应用清单.md`。

- **快捷键**：`Mod+Alt+O` / `Mod+Alt+C` 改走 `cachyos-agent`（不再直接 `kitty -e opencode`），新增 `Mod+grave`（`Super` + 反引号）启动默认 agent。
- **`--pick` 语义调整**：初版实现是"永远弹选择器"，快捷键直接用它会让人每次都看到选择器。改为**无参数时启动默认 agent，只有没有默认值才弹选择器**（复刻上游 `omarchy-agent --pick` 的语义），`--pick` 保留为强制重选。
- **`verify.sh`** 新增 `check_ai_agent_stack()`：share 目录里的库与两个 skill 是否存在、binds 是否仍引用 `cachyos-agent`、已存在的 harness 目录里的软链是否指向正确位置、crash-watch 是否启用（未启用只 `warn`，因为安装时用户管理器可能不可达）。技能根路径遵循仓库既有的 `CACHYOS_DESKTOP_SHARE_DIR` 覆盖约定，因此这个检查可被测试。
- **文档**：README 新增「AI Agent」小节（能力表、命令、技能、崩溃诊断、如何新增 agent）与快捷键行、验收命令加 `bash tests/run-all.sh`；流程文档新增「9.1 AI Agent」、快捷键表加 `Super+\``、验收命令同步。

验证：

| 项 | 方法 | 结果 |
| --- | --- | --- |
| Niri 语法 | `niri validate -c assets/niri/binds.kdl` | `config is valid` |
| 快捷键启动路径 | stub kitty + 已设默认 agent | `--class cachyos-agent -e codex --approve-for-me`，未进入选择器 |
| 无默认值时 | stub kitty + 未设默认 | 进入 `--class cachyos-agent-pick` 选择器 |
| verify 新检查 | 去掉末尾 `main` 调用后 source，构造正确/错误软链 | 8 PASS / 1 WARN / 0 FAIL；错误软链与普通文件都 FAIL |
| 完整 dry-run | 临时 `$HOME` + os-release fixture | 退出 0、无 ERROR、8 条新命令投递、unit 两条路径都在 |
| shellcheck | 全部新文件 | 零告警；`install.sh`/`verify.sh` 仅剩既有 SC1090/SC2155 |
| manifest 不变量 | 逐行比对 manifest 与 `install_desktop_assets` 的显式安装 | 0 处缺失（含新增行） |

### P0 汇总

新增 10 个文件、约 1550 行；修改 7 个文件（+193 / −11）。

| 交付 | 状态 |
| --- | --- |
| P0-1 默认 agent + 权限映射 | 完成并验证 |
| P0-2 技能软链分发 | 完成并验证 |
| P0-3 崩溃 → agent | 完成并验证（通知形式待 Spike A） |

**必须在真机上完成的手动验收**（本环境无法覆盖）：

1. `./verify.sh` 全绿（需要已安装的系统）。
2. `Mod+grave` 在 Niri 里实际按下能启动默认 agent / 弹出选择器。
3. fzf 选择器交互与 `cachyos-default-agent` 落盘（已用 stub 验证分支，未验证真实按键与终端交互）。
4. DMS 通知的实际投递，以及 Spike A（`notify-send -A ... -w` 的 ActionInvoked 回传）。
5. `systemctl --user enable --now cachyos-crash-watch.service` 在真实会话里生效并跨重启存活。

### 真机验收（2026-10-01，在用户的真实 CachyOS + Niri + DMS 会话上）

DSH 沙箱可访问会话 D-Bus（`/run/user/1000/bus`）与 `systemctl --user`，因此上面 1、4、5 项已实际执行。

| 验收项 | 结果 |
| --- | --- |
| Spike A 动作回传 | **通过**，有 D-Bus 原始信号证据（见 6.1） |
| `-t 0` 持久性 | DMS 接受，13 秒内零 `NotificationClosed` |
| 真机安装 | 最小化：`bin/*` + 3 个新 share 资源 + unit；已安装 manifest **只追加** unit 行，未整体刷新 |
| `cachyos-agent --list` | 三个 agent 均正确列出 |
| 技能软链 | 真机建立 6 条（`.claude/skills`、`.codex/skills`、`.cc-switch/skills` 各 2 条） |
| 真实崩溃 → 记录 | 安装版 watcher 捕获 SIGSEGV，`pid/comm/exe/signal/time` 五字段正确 |
| 真实崩溃 → 通知 | 带动作的通知发出（`notify-send` 处于等待用户处理状态） |
| 点击处理器 | 确定性验证：`cachyos-agent-crash --latest` 生成的 argv 为 `kitty --class cachyos-agent -e codex --approve-for-me -- <prompt>`；含五个事实字段与 skill 绝对路径，时间戳由 `coredumpctl` 真取出 |
| systemd 服务 | `enabled` + `active`，挂载点 `niri.service.wants/cachyos-crash-watch.service`（与 `dms.service` 同处） |
| 快捷键上线 | 部署 binds 后 niri 自动重载（journal 有 `loaded config`），`niri validate` 通过，`dms keybinds show niri` 可见 `Mod+grave → AI agent`、`Mod+Alt+O/C → cachyos-agent` |
| `./verify.sh` | 308 passed / 2 warnings / 4 failed；**AI Agent 的 18 项检查全部 PASS** |

实现期又发现并修掉的两个问题（由真机实测暴露）：

5. **动作式通知会阻塞检测循环**：`notify-send -A -w` 一直等到用户处理，期间发生的崩溃都不会被记录——正是最需要记录的时候。已把整个通知过程放进后台子 shell；用"去重关闭 + 连续两次崩溃"实测两次都被记录。
6. **崩溃提示默认 10 秒就消失**：改为 `-t 0`（不自动过期），并实测 DMS 接受。

**剩余 4 个 `verify.sh` FAIL 与本次改动无关**，同一根因是 live 系统落后于仓库：

- `package missing: claude-code`（本机用 Claude 原生安装器，不是 pacman 包）
- `installed Niri asset differs from assets/niri/cachyos-extras.kdl`（既有漂移，本次未触碰该文件）
- `installed Niri main config differs from rendered assets/niri/config.kdl`（既有漂移，本次未触碰）
- `managed DMS desktop settings are missing or incomplete`（既有）

**部署时顺带带入的变化**：`~/.config/niri/dms/binds.kdl` 整体更新为仓库版本，因此除 `Mod+grave` 外还带入了 `Alt+F4`（live 版本更旧，本来就没有这一条）。该文件是托管文件、仓库是权威版本；live 版本已备份到 `~/.local/state/cachyos-desktop/acceptance-backup-20261001-235646/binds.kdl.live`。

**回滚清单**：

```bash
systemctl --user disable --now cachyos-crash-watch.service
rm -f ~/.config/systemd/user/cachyos-crash-watch.service
sudo rm -f /usr/local/bin/cachyos-{agent,default-agent,agent-prompt,agent-skills,crash-watch,agent-crash,crash-mute}
sudo rm -rf /usr/local/share/cachyos-desktop/assets/{lib,agent-skills,systemd}
# 从 /usr/local/share/cachyos-desktop/config-manifest.tsv 删除 unit 那一行
rm -f ~/.claude/skills/{cachyos,diagnose-crash} ~/.codex/skills/{cachyos,diagnose-crash} ~/.cc-switch/skills/{cachyos,diagnose-crash}
rm -f ~/.config/cachyos-desktop/agent
cp ~/.local/state/cachyos-desktop/acceptance-backup-20261001-235646/binds.kdl.live ~/.config/niri/dms/binds.kdl
```

未完成：快照（`sudo snapper -c root create` 在本机报"创建快照失败"，原因未查明；已改用手动备份），以及第 2、3 项需要真实按键的验收。

### 独立审核（2026-10-02）

按文件维度派了三个**全新上下文**的评审（只读、要求 file:line + 实跑证据）。合并结果如下，全部已修。

| # | severity | 缺陷 | 证据 | 修法 |
| --- | --- | --- | --- | --- |
| R1 | **高** | `cachyos_agent_command` 按**行**输出 argv，`mapfile` 按行收集 → **prompt 里任何换行都会把参数拆开**；崩溃诊断的 prompt 正是多行 heredoc，agent 会收到多余位置参数而拒绝启动 | `mapfile -t arr < <(cachyos_agent_command codex $'第一行\n第三行')` → 5 个元素（应为 3）；真机链路实测收到 12 个参数 | 库改 `printf '%s\0'`、调用方改 `mapfile -d ''`；测试改用 NUL 读取并新增**参数个数**断言（换行/竖线/制表符），且验证过"新测试跑在旧库上会失败" |
| R2 | 中 | 每个未处理的动作式通知常驻 3 个进程且 `-t 0` 不过期 → 崩溃循环下**无上界累积**（评审现场抓到 11 组、约 33 个进程） | 评审现场进程树 | 每个程序最多一条待处理通知（`notification_pids` + `kill -0`）；实测去重关闭下连崩 5 次只留 1 组 |
| R3 | 中 | README 把 `CACHYOS_CRASH_ACTION` 的默认值写反了（"默认只发提示，需要时设 1"），而代码默认是 1 | `README.md:367` vs `bin/cachyos-crash-watch:22` | README 改写为"默认即可点击，设 0 退回提示式" |
| R4 | 中 | `niri.md` 称"所有 include 都是 optional，缺文件也能启动"——`config.kdl:277` 的 `cachyos-extras.kdl` **没有** optional，缺了会直接启动失败；文档同一页内自相矛盾 | 删掉该文件后 `niri validate` 报 `failed to read included config` | 文档改为"只有 DMS 生成的那批是 optional，`cachyos-extras.kdl` 必需" |
| R5 | 中 | `niri.md` 把 `Mod+grave` 列为**空闲键**，而同一次提交已把它绑给 AI agent；照文档做会产生重复绑定（硬错误） | `niri validate` 报 `duplicate keybind` | 从空闲键列表移除并明确标注它已被占用 |
| R6 | 中 | `commands.md` 写了不存在的 `cachyos-config windowrules`（真实子命令只有五个） | `bash bin/cachyos-config windowrules` → usage + exit 2 | 删掉该行，改为指向 `dms ipc call window-rules toggle` / `dms config windowrules` |
| R7 | 中 | `dms.md` 把 `Super+Alt+W` / `Super+Y` 说成 Waypaper；实际两者都是 `dms ipc call dankdash wallpaper`，Waypaper 是 `Super+Ctrl+F10` | `binds.kdl:47,244` vs `cachyos-extras.kdl:32` | 改写该段并说明两条路径的关系 |
| R8 | 低 | `verify.sh` 的 binds 检查只 grep 一次"存在"：删掉两条绑定只留一条仍 PASS | 评审反证 | 改为逐条断言 `Mod+Alt+O` / `Mod+Alt+C` / `Mod+grave`；并验证"删一条恰好 1 FAIL、改回裸 kitty 恰好 1 FAIL" |
| R9 | 低 | `verify.sh` 的首次登录 marker 列表漏了 `cachyos-agent-skills-v1` | `bin/cachyos-post-login-setup:16` vs `verify.sh:331` | 加入该 marker |
| R10 | 低 | `dms.md` 把 `settings`/`widget` 的方法混在一行（`widget` 没有 `dump`） | `dms ipc --help` | 拆成两行 |
| R11 | 低 | 内部计划术语泄漏进随包文档（`（P0-3 交付）`、`见 PLAN 的 Spike A`） | `commands.md`、`README.md` | 删除这些字样 |
| R12 | 低 | README 的 harness 目录清单漏了 `~/.hermes/profiles/*/skills` | `bin/cachyos-agent-skills:56-71` | 补上 |
| R13 | 低 | README 说统一 class"窗口规则和主题因此能一次命中"，但仓库里没有任何这样的规则 | 全仓库 grep 无匹配 | 改写为"统一后一条规则即可覆盖（项目目前未写规则）" |

**一条被评审推翻的我自己写的理由**：我原先把 `Restart=always` 的理由写成"安装时 `install` 就地替换脚本，运行中的 bash 读不到后续内容会以 0 退出"。评审实测 `install -m 0755 b.sh a.sh` 后 inode 由 8827 变 8829（**替换**而非就地截断），运行中的 bash 仍持有旧 inode 的 fd，不会因此退出——这个理由不成立。`Restart=always` 仍然保留，但理由改成真实的那条：**这个 watcher 没有合法的正常退出路径**（`watch` 是死循环，失败路径都以非 0 退出），任何一次 `exit 0` 都属意外，`on-failure` 会把它静默留在 dead 状态。

**审核过程本身的教训**：派发评审时**没有禁止它们改动系统状态**。结果评审在收到约束前对真机上正在运行的 `cachyos-crash-watch.service` 执行了 `stop`，并向 journal 注入合成 coredump 条目，在你桌面上产生约 11 条假的"进程崩溃"通知；这些通知的回调又跑在**临时 HOME** 下，于是点击后弹出 fzf 选择器（找不到默认 agent）。已清理（`notifications clearAll` + 收掉等待进程 + 清掉残留 watcher），服务已恢复。**以后派发涉及本机服务的评审，约束里必须写明"不得改动系统状态"。**

### 独立审核·第二轮（2026-10-02）

第二轮覆盖了第一轮没审的两个维度（崩溃诊断命令、agent 启动层与库），另加验器/文档层的 13 条。发现 3 个新阻塞项，全部已修。

| # | severity | 缺陷 | 证据 | 修法 |
| --- | --- | --- | --- | --- |
| S1 | **高** | fzf 选择器**从来没成功过**（两条缺陷叠加）：① `[[ -t 0 && -t 1 ]]` 在 `agent="$(pick_agent)"` 里恒为假（命令替换让 stdout 变成管道）→ 内联分支是死代码；② kitty 分支 `chosen="$(kitty … sh -lc '… | fzf | cut -f1')"` 捕获的是 kitty 自己的 stdout，而 kitty 把子进程挂在新窗口的 pty 上 → 永远为空 → "没有选择 agent。"。`Super+``、`--pick`、未设默认值时的 `--prompt` 全部失效 | 评审在真 pty 上复现（`$( )` 内 `-t 1` 为假；kitty 分支调用者拿到 0 字节，窗口内却写成功） | 判据只看 stdin；kitty 分支把选择写临时文件再读回；两条分支共用同一条 pipeline。**真机验证**：安装版 `cachyos-agent --pick` 现能写回 `codex` |
| S2 | **高** | 制表符是 IFS **空白**字符，`read` 仍会折叠空字段 → 缺 `COREDUMP_EXE` 时 `signal` 顶到 `exe` 列。上一轮"IFS=$'\t' 已修复"的说法是错的 | 评审逐条喂合成记录：`missing EXE → exe=11 signal=` | 改用非空白分隔符 `\x1f` + jq `join`；新增 `tests/crash-test.sh`（12 项），并验证它跑在修复前版本上会失败 |
| S3 | **高** | 内核把 `comm` 截到 15 字节，静音名单存完整名 → `gnome-keyring-daemon`、`xdg-desktop-portal` 这类长名字**永远静音不了** | 真实崩溃复现（`verylongprocessname12345`） | `normalize_program` 按**字节**截断到 15 并提示 |
| S4 | 中 | 动作式通知只传 PID → 提示词里进程/程序/信号全是 unknown；且 `-t 0` 通知挂久后 PID 可能已被复用 | 评审实测 | 四个字段一并传给 `cachyos-agent-crash` |
| S5 | 中 | `CACHYOS_CRASH_DEDUPE_SECONDS` 未校验：设成 `abc` → `set -u` 下算术报错，watcher 当场退出，state 目录都没建；叠加 `Restart=always` 变成"每次崩溃重启一次服务" | 评审实测 rc=1 | 校验为非负整数，否则回退 60 并告警 |
| S6 | 中 | 点击通知启动的 `cachyos-agent-crash → kitty → agent` 留在 service cgroup 里 → watcher 任何一次重启都会 SIGTERM 掉用户正在进行的诊断会话 | 评审抓到 cgroup 现场 | unit 加 `KillMode=process` |
| S7 | 中 | 默认限流（10s/5 次）与 `RestartSec=5` 组合下永远凑不满 → 坏掉的 watcher 无限静默重启、永不进入 failed | 评审实测 `StartLimit*` | 加 `StartLimitIntervalSec=60` + `StartLimitBurst=3` |
| S8 | 中 | 选中"未安装"的 agent 会打印归因错误的信息（"cachyos-default-agent 不可用"），且两条分支展示不一致 | 评审实测 | 区分退出码 127 与其他；两条分支统一用 `--list` |
| S9 | 中 | 目标同名若是**真实目录**，`ln -sfn` 会嵌套进去，脚本仍报"已链接 N 个技能"，技能在 harness 路径上不可见 | 评审实测 | 目标是真实文件/目录时跳过并告警，不碰用户内容 |
| S10 | 中 | 默认 agent 文件被手工改坏（拼错 / 尾随空格 / CRLF）直接 exit 2，不回落选择器 | 评审实测三种输入 | 读取时去首尾空白；不受支持则告警并重新选择 |
| S11 | 低 | journalctl 永久失败 = 服务 active 却什么都不做，`2>/dev/null` 让失败完全不可见 | 评审实测 | 不再吞 stderr，并记录每次重连 |
| S12 | 低 | 一个目标目录不可写就中止整个技能同步 | 评审实测 | 单目标失败不中止，末尾汇总退出码 |
| S13 | 低 | `--` 不被识别；`AGENT_FILE` 是目录时假成功；`--latest` 对目录静默 rc=4 | 评审实测 | 分别修掉 |

**测试盲区也补上了**：评审指出"A 只测库、不测收集端"正是 S2 能"全绿漏过"的原因。`tests/agent-test.sh` 现在有 launcher 端到端用例（stub harness 记录 argv，含多行 prompt 往返）和选择器用例（stub kitty 真的执行内层命令 + `FZF_DEFAULT_OPTS=--filter`）。

**我在修 S9/S12 时又犯了同类错误**：用 `edit` 替换 `main()` 时凭记忆写新旧文本，漏掉了 `--quiet` 与 `--harness` 两个选项、把文件改坏；靠"编辑后立刻读文件复核"发现并修复。教训：**替换块必须以刚读到的原文为锚点，不能凭记忆**。

## 附录 A：与 Omarchy 的对应关系

| Omarchy | 本项目 | 备注 |
| --- | --- | --- |
| `bin/omarchy-agent` | `bin/cachyos-agent` | 裁到 3 个 agent；保留 `case` 表结构与注释经验 |
| `bin/omarchy-default-agent` | `bin/cachyos-default-agent` | 去掉 mise 按需安装 |
| `bin/omarchy-agent-prompt` | `bin/cachyos-agent-prompt` | 同构 |
| `bin/omarchy-crash-watch` | `bin/cachyos-crash-watch` | 通知机制待 Spike A |
| `bin/omarchy-agent-crash` | `bin/cachyos-agent-crash` | 增加 `--latest` 降级入口 |
| `bin/omarchy-crash-mute` | `bin/cachyos-crash-mute` | 同构 |
| `default/agents/skills/**` | `assets/agent-skills/**` | 内容重写为本项目知识 |
| `omarchy-provision-user` 的 skill 软链 | `bin/cachyos-agent-skills` | 独立命令，三处触发 |
| `omarchy-mise-install` | 不移植 | 本项目用 pacman/AUR |
| `omarchy-notification-send` | `dms notify` / `notify-send` | 能力不同，见 6.1 |
| `omarchy-launch-tui --app-id=` | `kitty --class cachyos-agent -e` | 统一 class |
| `omarchy-done mark/ensure` | `~/.local/state/cachyos-desktop/<name>-v1` | 沿用仓库既有 marker 模式 |
| `omarchy-hw-vulkan` | `hardware.sh` 的 GPU 检测 | 本轮未用，P3 voxtype 时复用 |

## 附录 B：已确认的决策

| # | 决策项 | 结论 | 落点 |
| --- | --- | --- | --- |
| 1 | 命名空间 | `~/.config/cachyos-desktop/`（配置）+ `~/.local/state/cachyos-desktop/`（状态） | 全文 |
| 2 | agents 用量 UI | DMS 插件形式（本轮不实现，仅预留命名） | 2.2 |
| 3 | 本轮范围 | 只做 P0 | 2.1 |
| 4 | kitty 窗口 class | **统一为 `cachyos-agent`**（不再 per-agent） | 5.1 注释 3、7 修改表 |
| 5 | `~/.cc-switch/skills` | **纳入**软链目标 | 5.2 目标表 |
| 6 | 默认 agent 快捷键 | **`Mod+grave`**（两键）；备选 `Mod+BackSpace`；避开 `Mod+F9` | 3.4、7 修改表 |
| 7 | `codex -- <prompt>` | **实测可用** | 3.1 |

## 附录 C：自审结论（对初版计划的修正）

初版计划经逐条核对后发现 6 处问题，本版已修正。

| # | 严重度 | 问题 | 事实依据 | 修正 |
| --- | --- | --- | --- | --- |
| 1 | 高 | 初版 unit 用 `WantedBy=graphical-session.target`，但本桌面没有启动该 target 的证据 | `niri.service` 由 niri 包提供；DMS 经 `~/.config/systemd/user/niri.service.wants/dms.service` 挂载（由 `install.sh:657` 创建） | 改为 `WantedBy=niri.service` + `After=dms.service` |
| 2 | 高 | 初版只加 `config-manifest.tsv` 一行，以为文件会落 `$HOME` | `install.sh:439-482` 逐条显式安装 `$HOME` 文件；`install.sh:514` 只把 manifest 复制到 share；安装期不读 manifest | 在 `install_desktop_assets()` 加 `install -d $HOME/.config/systemd/user` 与显式 `install -D` 行；否则 `verify.sh:252` 必然 FAIL |
| 3 | 中 | 初版把 `jq` 加进 `preflight` 必需命令 | `preflight`（`install.sh:143-171`）在 `install_applications` **之前**运行，`jq` 来自 `DAILY_APP_PACKAGES`，全新系统上还没有 → 会直接 `die` | 从 `preflight` 移除；改为 `cachyos-crash-watch` 运行时自检 |
| 4 | 中 | 初版只在安装时做 skill 软链 | 本机实测：`~/.agents/skills`、`~/.gemini/config/skills`、`~/.pi/agent/skills`、`~/.hermes/skills` 均不存在；全新系统上 `~/.codex/skills` 要等 codex 首次运行才出现 → 安装时链接会静默无功 | 三处触发：安装时（尽力）+ 首次登录 + `cachyos-agent` 启动前按 harness 定向链接 |
| 5 | 低 | 初版把 "`tests/agent-test.sh` 通过" 当验收项，但仓库没有测试运行器 | 仓库无 Makefile / CI；`tests/hardware-test.sh` 从未被任何脚本或文档引用 | 新增 `tests/run-all.sh`，并把 `bash tests/run-all.sh` 写进 README 验收命令 |
| 6 | 中 | 初版默认快捷键写 `Mod+Shift+Alt+A`（三键），且我一度把 `Mod+X` 当作空闲键 | niri 中 `Mod` 与 `Super` 是同一个键，`binds.kdl:240` 的 `Super+X` 即 `Mod+X`（电源菜单）；plain `Mod+` 下 26 个字母全被占用 | 改为两键 `Mod+grave`；把"字母全占用 + `Mod+X` 陷阱 + 空闲键清单"记入 3.4 |

同时确认无问题的点：

- `assets/lib/**` 与 `assets/agent-skills/**` 不需要进 `config-manifest.tsv`：`verify.sh` 没有"assets 必须全部登记"的断言（已确认 `verify.sh` 中 manifest 相关代码仅 252/290 两处，均为正向检查）。
- 新增 helper 不会破坏 `verify.sh:217-220`：它们会被 `install_desktop_assets` 装到 `/usr/local/bin`。
- `binds.kdl` 改动不会破坏 `verify.sh:262-275` 的 `cmp`：两条安装路径（`install.sh` / `cachyos-config update`）都会刷新该文件。
- `~/.config/cachyos-desktop` 本机不存在，命名无冲突。
- `~/Work` 本项目不创建，5.1 的 `cd` 已加存在性守卫。
