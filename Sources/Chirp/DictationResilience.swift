import AppKit
import Foundation

// What keeps a dictation from being lost, or pasted somewhere it doesn't
// belong, when the Mac is too busy to transcribe it promptly.
//
// Seen in the logs on a Mac deep in swap: transcriptions that took a minute
// or more, results pasted into whatever had focus by then, and a few
// that never came back at all — the recognizer simply never returned, and
// the audio file was deleted with the task that was waiting on it.

// MARK: - Deadline

enum DeadlineError: LocalizedError {
    case timedOut(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds): "no result after \(Int(seconds)) s"
        }
    }
}

@MainActor
enum Deadline {
    /// Runs `operation`, but gives up waiting after `seconds`.
    ///
    /// Not a task group: a group waits for every child before it returns,
    /// so a recognizer that ignores cancellation would hold the caller
    /// exactly as long as it does today. Here the caller is released on
    /// time either way; the operation is cancelled and its late result,
    /// if one ever arrives, is dropped.
    static func run<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let state = DeadlineState()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task { @MainActor in
                let result: Result<T, Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                guard !state.finished else { return }
                state.finished = true
                state.timer?.cancel()
                continuation.resume(with: result)
            }
            state.timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, !state.finished else { return }
                state.finished = true
                work.cancel()
                continuation.resume(throwing: DeadlineError.timedOut(seconds: seconds))
            }
        }
    }
}

@MainActor
private final class DeadlineState {
    var finished = false
    var timer: Task<Void, Never>?
}

// MARK: - When to paste

enum PastePolicy {
    enum Decision: Equatable {
        case paste
        /// Ready too long after the recording stopped to assume the cursor
        /// is still where the user left it.
        case tooLate(seconds: Int)
        /// The user is in a different app than when they stopped talking.
        case appChanged
    }

    /// How long recognition may take before Chirp stops waiting. Normal is
    /// roughly a quarter of the audio's length (2.8 s for an 11 s clip),
    /// so this leaves several times that for a busy Mac.
    static func transcriptionLimit(forAudioSeconds audio: TimeInterval) -> Double {
        20 + 2 * max(0, audio)
    }

    /// How late a result can arrive and still be pasted.
    static func maxPasteDelay(forAudioSeconds audio: TimeInterval) -> Double {
        min(30, 10 + 0.5 * max(0, audio))
    }

    /// Compares the app in front when the recording *stopped* — not when it
    /// started, since hands-free dictation can begin in one app and be
    /// aimed at another — with the app in front now.
    static func decide(
        secondsSinceStop: Double,
        audioSeconds: TimeInterval,
        frontmostAtStop: String?,
        frontmostNow: String?,
        ownBundleID: String?
    ) -> Decision {
        // Dictating into Chirp's own window is exempt: Chirp can lose
        // active status during processing without the user going anywhere,
        // and the paste path reactivates it before posting ⌘V.
        if let frontmostAtStop, frontmostAtStop != ownBundleID, frontmostNow != frontmostAtStop {
            return .appChanged
        }
        if secondsSinceStop > maxPasteDelay(forAudioSeconds: audioSeconds) {
            return .tooLate(seconds: Int(secondsSinceStop.rounded()))
        }
        return .paste
    }
}

// MARK: - Recordings kept for a retry

/// Audio from dictations that failed or timed out, kept so they can be
/// transcribed again — including after a relaunch, which is when the old
/// behaviour lost them for good.
struct PendingRecordingStore {
    struct Item: Codable, Equatable {
        let id: String
        let createdAt: Date
        let duration: TimeInterval?
        let targetBundleID: String?
        var attempts: Int
    }

    static let maxAttempts = 3
    static let maxAge: TimeInterval = 7 * 24 * 3600

    let directory: URL

    init(directory: URL = AppPaths.supportDirectory.appendingPathComponent("pending", isDirectory: true)) {
        self.directory = directory
    }

    func audioURL(for id: String) -> URL { directory.appendingPathComponent("\(id).caf") }
    private func metadataURL(for id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    /// Moves `audio` into the store. Returns the saved item, or nil if the
    /// move failed (in which case the caller still owns the file).
    func keep(audio: URL, duration: TimeInterval?, targetBundleID: String?) -> Item? {
        let item = Item(id: UUID().uuidString, createdAt: Date(), duration: duration,
                        targetBundleID: targetBundleID, attempts: 1)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: audio, to: audioURL(for: item.id))
            try write(item)
            return item
        } catch {
            try? FileManager.default.removeItem(at: audioURL(for: item.id))
            return nil
        }
    }

    func write(_ item: Item) throws {
        try JSONEncoder().encode(item).write(to: metadataURL(for: item.id), options: .atomic)
    }

    /// Oldest first. Skips (and cleans up) half-written or orphaned pairs.
    func items() -> [Item] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [Item] = []
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard let data = try? Data(contentsOf: metadataURL(for: id)),
                  let item = try? JSONDecoder().decode(Item.self, from: data),
                  FileManager.default.fileExists(atPath: audioURL(for: id).path) else {
                remove(id: id)
                continue
            }
            result.append(item)
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(id: String) {
        try? FileManager.default.removeItem(at: audioURL(for: id))
        try? FileManager.default.removeItem(at: metadataURL(for: id))
    }

    /// Drops recordings too old to be worth transcribing.
    func pruneExpired(now: Date = Date()) {
        for item in items() where now.timeIntervalSince(item.createdAt) > Self.maxAge {
            remove(id: item.id)
        }
    }
}

// MARK: - Main-thread stall watchdog

/// Logs when the main thread stops responding. Those stalls are what make
/// the HUD look "on" while nothing happens; before this they showed up only
/// indirectly, as odd timestamps.
///
/// A stall still in progress after `sampleAfter` seconds also gets a
/// system snapshot and a `sample` of every thread (see `Diagnostics`), so
/// a freeze leaves behind what it was stuck in, not just that it happened.
///
/// Checks every 0.5 s while a dictation is in flight, and every 5 s with
/// generous leeway otherwise. The idle rate is the one exception to
/// `RuntimeActivity`'s no-polling rule, kept because a freeze while idle
/// (the "stuck until I restart" case) is otherwise invisible.
final class MainThreadStallWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.chirp.stall-watchdog", qos: .utility)
    private let threshold: Double
    private let sampleAfter: Double
    // All confined to `queue`.
    private var timer: DispatchSourceTimer?
    private var pingSentAt: DispatchTime?
    private var sampledThisStall = false
    private var active = false

    init(threshold: Double = 1.0, sampleAfter: Double = 3.0) {
        self.threshold = threshold
        self.sampleAfter = sampleAfter
    }

    /// Starts watching at the idle rate.
    func start() {
        queue.async { self.startTimer() }
    }

    /// Fast checks while recording or transcribing, slow ones otherwise.
    func setActive(_ value: Bool) {
        queue.async {
            guard self.active != value else { return }
            self.active = value
            self.reschedule()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        reschedule()
        source.resume()
    }

    private func reschedule() {
        let interval: DispatchTimeInterval = active ? .milliseconds(500) : .seconds(5)
        let leeway: DispatchTimeInterval = active ? .milliseconds(100) : .seconds(2)
        timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
    }

    private static func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    private func tick() {
        if let sent = pingSentAt {
            let waited = Self.seconds(since: sent)
            if waited >= sampleAfter, !sampledThisStall {
                sampledThisStall = true
                dictationLog.error(
                    "main thread: unresponsive for \(waited, format: .fixed(precision: 1)) s and counting; sampling threads")
                Diagnostics.shared.snapshot("stall")
                Diagnostics.shared.captureThreadSample(reason: "main thread unresponsive")
            }
            return
        }
        let sent = DispatchTime.now()
        pingSentAt = sent
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let waited = Self.seconds(since: sent)
            if waited >= self.threshold {
                dictationLog.notice("main thread: stalled \(waited, format: .fixed(precision: 1)) s")
            }
            self.queue.async {
                self.pingSentAt = nil
                self.sampledThisStall = false
            }
        }
    }
}

// MARK: - Self-test

enum DictationResilience {
    @MainActor
    static func runSelfTest() async -> Bool {
        var passed = true
        func check(_ value: Bool, _ label: String) {
            if !value { passed = false }
            print("\(value ? "PASS" : "FAIL"): \(label)")
        }

        let fast = try? await Deadline.run(seconds: 1) { "done" }
        check(fast == "done", "deadline passes a prompt result through")

        // An operation that ignores cancellation and runs far past its
        // deadline — the shape of a stuck recognizer.
        let started = Date()
        var timedOut = false
        do {
            _ = try await Deadline.run(seconds: 0.05) { () -> String in
                while Date().timeIntervalSince(started) < 0.6 {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return "late"
            }
        } catch DeadlineError.timedOut {
            timedOut = true
        } catch {}
        check(timedOut && Date().timeIntervalSince(started) < 0.4,
              "deadline releases the caller from an operation that ignores cancellation")

        enum Expected: Error { case boom }
        var rethrown = false
        do { _ = try await Deadline.run(seconds: 1) { () -> Int in throw Expected.boom } }
        catch Expected.boom { rethrown = true } catch {}
        check(rethrown, "deadline passes the operation's own error through")

        check(PastePolicy.decide(secondsSinceStop: 1, audioSeconds: 10, frontmostAtStop: "a",
                                 frontmostNow: "a", ownBundleID: "chirp") == .paste,
              "a prompt result in the same app is pasted")
        check(PastePolicy.decide(secondsSinceStop: 63, audioSeconds: 21, frontmostAtStop: "a",
                                 frontmostNow: "a", ownBundleID: "chirp") == .tooLate(seconds: 63),
              "a result a minute late is not pasted")
        check(PastePolicy.decide(secondsSinceStop: 2, audioSeconds: 5, frontmostAtStop: "a",
                                 frontmostNow: "b", ownBundleID: "chirp") == .appChanged,
              "a result is not pasted into a different app")
        check(PastePolicy.decide(secondsSinceStop: 2, audioSeconds: 5, frontmostAtStop: "chirp",
                                 frontmostNow: "a", ownBundleID: "chirp") == .paste,
              "dictating into Chirp itself survives Chirp losing focus")
        check(PastePolicy.maxPasteDelay(forAudioSeconds: 600) == 30, "paste delay is capped")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chirp-pending-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingRecordingStore(directory: directory)
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-test-\(UUID()).caf")
        FileManager.default.createFile(atPath: audio.path, contents: Data([1, 2, 3]))
        let kept = store.keep(audio: audio, duration: 4, targetBundleID: "a")
        check(kept != nil && !FileManager.default.fileExists(atPath: audio.path)
              && store.items() == [kept!], "a failed recording is moved into the pending store")
        if var item = kept {
            item.attempts += 1
            try? store.write(item)
            check(store.items().first?.attempts == 2, "retry attempts persist")
            store.pruneExpired(now: Date().addingTimeInterval(PendingRecordingStore.maxAge + 60))
            check(store.items().isEmpty, "week-old pending recordings are pruned")
        }
        return passed
    }
}
