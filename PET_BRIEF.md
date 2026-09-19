# Chirp Pet — Splendid Fairy Wren Animation Brief

For a design agent producing animated pixel-art sprite assets for
Chirp's floating desktop companion. This describes the character, the
states the app actually needs, and the technical constraints the assets
have to work within — not exact colors or frame-by-frame choreography,
which is the designer's call.

## Update — delivered: hover and chirp

Both shipped and are wired in: `hover` plays while the cursor is over
the wren (replacing the scale/lift placeholder transform that stood in
before this existed), `chirp` plays during onboarding's mic-test step,
pulsing with the live mic level in place of the old abstract waveform
bars (and, before that, the `walk` placeholder this ask replaced). No
further action needed on these two.

## Update — delivered: a walking cycle

Everything below is the original brief and still accurate — it's also
now all actually delivered: idle, idle_preen, idle_tailflick, listening,
processing, activated, and hop have shipped, in the format this
document asked for ("Currently a placeholder" below is now out of date;
the real wren replaced it). This section is the one thing needed on top
of that.

"Optional, if there's appetite: real movement" further down speculated
about the bird actually relocating itself around the screen rather than
just animating in place — that's now a confirmed feature, starting with
walking (not flying): the wren hops/relocates itself to a new spot every
so often while idle, then stands there and resumes normal idle
animation. The one missing piece is a walk cycle:

- **State key**: `walk`, delivered the same way as the states already
  shipped — a `wren_walk_sheet.png` and a `"walk"` entry in
  `pet_sprites.json` alongside the existing ones, same schema (`loop`,
  `sprite_sheet`, `frame_size`, `frame_count`, `frame_durations_ms`).
- **Canvas/format**: identical constraints to every other state — 32×32
  frame size, transparent background, hard pixel edges, the same tight
  palette. Nothing new to calibrate here.
- **Facing**: draw one direction only, facing right. The app mirrors the
  frames horizontally for leftward movement, so there's no need to draw
  or deliver a separate left-facing set.
- **Loop**: yes — this plays continuously for the second or so the bird
  is actually in transit between two points on screen, the same way
  `idle` loops while standing still.
- **Motion character**: per the character notes below, real fairy-wrens
  hop rather than stride — a hopping traverse (both feet leaving the
  ground together, a slight forward lean, optionally a small wing-flick
  on landing) fits the reference better than a smooth human-style walk
  cycle, and reads more clearly at the ~64px this renders at on screen
  than a subtle stride would.
- Same deliverable shape as everything else already sent: numbered PNGs
  or a sprite sheet, transparent background, intended playback speed,
  dropped into the same folder/manifest structure as the rest.

## What this is

A small, always-on-top companion that floats over other windows wherever
the user drags it — click it to bring Chirp's main window forward, and
a small pill beneath it handles starting/stopping dictation and reaching
Settings without needing the hotkey. It replaced an earlier hover-reveal
menu-bar HUD that kept colliding with the Dock; this one lives wherever
the user puts it instead.

Currently a placeholder: a hand-coded 2-frame blinking cat, drawn as raw
pixel-index data directly in Swift (16×16 grid, two frames — open eyes
and a blink). Deliberately simple, deliberately temporary. This brief is
for the real thing.

## The character: a splendid fairy wren

*Malurus splendens* — a small Australian songbird, chosen for its vivid,
genuinely striking look and lively, expressive behavior, both of which
suit a desktop mascot well.

- **Breeding male** (the classic, most recognizable look): crown, ear
  coverts, and mantle a bright iridescent cobalt-to-violet blue; black
  face mask, throat, and upper-back band; chocolate-brown wings; pale
  grey-white belly; a long tail, often cocked upright above the body,
  sometimes edged in a paler blue.
- **Female / non-breeding male**: much more subdued — grey-brown overall,
  a pale blue-grey tail, an eye-ring, warm chestnut/orange around the eye
  on females.
- **Behavior**: energetic hoppers (not walkers), quick flitting flight,
  an almost-always-cocked tail, highly social and active — visibly
  "busy" rather than a bird that sits still.

This is a real reference, not a mood board — a photo search for
"splendid fairy wren male breeding plumage" is the fastest way to
calibrate exact hue before designing. Which plumage to draw is a real,
open creative choice: the vivid breeding-male blue is the more iconic,
mascot-worthy look and reads better at tiny sizes, but nothing here
mandates it over the subtler natural coloring.

## Format — read before designing, it shapes everything else

The placeholder is hand-encoded pixel data rendered through SwiftUI's
`Canvas`. That approach works for a static or 2-frame character; it does
not scale to a real walk cycle or wingbeats.

- **Deliverable: real image assets.** A numbered PNG frame sequence per
  animation, or one sprite sheet with documented, fixed frame dimensions
  — either is fine, just say which. Not vector art, not a single static
  image.
- **Genuine pixel art**: hard edges, no anti-aliasing/blur between
  pixels, a small, disciplined fixed palette (the placeholder uses 5
  colors total — a similarly tight palette per state is the right
  target, not photorealistic shading).
- **Native resolution stays small**: needs to read clearly at roughly
  48–64px on screen. Design at a small fixed size (e.g. 24×24 or 32×32px
  per frame) and let the app scale up with nearest-neighbor, no
  smoothing — designing large and shrinking down loses exactly the
  crispness that makes pixel art read at a glance.
- **Transparent background** on every frame. The bird sits on (or
  replaces) a simple backing shape the app already draws; it shouldn't
  carry its own.
- **Frame count**: as many as an animation genuinely needs, but this is a
  small corner-of-screen companion, not a full-screen game character — a
  4–6 frame loop reads fine here; more mostly costs file size without
  adding perceptible motion.
- **Suggested playback speed per animation** (an FPS or per-frame
  duration) alongside the frames — without it the app is guessing at
  pacing you already have in mind.

## States the app actually needs

Required set — treat extra idle variety etc. as a welcome bonus on top,
not a substitute for these:

| State | When it shows | Notes |
|---|---|---|
| **Idle** | Default, most of the time | 2–3 idle variants the app can cycle between at random intervals would add real charm on their own — a plain loop, a preen, a tail-flick, a head-tilt. Doesn't need to be one committed animation. |
| **Listening / recording** | User has started dictating | Needs to read as clearly different from idle at a glance — an alert posture (head up, tail cocked higher, maybe a slight puff) is the natural real-bird version of "paying attention." |
| **Processing** | Briefly, right after recording stops, while the transcript is produced | Short, probably loopable — a curious head-tilt or a peck works. This state is on screen well under a second most of the time now, so it's not worth heavy investment. |
| **Activated / clicked** | The instant the user clicks it | A quick, satisfying single-shot reaction (a hop, an open-beak chirp implication) rather than a loop — plays once, not repeating. |

## Optional, if there's appetite: real movement

The idea of the bird actually hopping/walking/flying to new positions on
its own, not just animating in place, came up — flagging it as a
genuinely separate, larger question from the animation frames
themselves:

- **Animation-only** (the recommended starting scope): the bird stays
  wherever the user dragged it; only its *in-place* animation changes
  between the states above. This is what the app's current mechanism
  already supports with no further engineering.
- **Autonomous movement**: the bird actually relocates on its own —
  needs real pathing logic, screen-bounds awareness, and some notion of
  staying out of the way (not drifting over the Dock or another app's
  window). This is meaningful additional engineering on top of new art,
  not just more animation frames — worth deciding once the core
  animation set exists, not assumed as part of this pass.

A **hop-in-place** cycle (a small bounce that doesn't relocate the
character) is a low-cost middle ground worth including in the base set
regardless — real bird behavior, cheap to use even if autonomous roaming
never gets built.

## What's deliberately left open

Color harmony with the rest of the app (a calm cream/cobalt-blue palette,
sampled from this bird's own plumage),
exact silhouette and proportions, how stylized vs. anatomically faithful
to go, and whether the current circular backing plate stays or gets
replaced by something the bird's own art implies (a perch, a branch) —
all open. The wren's natural coloring is vivid and doesn't need to match
the app's own palette; most desktop mascots (Clippy, Duolingo's owl)
carry their own distinct identity rather than being reskinned in the
host app's colors, and that's a reasonable default here too, but not a
mandate.

## Deliverable

Per state above: a frame sequence (numbered PNGs, or one sprite sheet
with documented frame dimensions/order/count) at a small fixed pixel
resolution, transparent background, hard pixel edges, plus intended
playback speed. A style/proportion reference sheet up front — even one
static "here's the character" frame — is more useful to align on early
than polished animation for a design nobody's confirmed yet.
