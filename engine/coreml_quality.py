"""L'encodeur Core ML produit-il le même texte que PyTorch ?

Les écarts d'activations ne disent rien d'utilisable : le décodeur peut
absorber du bruit, ou s'effondrer sur peu. Seule la transcription tranche.
On branche donc l'encodeur Core ML sur le décodeur PyTorch existant, avec le
même prompt, les mêmes échantillons.
"""
import time

#: Le lexique qui servait à cette sonde quand `crisper.py` en portait un.
#: Recopié ici le jour où il en a été retiré — mesuré nuisible sur voix réelle,
#: cf. `poc/README.md` — pour que les relevés de cette sonde restent
#: comparables entre eux.
SONDE_LEXICON = [
    "useEffect", "useState", "component", "React", "Next.js", "TypeScript",
    "hook", "props", "state",
    "refactor", "merge", "commit", "branch", "pull request",
    "endpoint", "dependencies", "async", "await",
    "chunk",
]
from pathlib import Path
import numpy as np, soundfile as sf, torch
import coremltools as ct
from caspr_engine.crisper import CrisperWhisperEngine, SAMPLE_RATE, MEL_FRAMES_PER_S
from caspr_engine import prompt as prompt_mod

WINDOW_S, FRAMES = 15, 1500

engine = CrisperWhisperEngine()
engine.load()
mlmodel = ct.models.MLModel("coreml/encoder_15s.mlpackage",
                            compute_units=ct.ComputeUnit.CPU_AND_NE)

from transformers.modeling_outputs import BaseModelOutput

def transcribe(audio, language, backend):
    feats = engine._processor.feature_extractor(
        audio, sampling_rate=SAMPLE_RATE, return_tensors="pt")
    mel = feats.input_features[:, :, :FRAMES]

    t0 = time.perf_counter()
    if backend == "coreml":
        out = mlmodel.predict({"mel": mel.numpy().astype(np.float16)})
        hidden = torch.from_numpy(
            np.asarray(next(iter(out.values())), dtype=np.float32)
        ).to(engine.device).half()
        enc = BaseModelOutput(last_hidden_state=hidden)
    else:
        enc = engine._encode(mel.to(engine.device, engine.dtype))
    torch.mps.synchronize()
    enc_ms = (time.perf_counter() - t0) * 1000

    ids = prompt_mod.build(engine._processor.tokenizer, mode="intended",
                           language=language, hotwords=SONDE_LEXICON)
    toks = engine._decode(enc, ids, 256)
    raw = engine._processor.tokenizer.decode(toks, skip_special_tokens=True)
    return engine._clean(raw, keep_disfluencies=False), enc_ms

same = 0
total = 0
for wav in sorted(Path("../poc/samples").glob("*.wav")):
    audio, _ = sf.read(str(wav), dtype="float32")
    if len(audio) / SAMPLE_RATE > WINDOW_S:
        audio = audio[:WINDOW_S * SAMPLE_RATE]
    lang = "en" if wav.stem.endswith("english") else "fr"
    a, ta = transcribe(audio, lang, "mps")
    b, tb = transcribe(audio, lang, "coreml")
    total += 1
    ok = a.strip() == b.strip()
    same += ok
    print(f"\n── {wav.stem}   MPS {ta:.0f} ms · Core ML {tb:.0f} ms   "
          f"{'IDENTIQUE' if ok else '*** DIFFÉRENT ***'}")
    if not ok:
        print(f"   MPS     : {a[-90:]}")
        print(f"   Core ML : {b[-90:]}")
print(f"\n  {same}/{total} transcriptions identiques")
