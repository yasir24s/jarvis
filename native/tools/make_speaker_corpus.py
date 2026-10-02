#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
"""Write the M10 speaker-verification corpus: Tests/Fixtures/golden/voice/speaker/*.wav.

Run once, by hand; the WAVs are committed (the golden child cannot start `say`). Every speech
clip is a macOS `say` voice, never a recording of a person:

    say -v <voice> -r 180 --file-format=WAVE --data-format=LEI16@16000 -o <tmp>.wav "<text>"

The three daniel_enrol clips are then cut or zero-padded to exactly 64000 samples, the length of
Python's recognizer.record(source, duration=4). One clip is not speech: noise_m25dbfs.wav is
2 s of white noise from np.random.default_rng(7), scaled to -25 dBFS RMS. Each file is
rewritten with Python's wave module (16 kHz, mono, 16-bit, a 44-byte header), and
manifest.json records the macOS build, the say command, the sample count and the SHA-256 of
each file, because say's output can change with an OS update.

    make_speaker_corpus.py           write the corpus (refuses to overwrite a different file)
    make_speaker_corpus.py --check   exit 1 unless every file matches the manifest
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
OUT = NATIVE / "Tests" / "Fixtures" / "golden" / "voice" / "speaker"
RATE = 16000
SAY_RATE = 180
ENROL_SAMPLES = 64000          # recognizer.record(source, duration=4) at 16 kHz

# name | voice | text. Daniel stands in for the enrolled user; the others are other speakers.
SPEECH = [
    ("daniel_enrol_1", "Daniel", "Good morning. I would like to check my calendar for this week, please."),
    ("daniel_enrol_2", "Daniel", "The quick brown fox jumps over the lazy dog, down by the river bank."),
    ("daniel_enrol_3", "Daniel", "Please remind me to call the office at three o'clock this afternoon."),
    ("daniel_cmd_1", "Daniel", "Jarvis, what is the weather like today?"),
    ("daniel_cmd_2", "Daniel", "Open Safari and search for train times to London."),
    ("daniel_long", "Daniel", "I have been reading about the history of the London Underground. The first "
                              "line opened in eighteen sixty three, and it ran on steam."),
    ("daniel_pause", "Daniel", "Set a timer for ten minutes. [[slnc 1500]] Actually, make it twenty."),
    ("daniel_short", "Daniel", "Yes."),
    ("samantha_cmd", "Samantha", "Jarvis, what is the weather like today?"),
    ("karen_cmd", "Karen", "Open Safari and search for train times to London."),
    ("moira_cmd", "Moira", "Please remind me to call the office at three o'clock this afternoon."),
    ("rishi_cmd", "Rishi", "Good morning. I would like to check my calendar for this week, please."),
]


def say_command(voice, text, path):
    return ["say", "-v", voice, "-r", str(SAY_RATE), "--file-format=WAVE",
            "--data-format=LEI16@16000", "-o", str(path), text]


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, RATE):
            raise SystemExit(f"{path.name}: not 16 kHz mono 16-bit")
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").copy()


def write_wav(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(samples.astype("<i2").tobytes())


def noise():
    x = np.random.default_rng(7).standard_normal(2 * RATE)
    x *= (10 ** (-25 / 20)) * 32767 / np.sqrt(np.mean(x ** 2))
    return np.clip(np.round(x), -32768, 32767).astype(np.int16)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(tmp):
    clips = []
    for name, voice, text in SPEECH:
        raw = Path(tmp) / f"{name}.say.wav"
        cmd = say_command(voice, text, raw)
        subprocess.run(cmd, check=True)
        samples = read_wav(raw)
        if name.startswith("daniel_enrol"):
            samples = np.pad(samples, (0, max(0, ENROL_SAMPLES - len(samples))))[:ENROL_SAMPLES]
        clips.append((name, samples, {"voice": voice, "text": text,
                                      "say": " ".join(cmd[:-3] + ["-o", f"{name}.wav", repr(text)])}))
    clips.append(("noise_m25dbfs", noise(), {"voice": None, "text": None,
                                             "say": None, "made": "np.random.default_rng(7), -25 dBFS RMS, 2 s"}))
    return clips


def main(argv):
    manifest_path = OUT / "manifest.json"
    if argv == ["--check"]:
        manifest = json.loads(manifest_path.read_text())
        bad = [c["file"] for c in manifest["clips"] if sha256(OUT / c["file"]) != c["sha256"]]
        print("speaker corpus:", "ok" if not bad else f"changed: {bad}")
        return 1 if bad else 0
    if argv:
        raise SystemExit(__doc__)
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        clips = build(tmp)
        entries = []
        for name, samples, meta in clips:
            path = OUT / f"{name}.wav"
            staged = Path(tmp) / f"{name}.wav"
            write_wav(staged, samples)
            if path.exists() and sha256(path) != sha256(staged):
                raise SystemExit(f"{path.name} exists and differs; delete it first to regenerate")
            staged.replace(path)
            entries.append({"file": path.name, "samples": int(len(samples)),
                            "sha256": sha256(path), **meta})
    build_id = subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip()
    manifest = {"generator": "native/tools/make_speaker_corpus.py", "macos": platform.mac_ver()[0],
                "macos_build": build_id, "say_rate": SAY_RATE, "rate": RATE, "clips": entries}
    manifest_path.write_text(json.dumps(manifest, indent=1) + "\n")
    for e in entries:
        print(f"{e['file']:24} {e['samples'] / RATE:5.2f} s  {e['voice'] or 'noise'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
