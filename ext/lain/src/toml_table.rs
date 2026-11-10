//! A generic TOML parse: the owned [`Setting`] tree the `toml` crate's `Value` is projected onto, shared by
//! `prompt.rs`'s typed config and `Lain::Ext::Toml.parse`. Both read through the one parser cargo reads a
//! manifest with, so a file cargo reads one way is never read another way.

use std::collections::BTreeMap;

/// A scalar or container read out of a TOML document.
///
/// `toml::Value` is re-projected onto this owned enum rather than stored
/// directly, so no `toml` type is reachable from a shareable handle and the
/// interior-mutability audit stops at this module's own code.
#[derive(Debug, Clone, PartialEq)]
pub enum Setting {
    /// A TOML string.
    Str(String),
    /// A TOML integer.
    Int(i64),
    /// A TOML float.
    Float(f64),
    /// A TOML boolean.
    Bool(bool),
    /// A TOML array.
    List(Vec<Setting>),
    /// A TOML table, key-ordered.
    Table(BTreeMap<String, Setting>),
}

impl Setting {
    /// Project a `toml::Value` onto the owned enum. Datetimes have no Ruby
    /// counterpart worth inventing here, so they arrive as their TOML text.
    pub fn from_toml(value: toml::Value) -> Setting {
        match value {
            toml::Value::String(s) => Setting::Str(s),
            toml::Value::Integer(i) => Setting::Int(i),
            toml::Value::Float(f) => Setting::Float(f),
            toml::Value::Boolean(b) => Setting::Bool(b),
            toml::Value::Datetime(d) => Setting::Str(d.to_string()),
            toml::Value::Array(items) => {
                Setting::List(items.into_iter().map(Setting::from_toml).collect())
            }
            toml::Value::Table(table) => Setting::Table(
                table
                    .into_iter()
                    .map(|(key, value)| (key, Setting::from_toml(value)))
                    .collect(),
            ),
        }
    }
}

/// Parse a whole document into its top-level table. The error is the parser's
/// own text, with its line, column and a snippet of the source. Nesting is
/// bounded by the `toml` crate's recursion limit, which the tests below pin,
/// since every walk over the result recurses too.
pub fn parse(source: &str) -> Result<BTreeMap<String, Setting>, String> {
    let table: toml::Table = toml::from_str(source).map_err(|err| err.to_string())?;
    Ok(table
        .into_iter()
        .map(|(key, value)| (key, Setting::from_toml(value)))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_document_becomes_its_table() {
        let table = parse("a = 1\n[b]\nc = [true, \"x\"]\nd = 1979-05-27\n").expect("parses");
        assert_eq!(table["a"], Setting::Int(1));
        assert_eq!(
            table["b"],
            Setting::Table(BTreeMap::from([
                (
                    "c".to_string(),
                    Setting::List(vec![Setting::Bool(true), Setting::Str("x".to_string())])
                ),
                ("d".to_string(), Setting::Str("1979-05-27".to_string())),
            ]))
        );
    }

    #[test]
    fn an_invalid_document_is_the_parsers_message() {
        let message = parse("a = \n").expect_err("refused");
        assert!(!message.is_empty());
    }

    #[test]
    fn nesting_past_the_parsers_limit_is_refused_not_overflowed() {
        let arrays = format!("a = {}{}\n", "[".repeat(5000), "]".repeat(5000));
        let tables = format!("a = {}1{}\n", "{ a = ".repeat(5000), " }".repeat(5000));
        let dotted = format!("{} = 1\n", vec!["a"; 5000].join("."));
        for source in [arrays, tables, dotted] {
            assert!(parse(&source).is_err());
        }
    }
}

/// The `Lain::Ext::Toml` binding, and the Ruby rebuild of a [`Setting`] tree
/// that `Prompt#settings` shares.
#[cfg(not(test))]
pub mod ffi {
    use super::{Setting, parse};
    use crate::ffi::{frozen_str, lookup_error};
    // Bytes, not `read_text`: a manifest reaches this as it came off disk, and bad
    // UTF-8 there is an invalid document, which this raises as `Invalid` rather
    // than as an encoding error from the caller's side of the boundary.
    use crate::read_bytes::read_bytes;
    use magnus::{Error, ExceptionClass, RModule, Ruby, Value, function, prelude::*};
    use std::collections::BTreeMap;

    /// A frozen Ruby Hash holding `table`, frozen all the way down.
    pub(crate) fn table_to_ruby(
        ruby: &Ruby,
        table: &BTreeMap<String, Setting>,
    ) -> Result<Value, Error> {
        let hash = ruby.hash_new();
        table.iter().try_for_each(|(key, value)| {
            hash.aset(frozen_str(ruby, key), setting_to_ruby(ruby, value)?)
        })?;
        hash.freeze();
        Ok(hash.as_value())
    }

    fn setting_to_ruby(ruby: &Ruby, setting: &Setting) -> Result<Value, Error> {
        Ok(match setting {
            Setting::Str(text) => frozen_str(ruby, text),
            Setting::Int(n) => ruby.integer_from_i64(*n).as_value(),
            Setting::Float(f) => ruby.float_from_f64(*f).as_value(),
            Setting::Bool(true) => ruby.qtrue().as_value(),
            Setting::Bool(false) => ruby.qfalse().as_value(),
            Setting::List(items) => {
                let array = ruby.ary_new_capa(items.len());
                items
                    .iter()
                    .try_for_each(|item| array.push(setting_to_ruby(ruby, item)?))?;
                array.freeze();
                array.as_value()
            }
            Setting::Table(table) => table_to_ruby(ruby, table)?,
        })
    }

    /// `Lain::Ext::Toml.parse(text)` -- a deeply frozen Hash, or `Invalid`. A TOML date or time comes
    /// back as its text, indistinguishable from a String holding the same text.
    fn parse_toml(ruby: &Ruby, text: Value) -> Result<Value, Error> {
        let bytes = read_bytes(ruby, text, "TOML text")?;
        let parsed = std::str::from_utf8(&bytes)
            .map_err(|err| format!("invalid UTF-8: {err}"))
            .and_then(parse);
        // A refusal can run Ruby, so the text's Rust copy goes first.
        drop(bytes);
        let table = parsed.map_err(|message| {
            lookup_error(ruby, &["Lain", "Ext", "Toml", "Invalid"], move || message)
        })?;
        table_to_ruby(ruby, &table)
    }

    /// Register `Lain::Ext::Toml` and its `Invalid` error. Called from `lib.rs`'s `init`.
    pub fn define(_ruby: &Ruby, ext: RModule, lain_error: ExceptionClass) -> Result<(), Error> {
        let toml = ext.define_module("Toml")?;
        toml.define_error("Invalid", lain_error)?;
        toml.define_singleton_method("parse", function!(parse_toml, 1))?;
        Ok(())
    }
}
