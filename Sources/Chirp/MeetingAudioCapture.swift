import AVFoundation
import Foundation
import ScreenCaptureKit

/// Captures *system audio only* — the other side of a call — via
/// ScreenCaptureKit, filtered to one running app so a meeting capture
/// doesn't also pick up Spotify or a Slack notification sound playing at
/// the same time. The user's own voice is captured separately, by reusing
/// the existing `AudioRecorder`: ScreenCaptureKit's own `.microphone`
/// output type exists too, but its format follows the mic's native rate
/// rather than the 16kHz `AudioRecorder` already produces, so reusing the
/// proven recorder avoids a second resampling path for no real benefit.
///
/// Writes straight to a `.caf` file via `AVAssetWriter` rather than
/// hand-parsing each `CMSampleBuffer` into `[Float]` — `AVAssetWriterInput`
/// accepts a `CMSampleBuffer` directly, so the one place this needs raw
/// samples (`MeetingTranscriber` handing audio to `DiarizerManager`) reads
/// them back out of the finished file with `AVAudioFile`, the same
/// established pattern `WhisperCppEngine` already uses for a PCM buffer's
/// `floatChannelData`. No video track: `capturesAudio` only needs a
/// *legal* screen configuration to attach to, not a real one, so width/
/// height are set to the smallest ScreenCaptureKit will accept rather than
/// the display's actual resolution.
final class MeetingAudioCapture: NSObject, @unchecked Sendable {
    enum CaptureError: Error {
        case appNotRunning
        case noDisplay
        case writerSetupFailed
    }

    private static let sampleRate = 16_000
    private let captureQueue = DispatchQueue(label: "chirp.meeting.audio")

    // Touched only from `captureQueue` once `start(bundleID:)` hands them
    // off — `start`/`stop` themselves run on the caller's task, but never
    // concurrently with each other (see `MeetingTranscriber`, the only
    // caller, which never starts a second capture before awaiting `stop`
    // on the first).
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var outputURL: URL?

    // Synchronized the same way `start`/`stop` touch `stream` — read
    // directly (no `captureQueue.sync`), this raced with the capture
    // callback setting it from that queue.
    var isCapturing: Bool { captureQueue.sync { stream != nil } }

    /// Fired on `captureQueue` for every sample buffer this stream
    /// delivers, *in addition to* the file write above — a live tap on the
    /// other side of the call, the system-audio equivalent of
    /// `AudioRecorder.onLivePreviewBuffer`. Never gates or delays the file
    /// write itself; a slow or absent consumer here can't affect the saved
    /// recording.
    var onLiveBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(bundleID: String) async throws {
        guard !isCapturing else { return }
        let content = try await SCShareableContent.current
        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID })
        else { throw CaptureError.appNotRunning }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Self.sampleRate
        config.channelCount = 1
        // This is Chirp's own process — nothing it plays itself (a sound
        // effect, an in-app preview) belongs in a captured transcript.
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let url = AppPaths.supportDirectory.appendingPathComponent(
            "meeting-\(UUID().uuidString).caf")
        let newWriter = try AVAssetWriter(outputURL: url, fileType: .caf)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        input.expectsMediaDataInRealTime = true
        guard newWriter.canAdd(input) else { throw CaptureError.writerSetupFailed }
        newWriter.add(input)

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try await newStream.startCapture()

        captureQueue.sync {
            self.stream = newStream
            self.writer = newWriter
            self.audioInput = input
            self.sessionStarted = false
            self.outputURL = url
        }
    }

    /// Stops the stream and finalizes the written file — `nil` if nothing
    /// was ever actually captured (the target app closed the instant
    /// capture began, so no audio buffer ever arrived to open the write
    /// session).
    func stop() async -> URL? {
        guard let stream = captureQueue.sync(execute: { self.stream }) else { return nil }
        try? await stream.stopCapture()

        return await withCheckedContinuation { continuation in
            captureQueue.async {
                self.stream = nil
                let writer = self.writer
                let input = self.audioInput
                let started = self.sessionStarted
                let url = self.outputURL
                self.audioInput = nil
                self.writer = nil

                guard started, let writer, let input else {
                    continuation.resume(returning: nil)
                    return
                }
                input.markAsFinished()
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }
    }
}

extension MeetingAudioCapture: SCStreamOutput {
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // `addStreamOutput` was called with `sampleHandlerQueue: captureQueue`,
        // so this delivers on that same serial queue already — no further
        // hop needed, which is what keeps buffers appended to `audioInput`
        // in the same order ScreenCaptureKit produced them.
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let writer, let audioInput
        else { return }

        if !sessionStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        guard audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)

        if let onLiveBuffer, let buffer = Self.pcmBuffer(from: sampleBuffer) {
            onLiveBuffer(buffer)
        }
    }

    /// Converts one delivered `CMSampleBuffer` to the `AVAudioPCMBuffer`
    /// shape `onLiveBuffer` (and, downstream, `LivePreviewTranscriber`)
    /// expects — `AVAssetWriterInput.append` above takes a `CMSampleBuffer`
    /// directly, so this conversion exists solely for the live tap, not the
    /// file write. Grounded in `CMSampleBufferCopyPCMDataIntoAudioBufferList`,
    /// the documented CoreMedia call for copying PCM samples out of a
    /// sample buffer into a caller-owned `AudioBufferList` — reads the
    /// buffer's own format rather than assuming the 16kHz mono config
    /// requested above is exactly what ScreenCaptureKit delivered.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd)
        else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buffer
    }
}
