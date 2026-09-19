import Foundation

/// One person whose voice Chirp can now recognize across *different*
/// meetings — created the moment the user renames a diarized speaker, from
/// that segment's own `DiarizerManager` embedding. Matches how Wispr
/// Flow's own Notetaker describes this ("naming sticks for future
/// meetings with the same person"): a local voice-print keyed to a name
/// the user gave it, nothing looked up or inferred from outside Chirp.
struct KnownSpeaker: Codable, Identifiable {
    var id: String { name.lowercased() }
    var name: String
    var embedding: [Float]
}

final class KnownSpeakerStore {
    private(set) var speakers: [KnownSpeaker] = []
    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("known_speakers.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([KnownSpeaker].self, from: data) {
            speakers = saved
        }
    }

    /// Enrolls or refreshes one person's voice-print. Case-insensitive on
    /// name so renaming "bob" then later "Bob" updates the same entry
    /// rather than creating a near-duplicate.
    func upsert(name: String, embedding: [Float]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let index = speakers.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            speakers[index].embedding = embedding
        } else {
            speakers.append(KnownSpeaker(name: trimmed, embedding: embedding))
        }
        save()
    }

    func forget(name: String) {
        speakers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(speakers) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
