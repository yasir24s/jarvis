"""M11 golden suites: listening for a sentence, and its tone (plan: M08-M13 §3.4, §4; jarvis.py
72, 984-1048, 5521-5525, 5545-5547; speech_recognition 3.14's Recognizer).

Plugin for tools/golden.py. The inputs are the committed `say` clips (Tests/Fixtures/golden/voice/
speaker and voice/wake) and inputs built from them by exact integer operations (BUILD), so the
Swift tests rebuild every sample. Every expectation comes from the real code: a
speech_recognition Recognizer set up as jarvis.py's run_assistant sets it up
(dynamic_energy_threshold, pause_threshold = SENT_PAUSE), its listen() with
phrase_time_limit=PHRASE_LIMIT and adjust_for_ambient_noise(), jarvis.py's listen_sentence (with
transcribe stubbed to give fixed text), and jarvis.py's analyze_tone.

    m11_endpoint   adjust_for_ambient_noise(2) and the 3000 cap, then listen() calls, over a
                   stream serving 1280 samples a read: what each returns (or WaitTimeoutError),
                   how many reads it took, and the energy threshold before every read
    m11_sentence   listen_sentence(recognizer, source, timeout, online=False): the text, the clip
                   and the clips handed to transcribe, including the mid-sentence continuation
    m11_tone       analyze_tone(audio, text), with the loudness and the pitches it measured
"""
import wave
from pathlib import Path

from golden import suite

VOICE = Path(__file__).resolve().parents[1] / "Tests" / "Fixtures" / "golden" / "voice"
RATE = 16000
CHUNK = 1280


def _read(folder, name):
    import numpy as np
    with wave.open(str(VOICE / folder / f"{name}.wav"), "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, RATE):
            raise AssertionError(f"{folder}/{name}: not 16 kHz mono 16-bit")
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.int16)


def _floor(n):
    """n samples of the wake corpus's -60 dBFS noise floor: wake_hey_daniel_200's first second,
    repeated."""
    import numpy as np
    one = _read("wake", "wake_hey_daniel_200")[:RATE]
    return np.resize(one, n).astype(np.int16)


def _mix(pcm):
    """pcm with the floor added, saturating, so a say clip's digital silence sounds like a room."""
    import numpy as np
    return np.clip(pcm.astype(np.int32) + _floor(len(pcm)).astype(np.int32), -32768, 32767).astype(np.int16)


def _part(spec):
    """One piece of an input: ["floor", n] | ["mix", folder, clip] | ["clip", folder, clip] |
    ["slice", folder, clip, start, stop] | ["gain", folder, clip, k] (saturating) |
    ["shift", folder, clip, k] (arithmetic)."""
    import numpy as np
    kind = spec[0]
    if kind == "floor":
        return _floor(spec[1])
    pcm = _read(spec[1], spec[2])
    if kind == "mix":
        return _mix(pcm)
    if kind == "clip":
        return pcm
    if kind == "slice":
        return _mix(pcm[spec[3]:spec[4]])
    if kind == "gain":
        return np.clip(pcm.astype(np.int32) * spec[3], -32768, 32767).astype(np.int16)
    if kind == "shift":
        return (pcm >> spec[3]).astype(np.int16)
    raise AssertionError(f"unknown input part {spec!r}")


def build(parts):
    import numpy as np
    return np.concatenate([_part(p) for p in parts]).astype(np.int16)


class _Stream:
    """PyAudio's stream.read over `pcm`: `frames` samples of 2 bytes, b"" at the end. It notes the
    recognizer's energy threshold before every read."""
    def __init__(self, pcm, recognizer):
        self.data, self.pos, self.reads, self.recognizer, self.thresholds = pcm.tobytes(), 0, 0, recognizer, []

    def read(self, frames):
        self.thresholds.append(self.recognizer.energy_threshold)
        out = self.data[self.pos:self.pos + frames * 2]
        self.pos += frames * 2
        if out:
            self.reads += 1
        return out


def _source(J, pcm, recognizer):
    sr = J.sr

    class Source(sr.AudioSource):
        def __init__(self):
            self.SAMPLE_RATE, self.SAMPLE_WIDTH, self.CHUNK = RATE, 2, J.OWW_FRAME_SAMPLES
            self.stream = _Stream(pcm, recognizer)

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    return Source()


def _recognizer(J):
    """run_assistant's (J:5521-5525)."""
    r = J.sr.Recognizer()
    r.dynamic_energy_threshold = True
    r.pause_threshold = J.SENT_PAUSE
    return r


# ─── the endpointer ─────────────────────────────────────────────────────────────

FLOOR2 = ["floor", 2 * RATE]
ENDPOINT = [
    ("basic", [FLOOR2, ["mix", "wake", "wake_time_daniel_200"]], [["calibrate", 2], ["listen", 2.5], ["listen", 2.2]]),
    ("pause", [FLOOR2, ["mix", "speaker", "daniel_pause"], ["floor", 3 * RATE]],
     [["calibrate", 2], ["listen", 2.5], ["listen", 2.2], ["listen", 2.2]]),
    ("short_burst", [FLOOR2, ["floor", RATE], ["slice", "speaker", "daniel_cmd_1", 9600, 9600 + 3 * CHUNK],
                     ["floor", 4 * RATE]], [["calibrate", 2], ["listen", 2.5]]),
    ("long", [FLOOR2, ["mix", "speaker", "daniel_long"], ["mix", "speaker", "daniel_long"], ["floor", RATE]],
     [["calibrate", 2], ["listen", 30]]),
    ("loud_room", [["gain", "speaker", "noise_m25dbfs", 2], ["mix", "speaker", "daniel_cmd_2"], ["floor", 2 * RATE]],
     [["calibrate", 2], ["listen", 2.5]]),
    ("no_lead", [["mix", "speaker", "samantha_cmd"], ["floor", 2 * RATE]], [["listen", 2.5]]),
    ("quiet", [FLOOR2, ["shift", "speaker", "karen_cmd", 5], ["floor", 3 * RATE]], [["calibrate", 2], ["listen", 30]]),
]


def _run(J, recognizer, source, op):
    sr = J.sr
    before = source.stream.reads
    if op[0] == "calibrate":
        recognizer.adjust_for_ambient_noise(source, duration=op[1])
        recognizer.energy_threshold = min(recognizer.energy_threshold, 3000)
        return {"op": op, "reads": source.stream.reads - before, "threshold": recognizer.energy_threshold}
    try:
        audio = recognizer.listen(source, timeout=op[1], phrase_time_limit=J.PHRASE_LIMIT)
        return {"op": op, "reads": source.stream.reads - before, "samples": len(audio.get_raw_data()) // 2,
                "threshold": recognizer.energy_threshold}
    except sr.WaitTimeoutError:
        return {"op": op, "reads": source.stream.reads - before, "timeout": True,
                "threshold": recognizer.energy_threshold}


@suite("m11_endpoint")
def endpoint(ctx):
    J = ctx.J
    cases = [{"name": "constants", "input": {},
              "expected": {"SENT_PAUSE": J.SENT_PAUSE, "PHRASE_LIMIT": J.PHRASE_LIMIT, "CHUNK": J.OWW_FRAME_SAMPLES}}]
    for name, parts, ops in ENDPOINT:
        pcm = build(parts)
        recognizer = _recognizer(J)
        source = _source(J, pcm, recognizer)
        results = []
        for op in ops:
            results.append(_run(J, recognizer, source, op))
        cases.append({"name": name, "input": {"parts": parts, "ops": ops},
                      "expected": {"results": results, "thresholds": source.stream.thresholds}})
    return cases


# ─── listen_sentence ────────────────────────────────────────────────────────────

SENTENCE = [
    ("whole", [FLOOR2, ["mix", "speaker", "daniel_cmd_1"], ["floor", 3 * RATE]], 2.5,
     ["Jarvis, what is the weather like today?"]),
    ("continued", [FLOOR2, ["mix", "speaker", "daniel_pause"], ["floor", 3 * RATE]], 2.5,
     ["Set a timer for ten minutes and", " Actually, make it twenty. "]),
    ("continued_empty", [FLOOR2, ["mix", "speaker", "daniel_pause"], ["floor", 3 * RATE]], 2.5,
     ["Set a timer for ten minutes, ", ""]),
    ("no_rest", [FLOOR2, ["mix", "speaker", "daniel_cmd_2"], ["floor", 3 * RATE]], 2.5,
     ["Open Safari and search for train times to"]),
    ("nothing_heard", [FLOOR2, ["mix", "speaker", "daniel_short"], ["floor", 3 * RATE]], 2.5, [""]),
    ("timeout", [FLOOR2, ["floor", 4 * RATE]], 2.5, []),
]


@suite("m11_sentence")
def sentence(ctx):
    J = ctx.J
    sr = J.sr
    logs = []
    J.log = lambda m, *a: logs.append(str(m))
    cases = []
    for name, parts, timeout, texts in SENTENCE:
        pcm = build(parts)
        recognizer = _recognizer(J)
        source = _source(J, pcm, recognizer)
        recognizer.adjust_for_ambient_noise(source, duration=2)
        recognizer.energy_threshold = min(recognizer.energy_threshold, 3000)
        queue, calls = list(texts), []

        def transcribe(rec, audio, online, _queue=queue, _calls=calls, _source=source):
            _calls.append({"samples": len(audio.get_raw_data()) // 2, "after_read": _source.stream.reads})
            return _queue.pop(0) if _queue else ""

        J.transcribe = transcribe
        start = source.stream.reads
        try:
            text, audio = J.listen_sentence(recognizer, source, timeout, False)
            expected = {"text": text, "samples": len(audio.get_raw_data()) // 2}
        except sr.WaitTimeoutError:
            expected = {"timeout": True}
        expected.update({"reads": source.stream.reads - start, "calls": calls,
                         "threshold": recognizer.energy_threshold})
        cases.append({"name": name, "input": {"parts": parts, "timeout": timeout, "texts": texts},
                      "expected": expected})
    return cases


# ─── analyze_tone ───────────────────────────────────────────────────────────────

TONE = [
    ("cmd_daniel", [["clip", "speaker", "daniel_cmd_1"]], "Jarvis, what is the weather like today?"),
    ("cmd_daniel_rushed", [["clip", "speaker", "daniel_cmd_1"]],
     "jarvis what is the weather like today and tomorrow and the day after that please now"),
    ("cmd_daniel_loud", [["gain", "speaker", "daniel_cmd_1", 4]], "Jarvis, what is the weather like today?"),
    ("cmd_daniel_quiet", [["shift", "speaker", "daniel_cmd_1", 4]], "what is the weather"),
    ("cmd_samantha", [["clip", "speaker", "samantha_cmd"]], "Jarvis, what is the weather like today?"),
    ("cmd_karen", [["clip", "speaker", "karen_cmd"]], "Open Safari and search for train times to London."),
    ("cmd_moira", [["clip", "speaker", "moira_cmd"]], "Please remind me to call the office"),
    ("cmd_rishi", [["clip", "speaker", "rishi_cmd"]], "Good morning"),
    ("long_daniel", [["clip", "speaker", "daniel_long"]], "I have been reading about the history of the London Underground"),
    ("pause_daniel", [["mix", "speaker", "daniel_pause"]], "set a timer for ten minutes actually make it twenty"),
    ("short_yes", [["clip", "speaker", "daniel_short"]], "yes"),
    ("too_short", [["slice", "speaker", "daniel_cmd_1", 0, 6000]], "jarvis"),
    ("noise", [["clip", "speaker", "noise_m25dbfs"]], "hmm"),
    ("silence", [["floor", 2 * RATE]], "nothing"),
    ("wake_time", [["clip", "wake", "wake_time_daniel_200"]], "hey jarvis what's the time"),
    ("wake_kathy", [["clip", "wake", "wake_close_kathy_200"]], "jarvis close safari"),
    ("no_text", [["clip", "speaker", "daniel_cmd_2"]], None),
]


@suite("m11_tone")
def tone(ctx):
    import numpy as np
    J = ctx.J
    J.log = lambda *a: None
    real_log10, real_std = np.log10, np.std
    cases = []
    for name, parts, text in TONE:
        seen = {"log10": [], "std": []}

        def log10(x, *a, _seen=seen, **k):
            out = real_log10(x, *a, **k)
            _seen["log10"].append(float(out))
            return out

        def std(x, *a, _seen=seen, **k):
            out = real_std(x, *a, **k)
            _seen["std"].append({"f0s": [float(v) for v in x], "std": float(out)})
            return out

        pcm = build(parts)
        np.log10, np.std = log10, std
        try:
            desc = J.analyze_tone(J.sr.AudioData(pcm.tobytes(), RATE, 2), text)
        finally:
            np.log10, np.std = real_log10, real_std
        cases.append({"name": name, "input": {"parts": parts, "text": text},
                      "expected": {"descriptor": desc,
                                   "loud_db": 20 * seen["log10"][0] if seen["log10"] else None,
                                   "f0s": seen["std"][0]["f0s"] if seen["std"] else None,
                                   "f0_std": seen["std"][0]["std"] if seen["std"] else None}})
    return cases
