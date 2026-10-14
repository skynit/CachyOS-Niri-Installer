---
name: diagnose-oom
description: >
  Diagnose an out-of-memory (OOM) kill on this CachyOS + Niri + DankMaterialShell desktop.
  Use when a process disappears without a core dump, when investigating "Memory cgroup out
  of memory: Killed process", a kernel global OOM, or a systemd-oomd kill, when checking
  memory pressure (PSI) or a full swap, or when deciding whether to add a MemoryMax, change
  the swap policy, or reduce concurrency. Not for segfaults or aborts - those have core
  dumps, use diagnose-crash. Triggers: OOM, oom-killer, oomd, systemd-oomd, last-oom,
  SIGKILL, anon-rss, oom_score_adj, memory.peak, memory.events, PSI, memory pressure,
  swap full, "killed process", "process disappeared", "out of memory", 内存耗尽, 被 OOM 杀.
---

# 诊断 OOM 杀进程

被调用时通常已经拿到这些事实：受害者进程名、PID、时间、触发层
（来自 `~/.local/state/cachyos-desktop/agents/last-oom`，或通知里传来的参数）。任务是
**先建立事实，再判断责任方**，最后给出可执行的下一步——不是一上来就"加内存"。

## 第零步：OOM 不是崩溃，diagnose-crash 的方法在这里不适用

先把方向摆正，否则会在错误的地方找证据：

- OOM 是内核或 systemd-oomd 发出的 `SIGKILL`(9)，进程**没有机会**写核心转储。
- 因此 `coredumpctl list <pid>` 只会回 `No coredumps found.`——本机 09:28 被杀的三次
  node 全部如此。**查不到 core 是正常现象，不是"证据丢了"**。
- 内核与 systemd-oomd 的 OOM 消息**没有 `MESSAGE_ID`**（本机实测为空），所以根本没法按
  `MESSAGE_ID=` 过滤，只能按文本锚点匹配。

证据不在 core 里，而在 **journal 文本、PSI 压力值、cgroup 计数器**这三处。

## 第一步：确认事实，先分清三种来源

```bash
# 内核侧：memcg OOM 与全局 KOOM 都在这里。文本匹配，不要用 MESSAGE_ID
journalctl -k --since "1 hour ago" --no-pager \
  | grep -E "oom-kill|Killed process|Out of memory: Killed|invoked oom-killer"

# 用户态 oomd：它比内核早数分钟动手，是最好的预警点
journalctl -u systemd-oomd --since "1 hour ago" --no-pager
```

grep 没有匹配时退出码是 1，那只是"这段时间没 OOM"，不是命令坏了。

| layer | 锚点文本 | 特征 | 谁干的 |
| --- | --- | --- | --- |
| `kernel-memcg` | `Memory cgroup out of memory: Killed process <pid> (<comm>)`，伴随 `oom-kill:constraint=CONSTRAINT_MEMCG` | 发生在**受限 cgroup 内**，total 往往远小于机器内存 | 内核 |
| `kernel-global` | `oom-kill:constraint=CONSTRAINT_NONE` | 整机内存真的耗尽 | 内核 |
| `oomd` | `Marked <cg> for killing due to memory used (...) / total (...) and swap used (...) / total (...) being more than 90.00%` | 由 swap/内存使用率超限触发 | systemd-oomd |

两个容易读错的点：

- **内核只报 memcg 路径，不报 unit 名。** unit 名在 systemd 自己随后写的那条里：
  `<scope>: The kernel OOM killer killed some processes in this unit.`，以及
  `<scope>: Failed with result 'oom-kill'.`、`<scope>: Consumed ... 3G memory peak.`
  后者还直接给出该 scope 的峰值内存。
- **一次 OOM 在 journal 里是多条消息**（内核原文几条 + systemd 的 unit 级通知）。
  数"OOM 发生了几次"要用 **pid + 时间戳**去重，不要数行数，否则会严重高估。

## 第二步：判断"真的用爆"还是"被误杀"

看四个字段，而不是只看内存总量：

1. **`anon-rss`**——受害者实际占用。3G 的 node 在 30G 机器上被杀，说明不是它吃爆了整机，
   而是撞到了**更小的边界**。
2. **`oom_score_adj`**——`200` 表示它的被杀优先级已被主动调高（user@ 下的 scope 常见，
   也会由用户/服务自己设）。数值高的小进程，很容易先被牺牲。
3. **cgroup 层级**——`oom_memcg=` 指向哪个 scope。memcg OOM 只在**该 cgroup 内**挑受害者，
   机器整体可能还有富余内存。
4. **`constraint`**——`CONSTRAINT_MEMCG` 是局部，`CONSTRAINT_NONE` 才是全局。

| 现象 | 结论 |
| --- | --- |
| anon-rss 远小于机器内存，`constraint=CONSTRAINT_MEMCG` | 撞到 scope/cgroup 限额或 memcg 内部压力，不是整机耗尽 → 查限额与并发 |
| `constraint=CONSTRAINT_NONE` | 整机真耗尽 → 查 swap 与总工作集 |
| oomd 报 `swap used ... being more than 90.00%` | 工作集 > RAM+swap，系统在把 swap 当内存用 → swap 策略问题 |
| `oom_score_adj` 高，但它其实不大 | 它是被优先牺牲的替罪羊 → 去找真正的大户 |

## 第三步：现在还在压力下吗

```bash
cat /proc/pressure/memory
```

本机实测输出形如：

```
some avg10=0.00 avg60=0.04 avg300=0.81 total=101305079
full avg10=0.00 avg60=0.04 avg300=0.78 total=97015271
```

- `some` = 至少一个任务因内存停顿；`full` = **所有**任务都停顿，更严重。
- `avg10/avg60/avg300` 是百分比，分别代表 10/60/300 秒窗口。
- `full avg60` 持续偏高说明**仍在**受压；`avg10` 已回 0 说明这一波过去了。
- 本机 watcher 在 `full avg60 ≥ 10` 就预警，比 oomd 的 60% 阈值早得多——看到预警就该
  处理，别等进程被杀。

```bash
oomctl                                  # oomd 当前策略与监控对象（Swap Used Limit 实测 90%）
free -h; swapon --show                  # 内存/swap 余量；zram 与 swapfile 各占多少
systemd-cgtop -m --iterations=1 -n 1    # 现在谁在吃内存（只列活着的 cgroup）
```

## 第四步：已消失的 scope，从父 cgroup 取证

临时 scope（如 `run-p24156-i31266.scope`）被杀后会**立即消失**：
`/sys/fs/cgroup/.../run-p24156-i31266.scope` 已经不存在。但父级的**层级计数**还在，
这是唯一能回溯"刚才发生了什么"的地方：

```bash
CG=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice
cat $CG/memory.events        # 层级计数（含后代）：oom_kill 3 → 该子树被杀 3 次
cat $CG/memory.events.local  # 只算本级：oom_kill 0 → 说明死者是后代，不是它自己
cat $CG/memory.peak          # 子树内存峰值（本机实测 25226235904 ≈ 23.5G）
cat $CG/memory.swap.peak     # 子树 swap 峰值（本机实测 58410553344 ≈ 54.4G）
cat $CG/memory.max           # 限额；max = 不限
```

本机实测：`memory.events` 里 `oom_kill 3`，而 `memory.events.local` 里是 `0`——
3 次 kill 全发生在**子 scope**里。只看 `.local` 就会得出"这里没 OOM"的错误结论，所以
两个都要读。

注意：**`/sys/fs/cgroup/` 根目录没有** `memory.max` / `memory.events` / `memory.peak`
（本机实测），必须落到具体子 cgroup 路径上读。取路径：

```bash
systemctl show -p ControlGroup <unit>          # 系统 unit
systemctl --user show -p ControlGroup <unit>   # 用户 unit/scope（需在用户会话里跑，如 Niri 终端）
systemd-cgls --no-pager /user.slice            # 直接看层级树，不必先知道路径
```

## 第五步：读 last-oom，不要自己重新解析 journal

`~/.local/state/cachyos-desktop/agents/last-oom` 由 `cachyos-oom-watch` 写入，字段固定
（下面的名字就是契约，不要改）：

| 字段 | 含义 |
| --- | --- |
| `time` | 事件时间 `YYYY-MM-DD HH:MM:SS`（psi 层是采样时刻） |
| `layer` | `kernel-memcg` / `kernel-global` / `oomd` / `psi` |
| `victim_pid` | 被杀进程 PID；oomd/psi 层为空（oomd 报的是 cgroup 不是 pid） |
| `victim_comm` | 进程名；oomd/psi 层为空 |
| `victim_rss_kb` | 内核消息里的 `anon-rss`，单位 kB；只有内核层有 |
| `memcg` | `oom_memcg=` 的 cgroup 路径；oomd/psi 层为空 |
| `unit` | oomd 层填被标记/杀掉的 cgroup 路径；内核层为空 |
| `constraint` | `CONSTRAINT_MEMCG` / `CONSTRAINT_NONE`；oomd/psi 层为空 |
| `marked_cg` | oomd 的 "Marked ... for killing" 里的 cgroup；其余层为空 |
| `psi_full_avg60` | PSI 的 `full avg60` 数值（百分数）；仅 psi 层有 |

```bash
# 直接把记录交给默认 agent 诊断：它把这 10 个字段 + 当前 free/PSI/cgtop 拼成 prompt
cachyos-agent-oom --latest

# 想自己核对字段时，再看原始文件
cat ~/.local/state/cachyos-desktop/agents/last-oom
```

`--latest` 就是默认行为，不带参数等价；OOM 通知里点"用 AI 诊断"跑的就是它。它**只保留
最近一次**事件，历史必须回 journal 查。若一条记录都没有，`cachyos-agent-oom` 会退出非 0
并提示执行 `systemctl --user status cachyos-oom-watch.service`——用后者确认
`cachyos-oom-watch` 在跑，再回退到第一、四步的 journal + cgroup 取证，不要凭通知文案猜。

## 第六步：给出可执行结论

按证据选**一条**主因，不要把所有可能性都列一遍。

- **swap 打满**（`swapon --show` 接近满，或 oomd 报 >90%）：说明工作集超过 RAM+swap。
  两条路——加 swap（zram 快、适合可压缩的工作集；swapfile 大、适合溢出，别放慢盘），
  或者降并发（构建 `-j`、浏览器标签数、AI agent 并发数）。加 swap 只是延后问题，
  降并发才是治本。
- **memcg 局部 OOM**：给那个 scope/service 加限额，让它**先自己死**而不是拖垮同机器
  的其他任务；或者反过来放宽限额。改前必须说明单位与风险：`MemoryMax` 设小了会更频繁
  OOM；`MemoryHigh` 会限速但可能拖慢任务。
- **`oom_score_adj` 高的小进程被牺牲**：不要急着给它加保护，先用 `systemd-cgtop -m` /
  `memory.peak` 找出真正的大户。
- **只有 PSI 预警、还没 OOM**：这正是介入窗口，改并发或限额，比等被杀强。

提建议时给出具体命令、代价和回滚方式（drop-in 删掉即回默认），并明确**这只是建议，
尚未执行**。

## 第七步：安全边界

- 只读、永远安全：`journalctl`、`cat /proc/pressure/memory`、`cat /sys/fs/cgroup/...`、
  `oomctl`、`systemd-cgtop`、`free -h`、`swapon --show`。
- **不要为了"不再 OOM"擅自改系统配置**：oomd 的 `SwapUsedLimit`、cgroup 限额、swap 布局、
  `oom_score_adj` 都会影响整机行为，改错方向会让系统在更糟的时刻被杀。
- **不要建议关闭 systemd-oomd 或禁用 OOM killer**。那不会解决内存不足，只会让内核在更晚、
  更不可控的时刻动手，通常一次杀得更多。
- 不要把 `SIGKILL` 当崩溃，也不要在 `coredumpctl` 里找不存在的 core。

## 第八步：给出报告

结构固定，不要长篇大论：

1. **事实**：layer、受害者（pid / comm / anon-rss）、cgroup 或 unit、时间、constraint。
2. **当前状态**：PSI 的 full avg10/avg60、内存与 swap 余量，是否仍在压力下。
3. **判断**：真用爆 / 撞限额 / 被 oomd 按 swap 策略牺牲 / 只是预警，依据是什么。
4. **建议动作**：一条命令或一个改动 + 代价 + 回滚方式。
5. **是否值得上报**：见下。

要把这些事实直接交给 agent，跑 `cachyos-agent-oom --latest` 即可（见第五步）。

## 附：本机真实案例（2026-10-14，可直接对照）

同一天出现了**两类完全不同的 OOM**，正好说明为什么必须先分层：

- **09:21:33 / 09:26:13 systemd-oomd** 各标记一个 kitty scope 待杀
  （`kitty-5467-1.scope`、`kitty-20738-0.scope`）。理由文本是
  `memory used (31602503680) / total (32751992832) and swap used (60472098816) / total
  (67110952960) being more than 90.00%`，候选的 `Swap Usage` 为 48.7G / 49.1G。
  → 整机内存+swap 双双接近打满，是**资源真的耗尽**。
- **09:28:23 / 09:28:36 / 09:28:54 内核 memcg OOM**，连杀三次 `node-MainThread`
  （`anon-rss` ≈ 3.1G，`oom_score_adj=200`），scope 分别是
  `run-p24156-i31266.scope`、`run-p24187-i4870.scope`、`run-p24241-i3754.scope`。
  → 单次只有 3G，机器 30G，是短命 `systemd-run` scope 撞到了**局部边界**。
- 同期全局 KOOM（`constraint=CONSTRAINT_NONE`）**0 次**；父级 `app.slice` 的
  `memory.events` 记到 `oom_kill 3`，`memory.peak` 23.5G、`memory.swap.peak` 54.4G。

排查顺序就照本 skill：先 `journalctl` 分来源，再看 PSI 与 swap，最后用父 cgroup 计数
确认次数，别把这两件事混成"今天内存不够"一个笼统结论。

## 如果是本项目的 bug

- 若被杀的是 `cachyos-*` 命令或本项目部署的 unit，或本项目设的限额导致了 OOM → 提到
  <https://github.com/skynit/CachyOS-Niri-Installer>，附：`last-oom` 内容、
  `journalctl` 摘录、`free -h`、`swapon --show`、`cat /proc/pressure/memory`。
- 若被杀的是 Niri / DMS / kitty / Firefox 等上游进程 → OOM 本身通常**不是它们的
  bug**，而是资源配置或工作集问题；除非有明确的上游内存泄漏证据，否则不要报成上游缺陷。
- 公开前脱敏：`last-oom` 与 memcg 路径里含用户名和进程名。

## 不要做的事

- 不要用 `diagnose-crash` 的 coredumpctl 流程处理 OOM（没有 core）。
- 不要用 `MESSAGE_ID=` 过滤 OOM 消息（实测 ID 为空）。
- 不要在 `journalctl` 里写 `-n 0`：本机 systemd 262 下 `-n 0` 与任何过滤条件组合都不会
  返回真实记录（只回一行 `-- No entries --`），看着配好了其实什么都收不到。需要跟随时用
  `-f -n 1`，或干脆不写 `-n`。
- 不要按日志行数统计 OOM 次数（一次事件多条消息，要按 pid + 时间戳去重）。
- 不要凭"内存不够"就给所有服务加限额，也不要建议关闭 OOM killer / systemd-oomd。
- 不要在证据不足时断言"内存泄漏"或"加内存就好"。
