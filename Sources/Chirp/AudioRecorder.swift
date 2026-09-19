import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures microphone audio into a temporary file while the hotkey is held.
///
/// Deliberately simple: the engine starts on key-down and stops on release.
/// Two "improvements" were tried and reverted after breaking things:
/// - setVoiceProcessingEnabled: its echo canceller ducks/mutes other apps'
///   audio system-wide and can feed the recognizer silence.
/// - A warm always-on engine with a pre-roll ring buffer: wedged the engine
///   so recording never started.
final class AudioRecorder {
    private let engine = AVAudioEngine()

    /// Allocates the engine's resources ahead of the first key press.
    ///
    /// `prepare()` does not open the microphone — no recording indicator,
    /// nothing captured — it just does the allocation that would
    /// otherwise happen inside the first `start()`, which is the one most
    /// likely to lose a word because the user is already talking.
    func preload() {
        engine.prepare()
    }
    private var file: AVAudioFile?
    private(set) var currentFileURL: URL?
    private(set) var isRecording = false
    /// Audio frames actually captured. A recording that ends on zero means
    /// the microphone delivered nothing, which is worth reporting rather
    /// than passing an empty file to the recognizer and shrugging.
    private(set) var capturedFrames: AVAudioFramePosition = 0
    /// The format the tap really ran at, for diagnostics.
    private(set) var capturedFormat: AVAudioFormat?
    /// True once *enough total time* above the silence floor has been
    /// seen. A recording that never clears it isn't "no audio" (frames
    /// were captured — room tone, mic self-noise) but there's no actual
    /// speech in it either. Whisper models hallucinate on exactly this
    /// input — trained partly on YouTube transcripts, they'll fill true
    /// silence with "Thank you." or similar sign-off phrases rather than
    /// admit there's nothing there. Catching it here means every engine
    /// benefits, not just whichever one happens to hallucinate.
    ///
    /// This used to latch true the moment *any single* buffer crossed the
    /// floor — "was there ever a moment above threshold" — and a real
    /// incident showed why that's too weak: one click, pop, or breath is
    /// loud enough on its own to latch it permanently, even across an
    /// otherwise-silent 1.5 second hold, and the recognizer still
    /// hallucinated "Thank you." from what was actually silence.
    /// Requiring a minimum cumulative *duration* above the floor — not
    /// just an instant — is what the threshold below was actually tuned
    /// against ("comfortably below even quiet speech"): a transient is
    /// over almost immediately, a spoken word isn't.
    private(set) var hasSignal = false
    /// Frames whose own buffer cleared the silence floor, summed across
    /// the whole recording (not just whether one ever did).
    private var signalFrameCount: AVAudioFramePosition = 0
    /// -40dBFS. Comfortably below even quiet speech, comfortably above a
    /// silent room's noise floor — picked to avoid false positives on real
    /// (if soft) speech, not tuned to catch every last whisper.
    private let silenceRMSThreshold: Float = 0.01
    /// Below this much cumulative above-threshold audio, the recording
    /// counts as silence even if isolated buffers spiked. At the tap's
    /// 4096-frame buffer size (~85ms at 48kHz), this needs at least two
    /// consecutive above-floor buffers — long enough that a single click
    /// or mouth-noise can't clear it alone, short enough that even a
    /// one-syllable word comfortably does.
    private let minimumSignalDuration: Double = 0.15

    /// Optional live feed of every captured buffer, for callers that need to
    /// watch an in-progress recording (hands-free auto-stop) rather than
    /// just the completed file. `nil` by default — push-to-talk and
    /// hands-free sessions with no listener pay nothing extra. Called
    /// synchronously from the real-time tap callback below, so whatever's
    /// attached here must return immediately, same as the rest of that
    /// callback — no async work, no blocking.
    var onLiveBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// A second, independent live feed, for the HUD's live-transcript
    /// preview — separate from `onLiveBuffer` because the two run on
    /// different schedules (hands-free-with-auto-stop sessions only, vs.
    /// every recording) and must never clobber each other by sharing one
    /// slot the way a single property would. Same real-time contract as
    /// `onLiveBuffer`: called synchronously from the tap callback, so
    /// whatever's attached here must return immediately.
    var onLivePreviewBuffer: ((AVAudioPCMBuffer) -> Void)?

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start() throws {
        guard !isRecording else { return }

        let input = engine.inputNode
        // Pin to the built-in mic rather than trusting whatever the system's
        // current default input is. A Bluetooth headset's default input sits
        // in high-quality output-only mode (A2DP) until something asks for
        // input, at which point macOS switches it into a lower-quality
        // bidirectional mode (HFP) — a real hardware renegotiation. That
        // switch is what visibly ducks whatever else is playing, and it can
        // take longer than a quick hold-to-talk press: the recording ends
        // before the mic ever delivers a frame, so every dictation silently
        // came back empty. Best-effort — a Mac with no built-in mic just
        // keeps using the system default, same as before.
        preferBuiltInMicrophone(on: input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "Chirp", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-\(UUID().uuidString).caf")

        // Installing a tap on a bus that already has one raises an
        // NSException from AVFoundation — which Swift cannot catch, so it
        // aborts the whole process. `removeTap` on a bus with no tap is a
        // no-op, making this the cheap way to guarantee the bus is clear.
        input.removeTap(onBus: 0)

        file = nil
        currentFileURL = url
        capturedFrames = 0
        capturedFormat = nil
        hasSignal = false
        signalFrameCount = 0

        // `format: nil` means "whatever this bus is actually running at".
        //
        // Passing an explicit format is the other way installTap raises —
        // and a Bluetooth headset guarantees it eventually will. AirPods sit
        // at 48kHz for playback but drop to 24kHz the instant the mic is
        // engaged, so a format read a moment earlier is stale by the time
        // the tap installs: exception, process aborted.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            // The file is created from the FIRST buffer's real format rather
            // than the format read above, for the same reason. When those
            // disagreed, every write threw, `try?` swallowed it, and the
            // recording ended up as a header with no audio — a silent
            // failure that looked exactly like the app being broken.
            if self.file == nil {
                self.file = try? AVAudioFile(
                    forWriting: url, settings: buffer.format.settings)
                self.capturedFormat = buffer.format
            }
            try? self.file?.write(from: buffer)
            self.capturedFrames += AVAudioFramePosition(buffer.frameLength)
            if Self.hasSignal(in: buffer, above: self.silenceRMSThreshold) {
                self.signalFrameCount += AVAudioFramePosition(buffer.frameLength)
            }
            self.onLiveBuffer?(buffer)
            self.onLivePreviewBuffer?(buffer)
        }

        do {
            let startedAt = Date()
            engine.prepare()
            try engine.start()
            dictationLog.info(
                "start: engine running in \(Date().timeIntervalSince(startedAt) * 1000, format: .fixed(precision: 0))ms")
        } catch {
            // Unwind completely. Leaving the tap installed while
            // `isRecording` stayed false was a latent landmine: the next
            // start() would sail past the guard above, install a second tap,
            // and kill the app — so one transient audio failure permanently
            // broke dictation until relaunch.
            input.removeTap(onBus: 0)
            engine.stop()
            file = nil
            currentFileURL = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        isRecording = true
    }

    /// Stops recording and returns the captured audio file URL,
    /// or nil if nothing was recorded.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        file = nil
        hasSignal = Self.hasSustainedSignal(
            signalFrames: signalFrameCount,
            sampleRate: capturedFormat?.sampleRate ?? 0,
            minimumDuration: minimumSignalDuration)
        let url = currentFileURL
        currentFileURL = nil
        return url
    }

    /// Stops and deletes the in-progress recording.
    func cancel() {
        if let url = stop() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Silence detection

    /// Raw RMS energy of one buffer, 0 and up — the same computation
    /// `hasSignal(in:above:)` below compares against a fixed threshold,
    /// exposed directly for a caller that wants a continuous level to
    /// visualize (the onboarding mic test's live waveform) rather than a
    /// plain yes/no gate. Silent or malformed input reads as 0 rather
    /// than failing open, since a UI meter degrading to "looks quiet" is
    /// the right failure mode here — unlike `hasSignal`, nothing
    /// downstream mistakes this for "definitely no speech, skip
    /// recognition".
    static func rmsLevel(in buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else { return 0 }
        var sumOfSquares: Float = 0
        let samples = channelData[0]
        for i in 0..<frameCount {
            let sample = samples[i]
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(frameCount)).squareRoot()
    }

    /// RMS energy of one buffer against a threshold. The tap's format comes
    /// from whatever the live device reports (see `start()`), which in
    /// practice is always deinterleaved Float32 for an `AVAudioInputNode` —
    /// but "in practice" isn't "guaranteed", so an unrecognised format fails
    /// open (`true`) rather than silently treating real speech as silence.
    static func hasSignal(in buffer: AVAudioPCMBuffer, above threshold: Float) -> Bool {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return false }
        guard let channelData = buffer.floatChannelData else { return true }

        var sumOfSquares: Float = 0
        let samples = channelData[0]
        for i in 0..<frameCount {
            let sample = samples[i]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(frameCount)).squareRoot()
        return rms > threshold
    }

    /// Whether accumulated above-floor audio time (from summing
    /// `hasSignal(in:above:)` across every buffer in a recording) clears
    /// the minimum a real spoken word needs — as opposed to a single
    /// buffer's transient spike. `sampleRate <= 0` (no audio ever
    /// captured) can't clear any duration, so it's silence, not a crash.
    static func hasSustainedSignal(
        signalFrames: AVAudioFramePosition, sampleRate: Double, minimumDuration: Double
    ) -> Bool {
        guard sampleRate > 0 else { return false }
        return Double(signalFrames) / sampleRate >= minimumDuration
    }

    // MARK: - Device selection

    /// Overrides the input node's hardware device via Core Audio, entirely
    /// best-effort: any failure along the way just leaves the node on
    /// whatever the system default already was.
    private func preferBuiltInMicrophone(on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else {
            dictationLog.error("mic route: no input AudioUnit yet")
            return
        }
        guard var deviceID = Self.builtInInputDeviceID() else {
            dictationLog.info("mic route: no built-in mic found, using system default")
            return
        }
        // Only when it isn't already pinned there. Setting
        // `CurrentDevice` re-initialises the audio unit and renegotiates
        // the hardware route — hundreds of milliseconds, paid on *every*
        // key press, and it was being paid even when the answer was
        // "it's already the built-in mic". That's the delay where the
        // first word of a dictation went missing.
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let readStatus = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &current, &size)
        if readStatus == noErr, current == deviceID {
            dictationLog.info("mic route: already on built-in device \(deviceID)")
            return
        }
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        dictationLog.info(
            "mic route: pin to built-in device \(deviceID) -> status \(status)")
    }

    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &dataSize, &deviceIDs) == noErr
        else { return nil }

        return deviceIDs.first { isBuiltIn($0) && hasInputStreams($0) }
    }

    private static func isBuiltIn(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &transportType) == noErr
        else { return false }
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }

    /// A device can be built-in and output-only (the Mac's speakers) — this
    /// confirms it actually has an input side before we route to it.
    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
        else { return false }
        return size > 0
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000,
            channels: 1, interleaved: false)
        else {
            check(false, "could not construct a test audio format")
            return false
        }

        func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
            let buf = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buf.frameLength = AVAudioFrameCount(samples.count)
            let channel = buf.floatChannelData![0]
            for (i, sample) in samples.enumerated() { channel[i] = sample }
            return buf
        }

        let threshold: Float = 0.01

        let silence = buffer([Float](repeating: 0, count: 1000))
        check(!hasSignal(in: silence, above: threshold), "pure silence has no signal")

        // A real mic never reports exact zero — self-noise sits a bit above
        // it. This is what "pressed the key, said nothing" actually looks
        // like, not literal digital silence.
        let micNoiseFloor = buffer((0..<1000).map { _ in Float.random(in: -0.002...0.002) })
        check(!hasSignal(in: micNoiseFloor, above: threshold),
              "mic self-noise floor stays below the threshold")

        let speechLike = buffer((0..<1000).map { i in
            Float(sin(Double(i) * 0.1)) * 0.3
        })
        check(hasSignal(in: speechLike, above: threshold),
              "speech-amplitude signal is detected")

        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 0)!
        check(!hasSignal(in: empty, above: threshold), "an empty buffer has no signal")

        // Right at the threshold: a constant-amplitude signal's RMS equals
        // that amplitude, so this is the exact boundary the `>` comparison
        // has to get right in both directions.
        let justBelow = buffer([Float](repeating: threshold - 0.0001, count: 100))
        check(!hasSignal(in: justBelow, above: threshold), "just below threshold is silence")
        let justAbove = buffer([Float](repeating: threshold + 0.0001, count: 100))
        check(hasSignal(in: justAbove, above: threshold), "just above threshold is signal")

        // Reproduces the actual incident: a real recording held for 1.5s at
        // 48kHz, where only one 4096-frame tap buffer (~85ms) ever crossed
        // the RMS floor — a click or breath, not speech. The old "was there
        // ever a moment above threshold" latch called this signal; it isn't.
        let minDuration = 0.15
        let oneClickBuffer: AVAudioFramePosition = 4096
        check(!hasSustainedSignal(
            signalFrames: oneClickBuffer, sampleRate: 48000, minimumDuration: minDuration),
              "one 85ms buffer above the floor isn't sustained signal")

        // Two-plus consecutive buffers — what an actual spoken word looks
        // like — clears it.
        let wordLength: AVAudioFramePosition = 8192
        check(hasSustainedSignal(
            signalFrames: wordLength, sampleRate: 48000, minimumDuration: minDuration),
              "170ms of above-floor audio is sustained signal")

        check(!hasSustainedSignal(signalFrames: 0, sampleRate: 48000, minimumDuration: minDuration),
              "zero signal frames is silence")
        check(!hasSustainedSignal(signalFrames: 999_999, sampleRate: 0, minimumDuration: minDuration),
              "an unknown sample rate can't clear any duration")

        // Exact boundary: 0.15s at 48kHz is 7200 frames.
        check(!hasSustainedSignal(signalFrames: 7199, sampleRate: 48000, minimumDuration: minDuration),
              "just under the duration floor is silence")
        check(hasSustainedSignal(signalFrames: 7200, sampleRate: 48000, minimumDuration: minDuration),
              "exactly the duration floor is signal")

        return passed
    }
}
