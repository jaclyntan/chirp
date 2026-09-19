import Foundation

/// Whisper-family models (WhisperKit, whisper.cpp) hallucinate a small,
/// well-documented set of sign-off phrases when fed near-silent audio —
/// trained partly on YouTube transcripts, where silence is very often
/// followed by one of these. `no_speech_prob`, the model's own per-segment
/// confidence signal, was tried as a defense first and measured
/// unreliable: fed genuine near-silence, whisper.cpp reported it at
/// ~0.00002 (i.e. "almost certainly speech") for a "Thank you."
/// hallucination — the model is confident in its own invented completion,
/// not uncertain about it, so a probability threshold never fires on the
/// case that actually matters.
///
/// A phrase match is the blunter tool, but it's what actually works: the
/// hallucinated phrases are a small, recurring, specific set, so matching
/// the *entire* output against them — never a substring of a longer real
/// dictation — catches the failure directly rather than trying to predict
/// it from a confidence score the model doesn't produce.
enum HallucinationFilter {
    /// Deliberately short and specific to documented Whisper artifacts —
    /// not generic short replies ("okay", "yes", "hello") a real dictation
    /// could legitimately consist of entirely.
    private static let knownPhrases: Set<String> = [
        "thank you", "thanks", "thank you very much", "thank you so much",
        "thank you for watching", "thanks for watching",
        "please subscribe", "subscribe", "goodbye", "bye", "you",
    ]

    /// Whether `text` — the *entire* recognized+formatted dictation, not a
    /// fragment of it — is one of the known hallucination phrases. A
    /// genuine dictation that happens to contain "thank you" mid-sentence
    /// is unaffected; only a dictation that amounts to nothing but the
    /// phrase itself is flagged.
    static func isLikelyHallucination(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))
        guard !normalized.isEmpty else { return false }
        return knownPhrases.contains(normalized)
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        check(isLikelyHallucination("Thank you."), "\"Thank you.\" matches")
        check(isLikelyHallucination("thank you"), "case/punctuation-insensitive match")
        check(isLikelyHallucination(" Thanks for watching! "),
              "surrounding whitespace and punctuation ignored")
        check(isLikelyHallucination("Bye."), "a second known phrase also matches")
        check(!isLikelyHallucination("Thank you for the detailed report on Q3 revenue."),
              "a real sentence containing the phrase isn't flagged")
        check(!isLikelyHallucination("Remember to buy milk and eggs."),
              "an unrelated sentence isn't flagged")
        check(!isLikelyHallucination("Okay, sounds good."),
              "a generic short reply that isn't a documented artifact isn't flagged")
        check(!isLikelyHallucination(""), "empty text isn't flagged")
        check(!isLikelyHallucination("   "), "whitespace-only text isn't flagged")

        return passed
    }
}
