import harper

/// A fast, local, deterministic grammar pass — [Harper](https://github.com/Automattic/harper),
/// vendored as a small Rust static library (`Vendor/harper-ffi`, built into
/// `Vendor/harper.xcframework`). Runs *in addition to* the Apple Intelligence
/// edit pass in `RewriteEngine`, not instead of it: the LLM handles filler
/// removal and restructuring rambling speech into sentences, which Harper's
/// rule-based linting doesn't do; Harper catches grammar (agreement,
/// punctuation, repeated words) at millisecond speed, as a final polish the
/// LLM's own occasional misses don't get a chance to slip through.
///
/// Pure, synchronous, local Rust — no model to download, no warm-up, no
/// network. Unlike every other engine in this app, there's nothing to be
/// "ready" for.
enum HarperChecker {
    /// Lints `text` and applies every fix Harper is confident enough to
    /// suggest. Empty input returns empty output; never throws — a
    /// malformed C string round-trip degrades to returning `text`
    /// unchanged rather than losing the dictation.
    ///
    /// `vocabulary` is Chirp's own known words — pass
    /// `LearnedStore.biasTerms()`, the same list fed to ASR vocabulary
    /// biasing — so Harper's English dictionary doesn't flag them as
    /// misspelled and "correct" them into a real word it does recognize.
    /// Confirmed this was happening, not hypothetical: without this,
    /// Harper turned every correctly-transcribed "Supabase" into
    /// "Separate", deterministically, regardless of how upstream
    /// recognition spelled it — silently undoing Parakeet's own CTC
    /// vocabulary-boosting fix for the same word. Defaults to empty for
    /// callers (tests, `--harper-fix`) that don't have a term list handy.
    static func fix(_ text: String, vocabulary: [String] = []) -> String {
        guard !text.isEmpty else { return text }
        let vocabularyText = vocabulary.joined(separator: "\n")
        guard let resultPtr = text.withCString({ textPtr in
            vocabularyText.withCString { vocabPtr in
                harper_fix_text(textPtr, vocabPtr)
            }
        }) else {
            return text
        }
        defer { harper_free_string(resultPtr) }
        let fixed = String(cString: resultPtr)
        return fixed.isEmpty ? text : fixed
    }

    /// True if `word` is a real, ordinary English word in Harper's own
    /// dictionary — false for proper nouns, brand names, and acronyms.
    ///
    /// Used by `LearnedStore.isUsefulMapping` to refuse learning a
    /// pronunciation correction whose *entire* trigger is one ordinary
    /// word: auditing one real user's accumulated corrections found
    /// `team → theme`, `there → they`, `whisper → Wispr`, and others,
    /// apparently learned by mistake — the underlying diff extraction
    /// misattributing an edit made elsewhere in a correction round-trip to
    /// a short common word it happened to land near. A proper noun like
    /// "Giannis" isn't in this dictionary, so genuine name/brand
    /// corrections are unaffected.
    static func isKnownEnglishWord(_ word: String) -> Bool {
        word.withCString { harper_is_known_word($0) }
    }
}
