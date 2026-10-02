# Speaker-verification fixtures (M10)

Every speech file here is a macOS `say` voice. None is a recording of a person, and none is the
user's voice. Daniel stands in for the enrolled user; Samantha, Karen, Moira and Rishi are the
other speakers. One file is not speech: `noise_m25dbfs.wav` is 2 s of white noise from
`np.random.default_rng(7)`, scaled to -25 dBFS RMS.

`native/tools/make_speaker_corpus.py` made them on macOS 27.2 (build 26B5091g) with these
commands:

```
say -v Daniel -r 180 --file-format=WAVE --data-format=LEI16@16000 -o daniel_enrol_1.wav 'Good morning. I would like to check my calendar for this week, please.'
say -v Daniel -r 180 --file-format=WAVE --data-format=LEI16@16000 -o daniel_enrol_2.wav 'The quick brown fox jumps over the lazy dog, down by the river bank.'
say -v Daniel -r 180 --file-format=WAVE --data-format=LEI16@16000 -o daniel_enrol_3.wav "Please remind me to call the office at three o'clock this afternoon."
say -v Daniel -r 180 --file-format=WAVE --data-format=LEI16@16000 -o daniel_cmd_1.wav 'Jarvis, what is the weather like today?'
say -v Daniel -r 180 --file-format=WAVE --data-format=LEI16@16000 -o daniel_cmd_2.wav 'Open Safari and search for train times to London.'
say -v Daniel -r 180 --file-format=WAVE --data-format=LEI16@16000 -o daniel_long.wav 'I have been reading about the history of the London Underground. The first line opened in eighteen sixty three, and it ran on steam.'
say -v Daniel -r 180 --file-format=WAVE --data-format=LEI16@16000 -o daniel_pause.wav 'Set a timer for ten minutes. [[slnc 1500]] Actually, make it twenty.'
say -v Daniel -r 180 --file-format=WAVE --data-format=LEI16@16000 -o daniel_short.wav 'Yes.'
say -v Samantha -r 180 --file-format=WAVE --data-format=LEI16@16000 -o samantha_cmd.wav 'Jarvis, what is the weather like today?'
say -v Karen -r 180 --file-format=WAVE --data-format=LEI16@16000 -o karen_cmd.wav 'Open Safari and search for train times to London.'
say -v Moira -r 180 --file-format=WAVE --data-format=LEI16@16000 -o moira_cmd.wav "Please remind me to call the office at three o'clock this afternoon."
say -v Rishi -r 180 --file-format=WAVE --data-format=LEI16@16000 -o rishi_cmd.wav 'Good morning. I would like to check my calendar for this week, please.'
```

After `say`, the script cuts or zero-pads the three `daniel_enrol` clips to exactly 64000 samples,
the length of Python's `recognizer.record(source, duration=4)`. It then rewrites every file with
Python's `wave` module: 16 kHz, mono, 16-bit, a 44-byte header. `manifest.json` records each
file's sample count and SHA-256; `make_speaker_corpus.py --check` compares them.

`say` can render differently after an OS update, and in one run the first use of a voice gave a
different file. The committed files are the reference: `tools/golden_m10_speaker.py` computes
the Python expectations from them, so regenerating them means regenerating that suite too.
