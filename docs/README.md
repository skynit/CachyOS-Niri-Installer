# 项目文档索引

本仓库的文档分三层，避免把安装、桌面、AI 和验收的所有细节堆在一个文件里：

1. **[根 README](../README.md)** —— 纯入口与索引：项目是什么、快速开始、模块表、边界；细节全部引用下面两层。
2. **`docs/*.md`** —— 按模块拆分的说明：装什么、怎么用、怎么改、怎么验收。
3. **`assets/dms-plugins/*/README.md`** —— 7 个随包 DMS 插件各自的 README。它们是插件的
   随包资产，会被原样安装到 `~/.config/DankMaterialShell/plugins/<插件>/README.md`，所以
   留在插件目录里维护；插件总览见 [dms-plugins.md](dms-plugins.md)。

## 模块文档

| 文档 | 内容 | 什么时候读 |
| --- | --- | --- |
| [preview.md](preview.md) | 状态栏/用量面板截图与安装器界面 | 想先看成品长什么样 |
| [architecture.md](architecture.md) | 系统构成、分层图、数据流、仓库与安装后的文件位置 | 想先弄清整体结构 |
| [install.md](install.md) | 使用前提、CachyOS 镜像下载与校验、双系统、`install.sh` 选项与安装过程 | 第一次安装或复刻新机 |
| [apps.md](apps.md) | `packages.sh` 里的仓库包、AUR 包、DMS 功能包与硬件包 | 想知道默认装了什么 |
| [desktop.md](desktop.md) | DMS/Niri/Overview、Waybar、截图录屏、窗口工具、中文输入、首次登录初始化 | 用桌面功能或排查桌面问题 |
| [keybindings.md](keybindings.md) | 完整快捷键表，以及快捷键配置文件由谁管理 | 找某个快捷键或改键 |
| [ai.md](ai.md) | AI 层总览、agent 启动层、问一问、跨工具续接、跑完提醒、技能、AI 集成面板、配置镜像、隐私与排查 | 使用或扩展 AI 层 |
| [crash-oom.md](crash-oom.md) | 崩溃诊断与 OOM/内存压力诊断两条链路 | 进程崩溃、被 OOM 杀掉 |
| [usage.md](usage.md) | Agent 用量统计的数据链路、token 语义与定价 | 看用量面板或加采集器 |
| [dms-plugins.md](dms-plugins.md) | 7 个随包插件、启用与状态栏接线、helper 构建与许可 | 用插件或同步上游插件 |
| [voxtype.md](voxtype.md) | 可选组件：本地听写（Voxtype + Whisper） | 想用语音输入 |
| [power.md](power.md) | 锁屏、休眠与电源策略 | 调整锁屏时间或休眠行为 |
| [maintenance.md](maintenance.md) | 配置更新/保护/迁移、卸载与 HOME 残留、系统维护、DMS 版本更新 | 长期使用与升级 |
| [verification.md](verification.md) | 安装后验收、`tests/`、`verify.sh`、插件测试与硬件检查 | 装完或改完要验收 |
| [design.md](design.md) | 与 Omarchy 的关系、官方 Niri 差异、明确不会执行的操作、已知限制 | 想理解取舍与边界 |

## 仓库根目录的补充材料

| 文件 | 说明 |
| --- | --- |
| [安装流程与美化应用清单.md](../安装流程与美化应用清单.md) | 早期按阶段记录的安装流程与美化清单，作为历史参考；具体行为以当前脚本和本文档为准 |
| [AI-AGENT-INTEGRATION-PLAN.md](../AI-AGENT-INTEGRATION-PLAN.md) | AI 层移植计划与实施记录，包含设计推演和被否决的方案 |
| [docs/images/](images/) | 截图与架构图；架构图由 [make-architecture.py](make-architecture.py) 生成 |

## 维护约定

- **一个事实只写一处。** 某模块的细节写在它的文档里，其他页只链接过去；根 README 只保留
  入口级信息。
- **改功能时同 PR 改文档。** 新增命令、插件、快捷键、单元或选项时，更新对应模块页；新增
  模块时在 `docs/` 加一页，并在本索引与根 README 的模块地图各加一行。
- **易漂移的数字要给出出处。** 例如命令数、包数、插件数，尽量写明「由 `ls bin` /
  `packages.sh` / `assets/dms-plugins/` 得出」，便于复核。
- **架构图不要手改。** 改完结构后运行：

  ```bash
  python3 docs/make-architecture.py   # 需要 rsvg-convert 或 inkscape 才能同时生成 PNG
  ```
