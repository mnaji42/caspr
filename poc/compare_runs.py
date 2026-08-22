"""Compare les trois passages au propre, sur les mêmes dictées."""
import json, statistics, sys
from pathlib import Path
P = Path("/Users/mehdinaji/Desktop/projet-perso/CrispType")
sys.path.insert(0, str(P / "poc"))
from french_quality import analyse

NOMS = {"crisper": "CrisperWhisper turbo", "voxtral3b": "Voxtral 3B · MLX",
        "realtime": "Voxtral Realtime · flux"}
runs = {}
for k in NOMS:
    f = P / f"poc/mesures/run-{k}.json"
    if f.exists():
        d = json.load(open(f))
        runs[k] = {r["id"]: r for r in d["results"] if r.get("text")}

communs = set.intersection(*(set(v) for v in runs.values())) if len(runs) > 1 else set()
print(f"{len(communs)} dictées transcrites par les {len(runs)} moteurs\n")

print(f"{'moteur':26s} {'n':>4s} {'latence méd.':>13s} {'×réel':>7s} "
      f"{'ph. moy.':>9s} {'fragm.':>7s} {'bafouil.':>9s}")
for k, nom in NOMS.items():
    if k not in runs: continue
    rs = [runs[k][i] for i in communs] if communs else list(runs[k].values())
    fr = [analyse(r["text"]) for r in rs
          if r.get("language", "fr") == "fr" and len(r["text"].split()) >= 40]
    lat = sorted(r["latencyMs"] for r in rs)
    dur = sum(r["durationSeconds"] for r in rs)
    tot = sum(r["latencyMs"] for r in rs) / 1000
    mots = sum(a["mots"] for a in fr) or 1
    print(f"{nom:26s} {len(rs):4d} {lat[len(lat)//2]/1000:12.2f}s {tot/dur:7.2f} "
          f"{statistics.mean(a['phraseMoyenne'] for a in fr):9.1f} "
          f"{sum(a['fragments'] for a in fr)/mots*100:7.2f} "
          f"{sum(a['bafouillages'] for a in fr)/mots*100:9.2f}")
