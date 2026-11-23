//! Shannon entropy of a token and the alphabet-run test, the two measures
//! `Sensitivity::Entropy` takes of every candidate the masking scan finds.
//!
//! The unit of count is the String's own: a UTF-8 token is counted by
//! character and a binary one by byte, as Ruby's `each_char` read each. An
//! invalid byte inside a UTF-8 token is a character of its own, which is how
//! Ruby splits one. The arithmetic follows `Enumerable#sum` step for step
//! (first-seen order, Kahan-Babuska compensation), so the answer is the same
//! IEEE bits Ruby gave and the frozen corpus (`ext/lain/corpus/entropy.ndjson`)
//! can hold it exactly.
//!
//! The laws below are stated as properties in `cargo test`: the answer is
//! between 0 and log2 of the distinct symbols, and no order of the symbols
//! changes it (beyond rounding). `spec/lain/rust/entropy_spec.rb` holds the
//! binding to the corpus.

use std::collections::HashMap;

/// A run of consecutive byte values at least this long is a charset literal,
/// which no key generator emits.
const ALPHABET_RUN: usize = 16;

/// The first-seen order of a token's symbols and how often each occurred,
/// with the token's length in symbols. `width` says how many bytes the
/// character at the head of a slice takes; a width outside 1 through the
/// slice's length is clamped, so a miscounting encoding cannot loop or panic.
fn tally(token: &[u8], mut width: impl FnMut(&[u8]) -> usize) -> (Vec<usize>, usize) {
    let mut slot: HashMap<&[u8], usize> = HashMap::new();
    let mut counts: Vec<usize> = Vec::new();
    let mut total = 0;
    let mut rest = token;
    while !rest.is_empty() {
        let (symbol, tail) = rest.split_at(width(rest).clamp(1, rest.len()));
        let at = *slot.entry(symbol).or_insert_with(|| {
            counts.push(0);
            counts.len() - 1
        });
        counts[at] += 1;
        total += 1;
        rest = tail;
    }
    (counts, total)
}

/// Each byte is a symbol: a binary String.
#[must_use]
pub fn byte_width(_head: &[u8]) -> usize {
    1
}

/// A UTF-8 character's width, or 1 for a byte that begins none, which is how
/// Ruby splits a String with invalid bytes: each is a character of its own.
#[must_use]
pub fn utf8_width(head: &[u8]) -> usize {
    let width = match head.first() {
        Some(0x00..=0x7f) => 1,
        Some(0xc2..=0xdf) => 2,
        Some(0xe0..=0xef) => 3,
        Some(0xf0..=0xf4) => 4,
        _ => return 1,
    };
    match head.get(..width).map(std::str::from_utf8) {
        Some(Ok(_)) => width,
        _ => 1,
    }
}

/// Ruby's `Enumerable#sum` over floats: Kahan-Babuska compensated, in order.
fn compensated_sum(terms: impl Iterator<Item = f64>) -> f64 {
    let (mut sum, mut error) = (0.0_f64, 0.0_f64);
    for term in terms {
        let next = sum + term;
        error += if sum.abs() >= term.abs() {
            (sum - next) + term
        } else {
            (term - next) + sum
        };
        sum = next;
    }
    sum + error
}

/// Bits per symbol of `token`, 0 for an empty one.
#[must_use]
pub fn shannon(token: &[u8], width: impl FnMut(&[u8]) -> usize) -> f64 {
    let (counts, total) = tally(token, width);
    if total == 0 {
        // Ruby summed nothing and got the integer 0, so there is no sign to negate.
        return 0.0;
    }
    let length = total as f64;
    -compensated_sum(counts.iter().map(|count| {
        let share = *count as f64 / length;
        share * share.log2()
    }))
}

/// Whether runs of consecutive byte values, each at least [`ALPHABET_RUN`]
/// long, cover more than half of `token`.
#[must_use]
pub fn alphabet_run(token: &[u8]) -> bool {
    let mut covered = 0;
    let mut run = 0;
    let mut before: Option<u8> = None;
    for byte in token {
        run = match before {
            Some(prev) if u16::from(*byte) == u16::from(prev) + 1 => run + 1,
            _ => {
                covered += settled(run);
                1
            }
        };
        before = Some(*byte);
    }
    covered += settled(run);
    covered * 2 > token.len()
}

/// What a finished run of `length` contributes to the covered total.
fn settled(length: usize) -> usize {
    if length >= ALPHABET_RUN { length } else { 0 }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn distinct(text: &str) -> usize {
        text.chars().collect::<std::collections::HashSet<_>>().len()
    }

    #[test]
    fn the_sum_keeps_the_low_bits_a_plain_sum_drops() {
        assert_eq!(compensated_sum([1e16, 1.0, -1e16].into_iter()), 1.0);
        assert_eq!(compensated_sum([1.0, 1e16, -1e16].into_iter()), 1.0);
        assert_eq!(compensated_sum([0.5, 0.25].into_iter()), 0.75);
    }

    #[test]
    fn one_repeated_symbol_carries_no_information() {
        assert_eq!(shannon(b"aaaa", utf8_width), 0.0);
    }

    #[test]
    fn four_equally_common_symbols_carry_two_bits() {
        assert_eq!(shannon(b"abcd", utf8_width), 2.0);
    }

    #[test]
    fn the_empty_token_carries_none() {
        assert!(shannon(b"", utf8_width).is_sign_positive());
        assert_eq!(shannon(b"", byte_width), 0.0);
    }

    #[test]
    fn a_character_counts_once_as_a_character_and_per_byte_as_bytes() {
        let token = "ééé".as_bytes();
        assert_eq!(shannon(token, utf8_width), 0.0);
        assert_eq!(shannon(token, byte_width), 1.0);
    }

    #[test]
    fn an_invalid_byte_is_a_symbol_of_its_own() {
        assert_eq!(shannon(&[0xe3, 0x81], utf8_width), 1.0);
        assert_eq!(shannon(&[0xe3, 0x81, 0xe3, 0x81], utf8_width), 1.0);
    }

    #[test]
    fn a_stray_byte_is_never_a_character_whatever_its_value() {
        let mut token = vec![0xe3];
        token.extend("\u{10ff1d}".as_bytes());
        assert_eq!(shannon(&token, utf8_width), 1.0);
    }

    #[test]
    fn an_overlong_or_surrogate_lead_is_not_a_character() {
        assert_eq!(shannon(&[0xc0, 0x80], utf8_width), 1.0);
        assert_eq!(shannon(&[0xed, 0xa0, 0x80], utf8_width), 3.0_f64.log2());
    }

    #[test]
    fn sixteen_ascending_bytes_are_an_alphabet() {
        assert!(alphabet_run(b"abcdefghijklmnop"));
        assert!(!alphabet_run(b"abcdefghijklmno"));
    }

    #[test]
    fn a_run_must_cover_more_than_half_the_token() {
        assert!(alphabet_run(b"abcdefghijklmnopXXXXXXXXXXXXXXX"));
        assert!(!alphabet_run(b"abcdefghijklmnopXXXXXXXXXXXXXXXX"));
    }

    #[test]
    fn a_run_does_not_wrap_past_the_top_byte() {
        let wrapped: Vec<u8> = (246..=255).chain(0..=5).collect();
        assert!(!alphabet_run(&wrapped));
        assert!(alphabet_run(&(240..=255).collect::<Vec<u8>>()));
    }

    #[test]
    fn the_empty_token_is_no_alphabet() {
        assert!(!alphabet_run(b""));
    }

    proptest! {
        #[test]
        fn shannon_is_between_zero_and_log2_of_the_distinct_characters(text in "\\PC{1,64}") {
            let bits = shannon(text.as_bytes(), utf8_width);
            prop_assert!(bits >= 0.0);
            prop_assert!(bits <= (distinct(&text) as f64).log2() + 1e-9);
        }

        #[test]
        fn shannon_is_between_zero_and_log2_of_the_distinct_bytes(
            token in proptest::collection::vec(any::<u8>(), 1..64)
        ) {
            let bits = shannon(&token, byte_width);
            let distinct = token.iter().collect::<std::collections::HashSet<_>>().len();
            prop_assert!(bits >= 0.0);
            prop_assert!(bits <= (distinct as f64).log2() + 1e-9);
        }

        #[test]
        fn shannon_of_a_string_equals_shannon_of_any_permutation(
            text in "\\PC{1,64}",
            seed in any::<u64>(),
        ) {
            let mut chars: Vec<char> = text.chars().collect();
            let mut state = seed | 1;
            for at in (1..chars.len()).rev() {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                chars.swap(at, (state % (at as u64 + 1)) as usize);
            }
            let shuffled: String = chars.into_iter().collect();
            let (a, b) = (
                shannon(text.as_bytes(), utf8_width),
                shannon(shuffled.as_bytes(), utf8_width),
            );
            prop_assert!((a - b).abs() < 1e-9, "{a} vs {b}");
        }

        #[test]
        fn a_valid_token_is_split_into_its_characters(text in "\\PC{0,64}") {
            let mut rest = text.as_bytes();
            let mut pieces = Vec::new();
            while !rest.is_empty() {
                let (piece, tail) = rest.split_at(utf8_width(rest));
                pieces.push(std::str::from_utf8(piece).unwrap().to_string());
                rest = tail;
            }
            prop_assert_eq!(pieces, text.chars().map(String::from).collect::<Vec<_>>());
        }
    }
}

/// The magnus surface: `Lain::Ext::Entropy`.
#[cfg(not(test))]
pub mod ffi {
    use super::{alphabet_run, byte_width, shannon, utf8_width};
    use crate::read_bytes::read_bytes;
    use magnus::{
        Error, ExceptionClass, RModule, RString, Ruby, Value,
        encoding::{EncodingCapable, RbEncoding},
        function,
        prelude::*,
    };

    fn string_of(ruby: &Ruby, value: Value) -> Result<RString, Error> {
        RString::from_value(value).ok_or_else(|| {
            Error::new(
                ruby.exception_type_error(),
                "a token to measure must be a String",
            )
        })
    }

    /// `Lain::Ext::Entropy.shannon(token)` -> bits per character as a Float.
    /// A character is what the String's own encoding says it is, as for
    /// `each_char`: a byte for binary, the pure UTF-8 split for UTF-8, and the
    /// encoding's own `mbclen` for any other, which takes an invalid byte as a
    /// character of its own.
    fn shannon_of(ruby: &Ruby, token: Value) -> Result<f64, Error> {
        let encoding = string_of(ruby, token)?.enc_get();
        let bytes = read_bytes(ruby, token, "a token to measure")?;
        Ok(if encoding == ruby.ascii8bit_encindex() {
            shannon(&bytes, byte_width)
        } else if encoding == ruby.utf8_encindex() {
            shannon(&bytes, utf8_width)
        } else {
            let encoding = RbEncoding::from(encoding);
            shannon(&bytes, |head| encoding.mbclen(head))
        })
    }

    /// `Lain::Ext::Entropy.alphabet_run?(token)`, over the token's bytes
    /// whatever its encoding.
    fn alphabet_run_of(ruby: &Ruby, token: Value) -> Result<bool, Error> {
        string_of(ruby, token)?;
        let bytes = read_bytes(ruby, token, "a token to measure")?;
        Ok(alphabet_run(&bytes))
    }

    /// Register `Lain::Ext::Entropy`. Called from `lib.rs`'s `init`.
    pub fn define(_ruby: &Ruby, ext: RModule, _lain_error: ExceptionClass) -> Result<(), Error> {
        let entropy = ext.define_module("Entropy")?;
        entropy.define_singleton_method("shannon", function!(shannon_of, 1))?;
        entropy.define_singleton_method("alphabet_run?", function!(alphabet_run_of, 1))?;
        Ok(())
    }
}
