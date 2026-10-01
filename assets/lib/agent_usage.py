"""agent 用量采集器的共享工具。

被 bin/cachyos-agent-usage-claude 与 -codex 复用：增量缓存、JSONL 遍历、
本地日期归属、计数器累加。不依赖第三方包（只用标准库）。

设计要点：
- **按文件 (mtime, size) 做增量缓存**。Codex 的会话目录可达数百 MB，每次刷新
  全量重扫会让 15 分钟的定时刷新变得不可接受；缓存让"只解析变过的文件"成立。
- **计数按事件时间戳归属到本地日期**。会话累计值（Codex 的 total_token_usage）
  会把整个会话算到最后一天，因此必须用单事件增量（last_token_usage）或
  每条消息自己的 usage。
"""

from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path
from typing import Any, Iterable, Iterator

SCHEMA_VERSION = 1
RECENT_DAYS = 7


def cache_dir() -> Path:
    root = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache"))
    path = root / "cachyos-desktop" / "agent-usage"
    path.mkdir(parents=True, exist_ok=True)
    return path


def load_cache(agent: str) -> dict[str, Any]:
    path = cache_dir() / f"{agent}-files.json"
    try:
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {"files": {}}
    if not isinstance(data, dict) or not isinstance(data.get("files"), dict):
        return {"files": {}}
    return data


def save_cache(agent: str, cache: dict[str, Any]) -> None:
    path = cache_dir() / f"{agent}-files.json"
    temporary = path.with_suffix(".tmp")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(cache, handle, ensure_ascii=False)
        temporary.replace(path)
    except OSError:
        # 缓存写不进去只是变慢，不该让采集失败。
        pass


def empty_counters() -> dict[str, int]:
    return {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}


def add_counters(target: dict[str, int], source: dict[str, int]) -> None:
    for key, value in source.items():
        target[key] = target.get(key, 0) + int(value or 0)


def total_tokens(counters: dict[str, int]) -> int:
    """总 token = 输入 + 输出 + 缓存读 + 缓存写。

    缓存读往往占绝大多数，因此这里一并计入，面板会另外展示四项拆分。
    """
    return (
        int(counters.get("inputTokens", 0))
        + int(counters.get("outputTokens", 0))
        + int(counters.get("cacheReadInputTokens", 0))
        + int(counters.get("cacheCreationInputTokens", 0))
    )


def parse_timestamp(value: Any) -> dt.datetime | None:
    """解析 ISO8601（允许结尾 Z）。失败返回 None，绝不抛异常。"""
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


def local_date(value: Any) -> str:
    """事件时间戳 → 本地日期（YYYY-MM-DD）。拿不到时间戳时返回空串，调用方跳过。"""
    parsed = parse_timestamp(value)
    if parsed is None:
        return ""
    return parsed.astimezone().date().isoformat()


def iter_jsonl(path: Path) -> Iterator[Any]:
    """逐行解析 JSONL；坏行跳过（会话文件可能因崩溃被截断）。"""
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except ValueError:
                    continue
    except OSError:
        return


def recent_date_list(days: int = RECENT_DAYS) -> list[str]:
    today = dt.datetime.now().astimezone().date()
    return [(today - dt.timedelta(days=offset)).isoformat() for offset in range(days - 1, -1, -1)]


def file_stamp(path: Path) -> str:
    try:
        stat = path.stat()
    except OSError:
        return ""
    return f"{int(stat.st_mtime)}:{stat.st_size}"


def collect_files(roots: Iterable[Path], pattern: str) -> list[Path]:
    found: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        found.extend(sorted(root.rglob(pattern)))
    return found


def build_stats(
    per_day: dict[str, dict[str, Any]],
    model_usage: dict[str, dict[str, int]],
    sessions: set[str],
    prompts: int,
) -> dict[str, Any]:
    """把逐日/逐模型聚合整理成面板契约里的 stats 结构。"""
    today = dt.datetime.now().astimezone().date().isoformat()
    dates = recent_date_list()

    recent: list[dict[str, Any]] = []
    for date in dates:
        entry = per_day.get(date)
        counters = (entry or {}).get("counters") or empty_counters()
        recent.append(
            {
                "date": date,
                "totalTokens": total_tokens(counters),
                "counters": counters,
                "byModel": (entry or {}).get("byModel") or {},
                "prompts": int((entry or {}).get("prompts", 0)),
                "sessions": int((entry or {}).get("sessions", 0)),
            }
        )

    today_entry = per_day.get(today) or {}
    today_counters = today_entry.get("counters") or empty_counters()
    active_dates = sorted(date for date, entry in per_day.items() if total_tokens(entry.get("counters") or {}) > 0)

    return {
        "todayPrompts": int(today_entry.get("prompts", 0)),
        "todaySessions": int(today_entry.get("sessions", 0)),
        "todayTotalTokens": total_tokens(today_counters),
        "todayTokensByModel": {
            model: total_tokens(counters) for model, counters in (today_entry.get("byModel") or {}).items()
        },
        "recentDays": recent,
        "totalPrompts": prompts,
        "totalSessions": len(sessions),
        "activeDays": len(active_dates),
        "activeDates": active_dates,
        "modelUsage": {
            model: {**counters, "totalTokens": total_tokens(counters)} for model, counters in model_usage.items()
        },
    }


def merge_day(
    per_day: dict[str, dict[str, Any]],
    date: str,
    counters: dict[str, int],
    model: str,
    prompts: int = 0,
    session: str = "",
) -> None:
    entry = per_day.setdefault(date, {"counters": empty_counters(), "byModel": {}, "prompts": 0, "sessions": 0})
    add_counters(entry["counters"], counters)
    if model:
        add_counters(entry["byModel"].setdefault(model, empty_counters()), counters)
    entry["prompts"] += prompts
    if session:
        entry.setdefault("_sessions", set()).add(session)


def finalise_sessions(per_day: dict[str, dict[str, Any]]) -> None:
    for entry in per_day.values():
        entry["sessions"] = len(entry.pop("_sessions", ()))


def write_record(agent: str, record: dict[str, Any]) -> None:
    """打印一条 display-ready JSON 记录（编排器负责落盘）。"""
    print(json.dumps(record, ensure_ascii=False))
