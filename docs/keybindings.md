# 默认快捷键

安装器直接管理 `assets/niri/config.kdl`、`assets/niri/binds.kdl` 和
`assets/niri/cachyos-extras.kdl`。DMS 根据 `assets/dms/desktop-settings.json` 生成
配色、布局、输出、光标和模糊配置，因此这些自动生成文件不会被项目强制覆盖。

新机可以复刻稳定的 Niri 行为、窗口规则、Overview 设置和整套快捷键。动态配色仍取决于
所选壁纸；项目不复制本机个人壁纸、账号、令牌、Cookie、密钥或应用私有状态，因此不承诺
像素级复刻当前桌面。改键前先看文末“配置归谁管”。

## 常用应用与系统操作

```text
Super+Shift+/              搜索快捷键教程
Super+F1 / Super+Space     切换 Fcitx5 输入法
Ctrl+Space                切换 Fcitx5 输入法
Super+F2                   打开 DMS 设置
Super+F3                   打开录屏菜单
联想功能键模式下，Super+静音/音量-/音量+ 分别等价于 Super+F1/F2/F3
Super+F5                   创建 Snapper 快照（必要时打开 Kitty 请求 sudo）
Super+F8                   打开 Snapper 快速回滚选择器
Super+/                    打开 Kitty 临时终端
Super+T                    打开 Kitty 单实例终端
Super+Enter                打开独立 Kitty 终端
Super+B                    打开 Firefox
Super+Alt+O                用 OpenCode 启动 AI agent（自动带无人值守旗标）
Super+Alt+C                用 Claude Code 启动 AI agent
Super+`                    启动默认 AI agent（未设置时弹出选择器）
Super+Alt+B                打开 Obsidian
Super+P                    提取当前窗口信息并复制
Super+E                    打开 Thunar，失败时回退 Nautilus
Super+Alt+E                打开 Nautilus
Super+Z                    打开 DMS Spotlight，失败时回退 Fuzzel
Super+Alt+W / Super+Y      打开 DMS 壁纸选择器
Super+O / Super+G          打开或关闭 Niri Overview
Super+Q                    正常关闭当前窗口
Alt+4 / Alt+F4             强制结束点选窗口
Alt+Shift+F4               强制结束点选窗口及其进程树
Super+X                    打开 DMS 电源菜单
Super+Alt+V                打开 DMS 剪贴板
Super+Shift+N              打开 DMS 记事本
Super+Alt+L                锁屏
Super+Alt+P                锁屏、关闭显示器并休眠
Ctrl+Alt+Delete            打开 DMS 任务管理器
Super+Shift+W              打开 DMS 窗口规则工具
Super+BackSpace            打开/关闭 Top 系统面板
```

## 窗口、列、显示器与工作区

```text
Super+方向键 / H J K L     切换列或列内窗口
Super+Ctrl+方向键 / HJKL   移动列或列内窗口
Super+S / Super+W          向下或向上移动列内窗口
Super+Home / End           聚焦第一列或最后一列
Super+Ctrl+Home / End      将当前列移到第一列或最后一列
Super+Shift+方向键 / HJKL  切换显示器
Super+Ctrl+Shift+方向键    将当前列移动到相邻显示器
Super+Ctrl+Shift+HJKL      将当前列移动到相邻显示器
Super+Ctrl+Shift+WASD      将当前列移动到相邻显示器
Super+Alt+Shift+方向键     将整个工作区移动到相邻显示器
Super+Alt+Shift+HJKL/WASD  将整个工作区移动到相邻显示器
Super+鼠标滚轮             左右切换列
Super+Ctrl+鼠标滚轮        左右移动列
Super+Shift+鼠标滚轮       切换工作区
Super+Ctrl+Shift+鼠标滚轮  将当前列移动到相邻工作区
Super+[ / ]                向左或向右吸收/移出窗口
Super+A / D                向左或向右吸收/移出窗口
Super+, / .                合并窗口到列或从列中移出
Super+Shift+A / D          合并窗口到列或从列中移出
Super+Shift+X              切换列标签页模式
Super+R                    切换预设列宽
Super+Shift+R              切换预设窗口高度
Super+Ctrl+R               重置窗口高度
Super+F                    最大化当前列
Super+Alt+F                当前窗口全屏
Super+Ctrl+F               扩展列到可用宽度
Super+C                    居中当前列
Super+Ctrl+C               居中全部可见列
Super+- / =                减少或增加列宽
Super+Shift+- / =          减少或增加窗口高度
Super+V                    切换当前窗口浮动状态
Super+Shift+V / Super+N    在浮动和铺排窗口间切换焦点
Alt+` / Super+Alt+N        在浮动和铺排窗口间切换焦点
Super+1 ... Super+9        切换到数字工作区
Super+Ctrl+1 ... Super+Ctrl+9  将当前列移到数字工作区
Super+U / I                切换到下一个或上一个工作区
Super+Ctrl+U / I           将当前列移到相邻工作区
Super+Shift+U / I          重新排列工作区
Ctrl+Shift+R               重命名工作区
```

## 侧边栏、截图、媒体与补充功能

```text
Super+Alt+S / Super+M      将窗口加入或移出侧边栏
Super+Alt+Z                显示或隐藏侧边栏
Super+Alt+X                翻转侧边栏
Super+Alt+R                重新排列侧边栏窗口
Print / Super+Alt+A        区域截图
Ctrl+Print                 当前窗口截图
Shift+Print                当前显示器截图
Super+Shift+S              区域截图并使用 Satty 编辑
音量、媒体、亮度功能键      通过 DMS IPC 控制
Super+\                    问 AI：把选中/剪贴板/暂存改动交给 agent
Super+Shift+\              续接最近的 AI 会话（四个工具合并列表）
Super+' / Super+F9         开始或结束本地听写（装了听写才有这两个键）
Super+Ctrl+F2/F3/F4        顶栏、底栏和 Waybar 开关
Super+Ctrl+F9              开始或停止区域录屏
Super+Shift+F9             开始或停止 GIF 录屏
Super+Ctrl+F10             打开 Waypaper
Super+Ctrl+F11             区域截图并使用 Satty 编辑
Super+Ctrl+Shift+F11       连续翻页并智能拼接长截图
Super+Ctrl+F12             立即锁屏
Super+Shift+F12            锁屏并关闭显示器
Super+Alt+F5               将当前窗口加入或移出侧边栏
Super+Alt+Shift+F5         显示或隐藏侧边栏
Super+Alt+Ctrl+F5          翻转侧边栏位置
Super+Alt+F6               切换 nirius 窗口跟随模式
Super+Alt+F7               打开 Woomer 放大镜
Super+Alt+F8               打开官方 Niri Overview
Super+Alt+1                聚焦或启动 Firefox
Super+Alt+2                聚焦或启动 Kitty
```

`Super+Escape` 用于切换应用的快捷键抑制，`Super+Shift+E` 用于退出 Niri；后者会结束当前桌面会话，
使用前应保存工作。

## 配置归谁管

| 文件 | 谁维护 | 改法 |
| --- | --- | --- |
| `~/.config/niri/config.kdl` | 安装器（`assets/niri/config.kdl` 渲染 `@HOME@` 后写入） | 改仓库里的模板，或先 `cachyos-config protect` 再手改 |
| `~/.config/niri/dms/binds.kdl` | 安装器（`assets/niri/binds.kdl`） | 同上 |
| `~/.config/niri/cachyos-extras.kdl` | 安装器（`assets/niri/cachyos-extras.kdl`） | 同上 |
| `~/.config/niri/dms/colors.kdl` 等 | DMS 根据设置生成 | 改 DMS 设置，不要手改 |
| `~/.config/niri/cachyos-voxtype.kdl` | `cachyos-voxtype-install` / `-remove` | 装了听写才存在，由命令管理 |

因此新增或修改快捷键时，优先改仓库里的 `assets/niri/*.kdl` 再重跑安装器；只在本机调整则用：

```bash
cachyos-config protect ~/.config/niri/cachyos-extras.kdl   # 让 cachyos-config update 不覆盖
niri msg action load-config-file                            # 重载（旧版 niri 用 reload-config）
```

`Super+Shift+/`（`cachyos-keybind-help`）会读取当前配置并搜索快捷键，适合忘了某个键时用。
AI 相关的启动、提问与续接命令见 [ai.md](ai.md)。
