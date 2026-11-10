//! Every secret shape `Sensitivity::Regions` scans, compiled once into a [`Set`]
//! and run over a file's bytes in 1 call. Offsets are BYTE offsets into the
//! bytes handed over, whatever their encoding, since Ruby scans `content.b`.
//!
//! The shapes arrive already in this dialect: `Sensitivity::RustShapes`
//! translates each Ruby regex. Every shape runs on fancy-regex in ASCII bytes
//! mode, so `\w`, `\s`, `\b` and case folding are ASCII and a dot matches any
//! byte, as Onigmo's are over a BINARY string.
//!
//! A group name may repeat, as netrc's `value` does. [`Set::scan_until`]
//! reports the name's range the way Ruby's `MatchData#begin(name)` does: the
//! last group of that name that took part.
//!
//! A shape that exhausts fancy-regex's backtrack limit loses all its matches
//! and is named in [`Scan::limited`], so the caller can rescan it another way;
//! a partial list would under-mask without saying so.

use crate::nogvl::{Cancel, Halted, Threshold};
use fancy_regex::{BytesMode, Captures, Regex, RegexBuilder};

/// Texts shorter than this scan with the GVL held. The 24 shapes scan this
/// repository's 3,355 tracked files at about 20 ms per MB (measured 2026-11-09),
/// so 512 KiB holds the lock about 11 ms: half the 20 ms slice a released call
/// can wait out beside a busy thread, the stall budget `astgrep.rs` also uses.
pub const HOLD_BELOW: Threshold = Threshold::new(512 * 1024);

/// Matches found between reads of the stop request.
const MATCHES_PER_CHECK: usize = 64;

/// A shape that does not compile, named, so the caller can tell which.
#[derive(Debug, thiserror::Error)]
#[error("shape {name:?} does not compile: {reason}")]
pub struct CompileError {
    name: String,
    reason: String,
}

/// One reported group: its index in the shape's group table, and its range.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupSpan {
    pub group: usize,
    pub start: usize,
    pub end: usize,
}

/// One match of one shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hit {
    pub shape: usize,
    pub start: usize,
    pub end: usize,
    pub groups: Vec<GroupSpan>,
}

/// Every shape's matches over 1 text, shape by shape in order, each shape's in
/// text order, and the shapes that hit their backtrack limit.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Scan {
    pub matches: Vec<Hit>,
    pub limited: Vec<usize>,
}

/// A reported name and the capture indexes that carry it, ascending.
#[derive(Debug)]
struct Group {
    name: String,
    indexes: Vec<usize>,
}

#[derive(Debug)]
struct Shape {
    regex: Regex,
    groups: Vec<Group>,
}

/// The compiled shapes, in the order they were given.
#[derive(Debug)]
pub struct Set {
    shapes: Vec<Shape>,
}

impl Set {
    /// Compiles every `(name, source)` pair, refusing at the first that fails.
    ///
    /// # Errors
    ///
    /// [`CompileError`] naming the first shape fancy-regex refuses.
    pub fn compile(shapes: &[(String, String)]) -> Result<Self, CompileError> {
        let shapes = shapes
            .iter()
            .map(|(name, source)| {
                Shape::compile(source).map_err(|reason| CompileError {
                    name: name.clone(),
                    reason,
                })
            })
            .collect::<Result<_, _>>()?;
        Ok(Self { shapes })
    }

    /// The name group `group` of shape `shape` reports under.
    pub fn group_name(&self, shape: usize, group: usize) -> &str {
        &self.shapes[shape].groups[group].name
    }

    /// Every shape over `bytes`, reading `cancel` between shapes and every few
    /// matches.
    ///
    /// # Errors
    ///
    /// [`Halted`] once `cancel` is raised.
    pub fn scan_until(&self, bytes: &[u8], cancel: &Cancel<'_>) -> Result<Scan, Halted> {
        let mut scan = Scan::default();
        for (index, shape) in self.shapes.iter().enumerate() {
            cancel.check()?;
            match shape.hits(index, bytes, cancel)? {
                Some(hits) => scan.matches.extend(hits),
                None => scan.limited.push(index),
            }
        }
        Ok(scan)
    }
}

impl Shape {
    fn compile(source: &str) -> Result<Self, String> {
        let regex = RegexBuilder::new(source)
            .bytes_mode(BytesMode::Ascii)
            .seek(true)
            .build()
            .map_err(|err| err.to_string())?;
        let groups = groups_of(&regex);
        Ok(Self { regex, groups })
    }

    /// `None` when the shape ran out of backtracking, or reported a match with
    /// no group 0, so no partial list escapes and the caller rescans it.
    fn hits(
        &self,
        shape: usize,
        bytes: &[u8],
        cancel: &Cancel<'_>,
    ) -> Result<Option<Vec<Hit>>, Halted> {
        let mut hits = Vec::new();
        for (seen, found) in self.regex.captures_iter(bytes).enumerate() {
            if Cancel::due(seen, MATCHES_PER_CHECK) {
                cancel.check()?;
            }
            let Ok(captures) = found else {
                return Ok(None);
            };
            let Some(hit) = self.hit(shape, &captures) else {
                return Ok(None);
            };
            hits.push(hit);
        }
        Ok(Some(hits))
    }

    /// `None` for a match with no group 0, which fancy-regex never reports.
    fn hit(&self, shape: usize, captures: &Captures<'_, [u8]>) -> Option<Hit> {
        let whole = captures.get(0)?;
        let groups = self
            .groups
            .iter()
            .enumerate()
            .filter_map(|(group, carried)| {
                carried
                    .indexes
                    .iter()
                    .rev()
                    .find_map(|&index| captures.get(index))
                    .map(|span| GroupSpan {
                        group,
                        start: span.start(),
                        end: span.end(),
                    })
            })
            .collect();
        Some(Hit {
            shape,
            start: whole.start(),
            end: whole.end(),
            groups,
        })
    }
}

/// A shape with names reports only its names, since Ruby's unnamed groups do
/// not capture beside a named one; a shape with none reports every group by
/// its number.
fn groups_of(regex: &Regex) -> Vec<Group> {
    let names: Vec<(usize, &str)> = regex
        .capture_names()
        .enumerate()
        .filter_map(|(index, name)| name.map(|name| (index, name)))
        .collect();
    if names.is_empty() {
        return (1..regex.captures_len())
            .map(|index| Group {
                name: index.to_string(),
                indexes: vec![index],
            })
            .collect();
    }
    names
        .into_iter()
        .fold(Vec::new(), |mut groups: Vec<Group>, (index, name)| {
            match groups.iter_mut().find(|group| group.name == name) {
                Some(group) => group.indexes.push(index),
                None => groups.push(Group {
                    name: name.to_string(),
                    indexes: vec![index],
                }),
            }
            groups
        })
}

/// The `Lain::Ext::Regions` binding: `.compile` takes every shape in 1 crossing,
/// `Set#scan` scans 1 text in 1 crossing, and `Scan` builds its Ruby Arrays only
/// when asked, so the regex work and the result building can be timed apart.
#[cfg(not(test))]
pub mod ffi {
    use super::{HOLD_BELOW, Hit, Scan as Found, Set as Shapes};
    use crate::ffi::{frozen_str, int, lookup_error};
    use crate::nogvl::{Cancel, without_gvl_when};
    use crate::read_bytes::read_bytes;
    use crate::read_text::read_text;
    use magnus::{
        DataTypeFunctions, Error, ExceptionClass, RArray, RModule, RString, Ruby, TypedData, Value,
        function, method, prelude::*, typed_data::Obj,
    };
    use std::sync::Arc;

    /// A frozen compiled set, `Ractor.shareable?`.
    ///
    /// The audit behind `frozen_shareable`: `Shapes` is a `Vec` of fancy-regex
    /// `Regex` values and their group tables, and holds no Ruby object. Each
    /// `Regex` reaches regex-automata's search caches, which sit behind a
    /// thread-safe pool: interior mutability, but a cache that changes no
    /// answer, and `a_reused_set_agrees_with_a_fresh_one` is the proof.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Regions::Set", free_immediately, frozen_shareable)]
    pub struct Set {
        inner: Arc<Shapes>,
    }

    impl DataTypeFunctions for Set {}

    /// 1 text's matches, frozen. It holds the set for the group names.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Regions::Scan", free_immediately, frozen_shareable)]
    pub struct Scan {
        set: Arc<Shapes>,
        found: Found,
    }

    impl DataTypeFunctions for Scan {}

    /// `Lain::Ext::Regions.compile([[name, source], ...])` -> a frozen `Set`.
    /// Every entry is checked to be 2 Strings before any is read, so a
    /// refusal holds no Rust state and no Symbol's `to_s` runs.
    fn compile(ruby: &Ruby, shapes: RArray) -> Result<Obj<Set>, Error> {
        let entries = shapes
            .into_iter()
            .enumerate()
            .map(|(index, entry)| pair(ruby, index, entry))
            .collect::<Result<Vec<_>, Error>>()?;
        let pairs = entries
            .into_iter()
            .map(|(name, source)| {
                Ok((
                    read_text(ruby, name.as_value(), || "shape name".to_string())?,
                    read_text(ruby, source.as_value(), || "shape source".to_string())?,
                ))
            })
            .collect::<Result<Vec<_>, Error>>()?;
        let compiled = Shapes::compile(&pairs);
        drop(pairs);
        let inner = compiled.map_err(|err| {
            lookup_error(ruby, &["Lain", "Ext", "Regions", "BadShape"], move || {
                err.to_string()
            })
        })?;
        let set = ruby.obj_wrap(Set {
            inner: Arc::new(inner),
        });
        set.freeze();
        Ok(set)
    }

    fn pair(ruby: &Ruby, index: usize, entry: Value) -> Result<(RString, RString), Error> {
        let strings = RArray::from_value(entry)
            .filter(|pair| pair.len() == 2)
            .and_then(|pair| {
                let name = RString::from_value(pair.entry::<Value>(0).ok()?)?;
                let source = RString::from_value(pair.entry::<Value>(1).ok()?)?;
                Some((name, source))
            });
        strings.ok_or_else(|| {
            Error::new(
                ruby.exception_type_error(),
                format!("shape {index} must be an Array of 2 Strings, a name and a source"),
            )
        })
    }

    impl Set {
        /// `#scan(bytes)` -> a frozen `Scan`. A text of `HOLD_BELOW` bytes or
        /// more scans with the GVL released.
        fn scan(ruby: &Ruby, rb_self: &Set, bytes: Value) -> Result<Obj<Scan>, Error> {
            let release =
                RString::from_value(bytes).is_some_and(|text| HOLD_BELOW.releases(text.len()));
            let found = without_gvl_when(ruby, release, || {
                let (set, text) = (Arc::clone(&rb_self.inner), read_bytes(ruby, bytes, "text")?);
                Ok(move |cancel: &Cancel<'_>| set.scan_until(&text, cancel))
            })?;
            let scan = ruby.obj_wrap(Scan {
                set: Arc::clone(&rb_self.inner),
                found,
            });
            scan.freeze();
            Ok(scan)
        }
    }

    impl Scan {
        /// `#matches` -> frozen `[shape_index, start, end, {name => [start, end]}]`
        /// rows, built on each call.
        fn matches(ruby: &Ruby, rb_self: &Scan) -> Result<RArray, Error> {
            let out = ruby.ary_new_capa(rb_self.found.matches.len());
            for hit in &rb_self.found.matches {
                out.push(row(ruby, &rb_self.set, hit)?)?;
            }
            out.freeze();
            Ok(out)
        }

        /// `#limited` -> the frozen indexes of the shapes that hit their limit.
        fn limited(ruby: &Ruby, rb_self: &Scan) -> RArray {
            let out =
                ruby.ary_from_iter(rb_self.found.limited.iter().map(|&index| int(ruby, index)));
            out.freeze();
            out
        }
    }

    fn row(ruby: &Ruby, set: &Shapes, hit: &Hit) -> Result<RArray, Error> {
        let groups = ruby.hash_new_capa(hit.groups.len());
        for span in &hit.groups {
            groups.aset(
                frozen_str(ruby, set.group_name(hit.shape, span.group)),
                range(ruby, span.start, span.end),
            )?;
        }
        groups.freeze();
        let row = ruby.ary_from_iter([
            int(ruby, hit.shape),
            int(ruby, hit.start),
            int(ruby, hit.end),
            groups.as_value(),
        ]);
        row.freeze();
        Ok(row)
    }

    fn range(ruby: &Ruby, start: usize, end: usize) -> RArray {
        let pair = ruby.ary_from_iter([int(ruby, start), int(ruby, end)]);
        pair.freeze();
        pair
    }

    /// Registers `Lain::Ext::Regions`, its `Set` and `Scan`, and `BadShape`.
    pub fn define(ruby: &Ruby, ext: RModule, lain_error: ExceptionClass) -> Result<(), Error> {
        let regions = ext.define_module("Regions")?;
        regions.define_error("BadShape", lain_error)?;
        regions.define_singleton_method("compile", function!(compile, 1))?;
        let set = regions.define_class("Set", ruby.class_object())?;
        set.undef_default_alloc_func();
        set.define_method("scan", method!(Set::scan, 1))?;
        let scan = regions.define_class("Scan", ruby.class_object())?;
        scan.undef_default_alloc_func();
        scan.define_method("matches", method!(Scan::matches, 0))?;
        scan.define_method("limited", method!(Scan::limited, 0))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nogvl::Cancel;

    type Seen = Vec<(usize, usize, usize, Vec<(String, usize, usize)>)>;

    fn set(shapes: &[(&str, &str)]) -> Set {
        let owned: Vec<(String, String)> = shapes
            .iter()
            .map(|(name, source)| (name.to_string(), source.to_string()))
            .collect();
        Set::compile(&owned).expect("shapes compile")
    }

    fn seen(set: &Set, scan: &Scan) -> Seen {
        scan.matches
            .iter()
            .map(|hit| {
                let groups = hit
                    .groups
                    .iter()
                    .map(|g| {
                        (
                            set.group_name(hit.shape, g.group).to_string(),
                            g.start,
                            g.end,
                        )
                    })
                    .collect();
                (hit.shape, hit.start, hit.end, groups)
            })
            .collect()
    }

    fn scan(set: &Set, bytes: &[u8]) -> Scan {
        set.scan_until(bytes, &Cancel::never())
            .expect("never halted")
    }

    #[test]
    fn a_scan_reports_every_shape_by_index_with_byte_offsets() {
        let set = set(&[("aws", "AKIA[0-9A-Z]{16}"), ("word", r"\bkey\b")]);
        let found = scan(&set, b"key AKIAABCDEFGHABCDEFGH key\n");

        assert_eq!(
            seen(&set, &found),
            vec![(0, 4, 24, vec![]), (1, 0, 3, vec![]), (1, 25, 28, vec![])]
        );
        assert!(found.limited.is_empty());
    }

    #[test]
    fn bytes_that_are_not_utf8_are_scanned_and_counted_as_bytes() {
        let set = set(&[("tail", r"(?-u)\xff\x00(?<value>[a-z]+)")]);
        let found = scan(&set, b"\xfe\xff\x00abc\xc3");

        assert_eq!(
            seen(&set, &found),
            vec![(0, 1, 6, vec![("value".to_string(), 3, 6)])]
        );
    }

    #[test]
    fn a_repeated_name_reports_the_last_group_of_that_name_that_took_part() {
        let set = set(&[(
            "netrc",
            r"login (?<value>\w+) pw|pw (?<value>\w+) login|(?<value>x)?y",
        )]);

        assert_eq!(
            seen(&set, &scan(&set, b"login a pw")),
            vec![(0, 0, 10, vec![("value".to_string(), 6, 7)])]
        );
        assert_eq!(
            seen(&set, &scan(&set, b"pw b login")),
            vec![(0, 0, 10, vec![("value".to_string(), 3, 4)])]
        );
    }

    #[test]
    fn a_repeated_name_where_both_took_part_reports_the_later_one() {
        let set = set(&[("both", "(?<v>a)(?<v>b)")]);

        assert_eq!(
            seen(&set, &scan(&set, b"ab")),
            vec![(0, 0, 2, vec![("v".to_string(), 1, 2)])]
        );
    }

    #[test]
    fn a_name_that_took_no_part_is_absent() {
        let set = set(&[("either", "(?<a>a)|(?<b>b)")]);

        assert_eq!(
            seen(&set, &scan(&set, b"b")),
            vec![(0, 0, 1, vec![("b".to_string(), 0, 1)])]
        );
    }

    #[test]
    fn a_shape_with_no_names_reports_its_numbered_groups() {
        let set = set(&[("pair", "(a)(b)?(c)")]);

        assert_eq!(
            seen(&set, &scan(&set, b"ac")),
            vec![(
                0,
                0,
                2,
                vec![("1".to_string(), 0, 1), ("3".to_string(), 1, 2)]
            )]
        );
    }

    #[test]
    fn a_shape_with_names_reports_no_numbered_group() {
        let set = set(&[("mixed", "(a)(?<value>b)")]);

        assert_eq!(
            seen(&set, &scan(&set, b"ab")),
            vec![(0, 0, 2, vec![("value".to_string(), 1, 2)])]
        );
    }

    #[test]
    fn a_shape_over_its_backtrack_limit_is_limited_and_the_others_still_match() {
        let set = set(&[("runaway", r"^(a|aa)+\1c"), ("aws", "AKIA[0-9A-Z]{16}")]);
        let text = [b"a".repeat(60), b" AKIAABCDEFGHABCDEFGH".to_vec()].concat();
        let found = scan(&set, &text);

        assert_eq!(found.limited, vec![0]);
        assert_eq!(seen(&set, &found), vec![(1, 61, 81, vec![])]);
    }

    #[test]
    fn a_shape_that_does_not_compile_is_refused_by_name() {
        let shapes = vec![
            ("fine".to_string(), "a".to_string()),
            ("broken".to_string(), "(".to_string()),
        ];
        let Err(refused) = Set::compile(&shapes) else {
            panic!("an unclosed group compiled");
        };

        assert!(refused.to_string().contains("\"broken\""), "{refused}");
    }

    #[test]
    fn texts_from_half_a_mebibyte_release_the_gvl() {
        assert!(!HOLD_BELOW.releases(512 * 1024 - 1));
        assert!(HOLD_BELOW.releases(512 * 1024));
    }

    #[test]
    fn a_raised_cancel_halts_the_scan() {
        let set = set(&[("a", "a")]);

        assert!(set.scan_until(b"aaa", &Cancel::raised()).is_err());
    }

    #[test]
    fn a_reused_set_agrees_with_a_fresh_one() {
        let shapes = [("lookahead", r"(?=\w*\d)\w{4,}"), ("word", r"\b\w+\b")];
        let reused = set(&shapes);
        let text = b"abcd1 efgh2 ijkl mnop3";
        let first = seen(&reused, &scan(&reused, text));
        let again = seen(&reused, &scan(&reused, text));
        let fresh = set(&shapes);

        assert_eq!(first, again);
        assert_eq!(first, seen(&fresh, &scan(&fresh, text)));
    }
}
