# Performance on entry-level Apple Silicon Macs

Chirp still requires Apple Silicon and macOS 26 or newer. These changes
are aimed at reducing background work and peak memory, without replacing
Apple's final speech recognition or reducing recording quality. Whole-app
before/after figures have not been measured; see Verification below.

- Meeting speaker models load when a meeting is processed, rather than at
  launch. Their references are released before speaker-clip transcription.
  Apple Intelligence is no longer prewarmed at launch. VAD also loads
  only on demand, stays warm during hands-free recording or a file check,
  and releases its cached reference after 30 idle seconds.
- Live preview retains at most three seconds / 64 waiting audio buffers,
  plus the current inference buffer. When inference cannot keep up, preview
  pauses for that session. The full recording still transcribes normally.
  Hands-free turn detection has the same queue budget and fails open to
  manual stop if overloaded. Each stream has one inference drain.
- Preview drops unchanged text updates and rejects results from a stopped
  session. Decoder history resets at stop; model weights stay warm for
  nearby recordings, then release after 30 idle seconds. A completed load
  task no longer keeps the model alive, and failed loads can retry.
- Microphone audio is copied once for asynchronous live consumers only
  when those consumers exist, preventing recycled tap storage from being
  retained. Normal push-to-talk without preview does no extra copying.
- Meeting speaker separation streams saved audio from disk through a
  reusable ten-second window and a 16,384-frame read buffer, rather than
  loading the recording into an array. One diarizer retains speaker state
  across windows, with the same chunk boundaries, absolute timestamps and
  enrolled names. Short disk reads are combined to fill each exact window;
  the final partial window is processed once. Speaker clips also stream
  directly from file ranges. Disk reads and inference run on a separate
  actor, away from the UI thread.
- Hiding the dictation HUD now sets its state to hidden and removes the
  animated SwiftUI subtree. Ordering out its panel alone left repeating
  waveform/dot animations alive. Late caption updates cannot reopen it.
  Dashboard waveform and pulse animation also stop when its window is
  hidden or Low Power Mode/thermal policy reduces motion.
- The extra speech/no-speech gate streams a recording through one
  persistent resampler, using a 16,384-frame input buffer and 4,096-frame
  model chunks. The first speech-positive result immediately allows the
  original recording through. Silence scans to EOF, and errors fail open.
  This replaces the dependency's full native-rate array, resampled array,
  per-chunk arrays, and retained result list. Reads and conversion run off
  the UI actor; inference pauses between chunks on system sleep.
- Meeting app detection uses workspace activation notifications. A timer
  runs only while an opted-in browser is frontmost. Hidden dashboard and
  pet views have no ambient or permission-check timer. The bird's idle
  animations play once and rest between occasional activity.
- Audio RMS uses Accelerate's vector implementation and respects channel
  stride. In a local optimized microbenchmark of 50,000 4,096-frame buffers,
  the scalar loop took 0.668 s and Accelerate took 0.0166 s. This is a
  focused arithmetic benchmark, not an app-wide CPU or latency claim.

Meeting live captions are off by default for preferences that have never
been set. Existing explicit choices are respected. Enabling them runs two
independent preview models; disabling them keeps the saved meeting
transcript and speaker separation available. The floating pet and normal
live preview can also be disabled in Settings for the lightest idle setup.

The tradeoff for releasing unused models is a cold load on the next use
after the idle interval. Speaker separation now holds about 0.67 MiB of
input audio regardless of recording length, plus the engine's ten-second
padded buffer (about 0.61 MiB), model working memory and segment metadata.
The previous recording-sized array added about 220 MiB per hour. Segment
metadata still grows with the meeting. These changes do not promise a
fixed app-wide RAM ceiling or turn Intel Macs into supported devices.

Streaming applies to processing the saved meeting after capture; it does
not introduce live speaker labeling or change Apple's final recognition.
If separation fails, partial results are discarded and the original audio
still transcribes as one remote speaker.

## Verification

Build an optimized release and run its `--selftest`. The regression checks
cover silence thresholds and meter levels, interleaved audio, audio
ownership, FIFO ordering and memory bounds, stopped-session inference,
overload, failed-load retries, idle cleanup, exact streamed clip ranges,
window boundaries, storage reuse, short reads and tails, EOF, invalid
formats and inference error propagation. VAD checks cover early exit,
late speech, model-state continuity, mono/stereo resampling equivalence,
idle cache release, active streaming retention, failed-load retries and
stale loads across sleep/wake. HUD checks cover hidden animation state.
The release currently passes 157 checks.
Tests for model lifecycle use a controllable inference actor and require
no microphone, downloaded model, or network access.

For device-level profiling, quit and reopen the rebuilt signed app on the
target Mac first. Opening an already-running app only reopens its window;
it does not replace its executable or pick up the source changes. Measure
idle CPU, memory footprint and wakeups with its window closed, then with
its window open. Compare a short dictation, hands-free dictation, and a
long meeting with captions off/on. Include memory again 30 seconds after
stopping preview. Use real speech to check live preview with
`--live-preview audio.wav`; optional preview can intentionally pause when
its backlog exceeds the budget. Verify the final recording separately
with `--transcribe audio.wav`. Whole-app before/after CPU and RAM numbers
have not yet been measured on an entry-level M1/8 GB machine.

## Sleep, wake and power saving

A notification-driven runtime policy now handles system sleep, display
sleep and inactive user sessions separately. Overlapping events are tracked
independently so a system wake cannot resume ambient activity while the
screen or session is still inactive.

System sleep stops microphone recording, resets held-key/hands-free state,
and stops shortcut monitors. Captured dictation is transcribed into History
after wake, without automatically pasting into a possibly different app.
Meeting capture stops and finalizes its audio; new transcription work waits
for wake. Meeting duration is measured at capture stop, excluding sleep and
processing time. Pending system-audio startup is canceled and joined before
cleanup so it cannot start a stray capture after stop. Wake restores shortcut
monitors without automatically restarting recording or prewarming models.

Preview models release promptly on sleep, and unused VAD references are
cleared. Work already inside a framework's inference call can finish; the
policy prevents starting subsequent processing stages until wake rather
than interrupting recognition midway. Captured audio stays on disk while
processing is deferred. Speaker separation also gates every ten-second
window on wake, so it no longer starts an entire meeting's inference in
one uninterruptible call. This is sleep recovery, not crash/reboot recovery.

Display sleep alone pauses decoration, permission checks and browser meeting
polling, while keeping ongoing audio recordings available. Low Power Mode
and serious/critical thermal pressure suspend idle bird motion; active
recording and final recognition remain available. Caption updates now have
an independent observation scope, avoiding dashboard/history rebuilds on
every new token.

Self-tests simulate overlapping power events, verify deferred processing,
check hotkey and sprite suspension state, and cover immediate preview
cleanup. They do not put the user's Mac to sleep. A real lid-close/wake
cycle with microphone and system audio remains a device-level manual check.

## Streaming validation and memory benchmark

`Chirp --diarize-compare audio.wav` compares the streaming path with the
previous full-array algorithm using locally cached speaker models. It
accepts only a short 16 kHz mono fixture (longer than ten seconds, at most
two minutes), never loads stored meetings or downloads models, and checks
speaker assignments, timestamps, quality scores and embeddings. Generated
29.27-second speech alternating Daniel and Samantha passed with both
anonymous speakers and a seeded enrolled speaker (five segments each).
The comparison tolerance is 0.0001 for numeric model outputs.

A separate optimized file-ingestion benchmark uses the production reader
and the previous array-loading algorithm. A synthetic one-hour Float32
CAF file produced identical 57,600,000-frame counts and checksums:

| Reader | Peak resident memory | Elapsed time |
| --- | ---: | ---: |
| Previous full array | 227.5 MiB | 0.16 s |
| Ten-second stream | 8.5 MiB | 0.12 s |

These are local file-ingestion process measurements from `/usr/bin/time
-l`, not whole-app RAM or end-to-end transcription latency. The file was
cached; model inference, metadata, final transcription and UI are excluded.
The standalone source keeps this check reproducible without model downloads:

```sh
swiftc -O -module-cache-path /tmp/chirp-benchmark-cache \
  Sources/Chirp/MeetingAudioWindowReader.swift \
  scripts/benchmark_meeting_audio.swift -o /tmp/chirp-audio-benchmark
/tmp/chirp-audio-benchmark create /tmp/chirp-hour.caf 3600
/usr/bin/time -l /tmp/chirp-audio-benchmark array /tmp/chirp-hour.caf
/usr/bin/time -l /tmp/chirp-audio-benchmark stream /tmp/chirp-hour.caf
```

## Speech-presence check validation

`Chirp --vad-compare audio.wav` compares the new streamed speech decision
with the previous full-file VAD scan on an explicit fixture of at most
120 seconds. It uses the cached Silero model without downloading and
reports model-chunk counts. Actual model/read errors fail the comparison
rather than masquerading as a matching fail-open decision.

| Generated fixture | Full-file chunks | Streamed chunks | Decision |
| --- | ---: | ---: | --- |
| 29.27 seconds of alternating speech | 115 | 1 | Speech |
| 4 seconds of silence plus short tail | 16 | 16 | No speech |
| 4 seconds of low-amplitude random noise plus short tail | 16 | 16 | No speech |
| 3 seconds of silence followed by speech | 48 | 12 | Speech |

All four decisions match the previous path. This demonstrates inference
work avoided by early exit; it is not a whole-app CPU percentage or an
end-to-end latency benchmark. Short fixtures also compare resampled
samples against the dependency's full-file conversion at 16 kHz mono,
48 kHz mono and 44.1 kHz stereo (tolerance 0.00001), including final tails.

VAD model release trades lower idle memory for a cold load after a long
pause. Sleep invalidates pending loads so an old result cannot install
itself after wake. Stopping or canceling dictation always tears down turn
detection and its live hook, ending the active VAD retention period.
