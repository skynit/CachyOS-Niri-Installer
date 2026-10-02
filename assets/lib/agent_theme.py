"""把 DMS 生成的调色板渲染成 agent 能用的主题文件。

数据源：`~/.cache/DankMaterialShell/dms-colors.json`
  - `.mode`: "dark" / "light"
  - `.colors.dark` / `.colors.light`: 完整的 Material 3 角色（surface / on_surface / primary /
    outline / primary_container …）
  - `.dank16.colorN`: ANSI 16 色，各带 dark/light 变体（红绿黄蓝紫青在这里）

产物（键集与 Omarchy 的 `default/themed/{claude.json,hermes.yaml}.tpl` 一致，那是这些格式的
权威真源）：
  - Claude Code 自定义主题：`{"name", "base", "overrides": {...}}`
  - Hermes skin：`name:` / `description:` / `colors:` 每行 `  键: "#rrggbb"`

为什么要单独一个模块：颜色映射与混色是纯计算，放在 Python 里可以直接用 node/单元测试覆盖；
写进 shell 就只能靠"跑一次看看"。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
THEME_NAME = "cachyos"
HERMES_SKIN_NAME = "cachyos"

# Claude Code 主题的 overrides 键（顺序取自 Omarchy 的 claude.json.tpl）
CLAUDE_KEYS = (
    "claude", "claudeShimmer", "text", "inverseText", "inactive", "inactiveShimmer",
    "subtle", "suggestion", "permission", "permissionShimmer", "remember", "success",
    "error", "warning", "warningShimmer", "merged", "promptBorder", "promptBorderShimmer",
    "planMode", "autoAccept", "bashBorder", "ide", "diffAdded", "diffRemoved",
    "diffAddedDimmed", "diffRemovedDimmed", "diffAddedWord", "diffRemovedWord",
    "userMessageBackground", "userMessageBackgroundHover", "bashMessageBackgroundColor",
    "memoryBackgroundColor", "selectionBg", "rate_limit_fill", "rate_limit_empty",
    "briefLabelYou", "briefLabelClaude",
)

# Hermes skin 的颜色键（顺序取自 Omarchy 的 hermes.yaml.tpl）
HERMES_KEYS = (
    "background", "ui_text", "ui_primary", "ui_accent", "ui_border", "ui_label", "ui_ok",
    "ui_warn", "ui_error", "ui_tool", "ui_thinking", "banner_border", "banner_title",
    "banner_accent", "banner_dim", "banner_text", "prompt", "input_rule", "response_border",
    "shell_dollar", "selection_bg", "session_label", "session_border", "status_bar_bg",
    "status_bar_text", "status_bar_strong", "status_bar_dim", "status_bar_good",
    "status_bar_warn", "status_bar_bad", "status_bar_critical", "voice_status_bg",
    "completion_menu_bg", "completion_menu_current_bg", "completion_menu_meta_bg",
    "completion_menu_meta_current_bg", "diff_added", "diff_removed", "diff_added_word",
    "diff_removed_word", "syntax_string", "syntax_number", "syntax_keyword", "syntax_comment",
)


def normalize_hex(value: Any, fallback: str = "#000000") -> str:
    """收敛成 "#rrggbb"：DMS 偶尔给出不带 # 或带 alpha 的值。"""
    if not isinstance(value, str) or not value.startswith("#"):
        return fallback
    body = value[1:].strip()
    if len(body) >= 6:
        body = body[:6]
    elif len(body) == 3:
        body = "".join(ch * 2 for ch in body)
    else:
        return fallback
    try:
        int(body, 16)
    except ValueError:
        return fallback
    return "#" + body.lower()


def mix(base: str, other: str, percent: float) -> str:
    """把 other 按 percent 混进 base（与模板里的 `mix A B N%` 同义）。"""
    a = normalize_hex(base)
    b = normalize_hex(other)
    ratio = max(0.0, min(1.0, percent / 100.0))
    channels = []
    for index in (1, 3, 5):
        left = int(a[index:index + 2], 16)
        right = int(b[index:index + 2], 16)
        channels.append(round(left * (1 - ratio) + right * ratio))
    return "#" + "".join(f"{value:02x}" for value in channels)


def load_palette(colors_file: Path) -> dict[str, str]:
    """把 dms-colors.json 映射成模板变量。"""
    try:
        with colors_file.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as error:
        raise SystemExit(f"无法读取 DMS 调色板 {colors_file}: {error}")

    if not isinstance(data, dict):
        raise SystemExit(f"DMS 调色板格式意外（不是对象）: {colors_file}")

    mode = data.get("mode") if data.get("mode") in ("dark", "light") else "dark"
    roles = ((data.get("colors") or {}).get(mode)) or {}
    if not isinstance(roles, dict):
        roles = {}
    ansi: dict[str, str] = {}
    for key, entry in (data.get("dank16") or {}).items():
        if isinstance(entry, dict):
            ansi[key] = normalize_hex(entry.get(mode) or entry.get("default"))

    def role(name: str, ansi_key: str = "", fallback: str = "#000000") -> str:
        value = roles.get(name)
        if isinstance(value, str):
            return normalize_hex(value)
        if ansi_key and ansi.get(ansi_key):
            return ansi[ansi_key]
        return normalize_hex(fallback)

    palette = {
        "mode": mode,
        "theme_type": "light" if mode == "light" else "dark",
        "background": role("surface", "color0", "#000000"),
        "foreground": role("on_surface", "color7", "#ffffff"),
        "accent": role("primary", "color4", "#80d5d3"),
        "muted": role("outline", "color8", "#888888"),
        "selection": role("primary_container", "color4", "#33475b"),
        "selection_background": role("primary_container", "color4", "#33475b"),
        "dark_background": role("surface_container_lowest", "color0", "#000000"),
        "lighter_background": role("surface_container_high", "color0", "#222222"),
        "bright_foreground": role("on_surface", "color15", "#ffffff"),
        "dark_foreground": role("on_surface_variant", "color8", "#888888"),
        "red": ansi.get("color1") or "#ff5555",
        "green": ansi.get("color2") or "#55ff55",
        "yellow": ansi.get("color3") or "#ffff55",
        "blue": ansi.get("color4") or "#5555ff",
        "magenta": ansi.get("color5") or "#ff55ff",
        "cyan": ansi.get("color6") or "#55ffff",
        "bright_red": ansi.get("color9") or "#ff8888",
        "bright_yellow": ansi.get("color11") or "#ffff88",
        "bright_green": ansi.get("color10") or "#88ff88",
        "bright_cyan": ansi.get("color14") or "#88ffff",
        "bright_blue": ansi.get("color12") or "#8888ff",
    }
    return palette


def render_claude_theme(palette: dict[str, str]) -> str:
    """按 claude.json.tpl 的键集渲染 Claude Code 自定义主题。"""
    p = palette
    overrides = {
        "claude": p["accent"],
        "claudeShimmer": mix(p["accent"], p["foreground"], 35),
        "text": p["foreground"],
        "inverseText": p["background"],
        "inactive": mix(p["foreground"], p["background"], 40),
        "inactiveShimmer": mix(p["foreground"], p["background"], 25),
        "subtle": p["muted"],
        "suggestion": p["cyan"],
        "permission": p["blue"],
        "permissionShimmer": mix(p["blue"], p["foreground"], 35),
        "remember": p["yellow"],
        "success": p["green"],
        "error": p["red"],
        "warning": p["yellow"],
        "warningShimmer": mix(p["yellow"], p["foreground"], 35),
        "merged": p["magenta"],
        "promptBorder": p["accent"],
        "promptBorderShimmer": mix(p["accent"], p["foreground"], 35),
        "planMode": p["cyan"],
        "autoAccept": p["yellow"],
        "bashBorder": p["bright_yellow"],
        "ide": p["bright_cyan"],
        "diffAdded": mix(p["background"], p["green"], 15),
        "diffRemoved": mix(p["background"], p["red"], 15),
        "diffAddedDimmed": mix(p["background"], p["green"], 8),
        "diffRemovedDimmed": mix(p["background"], p["red"], 8),
        "diffAddedWord": mix(p["background"], p["green"], 32),
        "diffRemovedWord": mix(p["background"], p["red"], 32),
        "userMessageBackground": mix(p["background"], p["foreground"], 6),
        "userMessageBackgroundHover": mix(p["background"], p["foreground"], 10),
        "bashMessageBackgroundColor": mix(p["background"], p["foreground"], 6),
        "memoryBackgroundColor": mix(p["background"], p["foreground"], 6),
        "selectionBg": p["selection_background"],
        "rate_limit_fill": p["accent"],
        "rate_limit_empty": mix(p["background"], p["foreground"], 20),
        "briefLabelYou": p["yellow"],
        "briefLabelClaude": p["accent"],
    }
    return json.dumps(
        {"name": "CachyOS", "base": p["theme_type"], "overrides": overrides},
        ensure_ascii=False,
        indent=2,
        sort_keys=False,
    ) + "\n"


def render_hermes_skin(palette: dict[str, str]) -> str:
    """按 hermes.yaml.tpl 的键集渲染 Hermes skin（纯 ASCII，值必须是 "#rrggbb"）。"""
    p = palette
    colors = {
        "background": p["background"],
        "ui_text": p["foreground"],
        "ui_primary": p["accent"],
        "ui_accent": p["accent"],
        "ui_border": p["muted"],
        "ui_label": p["accent"],
        "ui_ok": p["green"],
        "ui_warn": p["yellow"],
        "ui_error": p["red"],
        "ui_tool": p["cyan"],
        "ui_thinking": p["dark_foreground"],
        "banner_border": p["muted"],
        "banner_title": p["accent"],
        "banner_accent": p["accent"],
        "banner_dim": p["dark_foreground"],
        "banner_text": p["foreground"],
        "prompt": p["bright_foreground"],
        "input_rule": p["muted"],
        "response_border": p["accent"],
        "shell_dollar": p["blue"],
        "selection_bg": p["selection"],
        "session_label": p["accent"],
        "session_border": p["muted"],
        "status_bar_bg": p["dark_background"],
        "status_bar_text": p["foreground"],
        "status_bar_strong": p["accent"],
        "status_bar_dim": p["dark_foreground"],
        "status_bar_good": p["green"],
        "status_bar_warn": p["yellow"],
        "status_bar_bad": p["red"],
        "status_bar_critical": p["bright_red"],
        "voice_status_bg": p["dark_background"],
        "completion_menu_bg": p["lighter_background"],
        "completion_menu_current_bg": p["selection"],
        "completion_menu_meta_bg": p["lighter_background"],
        "completion_menu_meta_current_bg": p["selection"],
        "diff_added": mix(p["background"], p["green"], 15),
        "diff_removed": mix(p["background"], p["red"], 15),
        "diff_added_word": p["green"],
        "diff_removed_word": p["red"],
        "syntax_string": p["green"],
        "syntax_number": p["yellow"],
        "syntax_keyword": p["magenta"],
        "syntax_comment": p["muted"],
    }
    lines = [f"name: {HERMES_SKIN_NAME}", "description: CachyOS desktop theme", "colors:"]
    lines.extend(f'  {key}: "{normalize_hex(colors[key])}"' for key in HERMES_KEYS)
    return "\n".join(lines) + "\n"


def validate_claude_theme(text: str) -> list[str]:
    """按 schema 校验，返回问题列表（空=通过）。"""
    problems: list[str] = []
    try:
        data = json.loads(text)
    except ValueError as error:
        return [f"不是合法 JSON: {error}"]
    if not isinstance(data, dict):
        return ["顶层不是对象"]
    if not isinstance(data.get("name"), str) or not data["name"]:
        problems.append("缺少 name")
    if data.get("base") not in ("dark", "light"):
        problems.append("base 必须是 dark 或 light")
    overrides = data.get("overrides")
    if not isinstance(overrides, dict):
        return problems + ["缺少 overrides 对象"]
    for key in CLAUDE_KEYS:
        if key not in overrides:
            problems.append(f"overrides 缺少 {key}")
        elif normalize_hex(overrides[key], "") == "":
            problems.append(f"overrides.{key} 不是合法颜色")
    return problems


def validate_hermes_skin(text: str) -> list[str]:
    """复刻 Hermes 的校验规则：纯 ASCII、name/colors 结构、每行 "#rrggbb"。"""
    problems: list[str] = []
    try:
        text.encode("ascii")
    except UnicodeEncodeError:
        problems.append("含有非 ASCII 字符（Hermes 会拒绝）")
    seen_name = False
    seen_colors = False
    colors = 0
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        if not seen_name:
            if line == f"name: {HERMES_SKIN_NAME}":
                seen_name = True
                continue
            problems.append(f"首行必须是 name: {HERMES_SKIN_NAME}，实际是 {line!r}")
            break
        if not seen_colors:
            if line == "colors:":
                seen_colors = True
            elif not line.startswith("description: "):
                problems.append(f"colors: 之前只允许 description，实际是 {line!r}")
                break
            continue
        parts = line.split(": ")
        if len(parts) != 2 or not parts[0].startswith("  "):
            problems.append(f"颜色行格式不对: {line!r}")
            break
        key = parts[0].strip()
        value = parts[1]
        if not key or len(key) > 64 or not all(ch.islower() or ch == "_" for ch in key):
            problems.append(f"颜色键名不合法: {key!r}")
            break
        # 含引号共 9 个字符：`"#rrggbb"`（Hermes 的真实校验用的是这个形式）
        if len(value) != 9 or not value.startswith('"#') or not value.endswith('"'):
            problems.append(f"颜色值必须是 \"#rrggbb\": {line!r}")
            break
        colors += 1
    if not seen_name:
        problems.append("缺少 name 行")
    if not seen_colors:
        problems.append("缺少 colors: 行")
    if colors == 0:
        problems.append("没有任何颜色")
    return problems


def write_if_changed(path: Path, text: str, dry_run: bool, verbose: bool) -> bool:
    """内容变了才写（原子替换）。返回是否发生了写入。"""
    try:
        if path.is_file() and path.read_text(encoding="utf-8") == text:
            if verbose:
                print(f"  未变: {path}")
            return False
    except OSError:
        pass
    if dry_run:
        if verbose:
            print(f"  [dry-run] 会写入: {path}")
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as handle:
        handle.write(text)
    temporary.replace(path)
    if verbose:
        print(f"  已写入: {path}")
    return True


def default_claude_dir() -> Path:
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude")).expanduser()


def default_hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes")).expanduser()


def default_colors_file() -> Path:
    state = os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")
    return Path(state) / "DankMaterialShell" / "dms-colors.json"


def main() -> int:
    parser = argparse.ArgumentParser(description="把 DMS 调色板渲染成 agent 主题文件")
    parser.add_argument("--colors", type=Path, default=default_colors_file())
    parser.add_argument("--claude-theme", type=Path, default=None,
                        help="Claude Code 自定义主题输出路径（默认 ~/.claude/themes/cachyos.json）")
    parser.add_argument("--hermes-skin", type=Path, default=None,
                        help="Hermes skin 输出路径（默认 ~/.hermes/skins/cachyos.yaml）")
    parser.add_argument("--no-hermes", action="store_true", help="不生成 Hermes skin")
    parser.add_argument("--dry-run", action="store_true", help="只显示会写什么")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--validate-only", action="store_true", help="只校验渲染结果，不写文件")
    args = parser.parse_args()

    verbose = not args.quiet
    palette = load_palette(args.colors)

    claude_path = args.claude_theme or (default_claude_dir() / "themes" / f"{THEME_NAME}.json")
    hermes_path = args.hermes_skin or (default_hermes_home() / "skins" / f"{HERMES_SKIN_NAME}.yaml")

    claude_text = render_claude_theme(palette)
    problems = validate_claude_theme(claude_text)
    if problems:
        print("Claude 主题校验失败: " + "; ".join(problems), file=sys.stderr)
        return 1

    wrote_claude = False
    if args.validate_only:
        if verbose:
            print(f"  Claude 主题校验通过（{len(CLAUDE_KEYS)} 个键）")
    else:
        wrote_claude = write_if_changed(claude_path, claude_text, args.dry_run, verbose)

    result = {
        "mode": palette["mode"],
        "claudeTheme": str(claude_path),
        "claudeThemeChanged": wrote_claude,
    }

    if not args.no_hermes:
        hermes_text = render_hermes_skin(palette)
        problems = validate_hermes_skin(hermes_text)
        if problems:
            print("Hermes skin 校验失败: " + "; ".join(problems), file=sys.stderr)
            return 1
        if args.validate_only:
            if verbose:
                print(f"  Hermes skin 校验通过（{len(HERMES_KEYS)} 个键）")
        else:
            result["hermesSkin"] = str(hermes_path)
            result["hermesSkinChanged"] = write_if_changed(
                hermes_path, hermes_text, args.dry_run, verbose
            )

    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
