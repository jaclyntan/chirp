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

    private let worker = MeetingAudioWorker()

    static func runSelfTest() async -> Bool {
        await MeetingAudioWorker.runSelfTest()
    }

    /// Explicit diagnostic, limited to short fixtures; never runs at launch.
    static func compareStreaming(fileAt url: URL) async -> Bool {
        await MeetingAudioWorker().compareStreaming(fileAt: url)
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
        activity: RuntimeActivity? = nil,
        transcribeFile: (URL) async throws -> String
    ) async -> [MeetingSegment] {
        var segments: [MeetingSegment] = []
        await activity?.waitUntilAwake()

        if let micURL {
            if let raw = try? await transcribeFile(micURL), !raw.isEmpty {
                let corrected = Self.applyCorrections(to: raw)
                let duration = Self.duration(of: micURL)
                segments.append(MeetingSegment(
                    speakerIndex: 0, speakerName: "You", text: corrected,
                    startTime: 0, endTime: duration))
            }
        }

        if let systemAudioURL {
            await activity?.waitUntilAwake()
            let knownNames = Set(knownSpeakers.map { $0.name.lowercased() })

            if let result = await worker.diarize(
                fileAt: systemAudioURL, knownSpeakers: knownSpeakers, activity: activity) {
                var speakerOrder: [String: Int] = [:]
                var hintUsed = false
                for speakerSegment in result.segments {
                    await activity?.waitUntilAwake()
                    let index: Int
                    if let known = speakerOrder[speakerSegment.speakerId] {
                        index = known
                    } else {
                        // Index 0 is reserved for "You" (the mic track), so
                        // the first distinct diarized voice becomes 1.
                        index = speakerOrder.count + 1
                        speakerOrder[speakerSegment.speakerId] = index
                    }

                    guard speakerSegment.durationSeconds > 0.25 else { continue }
                    guard let clipURL = try? await worker.writeClip(
                        from: systemAudioURL,
                        start: Double(speakerSegment.startTimeSeconds),
                        end: Double(speakerSegment.endTimeSeconds))
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
            } else {
                // A model/download failure must not discard the other side.
                await activity?.waitUntilAwake()
                if let raw = try? await transcribeFile(systemAudioURL), !raw.isEmpty {
                    segments.append(MeetingSegment(
                        speakerIndex: 1, speakerName: attendeeHint,
                        text: Self.applyCorrections(to: raw), startTime: 0,
                        endTime: Self.duration(of: systemAudioURL)))
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

}

/// Disk reads and synchronous Core ML diarization run away from the UI
/// actor. One reusable ten-second audio buffer replaces the full-file
/// array. Models are released before transcription starts reading clips.
private actor MeetingAudioWorker {
    func diarize(fileAt url: URL, knownSpeakers: [KnownSpeaker],
                 activity: RuntimeActivity? = nil) async -> DiarizationResult? {
        do {
            let reader = try MeetingAudioWindowReader(url: url)
            guard !reader.isEmpty else { return nil }
            await activity?.waitUntilAwake()
            try Task.checkCancellation()
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = Self.manager(models: models, knownSpeakers: knownSpeakers)
            return try await diarizeWindows(reader: reader, manager: manager, activity: activity)
        } catch {
            // Discard partial separation on failure; the caller transcribes
            // the original recording as one speaker instead of losing audio.
            dictationLog.error("meeting: speaker separation unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func manager(models: DiarizerModels, knownSpeakers: [KnownSpeaker]) -> DiarizerManager {
        // Keep disk windows and engine windows identical. The same manager
        // tracks enrolled and newly discovered speakers across every call.
        var config = DiarizerConfig.default
        config.chunkDuration = Float(MeetingAudioWindowReader.windowSeconds)
        config.chunkOverlap = 0
        let manager = DiarizerManager(config: config)
        manager.initialize(models: models)
        manager.initializeKnownSpeakers(knownSpeakers.map {
            Speaker(id: $0.name, name: $0.name, currentEmbedding: $0.embedding, isPermanent: true)
        })
        return manager
    }

    private func diarizeWindows(reader: MeetingAudioWindowReader, manager: DiarizerManager,
                                activity: RuntimeActivity? = nil) async throws -> DiarizationResult {
        var segments: [TimedSpeakerSegment] = []
        while reader.hasMore {
            // Sleep cannot start another ten-second inference window. No
            // borrowed PCM pointer is retained across this suspension.
            await activity?.waitUntilAwake()
            try Task.checkCancellation()
            let result = try autoreleasepool {
                try reader.withNextWindow { samples, offset in
                    try manager.performCompleteDiarization(
                        samples, sampleRate: MeetingAudioWindowReader.sampleRate, atTime: offset)
                }
            }
            if let result { segments.append(contentsOf: result.segments) }
        }
        return DiarizationResult(segments: segments)
    }

    /// Short fixtures only: never used by the production meeting pipeline.
    private static func fixtureSamples(from url: URL) throws -> [Float] {
        let reader = try MeetingAudioWindowReader(url: url)
        var samples: [Float] = []
        while let window = try reader.withNextWindow({ samples, _ in Array(samples) }) {
            samples.append(contentsOf: window)
        }
        return samples
    }

    /// Seek and stream the speaker's range from disk. No clip-sized Array
    /// or PCM allocation, and no full recording retained across awaits.
    func writeClip(from source: URL, start: TimeInterval, end: TimeInterval) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let rate = input.processingFormat.sampleRate
        let first = max(0, min(input.length, AVAudioFramePosition(start * rate)))
        let last = max(first, min(input.length, AVAudioFramePosition(end * rate)))
        guard last > first,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384)
        else { throw MeetingTranscriber.TranscribeError.emptyAudio }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-clip-\(UUID().uuidString).caf")
        do {
            let output = try AVAudioFile(forWriting: url, settings: input.processingFormat.settings)
            input.framePosition = first
            while input.framePosition < last {
                let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), last - input.framePosition))
                try input.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Compare the production streaming path with the previous full-array
    /// algorithm using cached models, without accessing any saved meetings.
    func compareStreaming(fileAt url: URL) async -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > Int64(MeetingAudioWindowReader.windowFrames),
                  Double(file.length) / file.processingFormat.sampleRate <= 120 else {
                print("FAIL: comparison fixture must be longer than 10 seconds and at most 120 seconds")
                return false
            }
            let directory = DiarizerModels.defaultModelsDirectory()
            let models = try DiarizerModels.load(
                localSegmentationModel: directory.appendingPathComponent("pyannote_segmentation.mlmodelc"),
                localEmbeddingModel: directory.appendingPathComponent("wespeaker_v2.mlmodelc"))
            let samples = try Self.fixtureSamples(from: url)
            let baseline = try autoreleasepool {
                try Self.manager(models: models, knownSpeakers: [])
                    .performCompleteDiarization(samples, sampleRate: MeetingAudioWindowReader.sampleRate)
            }
            guard let enrolled = baseline.segments.first, !enrolled.embedding.isEmpty else {
                print("FAIL: comparison fixture must contain recognizable speech")
                return false
            }
            // Repeat with enrollment to verify names also survive windows.
            let cases: [[KnownSpeaker]] = [[], [KnownSpeaker(name: "Fixture speaker", embedding: enrolled.embedding)]]
            for known in cases {
                let reference = known.isEmpty ? baseline : try autoreleasepool {
                    try Self.manager(models: models, knownSpeakers: known)
                        .performCompleteDiarization(samples, sampleRate: MeetingAudioWindowReader.sampleRate)
                }
                let streamed = try await diarizeWindows(
                    reader: MeetingAudioWindowReader(url: url),
                    manager: Self.manager(models: models, knownSpeakers: known))
                // New speaker UUIDs differ per manager; compare first-seen
                // ordering, but preserve enrolled names verbatim.
                func speakerKeys(_ segments: [TimedSpeakerSegment]) -> [String] {
                    var order: [String: Int] = [:]
                    return segments.map { segment in
                        if known.contains(where: { $0.name == segment.speakerId }) {
                            return segment.speakerId
                        }
                        if order[segment.speakerId] == nil { order[segment.speakerId] = order.count }
                        return "anonymous-\(order[segment.speakerId]!)"
                    }
                }
                let same = reference.segments.count == streamed.segments.count
                    && speakerKeys(reference.segments) == speakerKeys(streamed.segments)
                    && zip(reference.segments, streamed.segments).allSatisfy { left, right in
                        abs(left.startTimeSeconds - right.startTimeSeconds) < 0.0001
                            && abs(left.endTimeSeconds - right.endTimeSeconds) < 0.0001
                            && abs(left.qualityScore - right.qualityScore) < 0.0001
                            && left.embedding.count == right.embedding.count
                            && zip(left.embedding, right.embedding).allSatisfy { abs($0 - $1) < 0.0001 }
                    }
                let enrolledPreserved = known.isEmpty || streamed.segments.contains { $0.speakerId == "Fixture speaker" }
                let passed = same && enrolledPreserved
                print("\(passed ? "PASS" : "FAIL"): streamed diarization matches full-array labels, times and embeddings (\(known.isEmpty ? "anonymous" : "enrolled"), \(streamed.segments.count) segments)")
                if !passed { return false }
            }
            return true
        } catch {
            print("FAIL: streaming comparison: \(error)")
            return false
        }
    }

    static func runSelfTest() async -> Bool {
        var passed = true
        func check(_ value: Bool, _ label: String) {
            if !value { passed = false }
            print("\(value ? "PASS" : "FAIL"): \(label)")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-meeting-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][index] = Float(index) / 48000
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let samples = try fixtureSamples(from: url)
            check(samples.count == 48000 && samples[20000] == Float(20000) / 48000,
                  "chunked meeting read preserves samples across buffer boundaries")
            let worker = MeetingAudioWorker()
            let clip = try await worker.writeClip(from: url, start: 0.5, end: 2.75)
            defer { try? FileManager.default.removeItem(at: clip) }
            let clipped = try fixtureSamples(from: clip)
            check(clipped.count == 36000 && clipped.first == samples[8000] && clipped.last == samples[43999],
                  "streamed speaker clip preserves exact range across multiple writes")
            let clamped = try await worker.writeClip(from: url, start: 2.5, end: 100)
            defer { try? FileManager.default.removeItem(at: clamped) }
            check(try fixtureSamples(from: clamped).count == 8000,
                  "speaker clip safely clamps to the recording end")
            do {
                _ = try await worker.writeClip(from: url, start: 2, end: 1)
                check(false, "an invalid speaker range is rejected")
            } catch {
                check(true, "an invalid speaker range is rejected")
            }
            // More than two windows with a tiny final tail, written with
            // bounded storage and checked sample-by-sample without an array.
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let total = MeetingAudioWindowReader.windowFrames * 2 + 37
                let write = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                var first = 0
                while first < total {
                    write.frameLength = AVAudioFrameCount(min(4096, total - first))
                    for index in 0..<Int(write.frameLength) {
                        write.floatChannelData![0][index] = Float((first + index) % 8192) / 8192
                    }
                    try file.write(from: write)
                    first += Int(write.frameLength)
                }
            }
            let reader = try MeetingAudioWindowReader(url: url)
            var counts: [Int] = []
            var offsets: [TimeInterval] = []
            var address: UnsafePointer<Float>?
            var reused = true
            var exact = true
            while let count = try reader.withNextWindow({ samples, offset in
                let first = Int(offset * 16000)
                exact = exact && samples.enumerated().allSatisfy {
                    $0.element == Float((first + $0.offset) % 8192) / 8192
                }
                if let address { reused = reused && address == samples.baseAddress }
                else { address = samples.baseAddress }
                offsets.append(offset)
                return samples.count
            }) {
                counts.append(count)
            }
            check(counts == [160000, 160000, 37] && offsets == [0, 10, 20] && exact,
                  "meeting stream reads each sample once with exact absolute offsets and a short tail")
            check(reused, "meeting stream reuses one ten-second PCM allocation across windows")
            check(try reader.withNextWindow({ _, _ in true }) == nil,
                  "meeting stream produces no padded or duplicate window after EOF")
            do {
                _ = try MeetingAudioWindowReader(url: url).withNextWindow { _, _ -> Bool in
                    throw MeetingAudioWindowReader.ReadError.incompleteRead(expected: 1, actual: 0)
                }
                check(false, "meeting stream propagates inference errors instead of accepting partial results")
            } catch {
                check(true, "meeting stream propagates inference errors instead of accepting partial results")
            }
            for (rate, channels) in [(48000.0, AVAudioChannelCount(1)), (16000.0, AVAudioChannelCount(2))] {
                let invalid = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
                do { _ = try AVAudioFile(forWriting: url, settings: invalid.settings) }
                do {
                    _ = try MeetingAudioWindowReader(url: url)
                    check(false, "meeting stream rejects unsupported format \(Int(rate)) Hz / \(channels) channels")
                } catch {
                    check(true, "meeting stream rejects unsupported format \(Int(rate)) Hz / \(channels) channels")
                }
            }
            do { _ = try AVAudioFile(forWriting: url, settings: format.settings) }
            let empty = try MeetingAudioWindowReader(url: url)
            let emptyWindow = try empty.withNextWindow({ _, _ in true })
            check(empty.isEmpty && emptyWindow == nil,
                  "empty meeting audio requires no inference window")
        } catch {
            check(false, "meeting audio self-test: \(error)")
        }
        return passed
    }

}
