# Vocos (vendored, patched)

From https://github.com/lucasnewman/vocos-swift at commit f9502c7f703016ecceffd3915fea5ef0fe0d0122
(MIT, see LICENSE). Patched by the JARVIS voice spike (2026-10-01) to drop the Hugging Face
download path, so the vocoder loads from a local folder only. The spike's diff against
upstream is `results/patches/vocos-swift.diff` in the spike folder.
