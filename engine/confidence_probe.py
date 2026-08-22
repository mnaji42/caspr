"""Les mots inventés se distinguent-ils par une faible confiance ?

Si oui, on peut les cibler — les signaler, les retenter, ou n'envoyer qu'eux
à un correcteur. Si non, aucun « double check » automatique n'est possible :
le modèle serait aussi sûr de ses inventions que du reste, et rien ne
permettrait de les repérer sans relire.
"""
import numpy as np, soundfile as sf, torch
from pathlib import Path
from caspr_engine.crisper import CrisperWhisperEngine, SAMPLE_RATE, MEL_FRAMES_PER_S

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
from caspr_engine import prompt as prompt_mod

engine = CrisperWhisperEngine()
engine.load()

@torch.no_grad()
def decode_with_confidence(audio, language="fr"):
    feats = engine._processor.feature_extractor(
        audio, sampling_rate=SAMPLE_RATE, return_tensors="pt")
    window, _ = engine._window_for(len(audio) / SAMPLE_RATE)
    n = int(window * MEL_FRAMES_PER_S); n -= n % 2
    mel = feats.input_features[:, :, :n].to(engine.device, engine.dtype)
    enc = engine._encode(mel)

    ids = prompt_mod.build(engine._processor.tokenizer, mode="intended",
                           language=language, hotwords=SONDE_LEXICON)
    cur = torch.tensor([ids], device=engine.device)
    past, out = None, []
    for _ in range(256):
        res = engine._model(encoder_outputs=enc, decoder_input_ids=cur,
                            past_key_values=past, use_cache=True)
        past = res.past_key_values
        logprobs = torch.log_softmax(res.logits[0, -1].float(), dim=-1)
        tok = int(logprobs.argmax())
        if tok == engine._eos: break
        out.append((tok, float(logprobs[tok].exp())))
        cur = torch.tensor([[tok]], device=engine.device)
    return out

def words_with_confidence(pairs):
    """Regroupe les tokens en mots, en gardant la confiance minimale."""
    tok = engine._processor.tokenizer
    words, current, conf = [], "", 1.0
    for token, probability in pairs:
        piece = tok.decode([token])
        if piece.startswith(" ") and current:
            words.append((current.strip(), conf)); current, conf = "", 1.0
        current += piece
        conf = min(conf, probability)
    if current.strip(): words.append((current.strip(), conf))
    return words

for wav in sorted(Path("../poc/samples").glob("*.wav"))[:5]:
    audio, _ = sf.read(str(wav), dtype="float32")
    lang = "en" if wav.stem.endswith("english") else "fr"
    pairs = decode_with_confidence(audio, lang)
    words = words_with_confidence(pairs)
    confs = [c for _, c in words]
    low = [w for w in words if w[1] < 0.5]
    print(f"\n── {wav.stem}")
    print(f"   confiance médiane {np.median(confs):.2f} | "
          f"minimum {min(confs):.2f} | {len(low)}/{len(words)} mots sous 0,50")
    if low:
        print("   mots peu sûrs :", ", ".join(f"{w} ({c:.2f})" for w, c in low[:8]))
