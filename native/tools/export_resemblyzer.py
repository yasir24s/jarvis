#!/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
"""Export resemblyzer's speaker encoder to ONNX, once (plan: M08-M13 §3.5, T10.0).

    export_resemblyzer.py [--out <file>]   export, check, and keep the file only on a go
                                           (default native/Resources/vendor/resemblyzer.onnx)
    export_resemblyzer.py --check [<file>] check an existing export only

The model is resemblyzer 0.1.4's VoiceEncoder("cpu") with its own pretrained.pt, wrapped so the
export traces VoiceEncoder.forward unchanged: a 3-layer LSTM, hidden[-1], the linear layer, ReLU,
then L2 normalisation. Input "mels" [B, 160, 40] float32, output "embeds" [B, 256], B dynamic.

torch 2.12's legacy (TorchScript) exporter always calls onnx_proto_utils._add_onnxscript_fn,
which imports the onnx package and raises OnnxExporterError("Module onnx is not installed!").
That function only inlines onnxscript custom functions, and this model has none, so it is
replaced with the identity before exporting. Nothing is installed.

The check runs the export with the installed onnxruntime 1.26.0 (CPU, 1 intra-op and 1 inter-op
thread, ORT_ENABLE_ALL, the settings SpeakerEncoder uses) against torch on the same mels:
32 random batches (B from 1 to 8, seeded) and every partial of every clip in
Tests/Fixtures/golden/voice/speaker/. Go criteria: max |delta| <= 1e-5, B=1 and B=7 both run,
the file is at most 8 MB. Exit 1 on a no-go.
"""
import sys
import wave
from pathlib import Path

import numpy as np
import torch

NATIVE = Path(__file__).resolve().parents[1]
DEFAULT_OUT = NATIVE / "Resources" / "vendor" / "resemblyzer.onnx"
CORPUS = NATIVE / "Tests" / "Fixtures" / "golden" / "voice" / "speaker"
TOLERANCE = 1e-5
MAX_BYTES = 8 * 1024 * 1024


class Forward(torch.nn.Module):
    """VoiceEncoder.forward, unchanged, as the module the exporter traces."""

    def __init__(self, encoder):
        super().__init__()
        self.encoder = encoder

    def forward(self, mels):
        return self.encoder(mels)


def encoder():
    from resemblyzer import VoiceEncoder
    enc = VoiceEncoder("cpu", verbose=False)
    enc.eval()
    return enc


def export(path):
    from torch.onnx._internal.torchscript_exporter import onnx_proto_utils
    onnx_proto_utils._add_onnxscript_fn = lambda model_bytes, custom_opsets: model_bytes
    model = Forward(encoder()).eval()
    with torch.no_grad():
        torch.onnx.export(model, torch.zeros(1, 160, 40), str(path), dynamo=False, opset_version=17,
                          input_names=["mels"], output_names=["embeds"],
                          dynamic_axes={"mels": {0: "B"}, "embeds": {0: "B"}})


def corpus_batches():
    """Every partial of every corpus clip, as embed_utterance builds them, one batch per clip."""
    from resemblyzer import VoiceEncoder, preprocess_wav
    from resemblyzer.audio import wav_to_mel_spectrogram
    batches = []
    for path in sorted(CORPUS.glob("*.wav")):
        with wave.open(str(path), "rb") as w:
            pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
        wav = preprocess_wav(pcm.astype(np.float32) / 32768.0, source_sr=16000)
        if len(wav) < 6400:
            continue
        wav_slices, mel_slices = VoiceEncoder.compute_partial_slices(len(wav), 1.3, 0.75)
        if wav_slices[-1].stop >= len(wav):
            wav = np.pad(wav, (0, wav_slices[-1].stop - len(wav)), "constant")
        mel = wav_to_mel_spectrogram(wav)
        batches.append((path.stem, np.array([mel[s] for s in mel_slices])))
    return batches


def random_batches():
    rng = np.random.default_rng(10)
    sizes = [1, 7] + [int(b) for b in rng.integers(1, 9, size=30)]
    # Mel power is non-negative and heavy-tailed: exponential with a per-batch scale.
    return [(f"random_{k}_B{b}", (rng.exponential(1.0, (b, 160, 40)) * rng.uniform(0.01, 5.0)).astype(np.float32))
            for k, b in enumerate(sizes)]


def check(path):
    import onnxruntime as ort
    print(f"onnxruntime {ort.__version__}, torch {torch.__version__}")
    size = path.stat().st_size
    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    options.inter_op_num_threads = 1
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    session = ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])
    names = ([i.name for i in session.get_inputs()], [o.name for o in session.get_outputs()])
    model = encoder()
    worst, seen_b = 0.0, set()
    cases = random_batches()
    corpus = corpus_batches()
    if not corpus:
        print(f"warning: no corpus clips in {CORPUS.relative_to(NATIVE)}; random batches only")
    for name, mels in cases + corpus:
        with torch.no_grad():
            want = model(torch.from_numpy(mels)).numpy()
        got = session.run(["embeds"], {"mels": mels})[0]
        delta = float(np.max(np.abs(got - want)))
        worst = max(worst, delta)
        seen_b.add(mels.shape[0])
        if name in ("random_0_B1", "random_1_B7") or not name.startswith("random"):
            print(f"  {name:28} B={mels.shape[0]}  max|delta| {delta:.3g}")
    print(f"io names {names}; {len(cases)} random batches + {len(corpus)} corpus batches "
          f"({sum(m.shape[0] for _, m in corpus)} partials); batch sizes {sorted(seen_b)}")
    print(f"max |delta| {worst:.3g} (go <= {TOLERANCE}); file {size} bytes (go <= {MAX_BYTES})")
    go = worst <= TOLERANCE and {1, 7} <= seen_b and size <= MAX_BYTES and names == (["mels"], ["embeds"])
    print("GO" if go else "NO-GO")
    return 0 if go else 1


def main(argv):
    if argv[:1] == ["--check"]:
        return check(Path(argv[1]) if len(argv) > 1 else DEFAULT_OUT)
    if argv[:1] == ["--out"] and len(argv) == 2:
        out = Path(argv[1])
    elif not argv:
        out = DEFAULT_OUT
    else:
        raise SystemExit(__doc__)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + ".tmp")
    try:
        export(tmp)
        print(f"exported {out.name}")
        if check(tmp) != 0:
            return 1
        tmp.replace(out)
        return 0
    finally:
        tmp.unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
