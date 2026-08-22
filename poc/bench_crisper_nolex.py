"""Le lexique par défaut aide-t-il, ou nuit-il ?

`DEFAULT_LEXICON` est appliqué dès que l'application passe `nil`, ce qu'elle
fait tant qu'aucun terme n'a été ajouté à la main — donc en permanence sur
cette machine. Personne ne l'a choisi, et il n'a jamais été mesuré sur le
corpus entier. Ce banc rejoue tout avec `hotwords=[]`, qui le désactive.
"""
import json, sys, time
from pathlib import Path
P = Path("/Users/mehdinaji/Desktop/projet-perso/CrispType")
sys.path.insert(0, str(P / "engine"))
import soundfile as sf
from caspr_engine.crisper import CrisperWhisperEngine

C = Path.home() / "Library/Application Support/Caspr/corpus"
rows = [json.loads(l) for l in (C / "sessions.jsonl").read_text().splitlines() if l.strip()]
rows = [r for r in rows if r.get("audioFile") and (C / "audio" / r["audioFile"]).exists()]
eng = CrisperWhisperEngine(model_id="nyralabs/CrisperWhisper2.0_turbo")
charge = eng.load()
out = P / "poc/mesures/run-crisper-nolex.json"
res = []
for i, r in enumerate(rows, 1):
    a, _ = sf.read(C / "audio" / r["audioFile"], dtype="float32")
    if a.ndim > 1: a = a.mean(axis=1)
    t = time.time()
    try:
        txt = eng.transcribe(a, mode="intended", language=r.get("language", "fr"),
                             hotwords=[]).text
        err = None
    except Exception as exc:
        txt, err = "", f"{type(exc).__name__}: {exc}"
    res.append({"id": r["id"], "audioFile": r["audioFile"],
                "durationSeconds": r["durationSeconds"],
                "language": r.get("language", "fr"),
                "text": txt, "latencyMs": round((time.time()-t)*1000, 1), "error": err})
    out.write_text(json.dumps({"engine": "crisper-nolex",
        "model": "nyralabs/CrisperWhisper2.0_turbo", "lexicon": "DÉSACTIVÉ",
        "loadSeconds": round(charge,1), "results": res}, ensure_ascii=False, indent=1))
    print(f"[{i:3d}/{len(rows)}] {txt[:56]!r}")
print(f"\n{len(res)} → {out}")
