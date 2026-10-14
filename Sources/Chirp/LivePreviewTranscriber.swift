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

    private let loadPipeline: () async throws -> any PreviewInference
    private let idleDelay: Duration
    var onUpdate: ((String) -> Void)?

    init() {
        idleDelay = .seconds(30)
        loadPipeline = {
            let manager = StreamingEouAsrManager(chunkSize: Self.chunkSize)
            try await manager.loadModels()
            return manager
        }
    }

    private init(idleDelay: Duration, loadPipeline: @escaping () async throws -> any PreviewInference) {
        self.idleDelay = idleDelay
        self.loadPipeline = loadPipeline
    }

    func preload() {
        guard !suspended else { return }
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
        guard !suspended else { return }
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
            dictationLog.notice("livePreview: paused for this session; inference exceeded its audio budget")
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

    /// Keep weights warm across adjacent dictations, then reclaim them.
    /// The task doesn't retain this controller during its idle wait.
    private func scheduleReleaseIfIdle() {
        guard !active, !isDraining else { return }
        releaseTask?.cancel()
        let delay: Duration = suspended ? .zero : idleDelay
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
