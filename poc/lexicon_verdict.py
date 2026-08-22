import json, re, sys, statistics
from pathlib import Path
P = Path("/Users/mehdinaji/Desktop/projet-perso/CrispType")
sys.path.insert(0, str(P / "poc"))
from french_quality import analyse
import engine_stats as st

avec = {r["id"]: r for r in json.load(open(P/"poc/run-crisper.json"))["results"] if r.get("text")}
sans = {r["id"]: r for r in json.load(open(P/"poc/run-crisper-nolex.json"))["results"] if r.get("text")}
com = sorted(set(avec) & set(sans))
print(f"{len(com)} dictées comparées — même audio, même code, seul le lexique change\n")

diff = [i for i in com if st.similarity(avec[i]["text"], sans[i]["text"]) < 0.98]
casses = [i for i in com if st.similarity(avec[i]["text"], sans[i]["text"]) < 0.60]
print(f"  textes différents : {len(diff)} ({len(diff)/len(com)*100:.0f} %)")
print(f"  divergences franches (<0,60) : {len(casses)}\n")

FRAG = re.compile(r"\b(useEffect|useState|Effects?|States?|props?)\b")
for nom, tbl in (("AVEC lexique", avec), ("SANS lexique", sans)):
    rs = [analyse(tbl[i]["text"]) for i in com
          if tbl[i].get("language","fr")=="fr" and len(tbl[i]["text"].split())>=40]
    mots = sum(r["mots"] for r in rs) or 1
    fuites = sum(len(FRAG.findall(tbl[i]["text"])) for i in com)
    termes = sum(sum(st.terms(tbl[i]["text"]).values()) for i in com)
    print(f"  {nom:14s} fragments {sum(r['fragments'] for r in rs)/mots*100:.2f} | "
          f"bafouillages {sum(r['bafouillages'] for r in rs)/mots*100:.2f} | "
          f"phrase {statistics.mean(r['phraseMoyenne'] for r in rs):.1f} | "
          f"fuites {fuites:3d} | termes techniques {termes}")

print("\n── les divergences franches, à l'œil ──")
for i in casses[:6]:
    print(f"  {i[-8:]}  {avec[i]['durationSeconds']:.0f}s {avec[i].get('language','fr')}")
    print(f"     AVEC : {avec[i]['text'][:96]}")
    print(f"     SANS : {sans[i]['text'][:96]}")
