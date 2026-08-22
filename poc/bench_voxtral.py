"""Voxtral contre le corpus réel — étape 1 de l'ouverture à d'autres moteurs.

Ce banc ne note pas, il **donne à voir**. Le corpus n'a pas de vérité terrain :
ce sont des dictées spontanées, jamais retranscrites à la main. Calculer un WER
supposerait une référence qui n'existe pas, et en fabriquer une à partir d'un
moteur reviendrait à sacrer ce moteur juge de ses concurrents.

On mesure donc ce qui se mesure sans référence :

  * la latence, et le facteur temps réel ;
  * les termes techniques, à l'orthographe exacte — c'est la promesse de Caspr,
    et « useEffect » ou « use effect » se comptent sans arbitre ;
  * les décrochages en boucle, que le corpus contient déjà (CrisperWhisper en
    mode verbatim part parfois en « And. You. You. You. » sur cent tokens) ;
  * l'écart de longueur entre moteurs sur le *même* audio, qui trahit les mots
    avalés sans qu'on ait à lire.

Le reste est un travail de lecture, et c'est pour ça que la sortie principale
est une page HTML côte à côte plutôt qu'un tableau de scores.

Usage :
    engine/.venv/bin/python poc/bench_voxtral.py            # les 129 dictées
    engine/.venv/bin/python poc/bench_voxtral.py --limit 5  # un essai rapide
"""

from __future__ import annotations

import argparse
import json
import re
import time
import unicodedata
from pathlib import Path

CORPUS = Path.home() / "Library/Application Support/Caspr/corpus"
OUT = Path(__file__).parent / "mesures/voxtral-run.json"
REPO = "mistralai/Voxtral-Mini-3B-2507"

# Le vocabulaire que Caspr existe pour préserver. Relevé sur le corpus lui-même
# plutôt qu'inventé : ce sont les termes qui apparaissent réellement dans ces
# dictées, sous l'orthographe qu'ils devraient avoir.
TERMS = [
    "useEffect", "useState", "component", "React", "Next.js", "TypeScript",
    "JavaScript", "hook", "refactor", "merge", "commit", "endpoint",
    "dependencies", "pull request", "branch", "CrisperWhisper", "Whisper",
    "Apple", "Caspr", "Swift", "SwiftUI", "Python", "macOS", "prompt",
    "token", "socket", "backend", "frontend", "build", "release", "debug",
    "code", "data", "recording", "framework", "package", "API", "JSON",
]


def repetition_score(text: str) -> float:
    """Part du texte occupée par sa boucle la plus longue, entre 0 et 1.

    Un décrochage de décodeur répète un motif court jusqu'à épuiser son budget.
    On cherche donc, pour des motifs de un à quatre mots, la plus longue suite
    d'occurrences consécutives, et on rapporte ce qu'elle pèse dans le texte.
    Une parole légitimement répétitive (« non non non ») fait trois ou quatre ;
    un décrochage fait trente.
    """
    words = text.split()
    if len(words) < 12:
        return 0.0
    worst = 0
    for size in (1, 2, 3, 4):
        i = 0
        while i + size <= len(words):
            motif = words[i:i + size]
            runs = 1
            j = i + size
            while j + size <= len(words) and words[j:j + size] == motif:
                runs += 1
                j += size
            if runs >= 3:
                worst = max(worst, runs * size)
            i += size if runs == 1 else runs * size
    return round(worst / len(words), 3)


def _fold(s: str) -> str:
    return unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()


def terms_found(text: str) -> dict[str, int]:
    """Termes techniques présents **à l'orthographe exacte**.

    La casse compte : c'est tout l'objet. « useEffect » écrit « use effect » ou
    « Use Effect » n'est pas le même mot pour qui le colle dans un éditeur.
    """
    found = {}
    for term in TERMS:
        n = len(re.findall(rf"(?<![\w.]){re.escape(term)}(?![\w])", text))
        if n:
            found[term] = n
    return found


def load_corpus() -> list[dict]:
    rows = [json.loads(l) for l in (CORPUS / "sessions.jsonl").read_text().splitlines() if l.strip()]
    keep = []
    for r in rows:
        name = r.get("audioFile")
        if name and (CORPUS / "audio" / name).exists():
            keep.append(r)
    return keep


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--fresh", action="store_true",
                    help="tout refaire au lieu de compléter")
    args = ap.parse_args()

    import soundfile as sf
    import torch
    from transformers import AutoProcessor, VoxtralForConditionalGeneration

    rows = load_corpus()

    # Incrémental : le corpus grossit pendant qu'on travaille, et refaire une
    # heure de calcul pour rattraper six dictées neuves n'a aucun sens. Les
    # anciens résultats sont relus et conservés tels quels — ils viennent du
    # même modèle, dans la même configuration.
    done: dict[str, dict] = {}
    if OUT.exists() and not args.fresh:
        for r in json.loads(OUT.read_text())["results"]:
            if r.get("text"):
                done[r["id"]] = r
    todo = [r for r in rows if r["id"] not in done]
    if args.limit:
        todo = todo[: args.limit]
    if done:
        print(f"{len(done)} déjà transcrites, {len(todo)} à faire")
    rows = todo
    print(f"{len(rows)} dictées, "
          f"{sum(r['durationSeconds'] for r in rows) / 60:.1f} min d'audio")

    t0 = time.time()
    processor = AutoProcessor.from_pretrained(args.repo)
    model = VoxtralForConditionalGeneration.from_pretrained(
        args.repo, dtype=torch.bfloat16, device_map="mps")
    load_s = time.time() - t0
    print(f"modèle chargé en {load_s:.1f}s")

    results = list(done.values())
    for i, r in enumerate(rows, 1):
        path = CORPUS / "audio" / r["audioFile"]
        lang = r.get("language", "fr")
        try:
            t = time.time()
            inputs = processor.apply_transcription_request(
                language=lang, audio=str(path), model_id=args.repo)
            inputs = inputs.to("mps", dtype=torch.bfloat16)
            with torch.no_grad():
                out = model.generate(**inputs, max_new_tokens=2048, do_sample=False)
            text = processor.batch_decode(
                out[:, inputs.input_ids.shape[1]:], skip_special_tokens=True)[0].strip()
            torch.mps.synchronize()
            latency = (time.time() - t) * 1000
            err = None
        except Exception as exc:                      # noqa: BLE001
            text, latency, err = "", 0.0, f"{type(exc).__name__}: {exc}"

        results.append({
            "id": r["id"], "audioFile": r["audioFile"],
            "durationSeconds": r["durationSeconds"], "language": lang,
            "text": text, "latencyMs": round(latency, 1), "error": err,
        })
        OUT.write_text(json.dumps(
            {"repo": args.repo, "loadSeconds": round(load_s, 1),
             "results": results}, ensure_ascii=False, indent=1))
        rtf = latency / 1000 / max(r["durationSeconds"], 0.1)
        flag = "ERREUR" if err else f"{latency/1000:5.1f}s  ×{rtf:.2f}"
        print(f"[{i:3d}/{len(rows)}] {r['durationSeconds']:6.1f}s  {flag}  "
              f"{text[:60]!r}")

    OUT.write_text(json.dumps(
        {"repo": args.repo, "loadSeconds": round(load_s, 1), "results": results},
        ensure_ascii=False, indent=1))
    ok = [x for x in results if not x["error"]]
    print(f"\n{len(ok)}/{len(results)} transcrites → {OUT}")
    if ok:
        lat = sorted(x["latencyMs"] for x in ok)
        print(f"latence médiane : {lat[len(lat)//2]:.0f} ms")


if __name__ == "__main__":
    main()
