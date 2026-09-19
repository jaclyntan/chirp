# Chirp Pet — Splendid Fairy-Wren sprite set

Generated from `PET_BRIEF.md`. Replaces the hand-coded 2-frame placeholder
cat (`CatPixels` / `PixelCatView` in `PetPanelController.swift`) with real,
animated pixel-art image assets.

## Character

Male splendid fairy-wren (*Malurus splendens*), breeding plumage. The
brief's own written colour description ("chocolate-brown wings; pale
grey-white belly") reads closer to a *superb* fairy-wren than the actual
species — checked against Australian Museum / BirdLife Australia
reference photos per the brief's own instruction to calibrate against
real images rather than the mood-board wording. Designed against the
verified look instead: predominantly vivid cobalt-to-violet blue body,
black mask/throat, brown-with-a-blue-wash wings and tail, pale belly.

## Format

- **32×32px native canvas**, transparent background, hard pixel edges, no
  anti-aliasing. Chosen over 24×24 to keep the wing/tail/legs readable as
  distinct shapes — this is a full small bird, not an icon glyph — while
  still resolving cleanly at the ~48–64px on-screen size (checked at 2×
  with nearest-neighbour scaling, see `review_contact_sheet.png`).
- **10-colour fixed palette** (9 colours + transparency), reused across
  every state and frame — see `reference_sheet.png`.
- **1px outline** on the whole silhouette, added after every other
  element. The pet floats over an arbitrary desktop background, not just
  the app's own cream panel, so it needed to hold its shape against dark
  wallpapers and busy photos too, not only the app's own palette —
  checked on cream, near-black, and a mid-tone photo background.
- Every animation is a **horizontal-strip sprite sheet**, fixed
  32×32-per-frame, left to right (`sprite_sheet_layout` in
  `pet_sprites.json`) — plus the same frames as a numbered PNG sequence,
  so either loading style works.

## States delivered

| File prefix | Maps to brief's | Loop | Frames | Notes |
|---|---|---|---|---|
| `wren_idle` | Idle — default | yes | 4 | Deliberately subtle: a slow breathing sway, not competing with the variants below. |
| `wren_idle_preen` | Idle — variant | yes | 6 | Head dips to the flank and back. |
| `wren_idle_tailflick` | Idle — variant | yes | 4 | Quick flick breaking up a long hold. |
| `wren_listening` | Listening / recording | yes | 4 | Head raised, tail cocked near-vertical, a slight puff — reads as clearly different from idle at a glance. |
| `wren_processing` | Processing | yes | 4 | Small, fast head-tilt loop; kept cheap since it's on screen well under a second most runs. |
| `wren_activated` | Activated / clicked | **no** | 7 | Single-shot hop + tail flare (the "chirp" reaction). Ends back at the idle rest pose so it blends cleanly into idle afterwards — play once, don't loop. |
| `wren_hop` | Hop-in-place (bonus, brief explicitly calls this worth including) | yes | 4 | Small bounce, stays in place — no positioning/pathing logic needed. |
| `wren_walk` | Walk — the brief's "Update" ask, for autonomous relocation | yes | 6 | Hopping traverse, facing right only (the app mirrors frames for leftward travel). Uses `wren_pet.py`'s `lean` parameter — previously declared but unused — for a genuine forward pitch through the airborne frames, plus a small wing-flick on landing. Animation only; the actual pathing/relocation logic that would play this state is not part of this delivery (see integration note below). |
| `wren_hover` | Hover — cursor-over reaction, replacing the placeholder scale/lift transform | yes | 5 | Perkier/more curious than `listening`, per the brief's own distinction. Perks up into a genuine body puff (new `puff` param — a modest, head-untouched scale-up of the body silhouette) with the highest tail cock of any state, then a small curious dip-and-recover partway through the hold so it doesn't read as just a taller static pose. |
| `wren_chirp` | Chirp — genuine singing pose, used during onboarding's live mic-level reactive step | yes | 5 | Head tilted back, beak visibly open via the new `beak_open` param — two separate mandibles with a pale open-mouth wedge filled in between them (plain transparent gap didn't read at 32px, right next to the black eye-mask). Checked against `activated`'s own frames first per the brief's instruction — confirmed that one reads as a hop/dive lunge, not a sing, so this is genuinely new art, not a relabel. |

The three idle variants are meant to be cycled between at random by the
app, per the brief.

Exact per-frame durations are in `manifest.json` (design-side, full
detail) and `Sources/Chirp/Resources/Pet/pet_sprites.json` (runtime-side,
just what a player needs: loop flag, sheet name, frame size, durations).

## Where things live

- **`Resources/Pet/`** (this folder) — editable `.aseprite` sources (one
  per state), GIF previews, the proportion/palette reference sheet, the
  frame-by-frame self-review contact sheet, and `manifest.json`. Design
  source of truth; mirrors how `Chirp.svg` / `Chirp.icns` /
  `ChirpMascot.png` already sit at the repo's top-level `Resources/`
  rather than inside the SwiftPM target.
- **`Sources/Chirp/Resources/Pet/`** — the runtime assets: one sprite
  sheet PNG + one numbered-PNG sequence per state, plus
  `pet_sprites.json`. Mirrors `Sources/Chirp/Resources/Fonts/`, the
  existing precedent for a bundled binary-resource folder.

## Integration note (not done here — flagging, not deciding)

This delivers the art and its pacing data, not the Swift wiring:

- `Package.swift`'s executable target only declares
  `resources: [.copy("Resources/Fonts")]`. A `.copy("Resources/Pet")`
  entry needs to be added alongside it, or these assets won't ship in the
  built app.
- `AppDelegate.UIState` currently has three cases — `idle`, `recording`,
  `processing` — with no fourth case for "activated." Since
  activated/clicked is specified as a one-shot reaction to the click
  itself rather than a standing mode, it likely wants to fire as a
  transient animation trigger from `PetView`'s existing click handling
  rather than a new persistent enum case, but that's an app-wiring
  decision for whoever wires this up, not an art one.
- `PixelCatView` / `CatPixels` in `PetPanelController.swift` is the code
  this set is meant to replace — it currently draws pixel data by hand
  through SwiftUI `Canvas`, which is exactly what the brief says doesn't
  scale past a 2-frame character.
