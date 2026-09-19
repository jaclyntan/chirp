import Foundation

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What you say during dictation.
    var trigger: String
    /// What gets inserted instead (exact casing preserved).
    var expansion: String
    /// How many times this snippet has actually expanded into a real
    /// dictation — incremented by `SnippetStore.expand(in:)`, shown on
    /// each row so a snippet's own real payoff (or lack of one) is
    /// visible, not just guessed at.
    var useCount: Int = 0

    init(id: UUID = UUID(), trigger: String, expansion: String, useCount: Int = 0) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.useCount = useCount
    }

    private enum CodingKeys: String, CodingKey { case id, trigger, expansion, useCount }

    /// `useCount` didn't exist before this field shipped — decode it
    /// leniently (defaulting to 0) rather than with the compiler's own
    /// synthesized `Decodable`, which requires every key to be present and
    /// would otherwise fail the *whole array's* decode the moment one
    /// saved snippet predates this field, silently losing every snippet
    /// rather than just starting their counts at zero.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trigger = try container.decode(String.self, forKey: .trigger)
        expansion = try container.decode(String.self, forKey: .expansion)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
    }
}

/// Voice shortcuts: saying a trigger phrase mid-dictation inserts the saved
/// text block — like Wispr Flow's Snippets.
enum SnippetStore {
    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("snippets.json")
    }

    /// Written once on first launch (never re-added once `snippets.json`
    /// exists, even if the user deletes them all) so Snippets isn't an
    /// empty page with nothing to demonstrate the feature.
    ///
    /// Snippets are the safe place to ship presets: unlike Dictionary
    /// entries, which rewrite every transcript, one of these only ever
    /// fires when you say its trigger phrase out loud. So a preset that
    /// doesn't suit you costs nothing until you use it.
    ///
    /// Everything personal is an obvious placeholder rather than a guess
    /// — nobody's real email can be invented for them, and a snippet that
    /// silently pasted a wrong address would be worse than no snippet.
    /// The point is a working example of each *shape* a snippet takes:
    /// a fixed detail, a reusable block, a structured template.
    static let starterSnippets = [
        Snippet(
            trigger: "my email",
            expansion: "you@example.com"),
        Snippet(
            trigger: "my phone number",
            expansion: "+1 555 0100"),
        Snippet(
            trigger: "my calendar link",
            expansion: "https://cal.com/yourname"),
        Snippet(
            trigger: "standup update",
            expansion: "Yesterday: \nToday: \nBlockers: none"),
        Snippet(
            trigger: "meeting recap",
            expansion: "Thanks everyone. \n\nDecisions: \nAction items: \nNext steps: "),
        Snippet(
            trigger: "polite decline",
            expansion: "Thanks so much for thinking of me. I can't take this on right "
                + "now, but I'd love to stay in touch about it."),
    ]

    private static let cache = FileCache<[Snippet]>()

    static func load() -> [Snippet] {
        cache.value(for: fileURL) { loadUncached() }
    }

    private static func loadUncached() -> [Snippet] {
        guard let data = try? Data(contentsOf: fileURL),
              let snippets = try? JSONDecoder().decode([Snippet].self, from: data)
        else {
            guard !FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            save(starterSnippets)
            return starterSnippets
        }
        return snippets
    }

    /// Adds any starter snippet whose trigger isn't already present,
    /// leaving everything else untouched. Exists because seeding only
    /// happens when `snippets.json` has never existed — anyone who
    /// already had a snippet before the starter set shipped would
    /// otherwise never see it, and anyone who cleared the list has no way
    /// back. Returns how many were actually added.
    @discardableResult
    static func addMissingStarters() -> Int {
        var current = load()
        let existing = Set(current.map { $0.trigger.lowercased() })
        let missing = starterSnippets.filter { !existing.contains($0.trigger.lowercased()) }
        guard !missing.isEmpty else { return 0 }
        current.append(contentsOf: missing)
        save(current)
        return missing.count
    }

    static func save(_ snippets: [Snippet]) {
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: fileURL, options: .atomic)
        }
        cache.invalidate()
    }

    /// Replaces spoken trigger phrases with their expansions, and records a
    /// use against every snippet that actually matched — longest triggers
    /// win so overlapping phrases behave predictably.
    /// Compiled trigger patterns, keyed by the trigger itself. Building
    /// an `NSRegularExpression` is the expensive half of matching one,
    /// and the triggers barely ever change — without this, every
    /// dictation recompiled every snippet's pattern from scratch before
    /// discovering (as is usually the case) that none of them match.
    private static let regexCache = RegexCache()

    static func expand(in text: String) -> String {
        var result = text
        let snippets = load()
            .filter { !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }
        // Almost no dictation contains a trigger, so rule the whole set
        // out with one lowercased substring scan before touching regex
        // machinery at all.
        let haystack = text.lowercased()
        guard snippets.contains(where: {
            haystack.contains($0.trigger.trimmingCharacters(in: .whitespaces).lowercased())
        }) else { return text }

        var matchCounts: [UUID: Int] = [:]
        for snippet in snippets {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespaces)
            guard let regex = Self.regexCache.regex(for: trigger) else { continue }
            let fullRange = NSRange(result.startIndex..., in: result)
            let matches = regex.numberOfMatches(in: result, range: fullRange)
            guard matches > 0 else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: fullRange,
                withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion))
            matchCounts[snippet.id] = matches
        }
        if !matchCounts.isEmpty { recordUsage(matchCounts) }
        return result
    }

    private static func recordUsage(_ matchCounts: [UUID: Int]) {
        var all = load()
        var changed = false
        for index in all.indices {
            if let matches = matchCounts[all[index].id] {
                all[index].useCount += matches
                changed = true
            }
        }
        guard changed else { return }
        save(all)
    }
}
