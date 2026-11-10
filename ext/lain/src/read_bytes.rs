#![cfg(not(test))]
//! **The second way data enters this crate, for byte scans only.** `read_text`
//! refuses any String whose bytes are not its UTF-8 text, because an offset into
//! a transcoded copy would be wrong. A byte scan has no such copy: it reads the
//! bytes exactly as they sit, in whatever encoding, and its offsets are byte
//! offsets into the caller's String. `Lain::Ext::Regions#scan` is the one user,
//! since a file's bytes reach it as they came off disk.
//!
//! `spec/lain/rust/regions_spec.rb` holds this policy's examples.

use magnus::{Error, RString, Ruby, Value};
use std::ops::Deref;

/// The bytes of the String `value`, copied, whatever its encoding. A Symbol is
/// refused: its text is not a file's bytes, and reading it would run Ruby.
///
/// # Errors
///
/// A `TypeError` naming `what`. It names no class, because asking Ruby for one
/// runs Ruby while the caller may hold Rust state.
pub(crate) fn read_bytes(
    ruby: &Ruby,
    value: Value,
    what: &str,
) -> Result<impl Deref<Target = [u8]> + Send + 'static, Error> {
    RString::from_value(value)
        .map(RString::to_bytes)
        .ok_or_else(|| {
            Error::new(
                ruby.exception_type_error(),
                format!("{what} must be a String of the bytes to scan"),
            )
        })
}
