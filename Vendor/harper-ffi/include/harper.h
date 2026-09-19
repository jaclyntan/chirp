#ifndef HARPER_FFI_H
#define HARPER_FFI_H

#include <stdbool.h>

/// Lints the given UTF-8 text and returns a newly-allocated corrected copy.
/// `vocabulary` is a newline-separated list of words/phrases to treat as
/// known, correctly-spelled English (NULL or empty is fine) — without it,
/// Harper "corrects" any word its own dictionary doesn't contain to the
/// nearest one it does. Never returns NULL: null, non-UTF8, or unparseable
/// input yields an empty string. The caller owns the result and must free
/// it with harper_free_string.
char *harper_fix_text(const char *input, const char *vocabulary);

/// Frees a string returned by harper_fix_text. Safe to call with NULL.
void harper_free_string(char *s);

/// Reports whether `word` is a real, ordinary English word in Harper's own
/// dictionary (case-insensitive) — false for proper nouns, brand names,
/// and acronyms, none of which this dictionary carries. Null, non-UTF8, or
/// empty input returns false.
bool harper_is_known_word(const char *word);

#endif /* HARPER_FFI_H */
