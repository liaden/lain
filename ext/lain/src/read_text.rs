#![cfg(not(test))]
//! **The only way text enters this crate.** Every binding that takes a String
//! from Ruby -- `Fuzzy`, `Prompt`, `AstGrep`, `TreeSitter` -- reads it through
//! [`read_text`], so there is exactly one string-boundary policy to reason
//! about rather than one per module drifting apart.
//!
//! This module is `magnus`-typed throughout, so `cargo test` cannot reach it
//! (see the crate root's note on why `ffi` modules are `#[cfg(not(test))]`).
//! The `string boundary` example groups in `spec/lain/rust/fuzzy_spec.rb`,
//! `prompt_spec.rb`, `astgrep_spec.rb` and `treesitter_spec.rb` are the
//! authority on this policy; they all assert the same shape.

use magnus::encoding::{EncodingCapable, RbEncoding};
use magnus::{Error, RString, Ruby, Symbol, Value, prelude::*};

/// Read `value` as a Rust `String` whose bytes are **byte-identical** to the
/// Ruby String's own, refusing anything that would require a transcode.
///
/// The accepted set is "encodings whose bytes ARE the text, and whose bytes
/// really are valid UTF-8": UTF-8 and US-ASCII when the string is valid in its
/// own encoding, and BINARY when its bytes decode as UTF-8. Reading any of
/// those as UTF-8 is identity, never a transcode.
///
/// The ENCODING has to be checked and not merely the bytes, which is why there
/// is an allow-list rather than a lone `from_utf8`: `"abc".encode("UTF-16LE")`
/// is `61 00 62 00 63 00`, and NUL is valid UTF-8, so byte validation alone
/// would accept it and silently reinterpret the text.
///
/// The allow-list is deliberately narrower than the invariant strictly needs.
/// ISO-8859-1 or Windows-1252 carrying only 7-bit content IS byte-transparent,
/// and was accepted before this policy existed; it is refused now because the
/// TAG is the contract, and the very next string in that encoding would not be
/// -- above `0x7F` those encodings and UTF-8 disagree about what the bytes mean.
/// Deciding per string would make acceptance depend on the data rather than on
/// the declaration, which is how a caller comes to believe it may pass Latin-1.
/// Nothing in lain produces one: source reaches these bindings through
/// `File.read(path, encoding: Encoding::UTF_8)`, a UTF-8 literal, or
/// `Symbol#to_s`.
///
/// **Byte-identical is the point, and it is what makes an index space mean
/// anything.** magnus's own `String` conversion falls back to `rb_str_conv_enc`,
/// which succeeds by handing Rust a transcoded COPY. Every offset a binding then
/// reports -- `AstGrep`/`TreeSitter` byte offsets, `Fuzzy` grapheme-cluster
/// indices -- would address that copy, which the caller has no handle on, while
/// looking exactly like an offset into the String it passed in. Nothing fails;
/// the answer is just wrong. Each binding still declares its OWN index space in
/// its own doc (they disagree, deliberately); this function is what makes those
/// declarations true of the caller's string rather than of an invisible one.
///
/// Symbols are accepted, and `nil` is not offered in the message: `nil` is legal
/// only as a `Prompt` variable VALUE, which `read_vars` answers before calling
/// here, so there is no reachable state in which this text could truthfully
/// advertise it.
///
/// `what` is a closure so the only caller that has to BUILD its label --
/// `prompt`'s `read_vars`, once per variable per prompt -- pays for it on the
/// error path alone.
///
/// # Errors
///
/// A `TypeError` naming the class for a non-String, non-Symbol; an
/// `EncodingError` for each of the three refusals below. Both are Ruby's OWN
/// exception classes, not `Lain::Error` subclasses: the contract being broken is
/// Ruby's encoding contract, not one of lain's invariants, and
/// `Frontend::PromptComposer` already rescues bare `EncodingError` alongside
/// `Lain::Error` for exactly that reason. It also means this policy needs no
/// `define_error` registration, so it can be shared by a module that has no
/// class of its own.
///
/// Every refusal names an action the caller can take, because a message a model
/// cannot act on is only marginally better than a wrong answer.
pub(crate) fn read_text(
    ruby: &Ruby,
    value: Value,
    what: impl Fn() -> String,
) -> Result<String, Error> {
    let string = coerce_to_string(ruby, value, &what)?;
    let encoding = string.enc_get();
    let byte_transparent = encoding == ruby.utf8_encindex()
        || encoding == ruby.usascii_encindex()
        || encoding == ruby.ascii8bit_encindex();
    if !byte_transparent {
        return Err(Error::new(
            ruby.exception_encoding_error(),
            format!(
                "{} must be UTF-8, got {}; String#encode it first -- lain never transcodes for you",
                what(),
                RbEncoding::from(encoding).name()
            ),
        ));
    }

    // SAFETY: `as_slice` borrows the String's buffer, which is rooted by `value`
    // for the duration of this call; the bytes are copied out before returning
    // and no Ruby code runs meanwhile.
    let bytes = unsafe { string.as_slice() };

    // US-ASCII declares every byte is 7-bit, so a high byte makes the string one
    // Ruby ITSELF calls invalid (`valid_encoding? == false`) -- its bytes would
    // pass the UTF-8 check below only by accident. Accepting it would honour a
    // claim the tag denies, which is the same defect as accepting UTF-16LE, so
    // it is refused by the same rule. `force_encoding` is the honest fix and the
    // message says so, because this is a mislabelled string, not a broken one.
    let stray_high_byte = (encoding == ruby.usascii_encindex())
        .then(|| bytes.iter().position(|byte| !byte.is_ascii()))
        .flatten();
    if let Some(at) = stray_high_byte {
        return Err(Error::new(
            ruby.exception_encoding_error(),
            format!(
                "{} is tagged US-ASCII but byte {at} is not ASCII; \
                 force_encoding(Encoding::UTF_8) if the bytes really are UTF-8",
                what()
            ),
        ));
    }

    // Validated here rather than through magnus's `RString::as_str`, which is an
    // upstream constructor and not a contract (see ext/lain/CLAUDE.md). `as_str`
    // requires coderange `SevenBit` for an ASCII-8BIT string, so it REFUSES a
    // BINARY string whose bytes are perfectly good multi-byte UTF-8 -- and the
    // only message it can give is "expected utf-8, got ASCII-8BIT", which is
    // false. Owning the check makes the accepted set exactly what the doc above
    // claims, and lets the failure say where the bad byte is.
    std::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|err| {
            Error::new(
                ruby.exception_encoding_error(),
                format!(
                    "{} is not valid UTF-8 (first invalid byte at offset {})",
                    what(),
                    err.valid_up_to()
                ),
            )
        })
}

/// The String behind `value`, accepting a Symbol by its name. A `TypeError`
/// naming the class it got otherwise.
fn coerce_to_string(
    ruby: &Ruby,
    value: Value,
    what: &impl Fn() -> String,
) -> Result<RString, Error> {
    let symbol_text = Symbol::from_value(value)
        .map(|symbol| symbol.funcall::<_, _, RString>("to_s", ()))
        .transpose()?;
    RString::from_value(value).or(symbol_text).ok_or_else(|| {
        // SAFETY: see `ruby_to_canon` in lib.rs -- `classname` borrows from the
        // object, which is rooted for the duration of this call, and no Ruby
        // code runs meanwhile.
        let class = unsafe { value.classname() }.into_owned();
        Error::new(
            ruby.exception_type_error(),
            format!(
                "{} must be a String or Symbol, got {}",
                what(),
                with_article(&class)
            ),
        )
    })
}

/// `"Integer"` -> `"an Integer"`, `"Float"` -> `"a Float"`. Ruby class names are
/// always capitalised, so first-letter vowel is the whole rule.
fn with_article(class: &str) -> String {
    let vowel = class
        .chars()
        .next()
        .is_some_and(|first| "AEIOU".contains(first));
    format!("{} {class}", if vowel { "an" } else { "a" })
}
