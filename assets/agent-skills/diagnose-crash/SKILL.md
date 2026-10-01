---
name: diagnose-crash
description: >
  Diagnose a process crash on this CachyOS + Niri + DankMaterialShell desktop from a
  systemd-coredump entry. Use when investigating a segfault, reading a core dump,
  deciding whether a crash is caused by user configuration or is an upstream bug, or
  preparing an upstream bug report. Triggers: coredumpctl, core dump, segfault,
  SIGSEGV, SIGABRT, crash, backtrace, "process crashed".
---

# 诊断进程崩溃

被调用时通常已经拿到这些事实：进程名、PID、可执行文件路径、信号、时间。你的任务是
**establish the facts**，然后判断这是用户配置问题还是上游 bug，最后给出可执行的下一步。

## 第一步：确认事实，不要猜

```bash
coredumpctl list <pid>            # 时间、信号、核心转储是否还在
coredumpctl info <pid>            # 完整信息：命令行、环境、栈回溯
coredumpctl info <pid> | head -40 # 先看栈顶几帧
```

要确认的：

- **信号**：`SIGSEGV`/`SIGABRT` 通常是程序 bug；`SIGTERM`/`SIGKILL` 往往是别人杀的，
  不是崩溃。
- **可执行文件路径**：`/usr/bin/`、`/usr/lib/` 下的是发行版包；`/usr/local/bin/` 是本
  项目或用户自己装的；`~/.local/` 下的是用户级安装。
- **栈顶帧是否指向某个库**：GPU 驱动（`libnvidia*`、`libvulkan*`、`libgallium*`）、
  输入法（`libfcitx5*`）、Qt/Quickshell 等会指向不同的责任方。
- **是否可复现**：一次性的崩溃与稳定复现的崩溃，处理优先级完全不同。

## 第二步：区分三类原因

| 类型 | 特征 | 下一步 |
| --- | --- | --- |
| 上层程序 bug | 崩溃点在程序自己的代码里，配置正常，可复现 | 准备上游报告 |
| 用户配置错误 | 崩溃紧跟某次配置改动；`niri validate` 报错；插件/主题是第三方克隆来的 | 回退那次改动 |
| 环境或硬件 | 栈顶在 GPU/驱动/固件库；伴随显存、休眠或外接屏问题 | 查驱动版本与内核日志 |

本项目相关的位置：

- 用户配置：`~/.config/niri/`、`~/.config/DankMaterialShell/`、`~/.config/kitty/`
- 托管配置是否被改动过：`cachyos-config status`
- 第三方内容：从 git 克隆的主题或 DMS 插件

## 第三步：安全边界

- **核心转储可能含敏感数据**（进程内存里的密钥、令牌）。不要把完整 core 或 `info`
  原始输出贴到公开 issue；只贴**栈回溯**和必要的元数据，并对路径、用户名做脱敏。
- **不要为了"修好崩溃"擅自改用户的配置**。先说明你打算改什么、为什么，得到同意再动。
  需要回退时优先用 `cachyos-quick-rollback`（Snapper 快照），而不是手工猜。
- 只读检查是安全的：`coredumpctl`、`journalctl`、`niri validate`、`cachyos-config status`。

## 第四步：输出一份简短报告

按这个结构给结论，不要长篇大论：

1. **事实**：进程、信号、栈顶 2–3 帧（脱敏后）。
2. **判断**：属于上面三类中的哪一类，以及依据。
3. **建议动作**：一条可执行命令或一个明确的改动，说明它的代价。
4. **是否值得上报**：值得的话给出对应仓库（Niri / DMS / Quickshell / 发行版包）与
   需要附上的最小信息集；不值得就说清楚为什么（例如一次性崩溃、已被上游修掉）。

## 不要做的事

- 不要把 `SIGKILL`/`SIGTERM` 当成程序缺陷来诊断。
- 不要在证据不足时断言"这是驱动问题"或"重装就能解决"。
- 不要建议用户关闭沙箱、关闭权限检查或长期运行在 root 下。
