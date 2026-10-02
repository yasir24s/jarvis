# Wake-word fixtures (M11)

Every speech file here is a macOS `say` voice rendered to a file. None is a recording of a
person, and none is the user's voice. Each clip sits between 1.0 s and 3.0 s of a quiet noise
floor (Gaussian, -60 dBFS RMS, from `np.random.default_rng`), so no frame is digital silence.
`noise_m40dbfs.wav` is 3 s of white noise from `np.random.default_rng(7)` at -40 dBFS RMS.

`native/tools/make_wake_corpus.py` made them on macOS 27.2 (build 26B5091g). It searched voices
and rates for four clips that openWakeWord fires on (top score at least 0.5) and four in the
soft tier's band (0.15 to 0.5), scoring each with the real `openwakeword` model as jarvis.py
builds it, and with the seed noise of `seed_noise(k)` for every reset. `manifest.json` has each
`say` command, the sample count, the SHA-256 and that top score.

| File | Text | Voice, rate | Top score |
|---|---|---|---|
| wake_hey_daniel_200 | Hey Jarvis | Daniel, 200 | 0.998 |
| wake_hey_samantha_200 | Hey Jarvis | Samantha, 200 | 0.999 |
| wake_time_daniel_200 | Hey Jarvis, what's the time | Daniel, 200 | 0.998 |
| wake_bare_samantha_200 | Jarvis | Samantha, 200 | 0.996 |
| wake_bare_ralph_200 | Jarvis | Ralph, 200 | 0.482 |
| wake_bare_kathy_200 | Jarvis | Kathy, 200 | 0.406 |
| wake_close_kathy_200 | Jarvis. Close Safari | Kathy, 200 | 0.448 |
| wake_bare_karen_200 | Jarvis | Karen, 200 | 0.151 |
| neg_travis | Hey Travis | Daniel, 200 | 0.366 |
| neg_java | Java's great | Samantha, 200 | 0.060 |
| neg_weather | the weather tomorrow | Karen, 200 | 0.118 |
| noise_m40dbfs | (white noise) | | 0.272 |

`make_wake_corpus.py --check` confirms the files still match the manifest.
