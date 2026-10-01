# CachyOS Agents 用量

在 DMS 状态栏显示本机 AI 编程 agent 的 token 与费用统计。数据全部在本机采集，不联网。

| 项目 | 说明 |
| --- | --- |
| 插件 ID | `cachyosAgents` |
| 安装目录 | `~/.config/DankMaterialShell/plugins/CachyosAgents` |
| 依赖 | `jq`、`python3`，以及安装器的 `cachyos-agent-usage-update`（来自 CachyOS-Niri-Installer） |
| 数据目录 | `~/.local/state/cachyos-desktop/agents/usage/*.json` |

## 它显示什么

- **状态栏**：按设置显示"今天 / 近 7 天 / 累计费用"的 token 与金额；当天没有用量时，回落到最近有数据的一天并标出日期（例如 `09-22 12.0M · $73.50`），而不是显示一个会误导人的 0。
- **弹窗**：每个 agent 一张卡片——今天与累计的 token/费用、会话数与提示数、额度条（若采集器能拿到）、按费用排序的模型明细、最近 7 天的迷你柱状图。

数据缺失时显示"未采集 / 无数据"，不会把没采到渲染成 0。

## 数据从哪来

面板只读目录，不直接跑采集器：

```text
cachyos-agent-usage-update          # 并行跑各 agent 的采集器并原子落盘
  └── ~/.local/state/cachyos-desktop/agents/usage/<agent>.json
        └── 面板读取（jq -s 合成数组）
```

这样加一个 agent 只需要加一个采集器，面板不用改。token 语义按各家对齐：Claude 的
`input_tokens` 不含缓存，Codex 的已含缓存——记录里用 `inputTokenSemantics` 标明，费用也
据此拆分输入，避免缓存被双重计费。

## 安装

```bash
mkdir -p ~/.config/DankMaterialShell/plugins/CachyosAgents
cp -r CachyosAgents/. ~/.config/DankMaterialShell/plugins/CachyosAgents/
dms ipc call plugin-scan scan
```

随后在 DMS 设置 → 状态栏 → 添加控件里选择 **CachyOS Agents 用量**，并自行决定左右位置。
用 `dms ipc call plugin-scan list` 可以确认它已被发现。

## 设置

| 设置项 | 默认 | 说明 |
| --- | --- | --- |
| 显示 Claude Code / Codex / OpenCode | 全开 | 关掉的 agent 不出现在状态栏与弹窗里 |
| 统计范围 | 今天 | 今天 / 近 7 天 / 累计费用 / 只显示图标 |
| 自动刷新间隔 | 15 分钟 | 5 分钟 / 15 分钟 / 1 小时；到点会重新采集 |
| 每个 agent 显示的模型数 | 3 | 1 / 3 / 5 / 全部 |

## 开发验证

纯逻辑（格式化与摘要）在 `Usage.js` 里，不依赖 QML，可直接跑：

```bash
node --test tests/usage.test.cjs
```

QML 部分的静态检查需要 DMS 运行时的导入路径：

```bash
root=$(dirname "$(dirname "$(dirname "$(find /run/user/1000/danklinux-shell -name PluginComponent.qml | head -1)")")")
for f in *.qml; do qmllint -I "$root" "$f"; done
```

注意：本机 qmllint 解析不了可选链（`?.`），因此插件里一律用显式判空，
这样整份文件都能当门禁跑（`LocalStatus.qml` 等在用插件里的 `?.` 会报同类假阳性）。

改动运行中的插件后：

```bash
cp -f *.qml Usage.js plugin.json ~/.config/DankMaterialShell/plugins/CachyosAgents/
dms ipc call plugin-scan rescan cachyosAgents
```
