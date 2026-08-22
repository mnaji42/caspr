"""Rejoue tout le corpus avec le CrisperWhisper **d'aujourd'hui**.

Les transcriptions rangées dans `sessions.jsonl` datent du jour de chaque
dictée. Le moteur a beaucoup bougé depuis — garde-fous anti-effondrement,
fenêtre adaptative, découpage long-format, lexique par défaut — si bien que
comparer Voxtral à ces textes-là, c'est le comparer à un moteur qui n'existe
plus. Ce banc refait la base, et c'est elle qui sert de référence ensuite.

On importe `caspr_engine` directement plutôt que de passer par le socket : le
service tourne pendant ce temps et sert les vraies dictées, et lui envoyer 135
requêtes le bloquerait pendant un quart d'heure. Vérifié avant d'écrire ça —
le moteur installé dans « Application Support » est identique au dépôt, donc
le code rejoué est bien celui qui écrit au quotidien.

Le lexique laissé à `None` : c'est ce que l'application envoie quand aucun
terme n'a été ajouté à la main, et le moteur applique alors son
`DEFAULT_LEXICON` de 19 termes. C'est la configuration réelle de cette machine,
vérifiée dans les préférences.

Usage :
    engine/.venv/bin/python poc/bench_crisper.py
    engine/.venv/bin/python poc/bench_crisper.py --limit 3
    engine/.venv/bin/python poc/bench_crisper.py --modes intended
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))

CORPUS = Path.home() / "Library/Application Support/Caspr/corpus"
OUT = Path(__file__).parent / "mesures/crisper-run.json"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--model", default="turbo",
                    help="small|medium|turbo|large — turbo est celui installé ici")
    ap.add_argument("--modes", default="intended,verbatim")
    args = ap.parse_args()

    import soundfile as sf
    from caspr_engine.crisper import CrisperWhisperEngine

    modes = [m.strip() for m in args.modes.split(",") if m.strip()]
    rows = [json.loads(l) for l in (CORPUS / "sessions.jsonl").read_text().splitlines() if l.strip()]
    rows = [r for r in rows if r.get("audioFile") and (CORPUS / "audio" / r["audioFile"]).exists()]
    if args.limit:
        rows = rows[: args.limit]

    model_id = f"nyralabs/CrisperWhisper2.0_{args.model}"
    print(f"{len(rows)} dictées × {len(modes)} modes — {model_id}")

    t0 = time.time()
    engine = CrisperWhisperEngine(model_id=model_id)
    engine.load()
    load_s = time.time() - t0
    print(f"modèle chargé en {load_s:.1f}s sur {engine.device}")

    results = []
    for i, r in enumerate(rows, 1):
        audio, sr = sf.read(CORPUS / "audio" / r["audioFile"], dtype="float32")
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        lang = r.get("language", "fr")
        entry = {"id": r["id"], "audioFile": r["audioFile"],
                 "durationSeconds": r["durationSeconds"], "language": lang,
                 "modes": {}}
        line = []
        for mode in modes:
            try:
                t = time.time()
                out = engine.transcribe(audio, mode=mode, language=lang,
                                        hotwords=None)
                latency = (time.time() - t) * 1000
                entry["modes"][mode] = {
                    "text": out.text, "latencyMs": round(latency, 1),
                    "windowSeconds": round(out.window_s, 1),
                    "truncated": out.truncated, "error": None,
                }
                line.append(f"{mode[:3]} {latency/1000:5.1f}s")
            except Exception as exc:                       # noqa: BLE001
                entry["modes"][mode] = {"text": "", "latencyMs": 0.0,
                                        "error": f"{type(exc).__name__}: {exc}"}
                line.append(f"{mode[:3]} ERREUR")
        results.append(entry)
        head = entry["modes"].get(modes[0], {}).get("text", "")[:52]
        print(f"[{i:3d}/{len(rows)}] {r['durationSeconds']:6.1f}s  "
              f"{'  '.join(line)}  {head!r}")

        # Écrit à chaque tour : un quart d'heure de calcul ne doit pas être
        # perdu parce que la 130e dictée déclenche un cas non prévu.
        OUT.write_text(json.dumps(
            {"model": model_id, "modes": modes, "lexicon": "DEFAULT_LEXICON",
             "loadSeconds": round(load_s, 1), "generated": time.strftime("%FT%T"),
             "results": results}, ensure_ascii=False, indent=1))

    print(f"\n{len(results)} dictées → {OUT}")
    for mode in modes:
        lat = sorted(e["modes"][mode]["latencyMs"] for e in results
                     if e["modes"].get(mode, {}).get("text"))
        ok = sum(1 for e in results if e["modes"].get(mode, {}).get("text"))
        if lat:
            print(f"  {mode:9s} {ok:3d} transcrites, latence médiane "
                  f"{lat[len(lat)//2]:.0f} ms")


if __name__ == "__main__":
    main()
