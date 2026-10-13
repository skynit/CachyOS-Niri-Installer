#!/usr/bin/env python3
"""生成 README 用的完整架构图。

为什么用脚本生成而不是手写 SVG：图里有 40 多个方框和十几条带标签的箭头，
手写坐标几乎无法维护；脚本里用"分层 + 网格"描述结构，改一层只动一处。

产物：
  docs/images/architecture.svg   矢量源（可缩放、可 diff）
  docs/images/architecture.png   位图（任何 Markdown 渲染器都能显示）

用法：python3 docs/make-architecture.py   （需要 rsvg-convert 或 inkscape 渲染 PNG）
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from xml.sax.saxutils import escape

OUT_DIR = Path(__file__).resolve().parent / "images"

W = 1680
M = 46                      # 画布外边距
LABEL_W = 156               # 左侧层标签栏宽度
CONTENT_X = M + LABEL_W + 22
CONTENT_W = W - CONTENT_X - M
GAP = 16                    # 层与层之间
PAD = 14                    # 层内部留白
LINE_H = 22

FONT = "'Noto Sans CJK SC','Noto Sans SC','Source Han Sans SC',sans-serif"
MONO = "'Noto Sans Mono','DejaVu Sans Mono',monospace"

PALETTE = {
    "hw":     ("#f1f3f5", "#adb5bd", "#495057"),
    "base":   ("#eef2f6", "#8c959f", "#24292f"),
    "niri":   ("#e7f5ff", "#4dabf7", "#0b4f8a"),
    "shell":  ("#f3f0ff", "#9775fa", "#4c2d9c"),
    "extra":  ("#fff4e6", "#ffa94d", "#8a4b08"),
    "ai":     ("#e6fcf5", "#38d9a9", "#0b5f4a"),
    "state":  ("#f8f9fa", "#ced4da", "#495057"),
    "flow":   ("#ffffff", "#0ca678", "#0b5f4a"),
}

parts: list[str] = []
height_cursor = M


def text(x, y, s, size=15, weight="400", fill="#24292f", anchor="start", font=FONT,
         opacity=1.0, spacing=None) -> None:
    attrs = [
        f'x="{x}"', f'y="{y}"', f'font-size="{size}"', f'font-weight="{weight}"',
        f'fill="{fill}"', f'font-family="{font}"', f'text-anchor="{anchor}"',
    ]
    if opacity != 1.0:
        attrs.append(f'opacity="{opacity}"')
    if spacing:
        attrs.append(f'letter-spacing="{spacing}"')
    parts.append(f'<text {" ".join(attrs)}>{escape(s)}</text>')


def rect(x, y, w, h, fill, stroke, rx=10, sw=1.4, dash=None) -> None:
    attrs = [
        f'x="{x}"', f'y="{y}"', f'width="{w}"', f'height="{h}"', f'rx="{rx}"',
        f'fill="{fill}"', f'stroke="{stroke}"', f'stroke-width="{sw}"',
    ]
    if dash:
        attrs.append(f'stroke-dasharray="{dash}"')
    parts.append(f'<rect {" ".join(attrs)}/>')


def band(y, h, label, sublabel, kind) -> None:
    """一层：左侧标签栏 + 右侧内容区。"""
    fill, stroke, ink = PALETTE[kind]
    rect(M, y, W - 2 * M, h, "#ffffff", stroke, rx=14, sw=1.6)
    rect(M, y, LABEL_W, h, fill, stroke, rx=14, sw=1.6)
    # 标签栏右侧压平，避免与内容区之间出现圆弧
    rect(M + LABEL_W - 14, y, 14, h, fill, "none", rx=0, sw=0)
    parts.append(
        f'<line x1="{M + LABEL_W}" y1="{y}" x2="{M + LABEL_W}" y2="{y + h}" '
        f'stroke="{stroke}" stroke-width="1.6"/>'
    )
    text(M + LABEL_W / 2, y + (34 if sublabel else h / 2 + 6), label, 17, "700", ink, "middle")
    if sublabel:
        text(M + LABEL_W / 2, y + 58, sublabel, 12.5, "400", ink, "middle", opacity=0.72)


def box(x, y, w, h, title, lines=(), kind="base", title_size=14.5, line_size=12.5,
        mono_lines=()) -> None:
    fill, stroke, ink = PALETTE[kind]
    rect(x, y, w, h, fill, stroke, rx=9, sw=1.3)
    text(x + 13, y + 24, title, title_size, "700", ink)
    line_y = y + 24 + 19
    for line in lines:
        text(x + 13, line_y, line, line_size, "400", ink, opacity=0.88)
        line_y += 17
    for line in mono_lines:
        text(x + 13, line_y, line, line_size - 0.5, "400", ink, font=MONO, opacity=0.85)
        line_y += 17


# ---------------------------------------------------------------- 头部
parts.append(f'<rect x="0" y="0" width="{W}" height="100%" fill="#ffffff"/>')

text(M, M + 34, "CachyOS + Niri + DankMaterialShell 架构", 26, "700", "#111418")
text(M, M + 62, "从硬件到 AI 编程助手层：每层的归属、数据流向，以及安装器明确不改动的部分",
     14.5, "400", "#57606a")
height_cursor = M + 84

# ---------------------------------------------------------------- 1. 硬件
H1 = 104
band(height_cursor, H1, "硬件", "自动探测", "hw")
y = height_cursor + PAD + 12
w4 = (CONTENT_W - PAD * 2 - 3 * 12) / 4
hw = [
    ("CPU", ["x86-64-v3/v4 · Zen4", "→ 决定用哪套优化仓库"]),
    ("GPU", ["AMD / NVIDIA / Intel", "Vulkan / mesa 用户态驱动"]),
    ("音频与蓝牙", ["PipeWire + WirePlumber", "bluez、fwupd"]),
    ("I2C / DDC", ["亮度与外接屏控制", "i2c-dev udev 规则"]),
]
for i, (title, lines) in enumerate(hw):
    box(CONTENT_X + PAD + i * (w4 + 12), y, w4, 68, title, lines, "hw")
height_cursor += H1 + GAP

# ---------------------------------------------------------------- 2. CachyOS 基础
H2 = 116
band(height_cursor, H2, "基础系统", "CachyOS 官方", "base")
y = height_cursor + PAD + 10
w5 = (CONTENT_W - PAD * 2 - 4 * 10) / 5
base = [
    ("内核", ["linux-cachyos", "sched-ext / BORE"]),
    ("软件包", ["pacman + paru", "x86-64-v3/v4 仓库"]),
    ("服务管理", ["systemd", "用户单元与定时器"]),
    ("文件系统", ["btrfs + snapper", "安装前做包快照"]),
    ("登录", ["Ly（ly@tty2）", "停用其它显示管理器"]),
]
for i, (title, lines) in enumerate(base):
    box(CONTENT_X + PAD + i * (w5 + 10), y, w5, 78, title, lines, "base")
height_cursor += H2 + GAP

# ---------------------------------------------------------------- 3. Niri 会话
H3 = 150
band(height_cursor, H3, "Wayland 会话", "官方 Niri", "niri")
y = height_cursor + PAD + 8
box(CONTENT_X + PAD, y, 300, 116, "官方 Niri（滚动平铺合成器）",
    ["项目只提供配置与扩展，", "不打补丁、不替换二进制。"], "niri")
cfgs = [
    ("config.kdl", "主配置（@HOME@ 渲染）"),
    ("cachyos-extras.kdl", "项目快捷键与窗口规则"),
    ("dms/*.kdl", "DMS 生成的配色/布局/输出"),
    ("cachyos-voxtype.kdl", "可选 include：听写按键"),
]
cx = CONTENT_X + PAD + 300 + 18
cw = (CONTENT_W - PAD * 2 - 300 - 18 - 3 * 10) / 4
for i, (title, sub) in enumerate(cfgs):
    bx = cx + i * (cw + 10)
    box(bx, y, cw, 116, title, [sub], "niri", title_size=13.5, line_size=12)
height_cursor += H3 + GAP

# ---------------------------------------------------------------- 4. 桌面外壳
H4 = 168
band(height_cursor, H4, "桌面外壳", "DMS + Quickshell", "shell")
y = height_cursor + PAD + 8
box(CONTENT_X + PAD, y, 262, 134, "DankMaterialShell + Quickshell",
    ["栏、启动器、通知、锁屏、", "OSD、电源菜单", "（本项目不自研外壳）"], "shell")
shell_items = [
    ("DMS 栏", ["状态栏控件与托盘"]),
    ("动态主题", ["matugen → dms-colors.json"]),
    ("插件", ["CachyosAgents 用量面板"]),
]
sx = CONTENT_X + PAD + 262 + 16
sw = (CONTENT_W - PAD * 2 - 262 - 16 - 2 * 10) / 3
for i, (title, lines) in enumerate(shell_items):
    box(sx + i * (sw + 10), y, sw, 62, title, lines, "shell", title_size=14, line_size=12)
box(sx, y + 72, sw * 3 + 20, 62, "本项目的接入点",
    ["状态栏插件（只显示 token 数）、主题同步、通知（崩溃与听写）"], "shell",
    title_size=14, line_size=12.5)
height_cursor += H4 + GAP

# ---------------------------------------------------------------- 5. 附加 UI 与输入
H5 = 128
band(height_cursor, H5, "周边组件", "可选/附加", "extra")
y = height_cursor + PAD + 8
w6 = (CONTENT_W - PAD * 2 - 5 * 10) / 6
extra = [
    ("Waybar", ["顶/底栏（可选）", "听写状态模块"]),
    ("niri-sidebar", ["固定版二进制", "SHA256 校验"]),
    ("fuzzel", ["应用启动器"]),
    ("satty + 录屏", ["截图标注 / 录屏"]),
    ("waypaper + awww", ["壁纸与守护"]),
    ("Fcitx5 + RIME", ["雾凇拼音"]),
]
for i, (title, lines) in enumerate(extra):
    box(CONTENT_X + PAD + i * (w6 + 10), y, w6, 88, title, lines, "extra",
        title_size=14, line_size=12)
height_cursor += H5 + GAP

# ---------------------------------------------------------------- 6. AI 层
H6 = 480
band(height_cursor, H6, "AI 层", "本项目，与桌面解耦", "ai")
y0 = height_cursor + PAD + 8
ai_w = (CONTENT_W - PAD * 2 - 2 * 12) / 3
row1 = [
    ("统一启动层 + 按需提问", ["cachyos-agent（Super+`）", "cachyos-ask（Super+\\）：选区 /",
                          "剪贴板 / 暂存改动 → 动作 → agent"]),
    ("技能分发", ["cachyos / diagnose-crash", "软链进 Claude、Codex、", "OpenCode、CC Switch"]),
    ("崩溃诊断", ["systemd-coredump →", "cachyos-crash-watch →", "通知 → agent 分析"]),
]
for i, (title, lines) in enumerate(row1):
    box(CONTENT_X + PAD + i * (ai_w + 12), y0, ai_w, 96, title, lines, "ai")
row2_y = y0 + 96 + 14
row2 = [
    ("用量统计", ["4 个采集器读本机会话日志 →", "usage/*.json → DMS 用量面板"]),
    ("主题同步", ["dms-colors.json → Claude 主题", "与 Hermes skin（path 单元跟随）"]),
    ("本地听写（可选）", ["Voxtype + Whisper（Super+'）", "本地推理，音频不上传"]),
]
for i, (title, lines) in enumerate(row2):
    box(CONTENT_X + PAD + i * (ai_w + 12), row2_y, ai_w, 78, title, lines, "ai")
mirror_y = row2_y + 78 + 14
half = (ai_w * 3 + 24 - 12) / 2
box(CONTENT_X + PAD, mirror_y, half, 64, "跑完提醒",
    ["cachyos-agent-console：长任务或失败时", "发桌面通知，失败时窗口不关"], "ai",
    title_size=14, line_size=12)
box(CONTENT_X + PAD + half + 12, mirror_y, half, 64, "配置镜像（可选）",
    ["cachyos-ai-config-sync：CC Switch ↔ Codex", "Desktop 的非敏感字段镜像"], "ai",
    title_size=14, line_size=12)

# 数据流单独成块：早先用跨层箭头画，结果压住方框、语义也对不上
# （"崩溃交给 agent" 指到了配置镜像）。集中列成面板，改一条只动一行。
flow_y = mirror_y + 64 + 12
box(CONTENT_X + PAD, flow_y, ai_w * 3 + 24, 176, "数据流", [
    "会话日志（Claude / Codex / DSH） → 4 个采集器 → usage/*.json → DMS 用量面板（状态栏与弹窗）",
    "dms-colors.json（DMS 主题引擎） → 主题同步 → Claude 自定义主题 / Hermes skin",
    "systemd-coredump → crash-watch → 桌面通知 → cachyos-agent-crash → 交给 agent 分析",
    "Super+` → 启动层 → agent CLI；Super+\\ → 取选区/剪贴板/暂存改动 → 同一套 agent",
    "agent 退出 → cachyos-agent-console → 通知（长任务或失败）；失败保留窗口",
    "Super+Shift+\\ → cachyos-agent-resume：四个工具的会话按时间合并 → --resume / resume / --session",
    "api.anthropic.com 限额查询 = 唯一的联网行为（只读复用本机凭据）；其余全部读本地文件",
], kind="flow", title_size=14, line_size=12)
height_cursor += H6 + GAP

# ---------------------------------------------------------------- 7. 文件与状态
H7 = 118
band(height_cursor, H7, "文件与状态", "随包 + 运行时", "state")
y = height_cursor + PAD + 8
w4b = (CONTENT_W - PAD * 2 - 3 * 10) / 4
state = [
    ("命令", ["/usr/local/bin/cachyos-*", "69 个命令"]),
    ("随包资源", ["/usr/local/share/", "cachyos-desktop/assets/**"]),
    ("项目状态", ["~/.config/cachyos-desktop/", "默认 agent 等"]),
    ("运行数据", ["~/.local/state/cachyos-desktop/", "用量、崩溃、备份、日志"]),
]
for i, (title, lines) in enumerate(state):
    box(CONTENT_X + PAD + i * (w4b + 10), y, w4b, 80, title, lines, "state",
        title_size=14, line_size=12, mono_lines=())
height_cursor += H7 + GAP

# ---------------------------------------------------------------- 8. 不改动边界
H8 = 76
band(height_cursor, H8, "明确不改动", "安装器承诺", "base")
y = height_cursor + PAD + 14
text(CONTENT_X + PAD + 6, y + 10,
     "CachyOS 软件源与内核 · 引导器 · NetworkManager 连接 · Secure Boot 配置 · Windows 分区",
     14.5, "600", "#24292f")
text(CONTENT_X + PAD + 6, y + 34,
     "覆盖范围限于本项目管理的用户配置与 /usr/local 下的资源；安装前写入包快照，便于回滚",
     12.5, "400", "#57606a")
height_cursor += H8 + M

H = int(height_cursor)
svg = "\n".join([
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
    f'viewBox="0 0 {W} {H}" role="img" '
    f'aria-label="CachyOS + Niri + DankMaterialShell 架构图">',
    *parts,
    "</svg>",
    "",
])

OUT_DIR.mkdir(parents=True, exist_ok=True)
svg_path = OUT_DIR / "architecture.svg"
svg_path.write_text(svg, encoding="utf-8")
print(f"  写出 {svg_path.relative_to(OUT_DIR.parent.parent)}  ({W}x{H})")

png_path = OUT_DIR / "architecture.png"
renderer = shutil.which("rsvg-convert") or shutil.which("inkscape")
if renderer and "rsvg" in renderer:
    scale = int(W * 1.6)
    subprocess.run([renderer, "-w", str(scale), "-o", str(png_path), str(svg_path)], check=True)
    # 压到 128 色调色板：这张图只有几十种纯色 + 抗锯齿文字，量化后肉眼无差，
    # 体积却从约 740KB 降到约 200KB。降分辨率反而更大（重采样会造出大量中间色）。
    if shutil.which("magick"):
        subprocess.run(["magick", str(png_path), "-strip", "-colors", "128", "-depth", "8",
                        "-define", "png:compression-level=9", str(png_path)], check=True)
    w = int(W * 1.6)
    print(f"  写出 {png_path.relative_to(OUT_DIR.parent.parent)}  ({w}px 宽)")
elif renderer:
    subprocess.run([renderer, "--export-type=png", f"--export-filename={png_path}",
                    f"--export-width={W * 2}", str(svg_path)], check=True)
    print(f"  写出 {png_path.relative_to(OUT_DIR.parent.parent)}  ({W * 2}px 宽)")
else:
    print("  未找到 rsvg-convert / inkscape，只生成了 SVG")
