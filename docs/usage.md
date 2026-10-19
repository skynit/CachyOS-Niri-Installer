# Agent 用量统计

安装器会装上 DMS 插件 **AI 集成（`cachyosAgents`）** 的用量面板：**状态栏默认只显示 token 数字**——
没有图标、没有金额、也不带“今天/近 7 天”这类前缀（想要日期前缀就在插件设置里改「状态栏显示」；
也可把统计范围钉到某一个 agent）。点开是每个 agent 的明细（今天/累计的 token 与费用、会话与提示数、
按费用排序的模型、最近 7 天的**折线图**）。默认登记 Claude Code、Codex、OpenCode 与
**DSH（DeepSeek Harness）**，每个都能在插件设置里单独关掉。

每张卡片右上角有「**设为默认**」按钮——点一下就把 ``Super+` `` 的默认 agent 换成它；当前默认的卡片显示
「默认」徽标。只有**已安装**的 agent 才出现按钮：把没装的设成默认，按 ``Super+` `` 只会起不来。

```bash
cachyos-agent-usage-update                  # 刷新所有 agent 的用量记录（面板每 15 分钟自己调一次）
cachyos-agent-usage-update claude           # 只跑某一个 agent
cachyos-agent-usage-update --except codex   # 跳过某一个采集器（可重复）
cachyos-agent-usage-update --limits-only    # 只刷新限额，不动本地统计
cachyos-agent-usage-claude                  # 目前 3 个采集器，各自输出一条 JSON 记录
cachyos-agent-usage-codex
cachyos-agent-usage-dsh
```

> **OpenCode 没有采集器。** 面板的 `agents` 表里登记了它，但还没有对应的
> `cachyos-agent-usage-opencode`；没有记录时面板不会显示空卡片。加采集器的方法见下文
> “数据链路”。

安装时会**先算一次**，并启用 `cachyos-agent-usage.timer`（登录后 2 分钟 + 此后每 15 分钟，
`Persistent=true`，所以关机期间错过的刷新会在开机后补上）。没有这个定时器，面板只会停在
安装那一刻的数字。

## 数据链路

```text
cachyos-agent-usage-update          # 并行跑各 agent 的采集器并原子落盘
  └── ~/.local/state/cachyos-desktop/agents/usage/<agent>.json
        └── 面板读取（纯 Go usage-json 合成数组）
```

面板只读目录，不直接跑采集器；加一个 agent 需要两处：加一个采集器，并把它登记进面板的 agent 表
（`Usage.js` 顶部的 `agents` 数组——`summarise()` 只遍历那张表，只加 JSON 文件不会显示）。

## 取数、费用与 token 语义

- 全部在本机取数，**不联网**：Claude 读 `~/.claude/projects/**` 的转录，Codex 读
  `~/.codex/sessions/**` 的 rollout，DSH 读 `~/.dsh/sessions/**` 下 zstd 压缩的事件流
  （v4/v2/v0 三种格式都兼容；提示数只认 `source.kind == "user"`，合成条目不算）。
- **费用**取自 cc-switch 的 `model_pricing` 表（装了 cc-switch 才有）；没有定价时只显示
  token，未定价的模型会标注「未定价」。
- **token 语义按各家对齐**：Claude 与 DSH 的 input 都**不含**缓存读，Codex 的已含缓存。记录里用
  `inputTokenSemantics` 标明，总量与费用都据此拆分，避免缓存被重复计算。DSH 的 `reasoningTokens`
  已含在 `outputTokens` 里，不会被再加一遍。
- **缓存按源文件 `(mtime, size)` 增量**，并带 `CACHE_VERSION`：解析逻辑一变缓存整体作废，
  否则会出现“代码修好了、屏幕上的数字还是旧的”。
- 缺数据显示「未采集 / 无数据」，绝不把没采到渲染成 0；今天没有用量时回落到最近有数据的
  一天并标出日期（例如 `10-01 12.0M`）——金额只在弹窗里看。

| agent | `inputTokens` 是否含缓存读取 | 费用 |
| --- | --- | --- |
| Claude Code | **不含**（缓存读取单列） | 本机记录的价格 |
| DSH | **不含**（缓存读取单列） | 可为 DSH 单独配置价格，未配置时只显示 token |
| Codex | **含** | 本机记录的价格 |
| OpenCode | 暂无采集器（面板已登记，无记录时不显示卡片） | — |

合计与计费会按各自语义分别处理，不会把缓存读取重复计入。

> **DSH 的金额**：它的事件流里没有花费，cc-switch 的定价库里也没有 deepseek 条目，所以 DSH
> 默认只统计 token。想看到金额就在 `~/.config/cachyos-desktop/agents/dsh.json` 里给单价
> （美元/百万 token）：`{"pricing": {"deepseek-v4-flash": {"input": 0.28, "output": 1.1, "cacheRead": 0.028}}}`。

## 采集器的边界

- 同一条 API 消息被按 content block 写成多行（同 `message.id`）时只算一次；Codex 重复发出的
  `token_count` 快照（总量没前进）会跳过。`tests/usage-edge-test.sh` 专门盯这些边界。
- 读不了的文件不会被缓存成“0 条”，否则错误会一直留着；单个畸形的 token 字段不会让整次采集崩掉。
- 限额端点返回意外结构时不能让本地统计一起失败。
- 采集器目前用 Python 3；读取与合成用随包的 Go helper（`cachyos-usage-json`），细节见
  [dms-plugins.md](dms-plugins.md)。

面板 UI 与设置见 [ai.md](ai.md#ai-集成面板)；DMS 插件自身的说明见
[assets/dms-plugins/CachyosAgents/README.md](../assets/dms-plugins/CachyosAgents/README.md)。
