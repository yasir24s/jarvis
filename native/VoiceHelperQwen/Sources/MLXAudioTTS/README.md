# MLXAudioCore, MLXAudioCodecs, MLXAudioTTS (vendored subset, patched)

From https://github.com/Blaizzy/mlx-audio-swift at commit 8d86630 (MIT, see each folder's
LICENSE), the checkout the Qwen scratch runner built on 2026-10-03. Only what Qwen3-TTS needs is
here, in the upstream modules and folders:

- `MLXAudioCore/`: `AudioUtils.swift`, `DSP.swift` and `Generation/GenerationTypes.swift`.
- `MLXAudioCodecs/Mimi/`: `Conv.swift`, `Quantization.swift`, `Seanet.swift` and
  `Transformer.swift` (not `Mimi.swift`, the codec model itself, which Qwen3-TTS does not use).
- `MLXAudioTTS/`: `Generation.swift`, `TextProcessor.swift` and `Models/Qwen3TTS/*.swift`.

JARVIS's patches, all in `Models/Qwen3TTS/Qwen3TTS.swift`:

- `import HuggingFace` and `Qwen3TTSModel.fromPretrained` (the Hugging Face download path) are
  removed: the model loads only from a local folder (`fromModelDirectory`). Without them the
  package needs neither swift-huggingface nor its networking dependencies.
- `fromModelDirectory` no longer deletes the model folder when `speech_tokenizer` is not a
  directory; it throws.
- `generateVoiceDesign` is public, so the helper can run a generation itself, take its chunks as
  they come, and cancel it between tokens.
