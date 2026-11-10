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
//! A shape fancy-regex cannot finish, over its backtrack limit or its stack,
//! is retried at a higher limit. What the retry still cannot finish is
//! reported in [`Scan::over_masked`], since a partial list would under-mask
//! without saying so: a single-line shape line by line, each line it cannot
//! finish whole; any other shape from the end of its last finished match to
//! the end of the text.

use crate::nogvl::{Cancel, Halted, Threshold};
use fancy_regex::{BytesMode, Captures, Regex, RegexBuilder};

/// Texts shorter than this scan with the GVL held. The 24 shapes scan this
/// repository's 3,355 tracked files at about 20 ms per MB (measured 2026-11-09),
/// so 512 KiB holds the lock about 11 ms: half the 20 ms slice a released call
/// can wait out beside a busy thread, the stall budget `astgrep.rs` also uses.
pub const HOLD_BELOW: Threshold = Threshold::new(512 * 1024);

/// Matches found between reads of the stop request.
const MATCHES_PER_CHECK: usize = 64;

/// The backtracking budgets a shape is scanned under: once at `first`, and
/// again at `retry` when it cannot finish.
#[derive(Debug, Clone, Copy)]
struct Limits {
    first: usize,
    retry: usize,
}

impl Limits {
    /// fancy-regex's own default first. The retry is 10 times it: a 1.2 MB
    /// run of near misses for `quoted password key` needs more than the
    /// default and finishes well inside this.
    const DEFAULT: Self = Self {
        first: 1_000_000,
        retry: 10_000_000,
    };
}

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

/// A span a shape could not finish scanning, so it is masked whole.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OverMask {
    pub shape: usize,
    pub start: usize,
    pub end: usize,
}

/// Every shape's matches over 1 text, shape by shape in order, each shape's in
/// text order, and the spans the shapes could not finish.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Scan {
    pub matches: Vec<Hit>,
    pub over_masked: Vec<OverMask>,
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
    retry: Regex,
    single_line: bool,
    groups: Vec<Group>,
}

struct Run {
    hits: Vec<Hit>,
    finished: bool,
}

/// The compiled shapes, in the order they were given.
#[derive(Debug)]
pub struct Set {
    shapes: Vec<Shape>,
}

impl Set {
    /// Compiles every `(name, source, single_line)` shape, refusing at the
    /// first that fails. `single_line` says no match of the shape can cross a
    /// newline, so it may be retried line by line.
    ///
    /// # Errors
    ///
    /// [`CompileError`] naming the first shape fancy-regex refuses.
    pub fn compile(shapes: &[(String, String, bool)]) -> Result<Self, CompileError> {
        Self::compile_with(shapes, Limits::DEFAULT)
    }

    fn compile_with(
        shapes: &[(String, String, bool)],
        limits: Limits,
    ) -> Result<Self, CompileError> {
        let shapes = shapes
            .iter()
            .map(|(name, source, single_line)| {
                Shape::compile(source, *single_line, limits).map_err(|reason| CompileError {
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
            let first = shape.run(&shape.regex, index, bytes, 0, cancel)?;
            if first.finished {
                scan.matches.extend(first.hits);
            } else if shape.single_line {
                shape.retry_by_line(index, bytes, cancel, &mut scan)?;
            } else {
                shape.retry_to_end(index, bytes, cancel, &mut scan)?;
            }
        }
        Ok(scan)
    }
}

impl Shape {
    fn compile(source: &str, single_line: bool, limits: Limits) -> Result<Self, String> {
        let build = |limit: usize| {
            RegexBuilder::new(source)
                .bytes_mode(BytesMode::Ascii)
                .seek(true)
                .backtrack_limit(limit)
                .build()
                .map_err(|err| err.to_string())
        };
        let regex = build(limits.first)?;
        let retry = build(limits.retry)?;
        let groups = groups_of(&regex);
        Ok(Self {
            regex,
            retry,
            single_line,
            groups,
        })
    }

    /// A line's matches are kept only when its scan finishes, since the line
    /// is masked whole otherwise.
    fn retry_by_line(
        &self,
        shape: usize,
        bytes: &[u8],
        cancel: &Cancel<'_>,
        scan: &mut Scan,
    ) -> Result<(), Halted> {
        let mut start = 0;
        for line in bytes.split(|&byte| byte == b'\n') {
            cancel.check()?;
            let run = self.run(&self.retry, shape, line, start, cancel)?;
            if run.finished {
                scan.matches.extend(run.hits);
            } else {
                scan.over_mask(shape, start, start + line.len());
            }
            start += line.len() + 1;
        }
        Ok(())
    }

    fn retry_to_end(
        &self,
        shape: usize,
        bytes: &[u8],
        cancel: &Cancel<'_>,
        scan: &mut Scan,
    ) -> Result<(), Halted> {
        let run = self.run(&self.retry, shape, bytes, 0, cancel)?;
        let finished_to = run.hits.last().map_or(0, |hit| hit.end);
        scan.matches.extend(run.hits);
        if !run.finished {
            scan.over_mask(shape, finished_to, bytes.len());
        }
        Ok(())
    }

    /// `at` places a line's matches in the whole text, so a retry by line
    /// reports the offsets a whole-text scan would.
    fn run(
        &self,
        regex: &Regex,
        shape: usize,
        bytes: &[u8],
        at: usize,
        cancel: &Cancel<'_>,
    ) -> Result<Run, Halted> {
        let mut hits = Vec::new();
        for (seen, found) in regex.captures_iter(bytes).enumerate() {
            if Cancel::due(seen, MATCHES_PER_CHECK) {
                cancel.check()?;
            }
            let Some(hit) = found
                .ok()
                .and_then(|captures| self.hit(shape, &captures, at))
            else {
                return Ok(Run {
                    hits,
                    finished: false,
                });
            };
            hits.push(hit);
        }
        Ok(Run {
            hits,
            finished: true,
        })
    }

    /// `None` for a match with no group 0, which fancy-regex never reports.
    fn hit(&self, shape: usize, captures: &Captures<'_, [u8]>, at: usize) -> Option<Hit> {
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
                        start: at + span.start(),
                        end: at + span.end(),
                    })
            })
            .collect();
        Some(Hit {
            shape,
            start: at + whole.start(),
            end: at + whole.end(),
            groups,
        })
    }
}

impl Scan {
    fn over_mask(&mut self, shape: usize, start: usize, end: usize) {
        self.over_masked.push(OverMask { shape, start, end });
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
    use super::{HOLD_BELOW, Hit, OverMask, Scan as Found, Set as Shapes};
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

    /// `Lain::Ext::Regions.compile([[name, source, single_line], ...])` -> a
    /// frozen `Set`. The flag is true or false. Every entry is checked before
    /// any is read, so a refusal holds no Rust state and no Symbol's `to_s`
    /// runs.
    fn compile(ruby: &Ruby, shapes: RArray) -> Result<Obj<Set>, Error> {
        let entries = shapes
            .into_iter()
            .enumerate()
            .map(|(index, entry)| shape_entry(ruby, index, entry))
            .collect::<Result<Vec<_>, Error>>()?;
        let sources = entries
            .into_iter()
            .map(|(name, source, single_line)| {
                Ok((
                    read_text(ruby, name.as_value(), || "shape name".to_string())?,
                    read_text(ruby, source.as_value(), || "shape source".to_string())?,
                    single_line,
                ))
            })
            .collect::<Result<Vec<_>, Error>>()?;
        let compiled = Shapes::compile(&sources);
        drop(sources);
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

    fn shape_entry(
        ruby: &Ruby,
        index: usize,
        entry: Value,
    ) -> Result<(RString, RString, bool), Error> {
        let refused = |what: &str| {
            Error::new(
                ruby.exception_type_error(),
                format!("shape {index} must be {what}"),
            )
        };
        let array = RArray::from_value(entry)
            .filter(|array| array.len() == 3)
            .ok_or_else(|| refused("an Array of a name, a source and a single-line flag"))?;
        let (name, source) = name_and_source(array)
            .ok_or_else(|| refused("an Array of 2 Strings, a name and a source"))?;
        let flag = array.entry::<Value>(2)?;
        if flag.is_kind_of(ruby.class_true_class()) {
            Ok((name, source, true))
        } else if flag.is_kind_of(ruby.class_false_class()) {
            Ok((name, source, false))
        } else {
            Err(refused("given its single-line flag as true or false"))
        }
    }

    fn name_and_source(array: RArray) -> Option<(RString, RString)> {
        let name = RString::from_value(array.entry::<Value>(0).ok()?)?;
        let source = RString::from_value(array.entry::<Value>(1).ok()?)?;
        Some((name, source))
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

        /// `#over_masked` -> frozen `[shape_index, start, end]` rows, 1 for each
        /// span a shape could not finish.
        fn over_masked(ruby: &Ruby, rb_self: &Scan) -> RArray {
            let out = ruby.ary_from_iter(
                rb_self
                    .found
                    .over_masked
                    .iter()
                    .map(|span| over_masked_row(ruby, span)),
            );
            out.freeze();
            out
        }
    }

    fn over_masked_row(ruby: &Ruby, span: &OverMask) -> RArray {
        let row = ruby.ary_from_iter([
            int(ruby, span.shape),
            int(ruby, span.start),
            int(ruby, span.end),
        ]);
        row.freeze();
        row
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
        scan.define_method("over_masked", method!(Scan::over_masked, 0))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nogvl::Cancel;

    type Seen = Vec<(usize, usize, usize, Vec<(String, usize, usize)>)>;

    fn set(shapes: &[(&str, &str)]) -> Set {
        let lined: Vec<(&str, &str, bool)> = shapes
            .iter()
            .map(|&(name, source)| (name, source, false))
            .collect();
        set_with(&lined, Limits::DEFAULT)
    }

    fn set_with(shapes: &[(&str, &str, bool)], limits: Limits) -> Set {
        let owned: Vec<(String, String, bool)> = shapes
            .iter()
            .map(|&(name, source, single_line)| (name.to_string(), source.to_string(), single_line))
            .collect();
        Set::compile_with(&owned, limits).expect("shapes compile")
    }

    fn masked(scan: &Scan) -> Vec<(usize, usize, usize)> {
        scan.over_masked
            .iter()
            .map(|span| (span.shape, span.start, span.end))
            .collect()
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

    fn spans(set: &Set, scan: &Scan) -> Vec<(usize, usize, usize)> {
        seen(set, scan)
            .into_iter()
            .map(|(shape, start, end, _)| (shape, start, end))
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
        assert!(found.over_masked.is_empty());
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
    fn a_shape_the_first_limit_cannot_finish_is_retried_at_the_higher_one() {
        let limits = Limits {
            first: 2,
            retry: 1_000_000,
        };
        let set = set_with(&[("runaway", r"(a|aa)+\1c", false)], limits);
        let found = scan(&set, b"aaaaaaaaaa aaac");

        assert!(found.over_masked.is_empty(), "{:?}", found.over_masked);
        assert_eq!(
            seen(&set, &found),
            vec![(0, 11, 15, vec![("1".to_string(), 12, 13)])]
        );
    }

    /// Only a start-of-text anchor keeps fancy-regex from failing this
    /// runaway fast, so the line it cannot finish comes first.
    #[test]
    fn a_single_line_shape_over_its_limit_is_over_masked_on_that_line_alone() {
        let set = set_with(
            &[
                ("runaway", r"^(a|aa)+\1c", true),
                ("aws", "AKIA[0-9A-Z]{16}", false),
            ],
            Limits::DEFAULT,
        );
        let text = [b"a".repeat(60), b"\nAKIAABCDEFGHABCDEFGH\naac\n".to_vec()].concat();
        let found = scan(&set, &text);

        assert_eq!(masked(&found), vec![(0, 0, 60)]);
        assert_eq!(spans(&set, &found), vec![(0, 82, 85), (1, 61, 81)]);
    }

    #[test]
    fn a_multi_line_shape_over_its_limit_is_over_masked_from_its_last_match_to_the_end() {
        let pem =
            r"(?m)-----BEGIN ((?:RSA )?PUBLIC KEY)-----\r?\n([A-Za-z0-9+/=\r\n]+)-----END \1-----";
        let set = set(&[("pem", pem), ("aws", "AKIA[0-9A-Z]{16}")]);
        let closed = b"-----BEGIN PUBLIC KEY-----\nQUJD\n-----END PUBLIC KEY-----".to_vec();
        let text = [
            closed.clone(),
            b"\n-----BEGIN PUBLIC KEY-----\n".to_vec(),
            b"A".repeat(1_100_000),
            b"-----END RSA PUBLIC KEY-----\nAKIAABCDEFGHABCDEFGH".to_vec(),
        ]
        .concat();
        let found = scan(&set, &text);
        let aws = text.len() - 20;

        assert_eq!(masked(&found), vec![(0, closed.len(), text.len())]);
        assert_eq!(
            spans(&set, &found),
            vec![(0, 0, closed.len()), (1, aws, text.len())]
        );
    }

    #[test]
    fn a_multi_line_shape_with_no_finished_match_is_over_masked_from_the_start() {
        let set = set(&[("runaway", r"^(a|aa)+\1c")]);
        let text = b"a".repeat(60);

        assert_eq!(masked(&scan(&set, &text)), vec![(0, 0, 60)]);
    }

    /// Each line outruns the first limit and finishes inside the retry with no
    /// match, so nothing inside a line reads the stop request. It is raised
    /// halfway through a 1-line scan, which only a read between lines can see.
    #[test]
    fn a_retry_by_line_reads_the_stop_request_before_every_line() {
        let shape = [("runaway", r"^(a|aa)+\1c", true)];
        let tight = Limits {
            first: 100_000,
            retry: 100_000,
        };
        let set = set_with(&shape, Limits::DEFAULT);
        let line = b"a".repeat(28);
        assert_eq!(
            masked(&scan(&set_with(&shape, tight), &line)),
            vec![(0, 0, 28)]
        );
        let started = std::time::Instant::now();
        assert_eq!(scan(&set, &line), Scan::default());
        let one_line = started.elapsed();
        let text = vec![line; 63].join(&b'\n');
        let flag = std::sync::atomic::AtomicBool::new(false);

        let halted = std::thread::scope(|threads| {
            threads.spawn(|| {
                std::thread::sleep(one_line.mul_f64(0.5));
                flag.store(true, std::sync::atomic::Ordering::Relaxed);
            });
            set.scan_until(&text, &Cancel::watching(&flag)).is_err()
        });

        assert!(halted, "the retry ran every line after the stop request");
    }

    #[test]
    fn a_shape_that_does_not_compile_is_refused_by_name() {
        let shapes = vec![
            ("fine".to_string(), "a".to_string(), false),
            ("broken".to_string(), "(".to_string(), true),
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
