"""M10 golden suites: speaker verification (plan: M08-M13 §3.5, §4; jarvis.py 680-689, 5150-5263).

Plugin for tools/golden.py. The inputs are the committed `say` clips in
Tests/Fixtures/golden/voice/speaker/ (tools/make_speaker_corpus.py) plus inputs derived from them
by exact integer operations (DERIVED: an arithmetic right shift, a prefix, digital silence), so
the Swift tests rebuild every input bit for bit. Every expectation comes from the real code:
webrtcvad's Vad, resemblyzer 0.1.4's audio.py and VoiceEncoder, librosa's mel filterbank, and
jarvis.py's _embed, speaker_ok, _barge_in_speaker_match, enroll_voice, forget_voice and
_load_voiceprint. Internals of trim_long_silences (its VAD flags and masks) and of
embed_utterance (the padded wav, the mel, the partial batch) are observed by wrapping the real
functions, never recomputed here.

Float arrays are "f32": base64 of the little-endian float32 bytes, exact through JSON (NaN
included). Long arrays are given as a SHA-256 of those bytes, with every 97th value as f32.

    m10_vad            webrtcvad.Vad(3).is_speech per 30 ms and 20 ms frame
    m10_rz_preprocess  normalize_volume, trim_long_silences (flags, masks), preprocess_wav
    m10_rz_slices      VoiceEncoder.compute_partial_slices(n, 1.3, 0.75)
    m10_rz_mel         librosa.filters.mel(16000, 400, 40); embed_utterance's mels and torch's
                       partial embeddings for three clips
    m10_rz_embed       jarvis._embed(AudioData) per input
    m10_speaker        enroll_voice, the np.save bytes, speaker_ok at both thresholds with the sim,
                       _barge_in_speaker_match, the gate off, no voiceprint, forget_voice
    m10_enrol_record   enroll_voice with its takes from speech_recognition's real
                       Recognizer.record(source, duration=4) over a 16 kHz source, CHUNK 1280
    m10_thresholds     SPEAKER_THRESHOLD and WAKE_SPK_THRESHOLD for 57 environment values
"""
import ast
import base64
import hashlib
import wave
from pathlib import Path

from golden import suite

CORPUS = Path(__file__).resolve().parents[1] / "Tests" / "Fixtures" / "golden" / "voice" / "speaker"
RATE = 16000

# name -> how it is made. "clip": a corpus file; "shift": pcm >> k (arithmetic, so quiet inputs
# reach normalize_volume's gain); "stop": pcm[:stop]; "silence": that many zero samples.
DERIVED = [
    ("daniel_cmd_1_quiet", {"clip": "daniel_cmd_1", "shift": 4}),
    ("samantha_cmd_quiet", {"clip": "samantha_cmd", "shift": 4}),
    ("daniel_pause_quiet", {"clip": "daniel_pause", "shift": 6}),
    ("noise_quiet", {"clip": "noise_m25dbfs", "shift": 4}),
    ("daniel_cmd_1_head9000", {"clip": "daniel_cmd_1", "stop": 9000}),
    ("daniel_cmd_1_head9600", {"clip": "daniel_cmd_1", "stop": 9600}),
    ("silence_1s", {"silence": 16000}),
]
ENROL = ["daniel_enrol_1", "daniel_enrol_2", "daniel_enrol_3"]
MEL_CLIPS = ["daniel_cmd_1", "samantha_cmd", "daniel_long"]


def _clips():
    names = sorted(p.stem for p in CORPUS.glob("*.wav"))
    if len(names) < 13:
        raise AssertionError(f"speaker corpus has {len(names)} clips; run tools/make_speaker_corpus.py")
    return names


def _inputs():
    return [(n, {"clip": n}) for n in _clips()] + DERIVED


def _pcm(spec):
    import numpy as np
    if "silence" in spec:
        return np.zeros(spec["silence"], dtype=np.int16)
    with wave.open(str(CORPUS / f"{spec['clip']}.wav"), "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, RATE):
            raise AssertionError(f"{spec['clip']}: not 16 kHz mono 16-bit")
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.int16)
    if "shift" in spec:
        pcm = pcm >> spec["shift"]
    if "stop" in spec:
        pcm = pcm[:spec["stop"]]
    return pcm.astype(np.int16)


def _f32(a):
    import numpy as np
    return base64.b64encode(np.ascontiguousarray(a, dtype="<f4").tobytes()).decode("ascii")


def _sha(a):
    import numpy as np
    return hashlib.sha256(np.ascontiguousarray(a, dtype="<f4").tobytes()).hexdigest()


def _bits(flags):
    return "".join("1" if bool(f) else "0" for f in flags)


def _every97(a):
    """Every 97th value as f32, for reporting a max |delta| when the hashes differ."""
    return _f32(a[::97])


def _wav(pcm):
    import numpy as np
    return pcm.astype(np.float32) / 32768.0            # as _embed and enroll_voice convert


# ─── webrtcvad ──────────────────────────────────────────────────────────────────

@suite("m10_vad")
def vad(ctx):
    import webrtcvad
    cases = []
    for name, spec in _inputs():
        raw = _pcm(spec).tobytes()
        expected = {}
        for ms in (30, 20):
            v = webrtcvad.Vad(3)
            n = RATE * ms // 1000
            frames = range(0, len(raw) // 2 - n + 1, n)
            expected[f"vad{ms}"] = _bits(v.is_speech(raw[i * 2:(i + n) * 2], RATE) for i in frames)
        cases.append({"name": name, "input": spec, "expected": expected})
    return cases


# ─── resemblyzer preprocessing ──────────────────────────────────────────────────

@suite("m10_rz_preprocess")
def rz_preprocess(ctx):
    import numpy as np
    from resemblyzer import audio
    real_dilation, real_vad = audio.binary_dilation, audio.webrtcvad.Vad
    seen = {}

    class RecordingVad(real_vad):
        def is_speech(self, buf, sample_rate, length=None):
            r = super().is_speech(buf, sample_rate, length)
            seen["flags"].append(r)
            return r

    def dilation(mask, structure):
        seen["smoothed"] = np.array(mask, copy=True)
        out = real_dilation(mask, structure)
        seen["kept"] = np.array(out, copy=True)
        return out

    cases = []
    audio.binary_dilation, audio.webrtcvad.Vad = dilation, RecordingVad
    try:
        for name, spec in _inputs():
            wav = _wav(_pcm(spec))
            with np.errstate(all="ignore"):            # silence: log10(0) and 0 * inf, as in JARVIS
                normalized = audio.normalize_volume(wav, audio.audio_norm_target_dBFS, increase_only=True)
                seen.update(flags=[], smoothed=None, kept=None)
                trimmed = audio.trim_long_silences(normalized)
                trim_seen = dict(seen)
                seen.update(flags=[], smoothed=None, kept=None)
                pre = audio.preprocess_wav(wav, source_sr=RATE)
            if _sha(pre) != _sha(trimmed) or len(pre) != len(trimmed):
                raise AssertionError(f"{name}: preprocess_wav is not trim(normalize) here")
            cases.append({"name": name, "input": spec, "expected": {
                "samples": int(len(wav)),
                "normalized_changed": normalized is not wav,
                "normalized_sha256": _sha(normalized),
                "normalized_every97_f32": _every97(normalized),
                "flags": _bits(trim_seen["flags"]),
                "smoothed": _bits(trim_seen["smoothed"]),
                "kept": _bits(trim_seen["kept"]),
                "length": int(len(trimmed)),
                "sha256": _sha(trimmed),
                "every97_f32": _every97(trimmed),
            }})
    finally:
        audio.binary_dilation, audio.webrtcvad.Vad = real_dilation, real_vad
    return cases


@suite("m10_rz_slices")
def rz_slices(ctx):
    import numpy as np
    from resemblyzer import VoiceEncoder, preprocess_wav
    ns = {int(n) for n in np.linspace(6400, 200000, 500)}
    ns |= {1, 159, 160, 161, 6399, 12319, 12320, 12321, 25440, 25600, 25601, 37920, 38080, 49999}
    for _, spec in _inputs():                                   # the corpus's own lengths
        with np.errstate(all="ignore"):
            ns.add(int(len(preprocess_wav(_wav(_pcm(spec)), source_sr=RATE))))
    ns.discard(0)
    cases = []
    for n in sorted(ns):
        wav_slices, mel_slices = VoiceEncoder.compute_partial_slices(n, 1.3, 0.75)
        cases.append({"name": f"n{n}", "input": {"n": n}, "expected": {
            "mel": ",".join(f"{s.start}:{s.stop}" for s in mel_slices),
            "wav": ",".join(f"{s.start}:{s.stop}" for s in wav_slices),
        }})
    return cases


@suite("m10_rz_mel")
def rz_mel(ctx):
    import librosa
    import numpy as np
    from resemblyzer import audio, preprocess_wav
    from resemblyzer import voice_encoder as ve
    fb = librosa.filters.mel(sr=RATE, n_fft=400, n_mels=40)
    cases = [{"name": "filterbank", "input": {"sr": RATE, "n_fft": 400, "n_mels": 40},
              "expected": {"shape": list(fb.shape), "dtype": str(fb.dtype), "f32": _f32(fb)}}]
    enc = ctx.J._get_encoder()
    seen = {}
    real_mel, real_forward = audio.wav_to_mel_spectrogram, type(enc).forward

    def mel(wav):
        seen["padded"] = np.array(wav, copy=True)
        out = real_mel(wav)
        seen["mel"] = np.array(out, copy=True)
        return out

    def forward(self, mels):
        out = real_forward(self, mels)
        seen["batch"] = mels.detach().numpy().copy()
        seen["partials"] = out.detach().numpy().copy()
        return out

    ve.audio.wav_to_mel_spectrogram, type(enc).forward = mel, forward
    try:
        for name in MEL_CLIPS:
            pre = preprocess_wav(_wav(_pcm({"clip": name})), source_sr=RATE)
            seen.clear()
            embed = enc.embed_utterance(pre)
            cases.append({"name": name, "input": {"clip": name}, "expected": {
                "preprocessed_length": int(len(pre)),
                "padded_length": int(len(seen["padded"])),
                "mel_shape": list(seen["mel"].shape), "mel_f32": _f32(seen["mel"]),
                "batch_shape": list(seen["batch"].shape), "batch_sha256": _sha(seen["batch"]),
                "partials_shape": list(seen["partials"].shape), "partials_f32": _f32(seen["partials"]),
                "embed_f32": _f32(embed),
            }})
    finally:
        ve.audio.wav_to_mel_spectrogram, type(enc).forward = real_mel, real_forward
    return cases


# ─── jarvis.py: _embed, speaker_ok, barge-in, enroll, forget ───────────────────

def _audio(J, pcm):
    return J.sr.AudioData(pcm.tobytes(), RATE, 2)


@suite("m10_rz_embed")
def rz_embed(ctx):
    import numpy as np
    J = ctx.J
    logged = []
    J.log = logged.append
    cases = []
    for name, spec in _inputs():
        logged.clear()
        emb = J._embed(_audio(J, _pcm(spec)))
        errors = [m for m in logged if m.startswith("Embed error")]
        if errors:
            raise AssertionError(f"{name}: {errors}")
        cases.append({"name": name, "input": spec, "expected": {"embed_f32": None} if emb is None else {
            "embed_f32": _f32(emb), "dtype": str(emb.dtype), "norm": float(np.linalg.norm(emb))}})
    return cases


class _Recorder:
    """recognizer.record(source, duration=4) handing out fixed segments, as AudioData."""
    def __init__(self, J, pcms):
        self.J, self.pcms, self.calls = J, list(pcms), []

    def record(self, source, duration=None):
        self.calls.append(duration)
        return _audio(self.J, self.pcms.pop(0))


def _sim_expression(J):
    """speaker_ok's own `sim = ...` expression, read from its AST and compiled (not retyped)."""
    tree = ast.parse(open(J.__file__, encoding="utf-8").read())
    fns = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "speaker_ok"]
    if len(fns) != 1:
        raise AssertionError(f"jarvis.py has {len(fns)} speaker_ok functions")
    sims = [n.value for n in ast.walk(fns[0]) if isinstance(n, ast.Assign)
            and [t.id for t in n.targets if isinstance(t, ast.Name)] == ["sim"]]
    if len(sims) != 1:
        raise AssertionError(f"speaker_ok has {len(sims)} sim assignments")
    return compile(ast.Expression(sims[0]), "speaker_ok:sim", "eval"), ast.unparse(sims[0])


@suite("m10_speaker")
def speaker(ctx):
    import numpy as np
    J = ctx.J
    spoken, chimes, logged, bumps = [], [], [], []
    J.speak, J.chime, J.log = spoken.append, chimes.append, logged.append
    real_bump = J.research_bump

    def bump(key, n=1):
        bumps.append(key)
        real_bump(key, n)
    J.research_bump = bump
    printed = []
    J.print = lambda *a, **k: printed.append(" ".join(str(x) for x in a))   # speaker_ok's reject line
    vp_path = Path(J.VOICEPRINT_FILE)

    def clear():
        spoken.clear(); chimes.clear(); logged.clear(); bumps.clear(); printed.clear()

    cases = [{"name": "constants", "input": {}, "expected": {
        "SPEAKER_THRESHOLD": J.SPEAKER_THRESHOLD, "WAKE_SPK_THRESHOLD": J.WAKE_SPK_THRESHOLD,
        "sim_expression": _sim_expression(J)[1]}}]

    # enroll_voice: three good takes; one silent take; three silent takes; no backend.
    silence = np.zeros(64000, dtype=np.int16)
    takes = {
        "enroll_three": [_pcm({"clip": c}) for c in ENROL],
        "enroll_one_silent": [_pcm({"clip": ENROL[0]}), silence, _pcm({"clip": ENROL[2]})],
        "enroll_all_silent": [silence, silence, silence],
    }
    saved = {}
    for name, pcms in takes.items():
        clear()
        vp_path.unlink(missing_ok=True)
        J._voiceprint = None
        rec = _Recorder(J, pcms)
        enc = J._get_encoder()
        real_embed_utterance, embedded = enc.embed_utterance, []
        enc.embed_utterance = lambda wav, **kw: embedded.append(len(wav)) or real_embed_utterance(wav, **kw)
        try:
            with np.errstate(all="ignore"):
                J.enroll_voice(rec, object())
        finally:
            del enc.embed_utterance                            # back to the class's method
        data = vp_path.read_bytes() if vp_path.exists() else None
        if data is not None:
            saved[name] = data
        cases.append({"name": name, "input": {"takes": ["silence" if p is silence else c
                                                        for p, c in zip(pcms, ENROL)]},
                      "expected": {"spoken": list(spoken), "chimes": list(chimes),
                                   "durations": rec.calls, "embedded_takes": len(embedded),
                                   "embedded_lengths": embedded,
                                   "npy_b64": None if data is None else base64.b64encode(data).decode("ascii"),
                                   "voiceprint_set": J._voiceprint is not None,
                                   "logged": [m for m in logged if m.startswith("Voiceprint")]}})
    clear()
    real_get = J._get_encoder
    J._get_encoder = lambda: (_ for _ in ()).throw(ImportError("No module named 'resemblyzer'"))
    vp_path.unlink(missing_ok=True)
    J._voiceprint = None
    J.enroll_voice(_Recorder(J, []), object())
    J._get_encoder = real_get
    cases.append({"name": "enroll_backend_missing", "input": {}, "expected": {
        "spoken": list(spoken), "chimes": list(chimes), "npy_b64": None, "logged": list(logged)}})

    # The synthetic voiceprint (enroll_three), loaded back the way the app starts.
    vp_path.write_bytes(saved["enroll_three"])
    J._voiceprint = None
    clear()
    J._load_voiceprint()
    if J._voiceprint is None:
        raise AssertionError("_load_voiceprint did not load the synthetic voiceprint")
    cases.append({"name": "load", "input": {}, "expected": {
        "shape": list(J._voiceprint.shape), "dtype": str(J._voiceprint.dtype),
        "f32": _f32(J._voiceprint), "logged": list(logged)}})

    sim_code, _ = _sim_expression(J)
    real_embed = J._embed
    for name, spec in _inputs():
        pcm = _pcm(spec)
        got = {}
        captured = []

        def embed(audio):
            e = real_embed(audio)
            captured.append(e)
            return e
        J._embed = embed
        for label, thr in (("default", None), ("wake", J.WAKE_SPK_THRESHOLD)):
            clear()
            captured.clear()
            ok = J.speaker_ok(_audio(J, pcm)) if thr is None else J.speaker_ok(_audio(J, pcm), threshold=thr)
            emb = captured[0] if captured else None
            got[label] = {"ok": ok, "bumps": list(bumps), "printed": list(printed),
                          "logged": [m for m in logged if m.startswith("Speaker match")]}
            if emb is not None:
                got["sim"] = float(eval(sim_code, {"np": np, "float": float},
                                        {"emb": emb, "_voiceprint": J._voiceprint}))
        if "sim" not in got:
            got["sim"] = None
        clear()
        got["barge_in"] = J._barge_in_speaker_match(pcm.tobytes())
        J._embed = real_embed
        cases.append({"name": f"verify_{name}", "input": spec, "expected": got})

    # The gate off, and no voiceprint: speaker_ok accepts without embedding; barge-in refuses.
    pcm = _pcm({"clip": "samantha_cmd"})
    calls = []
    J._embed = lambda a: calls.append(1) or real_embed(a)
    J._spk_enabled = False
    clear()
    off = {"ok": J.speaker_ok(_audio(J, pcm)), "embedded": len(calls), "bumps": list(bumps)}
    J._spk_enabled = True
    J._voiceprint = None
    calls.clear()
    clear()
    none = {"ok": J.speaker_ok(_audio(J, pcm)), "barge_in": J._barge_in_speaker_match(pcm.tobytes()),
            "embedded": len(calls), "bumps": list(bumps)}
    J._embed = real_embed
    cases.append({"name": "gate_off", "input": {"clip": "samantha_cmd"}, "expected": off})
    cases.append({"name": "no_voiceprint", "input": {"clip": "samantha_cmd"}, "expected": none})

    # forget_voice, with the file there and again without it.
    J._load_voiceprint()
    first = J.forget_voice()
    gone = not vp_path.exists() and J._voiceprint is None
    second = J.forget_voice()
    cases.append({"name": "forget", "input": {}, "expected": {
        "reply": first, "file_removed": gone, "reply_again": second}})
    return cases


@suite("m10_enrol_record")
def enrol_record(ctx):
    """The takes as Python records them: the real Recognizer.record(source, duration=4) (J:5236)
    over a source like JARVIS's microphone (16 kHz, 16-bit, CHUNK = OWW_FRAME_SAMPLES = 1280,
    J:5518), which serves one corpus clip per take, then the real enroll_voice on them."""
    J = ctx.J
    sr = J.sr
    spoken = []
    J.speak, J.chime, J.log = spoken.append, (lambda *a: None), (lambda *a: None)

    class ClipStream:
        def __init__(self):
            self.data, self.pos, self.reads = b"", 0, 0

        def read(self, frames):                          # PyAudio: `frames` samples of 2 bytes
            out = self.data[self.pos:self.pos + frames * 2]
            self.pos += frames * 2
            self.reads += 1
            return out

    class ClipSource(sr.AudioSource):
        def __init__(self):
            self.SAMPLE_RATE, self.SAMPLE_WIDTH, self.CHUNK = RATE, 2, J.OWW_FRAME_SAMPLES
            self.stream = ClipStream()

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    class TakeRecognizer(sr.Recognizer):
        """The real record(), with the next clip put in the stream first."""
        def __init__(self, clips):
            super().__init__()
            self.clips, self.kept, self.reads = list(clips), [], []

        def record(self, source, duration=None, offset=None):
            source.stream.data, source.stream.pos, source.stream.reads = self.clips.pop(0).tobytes(), 0, 0
            audio = sr.Recognizer.record(self, source, duration=duration, offset=offset)
            self.kept.append(len(audio.get_raw_data()) // 2)
            self.reads.append(source.stream.reads)
            return audio

    vp_path = Path(J.VOICEPRINT_FILE)
    vp_path.unlink(missing_ok=True)
    J._voiceprint = None
    rec = TakeRecognizer([_pcm({"clip": c}) for c in ENROL])
    J.enroll_voice(rec, ClipSource())
    data = vp_path.read_bytes() if vp_path.exists() else None
    return [{"name": "enroll_recorded", "input": {"takes": ENROL, "chunk": J.OWW_FRAME_SAMPLES, "duration": 4},
             "expected": {"kept_samples": rec.kept, "chunks_read": rec.reads, "spoken": spoken,
                          "npy_b64": None if data is None else base64.b64encode(data).decode("ascii")}}]


THRESHOLD_INPUTS = [
    None, "0.60", "0.6", "0.5", " 0.7 ", "\t0.65\n", "\x0b0.4\x0c", "1e-1", "+.5", "5.", "-0.2", "0", "1", "1E2",
    "0.1234567890123456789", "1e400", "-1e400", "1e-400", "inf", "-Infinity", "INF", "+inf", "nan", "NaN", "-nan",
    "+NAN", "infinit", "nan(1)", "0_6", "0.6_0", "1_000", "1__0", "_1", "1_", "1_.5", "1._5", "1e1_0", "0x1", "0.6.0",
    "", "  ", "abc", "1e", "1e+", ".", "-", "+", ".e1", "١٢", "０.５", "٠.٥",
    " 0.5", "0.5 ", "　0.5　", "\x1c0.5", "0.5\x7f", "0.5\x00",
]


def _threshold_expressions(J):
    """jarvis.py's two module-level threshold assignments, read from its AST (not retyped)."""
    tree = ast.parse(open(J.__file__, encoding="utf-8").read())
    found = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in ("SPEAKER_THRESHOLD", "WAKE_SPK_THRESHOLD"):
                found[node.targets[0].id] = node.value
    if set(found) != {"SPEAKER_THRESHOLD", "WAKE_SPK_THRESHOLD"}:
        raise AssertionError(f"jarvis.py threshold assignments: {sorted(found)}")
    return {k: (compile(ast.Expression(v), k, "eval"), ast.unparse(v)) for k, v in found.items()}


@suite("m10_thresholds")
def thresholds(ctx):
    """SPEAKER_THRESHOLD and WAKE_SPK_THRESHOLD for each environment value: jarvis.py's own
    expressions, evaluated with os.environ replaced by a dict holding only that variable."""
    import struct
    import types
    J = ctx.J
    exprs = _threshold_expressions(J)
    cases = [{"name": "expressions", "input": {},
              "expected": {k: text for k, (_, text) in sorted(exprs.items())}}]
    for k, raw in enumerate(THRESHOLD_INPUTS):
        expected = {}
        for name, variable in (("SPEAKER_THRESHOLD", "JARVIS_SPK_THRESH"), ("WAKE_SPK_THRESHOLD", "JARVIS_WAKE_SPK_THRESH")):
            env = {} if raw is None else {variable: raw}
            fake_os = types.SimpleNamespace(environ=env)
            try:
                value = eval(exprs[name][0], {"os": fake_os, "float": float})
                expected[name] = {"repr": repr(value), "bits": struct.pack("<d", value).hex()}
            except ValueError as e:
                expected[name] = {"error": type(e).__name__}
        cases.append({"name": f"value_{k:02d}", "input": {"value": raw}, "expected": expected})
    return cases
