"""PB: Python's personal-data tools over fakes: no real message, mail, contact or event is touched.

pb_messages  input {sql} -> expected {text}
             execute_tool("get_messages", {}) over a chat.db built in the sandbox's HOME from `sql`
             (None: no database file at all).
pb_calendar  input {events, outputs} -> expected {text, window, scripts}
             execute_tool("get_calendar", {}) with `_ek_events` answering `events` (None: EventKit
             unavailable, so the AppleScript fallback runs over `outputs`) and recording its window.
pb_contacts  input {tool, args, ek, outputs} -> expected {text, scripts, created}
             find_contact, send_message, send_email and create_event with `_run_applescript`
             answering each script with the next of `outputs` ("" once they run out); for
             create_event, `_ek_create` answers `ek` (None: unavailable) and records its call.

The fake `_ensure_app_running` sends its launch script through the same fake, with no sleep.
"""
import os
import sqlite3

from golden import suite
from golden_m5_system import _assert_guard_live, _patched

_SCHEMA = ["CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)",
           "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, text TEXT, "
           "is_from_me INTEGER, date INTEGER)"]


def _insert(rows):
    """rows: (handle_id, text, is_from_me, date) -> INSERT statements (single quotes doubled)."""
    out = []
    for h, t, me, d in rows:
        text = "NULL" if t is None else "'" + t.replace("'", "''") + "'"
        out.append(f"INSERT INTO message (handle_id, text, is_from_me, date) VALUES ({h}, {text}, {me}, {d})")
    return out


def _messages_vectors():
    handles = ["INSERT INTO handle (ROWID, id) VALUES (1, '+447700900001')",
               "INSERT INTO handle (ROWID, id) VALUES (2, 'friend@example.com')",
               "INSERT INTO handle (ROWID, id) VALUES (3, '')"]
    return [
        None,
        [],                                            # a file with no tables: the query fails
        _SCHEMA,
        _SCHEMA + handles + _insert([(1, "hello", 0, 10)]),
        _SCHEMA + handles + _insert([(1, "one", 0, 10), (2, "two", 0, 30), (9, "orphan", 0, 20),
                                     (3, "blank handle", 0, 25), (1, "mine", 1, 40), (1, None, 0, 50),
                                     (1, "", 0, 60), (2, "it's 🙂 café", 0, 35), (1, "six", 0, 5),
                                     (2, "seven", 0, 1)]),
        _SCHEMA + handles + _insert([(1, "line one\nline two", 0, 10), (2, "  spaced  ", 0, 9)]),
    ]


@suite("pb_messages")
def messages(ctx):
    _assert_guard_live("pb_messages")
    J = ctx.J
    folder = os.path.join(ctx.sandbox, "Library", "Messages")
    db = os.path.join(folder, "chat.db")
    cases = []
    for index, sql in enumerate(_messages_vectors()):
        if os.path.exists(db):
            os.remove(db)
        if sql is not None:
            os.makedirs(folder, exist_ok=True)
            con = sqlite3.connect(db)
            for statement in sql:
                con.execute(statement)
            con.commit()
            con.close()
        with _patched(J, IS_MAC=True, IS_WIN=False, emotion_event=lambda *a, **k: None):
            text = J.execute_tool("get_messages", {})
        cases.append({"name": f"get_messages/{index}", "input": {"sql": sql}, "expected": {"text": text}})
    if os.path.exists(db):
        os.remove(db)
    _assert_guard_live("pb_messages")
    return cases


def _calendar_vectors():
    t = 1790582400                                   # the frozen clock: 09:00 in London
    return [
        ([], []),
        ([["Standup", t + 3600, False]], []),
        ([["Standup", t + 3600, False], ["Holiday", t - 32400, True], ["Lunch", t + 14400 + 1800, False],
          ["Untitled", t + 39600, False]], []),
        ([["Late", t + 46800 + 59 * 60, False], ["Early", t - 9 * 3600 + 60, False]], []),
        (None, ["Dentist at 10:00:00. Gym at 18:30:00. "]),
        (None, [""]),
        (None, ["Done."]),
        (None, ["execution error: Calendar got an error: Application isn't running. (-600)", "",
                "Standup at 09:30:00. "]),
        (None, ["execution error (-600)", "", "execution error (-600)"]),
        (None, ["AppleScript error: Command '['osascript', '-']' timed out after 30 seconds", "", ""]),
    ]


@suite("pb_calendar")
def calendar(ctx):
    _assert_guard_live("pb_calendar")
    J = ctx.J
    cases = []
    for index, (events, outputs) in enumerate(_calendar_vectors()):
        scripts, windows, queue = [], [], list(outputs)

        def applescript(script):
            scripts.append(script)
            return (queue.pop(0) if queue else "").strip()[:1000]   # as _run_applescript trims osascript

        def ensure(app, wait=2.0):
            J._run_applescript(f'tell application "{J._as_escape(app)}" to launch')

        def ek_events(start, end):
            windows.append([start.timestamp(), end.timestamp()])
            return None if events is None else [tuple(e) for e in events]

        with _patched(J, IS_MAC=True, IS_WIN=False, _run_applescript=applescript, _ensure_app_running=ensure,
                      _ek_events=ek_events, emotion_event=lambda *a, **k: None):
            text = J.execute_tool("get_calendar", {})
        cases.append({"name": f"get_calendar/{index}", "input": {"events": events, "outputs": outputs},
                      "expected": {"text": text, "window": windows[0], "scripts": scripts}})
    _assert_guard_live("pb_calendar")
    return cases


def _contact_vectors():
    jane = "Jane Doe, phone +44 7700 900000, phone 020 7946 0000, email jane@example.com"
    v = []
    for name in ("", "   ", None, 0, 5, ["x"], "Jane", " jane doe ", 'O"Brien \\ Jr'):
        v.append(("find_contact", {"name": name}, None, [jane]))
    for out in ("", "Done.", "AppleScript error: [Errno 2] No such file or directory: 'osascript'",
                "execution error: Contacts got an error (-1743)", "Jane"):
        v.append(("find_contact", {"name": "Jane"}, None, [out]))
    v.append(("find_contact", {}, None, [jane]))
    # send_message: the text first, then the recipient, then Messages and its legacy fallback.
    for args, outputs in (
            ({"recipient": "Jane", "text": ""}, []),
            ({"recipient": "Jane", "text": "   "}, []),
            ({"recipient": "Jane"}, []),
            ({"recipient": "Jane", "text": 5}, []),
            ({"recipient": 5, "text": "hi"}, []),
            ({"recipient": "jane@example.com", "text": " on my way "}, [""]),
            ({"recipient": "+44 (0) 7700-900 000", "text": "hi"}, [""]),
            ({"recipient": "07700 900000", "text": 'say "hi" \\ there'}, [""]),
            ({"recipient": "123456", "text": "hi"}, ["", ""]),
            ({"recipient": "Mum", "text": "home soon"}, ["+44 (7700) 900-000", ""]),
            ({"recipient": "Mum", "text": "home soon"}, ["mum@example.com", ""]),
            ({"recipient": "Mum", "text": "home soon"}, [""]),
            ({"recipient": "Mum", "text": "home soon"}, ["Done."]),
            ({"recipient": "Mum", "text": "home soon"}, ["AppleScript error: timed out"]),
            ({"recipient": "Mum", "text": "home soon"},
             ["07700900000", "execution error: Messages got an error: Can't get account (-1728)", ""]),
            ({"recipient": "Mum", "text": "home soon"},
             ["07700900000", "execution error (-1728)", "execution error: Messages got an error (-1743)"]),
            ({"recipient": "  Mum  ", "text": "x"}, ["07700900000", ""]),
    ):
        v.append(("send_message", args, None, outputs))
    # send_email: the address first, then Mail.
    for args, outputs in (
            ({"to": "jane@example.com", "subject": "Hi", "body": "Hello"}, [""]),
            ({"to": " jane@example.com ", "subject": 'a "b"', "body": "line\\one\nline two"}, [""]),
            ({"to": "Jane", "subject": "Hi", "body": "Hello"}, ["jane@example.com", ""]),
            ({"to": "Jane", "subject": "Hi", "body": "Hello"}, ["+44 7700 900000"]),
            ({"to": "Jane", "subject": "Hi", "body": "Hello"}, [""]),
            ({"to": "Jane", "subject": "Hi", "body": "Hello"}, ["jane@example.com", "execution error (-1743)"]),
            ({"to": "jane@example.com"}, [""]),
            ({"to": "jane@example.com", "subject": None, "body": 0}, [""]),
            ({"to": "jane@example.com", "subject": 5, "body": "x"}, [""]),
            ({"to": 7, "subject": "x", "body": "x"}, [""]),
            ({"to": "07700 900000", "subject": "x", "body": "x"}, [""]),
    ):
        v.append(("send_email", args, None, outputs))
    # create_event: the time, the duration, EventKit, then the AppleScript fallback.
    for args, ek, outputs in (
            ({"title": "Dentist", "when": "tomorrow at 3pm"}, True, []),
            ({"title": "  Dentist  ", "when": "in 2 hours", "duration_minutes": 30}, True, []),
            ({"title": "", "when": "at 5:30pm"}, True, []),
            ({"title": "Call", "when": "on friday at 2pm", "duration_minutes": "45"}, True, []),
            ({"title": "Call", "when": "in 90 minutes", "duration_minutes": 2}, True, []),
            ({"title": "Call", "when": "in 90 minutes", "duration_minutes": 2.9}, True, []),
            ({"title": "Call", "when": "in 90 minutes", "duration_minutes": None}, True, []),
            ({"title": "Call", "when": "in 90 minutes", "duration_minutes": "abc"}, True, []),
            ({"title": "Call", "when": "in 90 minutes", "duration_minutes": True}, True, []),
            ({"title": "Call", "when": "in 3 days"}, True, []),
            ({"title": "Call", "when": "next monday at 9am"}, True, []),
            ({"title": "Call", "when": "at 10am"}, True, []),
            ({"title": "Call", "when": ""}, True, []),
            ({"title": "Call"}, True, []),
            ({"title": "Call", "when": "whenever suits"}, True, []),
            ({"title": "Call", "when": 5}, True, []),
            ({"title": 5, "when": "at 10am"}, True, []),
            ({"title": "Call", "when": "tomorrow at 3pm"}, False, []),
            ({"title": 'Say "hi"', "when": "tomorrow at 3pm"}, None, [""]),
            ({"title": "Call", "when": "in 2 hours", "duration_minutes": 15}, None,
             ["execution error: Calendar got an error (-600)", "", ""]),
            ({"title": "Call", "when": "in 2 hours"}, None, ["execution error (-600)", "", "execution error (-600)"]),
            ({"title": "Call", "when": "in 2 hours"}, None, ["Some error happened"]),
    ):
        v.append(("create_event", args, ek, outputs))
    return v


@suite("pb_contacts")
def contacts(ctx):
    _assert_guard_live("pb_contacts")
    J = ctx.J
    cases = []
    for index, (tool, args, ek, outputs) in enumerate(_contact_vectors()):
        scripts, created, queue = [], [], list(outputs)

        def applescript(script):
            scripts.append(script)
            return (queue.pop(0) if queue else "").strip()[:1000]   # as _run_applescript trims osascript

        def ensure(app, wait=2.0):
            J._run_applescript(f'tell application "{J._as_escape(app)}" to launch')

        def ek_create(title, start, dur):
            created.append([title, start.timestamp(), dur])
            return ek

        with _patched(J, IS_MAC=True, IS_WIN=False, _run_applescript=applescript, _ensure_app_running=ensure,
                      _ek_create=ek_create, emotion_event=lambda *a, **k: None, log=lambda *a, **k: None):
            text = J.execute_tool(tool, args)
        cases.append({"name": f"{tool}/{index}", "input": {"tool": tool, "args": args, "ek": ek, "outputs": outputs},
                      "expected": {"text": text, "scripts": scripts, "created": created}})
    _assert_guard_live("pb_contacts")
    return cases
