# Chirp — UI Design Brief

For a design agent producing wireframes/prototypes. This describes the
product, its scope, and the screens/states to design — not visual style.
Typography, color, motion, and layout are open; see "Direction" below for
the one constraint that matters.

## What this is

A macOS menu bar app for voice dictation. Hold a key, speak, release the
key — clean text appears at the cursor in whatever app is focused. Runs
entirely on-device: no cloud, no account, no network calls during
dictation. English only.

It is a **rebuild** of an existing, working app (same name, same engine
code) — the UI is being redesigned from scratch because the current one
reads as a copy of a well-known competitor (Wispr Flow) and the product
itself is being cut down from a sprawling multi-feature app to a small,
fast, focused one. The engine (audio capture, speech recognition,
grammar/formatting, hotkey handling) is untouched and proven; only the
interface and the feature set are up for redesign.

## Direction

**Not a Wispr Flow clone.** The current UI (menu bar icon → floating HUD →
card-based settings window, warm/pastel palette, rounded glass panels) is
the thing being moved away from. The design agent has real freedom here —
the ask is a distinct visual identity, not a specific alternative style.
The one hard constraint: it must still feel *fast and quiet*, because the
product's whole premise is that dictation should be nearly instant and
should not get in your way. Whatever direction is chosen, avoid anything
that reads as ceremony — loading screens, multi-step confirmations,
decorative animation — sitting between "release the key" and "text
appears."

## Scope

### In scope (design these)

| Feature | What it does |
|---|---|
| **Push-to-talk dictation** | Hold `fn` (or right ⌥) anywhere, speak, release → text pastes at the cursor. Double-tap toggles hands-free (start/stop without holding). |
| **Menu bar presence** | Lives in the menu bar; no Dock icon. Icon reflects state (idle / recording / processing). |
| **In-flight status (HUD)** | A small, non-stealing-focus overlay shown only while recording/processing — mic state, maybe a waveform, a brief status label ("Listening…", "…"). Disappears the moment text is inserted. |
| **History** | A list of past dictations (recent, searchable). Click to copy. Correcting a saved entry's text feeds pronunciation learning (see below) — this is the *only* way that learning happens, so keep the edit affordance even though the list itself is being kept minimal. On disk this is small regardless of how long it's kept (measured: well under 1 MB even at the cap), so there's no size-driven reason to limit it further — the goal in trimming it is visual quiet, not storage. Should not be a permanent on-screen fixture — tucked behind one click/tab, collapsed or hidden by default, not a landing page. |
| **Personal dictionary** | User-maintained list of spoken → corrected-spelling pairs (e.g. brand names, jargon). Add/edit/delete. |
| **Pronunciation learning (implicit)** | When the user corrects a transcript (in History), Chirp learns the mishearing → correct-word mapping automatically. This has no dedicated screen — it's a background effect of editing History — but the design should make it discoverable/visible that corrections "stick." |
| **Snippets** | Say a trigger phrase during dictation → it expands into a saved block of text. List view: trigger, expansion, times-used. Add/edit/delete. |
| **Developer vocabulary** | A built-in list of dev/AI-tool terms (Claude, Xcode, Supabase, etc.) that biases recognition when dictating into a recognized developer app (terminal, editor, AI coding tool) — detected automatically by which app is frontmost, not a mode the user switches. Needs: a way to see it's active/what it covers, and a per-app override (force on/off for a specific app) if auto-detection gets it wrong. Likely a settings toggle plus a simple per-app exceptions list, not a large surface. |
| **Notes** (was "Notetaker") | Two ways in: (1) **meeting capture** — detects an in-progress meeting via calendar or (optionally) the active browser tab, records mic + system audio, transcribes it; (2) **brainstorm capture** — user-initiated (a hotkey or button, no meeting needed), records mic only, transcribes it. Both converge on the same on-demand "Summarize" step — an explicit action the user presses, not something that runs automatically, which turns a rambling transcript into a structured note (title, key points, action items where relevant). This is a deliberate, scoped exception to the no-LLM-by-default rule below: it's fine specifically *because* it's opt-in per note rather than paid on every dictation. Needs: a subtle "meeting detected, start capture?" prompt (meeting path only), a plain "start a note" entry point (brainstorm path), a recording-in-progress state, a saved-notes list, and a note detail view that reads fine both before and after summarizing (transcript alone, or transcript + summary). |
| **Onboarding** | First-run only: permissions (Microphone, Accessibility), a mic test, done. Should be short — this app has far fewer settings than before. |
| **Settings** | Hotkey rebinding, engine/model choice (if more than one ships), Raw mode toggle (skip all cleanup for a given app — useful for terminals/code editors), the dictionary/snippets/dev-vocabulary surfaces above, permissions status. |

### Explicitly out of scope (do not design)

Everything below is being removed from the product, not just hidden:

- Style rewriting (Formal/Casual/Very casual tone passes)
- Note templates (voice-triggered restructuring)
- Transforms (⌥-triggered rewrite shortcuts, custom or built-in)
- Ask Chirp (querying dictation history via LLM)
- Voice Profile (persona derived from dictation history)
- Insights (word count, WPM, streak charts)
- Scratchpad (floating notes panel)
- Per-app **tone/template** profiles (per-app **Raw toggle** and **dev-vocabulary override** survive, above — the tone/template layer they used to sit alongside does not)
- Multi-language support (English only)
- Multiple recognition-engine marketing/comparison UI — if multiple engines ship, this is a plain settings picker, not a feature in itself
- In-app changelog/legal/update-checker as dedicated screens (fold into a single "About" if needed at all)

All of the above depended on an on-device LLM step that added several
seconds of latency to *every dictation* — the whole rebuild exists to get
rid of that wait, so nothing that requires it belongs in the automatic,
default dictation path. That's specifically about the default path, not
a ban on the model existing in the app at all: Notes' on-demand
"Summarize" (above) uses the same on-device model, deliberately, because
it's an explicit action the user opts into per note rather than a cost
paid on every single utterance. The rule is "never automatic, never
blocking the fast path" — not "never present."

## Interaction model / constraints for the design agent

- **No main window by default.** This is a menu bar utility, not a
  document app. Settings/History/Snippets/Dictionary/Notes open in one
  lightweight window (tabs or a sidebar, agent's call), not separate
  windows. The app should be almost invisible when not actively recording.
- **The HUD is the only UI most users see most days.** It appears for a
  couple of seconds, at most, per dictation. It deserves real design
  attention — it's the product's actual face — but it must never demand
  interaction; recording/pasting must never wait on it.
- **Permissions are a hard requirement, not optional.** Microphone and
  Accessibility (for the global hotkey and paste) must be granted before
  dictation works at all. Onboarding needs to make this unavoidable but
  not tedious — a real OS permission prompt is involved, so there's a
  "waiting on the system" state to account for.
- **Speed is a design constraint, not just a backend one.** Any screen
  that appears in the dictation path itself (not Settings/History, which
  are opened deliberately) should assume near-zero patience from the
  user.

## States worth designing per relevant screen

- Empty states: no history yet, no snippets yet, no dictionary entries yet
- Recording / processing / done (HUD)
- Permission not granted / granted / needs re-grant after rebuild
- Notes: no meeting detected / meeting detected, awaiting start /
  brainstorm recording (user-initiated, no meeting) / recording /
  transcribing / transcript saved (no summary yet) / summarizing /
  summarized
- Engine or model not yet downloaded (if applicable) — a one-time,
  non-blocking background state, not a modal

## Deliverable

Wireframes/prototypes for: menu bar icon + its states, the HUD, Settings
(with its sub-sections), History (as a minimal, tucked-away view, not a
landing page), Snippets, Dictionary, Notes (both entry points, list +
detail + in-progress + summarize), and first-run onboarding. A rough flow
diagram (first launch → permissions → first dictation) is more useful up
front than polish on any single screen.
