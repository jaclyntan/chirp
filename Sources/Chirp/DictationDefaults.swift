import Foundation

/// Per-app dictation defaults that apply automatically, independent of
/// any user configuration — what's left after App Profiles (the feature
/// that let a user set explicit per-app overrides on top of these) was
/// removed. Was `AppProfileStore`, holding both the user's own override
/// storage and these fallbacks; with the overrides gone, "Store" and
/// "Profile" were both the wrong name for what's left.
enum DictationDefaults {
    /// The tone to use for an app: Raw if this is a recognized literal
    /// terminal (`DeveloperVocabulary.terminalBundleIDs` — Terminal,
    /// iTerm, Warp, ... where Claude Code/Codex CLI actually run), else
    /// the global default. Scoped to terminals specifically, not the
    /// broader developer-context list `developerVocabularyEnabled` uses:
    /// a terminal has no use for capitalized, LLM-polished prose
    /// (dictated text there is shell syntax, where that rewrite is
    /// actively risky, not just slow), but a code editor or an AI chat
    /// app is often prose that benefits from the same cleanup any other
    /// app gets — auto-silencing it there would be a regression, not a fix.
    static func style(forBundleID bundleID: String?) -> WritingStyle {
        if let bundleID, DeveloperVocabulary.terminalBundleIDs.contains(bundleID) {
            return .raw
        }
        return StyleSettings.defaultStyle
    }

    /// Whether Chirp's built-in developer vocabulary (terms + corrections)
    /// should bias recognition for this app: whether the bundle ID is a
    /// recognized developer context. A `nil` bundle ID (no resolvable
    /// frontmost app) isn't in the built-in list, so it resolves to
    /// `false` — the same safe-by-default the built-in list itself follows.
    static func developerVocabularyEnabled(forBundleID bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return DeveloperVocabulary.developerContextBundleIDs.contains(bundleID)
    }
}
