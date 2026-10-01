# Niri 配置

## 文件布局

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `~/.config/niri/config.kdl` | 安装器渲染 `assets/niri/config.kdl` | 安装时把模板里的 `@HOME@` 替换成实际家目录 |
| `~/.config/niri/dms/binds.kdl` | 安装器 `assets/niri/binds.kdl` | 全部快捷键都在这里 |
| `~/.config/niri/cachyos-extras.kdl` | 安装器 `assets/niri/cachyos-extras.kdl` | 窗口规则与项目扩展 |
| `~/.config/niri/dms/{colors,layout,alttab,outputs,cursor,wpblur}.kdl` | **DMS 生成** | 动态配色、布局、光标、模糊；不要手改，会被 DMS 重写 |

主配置通过 `include optional=true` 引入以上文件，所以任何一个文件缺失都不会让 Niri
启动失败：

```
include optional=true "dms/colors.kdl"
...
include "cachyos-extras.kdl"
```

## 关键事实

- **`Mod` 与 `Super` 是同一个键**，两种拼写在 `binds.kdl` 里等价。
- 26 个字母键**全部已被占用**。想加两键快捷键只能用非字母键；`Mod+X` 也不行
  （`Super+X` 是 DMS 电源菜单）。可用的空闲键包括
  `` Mod+grave ``、`Mod+BackSpace`、`Mod+Delete`、`Mod+Backslash`、`Mod+Insert`、
  `Mod+F4/F6/F7/F9/F10/F11/F12`。
- 快捷键绑定格式：

  ```kdl
  Mod+Alt+O hotkey-overlay-title="AI助手 opencode agent" { spawn "cachyos-agent" "opencode"; }
  ```

  `hotkey-overlay-title=null` 表示不在快捷键浮层里显示这一条。

## 查找与修改快捷键

```bash
cachyos-keybind-help          # Kitty + fzf，按快捷键/说明/动作/分组搜索
dms keybinds show niri        # 输出 JSON，可接 jq
niri validate                 # 校验配置语法
niri msg action <action>      # 运行时执行一个动作
```

修改步骤：

1. `cachyos-config protect ~/.config/niri/dms/binds.kdl`（否则下次更新会被覆盖）
2. 编辑该文件，用 `niri validate` 校验
3. Niri 会自动重载配置；不必重启会话
4. 若把绑定交给项目维护，应改安装器里的 `assets/niri/binds.kdl` 并重跑 `./install.sh`

## 窗口规则

窗口规则写在 `cachyos-extras.kdl`（同样受托管，改动前先 `protect`）。示例：

```kdl
window-rule {
    match app-id="^quickshell$"
    // ...
}
```

窗口的 `app-id` 可用 `cachyos-niri-pick focus` 或 `niri msg windows` 查询。

## 输出与显示器

`~/.config/niri/dms/outputs.kdl` 由 DMS 生成，不要手改。用 DMS 的设置界面或
`dms ipc call outputs ...` 调整。

## 常见坑

- `config.kdl` 里的 `@HOME@` 是**安装期模板占位符**，运行时文件里不应该再出现它。
- 托管文件被改动后，`./verify.sh` 会因逐字节比较失败而报 FAIL——这是预期行为，
  说明该文件已被用户改动；要么 `protect` 它，要么恢复原样。
