import AVFAudio
import FluidAudio
import Foundation
import Observation

/// Token updates have their own observation scope. Pages displaying only
/// history or app status do not rebuild on every live caption.
@MainActor
@Observable
final class LivePreviewState {
    var text = ""
}

/// The small interface also allows lifecycle checks without loading Core ML.
private protocol PreviewInference: Sendable {
    func reset() async
    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws
    func processBufferedAudio() async throws
    func getPartialTranscript() async -> String
    func cleanup() async
}

extension StreamingEouAsrManager: PreviewInference {}

/// Optional captions only. Final transcription always uses the complete
/// recording, independently of preview speed, errors, or overload.
@MainActor
final class LivePreviewTranscriber {
    private static let chunkSize: StreamingChunkSize = .ms320
    private var manager: (any PreviewInference)?
    private var loadTask: Task<any PreviewInference, Error>?
    private var releaseTask: Task<Void, Never>?
    private var pendingReset = false
    private var queue = AudioBufferQueue()
    private var isDraining = false
    private var active = false
    private var suspended = false
    private var overloaded = false
    private var generation = 0
    private var lastText = ""
    private var sessionStartedAt: Date?
    /// Set when a session falls behind real time. Until it passes, preview
    /// stays off: on a Mac busy enough to fall behind once, the next
    /// session would just reload the model and fall behind again, paying
    /// for the load each time and competing with the real transcription.
    private var cooldownUntil: ContinuousClock.Instant?
    /// Consecutive sessions that overflowed before the model finished
    /// loading. One slow cold start is normal (the budget is only 3 s of
    /// audio); twice in a row means every load is slow, and each reload is
    /// itself the memory churn worth avoiding.
    private var loadOverflowStreak = 0
    /// macOS has signalled memory pressure. Preview is optional, so it is
    /// the first thing to give its memory back.
    private var memoryConstrained = false

    private let loadPipeline: () async throws -> any PreviewInference
    private let idleDelay: Duration
    private let cooldown: Duration
    var onUpdate: ((String) -> Void)?

    /// Whether a new session would actually run. Callers check this before
    /// wiring up audio, so a skipped session costs nothing per buffer.
    var canRun: Bool {
        guard !suspended, !memoryConstrained else { return false }
        if let cooldownUntil, ContinuousClock.now < cooldownUntil { return false }
        return true
    }

    init() {
        idleDelay = .seconds(30)
        cooldown = .seconds(600)
        loadPipeline = {
            let manager = StreamingEouAsrManager(chunkSize: Self.chunkSize)
            try await manager.loadModels()
            return manager
        }
    }

    private init(idleDelay: Duration, cooldown: Duration = .seconds(600),
                 loadPipeline: @escaping () async throws -> any PreviewInference) {
        self.idleDelay = idleDelay
        self.cooldown = cooldown
        self.loadPipeline = loadPipeline
    }

    func preload() {
        guard canRun else { return }
        releaseTask?.cancel()
        Task {
            _ = try? await pipeline()
            scheduleReleaseIfIdle()
        }
    }

    private func pipeline() async throws -> any PreviewInference {
        guard !suspended else { throw CancellationError() }
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }
        let task = Task { try await loadPipeline() }
        loadTask = task
        // A completed Task retains its result, including the model. Clear
        // it on success AND failure so idle release and retries both work.
        defer { loadTask = nil }
        let loaded = try await task.value
        manager = loaded
        return loaded
    }

    func start() {
        guard canRun else { return }
        releaseTask?.cancel()
        generation += 1
        active = true
        overloaded = false
        pendingReset = true
        queue.removeAll()
        lastText = ""
        sessionStartedAt = Date()
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard active, !overloaded else { return }
        guard queue.append(buffer) else {
            overloaded = true
            queue.removeAll()
            let stillLoading = manager == nil
            if stillLoading { loadOverflowStreak += 1 }
            if !stillLoading || loadOverflowStreak >= 2 {
                loadOverflowStreak = 0
                cooldownUntil = ContinuousClock.now + cooldown
                dictationLog.notice(
                    "livePreview: fell behind real time (\(stillLoading ? "slow model loads" : "inference", privacy: .public)); off for \(Int(self.cooldown.components.seconds / 60)) min")
            } else {
                dictationLog.notice("livePreview: paused for this session; model still loading")
            }
            return
        }
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        defer {
            isDraining = false
            // start/stop can occur while reset or inference is suspended.
            // Don't strand audio belonging to a newer session.
            if active, !overloaded, !queue.isEmpty {
                isDraining = true
                Task { await drain() }
            } else {
                scheduleReleaseIfIdle()
            }
        }
        guard let manager = try? await pipeline() else {
            queue.removeAll()
            overloaded = true
            return
        }
        while active, !overloaded, !queue.isEmpty {
            let session = generation
            if pendingReset {
                pendingReset = false
                await manager.reset()
                guard session == generation else { continue }
            }
            guard let buffer = queue.popFirst() else { break }
            do {
                try await manager.appendAudio(buffer)
                guard active, !overloaded, session == generation else { continue }
                try await manager.processBufferedAudio()
                guard active, !overloaded, session == generation else { continue }
                let text = await manager.getPartialTranscript()
                guard active, !overloaded, session == generation, text != lastText else { continue }
                if lastText.isEmpty, !text.isEmpty, let sessionStartedAt {
                    dictationLog.info("livePreview: first text after \(Date().timeIntervalSince(sessionStartedAt), format: .fixed(precision: 2))s")
                }
                lastText = text
                onUpdate?(text)
            } catch {
                dictationLog.error("livePreview: inference failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Release decoder history and internal audio immediately, even if
        // model weights remain warm for a nearby recording.
        if !active || overloaded { await manager.reset() }
    }

    func stop() {
        if active, !overloaded { loadOverflowStreak = 0 }
        active = false
        generation += 1
        pendingReset = true
        queue.removeAll()
        if !isDraining, let manager {
            isDraining = true
            Task {
                await manager.reset()
                // A new session may have arrived while reset suspended.
                await drain()
            }
        } else {
            scheduleReleaseIfIdle()
        }
    }

    func suspend() {
        suspended = true
        stop()
    }

    func resume() { suspended = false }

    /// Under memory pressure, stop starting sessions and drop the weights
    /// as soon as nothing is using them. A session already running is left
    /// to finish; it ends with the recording.
    func setMemoryConstrained(_ value: Bool) {
        guard memoryConstrained != value else { return }
        memoryConstrained = value
        if value { scheduleReleaseIfIdle() }
    }

    /// Keep weights warm across adjacent dictations, then reclaim them.
    /// The task doesn't retain this controller during its idle wait.
    private func scheduleReleaseIfIdle() {
        guard !active, !isDraining else { return }
        releaseTask?.cancel()
        // Kept warm only if the next session could use it.
        let delay: Duration = canRun ? idleDelay : .zero
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.active, !self.isDraining else { return }
            let unused = self.manager
            self.manager = nil
            await unused?.cleanup()
        }
    }

    static func runSelfTest() async -> Bool {
        var passed = true
        func check(_ value: Bool, _ label: String) {
            if !value { passed = false }
            print("\(value ? "PASS" : "FAIL"): \(label)")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        func buffer(_ marker: Float) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            buffer.floatChannelData![0][0] = marker
            return buffer
        }
        func until(_ condition: () async -> Bool) async -> Bool {
            for _ in 0..<200 {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        let engine = PreviewTestInference()
        let preview = LivePreviewTranscriber(idleDelay: .milliseconds(5)) { engine }
        var updates: [String] = []
        preview.onUpdate = { updates.append($0) }
        preview.start()
        preview.enqueue(buffer(1))
        check(await until { await engine.waiting }, "preview test pauses an in-flight inference")
        preview.stop()
        preview.enqueue(buffer(99)) // a trailing tap must be ignored
        preview.start()
        preview.enqueue(buffer(2))
        await engine.resume()
        check(await until { updates == ["2"] }, "stop/start rejects stale results and preserves the new session")
        check(await engine.markers == [1, 2], "stopped preview ignores late audio")
        preview.suspend()
        check(await until { await engine.cleaned }, "sleep immediately releases idle preview model resources")
        check(preview.manager == nil && preview.loadTask == nil, "completed load tasks do not retain released models")

        preview.start()
        preview.enqueue(buffer(99))
        check(!preview.active && preview.queue.isEmpty, "sleeping preview cannot restart from a late callback")
        preview.resume()

        let idleEngine = PreviewTestInference()
        let idle = LivePreviewTranscriber(idleDelay: .milliseconds(5)) { idleEngine }
        idle.preload()
        check(await until { await idleEngine.cleaned }, "unused preview weights still release after normal idle timeout")

        let slow = PreviewTestInference()
        let bounded = LivePreviewTranscriber(idleDelay: .seconds(30)) { slow }
        bounded.start()
        bounded.enqueue(buffer(1))
        _ = await until { await slow.waiting }
        for _ in 0..<100 { bounded.enqueue(buffer(3)) }
        check(bounded.overloaded && bounded.queue.isEmpty, "overloaded preview drops its backlog and suspends optional inference")
        await slow.resume()
        _ = await until { !bounded.isDraining }
        bounded.stop()

        let coolingEngine = PreviewTestInference()
        let cooling = LivePreviewTranscriber(idleDelay: .seconds(30), cooldown: .milliseconds(80)) { coolingEngine }
        cooling.start()
        cooling.enqueue(buffer(1))
        _ = await until { await coolingEngine.waiting }
        for _ in 0..<100 { cooling.enqueue(buffer(3)) }
        check(!cooling.canRun, "a preview that fell behind stays off for the next session")
        await coolingEngine.resume()
        _ = await until { !cooling.isDraining }
        cooling.stop()
        check(await until { await coolingEngine.cleaned }, "a cooling-down preview releases its model at once")
        cooling.start()
        check(!cooling.active, "a session during cooldown does not start")
        try? await Task.sleep(for: .milliseconds(100))
        check(cooling.canRun, "preview comes back after its cooldown")

        let gate = PreviewLoadGate()
        let slowLoad = LivePreviewTranscriber(idleDelay: .seconds(30)) {
            await gate.wait()
            return PreviewTestInference()
        }
        slowLoad.start()
        for _ in 0..<100 { slowLoad.enqueue(buffer(3)) }
        check(slowLoad.canRun, "one slow cold start does not switch preview off")
        slowLoad.stop()
        slowLoad.start()
        for _ in 0..<100 { slowLoad.enqueue(buffer(3)) }
        check(!slowLoad.canRun, "two slow cold starts in a row do")
        await gate.open()
        _ = await until { !slowLoad.isDraining }
        slowLoad.stop()

        let pressured = LivePreviewTranscriber(idleDelay: .seconds(30)) { PreviewTestInference() }
        pressured.setMemoryConstrained(true)
        pressured.start()
        check(!pressured.canRun && !pressured.active, "memory pressure keeps preview from starting")
        pressured.setMemoryConstrained(false)
        check(pressured.canRun, "preview returns when memory pressure clears")

        enum ExpectedFailure: Error { case load }
        var attempts = 0
        let retry = LivePreviewTranscriber(idleDelay: .seconds(30)) {
            attempts += 1
            throw ExpectedFailure.load
        }
        retry.start()
        retry.enqueue(buffer(1))
        _ = await until { !retry.isDraining }
        retry.stop()
        retry.start()
        retry.enqueue(buffer(2))
        _ = await until { !retry.isDraining }
        check(attempts == 2, "a failed preview model load can retry in a later session")
        retry.stop()
        return passed
    }

}


/// Holds a test model load open until released.
private actor PreviewLoadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Suspends only its first inference to exercise real actor reentrancy.
private actor PreviewTestInference: PreviewInference {
    private var continuation: CheckedContinuation<Void, Never>?
    private var first = true
    private var text = ""
    private(set) var waiting = false
    private(set) var cleaned = false
    private(set) var markers: [Int] = []

    func reset() { text = "" }
    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        let marker = Int(buffer.floatChannelData![0][0])
        markers.append(marker)
        text = String(marker)
    }
    func processBufferedAudio() async {
        if first {
            first = false
            waiting = true
            await withCheckedContinuation { continuation = $0 }
            waiting = false
        }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
    func getPartialTranscript() -> String { text }
    func cleanup() { cleaned = true }
}
