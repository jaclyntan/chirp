import AVFoundation
import AppKit
import Foundation

@main
struct ChirpMain {
    @MainActor
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst()).makeIterator()
        var mode: Mode = .app
        var localeIdentifier = "en-US"
        var bundleID: String?

        while let argument = arguments.next() {
            switch argument {
            case "--transcribe":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .transcribe(path)
            case "--live-preview":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .livePreview(path)
            case "--format":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .format(text)
            case "--edit":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .edit(text)
            case "--harper-fix":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .harperFix(text)
            case "--history":
                mode = .history
            case "--history-search":
                guard let query = arguments.next() else { usageAndExit() }
                mode = .historySearch(query)
            case "--history-export":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .historyExport(path)
            case "--selftest":
                mode = .selftest
            case "--locale":
                localeIdentifier = arguments.next() ?? localeIdentifier
            case "--bundle-id":
                bundleID = arguments.next() ?? bundleID
            case "--help", "-h":
                usageAndExit()
            default:
                usageAndExit()
            }
        }

        switch mode {
        case .selftest:
            let formatterPassed = TextFormatter.runSelfTest()
            let learnedPassed = LearnedStore.runSelfTest()
            let rewritePlanPassed = RewritePlanSelfTest.run()
            let audioPassed = AudioRecorder.runSelfTest()
            let hallucinationPassed = HallucinationFilter.runSelfTest()
            let developerVocabPassed = DeveloperVocabulary.runSelfTest()
            exit(formatterPassed && learnedPassed
                 && rewritePlanPassed && audioPassed && hallucinationPassed
                 && developerVocabPassed ? 0 : 1)

        case .format(let text):
            // Same pipeline as live dictation: format, apply learned
            // corrections, then expand snippets. --bundle-id resolves
            // developer-vocabulary the same way a real dictation into that
            // app would (default: off, matching a `nil` bundle ID/no
            // resolvable frontmost app).
            let developerVocabulary = DictationDefaults.developerVocabularyEnabled(
                forBundleID: bundleID)
            print(SnippetStore.expand(
                in: LearnedStore.apply(
                    in: TextFormatter().format(text),
                    includeDeveloperVocabulary: developerVocabulary)))
            exit(0)

        case .harperFix(let text):
            let developerVocabulary = DictationDefaults.developerVocabularyEnabled(
                forBundleID: bundleID)
            print(HarperChecker.fix(
                text,
                vocabulary: LearnedStore.biasTerms(
                    includeDeveloperVocabulary: developerVocabulary)))
            exit(0)

        case .edit(let text):
            // Runs the exact same pipeline stopAndTranscribe() does for a
            // dictation into --bundle-id (default: no app, so the global
            // default style/no per-app override), rather than a synthetic
            // instruction string, so this reproduces field reports
            // faithfully instead of a simplified stand-in.
            //
            // Style resolves through DictationDefaults exactly like the real
            // pipeline (a bundle ID's own override, else Raw for a
            // recognized terminal, else the global default) rather than
            // hardcoding StyleSettings.defaultStyle — the gap between
            // those two used to mean this command couldn't reproduce a
            // Raw-style app at all, only ever exercising the non-Raw path.
            let style = DictationDefaults.style(forBundleID: bundleID)
            guard !style.skipsAllProcessing else {
                print(text)
                exit(0)
            }
            let engine = RewriteEngine()
            if let note = engine.availabilityNote {
                FileHandle.standardError.write(Data("Unavailable: \(note)\n".utf8))
                exit(1)
            }
            guard let instructions = RewritePlan.instructions(
                style: style, cleanupLevel: StyleSettings.defaultCleanupLevel)
            else {
                print(text)
                exit(0)
            }
            FileHandle.standardError.write(
                Data("--- instructions ---\n\(instructions)\n--- end instructions ---\n".utf8))
            do {
                let result = try await engine.edit(text, instructions: instructions)
                print(result)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
                exit(1)
            }

        case .history:
            printHistory(HistoryStore().entries)
            exit(0)

        case .historySearch(let query):
            printHistory(HistoryStore.matching(query, in: HistoryStore().entries))
            exit(0)

        case .historyExport(let path):
            do {
                let data = try JSONEncoder().encode(HistoryStore().entries)
                try data.write(to: URL(fileURLWithPath: path))
                print("Exported \(HistoryStore().entries.count) entries to \(path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Export failed: \(error)\n".utf8))
                exit(1)
            }

        // Feeds an audio file through `LivePreviewTranscriber` exactly as
        // a live recording would — one tap-sized buffer at a time — and
        // prints each partial. The only way to test the live preview
        // without speaking into a microphone, which is what made "no live
        // text" so hard to pin down.
        case .livePreview(let path):
            await runLivePreview(path: path)

        case .transcribe(let path):
            do {
                // --bundle-id resolves developer-vocabulary the same way a
                // real dictation into that app would (default: off,
                // matching a `nil` bundle ID/no resolvable frontmost app) —
                // pass e.g. `--bundle-id com.apple.dt.Xcode` to reproduce
                // what actually happens dictating into a recognized
                // developer-context app instead of the CLI's own default.
                let developerVocabulary = DictationDefaults.developerVocabularyEnabled(
                    forBundleID: bundleID)
                // Apple is the only engine now — see docs/removed-engines.md
                // for the Whisper/whisper.cpp/Parakeet branches this used
                // to dispatch across.
                let transcriber = Transcriber(
                    locale: Locale(identifier: localeIdentifier))
                let raw = try await transcriber.transcribe(
                    fileAt: URL(fileURLWithPath: path),
                    biasTerms: LearnedStore.biasTerms(
                        includeDeveloperVocabulary: developerVocabulary))
                // Full live-dictation pipeline: format → learned corrections
                // → snippet expansion → Harper — everything the real style
                // resolved for --bundle-id runs except the Apple
                // Intelligence rewrite pass, left out here since it's
                // non-deterministic and needs on-device model availability
                // this debug path shouldn't depend on. Personal corrections
                // and Harper are gated to English, matching AppDelegate's
                // `isEnglishDictation` — both assume English input and
                // corrupt other languages' real words otherwise.
                //
                // Branches on `DictationDefaults.style(forBundleID:)` the
                // same way AppDelegate does — this used to run one fixed
                // sequence regardless of --bundle-id, so it could not
                // exercise Raw mode's "skip formatting/Harper entirely"
                // path at all. Found by testing the terminal-defaults-to-
                // Raw change immediately after building it: every
                // --bundle-id gave the same output, silently, because
                // this pipeline never branched on the value it resolved.
                let isEnglishDictation =
                    String(localeIdentifier.prefix(while: { $0 != "-" }))
                    .lowercased() == "en"
                let style = DictationDefaults.style(forBundleID: bundleID)
                var formatted: String
                if style.skipsAllProcessing {
                    formatted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isEnglishDictation {
                        formatted = LearnedStore.apply(
                            in: formatted, includeDeveloperVocabulary: developerVocabulary)
                    }
                    formatted = SnippetStore.expand(in: formatted)
                } else {
                    formatted = TextFormatter(
                        dictionary: isEnglishDictation ? TextFormatter.loadDictionary() : [:]
                    ).format(raw)
                    if isEnglishDictation {
                        formatted = LearnedStore.apply(
                            in: formatted, includeDeveloperVocabulary: developerVocabulary)
                    }
                    formatted = SnippetStore.expand(in: formatted)
                    if isEnglishDictation {
                        formatted = HarperChecker.fix(
                            formatted,
                            vocabulary: LearnedStore.biasTerms(
                                includeDeveloperVocabulary: developerVocabulary))
                    }
                }
                print("RAW: \(raw)")
                print("style: \(style.rawValue)")
                print("FORMATTED: \(formatted)")
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data("Transcription failed: \(error)\n".utf8))
                exit(1)
            }

        case .app:
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }

    private enum Mode {
        case app
        case transcribe(String)
        case format(String)
        case edit(String)
        case harperFix(String)
        case history
        case historySearch(String)
        case historyExport(String)
        case selftest
        case livePreview(String)
    }

    @MainActor
    private static func runLivePreview(path: String) async {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else {
            FileHandle.standardError.write(Data("Could not open \(path)\n".utf8))
            exit(1)
        }
        let preview = LivePreviewTranscriber()
        var lastPrinted = ""
        preview.onUpdate = { text in
            guard text != lastPrinted else { return }
            lastPrinted = text
            print("partial: \(text)")
        }
        preview.start()

        // 4096 frames is what `AudioRecorder`'s own tap delivers, so the
        // model sees the same chunking a real dictation produces.
        let frames: AVAudioFrameCount = 4096
        while true {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
            do { try file.read(into: buffer, frameCount: frames) } catch { break }
            if buffer.frameLength == 0 { break }
            preview.enqueue(buffer)
            // Let the drain task actually run between buffers.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // Give the queue time to finish decoding what's left.
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("final partial: \(lastPrinted.isEmpty ? "<empty>" : lastPrinted)")
        exit(0)
    }

    /// One line per entry, tab-separated: timestamp, word count, text. Text
    /// can contain embedded newlines (templated output has its own line
    /// breaks) — collapsed to spaces so the one-line-per-entry shape a
    /// terminal pipeline expects actually holds.
    private static func printHistory(_ entries: [HistoryEntry]) {
        let formatter = ISO8601DateFormatter()
        for entry in entries {
            let line = entry.text.replacingOccurrences(of: "\n", with: " ")
            print("\(formatter.string(from: entry.date))\t\(entry.wordCount)w\t\(line)")
        }
    }

    private static func usageAndExit() -> Never {
        print("""
        Chirp — local dictation (hold fn to talk, release to paste)

        Usage:
          Chirp                      run as menu bar app
          Chirp --transcribe <file>  transcribe an audio file
                                      [--locale en-US]
                                      [--bundle-id com.apple.dt.Xcode] to test as
                                      if dictating into that app (developer
                                      vocabulary on/off resolves the same way);
                                      omitted, resolves like no app is focused
          Chirp --format "<text>"    run the text formatter on a string
                                      [--bundle-id ...] same as --transcribe
          Chirp --edit "<text>"      run the real rewrite pass on a string,
                                      same as a live dictation would use
                                      [--bundle-id ...] resolves style the
                                      same way a real dictation into that
                                      app would (default: global default
                                      style); a Raw-style app prints the
                                      text unchanged, same as live
          Chirp --history            print dictation history (last 30 days,
                                      500 entries max — that's all Chirp
                                      keeps on disk)
          Chirp --history-search "<term>"   search history, same window
          Chirp --history-export <path>     write history as JSON to a file
          Chirp --selftest           run formatter self-tests
        """)
        exit(0)
    }
}
