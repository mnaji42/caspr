# Caspr

> **Local dictation that speaks developer.**
> Press a key. Talk. Press it again. Your words land at the caret — `useEffect` spelled `useEffect`.

Caspr is a macOS dictation tool for Apple Silicon that handles how developers
actually speak: French and English in the same sentence, technical vocabulary,
hesitations. Everything runs on-device. No account, no cloud, no telemetry.

**Status: engine validated, app in daily use.** See [Roadmap](#roadmap).

---

## Why another dictation app?

macOS already has several good open-source local dictation tools. They share one
blind spot: they assume you speak *one* language at a time.

A French developer doesn't:

> « Tu as oublié les **dependencies** dans le **useEffect**. »

Every general-purpose speech model forces a single language token per segment.
In French mode, English technical terms get phonetically absorbed:

| Spoken | Whisper-family, French mode |
|---|---|
| `useEffect` | *« use effect »*, *« russe-fake »* |
| `dependencies` | *« dépendances »* |
| `React` | *« react »* (lowercase) |

Caspr fixes this with **vocabulary conditioning** — a trained mechanism in
CrisperWhisper 2.0 that biases decoding toward a supplied lexicon.

Measured on real French/English developer speech:

| | Technical terms preserved |
|---|---|
| Without lexicon | 29/34 (85%) |
| **With lexicon** | **32/34 (94%)** |

No regression on plain French sentences.

---

## While you are speaking

Dictation is not a one-shot command. You realise mid-sentence that the text
should not go where it is going, or that you wanted verbatim rather than clean
text. Stopping to fix that means saying it all again.

So a bar floats at the bottom of the screen while you talk, and everything on
it can be changed **without interrupting you**:

```
      [ Texte nettoyé │ Mot à mot ]      [ Curseur │ Notes › review.md ]

  ● 0:42  ▮▮▮▮▮                     Isolement    COLLECTE     👁
  … the words being recognised, as you speak them
```

- **Mode** — clean text or word-for-word.
- **Destination** — the caret of whatever app you are in, or a file. The note
  file is remembered independently of the current destination, so switching
  back and forth costs one click, even mid-sentence.
- **Live preview** — what is being heard, in real time. It comes from macOS's
  own recogniser, not from CrisperWhisper, and the interface says so: it has
  no lexicon, so the inserted text will differ. It answers *"is the mic
  hearing me"*, not *"will the transcription be right"*.
- **Collection** — an always-visible reminder that dictations are being
  archived, and a switch to stop it.

Mode and destination are read **when the recording ends**, never when it
starts. Pressing *Notes* halfway through a sentence sends that dictation to
the file, and the reverse works too.

The bar never takes focus — it is a non-activating panel — because the text
has to land where your caret already is.

---

## Measured results

All numbers from a MacBook Pro M4 Pro, 48 GB, macOS 26.6, on real voice
recordings — not synthetic speech. Reproduce them with the scripts in
[`poc/`](poc/).

### Latency

Round-trip through the engine service, model kept warm:

| Audio | Engine | mel | encoder | decoder |
|---|---|---|---|---|
| 13,2 s | **425 ms** | 6 ms | 296 ms | 120 ms |
| 12,2 s | **536 ms** | 5 ms | 376 ms | 154 ms |
| 29,2 s | 1 123 ms | 3 ms | 746 ms | 372 ms |

That is **4–5× faster than CrisperWhisper's own Python pipeline** on identical
audio, with byte-identical transcriptions. Two findings account for the gap:

**1. The reference pipeline costs more than the model.** Raw compute measured
at ~0,80 s where the package took ~2,30 s — roughly **1,5 s of pipeline
overhead** per transcription. Caspr calls mel → encoder → greedy decode
directly.

**2. Whisper always encodes 30 seconds.** Encoder cost is independent of what
you actually said — it processes a fixed 30 s mel window, mostly silence for a
short dictation. Shrinking the window to 15 s cuts encoder time ~45% with
**strictly identical output**:

| Sample | 30 s window | 15 s window | Text |
|---|---|---|---|
| 13,2 s | 0,76 s | **0,41 s** | identical |
| 12,2 s | 0,84 s | **0,44 s** | identical |
| 16,3 s | 0,82 s | **0,48 s** (20 s) | identical |

Below 15 s the model leaves its training distribution and output becomes
unpredictable — one clip stayed intact down to 4 s while another degraded at
10 s (*« Tu as oublié »* → *« State a oublié »*). **15 s is the safe floor**,
and Caspr does not go under it.

### Verbatim vs Intended

CrisperWhisper exposes two transcription styles. Both work in French:

```
verbatim : « Donc je je pense que enfin, le composant devrait être refactoré. »
intended : « Donc je pense que, enfin, le composant devrait être refactoré. »
```

Numbers settle the default. Verbatim transcribes what you *said*, intended what
you *meant*:

```
verbatim : « renvoie bien un deux cents au lieu du cinq cents »
intended : « renvoie bien un 200 au lieu du 500 »
```

Nobody wants *« erreur cinq cents »* in a bug report. **Intended is the
default**; verbatim is available for interview or note-taking use.

---

## Architecture

Two ways to dictate, and they never listen at the same time: either Caspr
opens the microphone (macOS), or a ChatGPT page does (the relay). They share
nothing upstream; they meet at delivery:

```
             hotkey
               │
     ┌─────────┴──────────┐
     │                    │
┌────▼─────────────┐ ┌────▼──────────────────┐
│  VoieApple       │ │  VoieChatGPT          │
│  Caspr's mic →   │ │  a WKWebView drives   │
│  Apple Intelli-  │ │  chatgpt.com: it      │
│  gence, or the   │ │  listens, transcribes │
│  system Dictation│ │  and may rework text  │
└────┬─────────────┘ └────┬──────────────────┘
     │   text             │   text
     └─────────┬──────────┘
          ┌────▼──────────────────────┐
          │  Livraison                │
          │  caret or notes file,     │
          │  history, rescue options  │
          └───────────────────────────┘
```

The path is switched in Settings › Voie, from the menu bar menu (« Écrire
avec ChatGPT »), or with an optional global shortcut, empty by default. A
switch applies to the next dictation. While ChatGPT is the path, the menu bar
ghost wears a sparkle — the one permanent sign that your voice goes through
your ChatGPT account rather than staying on the Mac.

```
caspr/
├── app/             Swift menu-bar app (builds to app/build/, gitignored)
│   ├── RELAIS.md    what the ChatGPT relay learned the hard way
│   └── Sources/
│       ├── CasprCore/                 pure logic, under tests
│       └── Caspr/
│           ├── DictationController.swift  the cycle: hotkey, state, Escape
│           ├── VoieApple.swift            macOS: mic, live preview, transcription
│           ├── VoieChatGPT.swift          ChatGPT: the page listens and answers
│           ├── Livraison.swift            insert, history, retry
│           ├── CarteVoie.swift            Settings › Voie: switch paths
│           ├── RecordingOverlay.swift     the floating bar
│           └── Relais/                    the ChatGPT page and its calibration
├── scripts/
│   ├── dev-cert.sh      local signing certificate, so TCC grants persist
│   ├── install.sh       build → sign → /Applications/Caspr.app
│   └── package-dmg.sh   .dmg with the Applications shortcut
└── website/         the landing page
```

### How the prompt actually works

CrisperWhisper conditions behaviour with tokens placed **before**
`<|startoftranscript|>`, not through Whisper's `<|startofprev|>`:

```
[intended_1..5]  <htx> useEffect component React <ehtx>  <|sot|> <|fr|> <|transcribe|> <|notimestamps|>
```

Two things worth knowing, both verified against the released weights:

- The five mode tags are emitted **as one block** — a soft prompt carrying a
  single signal. There are two modes, not ten fidelity levels.
- The hotword markers `<htx>` / `<ehtx>` (ids 51895/51896) **exist in the
  open-weight models**. Vocabulary conditioning works without Nyra's Pro tier.

---

## Requirements

They depend entirely on which engine you use, and the difference is large
enough that one list would mislead:

| | Built-in engine (macOS) | CrisperWhisper |
|---|---|---|
| macOS | **26+** | 14+ |
| Chip | any Mac that runs macOS 26 | Apple Silicon (M1+) |
| To download | nothing | ~1,6 GB of weights |
| Memory | negligible | ~3 GB resident |
| Setup | none | clone the repo, run a script |
| Licence | — | **non-commercial** — [read this](#licensing--read-this-before-using-the-models) |

The built-in engine is the default and needs no setup at all. It does not know
your technical vocabulary — it writes *"use effect"*. CrisperWhisper is what
writes `useEffect`, and it is opt-in.

---

## Install

### From the release (recommended)

1. Download **[Caspr.dmg](https://github.com/mnaji42/caspr/releases/latest/download/Caspr.dmg)**
   from the latest release.
2. Open it and drag Caspr to Applications.
3. Launch it. **macOS will refuse the first time** — see just below.
4. A welcome window walks through the microphone, Accessibility, and the
   choice of engine.

#### Why macOS refuses, and what to do

Caspr is **not notarized**. Notarization requires a paid Apple Developer
account, which this project does not have yet. So on first launch macOS says:

> « Apple n'a pas pu vérifier que « Caspr » ne contient pas de logiciel
> malveillant. »

This is Gatekeeper doing its job: it cannot verify software it has never seen.
It is not a claim that anything is wrong — but you are being asked to trust an
unsigned binary from a stranger, and you should decide that deliberately. The
source is here, and you can always build it yourself (below) instead.

To open it anyway:

1. Click **Terminer** on the dialog.
2. Go to  **Réglages Système › Confidentialité et sécurité**.
3. Scroll to the bottom: *« Caspr » a été bloqué…* → **Ouvrir quand même**.
4. Confirm, and authenticate.

Since macOS 15, Control-clicking the app no longer bypasses this — System
Settings is the only route.

The one-line equivalent, if you prefer the terminal:

```bash
xattr -d com.apple.quarantine /Applications/Caspr.app
```

That strips the quarantine flag so macOS stops asking. It is the same decision
as clicking through the panel, made faster — and it disables a check that
exists for a reason, so run it only on software you meant to install.

#### Updating

**Caspr makes no network request at all unless you ask it to.** Out of the
box it never contacts anything — the statement "nothing leaves your Mac" has
no exception to declare, which is the point.

Settings › Général › Version offers two ways to learn about a new version:

- **Vérifier maintenant** — a one-off check, whenever you feel like it.
- **Vérifier automatiquement** — a switch, off by default, that checks once a
  day and reports in the menu bar menu.

Either way the request is a GET on GitHub's public API, sending nothing but an
IP address, and Caspr never installs anything by itself: you download the new
DMG and drag it over the old app.

---

## Build from source

### 1. Build and install the app

```bash
./scripts/install.sh
```

This builds, signs, installs to `/Applications/Caspr.app`, and launches it.
Caspr appears in the menu bar — no Dock icon, no window. Build artifacts stay
in `app/build/`, never in the repo.

### 2. Grant two permissions

| Permission | Why | When |
|---|---|---|
| **Microphone** | capture your voice | prompted on first dictation |
| **Accessibility** | insert text into other apps | System Settings › Privacy & Security › Accessibility |

Accessibility must be granted manually. **You only do this once** — see below.

#### Why permissions survive rebuilds

macOS binds TCC permissions to a *designated requirement* derived from the code
signature. Ad-hoc signing puts the binary's `cdhash` in that requirement, so
every rebuild produces a new identity and silently revokes Accessibility —
you would re-tick the checkbox after every single build.

`scripts/dev-cert.sh` creates a local self-signed certificate once, and the
requirement becomes:

```
identifier "fr.lyriastudio.caspr" and certificate leaf = H"d25baa4b…"
```

It depends on the certificate, not the binary. Verified: two builds with
different `cdhash` values produce an identical requirement, so the grant holds.

The certificate is local and self-signed — it is not a substitute for an Apple
Developer ID, which distribution will require.

The same reasoning applies to *released* builds, and it is why the release
workflow imports a certificate rather than signing ad hoc: with an ad-hoc
signature, every new version would be a new identity, and macOS would revoke
everyone's Accessibility grant on every update.

### 3. Dictate

| Shortcut | Action |
|---|---|
| **Right ⌥** | start / stop dictation (press alone) |
| **⌃⌥⌘D** | same, keyboard fallback |
| **Escape** | cancel while recording (no text inserted) |

Tap **Right Option**, talk, tap again. Text lands at the cursor of whatever app is
focused.

**Why `⌃⌥⌘D`?** Three constraints narrow this down fast:

- macOS 15+ rejects global hotkeys whose only modifiers are Option and/or
  Shift — an anti-keylogger measure. `⌥Space` cannot work.
- On a French AZERTY keyboard Option types `@ # { } [ ] | \ ~`, ruling out
  Right Option as a push-to-talk key for developers.
- A global hotkey steals the combination from *every* app. `⌃⌥D` was already
  taken by Chrome and several editors; three modifiers make collisions rare.

It also needs no Input Monitoring permission, going through Carbon's
`RegisterEventHotKey` rather than a `CGEventTap`.

---

## Uninstalling

Menu bar → **Désinstaller Caspr…**, which opens a window listing everything
Caspr put on the machine, with what each thing weighs, and a checkbox for
each. The app itself always goes; the rest is a choice.

**Nothing is deleted outright — everything goes to the Trash.** That is the
macOS convention, and more importantly it is what separates a mistake from a
disaster: the dictation corpus is hundreds of real recordings that cannot be
reconstituted.

The corpus and the model weights are **unchecked by default**. One is
irreplaceable, the other is a 1.6 GB download; a checkbox pre-ticked on the
only thing you cannot get back is a trap. Everything small and rebuildable is
ticked.

| Item | Where | Ticked by default |
|---|---|---|
| The app | wherever it was installed — read from the bundle, not hardcoded | always |
| Settings and history | `~/Library/Preferences/fr.lyriastudio.caspr.plist` | yes |
| Microphone, Accessibility | TCC, via `tccutil` | yes |
| Engine launch agent | `~/Library/LaunchAgents/fr.lyriastudio.caspr.engine.plist` | yes |
| Logs and socket | `~/Library/Logs/Caspr`, `~/Library/Caches/caspr` | yes |
| **Dictation corpus** | `~/Library/Application Support/Caspr` | **no** |
| **CrisperWhisper weights** | `~/.cache/huggingface/hub/models--nyralabs--*` | **no** |

The login item is removed unconditionally — left behind, macOS would try to
launch a deleted application at every login and complain that it is missing.

Your **note file is never touched**. Caspr wrote into it; it is your document,
not part of the installation. Nor is the rest of the Hugging Face cache, which
is shared with any other project using the library.

## Testing a clean install

You cannot judge a first-run experience on the machine that developed it:
permissions are already granted, settings already chosen, and the welcome
window never appears.

```bash
./scripts/reset-state.sh
```

This clears settings and history, and revokes Microphone and Accessibility, so
the next launch behaves exactly like a first install. **It does not touch the
corpus** — the one irreplaceable thing on the machine.

| What | Where | Cleared by default? |
|---|---|---|
| Settings, history | `UserDefaults` | yes |
| Microphone, Accessibility | TCC | yes |
| **Dictation corpus** | `~/Library/Application Support/Caspr/corpus` | **no** |
| Engine logs | `~/Library/Logs/Caspr` | no |
| Model weights | `~/.cache/huggingface/hub/models--nyralabs--*` | no |

`./scripts/reset-state.sh --all` removes everything above, plus the launch
agent and the app itself. It lists what it will delete and asks you to type a
word before doing it.

### Testing the download itself

The reset covers the app, but not Gatekeeper: quarantine is attached when a
browser downloads a file, so the "macOS refuses to open it" step can only be
rehearsed by actually downloading the DMG. A second macOS user account is the
clean way — permissions, settings, and caches are all per-user, and deleting
the account removes them with it. Install into that account's own
`~/Applications` rather than `/Applications`, which is shared.

## Cutting a release

Versions come from git tags — nothing is written by hand. `scripts/version.sh`
derives `CFBundleShortVersionString` from the latest tag, `CFBundleVersion`
from the commit count, and records whether the build sits exactly on a tag.

```bash
git tag -a v0.2.0 -m "Caspr 0.2.0" && git push origin v0.2.0
```

That triggers [`.github/workflows/release.yml`](.github/workflows/release.yml),
which builds, signs, packages, verifies the microphone entitlement, and
attaches `Caspr.dmg` to the release. The asset name never changes, so
`releases/latest/download/Caspr.dmg` is a permanent link.

To build the same package locally:

```bash
./scripts/package-dmg.sh
```

A build that is not exactly on a clean tag marks itself as a development build:
it reports as such in Settings and never offers updates, since a working copy
is nearly always ahead of the last release.

### Signing, and why ad-hoc is not good enough

Without a certificate the workflow still produces a DMG, ad-hoc signed. It
installs and runs — but the bundle's designated requirement becomes the
binary's own hash:

```
designated => cdhash H"f82cc3b2…"
```

That changes with every build, so macOS sees each release as a *different*
application and revokes Accessibility. **Every user re-grants every
permission on every update.**

A stable certificate fixes it, and needs no Apple account:

```bash
./scripts/make-signing-cert.sh
```

It creates a self-signed distribution certificate, imports it so local builds
share the identity, and writes the two secret values to `dist/signing/` — to
files rather than the terminal, since anything printed there ends up in a
history or a screenshot. Paste them into GitHub → Settings → Secrets and
variables → Actions:

| Secret | Contents |
|---|---|
| `SIGNING_CERTIFICATE_P12` | the certificate, base64-encoded |
| `SIGNING_CERTIFICATE_PASSWORD` | its password |

The requirement then becomes identity-based and survives rebuilds:

```
designated => identifier "fr.lyriastudio.caspr" and certificate leaf = H"…"
```

Keep that certificate. Replacing it later breaks Accessibility for everyone
who already installed Caspr.

This is **not** notarization. Gatekeeper will still refuse the first launch
and send people through System Settings; that is a separate problem and it
needs the paid Apple Developer Program. The day a Developer ID exists it goes
into those same two secrets, and notarization is two commands added to the
workflow — `notarytool submit` then `stapler staple`.

---

## Tests

```bash
./scripts/test.sh          # logic only, ~3 s
./scripts/test.sh --full   # adds model-loaded regression + benchmark, ~1 min
```

67 fast tests pin the hand-calibrated decisions — the speech-detection
threshold, pause detection, window floor, loop guard, lexicon echo filter,
wire protocol, text composition. They exist because this project has had two
silent regressions: a VAD that started rejecting real speech, and a lexicon
that grew until it degraded punctuation. Neither raised an error; both were
caught by measurement after the fact.

The slow suite (`-m slow`) loads the model and checks end-to-end behaviour
that unit tests cannot see — technical terms surviving, intended mode writing
digits, verbatim staying distinct from intended, silence producing nothing,
long audio not being truncated. It needs `poc/samples/`, which is gitignored
as personal data, and skips without it.

## Improve it on your own voice

Every comparison below was run on a handful of chosen recordings. That is
enough to pick a starting point, not to settle anything. What actually decides
an engine is spontaneous speech: your accent, your room, your vocabulary, your
habit of switching languages mid-sentence.

So the app can archive what you dictate. Turn on *Collect dictations* in
Settings, and each dictation appends one JSON line to
`~/Library/Application Support/Caspr/corpus/sessions.jsonl`:

```json
{"id": "2026-08-15T13-21-40", "durationSeconds": 80.8, "language": "fr",
 "engineUsed": "crisperwhisper", "modelUsed": "nyralabs/CrisperWhisper2.0_turbo",
 "modeUsed": "intended", "destination": "curseur",
 "textIntended": "…", "textVerbatim": "…", "textApple": "…",
 "latencyIntendedMs": 5235.6, "latencyVerbatimMs": 6358.8,
 "audioFile": "2026-08-15T13-21-40.wav"}
```

Three transcriptions of the **same** audio: CrisperWhisper in both modes, plus
macOS's `SpeechTranscriber`. The last one is free — it already runs while you
speak, to drive the live preview. Keeping the audio is a separate checkbox,
off by default: about 2 MB a minute against a few kilobytes of text.

The second CrisperWhisper pass runs **after** insertion, never before, and
gives up as soon as a new recording starts. The engine handles one request at
a time, and dictation latency is not negotiable against collection.

Append-only, one line per dictation, so the file can be read while the app is
running:

```python
import pandas as pd
df = pd.read_json("sessions.jsonl", lines=True)
df[["textIntended", "textApple"]].head()
```

### Why this matters more than the benchmarks

Keeping the audio is what turns opinions into measurements. A worked example
from real use:

CrisperWhisper wrote *"Effects"* three times where the speaker said *« en
fait »* — a very common French filler. The cause looked obvious: `useEffect`
sits in the lexicon and is known to surface as *"Effects"*. Removing it and
re-running **the same audio** told a different story:

| passage | with `useEffect` | without |
|---|---|---|
| « en fait, la feature… » | *"Effect la feature"* | *"La feature"* ✓ |
| « en fait, ce qui fonctionne pas bien… » | *"Effects de fonctionnement pas bien, comment on peut…"* | *"Pourquoi on peut…"* — content lost |
| trailing mumble | *"Effects de la réunion des deux deux deux"* | *"Potentation de la vidéo"* |

One clear win, one regression, one unusable either way. The lexicon change
moves *which* error you get, not whether you get one. Without the audio, the
first table row alone would have justified a change that is not supported.

### What you can fork this into

The engine sits behind a unix socket with a small documented protocol, so the
corpus is directly usable to:

- **swap the engine** — anything that reads PCM and returns text can replace
  `caspr_engine`, and the corpus tells you immediately whether it is better
  *on your voice*;
- **compare a remote model** against the local one on identical audio, and
  measure what the round trip actually buys;
- **tune the lexicon** by measurement rather than intuition — the repository's
  rule is that a term only enters if another leaves, and now that trade can be
  evidenced;
- **fine-tune** on your own recordings, with paired text already aligned.

One honest caveat, so comparisons are not rigged: `textApple` comes from the
streaming preview, which runs with `fastResults` — quicker, and slightly less
accurate than the same engine given the whole file. To compare fairly, re-run
it offline on the retained audio.

## Roadmap

- [x] **J0** — validate CrisperWhisper on real French/English developer speech
- [x] **J1** — latency breakdown, adaptive encoder window
- [x] **J2** — persistent engine service (4–5× faster than reference pipeline)
- [x] **J3** — Swift app: global hotkey, capture, inject at caret
- [x] **J4** — VAD (no inference on silence) and anti-hallucination guards
- [x] **J5** — menu bar, settings, history, file target
- [x] **J6** — test suite (64 fast, 12 regression)
- [x] **J7** — control bar, note memory, live preview, corpus collection
- [x] **J8** — app icon, onboarding, DMG, tagged releases, update check
- [ ] **J8b** — notarization (waiting on an Apple Developer account)
- [ ] **J9** — Core ML / Neural Engine backend (unblocks in-app model download)
- [ ] **J10** — word-level speech detection from the live preview (below)
- [ ] **J11** — offline Apple pass on retained audio, for a fair comparison

### Engine comparison

Three local engines, same real recordings, each with its best setting:

| Engine | Technical terms | Median latency | Cleanup mode | Vocabulary bias |
|---|---|---|---|---|
| **CrisperWhisper turbo** | **29/29** | 763 ms | yes (intended) | native `<htx>` |
| Whisper large-v3-turbo | 29/29 | 960 ms | no | via `<\|startofprev\|>` |
| Parakeet TDT 0.6b v3 | 26/29 | **420 ms** | no | none |

Parakeet is nearly twice as fast and its French is fluent, but it has no
vocabulary conditioning: it writes `UseEffect`, `UseState`, `UseEffects`,
`Future` for "feature", `deuxcent` for "200". Whisper standard matches on terms
once prompted but returns unpunctuated lowercase text on spontaneous speech —
it has no intended mode.

The benchmark that ranks CrisperWhisper #1 measures **disfluency F1**, not word
error rate: how faithfully a system writes down hesitations actually spoken.
And those rankings are for the **Pro** weights (96.0 F1), which are gated and
commercial-licence only; the open weights score 89.9.

### Hallucination on near-silence, and how it is caught

Whisper never returns nothing. Given silence or a fragment, it invents a
phrase it saw in training. Tapping the key by accident produced this, while
Apple's engine correctly returned an empty string:

| Engine | Output for the same 4.3 s clip |
|---|---|
| macOS | *(empty)* |
| CrisperWhisper verbatim | `Effects-` |
| **CrisperWhisper intended** | **`Effects à la finition de la finition de la finition de la finition.`** |

That exact phrase — `Effects à la finition de la…` / `Effects à la fin de la…`
— was found in **four separate recordings** in the corpus. It is a training
artifact, the CrisperWhisper equivalent of Whisper's *"Sous-titrage Société
Radio-Canada"*.

Two decode-time guards already existed and both missed it. They tolerate three
consecutive repeats, and the vocabulary-collapse check only looks at the last
32 tokens, so it never arms on a short dictation — which is exactly where the
model derails. A word-level pass now runs on the final text, with thresholds
measured across the corpus's 86 dictations:

- **Repeats allowed depend on pattern length.** One or two words repeated three
  times is French — *"il y a un gros gros gros problème"* comes from the corpus
  itself. At three words or more, all seven cases found were hallucinations.
- **Short outputs are checked for vocabulary diversity.** The two
  hallucinations score 0.29 and 0.38 distinct-words-over-total; the poorest
  legitimate sentence in the corpus scores 0.56. The threshold sits in that gap
  at 0.45, and diversity is measured *before* collapsing loops — collapsing
  first raises it mechanically and hides what the test is looking for.

Replayed over the corpus, this rejects exactly the two hallucinations, trims
five tail loops, and leaves the other 201 transcriptions untouched.

### Measured non-results

- **On-device LLM review does not work.** Apple's Foundation Models are
  available and were wired behind a similarity guard, then removed. Asked to
  fix one absurd word in an otherwise sound sentence, the model answered the
  sentence conversationally, added bold instead of correcting, and turned
  "chun-teint" into "chanter" where the word was "chunk". It is tuned for
  assistance, not text transformation. Worth retrying when a stronger
  on-device model ships.
- **Apple's contextual strings do nothing measurable.** `AnalysisContext`
  exposes `contextualStrings`, which reads like the equivalent of
  CrisperWhisper's `<htx>` vocabulary conditioning. Tested on real recordings
  where the engine had already failed on exactly those terms — passing
  `["useEffect", "UI", "div", "React", …]` produced output identical byte for
  byte. *"divves"* stayed *"divves"*, *"l'UI"* stayed *"lui"*. Two avenues
  remain untested: `CustomPronunciation`, which maps a grapheme to explicit
  phonemes, and `SFCustomLanguageModelData`, a heavier custom-LM path. As used
  the obvious way, it has no effect.

  This decides the product: a build using only the system engine cannot spell
  `useEffect`, which is the whole reason this project exists. The technical
  vocabulary needs CrisperWhisper's weights, or Whisper's `<|startofprev|>`.

- **Low decoder confidence does not mark errors.** The least confident words
  on real samples are correct ones — "useEffect" at 0.34 — because the
  hesitation is about the following comma. Median confidence is 0.98
  throughout, so hallucinations cannot be located automatically.
- **A French-tuned Whisper is worse here.** `whisper-large-v3-distil-fr`
  scores 21/25 on technical terms against 25/25 for CrisperWhisper with
  lexicon, at 1.5-2× the latency. It has none of CrisperWhisper's tokens, so
  it loses both vocabulary conditioning (`useEffect` → "use effect") and
  intended mode — on the hesitation sample it returns raw unpunctuated
  speech, "bah je pense que ouais non attend ouais le problème". French is
  indeed a secondary language for CrisperWhisper, but the lexicon more than
  compensates on French/English developer speech.

Kept here because they cost time to establish and would otherwise be
re-attempted:

- **Beam search changes nothing.** On real voice, beam=5 produced output
  *byte-identical* to greedy across all samples, for 60% more latency.
- **`large` is not better than `turbo`.** It is 1.7× slower and sometimes
  worse — *« avant de merde »* where turbo gives *« avant de mer »*,
  *« commands »* where turbo gives *« comments »*. `turbo`'s 4-layer decoder
  is not the bottleneck people assume it is.
- **Speculative decoding is impossible on macOS** (needs CTranslate2, no
  Apple Silicon wheel), and the documented `large`+`turbo` pair is mismatched
  anyway: 80 vs 128 mel bins, 51896 vs 51897 vocab.
### Known gaps

- **VAD is energy-based, not neural.** It rejects silence, low background
  noise, constant hiss and isolated clicks, and accepts all real speech
  tested. It does not distinguish *your* voice from a nearby conversation —
  a neural VAD would, at the cost of another model to load.
- **Lexicon conditioning can hallucinate.** Biasing toward a vocabulary makes
  the decoder favour those terms on acoustically ambiguous passages, so a
  lexicon word can appear where nothing was said. Observed in real use:
  a stray "effect" from `useEffect` being in the list. The trade-off is
  inherent to the mechanism that fixes *« russe-fake »* → `useEffect`.
- **Speech detection is unreliable under a second.** The energy VAD measures
  how much the loudness fluctuates, over 20 ms frames. On a 300 ms fragment
  that is fifteen frames, and a breath or a click can score like speech.
  Measured on nineteen real end-of-dictation remnants: it correctly rejected
  fifteen, and passed four — each of which the model then filled with an
  invented sentence. Trailing remnants are now merged into the previous
  segment, which removes the isolated window without dropping anything, but
  the detector itself is still wrong on those cases.

  **The fix worth building** (J10): `SpeechTranscriber` can return word-level
  time ranges via `attributeOptions: [.audioTimeRange]`. Since it already runs
  during the dictation to drive the live preview, it would give a word-accurate
  speech detector for free — *"no word was heard between 71.2 s and 73.0 s"* is
  a far better signal than a hand-rolled energy threshold. Two conditions: it
  only works while the preview is on, so it must stay an opportunistic
  improvement layered on top of the merge rather than a replacement; and since
  that engine drops audio it fails to understand, its silence should only
  justify skipping short regions, never several seconds.

- **Long-form cost is linear.** A 10-minute dictation is transcribed in one
  pass, but takes roughly 25 s of processing. Acceptable, not instant.
- **Speculative decoding is not possible** on macOS. It requires CTranslate2,
  and the documented `large` + `turbo` pairing is structurally mismatched
  anyway: 80 vs 128 mel bins, 51896 vs 51897 vocab. `small` → `large` share
  both and would be the viable pair.

---

## Licensing — read this before using the models

Caspr's own code and CrisperWhisper's inference code are MIT. **The model
weights are not.**

| Component | License |
|---|---|
| Caspr source code | MIT |
| CrisperWhisper inference code | MIT |
| **CrisperWhisper 2.0 weights** | **Nyra Health Non-Commercial Research** |

The weights are free for research and non-commercial use. Commercial use
requires a licence from [Nyra Health](https://nyra-labs.com/crisperwhisper).
Under a strict reading, dictating work email may itself count as commercial
use.

Consequently Caspr **does not bundle or silently download the weights**. The
licence is shown before any download, and the choice is yours. A
commercially-unencumbered engine is on the roadmap so the app is usable
regardless.

This is a summary, not legal advice. Read
[the licence](https://huggingface.co/nyralabs/CrisperWhisper2.0_turbo/blob/main/LICENSE.md).

---

## Acknowledgements

- [CrisperWhisper](https://github.com/nyrahealth/CrisperWhisper) by Nyra Health
- [Whisper](https://github.com/openai/whisper) by OpenAI

---

## Why permissions break between versions

macOS attaches a TCC grant to the application's **code signature**, not to its
path. Change the signature and the old grant survives, matching nothing that
runs. System Settings keeps showing Caspr ticked while Caspr reports no
access, and unticking then reticking changes nothing — the checkbox drives a
stale record.

Measured on a machine where this had built up: `tccutil reset Accessibility
fr.lyriastudio.caspr` reported success **five times**, one grant per signature
the app had carried across versions.

This is not hypothetical for users. CI builds signed ad-hoc get a fresh
`cdhash` every release, so every update produces a new identity and the same
dead end. **This is the concrete reason to set the two signing secrets**, see
[Signing](#signing-and-why-ad-hoc-is-not-good-enough) — it is not about
Gatekeeper, which is a separate problem needing notarization.

Settings › Autorisations now names this failure and offers to clear the grant,
because nobody works out on their own that a permission is bound to a signature.
