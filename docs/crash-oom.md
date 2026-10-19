# 崩溃与 OOM 诊断

崩溃（coredump）和内存耗尽（OOM）是**两条独立链路**：前者有 systemd 固定 MESSAGE_ID，
后者由内核直接 SIGKILL、不产生 coredump。两条链路都做成“监听 → 记录 → 通知 → 交给 agent 分析”，
诊断方法写在技能里，换任何默认 agent 都适用。AI 层总览见 [ai.md](ai.md)。

## 崩溃诊断

`cachyos-crash-watch.service` 常驻监听 systemd-coredump。`cachyos-toggle-crash-capture` 可以整体关掉它：
关闭时写一个标记文件（单元里的 `ConditionPathExists=!` 让它在下次登录时也不启动），并立刻停掉当前会话的
监听——所以“关掉”是一次性动作，不用每次登录再关一遍。

进程崩溃后会：

1. 把 `pid`/`comm`/`exe`/`signal`/时间写入
   `~/.local/state/cachyos-desktop/agents/last-crash`；
2. 发一条通知。同一程序 60 秒内**只记录并提醒一次**——去重判断在写记录之前，所以窗口内的
   第二次崩溃既不记录也不提醒（`CACHYOS_CRASH_DEDUPE_SECONDS` 可调）。

诊断入口：

```bash
cachyos-agent-crash --latest        # 用默认 agent 诊断最近一次记录到的崩溃
cachyos-agent-crash 1516893         # 指定 PID（PID 见 coredumpctl list）
cachyos-crash-mute                  # 列出已静音的程序
cachyos-crash-mute SomeApp          # 不再提醒该程序
cachyos-crash-mute SomeApp off      # 恢复提醒
```

通知默认就是**可点击的动作式**：点通知上的「用 AI 诊断」会把崩溃的四个字段
（进程 / PID / 程序 / 信号）一并交给默认 agent（已在真实桌面会话上验证通知服务会回发
动作）。想要只提示、不等待点击，就设 `CACHYOS_CRASH_ACTION=0` 启动 watcher；动作式
通知发不出去时也会自动退回提示式。

几个刻意的设计：

- **同一个程序最多保留一条待处理通知。** 动作式通知会一直等到用户处理（`-t 0` 不自动
  过期），若每次都新起一个，崩溃循环会让通知和等待进程无上界堆积。
- **通知在后台发送**，不阻塞检测循环——否则用户还没点的那段时间里发生的崩溃都不会被记录。
- **静音按内核的程序名长度对齐**：内核只记录 `comm` 的前 15 字节，所以
  `cachyos-crash-mute gnome-keyring-daemon` 会按 `gnome-keyring-d` 静音（并给出提示）。
  静音只是不再提醒，程序该崩还是会崩。
- **`cachyos-agent-crash` 只把事实交给 agent**，诊断方法本身写在 `diagnose-crash` 技能里，
  因此换任何默认 agent 都适用，方法也只维护一份。

## OOM 诊断

内存耗尽与进程崩溃是**两条独立链路**。`cachyos-crash-watch` 订阅的是 systemd-coredump 的固定
MESSAGE_ID，而 OOM 由内核以 **SIGKILL** 结束进程——**既不产生 core dump，那条 MESSAGE_ID 也就
永远不会出现**，所以崩溃监听对 OOM 完全无感，必须有另一套监听。

`cachyos-oom-watch.service` 常驻盯着三种来源：

1. **内核 memcg OOM**：某个 cgroup 打到 `memory.max` 时内核直接杀进程，内核日志里是 `oom-kill`；
2. **systemd-oomd kill**：oomd 依据 PSI 与 swap 占用提前动手，杀掉整个 cgroup；
3. **PSI 内存压力提前预警**：内存还没耗尽、但压力已经持续吃紧时先提醒——这是唯一还来得及处理的时机。

`cachyos-toggle-oom-capture` 与 `cachyos-toggle-crash-capture` 是同一套实现：关闭时写一个标记文件
`~/.local/state/cachyos-desktop/toggles/oom-capture-off`，单元里的 `ConditionPathExists=!` 让它在
下次登录时也不再启动，同时立刻停掉当前会话的监听——所以“关掉”是一次性动作，不用每次登录再关一遍。

OOM 发生后，事实会记录到 `~/.local/state/cachyos-desktop/agents/last-oom`（与崩溃的 `last-crash`
并列），并发出一条通知。

诊断入口：

```bash
cachyos-agent-oom --latest          # 用默认 agent 诊断最近一次记录到的 OOM
cachyos-toggle-oom-capture off      # 关闭 OOM 监听（本次会话 + 下次登录都不启动）
cachyos-toggle-oom-capture on       # 恢复 OOM 监听
journalctl -k | grep oom-kill       # 手动核对内核的 OOM 记录
```

诊断方法本身写在 `diagnose-oom` 技能里，`cachyos-agent-oom` 只把事实交给 agent——与崩溃链路一样，
换任何默认 agent 都适用，方法也只维护一份。

OOM 监听与通知的参数（去重窗口、PSI 阈值、通知动作）也可以在 DMS「AI 集成」面板里改，见
[ai.md](ai.md#ai-集成面板)。

## 已知限制（两条链路共有）

- **只覆盖监听运行期间的新事件。** 崩溃监听只在服务运行期间生效：服务重启（例如更新）窗口内的
  崩溃不会被补报——订阅用 `journalctl -f -n 1` 建立，再按“订阅时刻”这一水位把带出来的那条历史
  记录丢掉。历史版本用的是 `-f -n 0`，而实测 systemd 262 上 `-n 0` 只要和任何过滤条件组合
  （`MESSAGE_ID=` / `-k` / `-t` / `-u`）就会静默返回 0 行：服务看着 active、日志里
  一句错误都没有，实际永远收不到任何崩溃——所以**不要**把它改回去。
- **OOM 同样只跟新消息**：`journalctl` 的 follow 流配一个“启动时间戳”水位
  （`-f -n 1` 带出的那条旧记录会被水位挡掉），所以服务重启或未运行的窗口内发生的 OOM 不会补报。
- **同一次 OOM 会收到两条内核消息。** 内核会先后发 `oom-kill` 与 `Memory cgroup out of memory`
  两条消息；去重键是**触发层 + 受害者 PID + 程序名**，所以同一受害者 300 秒内只提醒一次
  （`CACHYOS_OOM_DEDUPE_SECONDS` 可调）。反过来，**不同 PID 的同类 OOM 会各提醒一次**——
  本机 09:28 那种连续杀掉三个 node 进程的情形会给出三条通知，这是有意的：三次是真的三次损失。
- **PSI 提前预警默认在 `full avg60 ≥ 10%` 时触发**（`CACHYOS_OOM_PSI_FULL_AVG60` 可调；
  `CACHYOS_OOM_PSI_ENABLED=0` 可只留真实 OOM、关掉预警）。
- **OOM 监听只在 niri 用户会话内运行**（unit `WantedBy=niri.service`，每个用户各跑一份）：
  系统级 OOM、其他用户的会话，以及没登录桌面时的内存事件都不在覆盖范围内。
- **诊断会话不随服务重启被 SIGTERM**（`KillMode=process`：systemd 只杀主进程，
  同 cgroup 里的 kitty/agent 继续跑）。代价是重启 watcher 时会短暂留下一个空闲的 `journalctl`
  进程，它在下次有匹配输出时因 SIGPIPE 自行退出。
- 通知依赖桌面通知服务；无 D-Bus、勿扰或通知服务刚死时，记录仍会写入，只是提醒丢失。
