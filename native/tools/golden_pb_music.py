"""PB: Python's four music tools over a fake osascript, a fake network and a fake `open`.

pb_music  input {tool, args, outputs, online, pages} -> expected {text, scripts, opened, requests}
          execute_tool(tool, args) with `_run_applescript` answering each script with the next
          of `outputs` ("" once they run out), `_ensure_app_running` sending its launch script
          through the same fake (no sleep), and `_open_url` recording the URL it was given.
"""
from golden import suite
from golden_m5_system import _assert_guard_live, _patched
from golden_w1_web import _offline_world

_HITS8 = "\n".join(f"Song {i} | Artist {i} | Album {i}" for i in range(1, 9))
_YT = '<html>... "videoId":"dQw4w9WgXcQ", "videoId":"zzzzzzzzzzz" ...</html>'


def _vectors():
    v = []
    # music_now_playing: each shape osascript can answer with.
    for out in ("", "nothing", "Song | Artist | Album", "Song |  | Album", "Song | Artist |", "Song",
                "A | B | C | D", "Héllo 🎵 | Ünïcode | Ålbum", "execution error: Music got an error (-600)",
                "AppleScript error: [Errno 2] No such file or directory: 'osascript'", "Not running"):
        v.append(("music_now_playing", {}, [out], True, {}))
    # music_search: query and by, reply shapes, the cold-start retry.
    for args in ({}, {"query": ""}, {"query": "   "}, {"query": 0}, {"query": None}, {"query": 5},
                 {"query": ["x"]}, {"query": "queen", "by": 7}):
        v.append(("music_search", args, ["Song | Artist | Album"], True, {}))
    for by in ("", "artist", " Album ", "SONG", "track", "title", "genre", None):
        v.append(("music_search", {"query": "queen", "by": by}, ["Song | Artist | Album"], True, {}))
    v.append(("music_search", {"query": 'say "hi" \\ there '}, [""], True, {}))
    v.append(("music_search", {"query": "queen"}, [_HITS8], True, {}))
    v.append(("music_search", {"query": "queen"}, [_HITS8 + "\nSong 9 | A | B"], True, {}))
    v.append(("music_search", {"query": "queen"}, ["A | | \n\n  \nB | Art | \nC |  | Alb"], True, {}))
    v.append(("music_search", {"query": "queen"}, ["execution error: Music got an error: (-600)", "", "X | Y | Z"],
              True, {}))
    v.append(("music_search", {"query": "queen"}, ["execution error (-600)", "", "execution error (-600)"], True, {}))
    # music_control: every alias, unknown actions, volume shapes and failures.
    for action in ("play", "Resume", " unpause ", "pause", "stop", "next", "SKIP", "next track", "previous",
                   "prev", "back", "previous track", "", "dance", None, 0):
        v.append(("music_control", {"action": action}, ["ok"], True, {}))
    v.append(("music_control", {}, ["ok"], True, {}))
    v.append(("music_control", {"action": 5}, ["ok"], True, {}))
    v.append(("music_control", {"action": "it's"}, ["ok"], True, {}))
    for volume in (0, 50, 100, 150, -5, 55.9, "40", " 30 ", "1_0", "loud", "55.5", True, None, [1]):
        v.append(("music_control", {"volume": volume}, [""], True, {}))
    v.append(("music_control", {"action": "dance", "volume": 20}, [""], True, {}))
    v.append(("music_control", {"action": "pause", "volume": 20}, ["ok", ""], True, {}))
    v.append(("music_control", {"action": "pause", "volume": "x"}, ["ok", ""], True, {}))
    v.append(("music_control", {"volume": 20}, ["execution error: Music got an error"], True, {}))
    # music_play: library, YouTube, the search fallback.
    yt = "https://www.youtube.com/results?search_query="
    for query in ("Redbone by Childish Gambino", "  bohemian rhapsody ", 'say "hi" by \\me', "by the way",
                  "standby", "", "Song by   "):
        v.append(("music_play", {"query": query}, ["playing"], True, {}))
    v.append(("music_play", {"query": "Redbone by Childish Gambino"}, ["notfound"], False, {}))
    v.append(("music_play", {"query": "Redbone by Childish Gambino"}, ["notfound"], True,
              {yt + "Redbone%20by%20Childish%20Gambino": {"body": _YT}}))
    v.append(("music_play", {"query": "café/ñ & co"}, ["notfound"], True,
              {yt + "caf%C3%A9/%C3%B1%20%26%20co": {"body": _YT}}))
    v.append(("music_play", {"query": "zz"}, ["notfound"], True, {yt + "zz": {"body": "<html>nothing</html>"}}))
    v.append(("music_play", {"query": "zz"}, ["notfound"], True, {yt + "zz": {"status": 429}}))
    v.append(("music_play", {"query": "zz"}, ["notfound"], True, {}))
    v.append(("music_play", {"query": "zz"}, ["execution error (-1743)"], False, {}))
    v.append(("music_play", {"query": 7}, ["playing"], True, {}))
    v.append(("music_play", {}, ["notfound"], False, {}))
    return v


@suite("pb_music")
def music(ctx):
    _assert_guard_live("pb_music")
    J = ctx.J
    cases = []
    for index, (tool, args, outputs, online, pages) in enumerate(_vectors()):
        scripts, opened, queue = [], [], list(outputs)

        def applescript(script):
            scripts.append(script)
            return (queue.pop(0) if queue else "").strip()[:1000]   # as _run_applescript trims osascript

        def ensure(app, wait=2.0):
            J._run_applescript(f'tell application "{J._as_escape(app)}" to launch')

        with _patched(J, IS_MAC=True, IS_WIN=False, _run_applescript=applescript, _ensure_app_running=ensure,
                      _open_url=lambda url: opened.append(url), emotion_event=lambda *a, **k: None,
                      log=lambda *a, **k: None):
            with _offline_world(J, online, pages) as net:
                text = J.execute_tool(tool, args)
        cases.append({"name": f"{tool}/{index}",
                      "input": {"tool": tool, "args": args, "outputs": outputs, "online": online, "pages": pages},
                      "expected": {"text": text, "scripts": scripts, "opened": opened,
                                   "requests": net.requests}})
    _assert_guard_live("pb_music")
    return cases
