import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Shared by file checks and hands-free turn detection. Tests can exercise
/// lifecycle and early exit without loading a model or using a microphone.
protocol VoiceActivityInference: Sendable {
    var config: VadConfig { get async }
    func makeStreamState() async -> VadStreamState
    func processStreamingChunk(
        _ audioChunk: [Float], state: VadStreamState, config: VadSegmentationConfig,
        returnSeconds: Bool, timeResolution: Int
    ) async throws -> VadStreamResult
}

extension VadManager: VoiceActivityInference {}

extension VoiceActivityInference {
    func processStreamingChunk(_ samples: [Float], state: VadStreamState,
                               config: VadSegmentationConfig) async throws -> VadStreamResult {
        try await processStreamingChunk(samples, state: state, config: config,
                                        returnSeconds: false, timeResolution: 1)
    }
}

/// Additional silence gate after capture, never on the real-time audio tap.
/// Loads only when used, stays warm for nearby dictations, then releases.
@MainActor
final class VadEngine {
    private var suspended = false
    private var generation = 0
    private var manager: (any VoiceActivityInference)?
    private var loadTask: Task<any VoiceActivityInference, Error>?
    private var releaseTask: Task<Void, Never>?
    private var streamingActive = false
    private var fileChecks = 0
    private let worker = SpeechPresenceWorker()
    private let idleDelay: Duration
    private let loadModel: () async throws -> any VoiceActivityInference

    init() {
        idleDelay = .seconds(30)
        loadModel = { try await VadManager() }
    }

    private init(idleDelay: Duration, loadModel: @escaping () async throws -> any VoiceActivityInference) {
        self.idleDelay = idleDelay
        self.loadModel = loadModel
    }

    func beginStreaming() {
        guard !suspended else { return }
        streamingActive = true
        releaseTask?.cancel()
        releaseTask = nil
    }

    func endStreaming() {
        streamingActive = false
        scheduleReleaseIfIdle()
    }

    func suspend() {
        suspended = true
        generation += 1
        streamingActive = false
        releaseTask?.cancel()
        releaseTask = nil
        loadTask?.cancel()
        loadTask = nil
        manager = nil
    }

    func resume() { suspended = false }

    private func pipeline() async throws -> any VoiceActivityInference {
        guard !suspended else { throw CancellationError() }
        if let manager { return manager }
        if loadTask == nil { generation += 1 }
        let ticket = generation
        let task: Task<any VoiceActivityInference, Error>
        if let loadTask { task = loadTask }
        else {
            task = Task { try await loadModel() }
            loadTask = task
        }
        defer { if generation == ticket { loadTask = nil } }
        let loaded = try await task.value
        guard !suspended, generation == ticket else { throw CancellationError() }
        manager = loaded
        return loaded
    }

    private func scheduleReleaseIfIdle() {
        releaseTask?.cancel()
        releaseTask = nil
        guard !suspended, !streamingActive, fileChecks == 0, manager != nil else { return }
        let delay = idleDelay
        releaseTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !self.streamingActive, self.fileChecks == 0 else { return }
            self.manager = nil
            self.releaseTask = nil
        }
    }

    func loadedManager() async -> (any VoiceActivityInference)? {
        let loaded = try? await pipeline()
        scheduleReleaseIfIdle()
        return loaded
    }

    /// Only zero speech across the whole file can suppress recognition.
    /// The first speech-positive chunk allows the original recording
    /// through immediately. Errors always fail open, preserving speech.
    func hasNoDetectedSpeech(fileAt url: URL, activity: RuntimeActivity? = nil) async -> Bool {
        fileChecks += 1
        releaseTask?.cancel()
        releaseTask = nil
        defer { fileChecks -= 1; scheduleReleaseIfIdle() }
        await activity?.waitUntilAwake()
        guard let manager = try? await pipeline() else { return false }
        return await worker.hasNoSpeech(fileAt: url, manager: manager, activity: activity)
    }

    /// Cached model only, short explicit diagnostics; never reads history.
    static func compareFileCheck(fileAt url: URL) async -> Bool {
        await SpeechPresenceWorker().compare(fileAt: url)
    }

    static func runSelfTest() async -> Bool {
        var passed = true
        func check(_ value: Bool, _ label: String) {
            if !value { passed = false }
            print("\(value ? "PASS" : "FAIL"): \(label)")
        }
        var loads = 0
        let engine = VadEngine(idleDelay: .milliseconds(20)) {
            loads += 1
            return TestVoiceActivity()
        }
        check(engine.manager == nil && loads == 0, "VAD does not load models at app initialization")
        engine.beginStreaming()
        _ = await engine.loadedManager()
        try? await Task.sleep(for: .milliseconds(60))
        check(engine.manager != nil && loads == 1, "hands-free sessions keep VAD warm without reloading")
        engine.endStreaming()
        try? await Task.sleep(for: .milliseconds(60))
        check(engine.manager == nil && engine.loadTask == nil, "idle VAD weights and completed load tasks release")
        engine.beginStreaming()
        _ = await engine.loadedManager()
        engine.suspend()
        check(engine.manager == nil && engine.loadTask == nil, "sleep releases VAD references immediately")
        let sleepingModel = await engine.loadedManager()
        check(sleepingModel == nil && loads == 2, "sleeping VAD cannot restart from a late buffer")
        engine.resume()
        check(engine.manager == nil && loads == 2, "VAD wake does not prewarm a model")

        var attempts = 0
        let retry = VadEngine(idleDelay: .milliseconds(20)) {
            attempts += 1
            if attempts == 1 { throw CancellationError() }
            return TestVoiceActivity()
        }
        let firstAttempt = await retry.loadedManager()
        let secondAttempt = await retry.loadedManager()
        check(firstAttempt == nil && secondAttempt != nil && attempts == 2,
              "a failed VAD load can retry without retaining its failed task")
        retry.suspend()

        var continuation: CheckedContinuation<any VoiceActivityInference, Error>?
        let delayed = VadEngine(idleDelay: .milliseconds(20)) {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let pending = Task { await delayed.loadedManager() }
        while continuation == nil { await Task.yield() }
        delayed.suspend()
        delayed.resume()
        continuation?.resume(returning: TestVoiceActivity())
        let stale = await pending.value
        check(stale == nil && delayed.manager == nil, "a pre-sleep VAD load cannot install itself after wake")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-vad-test-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096 * 2 + 123)!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].initialize(repeating: 0.25, count: Int(buffer.frameLength))
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let worker = SpeechPresenceWorker()
            let immediate = TestVoiceActivity(probabilities: [1])
            let early = await worker.hasNoSpeech(fileAt: url, manager: immediate)
            let earlyCalls = await immediate.calls
            check(!early && earlyCalls == 1, "speech-presence check exits at the first positive chunk")
            let late = TestVoiceActivity(probabilities: [0, 0, 0.9])
            let lateResult = await worker.hasNoSpeech(fileAt: url, manager: late)
            let lateCalls = await late.calls
            check(!lateResult && lateCalls == 3, "speech at the short final tail is preserved")
            let silence = TestVoiceActivity()
            let quiet = await worker.hasNoSpeech(fileAt: url, manager: silence)
            let sizes = await silence.sizes
            let states = await silence.stateOffsets
            check(quiet && sizes == [4096, 4096, 123] && states == [0, 4096, 8192],
                  "silence check scans every sample once and preserves model state between chunks")
            let failing = TestVoiceActivity(fails: true)
            check(!(await worker.hasNoSpeech(fileAt: url, manager: failing)), "VAD inference failure preserves the original recording")
            check(!(await worker.hasNoSpeech(fileAt: url.appendingPathComponent("missing"), manager: silence)),
                  "VAD read failure never discards a recording")
            let activity = RuntimeActivity()
            let sleeping = TestVoiceActivity(onFirstChunk: { await activity.setSystemSleeping(true) })
            let interrupted = Task { await worker.hasNoSpeech(fileAt: url, manager: sleeping, activity: activity) }
            while !activity.systemSleeping { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(20))
            let heldCalls = await sleeping.calls
            check(heldCalls == 1, "sleep pauses the speech-presence check between chunks")
            activity.setSystemSleeping(false)
            let resumed = await interrupted.value
            let resumedCalls = await sleeping.calls
            check(resumed && resumedCalls == 3, "speech-presence check resumes with its model state after wake")
            let readPassed = try SpeechAudioReader.runSelfTest()
            check(readPassed, "streamed speech resampling matches full-file conversion for mono and stereo")
        } catch { check(false, "VAD file self-test: \(error)") }
        return passed
    }
}

private actor SpeechPresenceWorker {
    func hasNoSpeech(fileAt url: URL, manager: any VoiceActivityInference,
                     activity: RuntimeActivity? = nil) async -> Bool {
        await scan(fileAt: url, manager: manager, activity: activity).noSpeech
    }

    private func scan(fileAt url: URL, manager: any VoiceActivityInference,
                      activity: RuntimeActivity? = nil) async -> (noSpeech: Bool, chunks: Int, succeeded: Bool) {
        var chunks = 0
        do {
            let reader = try SpeechAudioReader(url: url)
            var state = await manager.makeStreamState()
            let threshold = await manager.config.defaultThreshold
            while true {
                await activity?.waitUntilAwake()
                try Task.checkCancellation()
                guard let samples = try reader.nextChunk() else { return (true, chunks, true) }
                let result = try await manager.processStreamingChunk(samples, state: state, config: .default)
                chunks += 1
                if result.probability >= threshold { return (false, chunks, true) }
                state = result.state
            }
        } catch { return (false, chunks, false) }
    }

    func compare(fileAt url: URL) async -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, Double(file.length) / file.processingFormat.sampleRate <= 120 else {
                print("FAIL: VAD comparison requires a non-empty fixture at most 120 seconds long")
                return false
            }
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let modelURL = support.appendingPathComponent("FluidAudio/Models/silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc")
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            let reference = try await VadManager(vadModel: model).process(url)
            let expected = !reference.contains { $0.isVoiceActive }
            let streamed = await scan(fileAt: url, manager: VadManager(vadModel: model))
            let passed = streamed.succeeded && expected == streamed.noSpeech
            print("\(passed ? "PASS" : "FAIL"): streamed VAD matches full-file speech decision (no speech: \(streamed.noSpeech), chunks: \(reference.count) → \(streamed.chunks))")
            return passed
        } catch {
            print("FAIL: VAD comparison: \(error)")
            return false
        }
    }
}

private actor TestVoiceActivity: VoiceActivityInference {
    let config = VadConfig.default
    private let probabilities: [Float]
    private let fails: Bool
    private let onFirstChunk: (@Sendable () async -> Void)?
    private(set) var calls = 0
    private(set) var sizes: [Int] = []
    private(set) var stateOffsets: [Int] = []

    init(probabilities: [Float] = [], fails: Bool = false,
         onFirstChunk: (@Sendable () async -> Void)? = nil) {
        self.probabilities = probabilities
        self.fails = fails
        self.onFirstChunk = onFirstChunk
    }

    func makeStreamState() -> VadStreamState { .initial() }

    func processStreamingChunk(_ audioChunk: [Float], state: VadStreamState,
                               config: VadSegmentationConfig, returnSeconds: Bool,
                               timeResolution: Int) async throws -> VadStreamResult {
        if fails { throw CancellationError() }
        let probability = probabilities.indices.contains(calls) ? probabilities[calls] : 0
        calls += 1
        sizes.append(audioChunk.count)
        stateOffsets.append(state.processedSamples)
        if calls == 1 { await onFirstChunk?() }
        var next = state
        next.processedSamples += audioChunk.count
        return VadStreamResult(state: next, event: nil, probability: probability)
    }
}
