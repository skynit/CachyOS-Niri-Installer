# CachyOS + Niri + DankMaterialShell

> 目标系统：[CachyOS](https://cachyos.org/)（Arch 派生，软件包按 x86-64-v3/v4 与 Zen4 指令集编译，
> 使用 `linux-cachyos` 内核）。基础系统尚未安装时，先按
> [安装文档](docs/install.md#下载并安装-cachyos)装好，再运行本项目的安装脚本。

这是一个面向已安装 CachyOS 的 x86_64 设备的完整桌面配置安装器，默认部署：

```text
CachyOS + 官方 Niri + DMS v1.6.2 + Quickshell + Kitty
```

应用、桌面增强和维护工具全部默认安装，不提供按功能拆分的可选开关。默认终端是
Kitty；DMS 负责主面板、启动器、通知、锁屏和动态主题，Quickshell 是 DMS 的运行基础。
AI 编程助手作为**独立的一层**：启动、提问、续接、崩溃/OOM 诊断、用量、主题同步，
不依赖桌面也能单独使用。

## 快速开始

前提：已安装 CachyOS、使用可 `sudo` 的普通用户、联网、`x86_64`；不要在 Live ISO 中运行。

```bash
./install.sh --dry-run     # 先看完整计划，不修改系统
./install.sh               # 执行安装（不会自动重启）
bash tests/run-all.sh      # 纯函数/stub 测试，不需要桌面环境
./verify.sh                # 安装后验收
```

安装细节、CachyOS 镜像下载与双系统见 [安装文档](docs/install.md)；验收与故障定位见
[验收文档](docs/verification.md)。

## 模块文档

本 README 只做入口和索引，细节按模块分散在 `docs/` 下，各模块页再互相引用：

| 模块 | README |
| --- | --- |
| 界面预览 | [docs/preview.md](docs/preview.md) |
| 系统构成与文件位置 | [docs/architecture.md](docs/architecture.md) |
| 安装（含 CachyOS、双系统） | [docs/install.md](docs/install.md) |
| 默认应用与包清单 | [docs/apps.md](docs/apps.md) |
| 桌面功能 | [docs/desktop.md](docs/desktop.md) |
| 快捷键 | [docs/keybindings.md](docs/keybindings.md) |
| AI 层（启动、提问、续接、面板） | [docs/ai.md](docs/ai.md) |
| 崩溃与 OOM 诊断 | [docs/crash-oom.md](docs/crash-oom.md) |
| Agent 用量统计 | [docs/usage.md](docs/usage.md) |
| 7 个随包 DMS 插件 | [docs/dms-plugins.md](docs/dms-plugins.md)（各插件另见 `assets/dms-plugins/*/README.md`） |
| 本地听写（可选） | [docs/voxtype.md](docs/voxtype.md) |
| 锁屏与电源 | [docs/power.md](docs/power.md) |
| 配置更新、卸载与系统维护 | [docs/maintenance.md](docs/maintenance.md) |
| 安装后验收与测试 | [docs/verification.md](docs/verification.md) |
| 设计取舍、已知限制 | [docs/design.md](docs/design.md) |

插件自带的 README（随插件一起安装到用户目录）：[AI 集成](assets/dms-plugins/CachyosAgents/README.md)、
[本机状态](assets/dms-plugins/LocalStatus/README.md)、
[离线翻译](assets/dms-plugins/LocalTranslate/README.md)、
[本地歌词](assets/dms-plugins/LocalLyrics/README.md)、
[连接（手机与电脑）](assets/dms-plugins/PhoneConnect/README.md)、
[专注](assets/dms-plugins/Focus/README.md)、
[Top 系统面板](assets/dms-plugins/Top/README.md)。

完整索引与文档维护约定见 [docs/README.md](docs/README.md)。仓库根目录的两份早期材料
（`安装流程与美化应用清单.md`、`AI-AGENT-INTEGRATION-PLAN.md`）也在那里说明。

## 系统构成

一句话：**CachyOS → 官方 Niri → DMS/Quickshell 外壳 → 周边组件**，AI 层独立挂在旁边。
分层图、数据流、仓库结构、安装后的文件位置与架构图生成方式统一写在
[docs/architecture.md](docs/architecture.md)。

## 边界与版本

安装器**不会**添加第三方软件源、修改 pacman 配置、切换网络管理、改写引导器或 Secure Boot、
也不自动重启。完整清单与设计原因见 [docs/design.md](docs/design.md)。

DMS 固定为 **v1.6.2**（随包插件的最低要求），DMS 安装器压缩包的 SHA-256 一并钉住；升级流程见
[docs/maintenance.md](docs/maintenance.md#dms-版本更新)。

> 文档维护：一个事实只写一处。模块细节写在对应的 `docs/<模块>.md`，插件说明留在
> `assets/dms-plugins/*/README.md`；根 README 只保留索引，新增模块时同步更新
> [docs/README.md](docs/README.md) 与本页的模块表。
