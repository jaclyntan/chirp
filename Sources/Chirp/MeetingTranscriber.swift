import AVFoundation
import FluidAudio
import Foundation

/// Turns a captured meeting — the user's own mic recording plus the other
/// side's system-audio recording — into a diarized, transcribed list of
/// `MeetingSegment`s. Deliberately takes transcription as an injected
/// closure rather than calling an ASR engine directly: `AppDelegate`
/// already owns engine selection, fallback, and error handling for every
/// other dictation (`recognize(fileAt:bundleID:)`), and this reuses that
/// exact function rather than duplicating it.
///
/// Speaker separation is two-tier, not full identification: track 0 is
/// always "You" (the mic recording, never ambiguous), and everyone else is
/// a numbered cluster from `DiarizerManager` — "Speaker 2", "Speaker 3" —
/// not a real name. Chirp has no source for real participant names
/// on-device; the user can rename a speaker afterward in the Notetaker
/// page, but nothing here guesses.
@MainActor
final class MeetingTranscriber {
    enum TranscribeError: Error {
        case emptyAudio
    }

    private var diarizer: DiarizerManager?
    private(set) var diarizerPreparationFailed = false

    var isDiarizerReady: Bool { diarizer?.isAvailable ?? false }

    /// Downloads (once, on first real use — not bundled with the app) and
    /// loads the diarization model, the same "fetch on first use" pattern
    /// Whisper/Parakeet's own models already follow. Safe to call
    /// speculatively and often — a no-op once `diarizer` is set.
    func prepareDiarizer() async {
        guard diarizer == nil, !diarizerPreparationFailed else { return }
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            diarizer = manager
        } catch {
            diarizerPreparationFailed = true
        }
    }

    /// - Parameters:
    ///   - micURL: the user's own voice, from `AudioRecorder.stop()`. Nil
    ///     if the mic recorder was never started (shouldn't normally
    ///     happen, but a meeting isn't lost over it).
    ///   - systemAudioURL: everyone else, from `MeetingAudioCapture.stop()`
    ///     — nil if system-audio capture never produced anything (Screen
    ///     Recording permission missing, or the meeting app closed
    ///     instantly).
    ///   - knownSpeakers: previously-enrolled voices (see
    ///     `KnownSpeakerStore`) — when one of them speaks in this meeting,
    ///     `DiarizerManager` recognizes the match itself and this returns
    ///     their real name already filled in, no renaming needed. This is
    ///     what makes a name "stick" across different meetings, the same
    ///     behavior Wispr Flow's own Notetaker describes.
    ///   - attendeeHint: the first still-unnamed voice gets this as a
    ///     best-effort label (from the calendar event's own attendee
    ///     list) rather than "Speaker 2" — a *label*, not an enrollment;
    ///     it isn't saved as a known speaker unless the user confirms it
    ///     by leaving it or renaming it, same as any other segment.
    func transcribe(
        micURL: URL?, systemAudioURL: URL?, knownSpeakers: [KnownSpeaker], attendeeHint: String?,
        transcribeFile: (URL) async throws -> String
    ) async -> [MeetingSegment] {
        var segments: [MeetingSegment] = []

        if let micURL {
            if let raw = try? await transcribeFile(micURL), !raw.isEmpty {
                let corrected = Self.applyCorrections(to: raw)
                let duration = Self.duration(of: micURL)
                segments.append(MeetingSegment(
                    speakerIndex: 0, speakerName: "You", text: corrected,
                    startTime: 0, endTime: duration))
            }
        }

        if let systemAudioURL, let diarizer, diarizer.isAvailable,
           let samples = try? Self.floatSamples(from: systemAudioURL), !samples.isEmpty {
            diarizer.initializeKnownSpeakers(knownSpeakers.map {
                Speaker(id: $0.name, name: $0.name, currentEmbedding: $0.embedding, isPermanent: true)
            })
            let knownNames = Set(knownSpeakers.map { $0.name.lowercased() })

            if let result = try? diarizer.performCompleteDiarization(samples, sampleRate: 16_000) {
                var speakerOrder: [String: Int] = [:]
                var hintUsed = false
                for speakerSegment in result.segments {
                    let index: Int
                    if let known = speakerOrder[speakerSegment.speakerId] {
                        index = known
                    } else {
                        // Index 0 is reserved for "You" (the mic track), so
                        // the first distinct diarized voice becomes 1.
                        index = speakerOrder.count + 1
                        speakerOrder[speakerSegment.speakerId] = index
                    }

                    let startSample = max(0, Int(speakerSegment.startTimeSeconds * 16_000))
                    let endSample = min(samples.count, Int(speakerSegment.endTimeSeconds * 16_000))
                    guard endSample - startSample > 16_000 / 4 else { continue }  // skip clips under ~250ms
                    guard let clipURL = try? Self.writeTempCAF(Array(samples[startSample..<endSample]))
                    else { continue }
                    defer { try? FileManager.default.removeItem(at: clipURL) }

                    guard let raw = try? await transcribeFile(clipURL), !raw.isEmpty else { continue }
                    let corrected = Self.applyCorrections(to: raw)

                    // A recognized known speaker's own diarized id *is*
                    // their enrolled name (see `initializeKnownSpeakers`
                    // above) — matching case-insensitively since that
                    // enrollment came from a name the user typed by hand.
                    var name: String?
                    if knownNames.contains(speakerSegment.speakerId.lowercased()) {
                        name = speakerSegment.speakerId
                    } else if index == 1, let attendeeHint, !hintUsed {
                        name = attendeeHint
                        hintUsed = true
                    }

                    segments.append(MeetingSegment(
                        speakerIndex: index, speakerName: name, text: corrected,
                        startTime: Double(speakerSegment.startTimeSeconds),
                        endTime: Double(speakerSegment.endTimeSeconds),
                        embedding: speakerSegment.embedding))
                }
            }
        }

        return segments.sorted { $0.startTime < $1.startTime }
    }

    /// The same English-only dictionary + grammar corrections every normal
    /// dictation gets (see `AppDelegate.stopAndTranscribe`'s own
    /// `isEnglishDictation` gate) — a meeting transcript was previously raw
    /// ASR output only, with none of Chirp's own accuracy pipeline
    /// applied. Snippet expansion is deliberately *not* included here:
    /// meeting audio is continuous, often someone else's, speech, not a
    /// one-shot dictation invocation — a snippet trigger phrase said in
    /// passing mid-sentence would silently swap out part of what was
    /// actually said, which is a real risk a normal dictation doesn't have.
    /// Developer vocabulary is left out too — it exists to bias code/API
    /// terms while dictating into an editor, which doesn't apply to
    /// meeting audio.
    private static func applyCorrections(to text: String) -> String {
        guard String(Settings.localeIdentifier.prefix(while: { $0 != "-" })).lowercased() == "en"
        else { return text }

        var corrected = LearnedStore.apply(in: text, includeDeveloperVocabulary: false)
        corrected = HarperChecker.fix(
            corrected, vocabulary: LearnedStore.biasTerms(includeDeveloperVocabulary: false))
        return corrected
    }

    private static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Reads a finished `.caf` recording back into raw samples — the one
    /// place this needs `[Float]` rather than a file, since
    /// `DiarizerManager.performCompleteDiarization` takes samples
    /// directly. Mirrors `WhisperCppEngine`'s own established
    /// `floatChannelData` extraction rather than inventing a new one.
    private static func floatSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw TranscribeError.emptyAudio }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }

    /// One diarized clip, written back out to its own tiny file so the
    /// existing `transcribeFile(URL)` engines — which all take a file, not
    /// samples — can run on just that speaker's turn instead of the whole
    /// system-audio recording.
    private static func writeTempCAF(_ samples: [Float]) throws -> URL {
        let url = AppPaths.supportDirectory.appendingPathComponent(
            "meeting-clip-\(UUID().uuidString).caf")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw TranscribeError.emptyAudio }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        return url
    }
}
