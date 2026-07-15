//! Pure, libruby-free port of `Lain::Canonical`.
//!
//! A [`Canon`] is the wire form of a value -- JSON-native types only, object
//! keys sorted, Symbol/String collapsed -- and it serializes to bytes that are
//! IDENTICAL to Ruby's `JSON.generate(Canonical.normalize(value))`. That byte
//! identity is the whole contract: it is what a `Turn` hashes and what keeps the
//! prompt cache stable, so the Rust and Ruby digests must agree to the byte.
//!
//! The reading of a Ruby value INTO a `Canon` lives in the FFI layer (`lib.rs`),
//! because that step needs `magnus` types. Everything here is plain Rust with no
//! `magnus` in its signatures, so `cargo test` exercises the serialization and
//! hashing laws without an embedded Ruby VM -- the same split as `blake3_hex`
//! and `build_env_filter`.
//!
//! Numbers are the one place byte-identity cannot be re-derived safely in Rust:
//! Ruby's JSON float formatting is neither `Float#to_s` nor Rust's shortest-float
//! output (they diverge in the exponential ranges). So the FFI reader captures a
//! number's rendered text from Ruby itself (`Integer#to_s`, `JSON.generate` for
//! floats) and stores it verbatim in [`Canon::Num`]; this serializer emits it
//! unchanged. Structure, sorting, and string escaping ARE re-derived here,
//! because those rules are simple enough to match Ruby exactly and are covered
//! by unit tests.
//!
//! `serde_json` and RFC-8785/JCS ("JSON Canonicalization Scheme") were both
//! evaluated and rejected as the serializer here, for the same byte-parity
//! reason: `serde_json` renders floats via `ryu`, and JCS mandates ES6's
//! `Number::toString` -- neither is Ruby's `JSON.generate` float text, so
//! either would reintroduce exactly the divergence `Canon::Num`'s pre-rendered
//! text exists to avoid.

use indexmap::IndexMap;
use std::fmt::Write as _;

/// The canonical wire form of a value. `Num` holds pre-rendered JSON number text
/// (see the module docs); `Object` pairs are sorted by key with keys unique.
/// `Eq` (not just `PartialEq`) is sound here because `Num` holds Ruby's
/// rendered text, not a `f64` -- there is no NaN to make equality partial.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Canon {
    Null,
    Bool(bool),
    Num(String),
    Str(String),
    Array(Vec<Canon>),
    Object(Vec<(String, Canon)>),
}

/// `dump` stays the named domain entry point; this just gives `Canon` a free
/// `to_string()` for anything (logging, error interpolation) that wants one.
impl std::fmt::Display for Canon {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&dump(self))
    }
}

/// The only error the pure layer can raise: a Hash carrying the same key as both
/// a Symbol and a String (e.g. `:a` and `"a"`), which is genuinely ambiguous
/// once the wire form collapses them. Type, float-finiteness, and UTF-8 errors
/// are detected while reading the Ruby value and raised in the FFI layer.
///
/// The `Display` text below IS the FFI-visible message: `lib.rs`'s `canon_hash`
/// raise site passes `ambiguous.message()` (a thin delegation to this Display,
/// kept so that call site compiles untouched) straight into the raised
/// `Lain::Canonical::AmbiguousKey`.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CanonError {
    #[error("{0:?} is both a String and a Symbol key")]
    AmbiguousKey(String),
}

impl CanonError {
    /// Thin delegation to `Display` so `lib.rs:309` (`ambiguous.message()`)
    /// compiles untouched; the message text itself lives on the `#[error(...)]`
    /// attribute above, the single source of the FFI-visible string.
    pub fn message(&self) -> String {
        self.to_string()
    }
}

/// Collapse already-normalized `(key, value)` pairs into a sorted, unique-keyed
/// object. A second occurrence of a key means it appeared as both a Symbol and a
/// String in the source Hash (Ruby Hashes cannot hold the same String key
/// twice), which is the ambiguous case. `IndexMap` preserves insertion order for
/// the duplicate check, then `sort_keys` gives the deterministic ordering
/// `Canonical.dump` requires -- Ruby sorts by `String#<=>`, which is byte order,
/// exactly `str`'s `Ord`.
pub fn build_object(pairs: Vec<(String, Canon)>) -> Result<Vec<(String, Canon)>, CanonError> {
    let mut map: IndexMap<String, Canon> = IndexMap::with_capacity(pairs.len());
    for (key, value) in pairs {
        if map.contains_key(&key) {
            return Err(CanonError::AmbiguousKey(key));
        }
        map.insert(key, value);
    }
    map.sort_keys();
    Ok(map.into_iter().collect())
}

/// Compact JSON with recursively sorted object keys -- byte-identical to Ruby's
/// `Canonical.dump`.
pub fn dump(canon: &Canon) -> String {
    let mut out = String::new();
    write_canon(canon, &mut out);
    out
}

/// Content address of `canon`, e.g. `"blake3:af1349..."`. The algorithm prefix
/// keeps a future migration from being a silent reinterpretation, matching
/// `Canonical.digest`.
pub fn digest(canon: &Canon) -> String {
    format!("blake3:{}", crate::blake3_hex(dump(canon).as_bytes()))
}

fn write_canon(canon: &Canon, out: &mut String) {
    match canon {
        Canon::Null => out.push_str("null"),
        Canon::Bool(true) => out.push_str("true"),
        Canon::Bool(false) => out.push_str("false"),
        Canon::Num(text) => out.push_str(text),
        Canon::Str(text) => escape_into(text, out),
        Canon::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canon(item, out);
            }
            out.push(']');
        }
        Canon::Object(pairs) => {
            out.push('{');
            for (index, (key, value)) in pairs.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                escape_into(key, out);
                out.push(':');
                write_canon(value, out);
            }
            out.push('}');
        }
    }
}

/// Escape a string exactly as Ruby's `JSON.generate` does by default: the five
/// short escapes (`\b \t \n \f \r`), `\"` and `\\`, other C0 control characters
/// as lowercase `\u00XX`, and everything else -- including `/`, DEL, and all
/// non-ASCII -- emitted raw as UTF-8. Verified byte-for-byte against Ruby.
fn escape_into(string: &str, out: &mut String) {
    out.push('"');
    for character in string.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{09}' => out.push_str("\\t"),
            '\u{0a}' => out.push_str("\\n"),
            '\u{0c}' => out.push_str("\\f"),
            '\u{0d}' => out.push_str("\\r"),
            control if (control as u32) < 0x20 => {
                // Writing to a String is infallible, so the `write!` Result is
                // deliberately discarded rather than unwrapped.
                let _ = write!(out, "\\u{:04x}", control as u32);
            }
            other => out.push(other),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obj(pairs: Vec<(&str, Canon)>) -> Canon {
        let owned = pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        Canon::Object(build_object(owned).expect("no ambiguous keys"))
    }

    fn num(text: &str) -> Canon {
        Canon::Num(text.to_string())
    }

    fn s(text: &str) -> Canon {
        Canon::Str(text.to_string())
    }

    #[test]
    fn sorts_object_keys() {
        assert_eq!(
            dump(&obj(vec![("b", num("1")), ("a", num("2"))])),
            r#"{"a":2,"b":1}"#
        );
    }

    #[test]
    fn sorts_nested_object_keys() {
        let nested = obj(vec![
            ("z", obj(vec![("b", num("1")), ("a", num("2"))])),
            ("y", num("3")),
        ]);
        assert_eq!(dump(&nested), r#"{"y":3,"z":{"a":2,"b":1}}"#);
    }

    #[test]
    fn preserves_array_order() {
        let array = Canon::Array(vec![num("3"), num("1"), num("2")]);
        assert_eq!(dump(&array), "[3,1,2]");
    }

    #[test]
    fn emits_scalars() {
        let scalars = obj(vec![
            ("n", Canon::Null),
            ("t", Canon::Bool(true)),
            ("f", Canon::Bool(false)),
            ("i", num("1")),
            ("s", s("x")),
        ]);
        assert_eq!(
            dump(&scalars),
            r#"{"f":false,"i":1,"n":null,"s":"x","t":true}"#
        );
    }

    #[test]
    fn keeps_integer_and_float_text_distinct() {
        assert_ne!(dump(&num("1")), dump(&num("1.0")));
    }

    #[test]
    fn ambiguous_key_is_rejected() {
        let pairs = vec![("a".to_string(), num("1")), ("a".to_string(), num("2"))];
        assert_eq!(
            build_object(pairs),
            Err(CanonError::AmbiguousKey("a".to_string()))
        );
    }

    #[test]
    fn ambiguous_key_message_matches_ruby() {
        assert!(
            CanonError::AmbiguousKey("a".to_string())
                .message()
                .contains("both a String and a Symbol")
        );
    }

    // Display IS the FFI-visible message: `lib.rs`'s `canon_hash` raise site
    // calls `ambiguous.message()`, which is now a thin delegation to Display.
    // Pin the exact text so a later card can swap that call site for
    // `.to_string()` with no byte drift.
    #[test]
    fn canon_error_display_is_the_exact_ffi_message() {
        assert_eq!(
            CanonError::AmbiguousKey("a".to_string()).to_string(),
            r#""a" is both a String and a Symbol key"#
        );
    }

    #[test]
    fn canon_error_is_a_std_error() {
        let boxed: Box<dyn std::error::Error> = Box::new(CanonError::AmbiguousKey("a".to_string()));
        assert_eq!(
            boxed.to_string(),
            r#""a" is both a String and a Symbol key"#
        );
    }

    #[test]
    fn canon_display_equals_dump() {
        let value = obj(vec![("b", num("1")), ("a", num("2"))]);
        assert_eq!(value.to_string(), dump(&value));
    }

    #[test]
    fn escapes_short_and_special_forms() {
        assert_eq!(dump(&s("a\"b")), r#""a\"b""#);
        assert_eq!(dump(&s("a\\b")), r#""a\\b""#);
        assert_eq!(dump(&s("a/b")), r#""a/b""#);
        assert_eq!(dump(&s("a\nb")), r#""a\nb""#);
        assert_eq!(dump(&s("a\tb")), r#""a\tb""#);
        assert_eq!(dump(&s("a\rb")), r#""a\rb""#);
        assert_eq!(dump(&s("a\u{08}b")), r#""a\bb""#);
        assert_eq!(dump(&s("a\u{0c}b")), r#""a\fb""#);
    }

    #[test]
    fn escapes_other_controls_as_lowercase_u00xx() {
        // Expected spelled with a literal backslash-u so this file holds no
        // control characters (a raw string keeps the backslash verbatim).
        assert_eq!(dump(&s("a\u{00}b")), r#""a\u0000b""#);
        assert_eq!(dump(&s("a\u{01}b")), r#""a\u0001b""#);
        assert_eq!(dump(&s("a\u{1f}b")), r#""a\u001fb""#);
        assert_eq!(dump(&s("a\u{0b}b")), r#""a\u000bb""#);
    }

    #[test]
    fn emits_del_and_non_ascii_raw() {
        assert_eq!(dump(&s("a\u{7f}b")), "\"a\u{7f}b\"");
        assert_eq!(dump(&s("caf\u{e9}")), "\"caf\u{e9}\"");
    }

    // The blake3 content address of `{"a":1}`, matching the byte-for-byte vector
    // asserted in canonical_spec.rb (independently checked with `b3sum`).
    #[test]
    fn digest_matches_the_ruby_vector() {
        assert_eq!(
            digest(&obj(vec![("a", num("1"))])),
            "blake3:d59b6562d7c9b121bc9760873d787890ef4d429aad33a70b405baa0fa08a1f53"
        );
    }
}
