# Caspr

> **Dictation for macOS, two ways.**
> Press a key. Talk. Press it again. Your words land at the caret — written
> offline by macOS, or by ChatGPT through your own account.

Caspr is a menu-bar dictation app for macOS. It does not transcribe anything
itself: it drives one of two recognisers, and puts the text where you were
typing — or in a notes file.

- **macOS** — offline, no account. Your voice is transcribed on your Mac and
  never leaves it.
- **ChatGPT** — through your own ChatGPT account, in a web page Caspr hosts.
  Better transcription, and modules that can rework the text or answer a
  question. Your voice goes to OpenAI, exactly as it would on chatgpt.com.

Caspr has **no server, no account and no telemetry** of its own. You pick the
path, and you can switch at any time.

**Status: in daily use.** Free, MIT-licensed, not notarized (see
[Install](#install)).

---

## Two ways to dictate

The two paths never listen at the same time — see
[why they exclude each other](#architecture). One of them is active, and every
dictation goes through it.

| | macOS | ChatGPT |
|---|---|---|
| Who transcribes | Apple's speech recognition, on your Mac | ChatGPT's transcriber, on OpenAI's servers |
| Where your voice goes | nowhere | to OpenAI, through your ChatGPT account |
| Account | none | a ChatGPT account (email and password — Google sign-in refuses embedded pages) |
| Internet | not needed | required |
| Live preview while you speak | yes | built, not yet confirmed on a real dictation (see below) |
| Retry after a failure | yes — the recording is kept | yes — the raw transcription is kept, and the page's audio once confirmed |
| Waiting for the result | seconds | as long as ChatGPT takes — never cut short by a timer |
| What it adds | — | modules: raw text, reorganise, discuss |
| Setup | a language model macOS may download | sign in, then automatic calibration |
| What can break it | little — it is a system API | a redesign of chatgpt.com (see below) |

### macOS

Caspr uses the best recogniser your Mac can run for the language, and picks it
by itself:

- **Apple Intelligence** (`SpeechTranscriber`, macOS 26 and later) — the
  normal case. macOS downloads the language model once, from System Settings
  or from Caspr's welcome window.
- **System Dictation** (`SFSpeechRecognizer`) — only as an automatic fallback,
  when Apple Intelligence cannot write that language on this Mac. It is never
  offered as a choice: measured on 129 real dictations, it dropped around 44%
  of the words.

Availability is **measured** on the machine, never deduced from a version
number: on a macOS 26 virtual machine, Apple Intelligence reports itself
available and returns empty strings, while Dictation works.

### ChatGPT

Caspr loads chatgpt.com in an embedded web page (a `WKWebView`), signed in
with your own account. When you press the key, Caspr clicks the page's own
dictation button; when you press it again, it stops, reads what ChatGPT
transcribed, and delivers it. What happens next is a **module**, chosen on the
floating bar while you speak:

| Module | Your voice is… | Output |
|---|---|---|
| **Brut** | the text itself | at the caret or in notes; nothing is sent |
| **Réorganiser** | material to put in order | at the caret or in notes, after ChatGPT's reply |
| **Discuter** | a question | nowhere: the page stays open and takes the keyboard |

The instruction is **spoken**, not configured: "translate this into English"
does not fit in a setting. If the second pass fails, you get the raw
transcription — a ten-minute dictation is never lost — and the menu offers
« Insérer la transcription brute de ChatGPT » to recover it after any failure.

**There is no time limit.** A long dictation can take ChatGPT thirty seconds,
or several minutes, to transcribe and answer; Caspr waits as long as it takes,
and only stops waiting when you say so or when the page proves a failure (a
refusal shown, the page's process killed, the session signed out). You can
leave at any moment, instantly — the bar says how:

- **the dictation key** gives up on ChatGPT and still delivers the best text
  in hand: the raw transcription if ChatGPT has returned it, otherwise the
  macOS transcription of the same audio (see below);
- **the × on the bar** cancels everything and inserts nothing; whatever was in
  hand stays in the menu.

**One microphone.** While ChatGPT listens, the page holds the mic, and Caspr
keeps an in-memory copy of the stream the page captures — never written to
disk, unchanged and undelayed for ChatGPT, freed once the text is delivered.
That copy is what lets macOS take over when you give up on ChatGPT, and what
feeds a live preview while ChatGPT listens. It has been verified in a test
harness, not yet on an installed build: until a real dictation logs the audio
arriving (`relais : écho — N s reçues`), the app, this README and the website
keep saying the ChatGPT path has no preview. If the copy receives nothing,
the dictation behaves exactly as before, and the log says so.

**Be clear about what this is.** Caspr drives ChatGPT's *web interface*, not
an API. OpenAI changes that page without notice, and when a button moves, the
ChatGPT path can stop working until Caspr relearns it. Relearning is
automatic: calibration tries each button of the page and keeps only those
whose effect it can see — typing is read back, the mic starts recording, the
reply is copied. It sends **one** test message, announced before it leaves,
and saves nothing until the whole round trip is proven. A manual calibration,
button by button, stays available for the day the automatic one cannot read
the page. The details, and the rules learned the hard way, are in
[`app/RELAIS.md`](app/RELAIS.md).

---

## Privacy, path by path

- **macOS path** — audio is processed in memory on your Mac. No byte of it is
  sent anywhere. Turn off Wi-Fi and it works the same.
- **ChatGPT path** — audio and text go to OpenAI through your account, under
  your account's terms and settings, as they would in a browser. Each
  dictation that sends something opens a new conversation, visible in your
  ChatGPT history; point Caspr at a dedicated ChatGPT project to keep them
  apart. The session lives in Caspr's own WebKit storage, and the uninstaller
  says so.
- **Caspr itself** — no server, no account, no analytics, no tracker. Its only
  network request of its own is the update check: a GET on GitHub's public
  API, sending nothing but an IP address. The automatic daily check is **off
  by default**; « Vérifier maintenant » runs it on demand, and installing an
  update downloads the DMG from GitHub.

History and the notes file stay on your disk, whichever path wrote them.

---

## While you are speaking

A bar floats at the bottom of the screen while you talk, and everything on it
can be changed **without interrupting you**:

- **Destination** — the caret of whatever app you are in, or a notes file.
  The notes file is remembered independently, so switching back and forth
  costs one click, even mid-sentence.
- **Module** (ChatGPT path) — raw, reorganise, discuss.
- **Live preview** — what is being heard, as you speak, written by the macOS
  engine. It answers *"is the mic hearing me"*. On the ChatGPT path it reads
  the copy of the page's audio, once that is confirmed (see above).

Destination and module are read **when the recording ends**, never when it
starts. Pressing *Notes* halfway through a sentence sends that dictation to the
file. The bar never takes focus — it is a non-activating panel — because the
text has to land where your caret already is. And the text goes back to the
app you were speaking in, even if you moved to another one while ChatGPT was
answering.

---

## Switching paths

In Settings › Voie, choosing ChatGPT starts sign-in, then calibration. From
the menu bar menu (« Écrire avec ChatGPT ») or an optional global shortcut,
empty by default, the switch is instant — or, while ChatGPT is not yet signed
in and calibrated, opens its settings instead: a path that refuses every
dictation is not a switch. Switching back to macOS always works. A switch
applies to the next dictation; one in progress finishes on the path it
started with.

While ChatGPT is the path, the menu bar ghost wears a sparkle: the one
permanent sign that your voice goes through your ChatGPT account rather than
staying on the Mac.

---

## Architecture

Either Caspr opens the microphone (macOS), or the ChatGPT page does. Never
both: measured on the recording's peak level, **0.072 before the ChatGPT page
existed, 0.000 on every dictation after** — the page holds the device, and
Caspr's own capture records silence. So the two paths share nothing upstream
but the page's audio, copied in memory; they meet at delivery:

```
                         hotkey  ·  × on the bar
                                │
         ┌──────────────────────┴───────────────────────────┐
         │                                                  │
┌────────▼─────────┐        ┌───────────────────────────────▼───────────────┐
│  VoieApple       │        │  VoieChatGPT — a state machine (RelaisCycle)  │
│  Caspr's mic →   │        │  demarrage → ecoute → transcription → envoi   │
│  Apple Intelli-  │        │  → reponse → lecture → livraison              │
│  gence, or the   │        │  one task, one generation number; the key and │
│  system Dictation│        │  the × decide by table, never a timer         │
└────────┬─────────┘        └──────┬──────────────────────────┬─────────────┘
         │                         │                          │
         │                 ┌───────▼──────────────┐   ┌───────▼──────────────┐
         │                 │  RelaisDictee        │   │  the tee (RelaisEcho)│
         │                 │  the scenario, on    │   │  in-memory copy of   │
         │                 │  one wait primitive: │   │  the page's audio:   │
         │                 │  observe the page,   │   │  live preview, and   │
         │                 │  no deadline         │   │  macOS fallback      │
         │                 └───────┬──────────────┘   └───────┬──────────────┘
         │                 ┌───────▼──────────────┐           │
         │                 │  RelaisPage + bridge │◄──────────┘
         │                 │  a WKWebView on      │
         │                 │  chatgpt.com, its JS │
         │                 │  in its own world    │
         │                 └───────┬──────────────┘
         │   text                  │   text (or the macOS fallback)
         └──────────────┬──────────┘
               ┌────────▼──────────────────┐
               │  Livraison                │
               │  caret or notes file,     │
               │  history, rescue options  │
               └───────────────────────────┘
```

The ChatGPT path is four layers, each leaning only on the one below:
`CasprCore/Relais`, pure and tested (the machine's table, the scenario
replayed against a fake page and a hand-driven clock, the fallback choice,
the bridge's JavaScript, modules); the page (WebKit, no decisions); the
page's life (created on the ChatGPT path only, prepared at the end of each
dictation for the next one, rebuilt when frozen); and the path itself,
`VoieChatGPT`. The details, and the rules learned the hard way, are in
[`app/RELAIS.md`](app/RELAIS.md).

```
caspr/
├── app/             Swift menu-bar app (builds to app/build/, gitignored)
│   ├── RELAIS.md    what the ChatGPT path learned the hard way
│   └── Sources/
│       ├── CasprCore/                 pure logic, under tests
│       │   └── Relais/        the ChatGPT path's decisions: state machine,
│       │                      scenario, fallback, bridge JavaScript, modules
│       └── Caspr/
│           ├── App/          launch, menu bar, logs, permissions, migration
│           ├── Dictee/       the cycle and where the text lands
│           │   ├── DictationController.swift  hotkey, state, Escape
│           │   ├── VoieApple.swift            macOS: mic, transcription
│           │   ├── ApercuEnDirect.swift       the live preview, by the macOS engine
│           │   ├── VoieChatGPT.swift          ChatGPT: the state machine at work
│           │   ├── Livraison.swift            insert, history, retry
│           │   └── Barre/                     the floating bar
│           ├── Apple/        Apple Intelligence, Dictation, their models
│           ├── Relais/       the ChatGPT page: WebKit, its bridge, the
│           │                 audio tee, its life, calibration, settings
│           ├── Reglages/     Settings, one file per tab (CarteVoie: switch paths)
│           ├── Accueil/      the welcome window
│           ├── MiseAJour/    updates
│           └── Desinstallation/  the uninstaller
├── scripts/
│   ├── dev-cert.sh      local signing certificate, so TCC grants persist
│   ├── install.sh       build → sign → /Applications/Caspr.app
│   ├── package-dmg.sh   .dmg containing the app alone
│   └── reset-state.sh   back to a first launch, to test the welcome window
└── website/         the landing page
```

---

## Requirements

| | macOS path | ChatGPT path |
|---|---|---|
| macOS | 14+ — Apple Intelligence needs 26+, Dictation covers the rest | 14+ |
| Chip | any Mac that runs it, Intel included | any |
| Download | a language model, handled by macOS | nothing |
| Account | none | ChatGPT |
| Network | none | always |

---

## Install

### From the release (recommended)

1. Download **[Caspr.dmg](https://github.com/mnaji42/caspr/releases/latest/download/Caspr.dmg)**
   from the latest release.
2. Open it and double-click Caspr. **macOS will refuse the first time** — see
   just below.
3. Once allowed, Caspr offers to install itself in Applications: click
   **Installer et ouvrir**. It copies itself there, ejects the disk image and
   reopens from Applications.
4. A welcome window walks through the choice of path, your languages, the
   microphone and Accessibility, and a first dictation. Choosing ChatGPT opens
   its sign-in page, then calibrates on its own.

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

Settings › Général › Version offers two ways to learn about a new version:

- **Vérifier maintenant** — a one-off check, whenever you feel like it.
- **Vérifier automatiquement** — a switch, off by default, that checks once a
  day and reports in the menu bar menu.

Either way the request is a GET on GitHub's public API, sending nothing but an
IP address. When a new version exists, Caspr shows its release notes and can
download and install it, after checking that it carries the same signing
certificate; otherwise, quit Caspr, download the new DMG and open Caspr from
it: seeing an older copy in Applications, it offers to replace it.

#### Coming from 0.14 or earlier

Versions up to 0.14 could also run a local speech engine, with a background
service, gigabytes of model files, and an optional archive of dictations. It
is gone. On first launch, Caspr stops that service and moves its files, the
archive, and what the app's former name left behind **to the Trash** —
nothing is deleted outright. Empty the Trash to reclaim the space, or take
your recordings back out of the `corpus` folder first. The settings that only
served that engine — its word list and its two writing modes — are erased.

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
| **Microphone** | capture your voice — by Caspr, or by the ChatGPT page, which runs inside Caspr | prompted on first use |
| **Accessibility** | insert text into other apps | System Settings › Privacy & Security › Accessibility |

Accessibility must be granted manually. **You only do this once** — see below.
System Dictation, when macOS falls back on it, also asks for Speech
Recognition.

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
| **⌃⌥⌘D** | same, when you choose a keyboard shortcut instead |
| **Escape** | cancel while recording (no text inserted) |
| **×** on the bar | cancel at any moment, inserting nothing (ChatGPT path) |

Tap **Right Option**, talk, tap again. Text lands at the cursor of the app you
were in when you spoke. Holding the key for a second opens Settings. While
ChatGPT is answering, the dictation key — not Escape — stops the wait, and
still delivers the best text in hand: Escape is a global shortcut, and holding
on to it for minutes would swallow it in every other app.

**Why `⌃⌥⌘D`?** Three constraints narrow this down fast:

- macOS 15+ rejects global hotkeys whose only modifiers are Option and/or
  Shift — an anti-keylogger measure. `⌥Space` cannot work.
- On a French AZERTY keyboard Option types `@ # { } [ ] | \ ~`, so Right
  Option only triggers when it is pressed **and released alone**: Option plus
  a key still types the character.
- A global hotkey steals the combination from *every* app. `⌃⌥D` was already
  taken by Chrome and several editors; three modifiers make collisions rare.

It also needs no Input Monitoring permission, going through Carbon's
`RegisterEventHotKey` rather than a `CGEventTap`.

---

## Uninstalling

Menu bar → **Désinstaller Caspr…**, which opens a window listing everything
Caspr put on the machine, with what each thing weighs, and a checkbox for
each. The app itself always goes; the rest is a choice, and only what is
actually present is listed.

**Nothing is deleted outright — everything goes to the Trash.** That is the
macOS convention, and it is what separates a mistake from a disaster.

| Item | Where |
|---|---|
| The app | wherever it was installed — read from the bundle, not hardcoded |
| Settings and history — **and the ChatGPT session**, named when one is signed in | `~/Library/Preferences/fr.lyriastudio.caspr.plist`, `~/Library/WebKit/fr.lyriastudio.caspr`, `~/Library/HTTPStorages/fr.lyriastudio.caspr.binarycookies` |
| Microphone, Accessibility, Speech Recognition | TCC, via `tccutil` |
| Caches | `~/Library/Caches/fr.lyriastudio.caspr`, `~/Library/HTTPStorages/fr.lyriastudio.caspr` |
| Leftovers of the old local engine, if any | its launch agent, environment, model files and logs (`~/Library/Logs/Caspr`) |

The ChatGPT session is cleared through WebKit's own API before the files are
swept, so no signed-in account is left behind. The login item is removed
unconditionally — left behind, macOS would try to launch a deleted application
at every login.

Your **notes file is never touched**. Caspr wrote into it; it is your document,
not part of the installation.

## Testing a clean install

You cannot judge a first-run experience on the machine that developed it:
permissions are already granted, settings already chosen, ChatGPT already
signed in, and the welcome window never appears.

```bash
./scripts/reset-state.sh
```

This backs up then clears settings and history — the ChatGPT calibration
included —, signs the ChatGPT page out by removing its WebKit data, and
revokes Microphone, Accessibility and Speech Recognition, so the next launch
behaves exactly like a first install. `./scripts/reset-state.sh --all` also
removes the app itself.

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
`releases/latest/download/Caspr.dmg` is a permanent link. The release notes
come from `release-notes/<tag>.md` and are shown inside the app — see
[`RELEASES.md`](RELEASES.md).

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
cd app && swift test
```

The tests cover `CasprCore`, the logic kept free of system dependencies: the
ChatGPT path's rules (the state machine's whole table; a whole dictation
replayed against a fake page and a hand-driven clock — five minutes of
ChatGPT pass in an instant, and a call that never returns is abandoned in
under 200 ms; the fallback's choices; the bridge's JavaScript, compiled and
evaluated in JavaScriptCore; a calibration that must still decode after an
update; modules offered only when the page has learned what they need; the
proofs an automatic calibration must gather before saving anything), the
migration from the old local engine, the choice of path, text composition,
version comparison, and the release notes the app displays. The app target
itself — windows, the microphone, the web page — has no automated tests; it
is checked by hand, on the installed app.

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

Settings › Dictée names this failure and offers to clear the grant, because
nobody works out on their own that a permission is bound to a signature.

---

## Licence

Caspr's code is MIT — see [LICENSE](LICENSE). ChatGPT is a trademark of
OpenAI; Caspr is not affiliated with OpenAI, and the ChatGPT path uses your
own account under OpenAI's terms.
