"""Rassemble les bancs en un seul fichier, lisible par quelqu'un d'autre.

Existe parce que le corpus de l'application et les bancs ont été confondus, et
que la confusion était prévisible : `sessions.jsonl` porte ce que l'application
a **inséré** au fil des mois — moteurs d'alors, versions d'alors, aucune
transcription Voxtral en lot — tandis que les `run-*.json` portent le corpus
**rejoué** par chaque moteur, à code figé et mémoire libre.

Donner le premier en croyant donner les seconds mène exactement où c'est allé :
un interlocuteur qui conclut que Mistral n'a que cinq mesures.

    engine/.venv/bin/python poc/export_bench.py
    → poc/benchmark-complet.json
"""
import json
from pathlib import Path

POC = Path(__file__).parent
CORPUS = Path.home() / "Library/Application Support/Caspr/corpus"

#: Les quatre passages retenus, et pourquoi ceux-là. Les fichiers
#: `voxtral-run.json` et `crisper-run.json` sont volontairement exclus : ils
#: viennent de la série tournée sous 9 Go de swap, qui coûtait 18 % de latence.
BANCS = {
    "crisperwhisper": ("run-crisper-nolex.json",
        "CrisperWhisper 2.0 turbo, PyTorch/MPS, hotwords=[] — CE QUE FAIT "
        "L'APPLICATION : elle envoie toujours une liste explicite, vide tant "
        "que personne n'a ajouté de terme"),
    "crisperwhisper_lexique_impose": ("run-crisper.json",
        "Le même avec un lexique de 19 termes imposé — configuration que "
        "l'application n'utilise PAS, gardée parce qu'elle chiffre ce que "
        "coûterait un lexique par défaut : 0,25 fragment pour cent mots contre "
        "0,19, quatre fuites contre zéro"),
    "voxtral_3b_mlx": ("run-voxtral3b.json",
        "Voxtral-Mini-3B-2507 bf16 sous MLX, language=fr, max_tokens=4096, "
        "transcription en lot"),
    "macos_apple_intelligence": ("run-macos.json",
        "macOS 26 SpeechTranscriber (Apple Intelligence), rejoué par Caspr.app "
        "elle-même — le framework Speech exige une autorisation que seule "
        "l'application détient, donc c'est elle qui mesure, via --bench-corpus"),
    "voxtral_realtime_flux": ("run-realtime.json",
        "Voxtral-Mini-4B-Realtime-2602 4-bit sous MLX, vrai streaming, "
        "morceaux d'une seconde, delay 480 ms"),
}


#: Les moteurs de macOS ne sont **pas** rejouables hors de l'application : le
#: framework Speech exige l'autorisation de reconnaissance vocale, accordée à
#: `Caspr.app` et refusée à un binaire d'essai — éprouvé, l'analyseur rend
#: `nilError`. Leurs transcriptions viennent donc du corpus, captées en direct
#: au fil des dictées. C'est une différence de nature, pas de détail, et le
#: fichier doit la porter : les quatre autres ont été rejoués à code figé et
#: mémoire libre, ceux-ci non.
MACOS = {
    "macos_dictee": ("apple-legacy",
        "macOS SFSpeechRecognizer, le moteur de la Dictée du système — capté en "
        "direct par l'application, PAS rejoué : lancé depuis le mode banc il fait "
        "planter le process sur une vérification TCC, alors que la clé "
        "NSSpeechRecognitionUsageDescription est bien présente et que le moteur "
        "fonctionne dans le parcours normal"),
}


def main() -> None:
    runs = {}
    for cle, (nom, desc) in BANCS.items():
        f = POC / "mesures" / nom
        if not f.exists():
            continue
        d = json.loads(f.read_text())
        if nom == "run-macos.json":
            # Ce banc-là porte plusieurs moteurs par ligne ; on n'en retient
            # qu'un, et on remet la sortie à la forme commune.
            res = {}
            for r in d["results"]:
                m = r.get("apple") or {}
                if m.get("text"):
                    res[r["id"]] = {"id": r["id"], "text": m["text"],
                                    "latencyMs": round(m.get("latencyMs", 0), 1),
                                    "durationSeconds": r.get("durationSeconds")}
            runs[cle] = {"description": desc, "modele": "macOS 26 SpeechTranscriber",
                         "lexique": "sans objet (contextualStrings sans effet, mesuré)",
                         "rejoue": True, "resultats": res}
            continue
        runs[cle] = {"description": desc, "modele": d.get("model"),
                     "lexique": d.get("lexicon", "DEFAULT_LEXICON"), "rejoue": True,
                     "resultats": {r["id"]: r for r in d["results"] if r.get("text")}}

    meta = {}
    for l in (CORPUS / "sessions.jsonl").read_text().splitlines():
        if l.strip():
            r = json.loads(l)
            meta[r["id"]] = r

    # Les moteurs macOS, tirés du corpus. Une seule transcription par moteur et
    # par dictée : quand l'application en a gardé plusieurs, on retient celle
    # qui a été insérée, sinon la première.
    for cle, (nom_moteur, desc) in MACOS.items():
        res = {}
        for i, r in meta.items():
            cands = [t for t in r["transcriptions"]
                     if t["engine"] == nom_moteur and t.get("text")]
            if not cands:
                continue
            t = next((x for x in cands if x.get("inserted")), cands[0])
            res[i] = {"id": i, "text": t["text"], "latencyMs": t.get("latencyMs"),
                      "durationSeconds": r["durationSeconds"]}
        if res:
            runs[cle] = {"description": desc, "modele": nom_moteur,
                         "lexique": "sans objet (l'API ignore contextualStrings, mesuré)",
                         "rejoue": False, "resultats": res}

    tous = sorted(set().union(*(set(v["resultats"]) for v in runs.values())))
    communs = sorted(set.intersection(*(set(v["resultats"]) for v in runs.values())))
    # Le sous-ensemble qui porte la comparaison la plus solide : les quatre
    # moteurs rejoués dans les mêmes conditions. « Tous les six » est plus
    # restrictif sans être plus rigoureux, la Dictée de macOS n'ayant tourné
    # que sur une partie du corpus.
    rejoues = [k for k, v in runs.items() if v["rejoue"]]
    quatre = sorted(set.intersection(*(set(runs[k]["resultats"]) for k in rejoues)))

    dictees = []
    for i in tous:
        m = meta.get(i, {})
        e = {"id": i,
             "dureeSecondes": round(m.get("durationSeconds", 0), 1),
             "langueDeclaree": m.get("language"),
             "transcritParTous": i in communs,
             "transcritParLesCinqRejoues": i in quatre,
             "moteursPresents": [],
             "moteurs": {}}
        for cle, v in runs.items():
            r = v["resultats"].get(i)
            if r:
                e["moteurs"][cle] = {"texte": r["text"],
                                     "latenceMs": r.get("latencyMs"),
                                     "mots": len(r["text"].split())}
                e["moteursPresents"].append(cle)
        dictees.append(e)

    sortie = {
        "aPropos": {
            "quoi": "Le même corpus de dictées réelles, rejoué par quatre "
                    "configurations de moteur. Un seul modèle chargé à la fois, "
                    "mémoire libre.",
            "ceQueCeNestPas": "Ce n'est pas `sessions.jsonl`, le corpus de "
                              "l'application : celui-là porte ce qui a été inséré "
                              "au fil des mois, par des moteurs d'alors, et ne "
                              "contient aucune transcription Voxtral en lot.",
            "pasDeVeriteTerrain": "Ces dictées n'ont jamais été retranscrites à "
                                  "la main. Il n'y a donc pas de référence, et un "
                                  "WER n'est pas calculable — comparer les "
                                  "moteurs entre eux est tout ce qui est possible.",
            "attention": "Cinq moteurs ont été REJOUÉS sur le même audio, à "
                         "code figé, un seul modèle chargé à la fois, mémoire "
                         "libre. Les deux moteurs macOS n'ont PAS pu l'être — le "
                         "framework Speech exige une autorisation que seule "
                         "l'application possède — donc leurs textes viennent du "
                         "corpus, captés en direct. Leurs latences ne sont pas "
                         "comparables aux quatre autres.",
            "machine": "Apple M4 Pro, 48 Go, macOS 26.6",
            "dicteesTotal": len(tous),
            "dicteesTranscritesParTous": len(communs),
            "dicteesTranscritesParLesCinqRejoues": len(quatre),
            "conseil": "Pour comparer les moteurs entre eux, filtrer sur "
                       "`transcritParLesCinqRejoues` : c'est le plus grand "
                       "sous-ensemble mesuré dans des conditions identiques. "
                       "`transcritParTous` est plus restrictif sans être plus "
                       "rigoureux, la Dictée de macOS n'ayant tourné que sur une "
                       "partie du corpus.",
        },
        "moteurs": {k: {"description": v["description"], "modele": v["modele"],
                        "lexique": v["lexique"], "rejoueAuPropre": v["rejoue"],
                        "dictees": len(v["resultats"])}
                    for k, v in runs.items()},
        "dictees": dictees,
    }
    f = POC / "mesures/benchmark-complet.json"
    f.write_text(json.dumps(sortie, ensure_ascii=False, indent=1))
    print(f"{len(tous)} dictées → {f}")
    print(f"  {len(quatre)} avec les cinq moteurs rejoués, {len(communs)} avec les six")
    print(f"  {f.stat().st_size/1e6:.1f} Mo")
    for k, v in sortie["moteurs"].items():
        marque = "rejoué" if v["rejoueAuPropre"] else "capté en direct"
        print(f"  {k:32s} {v['dictees']:3d} dictées   {marque}")


if __name__ == "__main__":
    main()
