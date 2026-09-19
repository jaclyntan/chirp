import Foundation

/// A value decoded from a file, kept in memory and re-read only when the
/// file actually changes on disk.
///
/// The dictation path used to re-read and re-decode the same three JSON
/// files several times per dictation — `SnippetStore.load()` alone ran
/// three times (twice from `AppDelegate`, once inside `expand`), and
/// `LearnedStore.load()` ran from both `apply` and `biasTerms`, which
/// itself ran twice. None of that changes between calls, but all of it
/// sat between the user releasing the key and the text appearing.
///
/// Validated by the file's modification date *and* size rather than a
/// timestamp alone: the stores are not the only writer — the Dictionary
/// and Snippets pages write their files directly — so a cache that
/// assumed it owned the file would serve stale data the moment someone
/// edited an entry. A `stat` is orders of magnitude cheaper than a read
/// plus a JSON decode, so checking every time costs nothing worth
/// measuring.
///
/// `NSLock` rather than an actor: every caller is synchronous and some
/// run off the main actor, so an actor would force the whole chain async
/// for what is a dictionary lookup in the common case.
final class FileCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp: Stamp?
    private var value: Value?

    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    /// Returns the cached value if the file is unchanged, otherwise calls
    /// `load` and caches the result.
    func value(for url: URL, load: () -> Value) -> Value {
        let current = Self.stamp(of: url)
        lock.lock()
        if let value, stamp == current {
            lock.unlock()
            return value
        }
        lock.unlock()

        // Deliberately outside the lock: `load` touches the filesystem and
        // decodes JSON, and holding a lock across that would serialise
        // every caller behind the slowest one. A racing caller may decode
        // the same file twice, which is harmless — both produce the same
        // value, and the last write wins.
        let fresh = load()
        lock.lock()
        self.value = fresh
        self.stamp = current
        lock.unlock()
        return fresh
    }

    /// Drops the cached value. Call after writing the file, so the next
    /// read reflects the write immediately rather than waiting for the
    /// filesystem's own timestamp resolution to catch up.
    func invalidate() {
        lock.lock()
        value = nil
        stamp = nil
        lock.unlock()
    }

    private static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date,
            let size = attributes[.size] as? Int
        else { return nil }
        return Stamp(modified: modified, size: size)
    }
}

/// Compiled `NSRegularExpression`s, keyed by their source phrase.
///
/// Compiling a pattern costs far more than running it, and the phrases
/// here (snippet triggers) change rarely while being matched on every
/// dictation. Unbounded on purpose: the key space is the user's own
/// snippet triggers, which is tens of entries, not something that grows
/// with use.
final class RegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]

    /// Case-insensitive whole-phrase match for `phrase`.
    func regex(for phrase: String) -> NSRegularExpression? {
        lock.lock()
        if let hit = cache[phrase] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
        guard let built = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive])
        else { return nil }

        lock.lock()
        cache[phrase] = built
        lock.unlock()
        return built
    }
}
