//! The 5 readers of the frozen conformance corpus (`ext/lain/corpus`).
//!
//! The corpus was generated from the Ruby implementation and checked in
//! (`spec/conformance/corpus_generator.rb` generates it, and
//! `spec/conformance_corpus_spec.rb` re-derives it from Ruby). Each reader answers every recorded input with this crate's pure
//! functions and compares the answer with what Ruby recorded, so the vectors
//! keep holding the extension to Ruby's bytes, digests and messages after the
//! Ruby implementation is gone. No Ruby VM is involved.
//!
//! Inputs are a tagged tree (see the generator's `Tagged`). Reading one into a
//! [`Canon`] mirrors the FFI reader in `lib.rs` (`read_canon` and its
//! helpers): that reader needs `magnus` and cannot run here, so its decisions
//! and its refusal wording are restated below, and a change to one must be
//! made to both. Float text is the exception: Ruby's rendering is not
//! re-derivable in Rust (`canonical.rs`), so each record carries Ruby's text
//! for its floats, and the reader checks only that the text names the
//! recorded bits exactly.

use crate::canonical::{self, Canon, build_object};
use crate::dag::{self, BlobData, CanonData, NodeData, Objects, StoreMap};
use crate::digest::Digest;
use crate::event::{EventData, Kind, PayloadData, Role};
use std::collections::HashMap;
use std::sync::Arc;

const CANONICAL: &str = include_str!("../corpus/canonical.ndjson");
const EVENT_DIGEST: &str = include_str!("../corpus/event_digest.ndjson");
const DAG: &str = include_str!("../corpus/dag.ndjson");
const STORE: &str = include_str!("../corpus/store.ndjson");
const ERRORS: &str = include_str!("../corpus/errors.ndjson");
const MANIFEST: &str = include_str!("../corpus/MANIFEST.json");

const UNSUPPORTED: &str = "Lain::Canonical::UnsupportedType";
const NON_FINITE: &str = "Lain::Canonical::NonFiniteFloat";
const AMBIGUOUS: &str = "Lain::Canonical::AmbiguousKey";
const MISSING: &str = "Lain::Ext::Store::MissingObject";
const MISMATCH: &str = "Lain::Ext::Store::DigestMismatch";

/// Numbers keep their text and objects their order, so nothing is lost before
/// a comparison.
#[derive(Debug, Clone, PartialEq)]
enum Json {
    Null,
    Bool(bool),
    Num(String),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    fn parse(text: &str) -> Json {
        let mut parser = Parser { text, at: 0 };
        let value = parser.value();
        parser.skip_space();
        assert_eq!(parser.at, text.len(), "trailing text after a JSON value");
        value
    }

    fn opt(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(pairs) => pairs.iter().find(|(name, _)| name == key).map(|(_, v)| v),
            other => panic!("expected an object holding {key:?}, got {other:?}"),
        }
    }

    fn get(&self, key: &str) -> &Json {
        self.opt(key)
            .unwrap_or_else(|| panic!("no {key:?} in {self:?}"))
    }

    fn str(&self) -> &str {
        match self {
            Json::Str(text) => text,
            other => panic!("expected a string, got {other:?}"),
        }
    }

    fn arr(&self) -> &[Json] {
        match self {
            Json::Arr(items) => items,
            other => panic!("expected an array, got {other:?}"),
        }
    }

    fn index(&self) -> usize {
        match self {
            Json::Num(text) => text.parse().expect("an index"),
            other => panic!("expected a number, got {other:?}"),
        }
    }

    fn digest(&self) -> Option<Digest> {
        match self {
            Json::Null => None,
            other => Some(Digest::from(other.str().to_string())),
        }
    }

    fn digests(&self) -> Vec<Digest> {
        self.arr()
            .iter()
            .map(|item| Digest::from(item.str().to_string()))
            .collect()
    }

    fn from_digest(digest: Option<&Digest>) -> Json {
        digest.map_or(Json::Null, |d| Json::Str(d.to_string()))
    }

    fn object(key: &str, value: Json) -> Json {
        Json::Obj(vec![(key.to_string(), value)])
    }
}

/// A recursive-descent reader for the JSON Ruby's `JSON.generate` writes.
/// Hand-written because the crate carries no JSON parser, and the corpus is
/// the only JSON it reads.
struct Parser<'a> {
    text: &'a str,
    at: usize,
}

impl Parser<'_> {
    fn peek(&self) -> u8 {
        self.text.as_bytes()[self.at]
    }

    fn skip_space(&mut self) {
        while self.at < self.text.len() && self.peek().is_ascii_whitespace() {
            self.at += 1;
        }
    }

    fn eat(&mut self, expected: u8) {
        self.skip_space();
        assert_eq!(self.peek(), expected, "at byte {}", self.at);
        self.at += 1;
    }

    fn next_is(&mut self, byte: u8) -> bool {
        self.skip_space();
        let found = self.peek() == byte;
        if found {
            self.at += 1;
        }
        found
    }

    fn literal(&mut self, word: &str, value: Json) -> Json {
        assert!(
            self.text[self.at..].starts_with(word),
            "at byte {}",
            self.at
        );
        self.at += word.len();
        value
    }

    fn value(&mut self) -> Json {
        self.skip_space();
        match self.peek() {
            b'n' => self.literal("null", Json::Null),
            b't' => self.literal("true", Json::Bool(true)),
            b'f' => self.literal("false", Json::Bool(false)),
            b'"' => Json::Str(self.string()),
            b'[' => Json::Arr(self.sequence(b']', Self::value)),
            b'{' => Json::Obj(self.sequence(b'}', Self::pair)),
            _ => self.number(),
        }
    }

    fn sequence<T>(&mut self, close: u8, item: fn(&mut Self) -> T) -> Vec<T> {
        self.at += 1;
        let mut items = Vec::new();
        if self.next_is(close) {
            return items;
        }
        loop {
            items.push(item(self));
            if self.next_is(close) {
                return items;
            }
            self.eat(b',');
        }
    }

    fn pair(&mut self) -> (String, Json) {
        self.skip_space();
        let key = self.string();
        self.eat(b':');
        (key, self.value())
    }

    fn number(&mut self) -> Json {
        let start = self.at;
        while self.at < self.text.len()
            && matches!(self.peek(), b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
        {
            self.at += 1;
        }
        assert!(self.at > start, "no JSON value at byte {start}");
        Json::Num(self.text[start..self.at].to_string())
    }

    fn string(&mut self) -> String {
        assert_eq!(self.peek(), b'"', "a string at byte {}", self.at);
        self.at += 1;
        let mut out = String::new();
        loop {
            let character = self.text[self.at..].chars().next().expect("an open string");
            self.at += character.len_utf8();
            match character {
                '"' => return out,
                '\\' => out.push(self.escape()),
                other => out.push(other),
            }
        }
    }

    fn escape(&mut self) -> char {
        let code = self.peek();
        self.at += 1;
        match code {
            b'"' => '"',
            b'\\' => '\\',
            b'/' => '/',
            b'b' => '\u{08}',
            b'f' => '\u{0c}',
            b'n' => '\n',
            b'r' => '\r',
            b't' => '\t',
            b'u' => self.unicode(),
            other => panic!("bad escape {:?}", other as char),
        }
    }

    fn unicode(&mut self) -> char {
        let high = self.hex4();
        let code = if (0xd800..0xdc00).contains(&high) {
            assert!(self.text[self.at..].starts_with("\\u"), "a lone surrogate");
            self.at += 2;
            0x10000 + ((high - 0xd800) << 10) + (self.hex4() - 0xdc00)
        } else {
            high
        };
        char::from_u32(code).expect("a scalar value")
    }

    fn hex4(&mut self) -> u32 {
        let digits = &self.text[self.at..self.at + 4];
        self.at += 4;
        u32::from_str_radix(digits, 16).expect("4 hex digits")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Raised {
    class: String,
    message: String,
}

fn raised(class: &str, message: impl Into<String>) -> Raised {
    Raised {
        class: class.to_string(),
        message: message.into(),
    }
}

struct Floats(HashMap<String, String>);

impl Floats {
    fn of(output: &Json) -> Floats {
        let table = match output.opt("floats") {
            Some(Json::Obj(pairs)) => pairs
                .iter()
                .map(|(bits, text)| (bits.clone(), text.str().to_string()))
                .collect(),
            _ => HashMap::new(),
        };
        Floats(table)
    }

    fn none() -> Floats {
        Floats(HashMap::new())
    }
}

/// `read_canon`'s decisions over a tagged tree. `depth` counts the containers
/// already entered, as there.
fn read(tag: &Json, floats: &Floats, depth: usize) -> Result<Canon, Raised> {
    let node = tag.arr();
    match node[0].str() {
        "nil" => Ok(Canon::Null),
        "true" => Ok(Canon::Bool(true)),
        "false" => Ok(Canon::Bool(false)),
        "int" => Ok(Canon::Num(node[1].str().to_string())),
        "float" => float(node[1].str(), floats),
        "str" | "sym" | "bin" | "bad" => text(node).map(Canon::Str),
        "arr" => {
            let inner = enter(depth)?;
            node[1]
                .arr()
                .iter()
                .map(|item| read(item, floats, inner))
                .collect::<Result<Vec<_>, _>>()
                .map(Canon::Array)
        }
        "hash" => {
            let inner = enter(depth)?;
            let pairs = node[1]
                .arr()
                .iter()
                .map(|pair| Ok((key(&pair.arr()[0])?, read(&pair.arr()[1], floats, inner)?)))
                .collect::<Result<Vec<_>, Raised>>()?;
            build_object(pairs)
                .map(Canon::Object)
                .map_err(|ambiguous| raised(AMBIGUOUS, ambiguous.message()))
        }
        "obj" => Err(raised(
            UNSUPPORTED,
            format!("cannot canonicalize {}", node[1].str()),
        )),
        other => panic!("unknown tag {other:?}"),
    }
}

fn enter(depth: usize) -> Result<usize, Raised> {
    crate::descend(depth).map_err(|too_deep| raised(UNSUPPORTED, too_deep))
}

fn float(bits: &str, floats: &Floats) -> Result<Canon, Raised> {
    let bits = u64::from_str_radix(bits, 16).expect("16 hex digits");
    if !f64::from_bits(bits).is_finite() {
        return Err(raised(NON_FINITE, crate::non_finite(f64::from_bits(bits))));
    }
    let text = floats
        .0
        .get(&format!("{bits:016x}"))
        .expect("Ruby's text for every finite float");
    let parsed: f64 = text.parse().expect("float text Rust can parse");
    assert_eq!(parsed.to_bits(), bits, "{text} does not name its bits");
    Ok(Canon::Num(text.clone()))
}

/// A binary String reaches UTF-8 by Ruby's transcoding, which refuses every
/// high byte, even where the bytes would read as UTF-8.
fn text(node: &[Json]) -> Result<String, Raised> {
    let invalid = || raised(UNSUPPORTED, "string is not valid UTF-8");
    match node[0].str() {
        "str" | "sym" => Ok(node[1].str().to_string()),
        "bin" => {
            let bytes = hex(node[1].str());
            bytes
                .is_ascii()
                .then(|| String::from_utf8(bytes).expect("ASCII"))
                .ok_or_else(invalid)
        }
        "bad" => String::from_utf8(hex(node[1].str())).map_err(|_| invalid()),
        other => panic!("{other:?} is not text"),
    }
}

fn key(tag: &Json) -> Result<String, Raised> {
    let node = tag.arr();
    match node[0].str() {
        "str" | "sym" | "bin" | "bad" => text(node),
        _ => Err(raised(
            UNSUPPORTED,
            format!(
                "hash keys must be String or Symbol, got {}",
                ruby_class(node)
            ),
        )),
    }
}

fn ruby_class(node: &[Json]) -> &str {
    match node[0].str() {
        "nil" => "NilClass",
        "true" => "TrueClass",
        "false" => "FalseClass",
        "int" => "Integer",
        "float" => "Float",
        "arr" => "Array",
        "hash" => "Hash",
        "obj" => node[1].str(),
        other => panic!("{other:?} names no class"),
    }
}

fn optional_text(tag: &Json) -> Option<String> {
    match tag.arr()[0].str() {
        "nil" => None,
        _ => Some(text(tag.arr()).expect("valid text")),
    }
}

fn hex(digits: &str) -> Vec<u8> {
    (0..digits.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&digits[at..at + 2], 16).expect("hex"))
        .collect()
}

fn accepted(tag: &Json, floats: &Floats) -> Canon {
    read(tag, floats, 0).unwrap_or_else(|refusal| panic!("refused {tag:?}: {refusal:?}"))
}

fn records(file: &str) -> impl Iterator<Item = (usize, Json, Json)> + '_ {
    file.lines().enumerate().map(|(index, line)| {
        let record = Json::parse(line);
        (
            index + 1,
            record.get("input").clone(),
            record.get("output").clone(),
        )
    })
}

fn manifest() -> Json {
    Json::parse(MANIFEST)
}

/// What the extension must raise where Ruby raised `ruby`: the same, unless
/// the manifest names the difference as deliberate.
fn expected(ruby: &Json) -> Raised {
    let class = ruby.get("class").str();
    let message = ruby.get("message").str();
    let manifest = manifest();
    let divergence = manifest.get("divergences").arr().iter().find(|known| {
        known.get("ruby_class").str() == class
            && message.starts_with(known.get("ruby_message_prefix").str())
    });
    match divergence {
        Some(known) => raised(
            known.get("rust_class").str(),
            match known.get("rust_message") {
                Json::Null => message,
                rust => rust.str(),
            },
        ),
        None => raised(class, message),
    }
}

fn kind(tag: &Json) -> Kind {
    optional_text(tag)
        .expect("a kind")
        .parse()
        .expect("a wire kind")
}

fn payload_dump(payload: &PayloadData) -> String {
    canonical::dump(&Canon::object_from_sorted([
        ("body", payload.body.clone()),
        ("kind", Canon::Str(payload.kind.as_str().to_string())),
    ]))
}

fn event(input: &Json, floats: &Floats) -> Arc<EventData> {
    if let Some(turn) = input.opt("turn") {
        let role: Role = optional_text(turn.get("role"))
            .expect("a role")
            .parse()
            .expect("a wire role");
        return EventData::turn(
            role,
            accepted(turn.get("content"), floats),
            turn.get("parent").digest(),
            accepted(turn.get("meta"), floats),
            turn.get("correlation").digest(),
            turn.get("causal_parents").digests(),
        );
    }
    let fields = input.get("event");
    EventData::new(
        optional_text(fields.get("from")),
        optional_text(fields.get("to")),
        fields.get("render_parent").digest(),
        fields.get("causal_parents").digests(),
        fields.get("correlation").digest(),
        PayloadData::new(
            kind(fields.get("kind")),
            accepted(input.get("body"), floats),
        ),
    )
}

/// Ruby's `ChainWriter.correlation_of`: the head's correlation, or the head
/// itself when it is the root.
fn correlation(map: &StoreMap, head: Option<&Digest>) -> Option<Digest> {
    head.map(|digest| {
        map.get(digest)
            .expect("a stored head")
            .correlation
            .clone()
            .unwrap_or_else(|| digest.clone())
    })
}

fn committed(map: &StoreMap, digests: &[Digest], commit: &Json) -> Arc<EventData> {
    let parent = match commit.get("on") {
        Json::Null => None,
        on => Some(digests[on.index()].clone()),
    };
    let causal = commit
        .get("causal")
        .arr()
        .iter()
        .map(|index| digests[index.index()].clone())
        .collect();
    EventData::turn(
        commit.get("role").str().parse().expect("a wire role"),
        accepted(commit.get("content"), &Floats::none()),
        parent.clone(),
        accepted(commit.get("meta"), &Floats::none()),
        correlation(map, parent.as_ref()),
        causal,
    )
}

fn answer(map: &StoreMap, digests: &[Digest], query: &Json) -> Json {
    let head = |slot: &Json| match slot {
        Json::Null => None,
        index => Some(&digests[index.index()]),
    };
    let one = head(query.get("a"));
    let operand = query.get("b");
    let walked = match query.get("op").str() {
        "ancestors" => dag::ancestor_digests(map, one)
            .map(|all| Json::Arr(all.iter().map(|d| Json::Str(d.to_string())).collect())),
        "length" => dag::length(map, one).map(|n| Json::Num(n.to_string())),
        "correlation" => Ok(Json::from_digest(correlation(map, one).as_ref())),
        "include" => dag::includes(map, one, &digests[operand.index()]).map(Json::Bool),
        "rewind" => {
            let steps = i64::try_from(operand.index()).expect("a small count");
            crate::rewind_to(map, one.cloned(), steps).map(|d| Json::from_digest(d.as_ref()))
        }
        "ancestor_of" => dag::ancestor_of(map, one, head(operand)).map(Json::Bool),
        "meet" => dag::meet(map, one, head(operand)).map(|d| Json::from_digest(d.as_ref())),
        other => panic!("unknown query {other:?}"),
    };
    walked.expect("a well-formed chain")
}

fn member(object: &Json, floats: &Floats) -> NodeData {
    if let Some(fields) = object.opt("payload") {
        return NodeData::Payload(PayloadData::new(
            wire_kind(fields),
            accepted(fields.get("body"), floats),
        ));
    }
    if let Some(fields) = object.opt("event") {
        let kind = wire_kind(fields);
        let render_parent = fields.get("render_parent").digest();
        let causal = fields.get("causal_parents").digests();
        let correlation = fields.get("correlation").digest();
        return NodeData::Event(match fields.opt("payload_digest") {
            Some(payload) => EventData::detached(
                kind,
                None,
                None,
                render_parent,
                causal,
                correlation,
                payload.digest().expect("a payload digest"),
            ),
            None => EventData::new(
                None,
                None,
                render_parent,
                causal,
                correlation,
                PayloadData::new(kind, accepted(fields.get("body"), floats)),
            ),
        });
    }
    if let Some(blob) = object.opt("blob") {
        return NodeData::Blob(Arc::new(BlobData::new(
            blob.get("tag").str(),
            hex(blob.get("hex").str()),
        )));
    }
    NodeData::Canon(Arc::new(CanonData::new(accepted(
        object.get("canon"),
        floats,
    ))))
}

fn wire_kind(fields: &Json) -> Kind {
    fields.get("kind").str().parse().expect("a wire kind")
}

fn applied(objects: &mut Objects, op: &Json, floats: &Floats) -> Result<Json, Raised> {
    if let Some(object) = op.opt("put") {
        return match crate::put_into(objects, &member(object, floats)) {
            Ok((next, digest)) => {
                *objects = next;
                Ok(Json::object("digest", Json::Str(digest.to_string())))
            }
            Err(refusal @ crate::PutRefusal::Dangling(_)) => {
                Err(raised(MISSING, refusal.to_string()))
            }
            Err(refusal) => Err(raised(MISMATCH, refusal.to_string())),
        };
    }
    if let Some(wanted) = op.opt("fetch") {
        let wanted = wanted.digest().expect("a digest");
        return objects
            .get(&wanted)
            .map(|found| Json::object("digest", Json::Str(found.digest().to_string())))
            .ok_or_else(|| raised(MISSING, format!("no object {wanted:?} in store")));
    }
    let wanted = op.get("key").digest().expect("a digest");
    Ok(Json::object("key", Json::Bool(objects.contains(&wanted))))
}

fn assert_answers(rust: Result<Json, Raised>, recorded: &Json, at: &str) {
    match recorded.opt("error") {
        Some(ruby) => assert_eq!(rust, Err(expected(ruby)), "{at}"),
        None => assert_eq!(rust, Ok(recorded.clone()), "{at}"),
    }
}

/// How Ruby's `inspect` quotes a kind argument; the FFI reader asks Ruby, so
/// the corpus keeps to Symbols and Strings that read the same either way.
fn inspected(tag: &Json) -> String {
    let node = tag.arr();
    match node[0].str() {
        "sym" => format!(":{}", node[1].str()),
        _ => format!("{:?}", node[1].str()),
    }
}

fn refusal(input: &Json, floats: &Floats) -> Raised {
    match input.get("case").str() {
        "canonical" => read(input.get("value"), floats, 0).expect_err("a refusal"),
        "role" => {
            let role = optional_text(input.get("role")).expect("role text");
            let invalid = role.parse::<Role>().expect_err("an invalid role");
            raised("Lain::Ext::Event::InvalidRole", invalid.to_string())
        }
        "kind" => {
            let tag = input.get("kind");
            let invalid = optional_text(tag)
                .expect("kind text")
                .parse::<Kind>()
                .expect_err("an invalid kind");
            raised("Lain::Error", invalid.message(&inspected(tag)))
        }
        "fetch" => {
            let wanted = input.get("digest").digest().expect("a digest");
            raised(MISSING, format!("no object {wanted:?} in store"))
        }
        other => panic!("unknown error case {other:?}"),
    }
}

#[test]
fn every_corpus_file_is_the_one_its_manifest_names() {
    let manifest = manifest();
    let files = manifest.get("files");
    for (name, text) in [
        ("canonical.ndjson", CANONICAL),
        ("event_digest.ndjson", EVENT_DIGEST),
        ("dag.ndjson", DAG),
        ("store.ndjson", STORE),
        ("errors.ndjson", ERRORS),
    ] {
        let entry = files.get(name);
        assert_eq!(
            format!("blake3:{}", crate::blake3_hex(text.as_bytes())),
            entry.get("blake3").str(),
            "{name} differs from the manifest"
        );
        assert_eq!(text.lines().count(), entry.get("records").index(), "{name}");
    }
}

#[test]
fn every_canonical_vector_dumps_and_digests_as_ruby_did() {
    for (line, input, output) in records(CANONICAL) {
        let canon = accepted(input.get("value"), &Floats::of(&output));
        assert_eq!(
            canonical::dump(&canon),
            output.get("dump").str(),
            "canonical:{line}"
        );
        assert_eq!(
            canonical::digest(&canon),
            output.get("digest").str(),
            "canonical:{line}"
        );
    }
}

#[test]
fn every_event_vector_addresses_its_payload_and_envelope_as_ruby_did() {
    for (line, input, output) in records(EVENT_DIGEST) {
        let node = event(&input, &Floats::of(&output));
        let payload = node.payload.as_ref().expect("a carried payload");
        let at = format!("event_digest:{line}");
        assert_eq!(
            payload_dump(payload),
            output.get("payload_dump").str(),
            "{at}"
        );
        assert_eq!(
            payload.digest.as_str(),
            output.get("payload_digest").str(),
            "{at}"
        );
        assert_eq!(
            canonical::dump(&node.payload_canon()),
            output.get("envelope_dump").str(),
            "{at}"
        );
        assert_eq!(node.digest.as_str(), output.get("digest").str(), "{at}");
    }
}

#[test]
fn every_dag_vector_commits_and_walks_as_ruby_did() {
    for (line, input, output) in records(DAG) {
        let mut map = StoreMap::new_sync();
        let mut digests = Vec::new();
        for commit in input.get("commits").arr() {
            let node = committed(&map, &digests, commit);
            digests.push(node.digest.clone());
            map = map.insert(node.digest.clone(), node);
        }
        assert_eq!(digests, output.get("digests").digests(), "dag:{line}");
        let queries = input.get("queries").arr();
        assert_eq!(
            queries.len(),
            output.get("answers").arr().len(),
            "dag:{line}"
        );
        for (query, recorded) in queries.iter().zip(output.get("answers").arr()) {
            assert_eq!(
                &answer(&map, &digests, query),
                recorded,
                "dag:{line} {query:?}"
            );
        }
    }
}

#[test]
fn every_store_vector_puts_fetches_and_refuses_as_ruby_did() {
    for (line, input, output) in records(STORE) {
        let floats = Floats::of(&output);
        let mut objects = Objects::empty();
        let ops = input.get("ops").arr();
        assert_eq!(ops.len(), output.get("results").arr().len(), "store:{line}");
        for (step, (op, recorded)) in ops.iter().zip(output.get("results").arr()).enumerate() {
            let rust = applied(&mut objects, op, &floats);
            assert_answers(rust, recorded, &format!("store:{line} op {step}"));
        }
        assert_eq!(objects.size(), output.get("size").index(), "store:{line}");
    }
}

#[test]
fn every_error_vector_is_refused_as_ruby_did() {
    for (line, input, output) in records(ERRORS) {
        let rust = refusal(&input, &Floats::of(&output));
        assert_eq!(rust, expected(output.get("raised")), "errors:{line}");
    }
}

#[test]
fn the_reader_parses_escapes_and_surrogate_pairs() {
    assert_eq!(
        Json::parse(r#"["a\"\\\/\b\f\n\r\t\u0001é🦀"]"#),
        Json::Arr(vec![Json::Str(
            "a\"\\/\u{8}\u{c}\n\r\t\u{1}\u{e9}\u{1f980}".to_string()
        )])
    );
}

#[test]
fn a_binary_string_with_any_high_byte_is_refused_even_when_it_reads_as_utf8() {
    let tag = |hex: &str| vec![Json::Str("bin".into()), Json::Str(hex.into())];
    assert_eq!(text(&tag("61")), Ok("a".to_string()));
    assert_eq!(
        text(&tag("c3a9")),
        Err(raised(UNSUPPORTED, "string is not valid UTF-8"))
    );
}

#[test]
#[should_panic(expected = "a string")]
fn the_reader_refuses_a_string_without_its_opening_quote() {
    Parser {
        text: "abc\"",
        at: 0,
    }
    .string();
}
