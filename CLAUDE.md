# Chirp — build and development notes

macOS menu-bar dictation app. Swift Package (no `.xcodeproj`), SwiftUI +
AppKit, everything on-device.

## Building

**Use the full Xcode toolchain, not Command Line Tools.** SwiftUI's macros
(`@State`, `@Published`, …) are compiler plugins that only ship with
Xcode. With `xcode-select` pointed at CommandLineTools every SwiftUI file
fails with `external macro implementation type 'SwiftUIMacros.StateMacro'
could not be found`, or the build system fails to start at all with
`Unknown error parsing property list`.

```bash
# One-time, if `xcode-select -p` prints /Library/Developer/CommandLineTools:
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Per-command alternative, no sudo:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

| Command | What it does |
|---|---|
| `swift build` | Debug binary at `.build/debug/Chirp`. Fast; use while iterating. |
| `./scripts/make_app.sh` | Release build, assembles and signs `build/Chirp.app`. **Required to actually run the app** — see below. |
| `./scripts/make_release.sh` | Notarisable release artifact. |
| `./scripts/make_icon.sh` | Regenerates `Resources/Chirp.icns` from the SVG. |
| `./scripts/build_harper.sh` | Rebuilds the vendored Harper grammar xcframework from `Vendor/harper-ffi`. |

### Why you can't just run the bare binary

`swift build` produces a binary, but the app needs a real `.app` bundle:
the global hotkey, Accessibility pasting and microphone access are all
granted per bundle identity, and bundled resources (fonts, pet sprites)
are looked up via `Bundle.main` at `Contents/Resources/…` rather than
SwiftPM's generated resource bundle — SwiftPM puts that at the app's top
level, where codesign's resource sealing rejects it. `make_app.sh` copies
them into the right place. See `FontLoader.registerManrope()` and
`PetSpriteStore` for the Bundle.main-first lookup both use.

### Keeping permissions across rebuilds

Run `./scripts/make_signing_cert.sh` once. It creates a local self-signed
certificate so the bundle keeps a stable identity, and macOS keeps your
Accessibility/Microphone grants between rebuilds. Without it the app is
ad-hoc signed and you re-grant Accessibility every single build, which
makes testing the hotkey miserable.

## Running and testing

```bash
./scripts/make_app.sh && open build/Chirp.app
```

Chirp is a menu-bar app with **no Dock icon**. The main window is opened
by clicking the menu-bar icon or the floating wren. `open build/Chirp.app`
on an already-running instance triggers `applicationShouldHandleReopen`,
which reopens the window — plain `activate` does not.

**Quit it with `osascript -e 'tell application "Chirp" to quit'`, never
`pkill`.** History is a JSON file written on change; SIGTERM mid-write
truncates it, and the app then rewrites it empty on next launch. This has
already destroyed a transcript history once.

### CLI modes (no GUI, no permissions needed)

```bash
.build/debug/Chirp --selftest                       # formatter + learning tests
.build/debug/Chirp --transcribe audio.wav
.build/debug/Chirp --format "um hello new line hi"  # cleanup pipeline only
.build/debug/Chirp --transform "fix this grammer"   # on-device LLM polish
```

These are the only automated tests in the repo. There is no XCTest suite;
`--selftest` is the regression net for the text pipeline.

## Releasing

Version lives in one place: the `VERSION` file at the repo root.
`CFBundleShortVersionString` is read from it, `CFBundleVersion` is the
commit count, and the git tag and GitHub release are derived from it —
so they can't drift apart.

```bash
echo "2.2.0" > VERSION
# …add a matching ## 2.2.0 section to CHANGELOG.md…
git commit -am "Release 2.2.0"

./scripts/publish_release.sh             # dry run: builds + shows the plan
./scripts/publish_release.sh --publish   # tags, pushes, creates the release
```

The dry run is the default deliberately. A tag and a release are public
the moment they exist, and deleting one afterwards doesn't remove it from
clones or from users' update checks.

Preflight refuses to publish if: `gh` isn't authenticated, the working
tree is dirty, the tag exists, the built version disagrees with `VERSION`,
the app fails signature verification, there's no CHANGELOG section for the
version, or **`UpdateChecker.repo` doesn't match the repo you're pushing
to** — that last one silently breaks in-app updates, so it's worth the
hard failure.

### Signing and what it does not do

`scripts/make_signing_cert.sh` creates a self-signed certificate "Chirp
Dev" in your login keychain. It gives downloaders **no** trust benefit —
`codesign -dv` on the result shows `TeamIdentifier=not set`, and Gatekeeper
treats the app as unidentified either way. Its actual job is signature
*stability*: macOS ties Accessibility and Microphone grants to the bundle
ID plus its signature, so a stable cert means users (and you) don't
re-grant permissions on every rebuild and every update.

The private key never leaves your keychain, and the signature embeds
nothing identifying beyond the certificate name. But it does mean:

- Only the machine holding that key can produce signed builds.
- If you lose it and generate a new one, existing installs see a changed
  signature and users have to re-grant Accessibility.

So back the certificate up (Keychain Access → export as `.p12`) and keep
it **out of the repo**.

Notarisation — the thing that actually removes the Gatekeeper warning —
needs a paid Apple Developer account, a Developer ID Application
certificate, hardened runtime, and a `notarytool` submit-and-staple step
added to `make_release.sh`. Not currently set up.

## Where things live

```
Sources/Chirp/
  AppDelegate.swift      App lifecycle, dictation pipeline, `Settings` (UserDefaults)
  AppShell.swift         Window shell + sidebar rail
  DesignSystem.swift     Shared components (page shell, surfaces, controls)
  DesignTokens.swift     Palette, type ramp, radii, motion
  ChirpIcons.swift       SVG path data + a tiny path parser
  *View.swift            One file per page
  PetPanelController.swift  The floating wren: panel, wander/flight, bubble
  Transcriber.swift      Recognition; TextFormatter/LearnedStore/HarperChecker
                         are the cleanup chain applied after it
```

Runtime data (history, snippets, dictionary, learned corrections) lives in
`~/Library/Application Support/Chirp/`. Preferences are in the
`local.chirp` defaults domain — `defaults read local.chirp`. Note that
`defaults read` can serve stale cached values while the app is running.

## First-run presets

`TextFormatter.starterDictionary` and `SnippetStore.starterSnippets` are
written **once**, only when their JSON file has never existed — never
re-added if the user clears them. Both pages have a "Remove all" that
says so.

Dictionary presets are casing fixes only (`iphone` → `iPhone`), never
word substitutions. `applyDictionary(to:)` rewrites every match in every
transcript case-insensitively, so a preset is a silent edit to text the
user is about to send: anything ambiguous ("set up" vs "setup", "log in"
vs "login") corrupts meaning with no visible cause. Changing only the
casing of an unambiguous proper noun can't change what a sentence says.
Snippets carry the richer presets instead — one only fires when you say
its trigger out loud, so a preset that doesn't suit you costs nothing.

## Design conventions

- **Type**: New York (system serif, `Font.chirpDisplay`) for page and
  section titles; Manrope (bundled, `Font.manrope`) for all interface
  text. Only four Manrope weights are bundled — adding a call site for a
  weight that isn't there silently falls back to the system font.
- **Surfaces**: one paper ground (`Palette.paper`) from titlebar to
  bottom edge. Cards use `.chirpSurface()` — never a bespoke white
  rounded rectangle. Structure comes from hairlines and whitespace; the
  app deliberately has almost no shadows.
- **Colour**: cobalt is an accent, used sparingly. There is no dark mode —
  `NSApp.appearance` is pinned to aqua at launch, so every `Palette`
  value is a plain fixed `Color`.
- **Pages**: no promo heroes, no banners restating the title, no
  accordions hiding short content. A page opens on its own content.

## Gotchas

- **Swift 6 warnings**: three pre-existing main-actor/Sendable warnings in
  `AppDelegate` and `MeetingDetector`. They are warnings today and errors
  under the Swift 6 language mode.
- **`Palette` in popovers/dropdowns**: content presented outside a page's
  `.light` pin can resolve colours differently. Attach `.sheet`/`.popover`
  at the call site, outside `GlassPanelPage`'s content closure.
- **Pet panel geometry**: the wren — not the window — is the fixed point.
  `PetPanelController.resize(to:)` solves the frame from the bird's own
  top edge and centre so the pill can grow below it and the transcript
  bubble above it without the bird appearing to move.
