# 设计取舍与边界

本页记录“为什么这样做”：与 Omarchy 的关系、与官方 Niri 的能力差异、明确不会自动执行的操作，
以及已知限制。功能细节见各模块页，入口见[文档索引](README.md)。

## 与 Omarchy 的关系

AI Agent 这一层是**借鉴 [Omarchy](https://omarchy.org/) 的设计**做的。Omarchy 是 DHH 主导
的 Arch + Hyprland 发行版，它把 AI 编程 agent 当作一等公民集成；本项目在
**CachyOS + Niri + DMS** 上重新实现了同样的思路，并按本项目的约定改写。

### 直接借鉴的做法

| Omarchy 的做法 | 本项目的实现 | 为什么照搬 |
| --- | --- | --- |
| `bin/omarchy-agent` 用一张 `case` 表统一各 agent 的“无人值守”旗标 | `assets/lib/agent.sh` 的 `cachyos_agent_command` | 每个 agent 的旗标都不同（`--auto` / `--permission-mode auto` / `--approve-for-me`…），散落在快捷键里必然漂移。本项目把它抽成**纯函数库**，因此可以单测 |
| 固定 app-id，让所有 agent 窗口共用一类 | kitty `--class cachyos-agent` | 一条窗口规则或主题即可覆盖全部 agent 窗口 |
| prompt 单独成一条命令（裸 prompt 会遮蔽子命令） | `cachyos-agent-prompt` | 上游注释里写明了这个理由 |
| prompt 前放 `--`，避免以横线开头的内容被当成选项 | 四个 agent 统一处理（`opencode` 用自己的 `--prompt`） | 上游为 `cursor-agent` 的子命令歧义专门解释过 |
| 从 `$HOME` 启动时切到工作目录 | 仅在 `~/Work` 已存在时才切 | agent 不记忆 `$HOME` 的信任，否则每次都要重新确认 |
| 用固定 MESSAGE_ID 订阅 systemd-coredump | `bin/cachyos-crash-watch` | 结构化字段比核心文件名信息更多 |
| 崩溃记录先写、通知后发 | 同 | 通知可能丢（无 D-Bus、勿扰、通知服务刚死），记录是诊断入口的唯一依赖 |
| 崩溃详情以独立 argv 传参，绝不拼命令字符串 | 同 | 进程名是攻击者可控的 |
| 崩溃去重 + 按程序静音 | 同，另加“每程序最多一条待处理通知” | 崩溃循环会反复转储 |
| 诊断方法只写一份（skill），prompt 里只放事实 | `assets/agent-skills/diagnose-crash/`（OOM 对称：`diagnose-oom/`） | 换任何 agent 都适用，方法也只维护一份 |
| 把系统知识做成技能并软链给各 harness | `cachyos-agent-skills` + `cachyos` 技能 | 让 agent 知道哪些配置受托管、改前先 `protect` |
| 在脚注里写清“为什么”与被否决的替代方案 | 本项目沿用同一风格 | 这是 Omarchy 最值得学的一点 |

### 没有照搬的部分

| Omarchy 的做法 | 本项目的选择 | 原因 |
| --- | --- | --- |
| `pacman` pre-transaction guard + `omarchy update` 更新管线 | 用 CachyOS 自己的 `pacman -Syu` / `cachyos-system-update` | 与 CachyOS 现有机制直接冲突，且会接管不属于本项目的更新路径 |
| 每用户迁移系统（数百个时间戳脚本） | `cachyos-config update` + manifest | 本项目规模不需要那套机器 |
| 470 个命令的 CLI 路由器（元数据头 + 最长前缀匹配） | 显式 `cachyos-*` 命令 + `verify.sh` 遍历 | 本项目安装的 73 个 `cachyos-*` 命令用不上路由层 |
| mise stub 按需安装 agent | 用 pacman / AUR 安装 | 不引入第二套包管理器 |
| `omarchy-shell` 的 QML 插件 | DMS 插件（`plugin.json`） | 宿主不同，插件 API 完全不同 |
| `omarchy-theme-set-hermes` | `cachyos-agent-theme-sync` 的 Hermes 分支 | skin 格式相同（`name`/`description`/`colors` 44 键），配色来自 DMS 而不是静态主题 |
| `omarchy-toggle-crash-capture` | `cachyos-toggle-crash-capture` | 同样用“标记文件 + 单元条件”实现跨登录关闭 |
| 用 `--exec` 绕开“shell 不回发 ActionInvoked” | 直接用 `notify-send -A -w` | 在本项目实测 DMS（quickshell）**会**回发 `ActionInvoked`，不需要绕 |

## 官方 Niri 与修改版功能差异

本项目只安装官方 Niri，不安装第三方 fork，因此以下功能是中性替代，不是完全复刻：

| 目标功能 | 当前实现 | 差异 |
| --- | --- | --- |
| 概览 | 官方 Niri Overview + DMS Overlay | 不提供 fork 的私有网格布局和交互 |
| 暗色模糊概览背景 | DMS Overview 模糊 + Niri 深色 backdrop | 常驻模糊壁纸层保持关闭 |
| 放大镜 | `Super+Alt+F7` 手动启动 Woomer | 不支持鼠标快速晃动自动放大 |
| 热角 | Waycorner | 独立工具实现，不依赖修改版 Niri |
| 窗口跟随/快速聚焦 | nirius | 独立辅助服务实现 |
| 侧边栏 | niri-sidebar | 独立辅助服务实现 |

DMS Overlay 不会为官方 Niri 增加 fork 的私有网格实现。鼠标晃动放大也未实现，当前提供的是
明确快捷键触发的 Woomer。

## 明确不会自动执行的操作

本安装器不会：

- 添加 ArchLinuxCN 或其他第三方软件仓库。
- 修改 `/etc/pacman.conf` 或 CachyOS 软件源。
- 切换 NetworkManager 到 IWD，或删除现有网络连接。
- 安装、重写或自动切换 GRUB、Limine、systemd-boot。
- 修改 Secure Boot、Windows 分区或双系统设置。
- 自动安装第三方 Wi-Fi DKMS 驱动。
- 自动重启。

## 已知限制

- **选择器需要终端或 Kitty**（`cachyos-agent` / `cachyos-ask` / `cachyos-agent-resume` 的
  fzf 选择器）；两者都没有时，只能用 `cachyos-default-agent <agent>` 直接指定。
- **不承诺像素级复刻桌面**：动态配色取决于所选壁纸，项目不复制个人壁纸、账号、令牌、Cookie、
  密钥或应用私有状态。能复刻的是软件、配置、快捷键与受管设置。
- **AI 层是可选层**：agent 未安装、未登录或权限策略不同时，启动/提问/续接会失败，但不会影响
  桌面启动；单点失败只警告。
- **崩溃与 OOM 监听只覆盖运行期间的新事件**，且 OOM 只在 niri 用户会话内运行；细节与设计原因见
  [crash-oom.md](crash-oom.md#已知限制两条链路共有)。
- **DMS 版本被钉住**：低于随包插件 `requires_dms` 的 DMS 不会加载对应插件；升级流程见
  [maintenance.md](maintenance.md#dms-版本更新)。
- **听写只能 toggle**：Niri 不支持按键释放绑定，无法实现“按住说话”；见
  [voxtype.md](voxtype.md)。
- **安装器不自动重启**：需要用户手动重启并在 Ly 中选择 Niri；首次登录初始化在后台执行。

## 项目内的命名与结构约定

- **命令前缀**：所有本项目的命令以 `cachyos-` 开头（唯一例外是 `terminal-here`），便于
  `verify.sh` 遍历与用户识别；桌面/系统类命令不占用通用名字。
- **代码与状态分离**：命令在 `/usr/local/bin/`，随包资源在
  `/usr/local/share/cachyos-desktop/`，运行状态在 `~/.local/state/cachyos-desktop/`。
- **受管 vs 用户配置**：受管配置进 `config-manifest.tsv`，可由 `cachyos-config` 更新；
  用户自己的配置（`ask-actions.conf`、`ai-settings.conf`、默认 agent）不进清单，重装不覆盖。
- **只做事实传递**：诊断命令只把结构化事实交给 agent，方法论写在技能里；这样换 agent 不需要
  改命令，方法也只维护一份。
