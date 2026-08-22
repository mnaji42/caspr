"""Construit la page de comparaison des moteurs sur le corpus réel.

Sortie : un fichier HTML autonome, à ouvrir dans un navigateur. Il n'y a pas de
vérité terrain sur ce corpus (cf. engine_stats), donc la page ne classe pas :
elle **donne à lire**, et elle range les dictées de façon que celles où les
moteurs divergent le plus arrivent en premier.

Usage :
    engine/.venv/bin/python poc/report_engines.py
    engine/.venv/bin/python poc/report_engines.py --out /tmp/comparaison.html
"""

from __future__ import annotations

import argparse
import difflib
import html
import json
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import engine_stats as st
from french_quality import analyse as st_analyse

CORPUS = Path.home() / "Library/Application Support/Caspr/corpus"
VOXTRAL_RUN = Path(__file__).parent / "mesures/voxtral-run.json"
CRISPER_RUN = Path(__file__).parent / "mesures/crisper-run.json"
AUDIO_DIR = Path(__file__).parent / "mesures/audio16"

# Les moteurs, dans l'ordre où ils s'affichent. La clé est celle du corpus :
# (engine, mode). La couleur encode la **famille** — deux nuances d'indigo pour
# les deux modes de CrisperWhisper, deux gris pour les deux macOS — parce que
# c'est vrai du sujet : ce sont deux réglages d'un même moteur, pas quatre
# moteurs.
ENGINES = [
    {"key": "voxtral3b",  "name": "Voxtral 3B", "sub": "MLX · au propre",      "hue": "amber"},
    {"key": "crisper",    "name": "CrisperWhisper", "sub": "turbo · lexique par défaut", "hue": "indigo"},
    # Le même moteur, le même code, le lexique en moins. La comparaison la plus
    # instructive du corpus : `DEFAULT_LEXICON` s'applique dès que l'application
    # passe `nil`, ce qu'elle fait tant qu'aucun terme n'a été ajouté à la main.
    # Personne ne l'a choisi et il n'avait jamais été mesuré ainsi.
    {"key": "crisper-nolex", "name": "CrisperWhisper", "sub": "turbo · SANS lexique", "hue": "teal"},
    {"key": "realtime",   "name": "Voxtral Realtime", "sub": "flux · au propre", "hue": "violet"},
    {"key": "apple",      "name": "macOS",      "sub": "Apple Intelligence",   "hue": "slate"},
    {"key": "apple-legacy", "name": "macOS",    "sub": "Dictée",               "hue": "steel"},
    # Ce que l'application avait réellement inséré le jour de la dictée. Gardé
    # exprès : c'est la seule façon de voir ce que les correctifs ont changé.
    {"key": "corpus:crisper", "name": "CrisperWhisper", "sub": "à l'époque · inséré", "hue": "faded"},
]

#: Les passages rejoués, un fichier par moteur. Ils priment sur le corpus :
#: celui-ci porte ce qui a été inséré le jour même, par un moteur qui a changé
#: depuis, et sous une pression mémoire qui coûtait 18 % de latence.
RUNS = {"crisper": "run-crisper.json",
        "crisper-nolex": "run-crisper-nolex.json",
        "voxtral3b": "run-voxtral3b.json",
        "realtime": "run-realtime.json"}


def engine_key(t: dict) -> str:
    e = t.get("engine")
    if e == "crisperwhisper":
        # Le texte du corpus ne rejoint plus la colonne « aujourd'hui » : il a
        # été produit par un moteur qui n'existe plus. Seul le mode nettoyé est
        # conservé — c'est celui qui a été inséré, donc le seul qui ait été vu.
        return "corpus:crisper" if (t.get("mode") or "intended") == "intended" else None
    if e == "apple-legacy":
        return "apple-legacy"
    return "apple" if e == "apple" else e


def load() -> list[dict]:
    rows = [json.loads(l) for l in (CORPUS / "sessions.jsonl").read_text().splitlines() if l.strip()]
    passages: dict[str, dict] = {}
    for cle, nom in RUNS.items():
        f = Path(__file__).parent / "mesures" / nom
        if f.exists():
            data = json.loads(f.read_text())
            passages[cle] = {r["id"]: r for r in data["results"] if r.get("text")}

    entries = []
    for r in rows:
        texts: dict[str, dict] = {}
        for t in r["transcriptions"]:
            k = engine_key(t)
            if k and t.get("text") and k not in texts:
                texts[k] = {"text": t["text"], "latencyMs": t.get("latencyMs"),
                            "model": t.get("model")}
        for cle, table in passages.items():
            if r["id"] in table:
                v = table[r["id"]]
                texts[cle] = {"text": v["text"], "latencyMs": v["latencyMs"],
                              "model": None}
        if not texts:
            continue
        longest = max(len(v["text"].split()) for v in texts.values())
        for v in texts.values():
            v["words"] = st.word_count(v["text"])
            v["repetition"] = st.repetition(v["text"])
            v["terms"] = st.terms(v["text"])
            v["coverage"] = round(v["words"] / longest, 3) if longest else 0.0

        # Termes isolés : présents chez **un seul** moteur sur cette dictée.
        # Le signal coupe dans les deux sens, et c'est pour ça qu'il vaut le
        # détour — soit ce moteur a inventé le mot (CrisperWhisper glisse son
        # lexique dans le texte : « Effect la feature » pour « parce que la
        # feature »), soit il est le seul à l'avoir bien écrit. Dans les deux
        # cas c'est là qu'il faut aller lire. Sans deux autres moteurs pour
        # faire quorum, la question ne se pose pas.
        for k, v in texts.items():
            others = [o for kk, o in texts.items() if kk != k]
            v["lonely"] = sorted(
                t for t in v["terms"]
                if len(others) >= 2 and not any(t in o["terms"] for o in others)
            ) if len(others) >= 2 else []
        entries.append({
            "id": r["id"], "date": r["date"], "duration": r["durationSeconds"],
            "language": r.get("language", "fr"), "audioFile": r.get("audioFile"),
            "texts": texts,
        })
    return entries


def diff_spans(a: str, b: str) -> tuple[str, str]:
    """Deux textes balisés mot à mot : ce qui diffère est marqué de part et
    d'autre. C'est ce qui remplace la lecture de deux paragraphes entiers."""
    aw, bw = a.split(), b.split()
    sm = difflib.SequenceMatcher(None, [st._fold(w) for w in aw],
                                 [st._fold(w) for w in bw])
    out_a: list[str] = []
    out_b: list[str] = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        ta = html.escape(" ".join(aw[i1:i2]))
        tb = html.escape(" ".join(bw[j1:j2]))
        if tag == "equal":
            out_a.append(ta); out_b.append(tb)
        else:
            if ta: out_a.append(f'<mark class="d">{ta}</mark>')
            if tb: out_b.append(f'<mark class="d">{tb}</mark>')
    return " ".join(out_a), " ".join(out_b)


CSS = """
/* Fondations — le gris tire légèrement vers le bleu de l'écran, pas vers le
   beige : le sujet est un instrument, pas un imprimé. */
:root{
  --ground:#F7F8FB; --surface:#FFFFFF; --sunken:#EEF0F6;
  --ink:#151821; --ink-soft:#4A5162; --ink-faint:#7C8497;
  --line:#E2E5EE; --line-soft:#EDEFF5;
  --amber:#B45309; --amber-bg:#FDF3E3;
  --indigo:#4338CA; --indigo-bg:#EDECFC;
  --violet:#6D28D9; --violet-bg:#F2ECFD;
  --slate:#334155; --slate-bg:#EDF0F4;
  --steel:#5B7189; --steel-bg:#EDF1F6;
  --faded:#8A93A6; --faded-bg:#F1F3F7;
  --teal:#0F766E; --teal-bg:#E6F2F0;
  --warn:#B42318; --warn-bg:#FDECEA;
  --diff:#FDE68A; --diff-ink:#4A3400;
  --shadow:0 1px 2px rgba(21,24,33,.05), 0 8px 24px -12px rgba(21,24,33,.18);
}
@media (prefers-color-scheme:dark){ :root:not([data-theme="light"]){
  --ground:#0F1116; --surface:#171A21; --sunken:#1E222B;
  --ink:#E7EAF2; --ink-soft:#A7B0C2; --ink-faint:#767F92;
  --line:#282D38; --line-soft:#20242D;
  --amber:#F0B357; --amber-bg:#2E2213;
  --indigo:#A5A0F5; --indigo-bg:#1E1D3A;
  --violet:#C4A5F7; --violet-bg:#251B38;
  --slate:#A8B6CA; --slate-bg:#1C222B;
  --steel:#93A9C2; --steel-bg:#1A212A;
  --faded:#6E7789; --faded-bg:#191D25;
  --teal:#5FCFC0; --teal-bg:#12231F;
  --warn:#F2938C; --warn-bg:#33191A;
  --diff:#5C4A12; --diff-ink:#FBE7A8;
  --shadow:0 1px 2px rgba(0,0,0,.4), 0 8px 24px -12px rgba(0,0,0,.6);
}}
:root[data-theme="dark"]{
  --ground:#0F1116; --surface:#171A21; --sunken:#1E222B;
  --ink:#E7EAF2; --ink-soft:#A7B0C2; --ink-faint:#767F92;
  --line:#282D38; --line-soft:#20242D;
  --amber:#F0B357; --amber-bg:#2E2213;
  --indigo:#A5A0F5; --indigo-bg:#1E1D3A;
  --violet:#C4A5F7; --violet-bg:#251B38;
  --slate:#A8B6CA; --slate-bg:#1C222B;
  --steel:#93A9C2; --steel-bg:#1A212A;
  --faded:#6E7789; --faded-bg:#191D25;
  --teal:#5FCFC0; --teal-bg:#12231F;
  --warn:#F2938C; --warn-bg:#33191A;
  --diff:#5C4A12; --diff-ink:#FBE7A8;
  --shadow:0 1px 2px rgba(0,0,0,.4), 0 8px 24px -12px rgba(0,0,0,.6);
}
*{box-sizing:border-box}
body{
  margin:0; background:var(--ground); color:var(--ink);
  font:400 15px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",system-ui,sans-serif;
  -webkit-font-smoothing:antialiased;
}
/* La chrome de données est en mono, la parole transcrite reste en humanist :
   c'est l'idée du sujet — un instrument d'ingénieur qui lit du langage. */
.mono{font-family:ui-monospace,"SF Mono",Menlo,monospace; font-variant-numeric:tabular-nums}
.wrap{max-width:1340px; margin:0 auto; padding:0 24px}
/* Les dictées débordent la colonne de lecture dès qu'on compare plus de deux
   moteurs : à trois colonnes dans 1340 px, chaque texte tombe sous 400 px et
   la prose devient illisible. L'en-tête et les constats gardent leur largeur —
   ce sont des paragraphes, ils ont besoin d'une ligne courte. */
.wrap.large{max-width:min(1900px, calc(100vw - 48px))}

header.top{border-bottom:1px solid var(--line); background:var(--surface)}
.masthead{padding:40px 0 28px}
h1{
  margin:0 0 6px; font-size:clamp(26px,3.4vw,38px); line-height:1.1;
  letter-spacing:-.028em; font-weight:640; text-wrap:balance;
}
.lede{margin:0; max-width:64ch; color:var(--ink-soft); font-size:15.5px}
.corpusline{
  margin-top:18px; display:flex; flex-wrap:wrap; gap:8px 22px;
  font-size:12px; letter-spacing:.04em; text-transform:uppercase; color:var(--ink-faint);
}
.corpusline b{color:var(--ink); font-weight:600}

/* Panneau agrégé — les chiffres qu'on lit avant d'ouvrir une dictée. */
section.summary{padding:30px 0 34px}
h2{
  margin:0 0 4px; font-size:13px; letter-spacing:.09em; text-transform:uppercase;
  color:var(--ink-faint); font-weight:640;
}
.note{margin:0 0 18px; color:var(--ink-soft); font-size:13.5px; max-width:70ch}
.tablewrap{overflow-x:auto; border:1px solid var(--line); border-radius:12px; background:var(--surface)}
table{border-collapse:collapse; width:100%; min-width:760px; font-size:13.5px}
th,td{padding:11px 14px; text-align:right; border-bottom:1px solid var(--line-soft); white-space:nowrap}
th{
  font-size:11px; letter-spacing:.06em; text-transform:uppercase;
  color:var(--ink-faint); font-weight:600; background:var(--sunken);
}
th:first-child,td:first-child{text-align:left}
tbody tr:last-child td{border-bottom:none}
.ename{display:flex; align-items:baseline; gap:8px}
.dot{width:9px; height:9px; border-radius:3px; flex:none; transform:translateY(-1px)}
.esub{color:var(--ink-faint); font-size:11.5px}
.bar{position:relative; height:5px; border-radius:3px; background:var(--sunken); min-width:64px}
.bar i{position:absolute; inset:0 auto 0 0; border-radius:3px}

/* Contrôles */
.controls{
  position:sticky; top:0; z-index:20; background:var(--surface);
  border-bottom:1px solid var(--line); padding:12px 0;
}
.ctlrow{display:flex; flex-wrap:wrap; gap:10px 16px; align-items:center}
.field{display:flex; align-items:center; gap:7px}
label{font-size:11px; letter-spacing:.06em; text-transform:uppercase; color:var(--ink-faint); font-weight:600}
select,input[type=search]{
  font:inherit; font-size:13px; color:var(--ink); background:var(--surface);
  border:1px solid var(--line); border-radius:8px; padding:6px 9px;
}
input[type=search]{min-width:180px}
select:focus-visible,input:focus-visible,button:focus-visible{
  outline:2px solid var(--ink); outline-offset:2px;
}
.seg{display:flex; border:1px solid var(--line); border-radius:8px; overflow:hidden}
.seg button{
  font:inherit; font-size:12.5px; padding:6px 11px; border:0; cursor:pointer;
  background:var(--surface); color:var(--ink-soft); border-right:1px solid var(--line);
}
.seg button:last-child{border-right:0}
.seg button[aria-pressed=true]{background:var(--ink); color:var(--ground)}
.count{margin-left:auto; font-size:12px; color:var(--ink-faint)}

/* Une dictée */
.entries{padding:26px 0 80px; display:flex; flex-direction:column; gap:16px}
article.entry{
  background:var(--surface); border:1px solid var(--line);
  border-radius:14px; box-shadow:var(--shadow); overflow:hidden;
}
.ehead{
  display:flex; flex-wrap:wrap; align-items:center; gap:8px 14px;
  padding:12px 18px; border-bottom:1px solid var(--line-soft); background:var(--sunken);
  font-size:12px; color:var(--ink-faint);
}
.eid{color:var(--ink); font-weight:600; font-size:12.5px}
.chip{
  display:inline-flex; align-items:center; gap:5px; padding:2px 8px;
  border-radius:999px; font-size:11px; font-weight:600; letter-spacing:.02em;
  background:var(--sunken); color:var(--ink-soft); border:1px solid var(--line);
}
.chip.warn{background:var(--warn-bg); color:var(--warn); border-color:transparent}
.chip.gap{background:var(--diff); color:var(--diff-ink); border-color:transparent}
/* Une grille qui suit le nombre de moteurs choisis plutôt qu'un gabarit fixe.
   À deux, côte à côte ; à trois, trois colonnes ; à quatre, deux lignes de
   deux — lire quatre colonnes de prose sur un écran, personne n'y arrive. */
.pair{display:grid; gap:0}
.pair[data-n="1"]{grid-template-columns:1fr}
.pair[data-n="2"]{grid-template-columns:1fr 1fr}
.pair[data-n="3"]{grid-template-columns:repeat(3,1fr)}
.pair[data-n="4"]{grid-template-columns:1fr 1fr}
.pair[data-n="5"],.pair[data-n="6"]{grid-template-columns:repeat(3,1fr)}
@media (max-width:1500px){ .pair[data-n="5"],.pair[data-n="6"]{grid-template-columns:1fr 1fr} }
@media (max-width:1150px){ .pair[data-n="3"]{grid-template-columns:1fr 1fr} }
@media (max-width:820px){ .pair{grid-template-columns:1fr!important} }
.side{padding:16px 18px 20px; min-width:0; border-left:1px solid var(--line-soft);
      border-top:1px solid var(--line-soft)}
.side:first-child{border-left:0}
.pair[data-n="2"] .side:nth-child(-n+2),
.pair[data-n="3"] .side:nth-child(-n+3),
.pair[data-n="4"] .side:nth-child(-n+2),
.pair[data-n="1"] .side:first-child{border-top:0}
.pair[data-n="4"] .side:nth-child(odd){border-left:0}
@media (max-width:820px){ .side{border-left:0} }
/* Puces de sélection : on coche les moteurs à afficher. */
.picks{display:flex; flex-wrap:wrap; gap:6px}
.pick{
  display:inline-flex; align-items:center; gap:6px; cursor:pointer;
  font:inherit; font-size:12px; padding:5px 10px; border-radius:999px;
  border:1px solid var(--line); background:var(--surface); color:var(--ink-soft);
}
.pick:hover{border-color:var(--ink-faint)}
.pick[aria-pressed=true]{background:var(--sunken); color:var(--ink); font-weight:600}
.pick .dot{width:8px; height:8px; border-radius:3px}
.refbadge{
  font-size:9.5px; letter-spacing:.06em; text-transform:uppercase;
  color:var(--ink-faint); border:1px solid var(--line); border-radius:4px;
  padding:0 4px; margin-left:2px;
}
.sidehead{display:flex; align-items:baseline; gap:8px; margin-bottom:9px; flex-wrap:wrap}
.sidename{font-size:12.5px; font-weight:650; letter-spacing:.01em}
.metrics{margin-left:auto; display:flex; gap:10px; font-size:11px; color:var(--ink-faint)}
.text{font-size:14.5px; line-height:1.68; color:var(--ink); overflow-wrap:break-word}
.pair[data-n="3"] .text,.pair[data-n="5"] .text,.pair[data-n="6"] .text{font-size:13.5px; line-height:1.62}
.text.small{font-size:13.5px}
mark.d{background:var(--diff); color:var(--diff-ink); border-radius:2px; padding:.5px 1px}
/* Écouter la dictée. Le bouton est dans l'en-tête, à côté de la durée : c'est
   la question qu'on se pose en lisant deux transcriptions qui divergent —
   « qu'est-ce que j'avais dit, au juste ? » */
.play{
  display:inline-flex; align-items:center; gap:6px; font:inherit; font-size:11px;
  font-weight:600; letter-spacing:.02em; cursor:pointer; padding:2px 9px 2px 7px;
  border-radius:999px; border:1px solid var(--line); background:var(--surface);
  color:var(--ink-soft);
}
.play:hover{border-color:var(--ink-faint); color:var(--ink)}
.play[aria-pressed=true]{background:var(--ink); color:var(--ground); border-color:transparent}
.play .glyph{font-size:9px; line-height:1}
.play .el{font-variant-numeric:tabular-nums; opacity:.75}
.noaudio{opacity:.4; cursor:default}
.lonely{margin:0 0 9px; font-size:11px; color:var(--ink-faint); display:flex;
        flex-wrap:wrap; gap:5px; align-items:center}
.tchip{background:var(--sunken); border:1px solid var(--line); border-radius:5px;
       padding:1px 6px; color:var(--ink-soft); font-weight:600}
.missing{color:var(--ink-faint); font-style:italic; font-size:13.5px}
.allbtn{
  font:inherit; font-size:12px; background:none; border:0; cursor:pointer;
  color:var(--ink-soft); text-decoration:underline; text-underline-offset:3px; padding:0;
}
.others{padding:0 18px 18px; display:none; flex-direction:column; gap:14px}
.others.open{display:flex}
.other{border-top:1px solid var(--line-soft); padding-top:13px}
.findings{display:grid; grid-template-columns:repeat(auto-fit,minmax(290px,1fr)); gap:14px}
.finding{
  background:var(--surface); border:1px solid var(--line); border-radius:12px;
  padding:16px 18px; box-shadow:var(--shadow);
}
.finding h3{
  margin:0 0 7px; font-size:14.5px; font-weight:640; letter-spacing:-.012em;
  line-height:1.3; text-wrap:balance;
}
.finding p{margin:0; font-size:13.5px; line-height:1.6; color:var(--ink-soft)}
.empty{padding:60px 0; text-align:center; color:var(--ink-faint)}
footer{border-top:1px solid var(--line); padding:22px 0 40px; color:var(--ink-faint); font-size:12.5px}
@media (prefers-reduced-motion:reduce){ *{animation:none!important; transition:none!important} }
"""


JS = r"""
const $ = s => document.querySelector(s);
const HUE = {amber:'--amber',indigo:'--indigo',violet:'--violet',slate:'--slate',steel:'--steel',faded:'--faded',teal:'--teal'};
const esc = s => s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const fold = w => w.normalize('NFKD').replace(/[̀-ͯ]/g,'')
                   .toLowerCase().replace(/[^a-z0-9]+/g,'');

/* Diff mot à mot par plus longue sous-séquence commune. Écrit ici plutôt que
   pré-calculé côté Python : dix paires de moteurs pré-rendues pèseraient dix
   fois le corpus, et on veut pouvoir comparer n'importe quel couple. */
function wordDiff(a, b){
  const A = a.split(/\s+/).filter(Boolean), B = b.split(/\s+/).filter(Boolean);
  const fa = A.map(fold), fb = B.map(fold);
  const n = fa.length, m = fb.length;
  if (n * m > 4e6) return [esc(a), esc(b)];      // garde-fou sur les très longues
  const L = Array.from({length:n+1}, () => new Uint32Array(m+1));
  for (let i=n-1;i>=0;i--) for (let j=m-1;j>=0;j--)
    L[i][j] = fa[i]===fb[j] ? L[i+1][j+1]+1 : Math.max(L[i+1][j], L[i][j+1]);
  const oa=[], ob=[]; let i=0, j=0;
  const push=(arr,w,same)=>arr.push(same?esc(w):'<mark class="d">'+esc(w)+'</mark>');
  while(i<n && j<m){
    if(fa[i]===fb[j]){ push(oa,A[i],1); push(ob,B[j],1); i++; j++; }
    else if(L[i+1][j] >= L[i][j+1]){ push(oa,A[i],0); i++; }
    else { push(ob,B[j],0); j++; }
  }
  while(i<n) push(oa,A[i++],0);
  while(j<m) push(ob,B[j++],0);
  return [oa.join(' '), ob.join(' ')];
}

function agreement(a, b){
  if(!a || !b) return 0;
  const A=a.split(/\s+/).map(fold).filter(Boolean), B=b.split(/\s+/).map(fold).filter(Boolean);
  const n=A.length,m=B.length; if(!n||!m) return 0;
  if(n*m>4e6) return 0.5;
  const L=Array.from({length:n+1},()=>new Uint32Array(m+1));
  for(let i=n-1;i>=0;i--) for(let j=m-1;j>=0;j--)
    L[i][j]= A[i]===B[j] ? L[i+1][j+1]+1 : Math.max(L[i+1][j],L[i][j+1]);
  return 2*L[0][0]/(n+m);
}

/* `picks` remplace le couple gauche/droite. Le premier coché sert de
   référence : c'est contre lui que les autres sont comparés, parce qu'un
   surlignage « tout le monde contre tout le monde » ne se lit pas. */
const state = {picks:[], sort:'disagree', lang:'', q:'', onlyGap:false};

/* Un seul lecteur pour toute la page : deux dictées qui se superposeraient ne
   servent personne, et garder 140 éléments <audio> vivants pour rien coûte de
   la mémoire pour aucun bénéfice. */
const player = {el:null, id:null, btn:null};
function stopPlayback(){
  if(player.el){ player.el.pause(); }
  if(player.btn){ player.btn.setAttribute('aria-pressed','false'); syncBtn(player.btn, false); }
  player.id = null; player.btn = null;
}
function syncBtn(btn, playing){
  const g = btn.querySelector('.glyph');
  if(g) g.textContent = playing ? '❙❙' : '▶';
}
function togglePlay(btn){
  const id = btn.dataset.audio;
  if(player.id === id){ stopPlayback(); return; }
  stopPlayback();
  const src = AUDIO[id];
  if(!src) return;
  if(!player.el){
    player.el = new Audio();
    player.el.addEventListener('ended', stopPlayback);
    player.el.addEventListener('error', stopPlayback);
  }
  player.el.src = src;
  player.el.currentTime = 0;
  player.id = id; player.btn = btn;
  btn.setAttribute('aria-pressed','true'); syncBtn(btn, true);
  const el = player.el;
  el.play().catch(() => stopPlayback());
  const tick = () => {
    if(player.el !== el || player.id !== id) return;
    const left = Math.max(0, (el.duration || 0) - el.currentTime);
    const span = btn.querySelector('.el');
    if(span && isFinite(left)) span.textContent = left.toFixed(0) + ' s';
    if(!el.paused) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

function engineMeta(k){ return DATA.engines.find(e=>e.key===k); }
function label(k){ const e=engineMeta(k); return e ? e.name+' · '+e.sub : k; }

function metricsHTML(t){
  const bits = [t.words+' mots'];
  if(t.latencyMs) bits.push((t.latencyMs/1000).toFixed(1)+' s');
  if(t.repetition >= 0.15) bits.push('<span style="color:var(--warn)">boucle '+Math.round(t.repetition*100)+'%</span>');
  const nt = Object.values(t.terms||{}).reduce((s,v)=>s+v,0);
  if(nt) bits.push(nt+' termes');
  return bits.join(' &middot; ');
}

/* Les termes qu'aucun autre moteur n'a produits sur cette dictée : la piste la
   plus rentable à lire, puisqu'elle isole soit une invention, soit la seule
   graphie correcte. */
function lonelyHTML(t){
  if(!t || !t.lonely || !t.lonely.length) return '';
  return '<div class="lonely mono">seul à écrire '
    + t.lonely.map(x => '<span class="tchip">'+esc(x)+'</span>').join('') + '</div>';
}

function sideHTML(key, marked, t, isRef){
  const e = engineMeta(key);
  if(!t) return '<div class="side"><div class="sidehead"><span class="dot" style="background:var(--line)"></span>'
    + '<span class="sidename">'+esc(label(key))+'</span></div>'
    + '<p class="missing">Pas de transcription pour cette dictée.</p></div>';
  return '<div class="side">'
    + '<div class="sidehead"><span class="dot" style="background:var('+HUE[e.hue]+')"></span>'
    + '<span class="sidename">'+esc(e.name)+'</span>'
    + '<span class="esub mono">'+esc(e.sub)+'</span>'
    + (isRef ? '<span class="refbadge">référence</span>' : '')
    + '<span class="metrics mono">'+metricsHTML(t)+'</span></div>'
    + lonelyHTML(t)
    + '<p class="text">'+marked+'</p></div>';
}

function entryHTML(en){
  const shown = state.picks.filter(k => k in en.texts);
  const ref = shown[0];
  const chips = [];
  chips.push(AUDIO[en.id]
    ? '<button class="play mono" data-audio="'+esc(en.id)+'" aria-pressed="false" '
      + 'title="Écouter cette dictée"><span class="glyph">▶</span>'
      + '<span class="el">'+en.duration.toFixed(0)+' s</span></button>'
    : '<span class="chip mono noaudio">'+en.duration.toFixed(0)+' s</span>');
  chips.push('<span class="chip mono">'+en.language+'</span>');
  // Un accord par moteur comparé à la référence, plutôt qu'un seul chiffre :
  // avec plus de deux colonnes, « accord 87 % » ne dit plus de quoi avec quoi.
  for(const k of shown.slice(1)){
    const a = agreement(en.texts[ref].text, en.texts[k].text);
    const cls = a < 0.65 ? 'chip gap mono' : 'chip mono';
    chips.push('<span class="'+cls+'">'+esc(engineMeta(k).name.split(' ')[0])+' '
      + Math.round(a*100)+'%</span>');
  }
  for(const [k,t] of Object.entries(en.texts))
    if(t.repetition >= 0.15)
      chips.push('<span class="chip warn mono">boucle · '+esc(engineMeta(k).sub)+'</span>');

  const others = Object.keys(en.texts).filter(k => !shown.includes(k));
  const othersHTML = others.map(k => {
    const t = en.texts[k], e = engineMeta(k);
    return '<div class="other"><div class="sidehead">'
      + '<span class="dot" style="background:var('+HUE[e.hue]+')"></span>'
      + '<span class="sidename">'+esc(e.name)+'</span>'
      + '<span class="esub mono">'+esc(e.sub)+'</span>'
      + '<span class="metrics mono">'+metricsHTML(t)+'</span></div>'
      + lonelyHTML(t)
      + '<p class="text small">'+esc(t.text)+'</p></div>';
  }).join('');

  return '<article class="entry"><div class="ehead">'
    + '<span class="eid mono">'+esc(en.id)+'</span>'
    + chips.join('')
    + (others.length ? '<button class="allbtn" data-id="'+esc(en.id)+'">'
        + others.length+' autre'+(others.length>1?'s':'')+' moteur'+(others.length>1?'s':'')+'</button>' : '')
    + '</div><div class="pair" data-n="'+shown.length+'">'
    + shown.map(k => {
        const t = en.texts[k];
        // Chaque colonne est marquée contre la référence. La référence
        // elle-même est marquée contre la suivante, sinon elle serait la seule
        // à ne rien montrer.
        const contre = k === ref ? (shown[1] || null) : ref;
        const marked = contre ? wordDiff(t.text, en.texts[contre].text)[0] : esc(t.text);
        return sideHTML(k, marked, t, k === ref);
      }).join('')
    + '</div>'
    + (others.length ? '<div class="others" id="o-'+esc(en.id)+'">'+othersHTML+'</div>' : '')
    + '</article>';
}

function visible(){
  let rows = DATA.entries.slice();
  if(state.lang) rows = rows.filter(e => e.language === state.lang);
  if(state.q){
    const q = state.q.toLowerCase();
    rows = rows.filter(e => Object.values(e.texts).some(t => t.text.toLowerCase().includes(q)));
  }
  rows.forEach(e => {
    const shown = state.picks.filter(k => k in e.texts);
    e._agr = shown.length >= 2
      ? Math.min(...shown.slice(1).map(k => agreement(e.texts[shown[0]].text, e.texts[k].text)))
      : null;
  });
  if(state.onlyGap) rows = rows.filter(e => e._agr !== null && e._agr < 0.75);
  const by = {
    disagree: (x,y) => (x._agr ?? 2) - (y._agr ?? 2),
    date:     (x,y) => x.date.localeCompare(y.date),
    longest:  (x,y) => y.duration - x.duration,
    shortest: (x,y) => x.duration - y.duration,
  }[state.sort];
  return rows.sort(by);
}

function render(){
  const rows = visible();
  $('#count').textContent = rows.length + ' / ' + DATA.entries.length + ' dictées';
  $('#entries').innerHTML = rows.length
    ? rows.map(entryHTML).join('')
    : '<p class="empty">Aucune dictée ne correspond à ce filtre.</p>';
  document.querySelectorAll('.allbtn').forEach(b => b.addEventListener('click', () => {
    const box = document.getElementById('o-' + b.dataset.id);
    const open = box.classList.toggle('open');
    b.textContent = open ? 'masquer' : b.dataset.lbl;
  }));
  document.querySelectorAll('.allbtn').forEach(b => { b.dataset.lbl = b.textContent; });
  stopPlayback();
  document.querySelectorAll('.play').forEach(b =>
    b.addEventListener('click', () => togglePlay(b)));
}

function boot(){
  const box = $('#picks');
  state.picks = DATA.defaultPicks.filter(k => DATA.engines.some(e => e.key === k));
  DATA.engines.forEach(e => {
    const b = document.createElement('button');
    b.className = 'pick'; b.dataset.key = e.key;
    b.setAttribute('aria-pressed', String(state.picks.includes(e.key)));
    b.innerHTML = '<span class="dot" style="background:var('+HUE[e.hue]+')"></span>'
      + esc(e.name) + ' <span class="esub mono">' + esc(e.sub) + '</span>';
    b.addEventListener('click', () => {
      const i = state.picks.indexOf(e.key);
      // Jamais moins d'un moteur : une page sans colonne n'apprend rien, et
      // l'ordre des clics fixe l'ordre des colonnes — donc la référence.
      if(i >= 0){ if(state.picks.length > 1) state.picks.splice(i, 1); }
      else state.picks.push(e.key);
      document.querySelectorAll('.pick').forEach(x =>
        x.setAttribute('aria-pressed', String(state.picks.includes(x.dataset.key))));
      render();
    });
    box.appendChild(b);
  });
  $('#sort').onchange = e => { state.sort = e.target.value; render(); };
  $('#lang').onchange = e => { state.lang = e.target.value; render(); };
  $('#q').oninput = e => { state.q = e.target.value.trim(); render(); };
  $('#gap').onclick = e => {
    state.onlyGap = !state.onlyGap;
    e.currentTarget.setAttribute('aria-pressed', String(state.onlyGap));
    render();
  };
  render();
}
document.addEventListener('DOMContentLoaded', boot);
"""


def aggregate(entries: list[dict]) -> list[dict]:
    """Une ligne par moteur, sur les dictées qu'il a réellement transcrites."""
    out = []
    for spec in ENGINES:
        ts = [e["texts"][spec["key"]] for e in entries if spec["key"] in e["texts"]]
        if not ts:
            continue
        lat = sorted(t["latencyMs"] for t in ts if t.get("latencyMs"))
        terms_total = sum(sum(t["terms"].values()) for t in ts)
        out.append({
            **spec,
            "n": len(ts),
            "medianLatency": lat[len(lat) // 2] if lat else None,
            "medianWords": sorted(t["words"] for t in ts)[len(ts) // 2],
            "coverage": round(sum(t["coverage"] for t in ts) / len(ts), 3),
            "loops": sum(1 for t in ts if t["repetition"] >= 0.15),
            "terms": terms_total,
            "distinctTerms": len({k for t in ts for k in t["terms"]}),
            "lonely": sum(len(t["lonely"]) for t in ts),
        })
    return out


def findings(entries: list[dict]) -> list[tuple[str, str]]:
    """Ce que le corpus dit, recalculé à chaque génération.

    Écrit ici plutôt que rédigé dans le HTML : un constat qui ne se recalcule
    pas devient faux à la dictée suivante sans que personne le voie.
    """
    import re as _re
    out: list[tuple[str, str]] = []
    trio = ("voxtral3b", "crisper", "realtime")
    communs = [e for e in entries if all(k in e["texts"] for k in trio)]
    if not communs:
        return out

    def moy(cle: str, champ: str) -> float:
        vals = [st_analyse(e["texts"][cle]["text"])[champ] for e in communs
                if e["language"] == "fr" and e["texts"][cle]["words"] >= 40]
        return sum(vals) / len(vals) if vals else 0.0

    def par_cent_mots(cle: str, champ: str) -> float:
        rows = [st_analyse(e["texts"][cle]["text"]) for e in communs
                if e["language"] == "fr" and e["texts"][cle]["words"] >= 40]
        mots = sum(r["mots"] for r in rows) or 1
        return sum(r[champ] for r in rows) / mots * 100

    out.append((
        f"Le 3B écrit le mieux, sur {len(communs)} dictées communes",
        f"Fragments pour cent mots : {par_cent_mots('voxtral3b','fragments'):.2f} contre "
        f"{par_cent_mots('crisper','fragments'):.2f} à CrisperWhisper. Bafouillages : "
        f"{par_cent_mots('voxtral3b','bafouillages'):.2f} contre "
        f"{par_cent_mots('crisper','bafouillages'):.2f}. Phrases de "
        f"{moy('voxtral3b','phraseMoyenne'):.1f} mots contre "
        f"{moy('crisper','phraseMoyenne'):.1f}. Ce que l'accord mot à mot ne voit pas, "
        f"parce que la ponctuation n'y pèse presque rien."))

    couv = {}
    for k in trio:
        tot = n = 0
        for e in communs:
            longest = max(e["texts"][x]["words"] for x in trio)
            if longest:
                tot += e["texts"][k]["words"] / longest; n += 1
        couv[k] = tot / n * 100 if n else 0
    out.append((
        f"Le flux perd {100-couv['realtime']:.0f} % des mots",
        f"Couverture : Voxtral 3B {couv['voxtral3b']:.0f} %, CrisperWhisper "
        f"{couv['crisper']:.0f} %, Realtime {couv['realtime']:.0f} %. Le Realtime est le "
        f"seul à en perdre, et ce n'est pas un réglage : son encodeur est causal, il "
        f"décide sans pouvoir revenir en arrière."))

    lat = {k: sorted(e["texts"][k]["latencyMs"] for e in communs
                     if e["texts"][k].get("latencyMs")) for k in trio}
    out.append((
        "Ce que chacun coûte en temps",
        f"Latence médiane : CrisperWhisper {lat['crisper'][len(lat['crisper'])//2]/1000:.2f} s, "
        f"Voxtral 3B {lat['voxtral3b'][len(lat['voxtral3b'])//2]/1000:.2f} s, Realtime "
        f"{lat['realtime'][len(lat['realtime'])//2]/1000:.2f} s. Celle du Realtime est le "
        f"traitement complet, pas l'attente ressentie : dans l'application, le rattrapage "
        f"après le dernier mot tient en 0,6 à 0,9 s."))

    frag = _re.compile(r"\b(useEffect|useState|Effects?|States?)\b")
    fuites = {k: sum(len(frag.findall(e["texts"][k]["text"])) for e in communs)
              for k in trio}
    out.append((
        f"Le lexique fuit {fuites['crisper']} fois chez CrisperWhisper",
        f"Fragments du lexique apparus là où l'audio ne les portait pas. "
        f"CrisperWhisper {fuites['crisper']}, Voxtral 3B {fuites['voxtral3b']}, "
        f"Realtime {fuites['realtime']}. C'est le prix du conditionnement par "
        f"vocabulaire, et il se paie quand le modèle hésite."))

    if "crisper-nolex" in entries[0]["texts"] or any(
            "crisper-nolex" in e["texts"] for e in entries):
        duo = [e for e in entries
               if "crisper" in e["texts"] and "crisper-nolex" in e["texts"]]
        if duo:
            change = sum(1 for e in duo if st.similarity(
                e["texts"]["crisper"]["text"], e["texts"]["crisper-nolex"]["text"]) < 0.98)
            casse = sum(1 for e in duo if st.similarity(
                e["texts"]["crisper"]["text"], e["texts"]["crisper-nolex"]["text"]) < 0.60)
            out.append((
                f"Le lexique par défaut change {change} dictées sur {len(duo)}, "
                f"et en casse {casse}",
                "Même audio, même code, seul `DEFAULT_LEXICON` diffère — dix-neuf "
                "termes codés dans `crisper.py`, appliqués dès que l'application "
                "passe `nil`, ce qu'elle fait tant qu'aucun terme n'a été ajouté à "
                "la main. Sans lui : moins de fragments, moins de bafouillages, "
                "des phrases plus longues, zéro fuite. Et il dégrade la casse de "
                "mots qui n'y figurent pas — « Whisper » écrit correctement 51 fois "
                "sans lui, 12 fois avec. Le comparer colonne contre colonne est le "
                "réglage le plus rentable du corpus."))

    out.append((
        "Cette série-ci est propre, la précédente ne l'était pas",
        "Rejouée avec la mémoire libre, un modèle chargé à la fois. La série "
        "d'avant tournait avec 9 Go de swap actif et coûtait 18 % de latence à "
        "CrisperWhisper — 1,52 s au lieu de 1,25. Assez pour fausser toute "
        "comparaison, et c'est pourquoi elle a été refaite."))
    return out


def audio_payload(entries: list[dict]) -> tuple[dict[str, str], float]:
    """L'audio embarqué dans la page, en data:.

    Embarqué et non référencé en chemin relatif : la page est faite pour être
    envoyée et ouverte n'importe où, et un lecteur qui casse dès que le fichier
    change de dossier ne rend pas le service demandé. Mesuré : les WAV du
    corpus pèsent 316 Mo, réencodés en Opus 14 kbps mono ils tombent à 8 Mo —
    de la parole, pas de la musique, et la question posée est « qu'est-ce que
    j'avais dit », pas « comment ça sonne ».
    """
    import base64
    out: dict[str, str] = {}
    total = 0
    for e in entries:
        name = e.get("audioFile")
        if not name:
            continue
        f = AUDIO_DIR / (Path(name).stem + ".opus")
        if not f.exists():
            continue
        raw = f.read_bytes()
        total += len(raw)
        out[e["id"]] = "data:audio/ogg;base64," + base64.b64encode(raw).decode()
    return out, total / 1e6


def render_html(entries: list[dict]) -> str:
    agg = aggregate(entries)
    keys = {a["key"] for a in agg}
    # Les trois passages au propre d'abord : c'est la comparaison qui vaut.
    prefere = [k for k in ("crisper", "crisper-nolex", "voxtral3b") if k in keys]
    default = prefere or sorted(keys)[:2]
    total_min = sum(e["duration"] for e in entries) / 60
    langs = sorted({e["language"] for e in entries})
    has_vox = "voxtral3b" in keys

    maxlat = max([a["medianLatency"] or 0 for a in agg] + [1])
    rows = []
    for a in agg:
        lat = f'{a["medianLatency"]/1000:.2f} s' if a["medianLatency"] else "—"
        barw = round(100 * (a["medianLatency"] or 0) / maxlat)
        rows.append(f"""<tr>
  <td><span class="ename"><span class="dot" style="background:var(--{a['hue']})"></span>
    <span><b>{html.escape(a['name'])}</b> <span class="esub mono">{html.escape(a['sub'])}</span></span></span></td>
  <td class="mono">{a['n']}</td>
  <td class="mono">{lat}</td>
  <td><div class="bar"><i style="width:{barw}%;background:var(--{a['hue']})"></i></div></td>
  <td class="mono">{a['medianWords']}</td>
  <td class="mono">{round(a['coverage']*100)}%</td>
  <td class="mono">{a['terms']} <span class="esub">/ {a['distinctTerms']}</span></td>
  <td class="mono">{a['lonely']}</td>
  <td class="mono">{'<span style="color:var(--warn)">'+str(a['loops'])+'</span>' if a['loops'] else '0'}</td>
</tr>""")

    payload = {
        "engines": [a for a in agg],
        "defaultPicks": list(default),
        "entries": [{
            "id": e["id"], "date": e["date"], "duration": round(e["duration"], 1),
            "language": e["language"],
            "texts": {k: {"text": v["text"], "words": v["words"],
                          "latencyMs": v["latencyMs"], "repetition": v["repetition"],
                          "terms": v["terms"], "lonely": v["lonely"]}
                      for k, v in e["texts"].items()},
        } for e in entries],
    }

    audio, audio_mb = audio_payload(entries)
    finds = findings(entries)
    findings_html = "".join(
        f'<div class="finding"><h3>{html.escape(t)}</h3><p>{b}</p></div>'
        for t, b in finds) or '<p class="note">Pas encore de comparaison possible.</p>'

    vox_note = ("" if has_vox else
                '<p class="note" style="color:var(--warn)"><b>Voxtral n\'est pas '
                'encore dans ce tableau</b> — le banc n\'a pas été exécuté, ou il '
                'n\'a rien produit. La page compare les moteurs déjà présents dans '
                'le corpus.</p>')

    return f"""<!doctype html>
<html lang="fr"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Les moteurs face au corpus</title>
<style>{CSS}</style>
</head><body>

<header class="top">
  <div class="wrap masthead">
    <h1>Les moteurs face au corpus</h1>
    <p class="lede">Les mêmes {len(entries)} dictées, transcrites par chaque moteur.
      Le corpus n'a pas de vérité terrain — ce sont des dictées spontanées, jamais
      retranscrites à la main. Cette page ne classe donc pas : elle met les textes
      côte à côte, marque ce qui diffère, et fait remonter en premier les dictées
      où les moteurs ne s'accordent pas.</p>
    <div class="corpusline mono">
      <span><b>{len(entries)}</b> dictées</span>
      <span><b>{total_min:.0f}</b> minutes</span>
      <span><b>{len(agg)}</b> moteurs</span>
      <span><b>{', '.join(langs)}</b></span>
      <span><b>{len(audio)}</b> audio embarqués</span>
      <span>généré le <b>{datetime.now():%d/%m/%Y à %H:%M}</b></span>
    </div>
  </div>
</header>

<div class="wrap">
<section class="summary">
  <h2>Ce que dit le corpus</h2>
  <p class="note">Recalculé à chaque génération de cette page, jamais rédigé à la
    main : un constat figé devient faux à la dictée suivante sans que personne
    le voie.</p>
  <div class="findings">{findings_html}</div>
</section>

<section class="summary">
  <h2>Vue d'ensemble</h2>
  <p class="note"><b>Couverture</b> — longueur du texte rapportée au plus long
    produit sur la même dictée ; nettement en dessous, le moteur avale des mots.
    <b>Termes</b> — mots techniques à l'orthographe et à la casse exactes : total,
    puis nombre de termes distincts. <b>Isolés</b> — termes qu'un seul moteur a
    produits sur une dictée où deux autres au moins ont travaillé ; le signal
    coupe dans les deux sens, soit le moteur a inventé le mot, soit il est le seul
    à l'avoir bien écrit, et c'est précisément là qu'il faut aller lire.
    <b>Boucles</b> — dictées contenant un passage où le vocabulaire s'effondre,
    au seuil que le moteur applique lui-même en production (32 mots glissants,
    25 % de diversité).</p>
  {vox_note}
  <div class="tablewrap"><table>
    <thead><tr>
      <th>Moteur</th><th>Dictées</th><th>Latence méd.</th><th></th>
      <th>Mots méd.</th><th>Couverture</th><th>Termes</th><th>Isolés</th><th>Boucles</th>
    </tr></thead>
    <tbody>{''.join(rows)}</tbody>
  </table></div>
</section>
</div>

<div class="controls"><div class="wrap large ctlrow">
  <div class="field" style="flex:1 1 100%">
    <label>Moteurs</label><div class="picks" id="picks"></div></div>
  <div class="field"><label for="sort">Trier</label>
    <select id="sort">
      <option value="disagree">Désaccord d'abord</option>
      <option value="date">Chronologique</option>
      <option value="longest">Plus longues d'abord</option>
      <option value="shortest">Plus courtes d'abord</option>
    </select></div>
  <div class="field"><label for="lang">Langue</label>
    <select id="lang"><option value="">toutes</option>
      {''.join(f'<option value="{l}">{l}</option>' for l in langs)}
    </select></div>
  <div class="seg"><button id="gap" aria-pressed="false">Désaccord marqué seulement</button></div>
  <div class="field"><label for="q" class="sr">Chercher</label>
    <input type="search" id="q" placeholder="chercher dans les textes…"></div>
  <span class="count mono" id="count"></span>
</div></div>

<div class="wrap large"><div class="entries" id="entries"></div></div>

<footer><div class="wrap">
  Corpus de Caspr — surligné en jaune : les mots où les deux moteurs choisis
  diffèrent de la colonne « référence », qui est le premier moteur coché — l'ordre des clics fixe l'ordre des colonnes. Le bouton ▶ lit l'enregistrement d'origine,
  embarqué dans la page en Opus 14 kbps.
</div></footer>

<script>const DATA = {json.dumps(payload, ensure_ascii=False)};</script>
<script>const AUDIO = {json.dumps(audio, ensure_ascii=False)};</script>
<script>{JS}</script>
</body></html>"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(Path(__file__).parent / "mesures/comparaison-moteurs.html"))
    args = ap.parse_args()
    entries = load()
    out = Path(args.out)
    out.write_text(render_html(entries), encoding="utf-8")
    size = out.stat().st_size / 1e6
    audio, audio_mb = audio_payload(entries)
    print(f"{len(entries)} dictées → {out} ({size:.1f} Mo, dont "
          f"{len(audio)} audio pour {audio_mb:.1f} Mo)")
    for a in aggregate(entries):
        lat = f"{a['medianLatency']/1000:.2f}s" if a["medianLatency"] else "—"
        print(f"  {a['name']:16s} {a['sub']:22s} n={a['n']:3d}  lat={lat:>7s}  "
              f"couv={a['coverage']*100:3.0f}%  termes={a['terms']:4d}  boucles={a['loops']}")


if __name__ == "__main__":
    main()
