import Foundation

/// Turns a meeting's transcript into a short summary plus decisions and
/// action items — the same on-device `RewriteEngine` Ask Chirp and Voice
/// Profile already use, not a new AI integration of its own.
enum MeetingSummarizer {
    struct Result {
        let summary: String
        let decisions: [String]
        let actionItems: [String]
    }

    static func summarize(_ note: MeetingNote, engine: RewriteEngine) async -> Result? {
        guard engine.isAvailable, !note.segments.isEmpty else { return nil }
        let transcript = String(note.transcriptText.prefix(6000))
        guard !transcript.isEmpty else { return nil }

        let instructions = """
        You will receive a meeting transcript with speaker labels. Write a \
        short summary (2-4 sentences), then list any clear decisions made, \
        then list any clear action items (who/what, if stated). If there \
        are none of either, say so plainly rather than inventing any. \
        Answer in exactly this format, nothing else:
        Summary: <2-4 sentences>
        Decisions: <one per line, each prefixed with "- ", or "None">
        Actions: <one per line, each prefixed with "- ", or "None">
        """
        guard let reply = try? await engine.rewrite(transcript, instructions: instructions)
        else { return nil }
        return parse(reply)
    }

    private static func parse(_ reply: String) -> Result {
        var summary = ""
        var decisions: [String] = []
        var actionItems: [String] = []
        // 0 = summary, 1 = decisions, 2 = actions — a reply line with no
        // recognized prefix belongs to whichever section came last.
        var section = 0

        for rawLine in reply.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            if lowered.hasPrefix("summary:") {
                summary = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                section = 0
            } else if lowered.hasPrefix("decisions:") {
                section = 1
                appendIfReal(String(line.dropFirst(10)), to: &decisions)
            } else if lowered.hasPrefix("actions:") {
                section = 2
                appendIfReal(String(line.dropFirst(8)), to: &actionItems)
            } else if !line.isEmpty {
                switch section {
                case 1: appendIfReal(line, to: &decisions)
                case 2: appendIfReal(line, to: &actionItems)
                default: break
                }
            }
        }
        return Result(summary: summary, decisions: decisions, actionItems: actionItems)
    }

    private static func appendIfReal(_ raw: String, to list: inout [String]) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("- ") { line.removeFirst(2) } else if line.hasPrefix("-") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, line.lowercased() != "none" else { return }
        list.append(line)
    }
}
