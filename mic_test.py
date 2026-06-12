#!/usr/bin/env python3
"""Microphone access probe. Reports whether we can actually capture audio."""
import sys, time, audioop
import pyaudio

CHUNK = 1024
RATE = 16000
SECONDS = 2.0

pa = pyaudio.PyAudio()
try:
    stream = pa.open(format=pyaudio.paInt16, channels=1, rate=RATE,
                     input=True, frames_per_buffer=CHUNK)
except Exception as e:
    print(f"OPEN_FAILED: {e}")
    sys.exit(2)

levels = []
t0 = time.time()
try:
    while time.time() - t0 < SECONDS:
        data = stream.read(CHUNK, exception_on_overflow=False)
        rms = audioop.rms(data, 2)
        levels.append(rms)
except Exception as e:
    print(f"READ_FAILED: {e}")
    sys.exit(3)
finally:
    stream.stop_stream()
    stream.close()
    pa.terminate()

peak = max(levels) if levels else 0
avg = sum(levels) / len(levels) if levels else 0
print(f"FRAMES={len(levels)} PEAK_RMS={peak} AVG_RMS={avg:.1f}")
# All-zero RMS across the board => permission denied (macOS feeds silence)
if peak == 0:
    print("RESULT=SILENCE_LIKELY_DENIED")
    sys.exit(4)
else:
    print("RESULT=MIC_WORKING")
    sys.exit(0)
