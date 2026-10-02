# CachyOS Agents 用量

在 DMS 状态栏显示本机 AI 编程 agent 的 token 与费用统计。数据全部在本机采集，不联网。

| 项目 | 说明 |
| --- | --- |
| 插件 ID | `cachyosAgents` |
| 安装目录 | `~/.config/DankMaterialShell/plugins/CachyosAgents` |
| 依赖 | `jq`、`python3`，以及安装器的 `cachyos-agent-usage-update`（来自 CachyOS-Niri-Installer） |
| 数据目录 | `~/.local/state/cachyos-desktop/agents/usage/*.json` |

## 它显示什么

- **状态栏**：**只显示 token 用量**——没有图标、没有金额。**默认只显示数字**（不带日期），也可以在设置里改成"今天 / 近 7 天 / 累计"——那几种模式会带日期前缀；当天没有用量时回落到最近有数据的一天，而不是显示一个会误导人的 0。 默认把**所有已启用且有数据的 agent 合计**成一个数；也可以在设置里把统计范围钉到某一个 agent（例如只看 DSH）——合计时单个 agent 的份额是看不出来的。
- **弹窗**：每个 agent 一张卡片——今天与累计的 token/费用、会话数与提示数、额度条（若采集器能拿到）、按费用排序的模型明细、最近 7 天的**折线图**（Canvas 绘制，末点高亮）。没有任何采集器的 agent 不会占一张空卡片。

数据缺失时显示"未采集 / 无数据"，不会把没采到渲染成 0：只有采集器真的产出了统计（`hasLocalStats`）才会显示数字，全 0 的空壳记录按缺失处理。

## 数据从哪来

面板只读目录，不直接跑采集器：

```text
cachyos-agent-usage-update          # 并行跑各 agent 的采集器并原子落盘
  └── ~/.local/state/cachyos-desktop/agents/usage/<agent>.json
        └── 面板读取（jq -s 合成数组）
```

这样加一个 agent 需要两处：加一个采集器，并在 `Usage.js` 顶部的 `agents` 表里登记。token 语义按各家对齐：Claude 与 DSH 的
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
| 显示 Claude Code / Codex / OpenCode / DSH | 全开 | 关掉的 agent 不出现在状态栏与弹窗里 |
| 状态栏统计范围 | 全部 agent 合计 | 可钉到某一个 agent（如只看 DSH） |
| 状态栏显示 | 只显示数字 | 只显示数字 / 今天（无数据时显示最近一天）/ 近 7 天 / 累计 token |
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
