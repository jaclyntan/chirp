//! Minimal C FFI around harper-core, built for Chirp.
//!
//! Exposes exactly two functions: `harper_fix_text` lints the input and
//! applies every suggested fix, returning corrected text; `harper_free_string`
//! frees what it returns. No other surface — Chirp only needs "fix this text",
//! not the full lint/suggestion API.

use harper_core::linting::{LintGroup, Linter};
use harper_core::parsers::PlainEnglish;
use harper_core::spell::{Dictionary, FstDictionary, MergedDictionary, MutableDictionary};
use harper_core::{DictWordMetadata, Dialect, Document};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Arc;

/// Lints `input` and returns a newly-allocated corrected copy.
///
/// `vocabulary` is a newline-separated list of words/phrases Harper should
/// treat as known, correctly-spelled English (may be null or empty). Without
/// it, any word Harper's own curated dictionary doesn't contain — a brand
/// name like "Supabase" — reads as a spelling error and gets "corrected" to
/// the nearest word Harper *does* know, silently undoing whatever upstream
/// step (ASR, vocabulary boosting, a learned correction) already got right.
/// Measured before this existed: "Supabase" → "Separate", every time,
/// regardless of how it was spelled going in. Multi-word entries are split
/// on whitespace so each word is registered individually — Harper tokenizes
/// running text word by word, so a dictionary entry for the phrase alone
/// would never match anything.
///
/// The caller owns the result and must pass it to `harper_free_string` when
/// done. Never fails outward: a null/invalid/non-UTF8 input produces an
/// empty string rather than a null pointer, so Swift callers don't need a
/// separate null-check path on top of the usual empty-string check.
#[no_mangle]
pub extern "C" fn harper_fix_text(
    input: *const c_char,
    vocabulary: *const c_char,
) -> *mut c_char {
    let text = if input.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(input) }.to_str().unwrap_or("")
    };
    let vocabulary_text = if vocabulary.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(vocabulary) }.to_str().unwrap_or("")
    };

    let fixed = fix_text(text, vocabulary_text);
    CString::new(fixed)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

/// Frees a string returned by `harper_fix_text`. Safe to call with null.
#[no_mangle]
pub extern "C" fn harper_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(s));
    }
}

/// Reports whether `word` is a real, ordinary English word in Harper's own
/// curated dictionary (case-insensitive) — as opposed to a proper noun,
/// brand name, or acronym, none of which this dictionary carries. Null,
/// non-UTF8, or empty input returns false.
///
/// Built for `LearnedStore.isUsefulMapping` on the Swift side: a personal
/// pronunciation correction whose *entire* trigger is one ordinary word
/// ("team", "there", "whisper") is far more likely to be a diff-algorithm
/// artifact — an edit made elsewhere in a correction round-trip,
/// misattributed to a short word it happened to land near — than a genuine
/// mishearing, and unlike Harper's own lints it runs with no confidence
/// gate at all once learned. A proper noun like "Giannis" or "Versal"
/// won't be in this dictionary and so isn't blocked; a real dictionary
/// word like "team" or "whisper" will be.
#[no_mangle]
pub extern "C" fn harper_is_known_word(word: *const c_char) -> bool {
    if word.is_null() {
        return false;
    }
    let Ok(word) = unsafe { CStr::from_ptr(word) }.to_str() else {
        return false;
    };
    if word.is_empty() {
        return false;
    }
    FstDictionary::curated().contains_word_str(word)
}

fn fix_text(text: &str, vocabulary_text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }

    let parser = PlainEnglish;

    // Harper's curated dictionary, plus Chirp's own vocabulary layered on
    // top — a `MergedDictionary` checks each child in order and treats a
    // word as known if *any* of them contain it, so this only ever adds
    // words Harper will leave alone; it can't remove or override Harper's
    // own.
    let mut user_dict = MutableDictionary::new();
    for term in vocabulary_text.lines() {
        for word in term.split_whitespace() {
            let cleaned: String = word
                .chars()
                .filter(|c| c.is_alphanumeric() || *c == '\'' || *c == '-')
                .collect();
            if !cleaned.is_empty() {
                user_dict.append_word_str(&cleaned, DictWordMetadata::default());
            }
        }
    }

    let mut dict = MergedDictionary::new();
    dict.add_dictionary(FstDictionary::curated());
    dict.add_dictionary(Arc::new(user_dict));
    let dict = Arc::new(dict);

    let document = Document::new(text, &parser, &*dict);
    let mut linter = LintGroup::new_curated(dict, Dialect::American);
    let mut lints = linter.lint(&document);

    // Apply fixes in reverse span order: applying an earlier edit first
    // would shift the character offsets every later lint's span is
    // expressed in, corrupting all subsequent splices.
    lints.sort_by(|a, b| b.span.start.cmp(&a.span.start));

    let mut chars: Vec<char> = text.chars().collect();
    for lint in &lints {
        if let Some(suggestion) = lint.suggestions.first() {
            suggestion.apply(lint.span, &mut chars);
        }
    }

    chars.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leaves_correct_text_alone() {
        let input = "This is a correct sentence.";
        assert_eq!(fix_text(input, ""), input);
    }

    #[test]
    fn fixes_repeated_word() {
        let fixed = fix_text("I went to the the store.", "");
        assert!(!fixed.contains("the the"), "got: {fixed}");
    }

    #[test]
    fn empty_input_is_empty_output() {
        assert_eq!(fix_text("", ""), "");
    }

    #[test]
    fn vocabulary_word_is_left_alone() {
        let fixed = fix_text(
            "I set up the database using Supabase yesterday.",
            "Supabase",
        );
        assert!(fixed.contains("Supabase"), "got: {fixed}");
    }

    #[test]
    fn without_vocabulary_hint_the_same_word_gets_mangled() {
        // Documents the exact failure the vocabulary parameter fixes: absent
        // the hint, Harper doesn't leave "Supabase" alone.
        let fixed = fix_text("I set up the database using Supabase yesterday.", "");
        assert!(
            !fixed.contains("Supabase"),
            "expected the unfixed baseline to mangle Supabase, got: {fixed}"
        );
    }

    #[test]
    fn multi_word_vocabulary_entry_protects_each_word() {
        let fixed = fix_text("I opened Claude Code this morning.", "Claude Code");
        assert!(fixed.contains("Claude Code"), "got: {fixed}");
    }

    #[test]
    fn ordinary_words_are_known() {
        for word in ["team", "there", "whisper", "weight", "tail", "wiser"] {
            assert!(
                FstDictionary::curated().contains_word_str(word),
                "expected {word:?} to be a known word"
            );
        }
    }

    #[test]
    fn proper_nouns_are_not_known() {
        for word in ["Giannis", "Versal", "Supabase", "Faipel"] {
            assert!(
                !FstDictionary::curated().contains_word_str(word),
                "expected {word:?} to be unknown"
            );
        }
    }
}
