//! The content-address newtype shared by the DAG.
//!
//! A [`Digest`] is a `"blake3:<hex>"` content address. It is a
//! type-DISTINGUISHING wrapper, NOT a shape-VALIDATING one: it accepts whatever
//! string the boundary hands it (the Ruby `Turn.new` accepts arbitrary parent
//! strings, and `rust/turn_spec.rb` constructs `parent: "blake3:abc"`, which is
//! not a real 64-hex digest), so a validating constructor here would diverge
//! from the Ruby side and break the pinned parity specs. What it buys is that a
//! bare `String` can no longer be passed where a digest is meant -- `TurnData`'s
//! fields, the `StoreMap` keys, and every `dag` signature take `Digest`, so the
//! two are no longer interchangeable at a call site.
//!
//! `String` conversion (`From`/`Into`) is deliberately confined to the FFI
//! boundary, where a Ruby-supplied String becomes a `Digest` on the way in and a
//! `Digest` becomes a Ruby String on the way out.

use std::borrow::Borrow;
use std::ops::Deref;

/// A `"blake3:<hex>"` content address. Transparent over its `String` -- see the
/// hand-written `Debug` below, which is the load-bearing piece of the byte-parity
/// contract.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Digest(String);

/// Hand-written, NOT derived. A derived `Debug` would render `Digest("blake3:x")`;
/// but this crate's error messages interpolate a digest with `{digest:?}` (e.g.
/// `no object {digest:?} in store`) expecting the plain `String`'s `Debug` --
/// the quoted, `String#inspect`-equal form Ruby `Store#fetch` also emits.
/// Delegating to the inner `String`'s `Debug` keeps every such message
/// byte-identical after the field's type changed from `String` to `Digest`.
impl std::fmt::Debug for Digest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(&self.0, f)
    }
}

/// The raw digest text, unquoted -- what a Journal writes and what a frozen Ruby
/// String is built from.
impl std::fmt::Display for Digest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl Digest {
    /// The digest as a `&str`. Used where a caller wants the borrowed text
    /// explicitly rather than through the `Deref` below (e.g. building a frozen
    /// Ruby String, or a `.get(..19)` prefix).
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A `Digest` derefs to `str`, so every read-only `str` method (`starts_with`,
/// `get`, `len`, `==` against a `&str`) is available without ceremony.
impl Deref for Digest {
    type Target = str;

    fn deref(&self) -> &str {
        &self.0
    }
}

/// So a `Digest` key can be looked up by `&str` if a call site ever wants to,
/// with a `Hash`/`Eq` that agree with `str`'s (a `String` hashes through its
/// `str`). Today every lookup crosses with an owned `Digest`, but this keeps the
/// newtype a drop-in for the bare `String` key it replaced.
impl Borrow<str> for Digest {
    fn borrow(&self) -> &str {
        &self.0
    }
}

/// Ruby hands the FFI boundary a `String`; this is where it becomes a `Digest`.
impl From<String> for Digest {
    fn from(text: String) -> Self {
        Digest(text)
    }
}

/// ...and the reverse, for the return trip to a Ruby String (`Store#put`).
impl From<Digest> for String {
    fn from(digest: Digest) -> Self {
        digest.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_is_the_raw_digest_text() {
        assert_eq!(
            Digest::from("blake3:abc".to_string()).to_string(),
            "blake3:abc"
        );
    }

    #[test]
    fn round_trips_through_string_unchanged() {
        let original = "blake3:deadbeef".to_string();
        let back: String = Digest::from(original.clone()).into();
        assert_eq!(back, original);
    }

    // The load-bearing property: `{:?}` must render exactly as the inner String's
    // `Debug`, so every `no object {digest:?}` message stays byte-identical to
    // Ruby `String#inspect` (quoting and escaping a contained double-quote).
    #[test]
    fn debug_is_transparent_to_the_inner_string() {
        let digest = Digest::from(r#"blake3:a"b"#.to_string());
        assert_eq!(format!("{digest:?}"), r#""blake3:a\"b""#);
        assert_eq!(
            format!("{digest:?}"),
            format!("{:?}", r#"blake3:a"b"#.to_string())
        );
    }

    #[test]
    fn deref_and_as_str_expose_the_str() {
        let digest = Digest::from("blake3:abc".to_string());
        assert_eq!(digest.as_str(), "blake3:abc");
        assert_eq!(&*digest, "blake3:abc");
        // A `str` method reached through `Deref`.
        assert!(digest.starts_with("blake3:"));
    }

    #[test]
    fn equal_digests_are_eq_and_hash_alike() {
        use std::collections::HashSet;
        let mut set = HashSet::new();
        set.insert(Digest::from("blake3:x".to_string()));
        assert!(set.contains(&Digest::from("blake3:x".to_string())));
        // Consistent with the `Borrow<str>` lookup path.
        assert!(set.contains("blake3:x"));
    }
}
