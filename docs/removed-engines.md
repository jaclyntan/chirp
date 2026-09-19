# Removed recognition engines

As of this pass, Chirp ships with exactly one recognition engine: Apple's
on-device `SpeechAnalyzer`/`SpeechTranscriber`. Three others existed and
were deliberately removed, not just hidden — this doc is the "how to bring
one back" reference the removal traded away by deleting their source.

## Why they were removed

Fewer dependencies, deliberately, once English-only + fast + local were
settled as the actual priorities:

- **Zero added dependency.** Apple's engine is already on the Mac — no
  vendored framework, no model download/version management, no separate
  settings UI to keep in sync.
- **Streaming.** `SpeechTranscriber.results` is already an incremental
  async sequence. Whisper-family models are architecturally batch-only —
  a full fixed window in, one transcript out — so they were the actual
  blocker on ever getting dictation to feel instant, not just slow today.
- **Vocabulary biasing already works on Apple's engine**
  (`AnalysisContext.contextualStrings`, see `Transcriber.swift`), which
  was Parakeet's specific gap (no decoder-prompt equivalent, and its
  production model had no boosting path at all — only the excluded,
  buggy "Flash" variant did).

None of this is a claim that Apple's engine is strictly *better* on
accuracy — that was never actually benchmarked head-to-head on real
dictation before this decision, and is worth doing if engines come back.

## What existed, and where its ideas still apply

### WhisperKit (`WhisperEngine.swift`, 215 lines)

CoreML Whisper on the Neural Engine, via
[WhisperKit](https://github.com/argmaxinc/WhisperKit). Vocabulary fed as
a decoder prompt. Package dependency:
`https://github.com/argmaxinc/WhisperKit.git`.

### whisper.cpp (`WhisperCppEngine.swift`, 335 lines)

The same Whisper models, run via Metal instead of the Neural Engine —
faster, more battery cost. Vendored as `Vendor/whisper.xcframework`
(binary target `WhisperCppFramework` in `Package.swift`) — **that
xcframework was deleted along with this file**; it would need rebuilding
from source (see `scripts/build_harper.sh` for the shape of that kind of
build script, though that one is for Harper, not whisper.cpp) or
re-vendoring from a released build.

Notable, real findings worth not re-discovering the hard way:

- **Silence hallucination.** Whisper-family models confidently hallucinate
  sign-off phrases ("Thank you.") on near-silent audio that still clears
  a signal-duration gate, with a *tiny* "no speech" probability
  (measured: ~0.00002) — the model's own confidence score doesn't catch
  this. `HallucinationFilter.swift` exists because of this and is
  engine-agnostic (kept, unused by anything now, but ready if a
  Whisper-family engine returns).
- **Model download integrity was a real, flagged gap.** The original
  download fetched from a mutable `resolve/main/` HuggingFace ref with no
  hash pinning, parsed by a C++ reader with a history of malformed-input
  CVEs — in a process holding Accessibility + Microphone. Pin the commit
  SHA and verify a checksum against a hardcoded manifest before
  reinstating any model download path.
- A dedicated Latvian fine-tune (University of Latvia AI Lab, Interspeech
  2025) was available as a whisper.cpp model option — 3.2% WER vs.
  Parakeet v3's 22.84% on Latvian. Irrelevant while English-only; relevant
  again if multi-language ever comes back.

### Parakeet (`ParakeetEngine.swift`, 676 lines)

NVIDIA's TDT model via [FluidAudio](https://github.com/FluidInference/FluidAudio)
(CoreML, Neural Engine) — the fastest of the three removed engines, and the
one whose *library* is still a live dependency (see below).

- **No vocabulary biasing on the production path.** Parakeet's transducer
  architecture has no decoder-prompt hook the way Whisper does; the
  `CustomVocabularyContext` boosting mechanism only worked on the
  excluded "Flash" model (kept out of `availableModels` for a real,
  reproducible bug: `finish()`'s zero-padded final chunk could drop the
  last word or two of a *complete* recording). `DeveloperVocabulary.swift`
  still carries Parakeet-specific similarity-floor tuning in comments —
  harmless dead reference now, real prior art if Parakeet returns.
- **This is the one worth genuinely reconsidering for streaming.**
  Transducers decode incrementally by construction. `LivePreviewTranscriber.swift`
  (kept — see below) already proves the FluidAudio streaming API works in
  this codebase; it was never promoted from "cosmetic preview" to "the
  real transcription path." See the session notes on why a pull-based
  delta + off-main-actor execution (not the original push-queue design)
  is what actually gets this working smoothly.

## What did *not* get removed, and why

`FluidAudio` is still a live package dependency. Nothing about "Apple
only" implied dropping it — it powers three things with no relationship
to which *main* engine is selected:

- `VadEngine.swift` — the voice-activity-detection gate every dictation
  runs through regardless of engine.
- `TurnDetector.swift` — hands-free end-of-turn detection.
- `MeetingTranscriber.swift` / `LivePreviewTranscriber.swift` —
  Notetaker's own transcription and live-preview-during-recording, which
  never went through the user's *main* engine selection to begin with
  (`LivePreviewTranscriber`'s own header explains why: always Parakeet
  EOU "Flash," independent of `Settings.engine` by design).

## Bringing one back

1. Re-add the package dependency in `Package.swift` (WhisperKit as a
   remote package; whisper.cpp needs the xcframework re-vendored, or a
   fresh `Vendor/whisper.xcframework` build).
2. Restore the engine file from git history (`git show
   <commit-before-this-removal>:Sources/Chirp/WhisperEngine.swift`, etc.)
   as a starting point — the API shape (`transcribe`, `preload`,
   `isReady(model:)`, `availableModels`) is what `AppDelegate` and the
   Settings/Onboarding engine pickers expect.
3. Re-add the engine to `Settings.engine`'s recognized values and the
   picker UI in both `OnboardingView.swift` and `SettingsView.swift` —
   both currently assume exactly one engine and were simplified
   accordingly (no picker shown at all).
4. If it's Parakeet specifically: strongly consider building it as a
   *streaming* engine from the start (see `LivePreviewTranscriber.swift`),
   not a batch one — that's the difference between "instant" and "just
   another engine choice."
