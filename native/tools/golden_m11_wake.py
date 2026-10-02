"""M11 golden suites: the wake word (plan: M08-M13 §3.6, §4; jarvis.py 69, 986-988, 1073-1142,
5124-5145, 5215-5221).

Plugin for tools/golden.py. The audio inputs are the committed `say` clips in
Tests/Fixtures/golden/voice/wake/ (tools/make_wake_corpus.py) plus inputs derived from them by
exact integer operations (DERIVED), so the Swift tests rebuild every input bit for bit. Every
expectation comes from the real code: jarvis.py's functions and openwakeword's Model, as
jarvis.py's get_wakeword() builds it.

openwakeword seeds its feature buffer with np.random.randint(-1000, 1000, 64000) when the model
is built and at every reset. Here that one call is answered with seed_noise(k), a 32-bit LCG
(the k-th draw of the case), which Swift's WakeSeed.noise(k) reproduces; nothing else is changed.

Float arrays are "f32": base64 of the little-endian float32 bytes, exact through JSON.

    m11_phrases     contains_wake_word, extract_command, _is_enroll, _is_shazam and
                    _INCOMPLETE_TAIL_RE.search over 178 strings
    m11_oww         Model.predict's score for every 80 ms frame of every clip, after
                    model.reset(); and _get_melspectrogram's rows for four frames of three clips
    m11_wake_watch  wait_for_wake_word over a stream that serves a clip 1280 samples a read (and
                    moves the frozen clock 80 ms a read), with whisper_transcribe stubbed to give
                    each soft confirm a fixed transcript
"""
import base64
import wave
from pathlib import Path

from golden import suite

CORPUS = Path(__file__).resolve().parents[1] / "Tests" / "Fixtures" / "golden" / "voice" / "wake"
RATE = 16000
FRAME = 1280

# name -> how it is made. "clip": a corpus file; "zeros": that many zero samples; "min_every":
# zeros with -32768 at every n-th sample (np.abs keeps it negative, so numpy calls the frame
# silent); "gap": zeros, one quiet noise frame from a clip, then zeros.
DERIVED = [
    ("silence_21s", {"zeros": 260 * FRAME}),
    ("min_every_100", {"zeros": 260 * FRAME, "min_every": 100}),
    ("silence_gap", {"zeros": 260 * FRAME, "gap_at": 200, "gap_from": "noise_m40dbfs"}),
]

# The watcher's cases: input, and the transcripts whisper_transcribe gives the soft confirms in
# turn (None: the stub raises, as a failed transcription would). `soft: False` passes no
# recognizer, so the soft tier is off.
WATCH = [
    ("hey_daniel", "wake_hey_daniel_200", {"soft": True, "heard": []}),
    ("hey_samantha", "wake_hey_samantha_200", {"soft": True, "heard": ["Hey Jarvis."]}),
    ("time_daniel", "wake_time_daniel_200", {"soft": True, "heard": ["hey jarvis what's the time"]}),
    ("bare_samantha", "wake_bare_samantha_200", {"soft": False, "heard": []}),
    ("bare_ralph_confirmed", "wake_bare_ralph_200", {"soft": True, "heard": ["Jarvis?"]}),
    ("bare_ralph_off", "wake_bare_ralph_200", {"soft": False, "heard": []}),
    ("bare_kathy_not_wake", "wake_bare_kathy_200", {"soft": True, "heard": ["Travis"]}),
    ("bare_kathy_failed", "wake_bare_kathy_200", {"soft": True, "heard": [None]}),
    ("close_kathy", "wake_close_kathy_200", {"soft": True, "heard": [" Jarvis. Close Safari. "]}),
    ("bare_karen", "wake_bare_karen_200", {"soft": True, "heard": ["jarvis"]}),
    ("neg_travis", "neg_travis", {"soft": True, "heard": ["hey travis"]}),
    ("neg_java", "neg_java", {"soft": True, "heard": ["java's great"]}),
    ("neg_weather", "neg_weather", {"soft": True, "heard": []}),
    ("noise", "noise_m40dbfs", {"soft": True, "heard": ["", ""]}),
    ("dead", "silence_21s", {"soft": True, "heard": []}),
    ("dead_min", "min_every_100", {"soft": True, "heard": []}),
    ("not_dead", "silence_gap", {"soft": True, "heard": []}),
]

MEL_CLIPS = ["wake_hey_daniel_200", "wake_bare_ralph_200", "noise_m40dbfs"]
MEL_FRAMES = [0, 1, 10, 30]


def seed_noise(k):
    """The k-th seed draw: 64000 samples in [-1000, 1000) from a 32-bit LCG (as in
    make_wake_corpus.py, and Swift's WakeSeed.noise)."""
    import numpy as np
    x = (k * 2654435761 + 1) & 0xFFFFFFFF
    out = np.empty(64000, dtype=np.int64)
    for i in range(64000):
        x = (1664525 * x + 1013904223) & 0xFFFFFFFF
        out[i] = (x >> 8) % 2000 - 1000
    return out


class _Seeds:
    """Answers openwakeword's seed call with seed_noise(0), (1), ... while installed."""
    def __init__(self):
        import numpy as np
        self.np, self.real, self.k = np, np.random.randint, 0

    def __call__(self, *args, **kwargs):
        if args == (-1000, 1000, 16000 * 4) and not kwargs:
            noise = seed_noise(self.k)
            self.k += 1
            return noise
        return self.real(*args, **kwargs)

    def __enter__(self):
        self.np.random.randint = self
        return self

    def __exit__(self, *exc):
        self.np.random.randint = self.real
        return False


def _clips():
    names = sorted(p.stem for p in CORPUS.glob("*.wav"))
    if len(names) < 12:
        raise AssertionError(f"wake corpus has {len(names)} clips; run tools/make_wake_corpus.py")
    return names


def _read(name):
    import numpy as np
    with wave.open(str(CORPUS / f"{name}.wav"), "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, RATE):
            raise AssertionError(f"{name}: not 16 kHz mono 16-bit")
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.int16)


def _pcm(name):
    import numpy as np
    spec = dict(DERIVED).get(name)
    if spec is None:
        return _read(name)
    pcm = np.zeros(spec["zeros"], dtype=np.int16)
    if "min_every" in spec:
        pcm[::spec["min_every"]] = -32768
    if "gap_at" in spec:
        at = spec["gap_at"] * FRAME
        pcm[at:at + FRAME] = _read(spec["gap_from"])[:FRAME]
    return pcm


def _f32(a):
    import numpy as np
    return base64.b64encode(np.ascontiguousarray(a, dtype="<f4").tobytes()).decode("ascii")


def _model(J):
    """jarvis.py's own model, built afresh: get_wakeword() caches it in J._oww_model."""
    J._oww_model = None
    return J.get_wakeword()


# ─── phrases ────────────────────────────────────────────────────────────────────

PHRASES = [
    None, "", " ", "jarvis", "Jarvis", "JARVIS", "hey jarvis", "Hey Jarvis", "hey  jarvis", "ok jarvis",
    "okay jarvis", "OK Jarvis, open Safari", "jarviss", "jervis", "j.a.r.v.i.s", "J.A.R.V.I.S.", "jarvis.",
    "jarvis, what's the time", "Jarvis. Close Safari.", "hey jarvis what's the weather",
    "can you hear me jarvis", "can you hear me, jarvis?", "open safari jarvis please",
    "what time is it jarvis and the date", "they jarvis open mail", "hey, jarvis, stop", "ok, jarvis",
    "okay. jarvis. lights", "hockey jarvis", "say hey jarvis", "jarvisx", "xjarvis", "jarvis_1",
    "jarvis1", "jarv is", "j.arvis", "ja.rvis", "jar.v.i.s", "j a r v i s", "the jarvis", "jarvis jarvis",
    "hey jarvis jarvis", "jarvis hey", "jarvis;", ";jarvis", "jarvis,,, open", "jarvis . . open",
    "  jarvis  open safari  ", "\tjarvis\n", "jarvis open", "hey jarvis", "hey　jarvis",
    "Ｊarvis", "jarvís", "jarviś", "İ jarvis", "JARVİS", "hey travis", "java's great",
    "the weather tomorrow", "nervous", "harvest", "jarvisjarvis", "hey jervis", "ok jervis open",
    "j.a.r.v.i.s. open", "jarvis.open", "jarvis. open", "hey jarvis.", "okay", "hey", "ok", "they",
    "foo hey jarvis bar", "foo okay jarvis", "foo bar okay jarvis baz", "a hey jarvis b",
    "foo bar hey jarvis", "set a timer jarvis", "jarvis, set a timer for ten minutes",
    "learn my voice", "Learn my voice", "learn my voice.", "learn my", "learn voice", "please learn my voice",
    "set up voice recognition", "voice recognition", "remember my voice jarvis", "enroll my voice",
    "calibrate my voice", "register my voice", "recognize my voice", "recognise my voice", "learn my voice please",
    "learn your voice", "learn", "my voice", " learn my voice ", "LEARN MY VOICE", "enrol my voice",
    "remind me to", "remind me to,", "remind me and", "I want to buy milk and", "open safari",
    "what's the weather", "call mum because", "turn the", "turn the lights", "send it to", "give it to my",
    "is it yours", "ask your", "for", "and", "AND", "And", "um", "uh", "er", "erm", "so", "then", "I",
    "i", "you", "please", "the", "a", "an", "my", "of", "in", "on", "at", "that", "with", "but", "or",
    "because", "to", "theory", "band", "hand", "brand", "tomato", "panda", ",", "hello,", "hello ,",
    "hello, ", "hello and\n", "hello and \n", "hello and\n\n", "and.", "and!", "and?", "x and", "x_and",
    "x-and", "x'and", "1and", "ẞand", "the end", "please and thank you", "I'll", "say um",
    "what song is this", "What's this song?", "whats this song jarvis", "jarvis name this song", "SHAZAM",
    "identify the song please", "what song is playing", "what is this song", "what's that song", "song",
]


@suite("m11_phrases")
def phrases(ctx):
    J = ctx.J
    cases = []
    for t in PHRASES:
        cases.append({
            "name": repr(t),
            "input": {"text": t},
            "expected": {
                "contains_wake_word": J.contains_wake_word(t),
                "extract_command": J.extract_command(t),
                "is_enroll": J._is_enroll(t),
                "is_shazam": J._is_shazam(t),
                "incomplete_tail": None if t is None else bool(J._INCOMPLETE_TAIL_RE.search(t)),
            },
        })
    return [{"name": "wake_words", "input": {}, "expected": {"WAKE_WORDS": list(J.WAKE_WORDS)}}] + cases


# ─── openwakeword ───────────────────────────────────────────────────────────────

@suite("m11_oww")
def oww(ctx):
    J = ctx.J
    J.log = lambda *a: None
    cases = []
    for name in _clips():
        pcm = _pcm(name)
        with _Seeds() as seeds:
            model = _model(J)
            model.reset()
            mels = []
            real_mel = model.preprocessor._get_melspectrogram
            if name in MEL_CLIPS:
                def recording(x, **kwargs):
                    out = real_mel(x, **kwargs)
                    mels.append(out)
                    return out
                model.preprocessor._get_melspectrogram = recording
            scores = []
            for start in range(0, len(pcm) - FRAME + 1, FRAME):
                scores.append(model.predict(pcm[start:start + FRAME]).get("hey_jarvis", 0.0))
            draws = seeds.k
        expected = {"frames": len(scores), "scores": _f32(scores), "seed_draws": draws,
                    "fires_05": [i for i, s in enumerate(scores) if s >= 0.5],
                    "fires_015": [i for i, s in enumerate(scores) if s >= 0.15]}
        if name in MEL_CLIPS:
            expected["mel"] = {str(i): {"rows": int(mels[i].shape[0]), "f32": _f32(mels[i].reshape(-1))}
                               for i in MEL_FRAMES}
        cases.append({"name": name, "input": {"clip": name}, "expected": expected})
    return cases


# ─── wait_for_wake_word ─────────────────────────────────────────────────────────

@suite("m11_wake_watch")
def wake_watch(ctx):
    J = ctx.J
    logs = []
    J.log = lambda m, *a: logs.append(str(m))
    cases = []
    for name, clip, how in WATCH:
        pcm = _pcm(clip).tobytes()
        start = 1790582400.0
        ctx.at(start)

        class Stream:
            def __init__(self):
                self.pos, self.reads = 0, 0

            def read(self, frames):                   # PyAudio: `frames` samples of 2 bytes
                if self.pos + frames * 2 > len(pcm):
                    raise OSError("end of clip")
                out = pcm[self.pos:self.pos + frames * 2]
                self.pos += frames * 2
                self.reads += 1
                ctx.at(start + 0.08 * self.reads)      # each read is 80 ms of audio
                return out

        class Source:
            stream = Stream()

        source = Source()
        heard = list(how["heard"])
        confirms = []

        def transcribe(recognizer, audio, _heard=heard, _confirms=confirms, _source=source):
            _confirms.append({"after_read": _source.stream.reads, "samples": len(audio.get_raw_data()) // 2})
            t = _heard.pop(0) if _heard else None
            if t is None:
                raise RuntimeError("stub: no transcript")
            return t

        J.whisper_transcribe = transcribe
        del logs[:]
        seen = []
        with _Seeds() as seeds:
            model = _model(J)
            real_predict = model.predict

            def predict(x, *args, _real=real_predict, _seen=seen, **kwargs):
                out = _real(x, *args, **kwargs)
                _seen.append(out.get("hey_jarvis", 0.0))
                return out
            model.predict = predict
            result = J.wait_for_wake_word(source, recognizer=object() if how["soft"] else None)
        if result is False:
            kind, samples, text = "false", 0, None
        elif isinstance(result, tuple):
            kind, samples, text = "soft", len(result[1].get_raw_data()) // 2, result[0]
        else:
            kind, samples, text = "hard", len(result.get_raw_data()) // 2, None
        cases.append({"name": name, "input": {"clip": clip, "soft": how["soft"], "heard": how["heard"]},
                      "expected": {"kind": kind, "reads": source.stream.reads, "samples": samples, "text": text,
                                   "confirms": confirms, "seed_draws": seeds.k, "scores": _f32(seen),
                                   "dead_stream": any("pure silence" in m for m in logs),
                                   "read_error": any("mic read error" in m for m in logs)}})
    return cases
