#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
"""Read-only schema-compatibility check over a JARVIS research dataset (plan: M01b T7 (a), A3).

    research_schema_check.py <research-dir>

Reads <research-dir>/metrics.jsonl and <research-dir>/usage.json, both opened "rb" and never
written. The dataset is private: nothing from it is printed except aggregates (row counts,
dates, key names, type names, row indexes, booleans).

stdout is exactly one line:
    rows N dates D first YYYY-MM-DD last YYYY-MM-DD violations V unchanged yes|no
(D = distinct dates; first/last = the first and last row's date, "-" when there is none).
stderr carries the aggregate details: duplicate dates, extra keys, usage.json day count, and one
line per violation. Exit 0 only when violations == 0 and unchanged == yes, 1 otherwise, 2 on a
usage error.

Checks (plan §2.1, §2.2, §2.3, §3.3):
  metrics rows  the 8 schema-1 keys come FIRST and IN ORDER with today's types (ts float,
                date str, code.{bytes,lines,git_head,git_commits} int,int,str,str,
                emotions.* numbers, counts.{profile_facts,corrections,kb_topics,history_turns}
                int, voiceprint_enrolled bool, personality/usage_today dicts); any further keys
                come only from the schema-2 set; dates are valid YYYY-MM-DD and non-decreasing
                (duplicates allowed: the last row of a day wins, the count is reported).
  usage.json    root is an object; every day is a valid YYYY-MM-DD mapping to an object; every
                counter is an int and its name is in the §2.3 catalogue or has a declared
                dynamic prefix.
  guard         size, mtime_ns and sha256 of both files before and after; "unchanged yes" only
                if all are identical.
"""
import datetime
import hashlib
import json
import os
import re
import sys

SCHEMA1_KEYS = ("ts", "date", "code", "personality", "emotions", "counts",
                "voiceprint_enrolled", "usage_today")
SCHEMA2_KEYS = frozenset(("emotions_at", "schema", "runtime", "code_native"))
CODE_KEYS = (("bytes", int), ("lines", int), ("git_head", str), ("git_commits", str))
COUNT_KEYS = ("profile_facts", "corrections", "kb_topics", "history_turns")

# §2.3: static counter names (existing + schema 2) and the declared dynamic prefixes.
STATIC_COUNTERS = frozenset((
    "interactions", "stt_segments_dropped", "personality_consolidations", "user_correction",
    "rephrase_suspected", "speaker_reject", "speaker_pass", "wake_rejected_foreign_voice",
    "alive_hours", "fast_path_handled", "interactions_text", "tts_elevenlabs", "tts_piper",
    "tts_chars_elevenlabs",
))
DYNAMIC_PREFIXES = ("backend_", "emotion_", "tone_", "tool_", "tts_fallback_", "starts_")

DATE_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")


def fingerprint(path):
    """(size, mtime_ns, sha256) of a regular file, or None if it is absent; plus its bytes."""
    try:
        st = os.stat(path)
        with open(path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return None, None
    return (st.st_size, st.st_mtime_ns, hashlib.sha256(data).hexdigest()), data


def type_name(v):
    return type(v).__name__


def is_int(v):
    return type(v) is int                       # bool is an int subclass: not accepted


def is_number(v):
    return type(v) in (int, float)


def valid_date(s):
    if not isinstance(s, str) or not DATE_RE.fullmatch(s):
        return False
    try:
        datetime.date.fromisoformat(s)
    except ValueError:
        return False
    return True


def check_row(i, row, violations, extras):
    where = f"row {i}"
    if not isinstance(row, dict):
        violations.append(f"{where}: not an object ({type_name(row)})")
        return
    keys = list(row)
    if tuple(keys[:len(SCHEMA1_KEYS)]) != SCHEMA1_KEYS:
        missing = [k for k in SCHEMA1_KEYS if k not in row]
        violations.append(f"{where}: schema-1 keys not first/in order"
                          + (f" (missing {', '.join(missing)})" if missing else ""))
    for k in keys:
        if k in SCHEMA1_KEYS:
            continue
        if k in SCHEMA2_KEYS:
            extras[k] = extras.get(k, 0) + 1
        else:
            violations.append(f"{where}: unexpected key {k!r}")

    if "ts" in row and type(row["ts"]) is not float:
        violations.append(f"{where}: ts is {type_name(row['ts'])}, expected float")
    if "date" in row and not isinstance(row["date"], str):
        violations.append(f"{where}: date is {type_name(row['date'])}, expected str")
    elif "date" in row and not valid_date(row["date"]):
        violations.append(f"{where}: date is not a valid YYYY-MM-DD")

    code = row.get("code")
    if "code" in row:
        if not isinstance(code, dict):
            violations.append(f"{where}: code is {type_name(code)}, expected dict")
        else:
            if tuple(code) != tuple(k for k, _ in CODE_KEYS):
                violations.append(f"{where}: code keys are not bytes, lines, git_head, git_commits")
            for k, t in CODE_KEYS:
                if k in code and not (is_int(code[k]) if t is int else type(code[k]) is t):
                    violations.append(f"{where}: code.{k} is {type_name(code[k])}, expected {t.__name__}")

    for k in ("personality", "usage_today"):
        if k in row and not isinstance(row[k], dict):
            violations.append(f"{where}: {k} is {type_name(row[k])}, expected dict")

    emotions = row.get("emotions")
    if "emotions" in row:
        if not isinstance(emotions, dict):
            violations.append(f"{where}: emotions is {type_name(emotions)}, expected dict")
        else:
            for k, v in emotions.items():
                if not is_number(v):
                    violations.append(f"{where}: emotions.{k} is {type_name(v)}, expected number")

    counts = row.get("counts")
    if "counts" in row:
        if not isinstance(counts, dict):
            violations.append(f"{where}: counts is {type_name(counts)}, expected dict")
        else:
            if tuple(counts) != COUNT_KEYS:
                violations.append(f"{where}: counts keys are not {', '.join(COUNT_KEYS)}")
            for k in COUNT_KEYS:
                if k in counts and not is_int(counts[k]):
                    violations.append(f"{where}: counts.{k} is {type_name(counts[k])}, expected int")

    if "voiceprint_enrolled" in row and type(row["voiceprint_enrolled"]) is not bool:
        violations.append(f"{where}: voiceprint_enrolled is "
                          f"{type_name(row['voiceprint_enrolled'])}, expected bool")


def check_metrics(data, violations, extras):
    """Returns the list of row dates (None where a row has no valid date)."""
    dates = []
    if data is None:
        violations.append("metrics.jsonl: missing")
        return dates
    if data and not data.endswith(b"\n"):
        violations.append("metrics.jsonl: last row is not newline-terminated")
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    previous = None
    for i, raw in enumerate(lines):
        try:
            row = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as e:
            violations.append(f"row {i}: does not parse ({type(e).__name__})")
            dates.append(None)
            continue
        check_row(i, row, violations, extras)
        date = row.get("date") if isinstance(row, dict) else None
        if not valid_date(date):
            dates.append(None)
            continue
        if previous is not None and date < previous:
            violations.append(f"row {i}: date is earlier than the previous row's")
        previous = date
        dates.append(date)
    return dates


def check_usage(data, violations):
    """Returns the number of days."""
    if data is None:
        violations.append("usage.json: missing")
        return 0
    try:
        usage = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        violations.append(f"usage.json: does not parse ({type(e).__name__})")
        return 0
    if not isinstance(usage, dict):
        violations.append(f"usage.json: root is {type_name(usage)}, expected dict")
        return 0
    for d, (day, counters) in enumerate(usage.items()):
        where = f"usage day {d}"
        if not valid_date(day):
            violations.append(f"{where}: key is not a valid YYYY-MM-DD")
        if not isinstance(counters, dict):
            violations.append(f"{where}: value is {type_name(counters)}, expected dict")
            continue
        for name, n in counters.items():
            if not is_int(n):
                violations.append(f"{where}: counter {name!r} is {type_name(n)}, expected int")
            if name not in STATIC_COUNTERS and not name.startswith(DYNAMIC_PREFIXES):
                violations.append(f"{where}: counter {name!r} is not in the §2.3 catalogue")
    return len(usage)


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: research_schema_check.py <research-dir>", file=sys.stderr)
        return 2
    metrics_path = os.path.join(argv[1], "metrics.jsonl")
    usage_path = os.path.join(argv[1], "usage.json")

    metrics_before, metrics_data = fingerprint(metrics_path)
    usage_before, usage_data = fingerprint(usage_path)

    violations = []
    extras = {}
    dates = check_metrics(metrics_data, violations, extras)
    days = check_usage(usage_data, violations)

    metrics_after, _ = fingerprint(metrics_path)
    usage_after, _ = fingerprint(usage_path)
    unchanged = metrics_before == metrics_after and usage_before == usage_after

    valid = [d for d in dates if d is not None]
    distinct = len(set(valid))
    first = dates[0] if dates and dates[0] is not None else "-"
    last = dates[-1] if dates and dates[-1] is not None else "-"

    print(f"duplicate_dates {len(valid) - distinct}", file=sys.stderr)
    print("extra_keys " + (", ".join(f"{k}={n}" for k, n in sorted(extras.items())) or "none"),
          file=sys.stderr)
    print(f"usage_days {days}", file=sys.stderr)
    for v in violations:
        print(f"violation: {v}", file=sys.stderr)
    if not unchanged:
        print("guard: size/mtime_ns/sha256 changed during the check", file=sys.stderr)

    print(f"rows {len(dates)} dates {distinct} first {first} last {last} "
          f"violations {len(violations)} unchanged {'yes' if unchanged else 'no'}")
    return 0 if not violations and unchanged else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
