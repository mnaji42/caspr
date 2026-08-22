"""Prompt décodeur, garde-fou anti-boucle et nettoyage de sortie.

Le prompt porte tout ce qui distingue Caspr : mode verbatim/intended et
conditionnement par vocabulaire. Une erreur d'ordre ou un token manquant ne
provoque aucune panne — la transcription sort simplement sans ces
fonctionnalités, ce qui est le pire mode d'échec.
"""

import pytest

from caspr_engine import prompt as prompt_mod
from caspr_engine.crisper import (LOOP_WINDOW_TOKENS,
                                  MAX_NGRAM_REPEATS,
                                  CrisperWhisperEngine as Engine)


class FakeTokenizer:
    """Tokenizer minimal : renvoie des identifiants stables et traçables."""

    SPECIAL = {"<|startoftranscript|>": 50258, "<|fr|>": 50265,
               "<|en|>": 50259, "<|transcribe|>": 50359,
               "<|notimestamps|>": 50364}

    def encode(self, text, add_special_tokens=False):
        return [hash(part) % 1000 for part in text.split()] or [0]

    def convert_tokens_to_ids(self, token):
        return self.SPECIAL.get(token, -1)


@pytest.fixture
def tokenizer():
    return FakeTokenizer()


# --- prompt ---------------------------------------------------------------

def test_prompt_ends_with_whisper_prefix(tokenizer):
    """Les tags CrisperWhisper viennent AVANT le début de transcription.
    C'est ce que WhisperKit ne permet pas, et ce qui a fait écarter ce SDK."""
    ids = prompt_mod.build(tokenizer, mode="intended", language="fr")
    assert ids[-4:] == [50258, 50265, 50359, 50364]


def test_timestamps_flag_removes_notimestamps(tokenizer):
    with_ts = prompt_mod.build(tokenizer, timestamps=True)
    without = prompt_mod.build(tokenizer, timestamps=False)
    assert 50364 in without
    assert 50364 not in with_ts


def test_language_is_honoured(tokenizer):
    assert 50259 in prompt_mod.build(tokenizer, language="en")
    assert 50265 in prompt_mod.build(tokenizer, language="fr")


def test_unknown_mode_is_rejected(tokenizer):
    with pytest.raises(ValueError):
        prompt_mod.build(tokenizer, mode="creative")


def test_hotwords_lengthen_the_prompt(tokenizer):
    plain = prompt_mod.build(tokenizer, hotwords=None)
    biased = prompt_mod.build(tokenizer, hotwords=["useEffect", "component"])
    assert len(biased) > len(plain)


def test_context_precedes_hotwords(tokenizer):
    """Ordre imposé par l'entraînement ; l'inverser sort de la distribution."""
    class Recorder(FakeTokenizer):
        seen = ""
        def encode(self, text, add_special_tokens=False):
            Recorder.seen = text
            return [1]

    prompt_mod.build(Recorder(), context="phrase précédente",
                     hotwords=["useEffect"])
    assert Recorder.seen.index("<ctx>") < Recorder.seen.index("<htx>")


def test_five_mode_tags_are_emitted_as_a_block(tokenizer):
    """Cinq tags groupés, pas une échelle de fidélité : deux modes, pas dix."""
    class Recorder(FakeTokenizer):
        seen = ""
        def encode(self, text, add_special_tokens=False):
            Recorder.seen = text
            return [1]

    prompt_mod.build(Recorder(), mode="verbatim")
    for index in range(1, 6):
        assert f"[verbatim_{index}]" in Recorder.seen


# --- garde-fou anti-boucle ------------------------------------------------

def test_allows_legitimate_repetition():
    """« non non non » est du langage, pas une boucle."""
    tokens = [7, 7, 7]
    assert not Engine._repeats_ngram(tokens, 9)


def test_blocks_single_token_loop():
    tokens = [7] * MAX_NGRAM_REPEATS
    assert Engine._repeats_ngram(tokens, 7)


def test_blocks_phrase_loop():
    """Le motif répété peut faire plusieurs tokens : « faire un peu plus de ».

    Le blocage vise le token qui *achève* une répétition de trop. Trois copies
    suivies d'un début de quatrième ne sont pas encore une boucle — c'est le
    token qui complète cette quatrième copie qui doit être refusé.
    """
    phrase = [11, 12, 13, 14]
    tokens = phrase * MAX_NGRAM_REPEATS + phrase[:-1]
    assert Engine._repeats_ngram(tokens, phrase[-1])


def test_allows_three_copies_plus_a_start():
    """Limite basse : on ne coupe pas une répétition encore plausible."""
    phrase = [11, 12, 13, 14]
    assert not Engine._repeats_ngram(phrase * (MAX_NGRAM_REPEATS - 1), phrase[0])


def test_ignores_unrelated_history():
    assert not Engine._repeats_ngram([1, 2, 3, 4, 5, 6], 7)


# --- garde-fou anti-effondrement -----------------------------------------
#
# Cas venu d'une dictée réelle : le modèle a produit « And. You. You. You.
# And. You. You. And. You. You. You. … » sur une quarantaine de répétitions.
# Le contrôle de n-grammes n'a refusé aucun token, parce que la période du
# motif variait. C'est ce trou que ces tests ferment.

def test_detects_varying_period_loop():
    """Le décrochage réel : quatre tokens, périodicité irrégulière."""
    et, you, point = 1, 2, 3
    loop = ([et, point] + [you, point] * 3) * 3 + ([et, point] + [you, point] * 2) * 3
    assert Engine._collapsed(loop)


def test_ignores_short_sequences():
    """Sous la fenêtre, aucune mesure n'est fiable — on ne coupe pas."""
    assert not Engine._collapsed([1, 2] * ((LOOP_WINDOW_TOKENS - 2) // 2))


def test_allows_repetitive_speech():
    """« Non non non, attends attends attends » : pauvre, mais pas effondré.

    Mesuré sur du texte réel, la parole la plus répétitive reste à 0,41 de
    diversité quand la boucle tombe à 0,09 ; le seuil est à 0,25.
    """
    speech = [10, 10, 10, 11, 12, 13, 13, 13, 14, 15, 16, 16, 17, 18, 19, 20]
    assert not Engine._collapsed(speech * 2)


def test_measures_only_the_recent_window():
    """Un texte sain n'est pas sauvé par son passé : c'est la fin qui compte."""
    healthy = list(range(100))
    assert Engine._collapsed(healthy + [42, 43] * LOOP_WINDOW_TOKENS)


# --- nettoyage ------------------------------------------------------------

def test_disfluencies_removed_by_default():
    text = Engine._clean("[UM] je pense [UH] que oui", keep_disfluencies=False)
    assert "[UM]" not in text and "[UH]" not in text
    assert text == "je pense que oui"


def test_disfluencies_kept_on_request():
    text = Engine._clean("[UM] je pense", keep_disfluencies=True)
    assert "[UM]" in text


def test_prompt_markers_never_leak():
    raw = "[intended_1][intended_2] <htx> useEffect <ehtx> Bonjour"
    assert Engine._clean(raw, keep_disfluencies=False) == "Bonjour"


#: Un lexique d'essai, écrit ici plutôt qu'importé. Le moteur n'en porte plus —
#: mesuré nuisible sur voix réelle, cf. `poc/README.md` — mais le filtre d'écho
#: qu'on éprouve ici sert toujours, dès que quelqu'un règle ses propres termes.
LEXIQUE_ESSAI = [
    "useEffect", "useState", "component", "React", "Next.js", "TypeScript",
    "hook", "props", "state", "refactor", "merge", "commit", "branch",
    "pull request", "endpoint", "dependencies", "async", "await", "chunk",
]


@pytest.mark.parametrize("text,should_strip", [
    ("Effects.Ok, donc là un texte.", True),
    ("Component. Je pense que oui.", True),
    ("Dependencies. Je regarde ça.", True),
    ("Ok. Donc là je teste.", False),
    ("Bon. On y va.", False),
    ("Next.js est vraiment bien.", False),
    ("Je vais modifier le component React.", False),
])
def test_lexicon_echo_filter(text, should_strip):
    """Retire un terme du lexique recraché seul en tête, sans toucher au reste."""
    result = Engine._strip_lexicon_echo(text, LEXIQUE_ESSAI).strip()
    assert (result != text) == should_strip


# --- normalisation de casse -----------------------------------------------

@pytest.mark.parametrize("given,expected", [
    ("Je modifie le UseEffect", "Je modifie le useEffect"),
    ("il utilise UseState et UseEffect", "il utilise useState et useEffect"),
    ("le component react est cassé", "le component React est cassé"),
    ("Typescript se plaint", "TypeScript se plaint"),
    # Rien à corriger : la casse est déjà bonne.
    ("le useEffect et React", "le useEffect et React"),
    # Mots hors lexique : intouchés.
    ("Le Chat mange", "Le Chat mange"),
    ("Bonjour tout le monde", "Bonjour tout le monde"),
])
def test_case_normalisation(given, expected):
    assert Engine._normalise_case(given, LEXIQUE_ESSAI) == expected


def test_case_normalisation_never_changes_letters():
    """Seule la casse bouge : jamais une lettre, jamais un mot entier."""
    text = "Le futur du framework est incertain"
    result = Engine._normalise_case(text, LEXIQUE_ESSAI)
    assert result.lower() == text.lower()


class TestWordLevelLoopGuard:
    """Dernier filet, sur le texte plutôt que sur les tokens.

    Les garde-fous de décodage tolèrent trois répétitions consécutives, ce qui
    est juste pour un mot isolé et faux pour un groupe de mots ; et le contrôle
    de diversité ne s'arme qu'au-delà de 32 tokens, donc jamais sur une dictée
    courte. C'est exactement là que le modèle produisait « Effects à la
    finition de la finition… » quand on effleurait la touche, alors que le
    moteur d'Apple ne rendait rien.

    Les seuils viennent du corpus du projet : voir les constantes.
    """

    def test_rejette_la_boucle_courte_observee(self):
        """L'hallucination retrouvée telle quelle dans quatre dictées."""
        text = ("Effects à la finition de la finition de la finition "
                "de la finition.")
        assert Engine._guard_loops(text) == ""

    def test_rejette_le_vocabulaire_effondre(self):
        assert Engine._guard_loops("Une un un un un un un") == ""

    def test_garde_une_repetition_legitime_d_un_mot(self):
        """« gros gros gros » est du français, et vient du corpus."""
        text = "il y a un gros gros gros problème avec les hallucinations"
        assert Engine._guard_loops(text) == text

    def test_garde_une_sortie_tres_courte(self):
        """Trop court pour que la diversité veuille dire quoi que ce soit."""
        assert Engine._guard_loops("Effects-") == "Effects-"

    def test_garde_la_phrase_legitime_la_plus_pauvre_du_corpus(self):
        """Diversité 0,56 — la plus basse mesurée sur de la vraie parole."""
        text = ("I think I just understand the problem. The problem is "
                "I don't know why")
        assert Engine._guard_loops(text) == text

    def test_coupe_une_boucle_de_queue_sans_perdre_le_reste(self):
        """Une longue dictée qui déraille à la fin garde son contenu."""
        body = ("donc là je viens de repasser en français et ça fonctionne "
                "plutôt bien pour le moment on continue comme ça ")
        text = body + "de la fin de la fin de la fin de la fin"
        out = Engine._guard_loops(text)
        assert out.startswith("donc là je viens de repasser")
        assert out.count("de la fin") <= 2

    def test_une_boucle_majoritaire_fait_tout_rejeter(self):
        text = "bonjour " + "de la fin " * 8
        assert Engine._guard_loops(text.strip()) == ""
