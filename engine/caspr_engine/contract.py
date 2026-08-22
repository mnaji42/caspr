"""Ce qu'un moteur rend, sans dire comment il le calcule.

Extrait de `crisper.py` le jour où un second moteur a été essayé. Le problème
était concret et immédiat : le nouveau moteur importait `Transcription` depuis
`crisper.py`, qui importe `torch` en tête de fichier — donc le faire tourner
sur un autre runtime exigeait d'installer PyTorch pour rien. Un contrat qui
traîne le runtime de sa première implémentation n'est pas un contrat.

L'essai en question a été retiré ; l'extraction reste, parce que le défaut
qu'elle corrige reviendra au moteur suivant.

Rien ici ne doit importer autre chose que la bibliothèque standard.
"""

from __future__ import annotations

from dataclasses import dataclass, field

SAMPLE_RATE = 16_000


@dataclass
class Timings:
    """Décomposition du temps d'inférence, en millisecondes.

    Les trois postes viennent de Whisper et n'ont pas d'équivalent partout : un
    moteur qui ne les distingue pas met tout dans `decoder_ms` plutôt que
    d'inventer une répartition. Le total reste juste, ce qui est la seule chose
    dont l'application se sert.
    """

    mel_ms: float = 0.0
    encoder_ms: float = 0.0
    decoder_ms: float = 0.0

    @property
    def total_ms(self) -> float:
        return self.mel_ms + self.encoder_ms + self.decoder_ms


@dataclass
class Transcription:
    text: str
    mode: str
    language: str
    window_s: float
    tokens: int
    timings: Timings = field(default_factory=Timings)
    truncated: bool = False
    #: Dernier instant horodaté par le modèle, en secondes depuis le début de
    #: la fenêtre. Renseigné seulement quand les horodatages sont demandés ;
    #: c'est lui qui pilote l'avance en long-format.
    last_timestamp: float | None = None
