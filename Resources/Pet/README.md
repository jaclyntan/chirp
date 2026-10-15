# Chirp Pet — Splendid Fairy-Wren sprite set

Updated pixel animations: 15 states on transparent 32×32 canvases.
The app renders numbered PNG frames with nearest-neighbour scaling and
uses each frame’s individual duration from `pet_sprites.json`.

## States

| State | Frames | Loop | App use |
|---|---:|---|---|
| `idle` | 4 | yes | Resting |
| `idle_preen` | 6 | yes | Idle variation |
| `idle_tailflick` | 4 | yes | Idle variation |
| `listening` | 4 | yes | Recording |
| `processing` | 4 | yes | Transcribing |
| `activated` | 7 | no | Clicked |
| `hop` | 4 | yes | Idle variation |
| `walk` | 6 | yes | Ground travel |
| `hover` | 5 | yes | Cursor hover |
| `chirp` | 5 | yes | Transcript bubble and onboarding mic test |
| `flight` | 6 | yes | Airborne travel |
| `side_perch` | 7 | yes | Bundled for future interactions |
| `sleep` | 4 | yes | Bundled for future interactions |
| `blink` | 5 | no | Idle variation |
| `celebrate` | 8 | no | Bundled for future interactions |

## Files

- `Resources/Pet/`: updated editable Aseprite sources, GIF previews, and
  full `manifest.json`. Existing reference and review sheets document the
  original design; they are not previews of the updated animations.
- `Sources/Chirp/Resources/Pet/`: updated sprite sheets, numbered PNG
  frames, and the runtime `pet_sprites.json`, generated from the full
  manifest so all 15 states retain their timing and loop flags.
- `Package.swift` bundles the runtime Pet directory. `scripts/make_app.sh`
  copies it into the app’s `Contents/Resources/Pet`.

`activated`, `blink`, and `celebrate` play once. The animator supports
completion callbacks after the final frame’s hold; other states loop
unless the caller requests a single idle cycle.
