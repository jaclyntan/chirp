import AVFAudio
import FluidAudio
import Foundation

/// A live, best-effort transcript of the current recording, shown in the
/// HUD purely as reassurance that Chirp is actually hearing you — not a
/// second recognition path. The real transcript still comes from whichever
/// engine the app actually selects, run
/// on the complete recording after it stops, with full developer-vocabulary
/// boosting, Harper, and the rewrite pass. This never feeds that pipeline
/// and never influences its output.
///
/// Always Parakeet EOU ("Flash"), regardless of the user's selected engine
/// — the two are independent by design, the same way `VadEngine` runs
/// underneath every engine choice. Flash was hidden from `ParakeetEngine
/// .availableModels` for a real, reproducible bug: `finish()`'s
/// zero-padded final chunk can drop the last word or two of a *complete*
/// recording (see [[project_chirp_nemotron_and_flash_engines]]). That bug
/// is unreachable here — `feed(_:)` never calls `finish()`, only
/// `getPartialTranscript()`, which just decodes whatever's been
/// incrementally recognized so far. A stale or briefly-wrong preview is a
/// non-issue for a display that exists to be glanced at and then replaced;
/// it would be a real one for committed output, which is exactly why
/// Flash stays out of `availableModels` for that path.
///
/// `getPartialTranscript()` only ever *appends* to the token sequence a
/// cache-aware streaming encoder has already committed — unlike a
/// periodic-full-rebuffer approach (re-transcribing the growing buffer
/// from scratch on a timer, as altic-dev/FluidVoice does), there's no
/// later pass that can silently rewrite an earlier word. That's the
/// stronger "stable prefix" guarantee cjpais/Handy's own live preview gets
/// from an explicit committed/tentative split in its streaming library —
/// here it falls out of using a genuinely incremental decoder directly,
/// with no extra bookkeeping needed.
///
/// Independent of `ParakeetEngine`'s own `eouManager` on purpose, not a
/// missed reuse opportunity: that instance is reserved for when a user
/// actually selects "flash" as their main model, and its `loadedModel`/
/// `readyModel` tracking assumes it's the one thing currently loaded for
/// the whole main-transcription pipeline. Sharing it here would mean a
/// live preview quietly flips that bookkeeping (and re-triggers "Loading
/// Parakeet Flash model" status messages) any time this runs underneath a
/// completely different selected engine. Flash is hidden from
/// `availableModels` today, so the two can never collide in practice, but
/// keeping them separate means that stays true even if Flash's bug gets
/// fixed and it ships as a selectable model later.
@MainActor
final class LivePreviewTranscriber {
    // Tried `.ms160` here briefly for lower first-word latency, on the
    // assumption that a smaller chunk is cheaper per call — wrong in
    // practice, confirmed by the diagnostic logging below on a real
    // recording: first text took 12.92s to appear on a 16.8s dictation,
    // and fewer than 10 of the ~200 buffers captured were ever processed
    // in time. Whatever per-call overhead FluidAudio's EOU pipeline has
    // (CoreML/ANE dispatch, mel front-end, etc.) doesn't shrink
    // proportionally with a smaller chunk, so `.ms160` needs roughly twice
    // as many calls per second of audio as `.ms320` for what turned out to
    // be a net loss, not a win — the queue this class already has (see
    // `enqueue`'s doc comment) fell permanently behind instead of catching
    // up. `.ms320` is the one tier with a real, published throughput
    // number behind it (FluidAudio's own benchmark: 14x RTFx on
    // LibriSpeech test-clean) rather than an assumption — back to that.
    private static let chunkSize: StreamingChunkSize = .ms320

    private var manager: StreamingEouAsrManager?
    private var loadTask: Task<StreamingEouAsrManager, Error>?
    /// Set by `start()`/`stop()`, consumed by `drain()` before it processes
    /// the next buffer. Deferred rather than awaited immediately for the
    /// same reason `pendingReset` predates this queue at all: `start()` and
    /// `stop()` both run synchronously, possibly while the model is still
    /// loading or `drain()` is mid-flight, and there is no clean moment to
    /// `await manager.reset()` from either that couldn't race the queue.
    private var pendingReset = false
    /// Buffers waiting to be appended, strictly in arrival order.
    private var queue: [AVAudioPCMBuffer] = []
    private var isDraining = false
    /// Set by `start()`, read once by `drain()` to log time-to-first-text —
    /// see that log line's own comment for what it's actually diagnosing.
    private var sessionStartedAt: Date?
    private var loggedFirstTextThisSession = false

    /// Latest best-guess transcript, after every processed chunk.
    var onUpdate: ((String) -> Void)?

    /// Kicks off model load/download in the background so the first real
    /// recording doesn't start the preview cold. Safe to call more than
    /// once — `pipeline()` caches.
    func preload() {
        Task { _ = try? await self.pipeline() }
    }

    private func pipeline() async throws -> StreamingEouAsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }
        let loadStart = Date()
        dictationLog.info("livePreview: loading Flash model")
        let task = Task { () -> StreamingEouAsrManager in
            let manager = StreamingEouAsrManager(chunkSize: Self.chunkSize)
            try await manager.loadModels()
            return manager
        }
        loadTask = task
        let loaded = try await task.value
        manager = loaded
        dictationLog.info(
            "livePreview: Flash model loaded in \(Date().timeIntervalSince(loadStart), format: .fixed(precision: 2))s, \(self.queue.count) buffer(s) already queued")
        return loaded
    }

    /// Marks a fresh session and discards anything left over from a
    /// previous one that `drain()` hadn't gotten to yet.
    func start() {
        pendingReset = true
        queue.removeAll()
        sessionStartedAt = Date()
        loggedFirstTextThisSession = false
    }

    /// Enqueues one live buffer. Cheap, synchronous, and — critically — has
    /// no `await` in it: earlier this queued a `Task` *per buffer* that
    /// itself awaited `appendAudio`, which was the actual bug behind
    /// "the first words didn't show up." Audio arrives in a steady stream
    /// from a real-time tap while the model can still be loading (first
    /// recording after launch is the common case; FluidAudio's model isn't
    /// instant). Every buffer captured during that window spawned its own
    /// task awaiting the *same* in-flight load, and Swift makes no promise
    /// about the order independently-suspended tasks resume in once that
    /// shared load finishes — so the first several hundred milliseconds of
    /// real speech could reach `appendAudio` scrambled, not in the order
    /// they were spoken. Routing every buffer through one array and one
    /// `drain()` loop below means the *only* thing that can race the queue
    /// is another call to `enqueue` itself, and appending to an array is
    /// atomic with respect to this actor (no suspension point inside this
    /// function for a second call to land in the middle of) — so arrival
    /// order is preserved no matter how long the model takes to load.
    func enqueue(_ buffer: AVAudioPCMBuffer) {
        queue.append(buffer)
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    /// Processes the queue strictly FIFO, one buffer at a time, however
    /// long each `await` takes — a second `enqueue` mid-drain only appends;
    /// it can't start a competing drain loop (`isDraining` guards that) or
    /// jump the line (buffers only leave via `removeFirst()` here).
    private func drain() async {
        guard let manager = try? await pipeline() else {
            dictationLog.error("livePreview: model unavailable, dropping \(self.queue.count) queued buffer(s)")
            queue.removeAll()
            isDraining = false
            return
        }
        var processed = 0
        var failed = 0
        while !queue.isEmpty {
            if pendingReset {
                pendingReset = false
                await manager.reset()
                dictationLog.info("livePreview: reset for new session")
            }
            let buffer = queue.removeFirst()
            let appendStart = Date()
            do {
                try await manager.appendAudio(buffer)
            } catch {
                failed += 1
                dictationLog.error("livePreview: appendAudio failed (\(failed) so far this drain): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let processStart = Date()
            do {
                try await manager.processBufferedAudio()
            } catch {
                failed += 1
                dictationLog.error("livePreview: processBufferedAudio failed (\(failed) so far this drain): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let processDone = Date()
            processed += 1
            let text = await manager.getPartialTranscript()
            // Time from hotkey-down to the first non-empty preview text —
            // the number that actually answers "did the first words show
            // up, and if not, was that a bug or just inherent chunk-buffer
            // latency". Logged once per session, not every update.
            if !loggedFirstTextThisSession, !text.isEmpty, let sessionStartedAt {
                loggedFirstTextThisSession = true
                dictationLog.info(
                    "livePreview: first text after \(Date().timeIntervalSince(sessionStartedAt), format: .fixed(precision: 2))s (\(text.count) chars)")
            }
            // Unconditional for the first 15 chunks of a session — a
            // session that never reaches the every-10th trend log below at
            // all (confirmed happening: 39s of real audio produced fewer
            // than 10 successful chunks in one test) still needs *some*
            // per-chunk timing on record, split append vs. process so a
            // slow step is identifiable rather than one lumped number.
            if processed <= 15 {
                // `text.count` included deliberately: a chunk that
                // appends and processes cleanly but decodes to nothing
                // looks identical to a healthy one without it, which is
                // exactly the state that made "no live text" impossible
                // to diagnose from these logs.
                dictationLog.info(
                    "livePreview: chunk \(processed) — append \(processStart.timeIntervalSince(appendStart), format: .fixed(precision: 3))s, process \(processDone.timeIntervalSince(processStart), format: .fixed(precision: 3))s, \(self.queue.count) queued, text \(text.count) chars")
            }
            // Every 10th buffer beyond that: queue depth still growing here
            // means processing can't keep up with real-time speech, which
            // would show up to a user as the preview falling further and
            // further behind, not as words silently vanishing — a
            // different failure mode than the ordering bug this queue
            // itself fixed, so worth telling apart in the log rather than
            // lumping both under "words drop".
            else if processed % 10 == 0 {
                dictationLog.info(
                    "livePreview: processed \(processed), \(self.queue.count) still queued, last chunk took \(processDone.timeIntervalSince(appendStart), format: .fixed(precision: 3))s")
            }
            onUpdate?(text)
        }
        isDraining = false
    }

    /// Ends the session. Deliberately does *not* clear the last preview
    /// text — `StatusHUDController` keeps it on screen (just without the
    /// live cursor, once `HUDState` leaves `.recording`) through the brief
    /// "Transcribing…" moment, then clears it itself once the HUD actually
    /// hides. Marks the manager for a reset before it accepts the next
    /// session's audio, for the same race-avoidance reason `start()`
    /// defers it.
    ///
    /// Does clear `queue`, though: a `drain()` that fell behind (the
    /// `.ms160` incident this file's chunk-size comment documents) would
    /// otherwise keep grinding through a real recording's worth of stale
    /// backlog after the user already stopped talking — burning CPU for a
    /// panel that's either frozen-on-purpose or already hidden, and, worse,
    /// still calling `onUpdate` partway through "Transcribing…" and
    /// un-freezing text that was supposed to hold still. Whatever's
    /// already mid-`appendAudio` when this runs finishes and reports once
    /// more regardless — acceptable, since one trailing update can't
    /// meaningfully un-freeze anything by itself.
    func stop() {
        pendingReset = true
        queue.removeAll()
    }
}
