# F5TTS (vendored, patched)

From https://github.com/lucasnewman/f5-tts-swift at commit 36899100db60159022fa20620facfa0404871c64
(MIT, see LICENSE). Patched by the JARVIS voice spike (2026-10-01) to load the MLX 8-bit
`model_v1_8b` checkpoint and to run the F5-TTS v1 forward pass: rotary on every attention
head, the text padding mask, quantised Linears built at construction, and missing checkpoint
arrays kept from the modules. JARVIS also removed the Hugging Face download path and the
bundled test clip. The spike's diff against upstream is `results/patches/f5-tts-swift.diff`
in the spike folder.
