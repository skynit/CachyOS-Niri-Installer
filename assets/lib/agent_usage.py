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


def total_tokens(counters: dict[str, int], input_includes_cache: bool = False) -> int:
    """总 token，按**各家的 input 语义**计算——这里不能一刀切。

    - Claude（`inputTokenSemantics="exclusive"`）：`input_tokens` 不含缓存，
      总 = 输入 + 输出 + 缓存读 + 缓存写。实测证据：同一条请求 input=4、
      cache_read=30208，input 显然是"非缓存的那一小部分"。
    - Codex（`"inclusive"`）：`input_tokens` **已包含** `cached_input_tokens`，
      总 = 输入 + 输出 + 缓存写；再加缓存读就是重复计数。
      实测证据：某个模型聚合 input=1,068,681,044、cache_read=1,011,316,992，
      差值仍为正且量级合理，说明缓存是输入的子集。
    """
    total = int(counters.get("inputTokens", 0)) + int(counters.get("outputTokens", 0))
    total += int(counters.get("cacheCreationInputTokens", 0))
    if not input_includes_cache:
        total += int(counters.get("cacheReadInputTokens", 0))
    return total


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
    input_includes_cache: bool = False,
    pricing: dict[str, dict[str, float]] | None = None,
) -> dict[str, Any]:
    """把逐日/逐模型聚合整理成面板契约里的 stats 结构。"""
    today = dt.datetime.now().astimezone().date().isoformat()
    dates = recent_date_list()

    pricing = pricing or {}
    recent: list[dict[str, Any]] = []
    for date in dates:
        entry = per_day.get(date)
        counters = (entry or {}).get("counters") or empty_counters()
        by_model = (entry or {}).get("byModel") or {}
        recent.append(
            {
                "date": date,
                "totalTokens": total_tokens(counters, input_includes_cache),
                "costUsd": round(
                    sum(
                        cost_usd(model_counters, price_for(model, pricing), input_includes_cache)
                        for model, model_counters in by_model.items()
                    ),
                    6,
                ),
                "counters": counters,
                "byModel": by_model,
                "prompts": int((entry or {}).get("prompts", 0)),
                "sessions": int((entry or {}).get("sessions", 0)),
            }
        )

    today_entry = per_day.get(today) or {}
    today_counters = today_entry.get("counters") or empty_counters()
    active_dates = sorted(
        date for date, entry in per_day.items() if total_tokens(entry.get("counters") or {}, input_includes_cache) > 0
    )

    return {
        "todayPrompts": int(today_entry.get("prompts", 0)),
        "todaySessions": int(today_entry.get("sessions", 0)),
        "todayTotalTokens": total_tokens(today_counters, input_includes_cache),
        "todayTokensByModel": {
            model: total_tokens(counters, input_includes_cache)
            for model, counters in (today_entry.get("byModel") or {}).items()
        },
        "recentDays": recent,
        "totalPrompts": prompts,
        "totalSessions": len(sessions),
        "activeDays": len(active_dates),
        "activeDates": active_dates,
        "modelUsage": {
            model: {
                **counters,
                "totalTokens": total_tokens(counters, input_includes_cache),
                "costUsd": round(cost_usd(counters, price_for(model, pricing), input_includes_cache), 6),
                "priced": bool(price_for(model, pricing)),
            }
            for model, counters in model_usage.items()
        },
        "costUsd": round(
            sum(cost_usd(counters, price_for(model, pricing), input_includes_cache) for model, counters in model_usage.items()),
            6
        ),
        "unpricedModels": sorted(model for model in model_usage if not price_for(model, pricing)),
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


# --------------------------------------------------------------------------- 定价

def ccswitch_pricing() -> dict[str, dict[str, float]]:
    """从 cc-switch 的 SQLite 读模型定价（每百万 token 的美元价）。

    读不到就返回空字典——没有定价只会少一个费用数字，不该让采集失败。
    查询用 `mode=ro`，绝不动用户数据库。
    """
    import sqlite3

    path = Path(os.environ.get("CC_SWITCH_DB") or (Path.home() / ".cc-switch" / "cc-switch.db"))
    if not path.is_file():
        return {}
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        rows = connection.execute(
            "select model_id, input_cost_per_million, output_cost_per_million,"
            " cache_read_cost_per_million, cache_creation_cost_per_million from model_pricing"
        ).fetchall()
        connection.close()
    except sqlite3.Error:
        return {}

    table: dict[str, dict[str, float]] = {}
    for model_id, in_cost, out_cost, read_cost, creation_cost in rows:
        try:
            table[str(model_id).lower()] = {
                "input": float(in_cost or 0),
                "output": float(out_cost or 0),
                "cacheRead": float(read_cost or 0),
                "cacheCreation": float(creation_cost or 0),
            }
        except (TypeError, ValueError):
            continue
    return table


def price_for(model: str, table: dict[str, dict[str, float]]) -> dict[str, float]:
    """按模型名查价：先精确、再去掉 `provider/` 前缀、最后忽略大小写。"""
    if not model or not table:
        return {}
    key = model.lower()
    if key in table:
        return table[key]
    short = key.rsplit("/", 1)[-1]
    if short in table:
        return table[short]
    return {}


def cost_usd(counters: dict[str, int], price: dict[str, float], input_includes_cache: bool = False) -> float:
    """按 token 类别计价，并**按各家语义拆分输入**，避免缓存被双重计费。

    - exclusive（Claude）：`input_tokens` 是非缓存部分，直接按输入价；
      缓存读/写各自单独计价。
    - inclusive（Codex）：`input_tokens` 里已经含了 `cached_input_tokens`，
      必须先减掉缓存那部分，否则同一批 token 会被按输入价和缓存价各收一次。
    """
    if not price:
        return 0.0
    input_tokens = int(counters.get("inputTokens", 0))
    cache_read = int(counters.get("cacheReadInputTokens", 0))
    billable_input = max(0, input_tokens - cache_read) if input_includes_cache else input_tokens
    return (
        billable_input / 1_000_000 * price.get("input", 0.0)
        + int(counters.get("outputTokens", 0)) / 1_000_000 * price.get("output", 0.0)
        + cache_read / 1_000_000 * price.get("cacheRead", 0.0)
        + int(counters.get("cacheCreationInputTokens", 0)) / 1_000_000 * price.get("cacheCreation", 0.0)
    )
