"""Rejoue tout le corpus avec les trois moteurs, un à la fois.

Un à la fois, et c'est le point : faire cohabiter CrisperWhisper (~3 Go) et
Voxtral 3B (~11 Go de Metal) pendant qu'un banc mesure des latences, c'est
mesurer la pression mémoire plutôt que les moteurs. La série précédente a été
faite avec 9 Go de swap actif — assez pour douter de chaque chiffre.

Chaque passage relève la pression avant et après, pour que la question ne se
repose pas.

    poc/.venv-mlx/bin/python poc/bench_all.py voxtral3b
    engine/.venv/bin/python  poc/bench_all.py crisper
    poc/.venv-mlx/bin/python poc/bench_all.py realtime
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

CORPUS = Path.home() / "Library/Application Support/Caspr/corpus"
OUT = Path(__file__).parent / "mesures"


def memoire() -> dict:
    """Pression mémoire au moment du relevé — le contexte manquait la fois d'avant."""
    top = subprocess.run(["top", "-l", "1", "-n", "0"], capture_output=True, text=True).stdout
    swap = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    ligne = next((l for l in top.splitlines() if "PhysMem" in l), "")
    return {"physmem": ligne.strip(), "swap": swap.strip()}


def dictees() -> list[dict]:
    rows = [json.loads(l) for l in (CORPUS / "sessions.jsonl").read_text().splitlines() if l.strip()]
    return [r for r in rows
            if r.get("audioFile") and (CORPUS / "audio" / r["audioFile"]).exists()]


def audio_de(r):
    import soundfile as sf
    a, _ = sf.read(CORPUS / "audio" / r["audioFile"], dtype="float32")
    return a.mean(axis=1) if a.ndim > 1 else a


# --------------------------------------------------------------------------

def run_crisper(rows):
    # `resolve()` appelle getcwd(), refusé quand le shell a perdu son répertoire.
    # `__file__` est déjà absolu dès qu'on invoque par chemin absolu.
    sys.path.insert(0, str(Path(__file__).parent.parent / "engine"))
    from caspr_engine.crisper import CrisperWhisperEngine
    eng = CrisperWhisperEngine(model_id="nyralabs/CrisperWhisper2.0_turbo")
    charge = eng.load()
    def une(r):
        out = eng.transcribe(audio_de(r), mode="intended", language=r.get("language", "fr"))
        return out.text
    return "crisper", "nyralabs/CrisperWhisper2.0_turbo", charge, une


def run_voxtral3b(rows):
    from mlx_audio.stt.generate import load_model
    repo = "mlx-community/Voxtral-Mini-3B-2507-bf16"
    t = time.time(); m = load_model(repo); charge = time.time() - t
    def une(r):
        # `language` et `max_tokens` explicitement : les défauts de mlx-audio
        # sont `en` et 128, donc sans eux le modèle traduit en anglais et
        # tronque au-delà d'une centaine de tokens. Découvert à la mesure.
        out = m.generate([str(CORPUS / "audio" / r["audioFile"])],
                         language=r.get("language", "fr"), max_tokens=4096)
        return getattr(out, "text", str(out))
    return "voxtral3b", repo, charge, une


def run_realtime(rows):
    """Vrai streaming : l'audio versé par secondes, comme dans l'application."""
    import mlx.core as mx
    from mlx_audio.stt.generate import load_model
    repo = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
    t = time.time(); m = load_model(repo); charge = time.time() - t
    def une(r):
        a = audio_de(r)
        sess = m.create_streaming_session(max_tokens=4096, temperature=0.0,
                                          transcription_delay_ms=480)
        texte = ""
        for i in range(0, len(a), 16000):
            sess.feed(a[i:i + 16000])
            for d in sess.step(max_decode_tokens=16):
                texte += d if isinstance(d, str) else getattr(d, "text", "")
        sess.close()
        for _ in range(4000):
            for d in sess.step(max_decode_tokens=16):
                texte += d if isinstance(d, str) else getattr(d, "text", "")
            if getattr(sess, "done", True):
                break
        return texte
    return "realtime", repo, charge, une


MOTEURS = {"crisper": run_crisper, "voxtral3b": run_voxtral3b, "realtime": run_realtime}


def main() -> None:
    quel = sys.argv[1] if len(sys.argv) > 1 else "crisper"
    rows = dictees()
    avant = memoire()
    print(f"{len(rows)} dictées — {quel}")
    print(f"  avant : {avant['physmem']}")

    nom, modele, charge, une = MOTEURS[quel](rows)
    print(f"  modèle chargé en {charge:.1f}s")

    sortie = OUT / f"run-{nom}.json"
    res = []
    for i, r in enumerate(rows, 1):
        t = time.time()
        try:
            texte, err = une(r), None
        except Exception as exc:                        # noqa: BLE001
            texte, err = "", f"{type(exc).__name__}: {exc}"
        ms = (time.time() - t) * 1000
        res.append({"id": r["id"], "audioFile": r["audioFile"],
                    "durationSeconds": r["durationSeconds"],
                    "language": r.get("language", "fr"),
                    "text": texte, "latencyMs": round(ms, 1), "error": err})
        sortie.write_text(json.dumps(
            {"engine": nom, "model": modele, "loadSeconds": round(charge, 1),
             "memoryBefore": avant, "results": res}, ensure_ascii=False, indent=1))
        print(f"[{i:3d}/{len(rows)}] {r['durationSeconds']:6.1f}s  {ms/1000:6.2f}s  "
              f"×{ms/1000/max(r['durationSeconds'],.1):.2f}  {texte[:46]!r}")

    apres = memoire()
    ok = [x for x in res if not x["error"]]
    lat = sorted(x["latencyMs"] for x in ok)
    print(f"\n{len(ok)}/{len(res)} transcrites → {sortie}")
    if lat:
        print(f"  latence médiane {lat[len(lat)//2]/1000:.2f}s")
    print(f"  après : {apres['physmem']}")
    print(f"          {apres['swap']}")


if __name__ == "__main__":
    main()
