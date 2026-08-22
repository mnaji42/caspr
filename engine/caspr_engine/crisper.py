"""Moteur CrisperWhisper — inférence directe, sans le runtime de Nyra.

Le package officiel n'est pas utilisé ici pour trois raisons mesurées pendant
le POC :

  * son backend CTranslate2 n'a pas de wheel Apple Silicon (Linux x86_64
    uniquement), donc sur Mac il retombe sur PyTorch de toute façon ;
  * ses protections anti-hallucination importent ``ctranslate2`` en dur et
    sont donc inactives sur Mac ;
  * son pipeline ajoute ~1,5 s de surcoût par transcription, soit deux fois
    le coût du calcul lui-même.

On refait donc le strict nécessaire : mel, encodeur, boucle greedy. Mesuré à
~0,45 s sur M4 Pro pour une dictée courte, contre ~2,3 s via le package.
"""

from __future__ import annotations

import logging
import re
import time
from dataclasses import dataclass, field

import numpy as np
import torch
import torch.nn.functional as F

from caspr_engine import prompt as prompt_mod
from caspr_engine.contract import (  # noqa: F401  (réexport)
    SAMPLE_RATE, Timings, Transcription,
)

log = logging.getLogger(__name__)

MEL_FRAMES_PER_S = 100          # le feature extractor produit un hop de 10 ms
MAX_WINDOW_S = 30.0             # limite architecturale de Whisper


# La référence, capturée avant tout correctif : `mps_linear_is_broken` doit
# interroger le noyau d'origine, pas notre remplaçant — sinon elle se compare à
# elle-même et conclut toujours que tout va bien.
_linear_origine = F.linear
_linear_defusionne = False


def mps_linear_is_broken() -> bool:
    """Le Metal de cette machine calcule-t-il faux les couches linéaires ?

    Diagnostiqué sur un Mac virtualisé, et il a fallu descendre loin. Metal y
    est disponible, le modèle s'y charge, chaque opération prise isolément est
    exacte — produit de matrices, convolution, normalisation, attention, aux
    tailles réelles de Whisper — et pourtant la transcription ne rend que du
    vide. La bissection couche par couche a montré que `k_proj` sortait juste
    quand `q_proj` et `v_proj` sortaient faux, alors que ce sont la **même**
    opération sur la **même** entrée. Leur seule différence : dans Whisper,
    `k_proj` est le seul `Linear` sans biais.

    Le noyau fautif est donc celui qui **fusionne** le produit et l'ajout du
    biais sur une entrée à trois dimensions. Sans biais il est exact ; en
    séparant `matmul` puis `+ biais`, il est exact. L'erreur est de l'ordre de
    2 % par couche — assez peu pour que les valeurs restent finies et d'allure
    plausible, assez pour qu'après trente-deux couches l'encodeur soit à 75 %
    de la vérité et que le décodeur n'y reconnaisse rien.

    D'où cette sonde, qui n'a besoin ni de modèle ni de référence sur
    processeur : les deux chemins tournent sur Metal, et sur une machine saine
    ils donnent le même résultat au bit près. Mesuré : 0,00000 sur un Mac réel,
    0,054 sur la machine virtuelle. Elle coûte des millisecondes.
    """
    try:
        g = torch.Generator().manual_seed(0)
        x = torch.randn(1, 64, 256, generator=g).to("mps")
        poids = torch.randn(256, 256, generator=g).to("mps")
        biais = torch.randn(256, generator=g).to("mps")
        fusionne = _linear_origine(x, poids, biais)
        separe = torch.matmul(x, poids.t()) + biais
        amplitude = separe.abs().max().clamp(min=1e-9)
        ecart = float((fusionne - separe).abs().max() / amplitude)
        if ecart > 0.01:
            log.warning("Metal calcule faux les couches linéaires ici "
                        "(écart %.4f entre le noyau fusionné et le calcul "
                        "séparé)", ecart)
            return True
        return False
    except Exception as exc:                       # noqa: BLE001 — on veut tout
        log.warning("Metal a refusé la sonde des couches linéaires : %s", exc)
        return False


def defuse_mps_linear() -> None:
    """Remplace le noyau fusionné par les deux opérations qu'il fusionne.

    Le repli sur le processeur marcherait aussi, mais il coûte un facteur trois
    à cinq sur une machine déjà lente. Ici on garde le GPU : seule la couche
    linéaire avec biais change de chemin, et uniquement sur Metal. Mesuré sur
    la machine virtuelle — transcription juste, même temps de chargement.

    Idempotent : la sonde peut être appelée plusieurs fois sans empiler les
    remplaçants.
    """
    global _linear_defusionne
    if _linear_defusionne:
        return

    def linear(entree, poids, biais=None):
        # Strictement limité au cas mesuré comme faux. Tout le reste — le CPU,
        # les couches sans biais, un poids de rang inattendu — repasse par le
        # noyau d'origine, qui est plus rapide et qui, lui, n'a jamais menti.
        if (biais is not None and entree.device.type == "mps"
                and poids.dim() == 2):
            return torch.matmul(entree, poids.t()) + biais
        return _linear_origine(entree, poids, biais)

    F.linear = linear
    _linear_defusionne = True
    log.warning("couches linéaires défusionnées sur Metal — contournement du "
                "noyau fautif, le GPU reste utilisé")


def resolve_device(requested: str = "auto") -> str:
    """L'accélérateur à employer, **mesuré** plutôt que supposé.

    ``mps`` était écrit en dur, ce qui tuait le service là où Metal n'existe
    pas. Ce n'est plus qu'une question de présence : la **justesse** de Metal
    est une autre question, traitée au chargement du modèle par
    `mps_linear_is_broken`, parce qu'elle se corrige au lieu d'imposer un repli.

    Un nom explicite reste honoré tel quel — c'est ce qui permet de forcer
    ``cpu`` pour comparer, ou d'essayer un backend que cette fonction ne
    connaît pas encore.
    """
    if requested != "auto":
        return requested
    if not torch.backends.mps.is_available():
        log.warning("Metal indisponible ici — repli sur le processeur, "
                    "la transcription sera nettement plus lente")
        return "cpu"
    return "mps"


def default_dtype(device: str) -> torch.dtype:
    """La précision qui va avec l'accélérateur.

    Le demi-flottant est un gain franc sur Metal, et un piège sur processeur :
    plusieurs opérateurs de l'encodeur n'ont pas d'implémentation CPU en
    ``float16`` et lèvent, et ceux qui en ont une sont plus lents qu'en
    ``float32``. Lier la précision au device évite de corriger l'un en
    laissant l'autre derrière.
    """
    return torch.float32 if device == "cpu" else torch.float16

# En dessous de 15 s la troncature devient imprévisible : mesuré sur clips
# courts, un échantillon restait intact jusqu'à 4 s quand un autre se
# dégradait dès 10 s ("Tu as oublié" -> "State a oublié"). 15 s est le
# plancher où la sortie est restée strictement identique à la fenêtre pleine.
MIN_WINDOW_S = 15.0

# Découpage long-format. Calibré contre des frontières connues : à 0,35 s on
# ne retrouvait que 2 coupes sur 7, à 0,20 s les 7. Les pauses de la parole
# spontanée sont bien plus brèves qu'on ne l'imagine.
MIN_PAUSE_S = 0.20
# Part de l'écart fond/voix au-dessus de laquelle on considère qu'il y a
# parole. Trop bas, les pauses passent inaperçues ; trop haut, chaque syllabe
# devient une frontière.
SILENCE_RATIO = 0.15
# Longueur minimale d'un segment : couper trop court multiplie les appels au
# modèle sans rien gagner.
MIN_SEGMENT_S = 5.0
# Progression minimale par fenêtre en long-format, pour ne jamais piétiner.
MIN_ADVANCE_S = 1.0
# Pas des tokens temporels de Whisper.
TIMESTAMP_STEP_S = 0.02
# Mots repris d'un segment à l'autre via <ctx>…<ectx>.
CONTEXT_WORDS = 12

# --- détection de parole ---------------------------------------------------
# En dessous, on considère qu'aucun son exploitable n'a été capté.
ABSOLUTE_SILENCE = 1e-4
# Dispersion minimale de l'énergie, en décibels, pour qualifier de la parole.
# Calibré contre des mesures : tous les bruits testés restent sous 2 dB, toute
# la parole réelle dépasse 8 dB. Le seuil est placé au milieu de cet écart,
# côté permissif — rejeter une dictée réelle coûte bien plus cher à
# l'utilisateur que transcrire quelques secondes de bruit.
SPEECH_MODULATION_DB = 4.0
# Part minimale de trames sonores. La modulation seule ne suffit pas : un
# claquement isolé dans le silence produit un écart-type énorme sans être de
# la parole. Il faut aussi une certaine *quantité* de son.
MIN_VOICED_RATIO = 0.04

# --- garde-fou anti-boucle -------------------------------------------------
# Taille maximale de motif surveillée, en tokens.
MAX_NGRAM_SIZE = 8
# Au-delà, on refuse le token : trois répétitions consécutives peuvent être
# légitimes ("non non non"), quatre relèvent de la boucle.
MAX_NGRAM_REPEATS = 3
# Nombre de tokens de repli examinés quand le meilleur enclenche une boucle.
LOOP_ESCAPE_CANDIDATES = 5

# --- garde-fou anti-effondrement ------------------------------------------
# Le contrôle de n-grammes ci-dessus exige des répétitions *exactement*
# consécutives et identiques. Constaté sur une dictée réelle de 80 s, le modèle
# passe juste en dessous à chaque échelle : « And. You. You. You. » puis
# « And. You. You. », etc. Rejoué à travers le garde-fou, ce décrochage de
# 82 tokens n'en a fait refuser aucun, et le texte inséré contenait une
# quarantaine de répétitions.
#
# On ajoute donc un critère qui ne dépend d'aucune périodicité : la diversité
# du vocabulaire sur une fenêtre glissante. Une boucle appauvrit le vocabulaire
# quelle que soit sa forme.
#
# Calibré sur du texte réel — dictées du corpus, README du dépôt, et de la
# parole volontairement répétitive (« non non non non », « attends attends
# attends », énumérations, bégaiements). Aucun de ces textes ne descend sous
# 0,41 ; le décrochage observé tombe à 0,09. Le seuil est placé au milieu.
LOOP_WINDOW_TOKENS = 32
MIN_TOKEN_DIVERSITY = 0.25

# --- dernier filet, au niveau des mots -------------------------------------
# Calibré sur les 86 dictées du corpus. Voir `_guard_loops` pour le pourquoi.
TOKEN_RE = re.compile(r"\S+")
WORD_RE = re.compile(r"\w+(?:'\w+)?")
# Plus long motif dont on surveille la répétition.
MAX_LOOP_PATTERN_WORDS = 6
# À partir de combien de mots un motif est-il « long » ? Mesuré : sur tout le
# corpus, un motif d'un ou deux mots répété trois fois est de la parole réelle
# (« gros gros gros », « un un ») ; à trois mots ou plus, les 7 cas relevés
# sont tous des hallucinations.
LONG_PATTERN_WORDS = 3
MAX_REPEATS_SHORT_PATTERN = 3
MAX_REPEATS_LONG_PATTERN = 2
# Part de mots supprimés au-delà de laquelle il ne restait plus de contenu.
MAX_LOOP_SHARE = 0.5
# Diversité minimale d'une sortie courte. Hallucinations mesurées à 0,29 et
# 0,38 ; la phrase légitime la plus pauvre du corpus est à 0,56.
SHORT_MIN_WORDS = 6
SHORT_MAX_WORDS = 40
MIN_SHORT_DIVERSITY = 0.45

# Marqueurs de disfluence émis en mode verbatim.
DISFLUENCY_RE = re.compile(
    r"\[(UM|UH|laughter|sniff|throatclearing|cough|sigh|breath|lipsmack|"
    r"yawn|noise|crying|fart|scream|sneeze)\]"
)
PROMPT_ARTIFACT_RE = re.compile(
    r"\[(verbatim|intended)_\d+\]|<htx>.*?<ehtx>|<ctx>.*?<ectx>|<vtx>.*?<evtx>",
    re.DOTALL,
)

# Lexique volontairement court, et c'est mesuré.
#
# Il avait grossi jusqu'à 36 termes au fil des ratés constatés. Comparaison A/B
# sur voix réelle : à 36 termes le modèle perd des virgules — « Dans Next.js
# j'ai envie » au lieu de « Dans Next.js, j'ai envie », « le component sinon »
# au lieu de « le component, sinon ». Un prompt plus long dilue le contexte et
# pousse vers un style télégraphique.
#
# ## Il n'y a plus de lexique par défaut, et c'est mesuré
#
# Ce fichier en portait un — dix-neuf termes de développement web, appliqués
# dès que l'appelant passait `hotwords=None`. L'application ne l'atteignait
# pas : elle envoie toujours une liste explicite, vide tant que personne n'a
# ajouté de terme. Mais tout autre appelant y tombait, et le banc de ce projet
# y est tombé.
#
# Rejoué sur 173 dictées réelles, avec et sans ces dix-neuf termes :
#
#     fragments/100 mots   0,25 avec   →   0,19 sans
#     bafouillages         0,43        →   0,26
#     phrase moyenne       16,0 mots   →   17,6
#     fuites du lexique    4           →   0
#
# Cinquante-trois pour cent des textes changent, quatre divergent franchement,
# et les quatre sont réparés par la suppression. Il ne dégrade pas la phrase,
# il la remplace : « Effect the button functions. » là où l'audio dit « Ça ne
# fonctionne plus du tout, je sais pas pourquoi. »
#
# Le plus contre-intuitif tient à la casse. « Whisper », qui ne figurait pas
# dans la liste, était écrit correctement 51 fois sans elle et 12 fois avec :
# le prompt perturbe la casse au-delà de ses propres termes.
#
# Ce que ça ne dit pas, c'est que le conditionnement lexical soit inutile. Les
# 94 % de termes préservés du README ont été mesurés sur huit clips choisis,
# avec un lexique adapté à eux. Ce qui est mesuré ici, c'est qu'un lexique que
# personne n'a choisi coûte plus qu'il ne rapporte sur de la parole réelle.
#
# `hotwords=None` veut donc dire « aucun lexique », et plus « celui d'ici ».


class CrisperWhisperEngine:
    """Charge le modèle une fois, transcrit à la demande.

    Le modèle reste chaud : les ~8 s de chargement sont payées au démarrage du
    service, pas à chaque dictée.
    """

    def __init__(
        self,
        model_id: str = "nyralabs/CrisperWhisper2.0_turbo",
        device: str = "auto",
        dtype: torch.dtype | None = None,
        beam_size: int = 1,
    ) -> None:
        # Faisceau désactivé par défaut : mesuré sur voix réelle, il produit
        # un texte *strictement identique* au glouton pour 60 % de latence en
        # plus. Le paramètre reste exposé pour re-mesurer sur d'autres voix.
        self.beam_size = beam_size
        self.model_id = model_id
        # Résolu ici et pas au chargement : `self.device` est lu par le `ping`
        # du service, donc l'application doit pouvoir l'afficher avant même
        # qu'un modèle soit chargé.
        self.device = resolve_device(device)
        # La précision suit le device dès qu'on ne l'impose pas.
        self.dtype = dtype if dtype is not None else default_dtype(self.device)
        self._model = None
        self._processor = None
        self._eos = -1
        self._timestamp_begin = -1

    # -- cycle de vie -------------------------------------------------

    def load(self) -> float:
        from transformers import WhisperForConditionalGeneration, WhisperProcessor

        # Avant de charger quoi que ce soit : sur certaines machines Metal
        # calcule faux les couches linéaires, sans rien signaler. Cf.
        # `mps_linear_is_broken` — la panne se voit uniquement à la sortie du
        # modèle, qui est vide.
        if self.device == "mps" and mps_linear_is_broken():
            defuse_mps_linear()

        t0 = time.perf_counter()
        self._model = (
            WhisperForConditionalGeneration
            .from_pretrained(self.model_id, dtype=self.dtype)
            .to(self.device)
            .eval()
        )
        self._processor = WhisperProcessor.from_pretrained(self.model_id)
        tok = self._processor.tokenizer
        self._eos = tok.convert_tokens_to_ids("<|endoftext|>")
        # Premier token temporel : tout id au-dessus encode un instant.
        self._timestamp_begin = tok.convert_tokens_to_ids("<|0.00|>")
        elapsed = time.perf_counter() - t0
        log.info("modèle %s chargé en %.1fs sur %s", self.model_id, elapsed, self.device)
        self._warmup()
        return elapsed

    def _warmup(self) -> None:
        """Force la compilation des kernels Metal.

        Sans ça la première dictée réelle paie ~0,5 s de compilation. Trois
        passes suffisent à stabiliser les temps (mesuré pendant le POC).
        """
        # Bruit léger plutôt que du silence : le VAD rejetterait un signal
        # nul et le warmup ne compilerait alors aucun kernel.
        rng = np.random.default_rng(0)
        noise = (rng.standard_normal(int(MIN_WINDOW_S * SAMPLE_RATE)) * 0.02).astype(np.float32)
        for _ in range(3):
            self._transcribe_window(noise)
        log.info("warmup terminé")

    @property
    def loaded(self) -> bool:
        return self._model is not None

    # -- inférence ----------------------------------------------------

    def _sync(self) -> None:
        if self.device == "mps":
            torch.mps.synchronize()
        elif self.device == "cuda":
            torch.cuda.synchronize()

    def _window_for(self, duration_s: float) -> tuple[float, bool]:
        """Fenêtre d'encodage à utiliser, et si l'audio a dû être coupé."""
        if duration_s > MAX_WINDOW_S:
            return MAX_WINDOW_S, True
        return max(MIN_WINDOW_S, min(duration_s + 1.0, MAX_WINDOW_S)), False

    def _encode(self, mel):
        """Encode un mel plus court que 30 s.

        WhisperEncoder impose trois contraintes cohérentes entre elles :
        un contrôle de longueur exacte, ``config.max_source_positions``, et
        ``embed_positions.num_embeddings`` par lequel il indexe les positions.
        Les trois sont abaissées ensemble, le temps de l'appel. Les positions
        conservées gardent leur indice d'origine — la sémantique temporelle
        est intacte.
        """
        enc = self._model.model.encoder
        n_pos = mel.shape[-1] // 2
        saved = (
            enc.config.max_source_positions,
            enc.embed_positions.num_embeddings,
            enc.embed_positions.weight,
        )
        if n_pos < saved[1]:
            enc.config.max_source_positions = n_pos
            enc.embed_positions.num_embeddings = n_pos
            enc.embed_positions.weight = torch.nn.Parameter(
                saved[2][:n_pos].clone(), requires_grad=False
            )
        try:
            with torch.no_grad():
                return enc(mel)
        finally:
            (enc.config.max_source_positions,
             enc.embed_positions.num_embeddings,
             enc.embed_positions.weight) = saved

    @torch.no_grad()
    def _decode_beam(self, enc_out, prompt_ids: list[int], max_new: int,
                     beam_size: int) -> list[int]:
        """Décodage par faisceau.

        Le décodage glouton choisit le token le plus probable à chaque pas sans
        jamais revenir dessus. Chaque choix est défendable localement mais la
        phrase produite peut être absurde : « en utilisant » ressort en « en un
        vivant », suite de tokens plausibles un à un, insensée mise bout à bout.
        Le faisceau garde plusieurs hypothèses et tranche sur le score de la
        séquence entière, ce qui rattrape précisément ce type d'erreur.

        Coût réel modeste ici : le décodage ne pèse que ~0,15 s sur une dictée
        courte, contre ~0,45 s pour l'encodeur qui, lui, ne tourne qu'une fois.
        """
        beams = enc_out.last_hidden_state.expand(beam_size, -1, -1).contiguous()
        expanded = type(enc_out)(last_hidden_state=beams)

        ids = torch.tensor([prompt_ids] * beam_size, device=self.device)
        # Seule la première hypothèse est active au départ : sans ça, les
        # beam_size copies identiques produiraient beam_size fois la même suite.
        scores = torch.full((beam_size,), float("-inf"), device=self.device)
        scores[0] = 0.0

        finished: list[tuple[float, list[int]]] = []
        sequences: list[list[int]] = [[] for _ in range(beam_size)]
        past = None
        cur = ids

        for step in range(max_new):
            out = self._model(encoder_outputs=expanded, decoder_input_ids=cur,
                              past_key_values=past, use_cache=True)
            past = out.past_key_values
            logprobs = torch.log_softmax(out.logits[:, -1].float(), dim=-1)

            total = scores.unsqueeze(1) + logprobs
            flat = total.view(-1)
            top_scores, top_flat = flat.topk(beam_size)
            beam_index = top_flat // logprobs.shape[-1]
            token_index = top_flat % logprobs.shape[-1]

            new_sequences: list[list[int]] = []
            keep: list[int] = []
            keep_scores: list[float] = []
            keep_tokens: list[int] = []

            for score, origin, token in zip(top_scores.tolist(),
                                            beam_index.tolist(),
                                            token_index.tolist()):
                seq = sequences[origin] + [token]
                if token == self._eos:
                    # Normaliser par la longueur, sinon les phrases courtes
                    # gagnent systématiquement : leur score cumule moins de
                    # termes négatifs.
                    finished.append((score / max(len(seq), 1), seq[:-1]))
                else:
                    new_sequences.append(seq)
                    keep.append(origin)
                    keep_scores.append(score)
                    keep_tokens.append(token)

            if not new_sequences or len(finished) >= beam_size:
                break

            # Recompléter le faisceau pour garder une forme de lot constante,
            # ce qu'exige la réorganisation du cache.
            while len(new_sequences) < beam_size:
                new_sequences.append(new_sequences[-1])
                keep.append(keep[-1])
                keep_scores.append(float("-inf"))
                keep_tokens.append(keep_tokens[-1])

            sequences = new_sequences
            scores = torch.tensor(keep_scores, device=self.device)
            past.reorder_cache(torch.tensor(keep, device=self.device))
            cur = torch.tensor([[t] for t in keep_tokens], device=self.device)

        if finished:
            return max(finished, key=lambda item: item[0])[1]
        return sequences[0] if sequences else []

    @staticmethod
    def _repeats_ngram(tokens: list[int], candidate: int) -> bool:
        """Ce token créerait-il une répétition en boucle ?

        Whisper part parfois en boucle et répète un fragment jusqu'à épuiser
        le budget de tokens. CrisperWhisper expose des protections contre ça,
        mais uniquement dans son backend CTranslate2 — indisponible sur Apple
        Silicon. Il faut donc les refaire ici.

        On vérifie si accepter ``candidate`` produirait plus de
        ``MAX_NGRAM_REPEATS`` copies consécutives d'un même motif. Les motifs
        courts comme longs sont couverts : « le le le » comme la répétition
        d'une phrase entière.
        """
        sequence = tokens + [candidate]
        for size in range(1, MAX_NGRAM_SIZE + 1):
            if len(sequence) < size * (MAX_NGRAM_REPEATS + 1):
                continue
            tail = sequence[-size:]
            repeats = 1
            position = len(sequence) - size
            while position >= size and sequence[position - size:position] == tail:
                repeats += 1
                position -= size
            if repeats > MAX_NGRAM_REPEATS:
                return True
        return False

    @staticmethod
    def _collapsed(tokens: list[int]) -> bool:
        """Le vocabulaire s'est-il effondré sur les derniers tokens ?

        Complément indispensable à ``_repeats_ngram``, qui ne voit que les
        répétitions exactes : un décrochage dont la période varie légèrement
        lui échappe entièrement, alors qu'il produit exactement le même texte
        inutilisable.

        On ne regarde pas *quel* motif se répète, seulement combien de tokens
        distincts occupent la fenêtre. Une boucle, régulière ou non, y tombe ;
        de la parole répétitive légitime reste largement au-dessus (mesures
        en tête de fichier).
        """
        if len(tokens) < LOOP_WINDOW_TOKENS:
            return False
        window = tokens[-LOOP_WINDOW_TOKENS:]
        return len(set(window)) / LOOP_WINDOW_TOKENS < MIN_TOKEN_DIVERSITY

    @torch.no_grad()
    def _decode(self, enc_out, prompt_ids: list[int], max_new: int) -> list[int]:
        """Décodage greedy avec cache KV.

        On n'utilise pas ``model.generate()`` : sur Whisper il réécrit le
        prompt du décodeur (tokens de langue forcés, logique longform) et
        écrase les tags CrisperWhisper, ce qui produit des sorties vides.
        """
        out: list[int] = []
        cur = torch.tensor([prompt_ids], device=self.device)
        past = None
        for _ in range(max_new):
            res = self._model(
                encoder_outputs=enc_out,
                decoder_input_ids=cur,
                past_key_values=past,
                use_cache=True,
            )
            past = res.past_key_values

            logits = res.logits[0, -1]
            nxt = int(logits.argmax())
            # Si le meilleur token enclenche une boucle, on prend le suivant.
            # Quelques candidats suffisent : au-delà, c'est que le modèle n'a
            # plus rien de sensé à produire et mieux vaut s'arrêter.
            if self._repeats_ngram(out, nxt):
                ranked = torch.topk(logits, LOOP_ESCAPE_CANDIDATES).indices.tolist()
                nxt = next((t for t in ranked
                            if not self._repeats_ngram(out, t)), self._eos)
                if nxt != self._eos:
                    log.debug("boucle évitée à %d tokens", len(out))

            if nxt == self._eos:
                break
            out.append(nxt)

            # Une fois le vocabulaire effondré, le modèle ne s'en sort pas
            # seul : sur le cas observé il a répété jusqu'à épuiser son budget
            # de tokens. On coupe, et on retire la fenêtre fautive — la garder
            # reviendrait à insérer le début de la boucle dans le texte de
            # l'utilisateur. En long-format le segment suivant reprend la
            # suite ; ici on perd un fragment, ce qui vaut mieux qu'un
            # paragraphe de répétitions.
            if self._collapsed(out):
                log.warning("vocabulaire effondré à %d tokens — décodage coupé",
                            len(out))
                del out[-LOOP_WINDOW_TOKENS:]
                break

            cur = torch.tensor([[nxt]], device=self.device)
        return out

    def transcribe(
        self,
        audio: np.ndarray,
        *,
        mode: str = "intended",
        language: str = "fr",
        hotwords: list[str] | None = None,
        keep_disfluencies: bool = False,
        max_new_tokens: int = 256,
    ) -> Transcription:
        if not self.loaded:
            raise RuntimeError("moteur non chargé : appeler load() d'abord")

        audio = np.asarray(audio, dtype=np.float32)

        # Filtrer ici plutôt que de jeter le résultat après coup : sur du
        # silence, Whisper invente une phrase plausible, et rien dans le texte
        # produit ne permet ensuite de savoir qu'elle est inventée.
        if not self.has_speech(audio):
            log.info("aucune parole détectée (%.1fs) — transcription ignorée",
                     len(audio) / SAMPLE_RATE)
            return Transcription(text="", mode=mode, language=language,
                                 window_s=0, tokens=0)

        if len(audio) / SAMPLE_RATE > MAX_WINDOW_S:
            return self._transcribe_longform(
                audio, mode=mode, language=language, hotwords=hotwords,
                keep_disfluencies=keep_disfluencies, max_new_tokens=max_new_tokens)
        return self._transcribe_window(
            audio, mode=mode, language=language, hotwords=hotwords,
            keep_disfluencies=keep_disfluencies, max_new_tokens=max_new_tokens)

    def _transcribe_longform(
        self,
        audio: np.ndarray,
        **kwargs,
    ) -> Transcription:
        """Transcrit un audio plus long que la fenêtre de 30 s du modèle.

        Découper à l'aveugle ne marche pas : Whisper émet volontiers une fin de
        séquence sur un silence interne et abandonne le reste de sa fenêtre.
        Une fenêtre de 25 s contenant deux phrases séparées par une pause perd
        la seconde — mesuré, la moitié des échantillons disparaissait.

        On procède donc comme Whisper en long-format : décoder **avec**
        horodatages, lire le dernier instant réellement transcrit, et faire
        repartir la fenêtre suivante exactement de là. Un arrêt prématuré
        cesse d'être une perte : il devient simplement une fenêtre plus courte,
        et la suite est reprise au tour d'après.
        """
        segments = self._split_at_silence(audio)
        texts: list[str] = []
        timings = Timings()
        tokens = 0
        context: str | None = None

        for index, segment in enumerate(segments):
            part = self._transcribe_window(segment, context=context, **kwargs)
            if part.text:
                texts.append(part.text)
                # Contexte court : trop long, le modèle paraphrase ce qui
                # précède au lieu de poursuivre.
                context = " ".join(" ".join(texts).split()[-CONTEXT_WORDS:])
            timings.mel_ms += part.timings.mel_ms
            timings.encoder_ms += part.timings.encoder_ms
            timings.decoder_ms += part.timings.decoder_ms
            tokens += part.tokens
            log.debug("  segment %d/%d (%.1fs) : %d mots", index + 1,
                      len(segments), len(segment) / SAMPLE_RATE,
                      len(part.text.split()))

        log.info("longform : %.0fs en %d segments, %d mots",
                 len(audio) / SAMPLE_RATE, len(segments),
                 len(" ".join(texts).split()))

        return Transcription(
            text=" ".join(texts).strip(),
            mode=kwargs.get("mode", "intended"),
            language=kwargs.get("language", "fr"),
            window_s=MAX_WINDOW_S,
            tokens=tokens,
            truncated=False,
            timings=timings,
        )

    @staticmethod
    def has_speech(audio: np.ndarray) -> bool:
        """L'audio contient-il de la parole ?

        Whisper ne rend jamais « rien » : sur du silence il invente, et
        produit typiquement une formule vue à l'entraînement (« Sous-titrage
        Société Radio-Canada », « Merci d'avoir regardé »). Presser le
        raccourci sans parler insérerait donc du texte inventé au curseur.

        On ne cherche pas à décider si c'est *une voix* — un vrai VAD
        neuronal ferait ça — mais si le signal a la **structure** de la
        parole : une alternance franche entre passages sonores et silences.
        Un souffle de ventilateur ou un bourdonnement ont une énergie
        constante ; la parole, non.
        """
        frame = int(0.02 * SAMPLE_RATE)
        usable = (len(audio) // frame) * frame
        if usable < frame * 10:                    # moins de 200 ms
            return False

        frames = audio[:usable].reshape(-1, frame)
        energy = np.sqrt((frames.astype(np.float64) ** 2).mean(axis=1))

        # Silence quasi absolu : micro coupé, ou personne n'a parlé.
        if float(energy.max()) < ABSOLUTE_SILENCE:
            return False

        # Modulation de l'énergie en décibels. La parole alterne syllabes et
        # pauses, ce qui produit une dispersion large ; un bruit stationnaire
        # reste plat quel que soit son volume.
        #
        # Une version précédente comparait deux centiles d'énergie. Mauvais
        # critère : mesuré sur voix réelle, ce rapport valait 2,5 à 4,4 pour de
        # la parole contre 1,8 pour du bruit modulé — marge trop mince, et un
        # échantillon parfaitement audible tombait pile sur le seuil et était
        # rejeté. En décibels la séparation est nette : 0 à 2 pour tous les
        # bruits testés, 8,4 à 13 pour toute la parole.
        decibels = 20 * np.log10(np.maximum(energy, 1e-9))
        if float(decibels.std()) < SPEECH_MODULATION_DB:
            return False

        # Second garde-fou : assez de trames sonores. Un clic unique module
        # fortement mais n'occupe qu'une trame sur des centaines.
        floor = float(np.percentile(energy, 10))
        speech = float(np.percentile(energy, 90))
        threshold = floor + SILENCE_RATIO * (speech - floor)
        return float((energy > threshold).mean()) >= MIN_VOICED_RATIO

    @staticmethod
    def _silence_boundaries(audio: np.ndarray) -> list[int]:
        """Indices d'échantillon au milieu de chaque pause détectée.

        Le seuil est relatif au niveau de la voix — un seuil absolu ne marche
        ni sur un micro de casque ni dans une pièce bruyante. On prend un
        centile bas de l'énergie comme référence de fond et on marque comme
        pause tout ce qui reste proche de ce fond assez longtemps.
        """
        frame = int(0.02 * SAMPLE_RATE)
        usable = (len(audio) // frame) * frame
        if usable < frame:
            return []

        frames = audio[:usable].reshape(-1, frame)
        energy = np.sqrt((frames.astype(np.float64) ** 2).mean(axis=1))

        floor = np.percentile(energy, 10)
        speech = np.percentile(energy, 90)
        if speech <= floor:
            return []                     # pas de parole distinguable du fond
        threshold = floor + SILENCE_RATIO * (speech - floor)

        quiet = energy < threshold
        min_frames = int(MIN_PAUSE_S / 0.02)

        boundaries: list[int] = []
        start = None
        for index, is_quiet in enumerate(quiet):
            if is_quiet and start is None:
                start = index
            elif not is_quiet and start is not None:
                if index - start >= min_frames:
                    boundaries.append(((start + index) // 2) * frame)
                start = None
        if start is not None and len(quiet) - start >= min_frames:
            boundaries.append(((start + len(quiet)) // 2) * frame)
        return boundaries

    @classmethod
    def _split_at_silence(cls, audio: np.ndarray) -> list[np.ndarray]:
        """Découpe l'audio en segments d'au plus 30 s, aux pauses réelles.

        Couper à intervalle fixe ne suffit pas : Whisper émet volontiers une
        fin de séquence sur un silence interne et abandonne le reste de la
        fenêtre. Un segment de 30 s contenant deux phrases séparées par une
        pause perd donc la seconde — constaté en test, un échantillon entier
        disparaissait de la transcription.

        On aligne donc les coupes sur les pauses de la parole : chaque segment
        correspond à un souffle continu, ce que le modèle sait transcrire d'un
        bout à l'autre. Sans pause exploitable (débit ininterrompu), on coupe
        à la limite de la fenêtre.
        """
        window = int(MAX_WINDOW_S * SAMPLE_RATE)
        if len(audio) <= window:
            return [audio]

        # Couper à *chaque* pause, pas seulement quand la fenêtre déborde :
        # c'est la pause à l'intérieur d'un segment qui déclenche l'arrêt
        # prématuré, donc en laisser une passer suffit à perdre la suite.
        cuts = [0, *cls._silence_boundaries(audio), len(audio)]

        segments: list[np.ndarray] = []
        start = cuts[0]
        for end in cuts[1:]:
            if end - start < MIN_SEGMENT_S * SAMPLE_RATE and end != len(audio):
                continue        # trop court : on prolonge jusqu'à la pause suivante
            while end - start > window:
                segments.append(audio[start:start + window])
                start += window
            if end > start:
                segments.append(audio[start:end])
            start = end

        segments = [s for s in segments if len(s) > 0]

        # Un dernier segment très court est la première source d'hallucination
        # observée en usage réel. La boucle ci-dessus fusionne les segments
        # trop courts avec le suivant, sauf le dernier — il n'a pas de suivant,
        # donc il sort tel quel, parfois moins d'une seconde. Isolé, il est
        # ensuite complété jusqu'à `MIN_WINDOW_S` par la fenêtre d'encodage :
        # le modèle voit une seconde de souffle dans quinze secondes de vide,
        # n'a rien à transcrire, et produit une formule apprise.
        #
        # Constaté sur une dictée de 73 s découpée en 11 segments : le dernier
        # faisait 0,7 s et ajoutait « Effects de la réunion des deux deux
        # deux. » à un texte par ailleurs correct.
        #
        # On le rattache au précédent plutôt que de le jeter : l'audio est
        # conservé, et il est de toute façon trop court pour porter autre
        # chose que la fin d'un mot.
        # Piste d'amélioration, cf. « Known gaps » du README : l'aperçu en
        # direct peut fournir les plages temporelles mot par mot, ce qui
        # donnerait une détection de parole autrement plus fiable que
        # `has_speech` sur ces durées. La fusion resterait le repli quand
        # l'aperçu est coupé.
        if len(segments) > 1 and len(segments[-1]) < MIN_SEGMENT_S * SAMPLE_RATE:
            merged = np.concatenate([segments[-2], segments[-1]])
            if len(merged) <= window:
                segments[-2:] = [merged]
                log.debug("dernier segment trop court, rattaché au précédent")

        return segments

    def _transcribe_window(
        self,
        audio: np.ndarray,
        *,
        mode: str = "intended",
        language: str = "fr",
        hotwords: list[str] | None = None,
        keep_disfluencies: bool = False,
        max_new_tokens: int = 256,
        context: str | None = None,
        timestamps: bool = False,
    ) -> Transcription:
        duration_s = len(audio) / SAMPLE_RATE
        window_s, truncated = self._window_for(duration_s)

        t0 = time.perf_counter()
        feats = self._processor.feature_extractor(
            audio, sampling_rate=SAMPLE_RATE, return_tensors="pt"
        )
        # La seconde convolution de l'encodeur a un pas de 2 : un nombre impair
        # de trames donne une longueur attendue qui ne retombe pas sur la
        # longueur fournie, et le contrôle interne de Whisper échoue. Les
        # fenêtres fixes de 15 s et 30 s tombaient juste par chance ; les
        # segments long-format, de durée variable, non.
        n_frames = int(window_s * MEL_FRAMES_PER_S)
        n_frames -= n_frames % 2
        mel = feats.input_features[:, :, :n_frames]
        mel = mel.to(self.device, self.dtype)
        self._sync()
        t_mel = time.perf_counter() - t0

        t0 = time.perf_counter()
        enc_out = self._encode(mel)
        self._sync()
        t_enc = time.perf_counter() - t0

        prompt_ids = prompt_mod.build(
            self._processor.tokenizer,
            mode=mode,
            language=language,
            hotwords=hotwords,
            context=context,
            timestamps=timestamps,
        )

        t0 = time.perf_counter()
        tokens = (self._decode_beam(enc_out, prompt_ids, max_new_tokens, self.beam_size)
                  if self.beam_size > 1
                  else self._decode(enc_out, prompt_ids, max_new_tokens))
        self._sync()
        t_dec = time.perf_counter() - t0

        last_ts = None
        if timestamps:
            stamps = [t for t in tokens if t >= self._timestamp_begin]
            if stamps:
                last_ts = (stamps[-1] - self._timestamp_begin) * TIMESTAMP_STEP_S
            tokens = [t for t in tokens if t < self._timestamp_begin]

        raw = self._processor.tokenizer.decode(tokens, skip_special_tokens=True)
        text = self._clean(raw, keep_disfluencies=keep_disfluencies)
        active_lexicon = hotwords
        if active_lexicon:
            text = self._strip_lexicon_echo(text, active_lexicon).strip()
            text = self._normalise_case(text, active_lexicon)

        return Transcription(
            text=text,
            mode=mode,
            language=language,
            window_s=window_s,
            tokens=len(tokens),
            truncated=truncated,
            timings=Timings(t_mel * 1000, t_enc * 1000, t_dec * 1000),
            last_timestamp=last_ts,
        )

    @staticmethod
    def _strip_lexicon_echo(text: str, lexicon: list[str]) -> str:
        """Retire un terme du lexique recraché seul en tête de transcription.

        Le lexique est injecté juste avant le début de transcription. Le modèle
        enchaîne parfois dessus et sort un fragment isolé avant le vrai texte :
        « Effects.Ok, donc là un texte… », alors que « Effects » n'a jamais été
        prononcé.

        On ne retire que ce cas précis — un fragment d'au plus deux mots,
        terminé par une ponctuation forte, dont la forme se retrouve dans un
        terme du lexique. Un « Ok. » ou un « Bon. » légitime ne correspond à
        aucune entrée et survit.
        """
        # Le point doit ouvrir une nouvelle phrase — majuscule derrière, avec
        # ou sans espace. Sans cette condition, « Next.js est bien » verrait
        # « Next. » traité comme un écho, alors que le « js » minuscule montre
        # qu'il s'agit d'un seul mot.
        match = re.match(
            r"^\s*([A-Za-zÀ-ÿ]+(?:\s+[A-Za-zÀ-ÿ]+)?)[.!?](?=\s*[A-ZÀ-Ÿ])\s*", text)
        if not match:
            return text
        head = match.group(1).strip().lower()
        if len(head) < 3:
            return text
        # Le modèle décline ce qu'il recrache : « useEffect » ressort en
        # « Effects ». On compare donc aussi la forme sans pluriel, sinon le
        # cas le plus courant passe à travers.
        stem = head[:-1] if head.endswith("s") and len(head) > 3 else head
        flat = [t.lower().replace(" ", "").replace(".", "") for t in lexicon]
        if any(stem in term or term in stem for term in flat):
            log.info("écho du lexique retiré en tête : %r", match.group(1))
            return text[match.end():]
        return text

    @staticmethod
    def _normalise_case(text: str, lexicon: list[str]) -> str:
        """Rétablit la casse canonique des termes du lexique.

        Le modèle reconnaît le mot mais se trompe de casse : « UseEffect »,
        « UseState », « React » en minuscules. C'est un cas où la correction
        est **déterministe** — on ne devine rien, on impose une forme connue à
        un mot déjà correctement entendu. À la différence d'une réécriture par
        modèle de langue, ça ne peut pas inventer.

        Les mots d'une seule lettre et les termes composés sont laissés de
        côté : trop de risque de collision avec du français ordinaire.
        """
        canonical = {t.lower(): t for t in lexicon
                     if " " not in t and len(t) > 2 and t != t.lower()}
        if not canonical:
            return text

        def fix(match: re.Match) -> str:
            word = match.group(0)
            target = canonical.get(word.lower())
            # On ne touche qu'à la casse, jamais aux lettres.
            return target if target and target != word else word

        return re.sub(r"\b[A-Za-z][A-Za-z.]*\b", fix, text)

    @staticmethod
    def _clean(text: str, *, keep_disfluencies: bool) -> str:
        text = PROMPT_ARTIFACT_RE.sub("", text)
        if not keep_disfluencies:
            text = DISFLUENCY_RE.sub("", text)
        text = " ".join(text.split()).strip()
        return CrisperWhisperEngine._guard_loops(text)

    # --- dernier filet, sur le texte -------------------------------------
    #
    # Les garde-fous précédents agissent pendant le décodage, sur des tokens.
    # Deux choses leur échappent, mesurées sur le corpus du projet :
    #
    # 1. Ils tolèrent trois répétitions consécutives, ce qui est juste pour un
    #    motif d'un ou deux mots — « il y a un gros gros gros problème » est du
    #    français — mais faux au-delà : sur 86 dictées, *tous* les motifs de
    #    trois mots ou plus répétés trois fois sont des hallucinations.
    # 2. `_collapsed` ne regarde que les 32 derniers tokens, donc ne s'arme
    #    jamais sur une dictée courte. Or c'est précisément là que le modèle
    #    déraille : appuyer une seconde sur la touche produisait
    #    « Effects à la finition de la finition de la finition de la
    #    finition. » — une formule vue à l'entraînement, retrouvée telle quelle
    #    dans quatre enregistrements distincts, là où le moteur d'Apple ne
    #    rendait rien du tout.
    #
    # Ici on travaille sur des mots, pas des tokens : la tokenisation varie
    # (« un » et « ␣un » diffèrent), ce qui laisse passer des répétitions
    # pourtant évidentes à la lecture.

    @staticmethod
    def _guard_loops(text: str) -> str:
        # La diversité se mesure sur le texte **brut** : effondrer les boucles
        # d'abord la ferait remonter mécaniquement, et le test ne verrait plus
        # rien de ce qu'il cherche.
        if CrisperWhisperEngine._degenerate_short(text):
            log.info("transcription rejetée : vocabulaire effondré (%s)", text[:60])
            return ""
        cleaned, removed, total = CrisperWhisperEngine._collapse_loops(text)
        if total and removed / total > MAX_LOOP_SHARE:
            log.info("transcription rejetée : %d/%d mots en boucle", removed, total)
            return ""
        return cleaned

    @staticmethod
    def _degenerate_short(text: str) -> bool:
        """Une sortie courte n'est-elle qu'une bouillie de mots répétés ?

        Sous ``SHORT_MIN_WORDS`` la diversité ne veut rien dire : « Effects- »
        vaut 1,0 et c'est une transcription correcte. Au-dessus de
        ``SHORT_MAX_WORDS``, les garde-fous de décodage prennent le relais.

        Le seuil vient d'une mesure sur le corpus : les deux hallucinations
        tombent à 0,29 et 0,38, la plus pauvre des phrases légitimes est à
        0,56. Le trou est franc, le seuil est posé dedans.
        """
        words = WORD_RE.findall(text.lower())
        if not SHORT_MIN_WORDS <= len(words) <= SHORT_MAX_WORDS:
            return False
        return len(set(words)) / len(words) < MIN_SHORT_DIVERSITY

    @staticmethod
    def _collapse_loops(text: str) -> tuple[str, int, int]:
        """Coupe les répétitions consécutives au-delà de ce qui est plausible.

        Retourne ``(texte, mots retirés, mots d'origine)``. Les motifs longs
        sont traités d'abord : sans ça, effacer « la » dans « de la fin de la
        fin » casserait le motif de trois mots avant qu'on l'ait vu.
        """
        parts = TOKEN_RE.findall(text)
        if not parts:
            return text, 0, 0
        norm = [re.sub(r"[^\w']", "", p).lower() for p in parts]
        keep = [True] * len(parts)
        removed = 0

        for size in range(MAX_LOOP_PATTERN_WORDS, 0, -1):
            i = 0
            while i + size * 2 <= len(parts):
                if not all(keep[i:i + size]) or not any(norm[i:i + size]):
                    i += 1
                    continue
                pattern = norm[i:i + size]
                repeats, j = 1, i + size
                while (j + size <= len(parts) and norm[j:j + size] == pattern
                       and all(keep[j:j + size])):
                    repeats += 1
                    j += size
                allowed = (MAX_REPEATS_SHORT_PATTERN if size < LONG_PATTERN_WORDS
                           else MAX_REPEATS_LONG_PATTERN)
                if repeats > allowed:
                    for k in range(i + size * allowed, j):
                        if keep[k]:
                            keep[k] = False
                            removed += 1
                    i = j
                else:
                    i += 1

        return " ".join(p for p, k in zip(parts, keep) if k), removed, len(parts)
