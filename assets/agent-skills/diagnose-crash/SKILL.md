---
name: diagnose-crash
description: >
  Diagnose a process crash on this CachyOS + Niri + DankMaterialShell desktop from a
  systemd-coredump entry. Use when investigating a segfault, reading a core dump, checking
  whether a crash is caused by user configuration or is an upstream bug, deciding whether
  to mute the notification, or preparing a bug report. Triggers: coredumpctl, core dump,
  segfault, SIGSEGV, SIGABRT, SIGBUS, backtrace, "process crashed", crash loop.
---

# 诊断进程崩溃

被调用时通常已经拿到这些事实：进程名、PID、可执行文件路径、信号、时间
（来自 `~/.local/state/cachyos-desktop/agents/last-crash`，或通知里传来的参数）。任务是
**先建立事实，再判断责任方**，最后给出可执行的下一步。

## 第一步：确认事实，不要猜

```bash
coredumpctl list <pid>              # 时间、信号、核心是否还在（missing = 已轮转/未保存）
coredumpctl info <pid>              # 完整记录：命令行、环境、完整回溯
coredumpctl info <pid> | head -40   # 先看栈顶几帧
```

要确认的：

- **信号**：`SIGSEGV`/`SIGABRT`/`SIGBUS` 通常是程序缺陷；`SIGTERM`/`SIGKILL` 往往是
  **别人杀的**，不是崩溃（见第二步）。
- **可执行文件路径**：`/usr/bin/`、`/usr/lib/` 是发行版包；`/usr/local/bin/` 是本项目或
  用户自装；`~/.local/` 是用户级安装。路径决定该找谁。
- **栈顶几帧指向谁**：GPU 驱动（`libnvidia*`、`libvulkan*`、`libgallium*`）、输入法
  （`libfcitx5*`）、Qt/Quickshell，还是程序自己的代码——责任方完全不同。
- **是否可复现**：一次性崩溃与稳定复现，处理优先级和上报价值完全不同。

## 第二步：先排除"无聊原因"

很多看起来像崩溃的东西不是程序缺陷。先花 30 秒排掉，避免把分析做在错误方向上。

| 现象 | 怎么确认 | 结论 |
| --- | --- | --- |
| 被 OOM killer 杀 | `journalctl -k --since '-10 min' \| grep -i 'killed process'`；信号是 `SIGKILL`(9) | 内存问题，不是崩溃缺陷 |
| 被脚本/会话结束杀掉 | 信号是 `SIGTERM`(15) 或 `SIGHUP`(1) | 正常收尾，不是崩溃 |
| 退出码非 0 但没有信号 | `coredumpctl` 里根本没有这条记录 | 程序自己退出的，去看它的日志 |
| 只崩一次、之后不复现 | 时间点附近有挂起/恢复、驱动更新或配置改动 | 多半是环境事件，不是稳定缺陷 |

## 第三步：与时间线对齐

崩溃很少孤立发生。看崩溃**前后各 30~60 秒**的系统日志，常能一眼看到诱因：

```bash
journalctl -k --since '-5 min' --no-pager -p warning        # 内核/驱动侧
journalctl --user -u niri.service --since '-5 min' --no-pager | tail -40
journalctl --user -u dms.service  --since '-5 min' --no-pager | tail -40
grep -E 'upgraded|installed' /var/log/pacman.log | tail -20  # 刚更新过什么
cachyos-config status                                        # 哪些托管配置被改过
```

重点找：挂起/恢复、GPU 驱动或内核模块加载、`nvidia`/`amdgpu` 报错、显存耗尽、
刚改过的配置、刚更新的包。

## 第四步：读完整的 core，不要只看第 0 帧

```bash
coredumpctl info <pid>                            # 这里已有完整回溯，多数情况够用
coredumpctl gdb <pid>                             # 进 gdb：bt full / thread apply all bt
coredumpctl dump <pid> --output=/tmp/core.bin     # 需要反复分析时先导出
eu-stack -n 64 -e <可执行文件> -c /tmp/core.bin    # 没 gdb 时的快速栈
```

- **多线程程序要看所有线程**：`thread apply all bt`。崩在哪个线程、和谁竞争，往往才是关键。
- **别只看第一帧**：第一帧常是 `abort()`/`raise()` 之类的库函数，真正的调用者在上面几帧。
- 栈里出现 `??` 说明缺符号，见下一步。

## 第五步：能符号化就符号化

本机（CachyOS）**已经预配置了 DEBUGINFOD**：`/etc/profile.d/debuginfod.sh` 把
`DEBUGINFOD_URLS` 指向 `https://debuginfod.archlinux.org` 与 `https://debuginfod.cachyos.org`，
`gdb` 与 `coredumpctl` 会按 build-id 自动下载调试符号。

```bash
echo "$DEBUGINFOD_URLS"            # 非登录 shell 里可能没继承，必要时自行 export
coredumpctl gdb <pid>              # 进去后若仍有 ?? ：
# (gdb) set debuginfod enabled on
# (gdb) bt full
```

符号下不下来时（离线、服务不可达），**如实说明"栈未符号化"**，不要凭 `??`
猜函数名——那等于编造证据。

## 第六步：判断责任方

| 类型 | 特征 | 下一步 |
| --- | --- | --- |
| 上游程序缺陷 | 崩在程序自身代码里，配置正常，可复现 | 准备上游报告（见下） |
| 用户配置问题 | 崩溃紧跟某次配置改动；`niri validate` 报错；第三方克隆的主题/插件在生效 | 回退那次改动（先看 `cachyos-config status`） |
| 环境 / 硬件 | 栈顶在 GPU / 驱动 / 固件库；伴随显存、挂起恢复、外接屏 | 查驱动版本、内核日志、是否刚更新 |

本项目相关的位置：

- 用户配置：`~/.config/niri/`、`~/.config/DankMaterialShell/`、`~/.config/kitty/`、`~/.config/waybar/`
- 托管配置是否被改过：`cachyos-config status`
- 本项目自己的服务：`systemctl --user status cachyos-crash-watch.service`（日志进 journal）
- 首次登录任务：`~/.local/state/cachyos-desktop/post-login.log`

## 第七步：安全边界

- **核心转储可能含敏感数据**（进程内存里的密钥、令牌、剪贴板内容）。不要把完整 core 或
  `coredumpctl info` 的原始输出贴到公开 issue；只贴**脱敏后的栈回溯**与必要元数据。
- **不要为了"修好崩溃"擅自改用户配置。** 先说清要改什么、为什么、怎么回滚，得到同意再动。
  需要回退时优先 `cachyos-quick-rollback`（Snapper 快照），而不是手工猜。
- 只读检查永远安全：`coredumpctl`、`journalctl`、`niri validate`、`cachyos-config status`。

## 第八步：给出报告

结构固定，不要长篇大论：

1. **事实**：进程、信号、可执行文件路径、栈顶 2–3 帧（脱敏；未符号化就明说）。
2. **时间线**：崩溃前后 30 秒内值得注意的事件（挂起、更新、驱动、配置改动），没有就说没有。
3. **判断**：属于上面三类中的哪一类，依据是什么。
4. **建议动作**：一条可执行命令或一个明确改动，并说明代价与回滚方式。
5. **是否值得上报**：值得就给目标仓库与最小信息集；不值得就说清为什么。

## 如果是本项目的 bug

先确认责任方，再看目标：

- 崩溃发生在 `cachyos-*` 命令、本项目部署的 user unit、或本项目生成的配置上
  → 提到 <https://github.com/skynit/CachyOS-Niri-Installer>，附：命令与参数、相关服务日志、
  脱敏后的栈回溯。
- 崩溃在 Niri / 官方包 → Niri 或 Arch 包；在 DMS / Quickshell → DankMaterialShell；
  在 Kitty / Firefox 等 → 各自项目。

## 顺带：要不要让它别再提醒

崩溃循环会很吵。这套桌面支持按程序静音，**取得用户同意后再做**：

```bash
cachyos-crash-mute                    # 列出已静音
cachyos-crash-mute <程序名>            # 静音（按内核 15 字节上限截断）
cachyos-crash-mute <程序名> off        # 恢复提醒
```

静音只是不再提醒，程序该崩还是会崩——它是降噪，不是解决。

## 不要做的事

- 不要把 `SIGKILL`/`SIGTERM` 当程序缺陷来诊断。
- 不要在证据不足时断言"这是驱动问题"或"重装就能解决"。
- 不要凭未符号化的 `??` 编造函数名或调用链。
- 不要公开粘贴完整 core 或含敏感信息的原始输出。
- 不要建议用户关闭沙箱、关闭权限检查或长期以 root 运行。
