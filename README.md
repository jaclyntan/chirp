<p align="center">
  <img src="Resources/Promo/chirp_promo_landscape_1920x1080.png" alt="Chirp" width="640">
</p>

**Private voice dictation for macOS — everything runs on your Mac.**

Hold `fn`, speak, release. Clean text appears at your cursor in any app.
No cloud, no account, no subscription, no word limits.

## Install

Download the latest `Chirp.dmg` from
[Releases](https://github.com/jaclyntan/chirp/releases/latest), open it,
and drag Chirp to Applications.

**The first launch needs one extra step.** Chirp is signed with a
self-signed certificate rather than a paid Apple Developer ID, so macOS
will refuse to open it normally and may claim it is "damaged". It isn't —
that's just what macOS says about any app it can't trace to a paid
developer account.

1. Right-click (or Control-click) Chirp in Applications → **Open**.
2. Click **Open** again in the dialog.

You only do this once. If the right-click route doesn't offer Open, go to
**System Settings → Privacy & Security**, scroll down, and click **Open
Anyway** next to the message about Chirp.

Chirp then asks for two permissions:

- **Microphone** — to hear you.
- **Accessibility** — to watch for the global hotkey and paste the result.
  Without it, transcripts are copied to your clipboard instead of typed.

Chirp lives in the menu bar and has no Dock icon. Click the menu-bar icon
or the floating wren to open the window.

### Requirements

macOS 26 (Tahoe) or newer, on an Apple Silicon Mac.

## What it does

- **Push-to-talk** — hold `fn` (or right ⌥) anywhere; release to paste at
  your cursor. Double-tap for hands-free.
- **On-device recognition** — Apple's SpeechAnalyzer. Instant, no model
  download, works offline.
- **Cleanup** — removes filler words, handles spoken "new line" and "new
  paragraph", capitalises, applies your personal dictionary, and expands
  snippets (say a trigger phrase → paste a saved block). Terminals and
  code editors get your exact words, untouched.
- **Grammar pass** — [Harper](https://github.com/Automattic/harper) catches
  agreement, punctuation and repeated words. Deterministic, milliseconds,
  no model.
- **Learns your corrections** — fix a transcript in History and Chirp
  remembers the misheard word for next time. Ships with starter snippets
  and dictionary entries to edit or clear out wholesale.
- **Live transcript**, optionally — see the words appear in the wren's
  speech bubble as you speak.
- **Opens at login**, optionally — so the dictation key works without
  launching anything first.
- **Notetaker** — captures a call from your mic and the meeting app's
  audio, separates speakers, and writes up a transcript locally. Optional
  on-device summary, per note.

## The wren

<p align="center">
  <img src="Resources/Pet/wren_idle.gif" alt="Idle" width="88">
  <img src="Resources/Pet/wren_hop.gif" alt="Hop" width="88">
  <img src="Resources/Pet/wren_listening.gif" alt="Listening" width="88">
  <img src="Resources/Pet/wren_walk.gif" alt="Walking" width="88">
  <img src="Resources/Pet/wren_chirp.gif" alt="Chirping" width="88">
</p>

Chirp's mascot is a splendid fairy-wren — a small, vividly blue Australian
songbird — drawn as 32×32 pixel art on a ten-colour palette, with a
silhouette outline on every frame so it stays legible against any
wallpaper.

It's not just a logo. A floating wren sits on your desktop and reacts to
what the app is doing: alert while listening, head-tilted while working,
preening and tail-flicking when idle. It shows what you just dictated in
a speech bubble you can copy or discard from, so a quick dictation never
needs the main window. Left to its own devices it hops and flies to new
spots on screen — or you can pin it in place from its own toolbar.

## Privacy

Everything runs on this Mac. Recognition is Apple's on-device
SpeechAnalyzer, and every cleanup pass after it — filler removal, your
dictionary, learned corrections, Harper's grammar lint — is deterministic
local code, not a model. The one exception is Notetaker's optional
Summarize, which you trigger yourself and which runs on Apple
Intelligence, still on-device.

Chirp makes no network requests except macOS's own one-time speech-asset
download and a version check against GitHub at launch. The one exception
is opt-in: turning on **Live transcript while speaking** fetches a ~220 MB
streaming model the first time it runs. It's off by default for exactly
that reason. Transcripts live only in
`~/Library/Application Support/Chirp/`.

## Building from source

```bash
git clone https://github.com/jaclyntan/chirp.git
cd chirp
./scripts/make_signing_cert.sh   # once — keeps permissions across rebuilds
./scripts/make_app.sh            # builds build/Chirp.app
open build/Chirp.app
```

Requires full Xcode, not just Command Line Tools — SwiftUI's macros are
Xcode-only compiler plugins. Build, test, architecture and design notes
are in [CLAUDE.md](CLAUDE.md).

## Architecture

Swift Package, SwiftUI + AppKit. Harper is vendored as a prebuilt
xcframework under `Vendor/` with its Rust source included; FluidAudio is a
remote SwiftPM dependency used for voice-activity detection and
Notetaker's speaker separation. See [NOTICE.md](NOTICE.md) for
third-party licences.

```
HotkeyMonitor  →  AudioRecorder  →  Transcriber (Apple SpeechAnalyzer)
                                        ↓
        TextFormatter → LearnedStore → SnippetStore → HarperChecker
                                        ↓
                        TextInserter (clipboard + ⌘V)
```

Recognition engines trialled and removed (WhisperKit, whisper.cpp,
Parakeet) are written up in
[docs/removed-engines.md](docs/removed-engines.md).
[CHANGELOG.md](CHANGELOG.md) covers what changed in each release.

## Credits

Chirp began as a fork of
[Murmur](https://github.com/janisbelozerovs-dev/murmur) and has since
diverged substantially — several recognition engines and features were
removed, and the interface was rebuilt. Murmur is MIT-licensed and its
copyright notice is retained in [LICENSE](LICENSE). Thanks to its authors
for the foundation.

## License

[MIT](LICENSE). Not affiliated with Apple.
