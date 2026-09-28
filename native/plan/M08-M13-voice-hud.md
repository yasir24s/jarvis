# M8–M13 — Voice out, voice in, speaker verification, wake word, conversation loop & barge-in, HUD
## 1. Goal and scope (in / explicitly out)

Replace every audio and presentation path of `jarvis.py` with native code in two SwiftPM
targets: `JarvisVoice` (headless, no AppKit/SwiftUI, unit-testable) and the HUD in
`JarvisApp`. Nothing here may add PyTorch, Whisper, WebKit or a Python interpreter to the
running app. Python stays the oracle for tests and one-off model export only.

In scope

| Milestone | In |
|---|---|
| M8 Voice out | `SpeechEngine` protocol. ElevenLabs = primary engine (HTTPS streaming via `URLSession`, no SDK). Piper `en_GB-alan-medium` = fallback engine, used when offline, on HTTP 401/402/429, on timeout, on any error, and for replies the user's `speakLocally` rule marks sensitive. Piper runs natively (ORT + espeak-ng phonemizer; route chosen in §3.2). Pitch shift via `AVAudioUnitTimePitch`. Sentence streaming that keeps the `pop_sentences` contract. `say -v Daniel -r 200` as the last resort. Chimes. All playback goes through the one `AVAudioEngine`, because echo cancellation can only remove audio it plays itself. Keychain storage for the ElevenLabs key. Dataset counters, proposed as additive: `tts_elevenlabs`, `tts_piper`, `tts_fallback_<reason>`, `tts_elevenlabs_chars`. |
| M9 Voice in | `AVAudioEngine` capture with voice processing (echo cancellation), 16 kHz mono Int16 frames of 1280 samples fanned out to sinks. A port of `speech_recognition`'s energy endpointer (golden-tested). `SpeechTranscriber` (en-GB, on-device) fed live while each utterance is captured. `contextualStrings` built from `WHISPER_PROMPT`, the profile name and correction targets. A confidence gate standing in for Whisper's hallucination guard. `_apply_corrections` called at the one transcription choke point. Sentence-aware continuation (`_INCOMPLETE_TAIL_RE`). `analyze_tone` port with its `tone_*` counters. Mic permission, device choice and rebinding on device change. |
| M10 Speaker verification | Resemblyzer exported to ONNX (spike first). Native preprocessing: `normalize_volume`, a bit-exact `trim_long_silences` (webrtcvad), and the librosa mel. Partial slicing and averaging. Embeddings must match Python to cosine ≥ 0.999. The existing `~/jarvis/voiceprint.npy` is read and written byte-compatibly (NPY v1.0, `<f4`, shape `(256,)`). Covers `speaker_ok`, the wake gate at `WAKE_SPK_THRESHOLD`, the fail-closed barge-in gate, `enroll_voice` (3 × 4 s) and `forget_voice`. |
| M11 Wake word | Salvaged openWakeWord ORT pipeline, ported to Swift 6 with `reset()`. Hard tier `WAKE_THRESHOLD`, soft tier `WAKE_SOFT` confirmed by SpeechTranscriber, dead-stream detection. Golden scores against Python on the same WAVs. |
| M12 Conversation loop & barge-in | The `run_assistant` state machine: wake → speaker gate before chime/HUD → command → conversation mode → dismiss, `CONV_TIMEOUT`, enrolment and forget by voice, the startup watchdog (exit 86), mic rebinding. Barge-in: VAD pre-gate, 800 ms of sustained speech, fail-closed speaker match. |
| M13 HUD | A native `NSPanel` that is non-activating, click-through, 360×430 at bottom-left and at screen-saver level. SwiftUI arc reactor with the four states, captions, level bars and the 2.6 s idle auto-hide from `hud.html`. Accessory activation policy. |

Explicitly out

- Google STT (`JARVIS_STT=google|auto`). It is cloud and opt-in. `JARVIS_STT` is read and
  logged as unsupported, and SpeechTranscriber is always used. `JARVIS_WHISPER` and
  `JARVIS_WHISPER_BEAM` are obsolete (PARITY marks them so). They are read and ignored,
  and startup logs one line naming them.
- The brain, tools, fast path, confirmation-gate logic and corrections *storage* (M2–M7).
  This section consumes their interfaces: `Corrections.apply(_:)`,
  `FastPath.route(_:)`, `Brain.process(_:turn:) -> AsyncStream<String>`,
  `ConfirmationGate.consumePending(_:)`, `Research.bump(_:)`, `Emotions.event(_:)`,
  `Personality.distillAsync()`, `Profile.name`.
- `identify_ambient` / Shazam (M6). M12 only gives it a `MicPipeline.record(seconds:)` hook.
- Windows paths (`IS_WIN` branches). macOS only.
- Background loops that speak (proactive, briefing, meeting, battery; M14). They call
  `SpeechQueue.say(_:turn:)` and the `HUDController` API defined here.
- Voice design at ElevenLabs. The user does this manually in their account (§6, T8.0). It
  is not a clone of Paul Bettany or any real person.
## 2. Python reference

Paths: `J` = `~/jarvis/jarvis.py`. `SP` = `/Library/Frameworks/Python.framework/Versions/3.14/lib/python3.14/site-packages`.
Installed versions (queried via `importlib.metadata`, nothing imported): piper-tts 1.4.2,
onnxruntime 1.26.0, torch 2.12.0, Resemblyzer 0.1.4, openwakeword 0.6.0, webrtcvad 2.0.10,
SpeechRecognition 3.16.1, numpy 2.4.4, librosa 0.11.0, scipy 1.17.1. **`onnx` and
`onnxscript` are NOT installed.**

### 2.1 Configuration (verbatim)

| Constant | File:line | Verbatim | Notes |
|---|---|---|---|
| `WAKE_WORDS` | J:69 | `WAKE_WORDS      = ["jarvis", "hey jarvis", "ok jarvis", "j.a.r.v.i.s", "jervis", "jarvis."]` | used by `extract_command` (longest first) |
| `MIC_RATE` | J:70 | `MIC_RATE        = 16000` | |
| `PHRASE_LIMIT` | J:72 | `PHRASE_LIMIT    = 12` | `phrase_time_limit` for every listen |
| `CONV_TIMEOUT` | J:73 | `CONV_TIMEOUT    = 30             # seconds to keep a conversation open with no speech` | |
| `PIPER_MODEL` | J:80 | `PIPER_MODEL     = os.path.join(HERE, "voices", "en_GB-alan-medium.onnx")` | 63,201,294 bytes; config `.onnx.json`: sample_rate 22050, espeak voice `en-gb-x-rp`, noise_scale 0.667, length_scale 1, noise_w 0.8, 154 phoneme ids |
| `PIPER_LENGTH` | J:82 | `PIPER_LENGTH    = float(os.environ.get("JARVIS_SPEED", "0.62"))  # <1.0 = faster/more human` | Piper `length_scale` (the duration model, not a tempo effect) |
| `VOICE_PITCH` | J:83 | `VOICE_PITCH     = float(os.environ.get("JARVIS_PITCH", "0.92"))  # <1.0 = deeper (toward film JARVIS)` | the ffmpeg pitch factor |
| `TTS_RATE` | J:84 | `TTS_RATE        = "200"                 # fallback \`say\` rate` | |
| `FALLBACK_VOICE` | J:85 | `FALLBACK_VOICE  = "Daniel"` | |
| `ENABLE_HUD` | J:88 | `ENABLE_HUD      = os.environ.get("JARVIS_NO_HUD") != "1"` | |
| `STT_ENGINE` | J:90 | `STT_ENGINE      = os.environ.get("JARVIS_STT", "whisper").strip().lower() # local-first; "auto"/"google" are opt-in` | native: only the local path |
| `STT_LANG` | J:91 | `STT_LANG        = os.environ.get("JARVIS_STT_LANG", "en-GB")             # locale for the optional Google path` | native: SpeechTranscriber locale (reuse the same env) |
| `WHISPER_PROMPT` | J:95-98 | `"A short voice command spoken to JARVIS, a personal assistant. "` `"Vocabulary: Jarvis, calendar, reminder, alarm, timer, volume, brightness, "` `"screenshot, weather, news, Safari, Chrome, thank you, that's all Jarvis."` | env `JARVIS_WHISPER_PROMPT`; becomes `contextualStrings` (§3.4) |
| `BARGE_IN_ENABLED` | J:675 | `BARGE_IN_ENABLED   = os.environ.get("JARVIS_BARGE_IN", "1") != "0"` | |
| `BARGE_IN_MS` | J:676 | `BARGE_IN_MS        = 800                     # sustained voiced audio required before we react` | `frames_needed = BARGE_IN_MS // 80` = 10 |
| `SENT_PAUSE` | J:984 | `SENT_PAUSE = float(os.environ.get("JARVIS_PAUSE", "0.9"))   # end-of-sentence silence, s` | the recognizer's `pause_threshold` (J:5510) |
| `_INCOMPLETE_TAIL_RE` | J:986-988 | `r"(?:,\|\b(?:and\|but\|or\|so\|then\|because\|to\|the\|a\|an\|my\|your\|for\|with\|of\|in\|on\|at"` `r"\|that\|i\|you\|please\|um\|uh\|er))$", re.I` | pipes are escaped for the table; the golden test uses the regex source string exported by golden.py |
| `OWW_FRAME_SAMPLES` | J:1073 | `OWW_FRAME_SAMPLES = 1280                    # 80ms @ 16kHz — openWakeWord's expected hop` | |
| `WAKE_THRESHOLD` | J:1074 | `WAKE_THRESHOLD    = float(os.environ.get("JARVIS_WAKE_THRESHOLD", "0.5"))` | |
| `WAKE_SOFT` | J:1085 | `WAKE_SOFT = float(os.environ.get("JARVIS_WAKE_SOFT", "0.15"))   # 0 disables the soft tier` | |
| `_SENT_BOUNDARY` | J:4696 | `_SENT_BOUNDARY = re.compile(r'[.!?]+\s+')` | owned by M3/M4; the SpeechQueue contract depends on it |
| `_SENT_MAX_CHARS` | J:4697 | `_SENT_MAX_CHARS = 160` | |
| `_WAKE_RE` | J:5109 | `_WAKE_RE = re.compile(r"\b(?:hey \|ok \|okay )?(?:jarvis\|jarviss\|jervis\|j\.?a\.?r\.?v\.?i\.?s)\b")` | pipes escaped for the table |
| `VOICEPRINT_FILE` | J:5134 | `VOICEPRINT_FILE   = os.path.join(HERE, "voiceprint.npy")` | on disk: 1152 bytes = 128-byte NPY v1.0 header `{'descr': '<f4', 'fortran_order': False, 'shape': (256,), }` + 256 × float32 |
| `SPEAKER_THRESHOLD` | J:5140 | `SPEAKER_THRESHOLD  = float(os.environ.get("JARVIS_SPK_THRESH", "0.60"))` | |
| `WAKE_SPK_THRESHOLD` | J:5141 | `WAKE_SPK_THRESHOLD = float(os.environ.get("JARVIS_WAKE_SPK_THRESH", "0.38"))` | |
| HUD geometry | J:5740-5744 | `W, H = 360, 430` / `x=28, y=(SH - H) - 48,          # bottom-left, out of the way` | pywebview uses a top-left origin, so the panel's bottom edge sits 48 pt above the screen bottom |
| Startup watchdog | J:5482-5485 | `if not _listening.wait(240):` … `os._exit(86)` | |
| Recogniser setup | J:5508-5533 | `recognizer.dynamic_energy_threshold = True`, `recognizer.pause_threshold = SENT_PAUSE`, `adjust_for_ambient_noise(src, duration=2)`, `recognizer.energy_threshold = min(recognizer.energy_threshold, 3000)` | mic-verify loop `while attempt < 12:` with `time.sleep(1.5)` |

### 2.2 Behaviour

| Function / constant | File:lines | Behaviour | Notes |
|---|---|---|---|
| `_play_wav`, `stop_playback` | J:609-641 | Plays through `afplay` with the process kept killable; `stop_playback` terminates it | native: an `AVAudioPlayerNode` in the shared engine, so AEC sees it |
| `get_piper` | J:653-664 | Lazy `PiperVoice.load(PIPER_MODEL, PIPER_CONFIG)` in-process; on failure sets `False` and uses the system voice | Piper is not a subprocess. ROADMAP row "Piper (subprocess)" is wrong; see §8 |
| `_barge_in_speaker_match` | J:680-689 | No voiceprint → False. `_embed` → None → False (fail closed). Cosine ≥ `SPEAKER_THRESHOLD` | |
| `_barge_in_watch` | J:691-721 | Runs only while playing and only if `BARGE_IN_ENABLED`, a voiceprint and a mic all exist. `webrtcvad.Vad(3)`. Each 1280-sample frame is voiced if any 20 ms (320-sample) subframe is speech. A run of 10 voiced frames → speaker match → `_barge_in_triggered.set()`, `emotion_event("barge_in")`, `stop_playback()`. A mismatch resets the run | |
| `speak` | J:723-772 | Strips `[*_\`#\[\]()\|\\~>•]` and collapses whitespace. Piper `synthesize_wav(..., length_scale=PIPER_LENGTH)`. If `VOICE_PITCH != 1.0`, runs ffmpeg `asetrate={new_rate},aresample={sr_hz},atempo={atempo:.5f}` with `new_rate = max(8000, int(sr_hz * VOICE_PITCH))`, `atempo = sr_hz / new_rate`. Barge-in watcher runs during playback. Any failure → `_system_say` unless barge-in fired | regex source is exported verbatim by golden.py |
| `_system_say` | J:774-788 | `say -v Daniel -r 200 <text>` | |
| `chime` | J:792-802 | `afplay /System/Library/Sounds/{name}.aiff` async; names used are Tink, Glass, Funk | |
| `_apply_corrections` | J:892-913 | Taught substitutions, applied to every transcript. Interface only here (owned by M1/M2) | |
| `_whisper_prompt` | J:915-931 | `WHISPER_PROMPT` + `" Also: "` + profile name + `meant` of the last 12 corrections, de-duplicated | |
| `whisper_transcribe` | J:933-958 | faster-whisper `beam_size=WHISPER_BEAM, temperature=0.0, condition_on_previous_text=False, vad_filter=True, vad_parameters={"min_silence_duration_ms": 400}`. Drops a segment if `s.no_speech_prob > 0.6 or s.avg_logprob < -1.2` and calls `research_bump("stt_segments_dropped")` per dropped segment | SpeechTranscriber has no `no_speech_prob`/`avg_logprob`; it has a per-run `transcriptionConfidence: Double` (verified in the SDK). The mapping is in §3.4 |
| `transcribe` | J:960-974 | Whisper path + `_apply_corrections` | |
| `listen_sentence` | J:990-1004 | `recognizer.listen(timeout, phrase_time_limit=PHRASE_LIMIT)` → transcribe → lower/strip. If `_INCOMPLETE_TAIL_RE` matches, listens once more with `timeout=2.2` and appends the continuation. Returns `(text, audio)` for the first clip only | |
| `analyze_tone` | J:1006-1048 | 20 ms frames (F=320); `voiced = rms > max(0.01, rms.max()*0.2)`; needs ≥ 5 voiced frames. `loud_db` = 20·log10(mean voiced rms). f0 from the autocorrelation of the 10 loudest frames (W=640, lag 40..228), accepted if `ac[lag] > 0.3*ac[0]`; `f0_std` needs ≥ 4 values. `rate` = words / voiced seconds (min 0.3). Rules in order: `rate >= 3.6 and loud_db > -26` → "hurried and tense"; `loud_db > -22 and f0_std < 12 and rate >= 2.0` → "clipped, possibly irritated"; `f0_std > 28 and rate >= 2.4` → "animated and upbeat"; `loud_db < -34 and rate < 2.2` → "quiet and subdued"; else "calm and even". Under 0.4 s → "" | deterministic, golden |
| `set_tone` / `tone_context` | J:1052-1066 | `research_bump("tone_" + re.sub(r"\W+", "_", desc.split(",")[0].strip()))`. "hurried" → `emotion_event("user_urgent")`. The prompt tone expires after 90 s | counter keys: `tone_hurried_and_tense`, `tone_clipped`, `tone_animated_and_upbeat`, `tone_quiet_and_subdued`, `tone_calm_and_even`. Sacred; never rename |
| `get_wakeword` | J:1077-1083 | `Model(wakeword_models=["hey_jarvis"], inference_framework="onnx")` | |
| `wait_for_wake_word` | J:1087-1142 | `model.reset()`, a 25-frame ring. All-zero frame counter: at 250 in a row → return False (dead stream). `score >= WAKE_THRESHOLD` → return the ring's audio. Soft tier: `WAKE_SOFT > 0 and score >= WAKE_SOFT`, recogniser present and more than 3.0 s since the last soft attempt → read 20 more frames, transcribe ring+extra, `_apply_corrections`, and if `contains_wake_word` → return `(heard, clip)`, else `model.reset()` | |
| `contains_wake_word`, `extract_command` | J:5110-5131 | Regex search. Strips the longest `WAKE_WORDS` prefix and `" ,;."`. A mid-phrase "jarvis" returns before+after, removing a trailing hey/ok/okay from before | the prototype `Assistant.swift` got this wrong (no before+after), so it is rewritten against golden |
| `_load_voiceprint` | J:5146-5154 | `np.load(VOICEPRINT_FILE)` if it exists | |
| `_embed` | J:5163-5178 | int16 → float/32768. Under 0.6 s (9600 samples) → None. `preprocess_wav(wav, source_sr=16000)`; under 0.4 s after trimming → None; `embed_utterance` | |
| `speaker_ok` | J:5180-5198 | Fails open: no print, gate off, or emb None → True. Cosine uses `+ 1e-9` in the denominator; `sim < thr` → `research_bump("speaker_reject")`, False; else `research_bump("speaker_pass")` | |
| `_is_enroll` | J:5200-5206 | exact set + substring list | golden |
| `enroll_voice` | J:5208-5239 | Speaks the prompt, chime Tink, 3 × `recognizer.record(duration=4)`; per segment `preprocess_wav`, keep if > 0.8 s (12800 samples); `vp = mean; vp /= (norm + 1e-9)`; `np.save`; chime Glass; speaks confirmation | spoken strings are verbatim in the source |
| `forget_voice` | J:5241-5249 | Deletes the file, clears the print, returns "Voice recognition cleared, sir. I'll respond to any voice now." | also reached from fast path J:4503-4506 |
| `request_microphone_access` | J:5251-5282 | AVCaptureDevice status; request; polls up to 150 s; speaks "Please allow microphone access, sir." once | |
| `pick_microphone_index` / `_find_mic_index_by_name` | J:5284-5321 | prefer `("macbook", "built-in", "built in", "internal", "imac", "microphone array", "realtek")`; avoid `("background music", "ui sounds", "blackhole", "soundflower", "loopback", "aggregate", "multi-output", "airbeam", "recorder", "virtual")`; score 100/50, +10 if "microphone". Re-resolved by name on every open | |
| `Hud` + overlay | J:5325-5438 | JS bridge `jarvisState(s,text)`, `jarvisCaption`, `jarvisHide`. Overlay on the main thread: activation policy 1 (Accessory), `ignoresMouseEvents`, `NSScreenSaverWindowLevel`, clear and non-opaque, no shadow, `hidesOnDeactivate` off, `canHide` off, CanJoinAllSpaces\|Stationary\|FullScreenAuxiliary, `orderFrontRegardless`, plus the lock observer | `_install_lock_observer` belongs to M14; it is only called from here |
| `hud.html` | `~/jarvis/hud.html:1-94` | 190 px reactor: ring r1 (2 px, top cyan, spins 7 s), r2 (inset 16, dashed, 13 s reverse), r3 (inset 34, bottom gold, 9 s), r4 (inset 50, static), a ticks conic ring (inset 6, 40 s), and a core (inset 66, radial gradient, `breathe` 3.4 s; 1.1 s while thinking; gold gradient while speaking). 22 bars (2 px wide, 3–23 px tall, centre-weighted random). A status pill (letter-spacing .4em, 11 px, uppercase). A caption (max-width 330, 14 px). Labels: idle "J.A.R.V.I.S", listening "Listening", thinking "Processing", speaking "Speaking". Bar level .6 for listening/speaking, .35 for thinking, 0 otherwise. Idle hides after 2600 ms. Show and hide transition .45 s (scale .8→1, translateY 8→0, opacity) | colours `--cyan:#5fdcff; --cyan-dim:#1b6e85; --gold:#ffcf6b;` |
| `run_assistant` | J:5441-5708 | See the state machine in §3.6. Key order: `wait_for_wake_word` → False → reopen the mic. Wake clip → `speaker_ok(clip, WAKE_SPK_THRESHOLD)` → reject → `research_bump("wake_rejected_foreign_voice")`, silent. Otherwise `chime("Tink")`, HUD listening. Soft → pre-extracted command; hard → `listen_sentence(timeout=2.5)`. Empty → "Yes, sir?" then `listen_sentence(CONV_TIMEOUT)`. Enrol check → `speaker_ok(audio)` → `set_tone` → shazam → dismiss or `handle_one`. Conversation loop until timeout/dismiss ("Always a pleasure, sir."); `personality_distill_async()` | `is_dismiss` J:5591-5596 |
| `handle_one` | J:5548-5589 | `_consume_pending` first, then clears `_barge_in_triggered`, `chime("Tink")`, HUD thinking + caption(command), fast path (a tuple means speak and act in parallel, join 8 s), else `process_command` streams speech itself | |
| Ollama speech consumer | J:4785-4812 | A queue consumer drops the remaining sentences once `_barge_in_triggered` is set | |
| Claude `emit` | J:4948-4967 | Calls `speak(s)` for every sentence without checking `_barge_in_triggered` | a Python bug; see §8 R9 |

### 2.3 Libraries (site-packages)

| Item | File:lines | Behaviour | Notes |
|---|---|---|---|
| `preprocess_wav` | SP/resemblyzer/audio.py:13-39 | resample (a no-op at 16k→16k; librosa `if orig_sr == target_sr:` at SP/librosa/core/audio.py:630) → `normalize_volume(wav, -30, increase_only=True)` → `trim_long_silences` | |
| `wav_to_mel_spectrogram` | audio.py:42-54 | `librosa.feature.melspectrogram(y, sr=16000, n_fft=400, hop_length=160, n_mels=40)`, defaults: hann (periodic), `center=True`, `pad_mode="constant"`, `power=2.0`, Slaney mel with norm. Not log. Transposed → (frames, 40) float32 | defaults verified at SP/librosa/feature/spectral.py:2013-2025, filters.py:128-137 |
| `trim_long_silences` | audio.py:57-97 | 30 ms windows (480 samples), trims the tail to a multiple; `np.round(wav*32767)` → int16; `webrtcvad.Vad(mode=3)`; moving average width 8; round; `binary_dilation(ones(7))`; repeat ×480; mask | `binary_dilation` is imported from `scipy.ndimage.morphology`, a deprecated alias |
| `normalize_volume` | audio.py:100-108 | `rms = sqrt(mean((wav*32767)2))`, dBFS change, increase only | |
| hparams | SP/resemblyzer/hparams.py:1-33 | `mel_window_length = 25`, `mel_window_step = 10`, `mel_n_channels = 40`, `sampling_rate = 16000`, `partials_n_frames = 160`, `vad_window_length = 30`, `vad_moving_average_width = 8`, `vad_max_silence_length = 6`, `audio_norm_target_dBFS = -30`, `model_hidden_size = 256`, `model_embedding_size = 256`, `model_num_layers = 3` | |
| `VoiceEncoder` | SP/resemblyzer/voice_encoder.py:11-64 | `nn.LSTM(40, 256, 3, batch_first=True)` → `hidden[-1]` → Linear(256,256) → ReLU → L2 normalise. Weights from `pretrained.pt` (17,090,379 bytes, loaded with `strict=False`) | |
| `compute_partial_slices` / `embed_utterance` | voice_encoder.py:66-164 | `rate=1.3, min_coverage=0.75`. `samples_per_frame=160`, `n_frames=ceil((n+1)/160)`, `frame_step=round((16000/1.3)/160)` = 77, `steps=max(1, n_frames-160+77+1)`. Drops the last slice if coverage < 0.75 and there is more than one slice. Zero-pads the wav to the last stop. Mean of partial embeddings, then L2 normalise | |
| `AudioFeatures` | SP/openwakeword/utils.py:160-452 | raw buffer, `melspectrogram_buffer = np.ones((76, 32))`, `melspectrogram_max_len = 10*97`, `feature_buffer_max_len = 120`. `reset()` re-seeds `feature_buffer` with embeddings of `np.random.randint(-1000, 1000, 16000*4)`, unseeded (utils.py:172-178). `melspec_transform = x/10 + 2`. Embedding windows are 76 rows, step 8 | |
| `Model.predict` | SP/openwakeword/model.py:232-386 | For 1280-sample input: `get_features(16)` → classifier. The first 5 predictions after reset are forced to 0.0 (`len(self.prediction_buffer[cls]) < 5`, model.py:332) | |
| ORT session options | model.py:149-154, utils.py:79-85 | `inter_op_num_threads = 1`, `intra_op_num_threads = 1`, `CPUExecutionProvider` | the prototype matches (1/1, `ORT_ENABLE_ALL`) |
| `Recognizer` defaults | SP/speech_recognition/__init__.py:325-333 | `energy_threshold = 300`, `dynamic_energy_adjustment_damping = 0.15`, `dynamic_energy_ratio = 1.5`, `phrase_threshold = 0.3`, `non_speaking_duration = 0.5` | |
| `adjust_for_ambient_noise` | __init__.py:368-393 | EMA `thr = thr*damping + energy*1.5*(1-damping)` with `damping = 0.15  seconds_per_buffer` | |
| `_listen` | __init__.py:466-570 | Energy endpointer: `pause_buffer_count = ceil(pause/spb)`, `phrase_buffer_count = ceil(0.3/spb)`, `non_speaking_buffer_count = ceil(0.5/spb)`. With spb = 1280/16000 = 0.08 these are 12 / 4 / 7. `audioop.rms` truncates to int. Dynamic threshold is updated only on non-trigger buffers | the Mic in J:5497-5504 uses `chunk_size=OWW_FRAME_SAMPLES` |
| `PiperVoice.synthesize` | SP/piper/voice.py:269-320, 423-490 | phonemize (espeak, grouped by sentence) → ids (`^`, `_` after each, `$`) → ORT `input`, `input_lengths`, `scales=[noise_scale, length_scale, noise_w]` → normalise to peak (`normalize_audio=True` default) → clip → int16 via ×32767 | the VITS graph samples noise internally, so output is non-deterministic unless noise_scale = noise_w = 0 |
| `EspeakPhonemizer.phonemize` | SP/piper/phonemize_espeak.py:1-53 | `espeakbridge.set_voice(voice)`, `get_phonemes(text)` → (phonemes, terminator, eos). Strips `\([^)]+\)`, appends the terminator, adds a space after `,:;`, NFD-decomposes into codepoints, splits on eos | `espeakbridge.so` exports the espeak-ng C API (§3.2) |
## 3. Swift design

### 3.1 Targets and files (added to `native/Package.swift` by T0.1)

| Target | Kind | Contents |
|---|---|---|
| `COnnxRuntime` | `.systemLibrary`, path `Sources/COnnxRuntime` | Copied from `~/jarvis-swift/Sources/COnnxRuntime/include` (module map + the 1.26.0 headers). Reuse as-is. Links `onnxruntime.1`. The dylib is `native/Resources/vendor/libonnxruntime.1.26.0.dylib`, copied from `~/jarvis-swift/Resources/`, arm64 only, `@rpath/libonnxruntime.1.dylib` |
| `CPyStubs` | C target | `pystubs.c` defines the 5 data symbols that the two Python extension modules bind non-lazily: `PyExc_ValueError`, `PyExc_RuntimeError`, `_Py_NoneStruct`, `_Py_TrueStruct`, `_Py_FalseStruct` (from `dyld_info -fixups`: webrtcvad needs ValueError/None/True/False, espeakbridge needs RuntimeError/None/True/False). Built as `.dynamic` product `libpystubs.dylib` and `dlopen`ed `RTLD_GLOBAL` first. No `Py*` function is ever called |
| `JarvisVoice` | Swift, depends on `JarvisCore`, `COnnxRuntime`, `CPyStubs` | Everything below except the HUD. Frameworks: AVFAudio, AVFoundation, Speech, Accelerate, CoreAudio, AudioToolbox, Security, Network |
| `JarvisApp` | executable | `HUD/*`, `VoiceLoop/AssistantLoop.swift` wiring |
| `JarvisVoiceTests` | test | golden tests; fixtures under `Tests/Fixtures/golden/voice/` via `#filePath` |

Vendored binaries live in `native/Resources/vendor/` (gitignored). `scripts/vendor-voice-assets.sh` fills it
from site-packages and `~/jarvis-swift`, and `scripts/build-app.sh` copies them into
`JARVIS.app/Contents/{Frameworks,Resources}` and re-signs each `.so`/`.dylib` with the app identity,
which library validation requires. Contents: ORT dylib, `_webrtcvad.cpython-314-darwin.so`,
`piper/espeakbridge.so`, `piper/espeak-ng-data/` (19 MB), the 3 oww models (md5-identical to
openwakeword 0.6.0's), `resemblyzer.onnx` (exported in T10.0). The Piper voice is read in place from
`~/jarvis/voices/` (shared state, never copied).

```
Sources/JarvisVoice/
  Audio/AudioHub.swift          actor-owned AVAudioEngine: VP, players, tap, rebinding
  Audio/MicPipeline.swift       16 kHz Int16 1280-frame broadcaster (adapted from jarvis-swift Mic.swift)
  Audio/DeviceSelector.swift    prefer/avoid lists (J:5284-5321) over CoreAudio devices
  Audio/Chime.swift             Tink/Glass/Funk via AudioHub.fxPlayer
  ORT/OrtSession.swift          adapted from WakeWord.swift:26-167 (Ort, OrtInferenceSession)
  Speech/SpeechEngine.swift     protocol + EngineID + FallbackReason
  Speech/ElevenLabsEngine.swift
  Speech/PiperEngine.swift      VITS on ORT
  Speech/EspeakPhonemizer.swift dlopen espeakbridge.so
  Speech/SayEngine.swift        `say -o` → AIFF → fxPlayer
  Speech/SpeechQueue.swift      sentence queue, routing, prefetch, barge-in cancel
  Speech/SpeechRouting.swift    USER DECISION: speakLocally(reply:turn:)
  Speech/KeychainSecret.swift
  Speech/TextClean.swift        the speak() strip regex (J:726-727)
  Listen/EnergyEndpointer.swift port of sr.Recognizer._listen / adjust_for_ambient_noise / record
  Listen/Transcriber.swift      SpeechAnalyzer + SpeechTranscriber
  Listen/Vocabulary.swift       contextualStrings from WHISPER_PROMPT/profile/corrections
  Listen/SentenceListener.swift listen_sentence port
  Listen/ToneAnalyzer.swift     analyze_tone / set_tone port
  Speaker/WebRTCVAD.swift       dlopen _webrtcvad .so
  Speaker/ResemblyzerPreprocess.swift  normalize_volume, trim_long_silences, mel (Slaney, DFT-400)
  Speaker/SpeakerEncoder.swift  ORT resemblyzer.onnx, partial slicing, embed
  Speaker/Voiceprint.swift      NPY v1.0 read/write, cosine, speakerOK
  Wake/WakeWordDetector.swift   adapted from jarvis-swift WakeWord.swift:169-305 (+reset)
  Wake/WakeWatcher.swift        wait_for_wake_word port (ring 25, soft tier, dead stream)
  Wake/WakePhrases.swift        _WAKE_RE, extract_command, is_dismiss, _is_enroll (pure; JarvisCore if M7 already owns them)
  Loop/BargeIn.swift
  Loop/ConversationLoop.swift   run_assistant state machine (headless, HUD via protocol)
Sources/JarvisApp/HUD/HUDPanel.swift, HUDView.swift, HUDController.swift
```

Salvage verdicts (`~/jarvis-swift`, read-only):

| File | Verdict |
|---|---|
| `Sources/COnnxRuntime/*`, `libonnxruntime.1.26.0.dylib`, `Resources/models/*.onnx` | reuse as-is |
| `WakeWord.swift` | adapt. The pipeline is a faithful port with the same 1/1 threads and `ORT_ENABLE_ALL` as Python. Add `reset()`, replace `fatalError` with a thrown error and counter, make it a non-Sendable class owned by `WakeActor` (Swift 6), add an injectable seed-noise provider for tests |
| `Mic.swift` | adapt. Keep the tap → `AVAudioConverter` → 1280 slicer. Add VP, broadcast via `AsyncStream`, configuration-change rebinding, and remove the `NSLock` + closure sinks, which are not Sendable |
| `Speech.swift` (SFSpeechRecognizer) | superseded; rewrite on SpeechAnalyzer |
| `Voice.swift` (AVSpeechSynthesizer) | superseded; not used |
| `HUD.swift` | adapt the window setup only (borderless, clear, ignoresMouseEvents, collection behaviour), switching to `NSPanel` + `.nonactivatingPanel`, `.screenSaver` level, 360×430 at (28, 48). Rewrite the visuals from `hud.html` |
| `Assistant.swift` | rewrite. `extractCommand` diverges from J:5113-5131; everything is re-derived from golden |

### 3.2 M8 — Voice out

```swift
public enum EngineID: String, Sendable { case elevenlabs, piper, say }
public enum FallbackReason: String, Sendable {       // → counter "tts_fallback_<raw>"
  case offline, auth /*401*/, quota /*402 or quota_exceeded body*/, rateLimited /*429*/ = "rate_limited",
       timeout, http /*other 4xx/5xx*/, network, sensitive, noKey = "no_key", disabled, error }
public struct PCMChunk: Sendable { public let samples: [Float]; public let sampleRate: Double }   // mono
public protocol SpeechEngine: Actor {
  var id: EngineID { get }
  /// Streams audio for ONE sentence. Throws SpeechEngineError(reason:) before the first chunk
  /// → caller falls back; after the first chunk, errors end the sentence (no mid-sentence switch).
  func synthesize(_ sentence: String, context: SynthesisContext) -> AsyncThrowingStream<PCMChunk, Error>
  func release() async                                  // drop models/sessions (idle)
}
public struct SynthesisContext: Sendable { let turnID: UUID; let previousRequestIDs: [String] }
```

ElevenLabsEngine. The endpoint and field names come from ElevenLabs' public docs. None of
this was verified against the live API here. T8.2 confirms it with one real request.
- `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream?output_format=pcm_22050`
  with headers `xi-api-key: <keychain>` and `Content-Type: application/json`. Body:
  `{"text": s, "model_id": modelID, "voice_settings": {"stability":0.5,"similarity_boost":0.75,"style":0.0,"use_speaker_boost":true}, "previous_request_ids": [...≤3]}`.
  The response is raw s16le mono at 22050 Hz, the same rate as Piper, so one player format
  serves both. `previous_request_ids` comes from the `request-id` response header of the
  previous sentences in the same turn, which keeps prosody continuous (header name unverified).
- Transport: `URLSession(configuration: .ephemeral)` with `timeoutIntervalForRequest = 3`,
  `httpShouldSetCookies=false` and no URL cache. `session.bytes(for:)` is read in 4410-byte
  (100 ms) blocks → `PCMChunk`.
- Latency budget: sentence ready → first audio p50 ≤ 600 ms. Hard TTFB deadline 1.5 s
  (a racing `Task.sleep`), then `timeout` fallback. A stall of more than 2 s between chunks
  ends the sentence.
- Circuit breaker, per process:
  - 401 → `auth`, disabled until restart or until a new key is saved.
  - 402, or a body containing `quota_exceeded` → `quota`, disabled until the
    `next_character_count_reset_unix` from `GET /v1/user/subscription` (field names unverified).
  - 429 → `rate_limited`, 60 s cool-off.
  - timeout or network error → 30 s cool-off.
  - `NWPathMonitor` unsatisfied → `offline`, and no request is attempted.
- Streaming: one request per sentence, keeping `pop_sentences`. Prefetch is at most one
  sentence ahead, whatever the engine. The WebSocket `stream-input` API is deliberately not
  used: it needs no extra latency win at a sentence granularity and complicates fallback.
- Config (not secret): `UserDefaults(suiteName: "com.jarvis.assistant")` keys
  `ElevenLabsVoiceID` (no default; empty → `disabled`) and `ElevenLabsModelID` (default
  `eleven_flash_v2_5`). Proposed env overrides `JARVIS_EL_VOICE`, `JARVIS_EL_MODEL`, and
  `JARVIS_TTS=piper` (forces local). These are new env vars, flagged for the planner (§8).
- Key: `KeychainSecret(service: "com.jarvis.assistant.elevenlabs", account: "api-key")`,
  `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. It is written
  by the app itself (`JARVIS --set-elevenlabs-key` reads stdin with echo off), so the item's
  ACL is the signed app and there is no keychain prompt. It never appears in logs (the logger
  redacts `xi-api-key`), in files, in env, or in `Process.environment`. `SayEngine` passes an
  explicit minimal env.
- Quota tracking: `Research.bump("tts_elevenlabs_chars", by: cleaned.count)` when the first
  audio byte of a sentence arrives. `GET /v1/user/subscription` is fetched at most once a day
  and its `character_count`/`character_limit` are logged only.

PiperEngine (native). Routes evaluated, measured facts from the orchestrator 2026-09-28
plus the checks here:

| Route | RAM while loaded | Cold start | Parity with Python | Install needed | Verdict |
|---|---|---|---|---|---|
| (a) persistent Python helper (`piper` package), killed after idle | ~356 MB peak (measured) | 1.32 s load (measured) | exact | none | last resort: keeps Python at runtime and spikes RAM exactly when offline |
| (b1) VITS ONNX on ORT + dlopen `espeakbridge.so` | est. 100–180 MB (63 MB weights + ORT arena), to measure | est. < 1 s | phonemes exact by construction (the same compiled espeak-ng as the oracle); audio exact when noise = 0 | none | recommended |
| (b2) VITS on ORT + Homebrew `espeak-ng` | same as b1 | same | phonemes may differ (a different espeak build) | `brew install espeak-ng`, only with explicit user approval | fallback if b1's dlopen fails |

Checked here (read-only): `espeakbridge.so` is arm64, links only `libSystem`, and exports
`espeak_Initialize`, `espeak_ng_InitializePath`, `espeak_SetVoiceByName`,
`espeak_TextToPhonemesWithTerminator`, `espeak_ng_Terminate`. Its non-lazy binds are only
`_PyExc_RuntimeError`, `__Py_FalseStruct`, `__Py_NoneStruct` and `__Py_TrueStruct`. The
`Py*` functions are lazy and never called. The design:
- `EspeakPhonemizer` actor (espeak is not thread-safe): `espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, dataDir, 0)`,
  `espeak_SetVoiceByName("en-gb-x-rp")`, then loops `espeak_TextToPhonemesWithTerminator(&ptr, espeakCHARS_AUTO, mode, &term)`.
  The `mode` value and the `term` → (terminator char, end_of_sentence) mapping are
  derived in T8.3 from golden data (raw `term` ints logged natively against Python's
  tuples), never typed from memory.
- Then the `phonemize_espeak.py` post-processing: strip `\([^)]+\)`, append the terminator,
  add a space after `,:;`, NFD, split on eos. Then `phonemes_to_ids` with the voice JSON's
  `phoneme_id_map`: `^`, then `_` after each phoneme, then `$`; a missing phoneme is logged
  and skipped.
- ORT inputs: `input` int64 [1,N], `input_lengths` [N], `scales` f32 `[0.667, PIPER_LENGTH, 0.8]`,
  and no `sid` (num_speakers 1). Output → peak-normalise → clip → `PCMChunk` at 22050 Hz.
  One sentence per call (Piper already splits by sentence).
- Idle release: the ORT session and espeak state are released after `JARVIS_PIPER_IDLE_S`
  (proposal, default 120 s) with no Piper use. Loading is lazy on first need. It is pre-warmed
  when `NWPathMonitor` goes offline or when ElevenLabs is disabled.

SayEngine (last resort, J:774-788 parity): `/usr/bin/say -v Daniel -r 200 -o <tmp>.aiff -- <text>`
→ `AVAudioFile` → fxPlayer. Rendering to a file keeps the exact voice and rate while letting AEC
see the audio.

Pitch/tempo. `JARVIS_SPEED` → Piper `length_scale` only (as in Python). `JARVIS_PITCH` →
`AVAudioUnitTimePitch.pitch = 1200 * log2(VOICE_PITCH)` cents (0.92 → −144.353 cents),
`rate = 1.0`, on the Piper chain only. Python pitched Piper and never `say`, and the
ElevenLabs voice is designed with the intended timbre, so pitching it degrades quality.
Proposal `JARVIS_EL_PITCH` (default 1.0) exists only if the user wants it. The algorithm
differs from ffmpeg `asetrate+atempo`, so parity is duration ±1 % plus a measured f0 ratio of
0.92 ± 0.02, not samples (§4).

SpeechQueue (actor; the only way anything speaks):
```swift
public actor SpeechQueue {
  func begin(turn: TurnContext)                        // new turn: clears bargedIn, stickiness
  func enqueue(_ sentence: String)                     // from pop_sentences output, in order
  func say(_ text: String, turn: TurnContext) async    // one-shot (greetings, "Yes, sir?")
  func finish() async                                  // wait until drained
  func cancelAll(reason: CancelReason)                 // barge-in / shutdown
  var events: AsyncStream<SpeechEvent>                 // .sentenceStarted(text) → HUD caption; .idle
}
```
Per sentence:
1. `TextClean` (J:726-727 regexes; empty → skip).
2. Engine choice: `JARVIS_TTS=piper` → piper. Otherwise, if
   `speakLocally(reply: sentence, turn: turn)` → piper (`tts_fallback_sensitive`). Otherwise, if
   the turn is already sticky-Piper → piper. Otherwise elevenlabs.
3. On a pre-first-chunk failure → Piper, bump `tts_fallback_<reason>`, and mark the turn
   sticky, so the voice does not change back and forth inside one reply.
4. A Piper failure → `say`.
5. Bump `tts_elevenlabs` or `tts_piper` once per sentence spoken.

The ordering and content of sentences never change. Only prefetch (one ahead) is new.

**USER DECISION POINT — `Speech/SpeechRouting.swift`:**
```swift
// ┌───────────────────────── USER DECISION ─────────────────────────┐
// Return true to speak this reply with local Piper (content never leaves the Mac).
// turn.dataSourcesTouched is provided by W4 (M2–M4 TurnContext): e.g. .messages,
// .calendar, .file, .clipboard, .screen, .email, .contacts, .notes, .location.
// Evaluated per sentence at emission time; once true in a turn, the queue keeps Piper.
public func speakLocally(reply: String, turn: TurnContext) -> Bool {
    return true   // USER DECISION (D-17): replace with your rule — see §3.2 trade-offs
}
// └─────────────────────────────────────────────────────────────────┘
```
Trade-offs the user weighs:
- Any personal source → local. Strongest privacy. The voice switches mid-conversation, and
  some harmless replies ("You have no new messages") go local.
- An allow-list of sources (e.g. calendar is fine, messages/email/files/screen are not).
  Fewer switches, but the user carries the judgement.
- Content heuristics (names, numbers, quoted text). Leaky and unpredictable; not recommended.
- Never local (always ElevenLabs). Message bodies, calendar entries and file text are sent
  to ElevenLabs' servers.

The executor must not pick a policy. T8.6 ships the stub with the privacy-safe default
`return true` (D-17: every reply is spoken by local Piper, nothing leaves the Mac; it never
crashes) behind `JARVIS_TTS=piper` until the user fills it in, and the test harness injects
its own closure.

### 3.3 Audio graph (`AudioHub`, one engine for everything)

```
inputNode [VP on] ─tap(bus 0, inputFormat)→ AVAudioConverter → 16 kHz mono Int16 → 1280 slicer → MicPipeline.broadcast
piperPlayer (22050 mono f32) → timePitch (AVAudioUnitTimePitch) ┐
cloudPlayer (22050 mono f32) ───────────────────────────────────┼→ mainMixerNode → outputNode [VP]
fxPlayer   (chimes / say AIFF, file format) ────────────────────┘
```
- Setup, with the engine stopped:
  - `try engine.inputNode.setVoiceProcessingEnabled(true)`. This also enables the output node.
  - `inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)`.
    The default ducking would permanently quieten the user's music while JARVIS is always on.
  - `inputNode.isVoiceProcessingAGCEnabled = false`, to keep levels close to the raw mic the
    thresholds were tuned on. Measured in T9.1.
  - Proposal `JARVIS_AEC=0` disables VP entirely; in that case barge-in behaves exactly like
    Python (fail-closed voice gate).
- Tap: `installTap(onBus: 0, bufferSize: 2048, format: inputNode.outputFormat(forBus: 0))`. The
  block runs on an engine-internal, non-render thread. It converts and appends to a
  preallocated ring, slices 1280-sample frames, and calls `continuation.yield(Frame)` for each
  subscriber (`AsyncStream`, `.bufferingNewest(64)`, ≈5 s). There is no locking or awaiting
  in the tap. `Frame: Sendable { samples: [Int16] /*1280*/, index: UInt64, hostTime: UInt64 }`.
- `AudioHub` is an `actor`. The engine and nodes are touched only from it. Player scheduling
  uses `scheduleBuffer(_:completionCallbackType: .dataPlayedBack)`, bridged to async.
- Barge-in and stop: `player.stop()` on every speech player (the fxPlayer keeps chimes).
- Rebinding:
  - `.AVAudioEngineConfigurationChange` → stop, re-apply VP settings, re-install the tap, start.
  - A CoreAudio `kAudioHardwarePropertyDefaultInputDevice` listener does the same.
  - `DeviceSelector` applies the prefer/avoid lists via `kAudioOutputUnitProperty_CurrentDevice`
    on `inputNode.audioUnit`. Whether this works with VP on is verified in T9.1; if not, it logs
    a warning when the default input is on the avoid list.
  - 250 consecutive all-zero frames → rebind (J:1121).
- The startup watchdog (J:5482-5485): a detached `Task` calls `exit(86)` if `MicPipeline`
  has not delivered a non-zero frame and the loop is not listening within 240 s.

### 3.4 M9 — Voice in

- `EnergyEndpointer` (a pure struct, golden-tested) ports `Recognizer` fields and
  `_listen`/`adjust_for_ambient_noise`/`record` (SP/speech_recognition/__init__.py:325-393,
  466-570, 335-366) for `CHUNK=1280`:
  - It keeps the same Double accumulation order for `elapsed_time`. `0.08` summed 25 times
    exceeds 2.0, so calibration reads 24 buffers, and `record(4)` keeps 49 buffers (3.92 s); golden pins both.
  - `rms` = `Int(sqrt(Double(sumSq)/Double(n)))`, truncating like `audioop.rms`.
  - `mutating func feed(_ frame: [Int16]) -> Event` with
    `Event = .waiting | .phraseStarted | .ended(clip: [Int16]) | .timedOut`.
  - `calibrate(frames:)`, then `energyThreshold = min(energyThreshold, 3000)`.
  - `pauseThreshold = SENT_PAUSE`.
- `Transcriber` (actor):
  - `SpeechTranscriber(locale: Locale(identifier: STT_LANG), transcriptionOptions: [], reportingOptions: [], attributeOptions: [.transcriptionConfidence, .audioTimeRange])`
  - `SpeechAnalyzer(modules: [t], options: .init(priority: .userInitiated, modelRetention: .lingering))`
  - `try await analyzer.setContext(ctx)`, with `ctx.contextualStrings[.general] = Vocabulary.current()`.
  - Audio format: `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])` and
    `prepareToAnalyze(in:)`.
  - An utterance session starts at `.phraseStarted` and pre-rolls the retained 7 buffers. It
    feeds `AnalyzerInput(buffer:)` live through an `AsyncStream` passed to
    `analyzer.start(inputSequence:)`. At `.ended` it finishes the stream, calls
    `finalizeAndFinishThroughEndOfInput()` and collects the final `results`.
  - Startup: `AssetInventory.status(forModules:)`; if not `.installed`,
    `assetInstallationRequest(supporting:)?.downloadAndInstall()` (en-GB is already installed
    here). `volatileResults` is off because only finals are used, as in Python.
- Hallucination-guard mapping. Per final result, `conf` = the `audioTimeRange`-duration
  weighted mean of the runs' `transcriptionConfidence`. If `conf < STT_MIN_CONF`, the result
  is dropped, logged like J:949-951, and bumps `stt_segments_dropped` (same key, once per
  dropped result). `STT_MIN_CONF` is calibrated in T9.4 (Whisper's `no_speech_prob > 0.6` /
  `avg_logprob < -1.2` have no numeric equivalent) and recorded in this file. Proposed env
  `JARVIS_STT_MIN_CONF`. The kept text is joined with " ", stripped, then `Corrections.apply`
  (the single choke point), then lowercased/stripped in `SentenceListener`.
- `Vocabulary`. Parses `WHISPER_PROMPT` (or the env) as the text after the last
  `"Vocabulary:"`, split on `,`, trimmed of spaces and a trailing `.`. For the default this
  gives 14 strings: `Jarvis … that's all Jarvis`. It then appends the profile name and the
  last 12 correction `meant` values, de-duplicated in order (J:915-931). If the env prompt has
  no `Vocabulary:`, the whole string is one entry.
- `SentenceListener.listen(timeout:) async throws -> (text, clip)` ports J:990-1004
  (continuation with `timeout: 2.2`, `_INCOMPLETE_TAIL_RE` verbatim, first clip returned).
- `ToneAnalyzer.analyze(_ samples: [Int16], text: String) -> String` ports J:1006-1048 in
  Float32 with vDSP. `argsort` is stable descending by rms; top 10.
  `setTone` → `Research.bump("tone_" + desc-before-comma with \W+→_)`, and "hurried" →
  `Emotions.event("user_urgent")`. `toneContext()` has the same text and a 90 s expiry (J:1060-1066).

### 3.5 M10 — Speaker verification

- Export (T10.0, Python, one-off): `native/tools/export_resemblyzer.py` loads `VoiceEncoder("cpu")` and wraps
  `forward` (LSTM → `hidden[-1]` → linear → relu → L2). It runs
  `torch.onnx.export(m, torch.zeros(1,160,40), "resemblyzer.onnx", dynamo=False, opset_version=17, input_names=["mels"], output_names=["embeds"], dynamic_axes={"mels":{0:"B"},"embeds":{0:"B"}})`.
  - torch 2.12's legacy exporter unconditionally calls `onnx_proto_utils._add_onnxscript_fn`,
    which does `import onnx` and raises `OnnxExporterError("Module onnx is not installed!")`
    (SP/torch/onnx/_internal/torchscript_exporter/utils.py:1588 and onnx_proto_utils.py:177-185).
    That function only inlines onnxscript custom functions, of which this model has none.
    The script therefore monkeypatches
    `torch.onnx._internal.torchscript_exporter.onnx_proto_utils._add_onnxscript_fn = lambda b, c: b`
    before exporting. No package install.
  - Verification uses the installed `onnxruntime` 1.26.0 on the same mels.
- `WebRTCVAD`: `dlopen(libpystubs, RTLD_GLOBAL)`, then `dlopen(_webrtcvad…so, RTLD_NOW)`.
  `dlsym`: `int WebRtcVad_Create(VadInst)` (the out-pointer form, confirmed by disassembly:
  `cbz x0; malloc(0x2e0); str x0,[x19]`), `WebRtcVad_Init`, `WebRtcVad_set_mode`,
  `WebRtcVad_Process(VadInst*, int fs, const int16_t*, size_t len) -> Int32` (1/0/-1), and
  `WebRtcVad_Free`. The `Process` length type and return are verified by golden flags in T10.1.
- `ResemblyzerPreprocess`:
  - `normalizeVolume(-30, increaseOnly)` in Double.
  - `trimLongSilences`, a line-for-line port of audio.py:57-97: `np.round` is half-to-even
    (use `.toNearestOrEven`); the moving average uses cumsum in Double; and `binary_dilation`
    with `ones(7)` is centred, which is equivalent to a ±3 window OR (golden-pinned).
  - `melSpectrogram` pads 200 zeros each side (center, constant) and uses a periodic Hann of
    400. n_fft=400 = 25·16 is not a size vDSP DFT supports, so it uses a precomputed
    201×400 cos/sin matrix and `vDSP_mmulD` → power → a Slaney mel filterbank (40×201,
    computed natively in Double and golden-checked) → Float32 (frames, 40).
- `SpeakerEncoder` (actor, lazy ORT session, released after 300 s idle except while a
  conversation is open): `computePartialSlices(n, rate: 1.3, minCoverage: 0.75)` is a verbatim
  port (Python `round` = half-to-even on `76.923…` → 77). It pads, batches all partials in one
  `[B,160,40]` run, means them, and L2-normalises. `embed(_ samples: [Int16]) -> [Float]?`
  replicates `_embed` (under 9600 samples → nil; under 6400 after trimming → nil).
- `Voiceprint`:
  - `load()` parses NPY v1.0: magic, header length, and requires `'<f4'`, non-Fortran,
    `(256,)`.
  - `save(_:)` writes byte-identical `np.save` output: a 128-byte header padded with spaces
    and ending `\n`. The write is atomic (temp + rename).
  - `cosine(a,b)` uses `+ 1e-9`.
  - `speakerOK(clip, threshold)` fails open, exactly as J:5180-5198, with the
    `speaker_pass`/`speaker_reject` counters.
  - `matchesForBargeIn(clip)` fails closed.
  - `enroll()` and `forget()` port J:5208-5249, using `EnergyEndpointer.record(seconds: 4)`
    ×3, keeping a segment only if > 12800 samples after preprocessing.

### 3.6 M11 + M12 — Wake word and conversation loop

- `WakeWordDetector.process(frame) -> Float`: salvaged, plus `reset()`. `reset` is
  `melBuffer = ones(76×32)`, re-seeds the feature buffer from `NoiseSource` (production uses
  `Int16.random(in: -1000...999)`, tests inject Python's exact noise array from the fixture),
  and zeroes `framesSeen`. The first 5 scores are 0.
- `WakeWatcher.wait(frames:, allowSoft:) async -> WakeResult`, with
  `enum WakeResult { case hard(clip: [Int16]); case soft(text: String, clip: [Int16]); case deadStream }`.
  Per J:1087-1142: a ring of 25, the all-zero counter at 250, hard at ≥ `WAKE_THRESHOLD`.
  Soft tier: `WAKE_SOFT > 0 && score ≥ WAKE_SOFT && now - lastSoft > 3.0` → take 20 more
  frames → `Transcriber.transcribe(clip)` → `Corrections.apply` → lower/strip →
  `WakePhrases.containsWakeWord`, else `reset()`.
- `ConversationLoop` (actor in JarvisVoice; the HUD is injected as `HUDSink` protocol):
```
boot: mic access (AVCaptureDevice.requestAccess(for: .audio), ≤150 s, speaks once) → Voiceprint.load
      → pre-warm SpeakerEncoder if enrolled → mic verify (≤12 × 1 s record, 1.5 s apart, "Awaiting
      microphone access, sir." once) → calibrate 2 s, cap 3000 → warm wake model → greet
      "JARVIS online and running locally. {Good morning|afternoon|evening}, sir." (hour <12, <17)
      → hud.idle → watchdog.stand down
standby: WakeWatcher → .deadStream → AudioHub.rebind, continue
      → clip → Voiceprint.speakerOK(clip, WAKE_SPK_THRESHOLD) false → bump wake_rejected_foreign_voice, continue (NO chime/HUD)
      → Chime.tink; hud.listening
      → soft: text = heard, pre = extract if contains; if pre empty text = ""
        hard: SentenceListener.listen(timeout: 2.5) (timeout → "")
      → text empty: hud.listening; say "Yes, sir?"; listen(CONV_TIMEOUT) (timeout/empty → hud.idle, standby)
      → command = extract if contains else text
      → isEnroll → Voiceprint.enroll → standby | !speakerOK(audio) → standby
      → ToneAnalyzer.setTone | isShazam → M6 hook | !isDismiss → handleOne else say "Yes, sir?"
conversation: loop { hud.listening; listen(CONV_TIMEOUT) timeout → hud.idle, caption "", break
      empty → continue; !speakerOK → continue; setTone; enroll → break; shazam → hook, continue
      dismiss → say "Always a pleasure, sir."; hud.idle; break; else handleOne(extract-or-reply) }
      → Personality.distillAsync()
handleOne: ConfirmationGate.consumePending → speak; else SpeechQueue.begin(turn); chime Tink; hud.thinking
      + caption(command); FastPath tuple → act ∥ speak, join 8 s | string → speak | nil → Brain stream
      → pop_sentences → SpeechQueue.enqueue; remember last reply unless "Copied to your clipboard"
```
- `BargeIn` runs only while `SpeechQueue` is playing and only if `BARGE_IN_ENABLED`, a
  voiceprint and the mic all exist. It subscribes to frames. A frame counts as voiced if any
  of its 4 × 320-sample subframes gets `WebRtcVad_Process == 1` in mode 3. A run of 10 voiced
  frames → `Voiceprint.matchesForBargeIn(buf)` → `SpeechQueue.cancelAll(.bargeIn)` (stops
  players, drops queued sentences for both backends; see §8 R9), `Emotions.event("barge_in")`,
  and the turn is marked interrupted. A mismatch resets the run. The barge-in audio is not
  replayed into the next listen (Python parity). AEC is expected to cut self-triggering; the
  voice gate stays for parity.

### 3.7 M13 — HUD (`JarvisApp/HUD`)

- `HUDPanel: NSPanel` with `styleMask [.borderless, .nonactivatingPanel]`, `isOpaque=false`,
  `backgroundColor=.clear`, `hasShadow=false`, `level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))`,
  `ignoresMouseEvents=true`, `hidesOnDeactivate=false`, `canHide=false` (subclass override),
  `collectionBehavior [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`,
  `becomesKeyOnlyIfNeeded=true`, `canBecomeKey/Main=false`. The frame is 360×430 at
  `(screen.frame.minX + 28, screen.frame.minY + 48)` on `NSScreen.main` (pywebview used the
  full frame, not the visible frame).
- `NSApp.setActivationPolicy(.accessory)` at launch on the main thread. `JARVIS_NO_HUD=1` →
  no panel. Every call is `@MainActor`.
- `HUDController: @MainActor, HUDSink` provides `state(_ s: HUDState, text: String = "")`,
  `caption(_:)`, `hide()` and `level(_:)`, mirroring `jarvisState/Caption/Hide/Level`. Idle
  starts a 2.6 s hide timer, cancelled by any state call.
- `HUDView` (SwiftUI, `TimelineView(.animation)`, paused when hidden, so it costs no CPU idle):
  - 190 pt reactor: r1–r4, ticks, core, colours and periods as in §2.2.
  - Core `breathe` scale 0.93↔1.06 and opacity 0.9↔1, over 3.4 s, or 1.1 s while thinking.
  - The speaking core is a gold radial gradient.
  - 22 bars with height `3 + level·20·c·(0.5+rand)`, where `c` is the centre weight, and gold
    while speaking.
  - Status pill and caption use `.ultraThinMaterial`-like `NSVisualEffectView` backgrounds.
  - Show/hide: 0.45 s, scale 0.8→1, y 8→0, opacity.
  - Captions come from `SpeechEvent.sentenceStarted`, as in Python's `hud.caption(s)` before each `speak`.
## 4. Golden vectors

Corpus (no mic, never the user's voice). T0.2 creates `native/tools/make_voice_corpus.py`,
which writes `Tests/Fixtures/golden/voice/corpus/*.wav` (16 kHz mono s16le) and `manifest.json`.
The WAVs are synthetic and committed; the manifest records the macOS build and each `say`
voice, because output may change across OS updates.

| Group | How | Count |
|---|---|---|
| speech | `say -v <V> -r <R> --file-format=WAVE --data-format=LEI16@16000 -o f.wav "<text>"`. Voices are chosen at run time from `say -v '?'` en_GB/en_US entries, ≥ 4 distinct voices. Texts: 20 commands from the fast-path corpus, 5 long (8–12 s, for partial slicing), 5 with 1.5 s pauses (trim/endpointer) | 40 |
| wake | "Hey Jarvis", "Jarvis", "Hey Jarvis, what's the time", "Jarvis. Close Safari" × voices × rates 160/200/240. The generator keeps searching until the manifest holds ≥ 3 clips with Python score ≥ 0.5 and ≥ 3 with max in [0.15, 0.5), and fails loudly if it cannot | ≥ 12 |
| negatives | "Hey Travis", "Java's great", "the weather tomorrow" | 6 |
| non-speech | digital silence 5 s; seeded white noise (`np.random.default_rng(7)`) at −40/−25 dBFS; a pink-ish noise 10 s; chord tones 220/277/330 Hz 5 s; a speech + noise mix at 10 dB SNR | 6 |
| barge-in | a Piper-synthesised sentence (the "JARVIS voice") with a `say` voice overlaid at t = 1.0 s | 3 |

Oracle. `native/tools/golden.py voice` (the M0 tool gains a `voice` subcommand). It runs
the real Python functions. It needs torch and piper; it runs once, offline, with Python
voice JARVIS stopped, and only when `memory_pressure` shows ≥ 1.5 GB free (it is
transient, about 1 GB). Arrays are written as `.npy`, which `Voiceprint`'s NPY reader parses,
and scalars as JSON.

| Pipeline | Python reference called | Fixture (`Tests/Fixtures/golden/voice/…`) | Tolerance |
|---|---|---|---|
| Wake phrases | `contains_wake_word`, `extract_command`, `is_dismiss` (lifted from `run_assistant` source by AST, not retyped), `_is_enroll`, `_INCOMPLETE_TAIL_RE.search` on 150 strings | `phrases.json` | exact |
| Text clean / sentences | `speak()`'s two `re.sub`, `pop_sentences(buf, force)` on 60 streamed buffers | `textclean.json`, `pop_sentences.json` | exact |
| Vocabulary | `_whisper_prompt()` with a fixture profile + corrections; also the prompt string | `vocabulary.json` | exact (the parse into list entries is a spec, not oracle-derived; flagged §8) |
| openWakeWord mel | `AudioFeatures._get_melspectrogram` per 1760-sample window | `oww_mel_<clip>.npy` | max abs ≤ 1e-4 |
| openWakeWord scores | `Model.predict` per 1280 frame with `np.random.randint` wrapped to record the 64000-sample seed noise per reset | `oww_scores_<clip>.npy` + `oww_seed_<clip>_<k>.npy` | with injected seed: all frames \|Δ\| ≤ 1e-4 (same ORT 1.26.0, 1/1 threads); fire/no-fire at 0.5 and 0.15 identical |
| Wake watcher | `wait_for_wake_word` driven by a fake `source.stream` over the WAV; the soft-confirm transcriber is stubbed to return fixture text | `wake_watch.json` (return kind, frame index, clip length) | exact |
| WebRTC VAD | `webrtcvad.Vad(3).is_speech` on 30 ms and 20 ms frames | `vad30_<clip>.npy`, `vad20_<clip>.npy` (bool) | exact |
| Resemblyzer preprocess | `normalize_volume`, `trim_long_silences`, `preprocess_wav` | `rz_pre_<clip>.npy` | length exact; max abs ≤ 1e-6 |
| Mel filterbank | `librosa.filters.mel(sr=16000, n_fft=400, n_mels=40)` | `rz_melfb.npy` (40×201) | max abs ≤ 1e-7 |
| Resemblyzer mel | `wav_to_mel_spectrogram` | `rz_mel_<clip>.npy` | max abs ≤ 1e-4 × max(mel) |
| Partial slices | `compute_partial_slices(n, 1.3, 0.75)` for n ∈ {6400…200000, 500 values} + corpus | `rz_slices.json` | exact |
| ONNX export | torch `VoiceEncoder.forward` vs ORT on the same 32 random + corpus mels | `rz_onnx_io.npy` | \|Δ\| ≤ 1e-5 (the spike's go criterion) |
| Embedding | `_embed(AudioData)` end-to-end | `rz_embed_<clip>.npy` | cosine ≥ 0.999 (target ≥ 0.9999); None/non-None identical |
| Speaker decisions | `speaker_ok` against a synthetic voiceprint `vp_synth.npy` enrolled by Python `enroll_voice` logic from 3 Daniel clips | `spk.json` (sim, decision at 0.60/0.38) | sim \|Δ\| ≤ 1e-3; decisions identical when \|sim−thr\| > 1e-3 |
| NPY write | `np.save` of `vp_synth` | `vp_synth.npy` | byte-identical output from `Voiceprint.save` |
| Endpointer | `Recognizer._listen` / `adjust_for_ambient_noise(2)` / `record(4)` over a `CHUNK=1280` WAV source, timeouts 2.5/2.2/30, `phrase_time_limit=12` | `endpoint_<clip>.json` (start/end frame, byte length, threshold trajectory, WaitTimeoutError) | exact (threshold \|Δ\| ≤ 1e-9) |
| Tone | `analyze_tone(audio, text)` + intermediates (loud_db, f0s, f0_std, rate); `set_tone` counter key | `tone.json` | descriptor + key exact; intermediates \|Δ\| ≤ 1e-3 |
| Piper phonemes | `espeakbridge.get_phonemes`, `PiperVoice.phonemize`, `phonemes_to_ids` on 200 sentences (persona lines, numbers, "Mr.", "72.5 °C", "Wi-Fi", questions, exclamations) | `piper_phon.json` | exact |
| Piper audio | `synthesize` with `SynthesisConfig(length_scale=0.62, noise_scale=0.0, noise_w_scale=0.0)` (deterministic) on 10 sentences | `piper_pcm_<n>.npy` (int16) | length exact; max \|Δ\| ≤ 2 LSB |
| Pitch | ffmpeg `asetrate=20286,aresample=22050,atempo=1.08696` on `piper_pcm_0` (`new_rate = int(22050*0.92)` = 20286) | `pitch_ffmpeg_0.wav` | native TimePitch output: duration ±1 %, median-f0 ratio vs the unpitched source 0.92 ± 0.02 (not sample parity) |
## 5. Acceptance checks

Run from `cd ~/jarvis/native`. `A` = automated, `M` = manual (needs the user
speaking or listening). Every check pastes its observed output into PARITY.md's evidence column.

| ID | Command | Observable proof | Kind |
|---|---|---|---|
| A0 | `python3.14 tools/golden.py voice --check` | regenerates fixtures into a temp dir; `diff -r` against the committed ones is empty (the oracle is reproducible) | A |
| A1 | `swift test --filter JarvisVoiceTests.WakePhrasesGolden` | 150/150 exact | A |
| A2 | `swift test --filter JarvisVoiceTests.WakeWordGolden` | per clip, max \|Δscore\| printed ≤ 1e-4; fire sets identical at 0.5 and 0.15 | A |
| A3 | `swift test --filter JarvisVoiceTests.VADGolden` | 30 ms and 20 ms flags: 0 mismatches | A |
| A4 | `swift test --filter JarvisVoiceTests.ResemblyzerGolden` | filterbank ≤ 1e-7; mel ≤ 1e-4 rel; slices exact; min cosine printed ≥ 0.999 | A |
| A5 | `swift test --filter JarvisVoiceTests.VoiceprintCompat` | reads `~/jarvis/voiceprint.npy` (header parse only + 256 finite floats, norm within 1e-3 of 1); `save(vp_synth)` bytes == fixture (`cmp` exit 0) | A |
| A6 | `swift test --filter JarvisVoiceTests.EndpointerGolden` and `…ToneGolden` | exact frames and thresholds; descriptors exact | A |
| A7 | `swift test --filter JarvisVoiceTests.PiperGolden` | phonemes/ids exact for 200/200; PCM max \|Δ\| ≤ 2 LSB | A |
| A8 | `swift test --filter JarvisVoiceTests.SpeechQueueRouting` (fake engines) | the ElevenLabs stub failing with 401/402/429/timeout/offline → Piper, counters `tts_fallback_{auth,quota,rate_limited,timeout,offline}` bumped once; sticky per turn; the sensitive closure → Piper; order preserved; barge-in cancel drops queued sentences | A |
| A9 | `.build/debug/JARVIS --selftest-tts "Good evening, sir. All systems nominal."` (key present) | stdout logs `engine=elevenlabs ttfb_ms=<n>` with n < 1500, then `tts_elevenlabs +2`; the user hears the designed voice | A (log) + M (listen) |
| A10 | same with Wi-Fi off, or `JARVIS_TTS=piper` | `engine=piper fallback=offline`; audio plays with −144 cents pitch | A + M |
| A11 | `log stream --process JARVIS --predicate 'eventMessage CONTAINS "xi-api-key"'` during A9, then `grep -r "$(security find-generic-password -s com.jarvis.assistant.elevenlabs -w)" ~/jarvis/logs ~/jarvis/native 2>/dev/null \| wc -l` | no lines; count 0 (key never logged or on disk) | A |
| A12 | `.build/debug/JARVIS --selftest-stt Tests/Fixtures/golden/voice/corpus/cmd_03.wav` | transcript equals the corpus text modulo case/punctuation for ≥ 18/20 command clips; the noise clips produce "" and `stt_segments_dropped` bumps | A |
| A13 | `.build/debug/JARVIS --selftest-aec` | plays a 10 s Piper sentence through the engine while recording; prints the RMS of the input with VP on vs `voiceProcessingBypassed=true`. Pass: ≥ 15 dB attenuation | A (speakers on, room quiet) |
| A14 | `footprint -p JARVIS \| grep -i "phys_footprint"` in each state (idle listening; mid-reply with ElevenLabs; mid-reply with Piper; 130 s after the last Piper use) | numbers recorded in PARITY §RAM; Piper memory released after idle (the footprint drops by ≥ 80 % of its load delta) | A |
| A15 | `ps -M -p $(pgrep -x JARVIS) \| wc -l` idle, and `top -l 3 -pid $(pgrep -x JARVIS) -stats cpu` | idle CPU < 5 % of one core with the wake model running | A |
| M1 | User says "Hey Jarvis" ×10 at 1 m and ×10 at 3 m | JARVIS logs `wake score=` / `spk sim=` per attempt. Hard fires ≥ 9/10 at 1 m. Wake speaker sims vs 0.38 recorded (VP on). No chime on the 5 TV/other-voice attempts (TV playing a talk show) | M |
| M2 | User: "Jarvis" (bare) → "Yes, sir?" → "what time is it" | reply spoken, HUD listening→thinking→speaking→listening; after 30 s of silence the HUD goes idle and hides 2.6 s later | M |
| M3 | Barge-in: ask for a long answer, then say "stop, what's the weather" 2 s in | playback stops within ≤ 1.2 s of speech onset; queued sentences dropped; `barge_in` emotion logged. With a TV voice instead, no stop in 5 tries | M |
| M4 | "learn my voice" enrol (on a copy: `JARVIS_VOICEPRINT=/tmp/vp.npy`, a proposed test-only env) | 3 × 4 s capture, "Voice recognition is set, sir."; Python `np.load('/tmp/vp.npy')` loads it with shape (256,) float32; the real `voiceprint.npy` mtime is unchanged | M |
| M5 | Existing voiceprint validity: the user speaks 5 commands | native sim ≥ 0.60 for ≥ 4/5 (same threshold as Python, same `voiceprint.npy`) | M |
| M6 | HUD visual | screenshot next to the Python HUD (from an earlier screenshot or the `hud.html` in a browser): same layout and colours; click-through (clicking the desktop behind it works); stays visible over a full-screen app and across Spaces; never takes focus from the frontmost app | M |
| M7 | Music playing in Music.app while JARVIS idles | the user confirms no audible ducking (VP ducking at `.min`); if ducked → §8 R3 fallback | M |
| M8 | A sensitive turn ("read my latest message") after `speakLocally` is implemented | reply spoken in the Piper voice; `tts_fallback_sensitive` +1; no ElevenLabs request in the log | M |
## 6. Executor tasks

Rules for every task:
- Start writing at once and read on demand (grep or `sed -n`). §2 has the line numbers.
- Keep a worklog (one line per step, stating what was learned).
- Python voice JARVIS stays stopped.
- Nothing is committed without the M0 pre-commit hook passing.
- `voiceprint.npy` is only ever read, except in T10.4 against a copy.

| ID | ≤h | Files | Spec | Verification | Deps |
|---|---|---|---|---|---|
| T0.1 | 1.5 | `Package.swift`, `Sources/COnnxRuntime/*`, `Sources/CPyStubs/{pystubs.c,include/pystubs.h}`, `scripts/vendor-voice-assets.sh`, `.gitignore` (+`Resources/vendor/`) | Add the targets in §3.1. Copy the module map and headers verbatim from jarvis-swift. The vendor script copies ORT dylib + symlink, the 3 oww models, `_webrtcvad…so`, `espeakbridge.so` and `espeak-ng-data/`, and checks md5 against §8 values | `swift build --target JarvisVoice` ok; `md5` of the models = `7602421d…`, `de6abe00…`, `763f67cd…` | M0 |
| T0.2 | 2 | `tools/make_voice_corpus.py`, `tools/golden.py` (`voice` subcommand: phrases, textclean, pop_sentences, vocabulary) | Corpus per §4. The wake-clip search loop only imports openwakeword + onnxruntime | the manifest meets the ≥3/≥3 wake criterion; `golden.py voice --check` reproducible (A0) | M0 golden.py |
| T0.3 | 1 | `Sources/JarvisVoice/Speaker/WebRTCVAD.swift` (load only), `Speech/EspeakPhonemizer.swift` (load only), `--selftest-dlopen` | Spike, go/no-go. Inside the signed app bundle (hardened runtime), `dlopen` libpystubs (`RTLD_GLOBAL`), then both `.so`s. Call `WebRtcVad_Create/Init/set_mode(3)/Process` on one 30 ms frame and `espeak_Initialize` + `TextToPhonemesWithTerminator("Hello.")` | Go if both load and return (VAD 0/1, phoneme string non-empty). No-go VAD → §8 Q2. No-go espeak → ask the user about `brew install espeak-ng` (route b2), else route (a) | T0.1, M0 signing |
| T8.0 | user | ElevenLabs web UI; `JARVIS --set-elevenlabs-key` | User action: design a refined British butler voice (Voice Design prompt, e.g. "older male, received pronunciation, calm, dry wit, warm baritone"). Not a clone of Paul Bettany or any real person. Save the voice ID with `defaults write com.jarvis.assistant ElevenLabsVoiceID <id>` | `security find-generic-password -s com.jarvis.assistant.elevenlabs` finds the item | — |
| T8.1 | 2 | `Audio/AudioHub.swift` (output side), `Audio/Chime.swift`, `Speech/SayEngine.swift`, `Speech/TextClean.swift` | Graph from §3.3 with VP off for now; `say -o` path; chimes via fxPlayer | `--selftest-chime Tink` audible; `TextCleanGolden` exact | T0.1, T0.2 |
| T8.2 | 2 | `Speech/ElevenLabsEngine.swift`, `Speech/KeychainSecret.swift`, `SpeechEngine.swift` | §3.2: URLSession streaming, 1.5 s TTFB, breaker, the `--set-elevenlabs-key` CLI | `URLProtocol` stub tests for 200/401/402/429/stall; one live request (A9), recording the real response headers (the `request-id` name) and correcting §3.2 if they differ; A11 | T8.1, T8.0 |
| T8.3 | 2 | `Speech/EspeakPhonemizer.swift`, golden `piper_phon.json` | Full phonemize + ids per §3.2. Derive `mode` and the terminator mapping from logged raw ints vs Python tuples, and write the derived table with its evidence into the file header | `PiperGolden` phonemes/ids 200/200 | T0.3 |
| T8.4 | 2 | `Speech/PiperEngine.swift`, `ORT/OrtSession.swift` | VITS on ORT (1 intra thread), peak-normalise, 22050 Hz, idle release, TimePitch chain | `PiperGolden` PCM ≤ 2 LSB with noise = 0; pitch check (§4); A14 load/release numbers | T8.3 |
| T8.5 | 2 | `Speech/SpeechQueue.swift` | Routing, stickiness, one-ahead prefetch, counters, `events`, `cancelAll` | A8 | T8.2, T8.4 |
| T8.6 | 0.5 | `Speech/SpeechRouting.swift` | Commit the USER DECISION stub exactly as §3.2; ask the user to fill it in. Until then the app forces `JARVIS_TTS=piper` | the build passes; the user-written body exists before M12 sign-off; M8 | T8.5, W4 TurnContext |
| T9.1 | 2 | `Audio/AudioHub.swift` (input), `Audio/MicPipeline.swift`, `Audio/DeviceSelector.swift` | VP on, ducking `.min`, AGC off, tap/broadcast, rebinding, dead-stream hook, watchdog hook. Test whether `CurrentDevice` works with VP on | A13 (≥ 15 dB), M7, `--selftest-mic 10` prints 125 frames with non-zero RMS | T8.1 |
| T9.2 | 2 | `Listen/EnergyEndpointer.swift` | Port per §3.4, including float accumulation and `record` | `EndpointerGolden` exact | T0.2 |
| T9.3 | 2 | `Listen/Transcriber.swift`, `Listen/Vocabulary.swift` | Live-fed analyzer per utterance, contextualStrings, AssetInventory check, `--selftest-stt` | A12 (≥ 18/20), `VocabularyGolden` | T9.2 |
| T9.4 | 1 | `Transcriber.swift` const + this file §3.4 | Calibrate `STT_MIN_CONF`: dump per-result conf for the 40 speech + 6 non-speech clips. Choose the largest threshold keeping ≥ 39/40 speech results, and report how many non-speech results it drops | a table of (clip, conf) pasted into this file; the counter bumps on dropped results | T9.3 |
| T9.5 | 2 | `Listen/SentenceListener.swift`, `Listen/ToneAnalyzer.swift` | Ports per §3.4 | `ToneGolden` exact; a continuation test with a split WAV | T9.3 |
| **T10.0** | 1.5 | `tools/export_resemblyzer.py`, output `Resources/vendor/resemblyzer.onnx` | SPIKE (first in M10). The export in §3.5 with the `_add_onnxscript_fn` monkeypatch, `dynamo=False`, opset 17, dynamic batch. Compare ORT against torch on 32 random `[B,160,40]` and all corpus partials | Go: export succeeds without installing anything, max \|Δ\| ≤ 1e-5, B=1 and B=7 both run, file ≤ 8 MB. No-go → fallback: `tools/export_resemblyzer_weights.py` dumps the `state_dict` (`lstm.weight_ih_l{0,1,2}`, `weight_hh_l*`, `bias_ih_l*`, `bias_hh_l*`, `linear.weight`, `linear.bias`) to `.npy`. `SpeakerEncoder` then implements a 3-layer LSTM with Accelerate (`cblas_sgemm` for input projections, per-step `cblas_sgemv`, PyTorch gate order i,f,g,o, `sigmoid`/`tanh` via vForce) against the same `rz_onnx_io` fixture and tolerance | T0.1 |
| T10.1 | 1 | `Speaker/WebRTCVAD.swift` | `Process` binding + mode 3; 20/30 ms helpers | `VADGolden` 0 mismatches | T0.3 |
| T10.2 | 2 | `Speaker/ResemblyzerPreprocess.swift` | normalize, trim, Slaney filterbank, DFT-400 mel | filterbank ≤ 1e-7, pre ≤ 1e-6, mel ≤ 1e-4 rel | T10.1 |
| T10.3 | 2 | `Speaker/SpeakerEncoder.swift`, `Speaker/Voiceprint.swift` | Slices, batch embed, NPY r/w, cosine, speakerOK (open) / barge-in (closed), counters | A4, A5, `spk.json` decisions | T10.0, T10.2 |
| T10.4 | 1 | `Voiceprint.swift` (enroll/forget), `Loop` hook | Enrol 3 × `record(4)`; the path comes from the `VOICEPRINT_FILE` equivalent with the proposed test override `JARVIS_VOICEPRINT` | M4 on a copy; M5 | T10.3, T9.2 |
| T11.1 | 2 | `Wake/WakeWordDetector.swift` | Adapt the salvaged file per §3.1 verdict; `reset`; `NoiseSource` injection | A2 | T0.1, T0.2 |
| T11.2 | 1.5 | `Wake/WakeWatcher.swift` | Ring 25, hard/soft, 3.0 s rate limit, 20 extra frames, dead stream at 250 | `wake_watch.json` exact (stubbed transcriber) | T11.1, T9.3 |
| T12.1 | 1 | `Wake/WakePhrases.swift` | `_WAKE_RE`, `extract_command`, `is_dismiss`, `_is_enroll` (reuse JarvisCore if M7 ported them; do not duplicate) | A1 | T0.2 |
| T12.2 | 2 | `Loop/ConversationLoop.swift` | The state machine in §3.6 with injected fakes (frames from WAVs, brain stub, HUDSink recorder) | a scripted test asserting the event sequences for 8 scenarios (foreign wake silent; bare wake → "Yes, sir?"; soft wake with command; timeout → idle; dismiss; enrol; mismatch mid-conversation ignored; fast-path tuple) | T8.5, T9.5, T10.3, T11.2, T12.1 |
| T12.3 | 1.5 | `Loop/BargeIn.swift` | Per §3.6 | a barge-in corpus test (the overlay clip triggers only with a matching synthetic voiceprint); M3 | T12.2, T10.1 |
| T12.4 | 1.5 | `ConversationLoop.swift` boot, `JarvisApp` wiring | Mic permission, verify loop, calibration, greeting, watchdog exit 86, rebind on `.deadStream` | kill the default input device mid-run (unplug USB mic) → log "Reopening the microphone stream." and recovery; A14 idle; M1, M2 | T12.2, T9.1 |
| T13.1 | 1.5 | `JarvisApp/HUD/HUDPanel.swift`, `HUDController.swift` | Panel per §3.7; accessory policy; `JARVIS_NO_HUD` | M6 click-through/Spaces/focus; `CGWindowListCopyWindowInfo` shows layer = screenSaver level at (28, 48, 360, 430) | M0 app |
| T13.2 | 2 | `JarvisApp/HUD/HUDView.swift` | Visuals per §2.2 `hud.html`, captions from `SpeechEvent`, bars from input level while listening (RMS/32768 ×4, clamped) | M6 screenshots side by side; idle CPU (A15) with the HUD hidden | T13.1, T8.5 |
## 7. RAM / permissions

Resident cost per subsystem. Only the Python Piper figure was measured (by the orchestrator,
2026-09-28). Every other number is an estimate from file sizes, to be replaced by the A14
`footprint` measurements.

| Subsystem | When resident | Estimate | Basis |
|---|---|---|---|
| ORT dylib | always (wake word) | 15–30 MB | 28.8 MB file, arm64; only touched pages count |
| oww mel + embedding + hey_jarvis sessions | always while listening | 10–20 MB | models 1.09 + 1.33 + 1.27 MB, 1 thread |
| AVAudioEngine + VPIO | always | 10–25 MB | VP unit + 3 players + converter |
| SpeechAnalyzer/SpeechTranscriber | per utterance; `.lingering` retention | in-process delta to measure | Apple says the model lives in system storage and is managed by the OS; not verified here |
| Resemblyzer ONNX | lazy; released 300 s after last use outside conversations | 10–15 MB | ≈1.42 M params ≈ 5.7 MB fp32 (the 17 MB `pretrained.pt` includes non-model state) |
| Piper (native b1) | lazy; released after 120 s idle; pre-warmed when offline | 100–180 MB peak | 63 MB weights + ORT arena. The Python equivalent peaked at 356 MB (measured) |
| espeak-ng (in espeakbridge.so) + data | with Piper | 3–8 MB | 0.5 MB .so; the 19 MB data dir is mostly per-language and mmapped on demand |
| ElevenLabs client | during a reply | < 10 MB | ephemeral URLSession, no cache |
| HUD panel + SwiftUI | when shown; the timeline is paused when hidden | 15–30 MB | |
| Target idle total | wake listening, HUD hidden | ≤ 90 MB | PARITY §RAM row "Idle, listening for wake word" |

TCC and Info.plist. The M0 plist carries these keys; this section only requires them.
- `NSMicrophoneUsageDescription`: "JARVIS listens for its wake word and your commands on this Mac."
  Needed for AVAudioEngine input and the VP unit.
- `NSSpeechRecognitionUsageDescription`: "JARVIS transcribes your commands on-device."
  Whether SpeechAnalyzer triggers the Speech Recognition TCC prompt on macOS 26+ is
  not verified here. T9.3 records whether a prompt appeared.
- `LSUIElement` = `true` (agent app, no Dock icon), matching activation policy 1 in Python.
- The hardened runtime must allow `dlopen` of the re-signed vendor `.so`s. Library validation
  is satisfied by re-signing with the same Team ID (`build-app.sh`). If that fails, the
  fallback is `com.apple.security.cs.disable-library-validation`, flagged in §8.
- Keychain: no entitlement is needed for a login-keychain generic password owned by the app.
  A stable signing identity (M0) keeps the ACL valid across rebuilds.
- Network: outbound HTTPS to `api.elevenlabs.io` only. Add
  `com.apple.security.network.client` if the app is ever sandboxed; it is not sandboxed today.
- Bundle id `com.jarvis.assistant` (shared with Python's grant). The TCC mic grant carries
  over only if the code-signing requirement matches. Otherwise M15 re-grants.
## 8. Risks and open questions

Reference hashes (md5, checked 2026-09-28): `embedding_model.onnx 7602421d736d1a67e616bd85a01686fc`,
`hey_jarvis_v0.1.onnx de6abe00036ec10b675a679f45c5c643`, `melspectrogram.onnx 763f67cda79753bd15a7dc9e2c391100`.
These are identical in `~/jarvis-swift/Resources/models/` and SP/openwakeword/resources/models/.

Risks

| # | Risk | Mitigation / owner |
|---|---|---|
| R1 | ROADMAP's "Piper (subprocess, kept)" is wrong. J:653-664 loads `piper.PiperVoice` in-process. There is no standalone binary; `bin/piper` is a Python entry point | Native route b1 (§3.2). The planner should fix the ROADMAP row (not edited here) |
| R2 | `dlopen` of two Python extension modules with stubbed `Py*` data symbols is unusual and breaks if pip upgrades them | The vendor script pins md5s and copies once; T0.3 is the go/no-go. espeak-ng is GPL-3.0 (piper1-gpl); vendoring it into the app is fine for personal use but makes any redistribution GPL-bound. webrtcvad is MIT (wrapper) + BSD (WebRTC) |
| R3 | Voice processing (a) ducks other apps' audio by default, and (b) changes the mic signal (NS/AGC). The thresholds 0.5 / 0.38 / 0.60 were tuned on the raw mic (J:5135-5139 comment) | Ducking `.min`, AGC off; M1/M5/M7 measure with VP on. If sims drop or ducking is audible: `JARVIS_AEC=0` (exact Python behaviour), or enable VP only while speaking (engine restart glitch, unmeasured) |
| R4 | Choosing a non-default input device with VP on is unverified | T9.1 tests it; the fallback is a warning when the default input is on the avoid list |
| R5 | SpeechTranscriber confidence is not Whisper's `no_speech_prob`/`avg_logprob`; `STT_MIN_CONF` is calibrated on synthetic speech | T9.4, then re-checked in M1/M2 on the user's voice; the counter name is unchanged |
| R6 | The ElevenLabs endpoint, headers, quota fields and error codes are from public docs, not verified here. Voice cloning of real people is prohibited | T8.2 makes one live call and corrects §3.2. T8.0 designs an original voice. Replies go to the cloud by default. Until the user writes `speakLocally`, the app forces `JARVIS_TTS=piper` |
| R7 | oww `reset()` seeds from unseeded random noise, so the first 16 frames after a reset are non-deterministic in Python too | Tests inject the recorded seed noise, making every frame comparable |
| R8 | Golden generation imports torch + piper (~1 GB transient) on an 8 GB machine | Run only with ≥ 1.5 GB free; never while Python JARVIS runs |
| R9 | Python bug: the Claude-path `emit` (J:4949-4954) keeps speaking later sentences after a barge-in. Only the Ollama consumer (J:4789) drops them | The native `SpeechQueue.cancelAll` drops queued sentences for both backends. This is a deliberate deviation: the judge/planner approves it or asks for bug-for-bug parity |
| R10 | Proposed new env vars: `JARVIS_TTS`, `JARVIS_EL_VOICE`, `JARVIS_EL_MODEL`, `JARVIS_EL_PITCH`, `JARVIS_PIPER_IDLE_S`, `JARVIS_STT_MIN_CONF`, `JARVIS_AEC`, `JARVIS_VOICEPRINT` (test only) | All additive; PARITY env table update is the planner's call |
| R11 | Proposed additive dataset counters: `tts_elevenlabs`, `tts_piper`, `tts_elevenlabs_chars`, and `tts_fallback_{offline,auth,quota,rate_limited,timeout,http,network,sensitive,no_key,disabled,error}` | W3 owns the schema; existing keys (`stt_segments_dropped`, `speaker_pass`, `speaker_reject`, `wake_rejected_foreign_voice`, `tone_*`) are unchanged |
| R12 | The parse of `WHISPER_PROMPT` into contextual strings is a spec, not oracle-derived | Low impact; the list is visible in `vocabulary.json` |
| R13 | The `ConversationLoop` scenario test is spec-derived: a Python trace needs a mic + webview, so this is a test written from the same belief as the code | Every leaf is golden; M1–M3 cover the whole loop live |
| R14 | `AVAudioUnitTimePitch` is not ffmpeg `asetrate+atempo`, so the timbre may differ audibly | A10 listening; duration and f0 checks in §4 |
| R15 | One-ahead ElevenLabs prefetch spends characters on a sentence that barge-in then cancels | Bounded to one sentence per interruption; counted only when first audio arrives |
| R16 | Whether SpeechAnalyzer raises the Speech Recognition TCC prompt is unknown | T9.3 records it; the key is in the plist either way |
| R17 | Library validation may reject the re-signed vendor `.so`s | If so, `disable-library-validation` weakens the hardened runtime. Planner/user decision, not the executor's |

Open questions

- Q1 (planner): correct the ROADMAP Piper row and add R10/R11 to PARITY?
- Q2 (user, only if T0.3's VAD load fails). Three options:
  - (i) Approve fetching the py-webrtcvad 2.0.10 C source (BSD/MIT) to vendor.
  - (ii) A Swift port using the GMM tables, which are visible as local symbols in the `.so`
    (`nm`: `_kNoiseDataMeans`, `_kSpeechDataMeans`… at `0x7b80…`), validated by the exact
    flags golden.
  - (iii) Accept non-bit-exact trimming and relax the embedding bar.

  The recommendation is (i).
- Q3 (user): the `speakLocally` policy (§3.2).
- Q4 (planner): after a barge-in, feed the interrupting 800 ms into the next listen (better UX, a deviation) or drop it (parity, the default here)?
- Q5 (planner): is "sticky Piper for the rest of the turn after a fallback" acceptable, versus retrying ElevenLabs on every sentence?
- Q6 (user, only if route b1 fails): approve `brew install espeak-ng` (route b2)?
