#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
"""Write the M11 wake-word corpus: Tests/Fixtures/golden/voice/wake/*.wav.

Run once, by hand; the WAVs are committed (the golden child cannot start `say`). Every speech
clip is a macOS `say` voice rendered to a file, never a recording of a person, and nothing is
played aloud:

    say -v <voice> -r <rate> --file-format=WAVE --data-format=LEI16@16000 -o <tmp>.wav "<text>"

Each clip is put between 1.0 s and 3.0 s of a quiet noise floor (np.random.default_rng(seed),
Gaussian, -60 dBFS RMS), as a microphone would hear it, so no frame is digital silence.

The wake clips are searched for (plan M08-M13 §4): "Hey Jarvis", "Jarvis", "Hey Jarvis, what's
the time" and "Jarvis. Close Safari", in several voices at 160, 200 and 240 words a minute,
scored by the real openwakeword Model as jarvis.py builds it, with every reset's seed noise
taken from `seed_noise(k)` (the golden suites and the Swift tests use the same). The search
keeps going until it has four clips whose top score is at least 0.5 (hard fires) and four whose
top score is in [0.15, 0.5) (soft candidates), and fails loudly if it cannot. Three negatives
("Hey Travis", "Java's great", "the weather tomorrow") and 3 s of white noise at -40 dBFS
(np.random.default_rng(7)) are always written.

manifest.json records the macOS build, each say command, the sample count, the SHA-256 and the
top score of each file, because say's output can change with an OS update.

    make_wake_corpus.py           write the corpus (refuses to overwrite a different file)
    make_wake_corpus.py --check   exit 1 unless every file matches the manifest
"""
import hashlib
import json
import platform
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

NATIVE = Path(__file__).resolve().parents[1]
OUT = NATIVE / "Tests" / "Fixtures" / "golden" / "voice" / "wake"
RATE = 16000
FRAME = 1280
LEAD, TAIL = 1.0, 3.0
FLOOR_DBFS = -60.0

PHRASES = [("hey", "Hey Jarvis"), ("bare", "Jarvis"), ("time", "Hey Jarvis, what's the time"),
           ("close", "Jarvis. Close Safari")]
VOICES = ["Daniel", "Samantha", "Karen", "Moira", "Rishi", "Fred", "Ralph", "Kathy"]
RATES = [200, 160, 240]
NEGATIVES = [("neg_travis", "Daniel", 200, "Hey Travis"), ("neg_java", "Samantha", 200, "Java's great"),
             ("neg_weather", "Karen", 200, "the weather tomorrow")]
WANT = 4


def seed_noise(k):
    """The k-th reset's 64000 seed samples in [-1000, 1000): a 32-bit LCG that Swift's
    WakeSeed.noise(k) reproduces exactly (np.random.randint in openwakeword's
    AudioFeatures.__init__ and reset is replaced by this in the golden child)."""
    x = (k * 2654435761 + 1) & 0xFFFFFFFF
    out = np.empty(64000, dtype=np.int64)
    for i in range(64000):
        x = (1664525 * x + 1013904223) & 0xFFFFFFFF
        out[i] = (x >> 8) % 2000 - 1000
    return out


class SeededRandint:
    """np.random.randint, except openwakeword's seed call, which gets seed_noise(0), (1), ..."""
    def __init__(self, real):
        self.real, self.k = real, 0

    def __call__(self, *args, **kwargs):
        if args == (-1000, 1000, 16000 * 4) and not kwargs:
            noise = seed_noise(self.k)
            self.k += 1
            return noise
        return self.real(*args, **kwargs)


def scores(pcm):
    """openwakeword's per-frame scores for `pcm` as jarvis.py's get_wakeword() model gives them
    after model.reset(), with seeds 0 (the model's construction) and 1 (the reset)."""
    from openwakeword.model import Model
    real = np.random.randint
    np.random.randint = SeededRandint(real)
    try:
        model = Model(wakeword_models=["hey_jarvis"], inference_framework="onnx")
        model.reset()
        out = []
        for start in range(0, len(pcm) - FRAME + 1, FRAME):
            out.append(float(model.predict(pcm[start:start + FRAME]).get("hey_jarvis", 0.0)))
        return out
    finally:
        np.random.randint = real


def floor(n, seed):
    sigma = 32768.0 * 10 ** (FLOOR_DBFS / 20)
    return np.random.default_rng(seed).normal(0.0, sigma, n)


def say(voice, rate, text, path):
    cmd = ["say", "-v", voice, "-r", str(rate), "--file-format=WAVE", "--data-format=LEI16@16000",
           "-o", str(path), text]
    subprocess.run(cmd, check=True)
    return cmd


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, RATE):
            raise SystemExit(f"{path}: not 16 kHz mono 16-bit")
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.int16)


def write_wav(path, pcm):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.astype("<i2").tobytes())


def framed(speech, seed):
    lead, tail = floor(int(LEAD * RATE), seed), floor(int(TAIL * RATE), seed + 1)
    mixed = np.concatenate([lead, speech.astype(np.float64), tail])
    return np.clip(np.round(mixed), -32768, 32767).astype(np.int16)


def render(name, voice, rate, text, seed, tmp):
    cmd = say(voice, rate, text, tmp / f"{name}.wav")
    pcm = framed(read_wav(tmp / f"{name}.wav"), seed)
    return pcm, " ".join(cmd[:-3] + ["-o", "<file>", repr(text)])


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check():
    manifest = json.loads((OUT / "manifest.json").read_text())
    bad = [n for n, e in manifest["files"].items() if not (OUT / n).exists() or sha(OUT / n) != e["sha256"]]
    if bad:
        print(f"make_wake_corpus: {len(bad)} file(s) differ from the manifest: {bad}")
        return 1
    print(f"make_wake_corpus: {len(manifest['files'])} files match the manifest")
    return 0


def main(argv):
    if argv[1:] == ["--check"]:
        return check()
    OUT.mkdir(parents=True, exist_ok=True)
    chosen, hard, soft, seed = {}, [], [], 100
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        for rate in RATES:
            for voice in VOICES:
                for key, text in PHRASES:
                    if len(hard) >= WANT and len(soft) >= WANT:
                        break
                    name = f"wake_{key}_{voice.lower()}_{rate}"
                    pcm, cmd = render(name, voice, rate, text, seed, tmp)
                    seed += 2
                    top = max(scores(pcm))
                    if top >= 0.5 and len(hard) < WANT:
                        hard.append(name)
                    elif 0.15 <= top < 0.5 and len(soft) < WANT:
                        soft.append(name)
                    else:
                        continue
                    chosen[name] = {"key": key, "pcm": pcm, "say": cmd, "top": top}
                    print(f"  {name}: top score {top:.3f}")
        if len(hard) < 3 or len(soft) < 3:
            raise SystemExit(f"make_wake_corpus: found {len(hard)} hard and {len(soft)} soft clips; need 3 of each")
        for name, voice, rate, text in NEGATIVES:
            pcm, cmd = render(name, voice, rate, text, seed, tmp)
            seed += 2
            chosen[name] = {"key": "negative", "pcm": pcm, "say": cmd, "top": max(scores(pcm))}
            print(f"  {name}: top score {chosen[name]['top']:.3f}")
    noise = np.random.default_rng(7).standard_normal(3 * RATE)
    noise = noise / np.sqrt(np.mean(noise ** 2)) * 32768.0 * 10 ** (-40 / 20)
    chosen["noise_m40dbfs"] = {"key": "noise", "pcm": np.clip(np.round(noise), -32768, 32767).astype(np.int16),
                               "say": None, "top": None}
    chosen["noise_m40dbfs"]["top"] = max(scores(chosen["noise_m40dbfs"]["pcm"]))
    files = {}
    for name, c in sorted(chosen.items()):
        path = OUT / f"{name}.wav"
        tmp_path = OUT / f".{name}.wav.new"
        write_wav(tmp_path, c["pcm"])
        if path.exists() and sha(path) != sha(tmp_path):
            tmp_path.unlink()
            raise SystemExit(f"make_wake_corpus: {path.name} exists and differs; delete it first to regenerate")
        tmp_path.replace(path)
        files[path.name] = {"kind": c["key"], "say": c["say"], "samples": int(len(c["pcm"])),
                            "sha256": sha(path), "top_score": round(c["top"], 6)}
    manifest = {"macos": platform.mac_ver()[0], "build": subprocess.run(["sw_vers", "-buildVersion"],
                capture_output=True, text=True).stdout.strip(), "rate": RATE, "lead_s": LEAD, "tail_s": TAIL,
                "floor_dbfs": FLOOR_DBFS, "files": files}
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    print(f"make_wake_corpus: {len(files)} files in {OUT.relative_to(NATIVE)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
