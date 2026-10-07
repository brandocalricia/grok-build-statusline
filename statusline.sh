#!/usr/bin/env python3
"""One status row. Unique subagent_spawned counts. Dollars are the measured gap versus grok-4.7."""

import fcntl
import json
import os
import sys
from pathlib import Path

LEDGER = Path(os.environ.get("STATUSLINE_LEDGER", Path.home() / ".grok" / "auto-route" / "ledger.json"))
OFFSETS = Path(os.environ.get("STATUSLINE_OFFSETS", Path.home() / ".grok" / "auto-route" / "offsets.json"))
OFF = Path(os.environ.get("STATUSLINE_OFF", Path.home() / ".grok" / "auto-route" / "off"))
SESSIONS = Path(os.environ.get("STATUSLINE_SESSIONS", Path.home() / ".grok" / "sessions"))
COUNT_KEYS = ("grok-4.5", "grok-4.6", "grok-4.7")
SAVINGS_NOTE = (
    "Dollar figure is the measured gap versus grok-4.7, not a guessed discount. "
    "grok-4.7-build-fast is 2x and is not a saving. Counts are unique subagent_spawned events."
)
TICKS_PER_USD = 10_000_000_000
LONG_INPUT_PER_CALL = 200_000
UNCACHED_TICKS = 6800
OUTPUT_TICKS = 20400
CACHED_TICKS = {"grok-4.5": 1020, "grok-4.6": 1700, "grok-4.7": 1700}


def load_json(path, default):
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def shorten(text, limit):
    text = text or "?"
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def empty_ledger():
    return {
        "priced": True,
        "note": SAVINGS_NOTE,
        "seen": {},
        "counts": {key: 0 for key in COUNT_KEYS},
        "saved_tokens": 0,
        "saved_ticks": 0,
    }


def under_sessions(path):
    try:
        path.resolve().relative_to(SESSIONS.resolve())
    except Exception:
        return False
    return True


def consume(path, seen, counts, offsets):
    """Read new lines of one transcript. Return True when the offset or counts move."""
    if not path.is_file() or not under_sessions(path):
        return False
    key = str(path.resolve())
    size = path.stat().st_size
    start = offsets.get(key, 0)
    if not isinstance(start, int) or start < 0 or start > size:
        start = 0
    if start == size:
        return False
    moved = False
    with path.open("rb") as handle:
        if start:
            handle.seek(start - 1)
            if handle.read(1) != b"\n":
                handle.readline()
        for raw in handle:
            try:
                event = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                continue
            update = (event.get("params") or {}).get("update") or {}
            if update.get("sessionUpdate") != "subagent_spawned":
                continue
            child = update.get("subagent_id")
            model = update.get("model")
            if not isinstance(child, str) or not isinstance(model, str) or child in seen:
                continue
            seen[child] = model
            moved = True
            if model in counts:
                counts[model] += 1
        offsets[key] = handle.tell()
    return True if offsets.get(key) != start else moved


def transcript_paths(preferred):
    found = []
    if SESSIONS.is_dir():
        for path in SESSIONS.rglob("updates.jsonl"):
            if path.is_file():
                found.append(path)
    if preferred and preferred.is_file() and under_sessions(preferred):
        found.append(preferred)
    unique = []
    seen_paths = set()
    for path in found:
        key = str(path.resolve())
        if key in seen_paths:
            continue
        seen_paths.add(key)
        unique.append(path)
    return unique


def usage_by_session():
    mapping = {}
    if not SESSIONS.is_dir():
        return mapping
    for path in SESSIONS.rglob("usage.json"):
        if path.is_file():
            mapping[path.parent.name] = path
    return mapping


def as_int(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return int(value)


def turn_ticks(turn, cached_rate):
    inn = as_int(turn.get("inputTokens"))
    out = as_int(turn.get("outputTokens"))
    cached = as_int(turn.get("cachedReadTokens"))
    calls = as_int(turn.get("modelCalls"))
    if cached < 0:
        cached = 0
    if cached > inn:
        cached = inn
    uncached = inn - cached
    long_ctx = calls > 0 and inn >= LONG_INPUT_PER_CALL * calls
    mul = 2 if long_ctx else 1
    return (cached * cached_rate + uncached * UNCACHED_TICKS + out * OUTPUT_TICKS) * mul


def recount(seen):
    counts = {key: 0 for key in COUNT_KEYS}
    for model in seen.values():
        if model in counts:
            counts[model] += 1
    return counts


def savings_from(seen, usage_map):
    """Token sum and grok-4.7 tick gap for grok-4.5 / grok-4.6 children with usage.json."""
    tokens = 0
    ticks = 0
    for child, model in seen.items():
        if model not in ("grok-4.5", "grok-4.6"):
            continue
        if "build-fast" in model:
            continue
        path = usage_map.get(child)
        if not path or not path.is_file():
            continue
        try:
            data = json.loads(path.read_text())
        except Exception:
            continue
        if not isinstance(data, dict):
            continue
        session = data.get("session")
        if not isinstance(session, dict):
            continue
        primary = str(session.get("primaryModelId") or "")
        if "build-fast" in primary:
            continue
        total = session.get("totalTokens")
        if isinstance(total, (int, float)) and not isinstance(total, bool):
            tokens += int(total)
        turns = data.get("turns")
        if not isinstance(turns, list):
            continue
        cached_rate = CACHED_TICKS[model]
        for turn in turns:
            if not isinstance(turn, dict):
                continue
            ticks += turn_ticks(turn, CACHED_TICKS["grok-4.7"]) - turn_ticks(turn, cached_rate)
    return tokens, ticks


def format_usd(ticks):
    """Integer ticks / 1e10. Strip trailing zeros; keep at least two decimal places."""
    sign = "-" if ticks < 0 else ""
    ticks = abs(int(ticks))
    whole, frac = divmod(ticks, TICKS_PER_USD)
    digits = f"{frac:010d}".rstrip("0")
    if len(digits) < 2:
        digits = f"{frac:010d}"[:2]
    return f"{sign}${whole}.{digits}"


def merge_seen(seen, current_seen):
    if not isinstance(current_seen, dict):
        return seen
    for child, model in current_seen.items():
        if child not in seen and isinstance(model, str):
            seen[child] = model
    return seen


def persist(ledger, seen, offsets, saved_tokens, saved_ticks, spawn_changed):
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    lock_path = LEDGER.with_name(LEDGER.name + ".lock")
    with open(lock_path, "a") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        current = load_json(LEDGER, empty_ledger())
        current_seen = current.get("seen") if isinstance(current, dict) else None
        seen = merge_seen(seen, current_seen)
        counts = recount(seen)
        usage_map = usage_by_session()
        saved_tokens, saved_ticks = savings_from(seen, usage_map)
        ledger["seen"] = seen
        ledger["counts"] = counts
        ledger["priced"] = True
        ledger["note"] = SAVINGS_NOTE
        ledger["saved_tokens"] = saved_tokens
        ledger["saved_ticks"] = saved_ticks
        disk_tokens = current.get("saved_tokens") if isinstance(current, dict) else None
        disk_ticks = current.get("saved_ticks") if isinstance(current, dict) else None
        disk_note = current.get("note") if isinstance(current, dict) else None
        disk_priced = current.get("priced") if isinstance(current, dict) else None
        savings_changed = (
            disk_tokens != saved_tokens
            or disk_ticks != saved_ticks
            or disk_note != SAVINGS_NOTE
            or disk_priced is not True
        )
        if spawn_changed or savings_changed:
            current_offsets = load_json(OFFSETS, {})
            if not isinstance(current_offsets, dict):
                current_offsets = {}
            for key, value in offsets.items():
                prior = current_offsets.get(key, 0)
                if not isinstance(prior, int) or (isinstance(value, int) and value > prior):
                    current_offsets[key] = value
            temporary = LEDGER.with_suffix(".json.tmp")
            temporary.write_text(json.dumps(ledger, indent=2) + "\n")
            os.replace(temporary, LEDGER)
            offset_tmp = OFFSETS.with_suffix(".json.tmp")
            offset_tmp.write_text(json.dumps(current_offsets) + "\n")
            os.replace(offset_tmp, OFFSETS)
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
    return ledger


def scan(transcript):
    ledger = load_json(LEDGER, empty_ledger())
    if not isinstance(ledger, dict):
        ledger = empty_ledger()
    seen = ledger.get("seen")
    counts = ledger.get("counts")
    if not isinstance(seen, dict) or not isinstance(counts, dict):
        ledger = empty_ledger()
        seen = ledger["seen"]
        counts = ledger["counts"]
    for key in COUNT_KEYS:
        if not isinstance(counts.get(key), int):
            counts[key] = 0
    offsets = load_json(OFFSETS, {})
    if not isinstance(offsets, dict):
        offsets = {}
    preferred = Path(transcript) if transcript else None
    changed = False
    for path in transcript_paths(preferred):
        if consume(path, seen, counts, offsets):
            changed = True
    usage_map = usage_by_session()
    saved_tokens, saved_ticks = savings_from(seen, usage_map)
    ledger["seen"] = seen
    ledger["counts"] = recount(seen)
    ledger["priced"] = True
    ledger["note"] = SAVINGS_NOTE
    ledger["saved_tokens"] = saved_tokens
    ledger["saved_ticks"] = saved_ticks
    return persist(ledger, seen, offsets, saved_tokens, saved_ticks, changed)


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        payload = {}
    workspace = payload.get("workspace") or {}
    directory = workspace.get("current_dir") or payload.get("cwd") or "?"
    model = (payload.get("model") or {}).get("display_name")
    if not model:
        model = (payload.get("model") or {}).get("id") or "?"
    window = payload.get("context_window") or {}
    percent = window.get("used_percentage")
    percent_text = "?" if percent is None else str(percent)
    cost = (payload.get("cost") or {}).get("total_cost_usd")
    base = shorten(str(directory).rstrip("/").split("/")[-1] or str(directory), 40)
    model = shorten(str(model), 30)
    cost_part = ""
    if isinstance(cost, (int, float)) and not isinstance(cost, bool) and cost >= 0.005:
        cost_part = f" │ ${cost:.2f}"
    if OFF.exists():
        route = "router off"
    else:
        ledger = scan(payload.get("transcript_path"))
        counts = ledger.get("counts") or {}
        saved_tokens = as_int(ledger.get("saved_tokens"))
        saved_ticks = as_int(ledger.get("saved_ticks"))
        route = (
            f"4.5×{int(counts.get('grok-4.5') or 0)} "
            f"4.6×{int(counts.get('grok-4.6') or 0)} · "
            f"saved {saved_tokens:,} tok ({format_usd(saved_ticks)})"
        )
    sys.stdout.write(f"{base} │ {model} │ {percent_text}% ctx{cost_part} │ {route}\n")


if __name__ == "__main__":
    main()
