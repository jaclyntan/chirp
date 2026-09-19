import Foundation

/// One day's tally of automatic corrections — feeds Insights' "Fixes made
/// by Chirp" card. Deliberately just counts, not the corrections
/// themselves: unlike `HistoryEntry` or `LearnedCorrection`, there's no
/// reason to keep the actual before/after text around once the day's total
/// is recorded.
struct DailyPipelineStats: Codable {
    var date: Date
    var harperFixes: Int = 0
    var dictionaryFixes: Int = 0
    var snippetExpansions: Int = 0
}

/// Persists daily counts of what each pipeline stage actually changed.
/// Populated from `AppDelegate.stopAndTranscribe()`'s own before/after
/// snapshots of `formatted` at each stage — this store only tallies what
/// it's handed, it doesn't call into Harper/LearnedStore/SnippetStore
/// itself.
final class PipelineStatsStore {
    private(set) var days: [DailyPipelineStats] = []
    /// Generous compared to `HistoryStore`'s 30-day cap: a day's entry here
    /// is three integers, not full transcript text, so keeping roughly two
    /// quarters of history costs nothing and lets Insights show a real
    /// monthly (or longer) total without the underlying data having
    /// already aged out.
    private let retentionDays = 180
    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("pipeline_stats.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([DailyPipelineStats].self, from: data) {
            days = saved
            prune()
            save()
        }
    }

    /// Adds today's counts, merging into an existing entry for today if
    /// `stopAndTranscribe` already recorded something earlier today. A
    /// no-op call (everything zero — the common case, most dictations
    /// trigger no corrections at all) never touches disk.
    func record(harperFixes: Int, dictionaryFixes: Int, snippetExpansions: Int) {
        guard harperFixes > 0 || dictionaryFixes > 0 || snippetExpansions > 0 else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if let index = days.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: today) }) {
            days[index].harperFixes += harperFixes
            days[index].dictionaryFixes += dictionaryFixes
            days[index].snippetExpansions += snippetExpansions
        } else {
            days.append(DailyPipelineStats(
                date: today, harperFixes: harperFixes, dictionaryFixes: dictionaryFixes,
                snippetExpansions: snippetExpansions))
        }
        prune()
        save()
    }

    /// Summed counts for the last `days` days, inclusive of today — what
    /// Insights' "Fixes made by Chirp" card actually reads.
    func totals(lastDays days: Int) -> DailyPipelineStats {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        else { return DailyPipelineStats(date: Date()) }
        let inRange = self.days.filter { $0.date >= Calendar.current.startOfDay(for: cutoff) }
        return DailyPipelineStats(
            date: Date(),
            harperFixes: inRange.reduce(0) { $0 + $1.harperFixes },
            dictionaryFixes: inRange.reduce(0) { $0 + $1.dictionaryFixes },
            snippetExpansions: inRange.reduce(0) { $0 + $1.snippetExpansions })
    }

    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
        else { return }
        days.removeAll { $0.date < cutoff }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(days) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Pure helpers for turning a pipeline stage's before/after text into a
/// rough count, kept independent of any one store or call site.
enum PipelineDiff {
    /// A rough count of how many word *positions* differ between two
    /// strings — not a true edit distance, just "how many words did this
    /// stage touch." That's the right granularity for a stats tally
    /// (Harper and the Dictionary both substitute word-for-word almost
    /// always) and, critically, this only ever *reads* the before/after
    /// text a call site already has — it doesn't change what either stage
    /// does or re-run any correction logic itself.
    static func wordChangeCount(from before: String, to after: String) -> Int {
        guard before != after else { return 0 }
        let beforeWords = before.split(whereSeparator: { $0.isWhitespace })
        let afterWords = after.split(whereSeparator: { $0.isWhitespace })
        let overlap = min(beforeWords.count, afterWords.count)
        var changed = abs(beforeWords.count - afterWords.count)
        for i in 0..<overlap where beforeWords[i] != afterWords[i] { changed += 1 }
        return changed
    }

    /// How many of `snippets`' own trigger phrases actually appear in
    /// `text` — checked against the text *before* `SnippetStore.expand`
    /// runs, using the exact same whole-word, case-insensitive pattern
    /// `expand` itself matches with, so this counts real expansions, not
    /// coincidental substring hits.
    static func snippetMatchCount(in text: String, snippets: [Snippet]) -> Int {
        var count = 0
        for snippet in snippets {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespaces)
            guard !trigger.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: trigger)
            guard let regex = try? NSRegularExpression(pattern: "(?i)\\b\(escaped)\\b") else { continue }
            count += regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        return count
    }
}
