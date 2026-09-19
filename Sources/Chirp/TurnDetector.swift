import AVFAudio
import FluidAudio
import Foundation

/// Watches a live, in-progress hands-free recording and detects a natural
/// end of turn — a real pause, not a second key press — using FluidAudio's
/// streaming VAD.
///
/// Only ever active during a hands-free session: `AppDelegate` wires
/// `AudioRecorder.onLiveBuffer` to `ingest` for exactly the duration of one
/// hands-free session and clears it the instant that session ends, by any
/// means, so this never runs during push-to-talk and never leaks into the
/// next recording.
@MainActor
final class TurnDetector {
    private let vadEngine: VadEngine
    private let converter = AudioConverter()

    private var state: VadStreamState?
    private var accumulator: [Float] = []
    private var speechStartSample: Int?
    private var hasFiredThisSession = false

    /// Called at most once per session, the moment a real pause is detected.
    var onTurnEnd: (() -> Void)?

    /// FluidAudio's own default (0.75s) is tuned for voice-agent turn-taking,
    /// not someone dictating and thinking mid-sentence — long enough that a
    /// real thinking pause isn't mistaken for "done," while still clearly
    /// shorter than someone deliberately walking away.
    private let segmentationConfig = VadSegmentationConfig(minSilenceDuration: 2.0)

    /// FluidAudio's streaming path has no minimum-speech arming gate: a
    /// single click or cough can set `.speechStart`, and `.speechEnd` would
    /// then fire after just `minSilenceDuration` of quiet, with no real
    /// speech having happened. Mirrors `AudioRecorder.hasSustainedSignal`'s
    /// exact reasoning at this layer: only trust `.speechEnd` once genuine
    /// speech was actually sustained first, measured in real audio samples
    /// (not wall-clock time, which would drift under any processing delay).
    private let minimumTriggeredDuration: TimeInterval = 0.3

    init(vadEngine: VadEngine) {
        self.vadEngine = vadEngine
    }

    /// Resets all per-session state. Synchronous and cheap — the model
    /// itself is lazily fetched on the first `ingest` call instead of here,
    /// so there's no race between this and that first call.
    func start() {
        state = nil
        accumulator = []
        speechStartSample = nil
        hasFiredThisSession = false
    }

    func stop() {
        state = nil
        accumulator = []
        speechStartSample = nil
    }

    /// Fails silent on any problem — model not ready, a conversion or
    /// processing error — leaving auto-stop simply inactive for this
    /// session rather than risking a bad state. Manual double-tap-to-stop
    /// is never affected either way.
    func ingest(_ buffer: AVAudioPCMBuffer) async {
        guard !hasFiredThisSession, let manager = await vadEngine.loadedManager()
        else { return }
        guard let samples = try? converter.resampleBuffer(buffer) else { return }

        if state == nil {
            state = await manager.makeStreamState()
        }
        guard var currentState = state else { return }
        accumulator.append(contentsOf: samples)

        while accumulator.count >= VadManager.chunkSize {
            let chunk = Array(accumulator.prefix(VadManager.chunkSize))
            accumulator.removeFirst(VadManager.chunkSize)

            guard let result = try? await manager.processStreamingChunk(
                chunk, state: currentState, config: segmentationConfig)
            else { continue }
            currentState = result.state

            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    speechStartSample = event.sampleIndex
                case .speechEnd:
                    let startSample = speechStartSample ?? event.sampleIndex
                    let sustainedSeconds = Double(event.sampleIndex - startSample)
                        / Double(VadManager.sampleRate)
                    speechStartSample = nil
                    if sustainedSeconds >= minimumTriggeredDuration {
                        hasFiredThisSession = true
                        state = currentState
                        onTurnEnd?()
                        return
                    }
                }
            }
        }
        state = currentState
    }
}
