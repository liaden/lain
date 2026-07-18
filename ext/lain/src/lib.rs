#![deny(clippy::print_stdout, clippy::print_stderr)]
//! Output discipline is enforced at the crate root: `print_stdout` /
//! `print_stderr` are hard errors so no Rust code here can smear plain text
//! onto a stream the Ruby-side Journal may be parsing as NDJSON. Diagnostics go
//! through `tracing`, whose writer is a caller-supplied fd (see
//! [`ffi::init_tracing`]).

use tracing_subscriber::EnvFilter;

mod astgrep;
mod bm25;
mod canonical;
mod dag;
mod digest;
mod event;

/// Build a `tracing_subscriber` [`EnvFilter`] from a caller-supplied level or
/// directive string (e.g. `"info"`, `"debug"`, `"lain=trace,warn"`).
///
/// This is deliberately a plain Rust function with no `magnus` types in its
/// signature so it can be unit-tested without an embedded Ruby VM. It returns a
/// human-readable error message on invalid input instead of panicking.
fn build_env_filter(level: &str) -> Result<EnvFilter, String> {
    let trimmed = level.trim();
    if trimmed.is_empty() {
        return Err("log level must not be empty".to_string());
    }
    EnvFilter::try_new(trimmed).map_err(|e| format!("invalid log level directive {trimmed:?}: {e}"))
}

/// Duplicate a caller-owned file descriptor into an independent [`std::fs::File`].
///
/// This is the load-bearing half of output discipline on the Rust side. Ruby
/// hands us an `IO#fileno` for where tracing should write (its real stderr, or
/// an open Journal file). We must NOT wrap that fd directly: when the resulting
/// `File` is dropped it would `close(2)` the descriptor, silently closing
/// Ruby's log file or, worse, its stderr. Instead we `dup(2)` first and own
/// only the dup, so dropping the Rust side never touches the fd Ruby still owns.
///
/// Kept at crate root (outside the Ruby-only `ffi` module) so the invariant can
/// be unit-tested without an embedded Ruby VM.
#[cfg(unix)]
fn dup_writer(fd: std::os::unix::io::RawFd) -> std::io::Result<std::fs::File> {
    use std::os::unix::io::FromRawFd;

    // SAFETY: `dup` returns a brand-new descriptor that we exclusively own on
    // success; `File::from_raw_fd` then takes ownership of that dup alone. The
    // caller's original `fd` is untouched and remains theirs to close.
    let duped = unsafe { libc::dup(fd) };
    if duped < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { std::fs::File::from_raw_fd(duped) })
}

/// The lowercase-hex BLAKE3 digest of `bytes`.
///
/// Plain Rust, no `magnus` types, so `cargo test` covers the one hash Lain
/// uses for content-addressing without needing an embedded Ruby VM. `Canonical`
/// calls through the FFI wrapper below; this function is what is actually
/// under test.
fn blake3_hex(bytes: &[u8]) -> String {
    blake3::hash(bytes).to_hex().to_string()
}

/// How a [`Canon::Num`] text must be rebuilt as a Ruby value. `Canon::Num`
/// holds text a reader already rendered (an Integer's `#to_s` or a Float's
/// `JSON.generate`, see `canonical.rs`), so this classification is total on
/// that domain -- but the function is defined on ALL `&str` input, returning
/// `Err` for anything a reader could never emit. That is deliberate: it turns
/// "unreachable for reader-produced text" into a checked fact instead of an
/// assumption, so a future bug that hands this function un-rendered text
/// fails loudly instead of turning into a silent `NaN` or `nil`.
#[derive(Debug, PartialEq)]
enum NumClass {
    /// A JSON float text (contains `.`, `e`, or `E`), pre-parsed.
    Float(f64),
    /// An integer text that fits `i64`, pre-parsed.
    Small(i64),
    /// An integer text too large for `i64`. Kept as text -- Rust has no
    /// arbitrary-precision integer here, so the caller re-parses it through
    /// Ruby's own `String#to_i`, which is exactly what `canonical_dump`'s
    /// `Integer#to_s` inverts.
    Big,
}

fn classify_num(text: &str) -> Result<NumClass, String> {
    if text.contains(['.', 'e', 'E']) {
        return text
            .parse::<f64>()
            .map(NumClass::Float)
            .map_err(|e| format!("unparseable float text {text:?}: {e}"));
    }
    if let Ok(small) = text.parse::<i64>() {
        return Ok(NumClass::Small(small));
    }
    // Not an i64: valid only as a bignum if it is a non-empty run of ASCII
    // digits with an optional leading `-`. Anything else (garbage like
    // `"abc"` or `""`) must NOT fall through to Ruby's `String#to_i`, which
    // silently reads a numeric prefix and returns 0 for none at all.
    let digits = text.strip_prefix('-').unwrap_or(text);
    if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        Ok(NumClass::Big)
    } else {
        Err(format!("unparseable integer text {text:?}"))
    }
}

/// A `Store#put` refused because one of the node's parent digests is absent
/// from the store -- the referential-integrity check at the public API
/// boundary. The message's family form (`no object <parent> in store`) matches
/// every other dangling-digest raise (see [`dag::DanglingDigest`]); the tail
/// names the refusal context. This `Display` IS the FFI-visible message,
/// byte-identical to Ruby `Store#validate_parents!` (`lib/lain/store.rb`) for
/// plain digests -- `{:?}` on a [`crate::digest::Digest`] renders as Ruby's
/// `String#inspect` does, the same contract `DanglingDigest` documents.
///
/// Prevention here is what makes the pure `dag.rs` walk arms unreachable via
/// the public API; they stay loud regardless (their cargo tests hand-corrupt
/// a StoreMap directly), same philosophy as `classify_num`'s garbage arm.
#[derive(Debug, Clone, PartialEq, Eq)]
struct DanglingPut {
    parent: crate::digest::Digest,
    child: crate::digest::Digest,
}

impl std::fmt::Display for DanglingPut {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "no object {:?} in store: putting {:?} would dangle",
            self.parent, self.child
        )
    }
}

impl std::error::Error for DanglingPut {}

/// Whether `node` may enter `map` at the public `put` boundary: every parent
/// edge -- the single render edge, then each causal parent in their pinned
/// sorted order -- must already be present. The refusal names the FIRST
/// dangling edge, the same order Ruby `Store#parent_edges` checks (render
/// parent before causal set; `payload_digest` has no arm here because the Ext
/// store carries an event's payload inline with its envelope, never as a
/// separate object). Plain Rust over the locked map -- the caller holds the
/// Store's lock across this check AND the insert, so a concurrent put cannot
/// race in between. The internal commit path skips this deliberately: its
/// parent is the committing Timeline's own validated head, so it is
/// inductively safe (see `Timeline::commit` in the `ffi` module).
fn validate_put(map: &dag::StoreMap, node: &event::EventData) -> Result<(), DanglingPut> {
    let dangling = node
        .render_parent
        .iter()
        .chain(node.causal_parents.iter())
        .find(|edge| !map.contains_key(*edge));
    match dangling {
        Some(edge) => Err(DanglingPut {
            parent: edge.clone(),
            child: node.digest.clone(),
        }),
        None => Ok(()),
    }
}

// ---------------------------------------------------------------------------
// FFI surface.
//
// Everything below touches `magnus`/Ruby C symbols. It is compiled for the
// real cdylib build (`cargo build`) and checked by `cargo clippy`, but excluded
// from the unit-test binary (`cfg(test)`), which only exercises the pure Rust
// helpers above. This keeps `cargo test` from having to link libruby (this
// toolchain ships a static-only Ruby, and linking it into a test executable is
// both heavyweight and fragile), so plain `cargo test` needs no extra flags,
// dev-dependencies, or linker configuration.
// ---------------------------------------------------------------------------

#[cfg(not(test))]
mod ffi {
    use super::{NumClass, blake3_hex, build_env_filter, classify_num, dup_writer, validate_put};
    use crate::canonical::{self, Canon};
    use crate::dag;
    use crate::digest::Digest;
    use crate::event::{EventData, Role};
    use magnus::{
        DataTypeFunctions, Error, ExceptionClass, Float, Integer, RArray, RClass, RHash, RModule,
        RString, Ruby, Symbol, TryConvert, TypedData, Value, function, gc, method,
        prelude::*,
        r_hash::ForEach,
        scan_args::{get_kwargs, scan_args},
        typed_data::{self, Obj},
        value::Opaque,
    };
    use std::io::Write;
    use std::sync::{Arc, Mutex};

    /// Shareability canary for the M4 Timeline port.
    ///
    /// The whole port hinges on a magnus `TypedData` object being
    /// `Ractor.shareable?` once frozen -- `Turn` must stay shareable (there is a
    /// spec). `frozen_shareable` sets `RUBY_TYPED_FROZEN_SHAREABLE`, but that is
    /// a *promise* to Ruby, honoured only if the wrapped state is genuinely
    /// immutable and holds no reachable mutable Ruby object. This wraps a single
    /// immutable `u64` and nothing else, so it isolates the mechanism from any
    /// one port's own state. The Timeline port has since landed and `turn_spec`
    /// now asserts `Ractor.shareable?(turn)` on the real thing -- but this canary
    /// is deliberately RETAINED (not stale) as the isolated control: if a magnus
    /// upgrade breaks `frozen_shareable`, `share_probe_spec` fails here, telling
    /// you it is the flag itself and not `Turn`'s state, and it stands the same
    /// guard for the future `frozen_shareable` ports (Workspace Timeline,
    /// structural memory) before they exist to test it.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::ShareProbe", free_immediately, frozen_shareable)]
    struct ShareProbe {
        value: u64,
    }

    impl DataTypeFunctions for ShareProbe {}

    impl ShareProbe {
        fn new(ruby: &Ruby, value: u64) -> magnus::typed_data::Obj<Self> {
            let obj = ruby.obj_wrap(Self { value });
            obj.freeze();
            obj
        }

        fn value(&self) -> u64 {
            self.value
        }
    }

    /// A cloneable `MakeWriter` handle over one shared, dup'd file. Cloning is
    /// an `Arc` bump (never another `dup`, so no fd leak per event), and the
    /// mutex serializes writes so concurrent Rust spans cannot interleave a
    /// half-written NDJSON line.
    struct SharedWriter(Arc<Mutex<std::fs::File>>);

    impl SharedWriter {
        /// A poisoned mutex means another thread panicked mid-write. The log line
        /// it was writing may be torn, but that is no reason for a *logger* to
        /// panic too -- especially across an FFI boundary, where unwinding into
        /// Ruby is far worse than a corrupt line. Recover the guard and continue.
        ///
        /// Named `locked_file`, not `file`: the noun `file` reads as a plain
        /// accessor, but this call acquires the `Mutex` -- the name should say
        /// so, matching `Store::locked`.
        fn locked_file(&self) -> std::sync::MutexGuard<'_, std::fs::File> {
            self.0
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
        }
    }

    impl Write for SharedWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.locked_file().write(buf)
        }

        /// Overridden deliberately. The default `write_all` loops over `write`,
        /// re-acquiring the mutex on each partial write -- so a second thread
        /// could slip a whole event between two fragments of this one. Regular
        /// files seldom write partially, but stderr is typically a pipe or tty,
        /// where they do. Holding the lock across the entire buffer is what
        /// actually keeps one event on one NDJSON line.
        fn write_all(&mut self, buf: &[u8]) -> std::io::Result<()> {
            self.locked_file().write_all(buf)
        }

        fn flush(&mut self) -> std::io::Result<()> {
            self.locked_file().flush()
        }
    }

    /// Install a global JSON-emitting `tracing` subscriber that writes NDJSON
    /// (one flat JSON object per line), filtered by `level`, to the file
    /// descriptor `fd` (a Ruby `IO#fileno`). Pass `2` for stderr.
    ///
    /// The fd is dup'd (see [`super::dup_writer`]) so dropping the Rust
    /// subscriber never closes Ruby's descriptor.
    ///
    /// Idempotent: the underlying `try_init` only succeeds once per process. A
    /// second call is reported as a no-op (`false`) rather than panicking or
    /// aborting the Ruby VM. Invalid level strings surface as a Ruby
    /// `ArgumentError`; a failed `dup` surfaces as a `RuntimeError`.
    ///
    /// Returns `true` if this call installed the subscriber, `false` if a
    /// global subscriber was already present.
    fn init_tracing(ruby: &Ruby, level: String, fd: i32) -> Result<bool, Error> {
        let filter =
            build_env_filter(&level).map_err(|msg| Error::new(ruby.exception_arg_error(), msg))?;

        let file = dup_writer(fd).map_err(|e| {
            Error::new(
                ruby.exception_runtime_error(),
                format!("failed to dup fd {fd}: {e}"),
            )
        })?;
        let writer = Arc::new(Mutex::new(file));

        // Flat, machine-parseable NDJSON: event fields are hoisted to the top
        // level and the current span's fields are included, so a Rust span can
        // later be merged into Lain's Journal event stream alongside Ruby-side
        // events.
        let installed = tracing_subscriber::fmt()
            .json()
            .flatten_event(true)
            .with_current_span(true)
            .with_span_list(false)
            .with_env_filter(filter)
            .with_writer(move || SharedWriter(Arc::clone(&writer)))
            .try_init()
            .is_ok();

        Ok(installed)
    }

    /// Demo FFI entry point, instrumented so that calling it emits a span plus
    /// an event through the subscriber installed by `init_tracing`.
    #[tracing::instrument(level = "info")]
    fn hello(subject: String) -> String {
        tracing::info!(subject = %subject, "hello invoked");
        format!("Hello from Rust, {subject}!")
    }

    /// `Lain::Canonical`'s content-addressing hash. Thin FFI wrapper over
    /// [`super::blake3_hex`]; the hashing itself is tested in `cargo test`
    /// without libruby, so this wrapper has nothing left to get wrong beyond
    /// reading the argument's bytes.
    ///
    /// Threads the argument's raw bytes rather than a UTF-8 `String`. blake3 is
    /// a function over bytes; typing the boundary as `String` would silently
    /// transcode (or reject) a future binary caller. `Canonical` passes a UTF-8
    /// JSON dump, so its bytes are unchanged.
    fn ffi_blake3_hex(bytes: RString) -> String {
        // SAFETY: we do not call back into Ruby (which could move or free the
        // string) between borrowing the slice and hashing it.
        blake3_hex(unsafe { bytes.as_slice() })
    }

    /// Look up `name` as a constant of `scope`, which may be a Module or a
    /// Class -- `Lain`/`Ext`/`Canonical` are modules, `Store`/`Bm25`/`Turn`/
    /// `Timeline` are classes, and a `lookup_error` path interleaves both as
    /// it walks down. `RModule::const_get` and `RClass::const_get` do the
    /// identical lookup (Ruby's own `Module#const_get`, which `Class`
    /// inherits); this just picks whichever the value actually is, since a
    /// `TryConvert` to the wrong one of the two rejects the other's runtime
    /// type outright.
    fn scoped_const_get(ruby: &Ruby, scope: Value, name: &str) -> Result<Value, Error> {
        if let Some(module) = RModule::from_value(scope) {
            module.const_get(name)
        } else if let Some(class) = RClass::from_value(scope) {
            class.const_get(name)
        } else {
            Err(Error::new(
                ruby.exception_type_error(),
                // SAFETY: classname reads the object's class name; no Ruby
                // code runs meanwhile.
                format!("no implicit conversion of {} into Module", unsafe {
                    scope.classname()
                }),
            ))
        }
    }

    /// Build the exception named by `path` (a full constant path starting at
    /// `Lain`, e.g. `["Lain", "Canonical", "AmbiguousKey"]` or `["Lain", "Ext",
    /// "Store", "MissingObject"]`) with `message`. Looked up at raise-time
    /// (not ext-init) because the Ruby-side classes are defined after this
    /// extension loads; a lookup failure surfaces as the underlying
    /// `NameError`/`TypeError` rather than being swallowed.
    ///
    /// Absorbs what were two near-identical functions, `canonical_error`
    /// (`Lain::Canonical::<name>`, a two-segment walk after the root) and
    /// `ext_error` (`Lain::Ext::<class>::<error>`, three segments) -- they
    /// differed only in path depth, and every real caller is one of exactly
    /// those two shapes.
    pub(crate) fn lookup_error(ruby: &Ruby, path: &[&str], message: String) -> Error {
        let (last, init) = path
            .split_last()
            .expect("lookup_error path must be non-empty");
        let scope = init
            .iter()
            .try_fold(ruby.class_object().as_value(), |scope, segment| {
                scoped_const_get(ruby, scope, segment)
            });
        let looked = scope
            .and_then(|scope| scoped_const_get(ruby, scope, last))
            .and_then(ExceptionClass::try_convert);
        match looked {
            Ok(exception) => Error::new(exception, message),
            Err(lookup_failure) => lookup_failure,
        }
    }

    /// Read a Ruby value into a [`Canon`], applying `Canonical.normalize`'s rules
    /// and raising the matching `Lain::Canonical` error on anything JSON cannot
    /// represent. Numbers keep the text Ruby renders (see `canonical.rs`): an
    /// Integer via `#to_s`, a Float via `JSON.generate`, so the bytes match
    /// Ruby's exactly even where Rust's float formatting would diverge.
    fn ruby_to_canon(ruby: &Ruby, value: Value) -> Result<Canon, Error> {
        // `equal` calls Ruby's `#==`, which a hostile or buggy class can
        // override to raise. Propagated with `?` rather than swallowed to
        // `false`: falling through would misreport a raising `==` as "not
        // true, not false" and (most likely) end up raising the wrong error --
        // `UnsupportedType` for the object's class -- instead of the real one.
        if value.is_nil() {
            Ok(Canon::Null)
        } else if value.equal(ruby.qtrue())? {
            Ok(Canon::Bool(true))
        } else if value.equal(ruby.qfalse())? {
            Ok(Canon::Bool(false))
        } else if let Some(integer) = Integer::from_value(value) {
            Ok(Canon::Num(integer.funcall("to_s", ())?))
        } else if let Some(float) = Float::from_value(value) {
            canon_float(ruby, float, value)
        } else if let Some(text) = coerce_text(ruby, value)? {
            Ok(Canon::Str(text))
        } else if let Some(array) = RArray::from_value(value) {
            let items = array
                .into_iter()
                .map(|element| ruby_to_canon(ruby, element))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Canon::Array(items))
        } else if let Some(hash) = RHash::from_value(value) {
            canon_hash(ruby, hash)
        } else {
            // SAFETY: classname reads the object's class name; no Ruby code runs
            // meanwhile.
            let class = unsafe { value.classname() }.into_owned();
            Err(lookup_error(
                ruby,
                &["Lain", "Canonical", "UnsupportedType"],
                format!("cannot canonicalize {class}"),
            ))
        }
    }

    fn canon_float(ruby: &Ruby, float: Float, value: Value) -> Result<Canon, Error> {
        // JSON has no NaN/Infinity; a hash over one would not round-trip. Checked
        // before rendering so the error is `NonFiniteFloat`, not JSON's own.
        if !float.to_f64().is_finite() {
            return Err(lookup_error(
                ruby,
                &["Lain", "Canonical", "NonFiniteFloat"],
                "cannot canonicalize a non-finite Float".to_string(),
            ));
        }
        let json = ruby.class_object().const_get::<_, RModule>("JSON")?;
        Ok(Canon::Num(json.funcall("generate", (value,))?))
    }

    fn canon_hash(ruby: &Ruby, hash: RHash) -> Result<Canon, Error> {
        let mut pairs: Vec<(String, Canon)> = Vec::new();
        hash.foreach(|key: Value, val: Value| {
            pairs.push((canon_key(ruby, key)?, ruby_to_canon(ruby, val)?));
            Ok(ForEach::Continue)
        })?;
        let object = canonical::build_object(pairs).map_err(|ambiguous| {
            lookup_error(
                ruby,
                &["Lain", "Canonical", "AmbiguousKey"],
                ambiguous.message(),
            )
        })?;
        Ok(Canon::Object(object))
    }

    fn canon_key(ruby: &Ruby, key: Value) -> Result<String, Error> {
        if let Some(text) = coerce_text(ruby, key)? {
            Ok(text)
        } else {
            // SAFETY: see `ruby_to_canon`.
            let class = unsafe { key.classname() }.into_owned();
            Err(lookup_error(
                ruby,
                &["Lain", "Canonical", "UnsupportedType"],
                format!("hash keys must be String or Symbol, got {class}"),
            ))
        }
    }

    /// A validated UTF-8 `String`, transcoding from the string's own encoding
    /// exactly as `Canonical#utf8` does: `RString::to_string` takes the valid
    /// UTF-8 fast path or `rb_str_conv_enc`, and errors on bytes that are not
    /// convertible -- which is precisely when Ruby raises.
    fn validated_utf8(ruby: &Ruby, string: RString) -> Result<String, Error> {
        string.to_string().map_err(|_| {
            lookup_error(
                ruby,
                &["Lain", "Canonical", "UnsupportedType"],
                "string is not valid UTF-8".to_string(),
            )
        })
    }

    /// A String or Symbol coerced to a validated UTF-8 `String`, or `None` when
    /// the value is neither. Both branches -- a String's own bytes, a Symbol via
    /// `#to_s` -- are identical across `ruby_to_canon`, `canon_key`, and
    /// `read_role`; each caller supplies its own error for the `None` case.
    fn coerce_text(ruby: &Ruby, value: Value) -> Result<Option<String>, Error> {
        if let Some(string) = RString::from_value(value) {
            Ok(Some(validated_utf8(ruby, string)?))
        } else if let Some(symbol) = Symbol::from_value(value) {
            Ok(Some(validated_utf8(ruby, symbol.funcall("to_s", ())?)?))
        } else {
            Ok(None)
        }
    }

    /// `Lain::Ext.canonical_dump` -- the byte-identical twin of `Canonical.dump`,
    /// driving the shared `canonical determinism` group against this impl.
    fn canonical_dump(ruby: &Ruby, value: Value) -> Result<String, Error> {
        Ok(canonical::dump(&ruby_to_canon(ruby, value)?))
    }

    /// `Lain::Ext.canonical_digest` -- `"blake3:" + hex`, equal to
    /// `Canonical.digest` byte-for-byte. This is the entry the Rust `Turn` will
    /// hash through, and the one the digest-equality spec pins to Ruby.
    fn canonical_digest(ruby: &Ruby, value: Value) -> Result<String, Error> {
        Ok(canonical::digest(&ruby_to_canon(ruby, value)?))
    }

    // -----------------------------------------------------------------------
    // Turn / Store / Timeline: the content-addressed DAG.
    //
    // FFI-boundary decision: a Turn, a Store, and a Timeline each cross as an
    // OPAQUE HANDLE, never a serialized copy, and every DAG walk runs ENTIRELY
    // in Rust against the Store's `rpds` map. A method returns either a scalar,
    // one fresh handle, or a single Ruby Array built in one pass -- never one
    // FFI call per node, which is where a naive binding loses to plain Ruby.
    // `Turn` holds only immutable Rust state (an `Arc<EventData>`: no reachable
    // Ruby object), so `frozen_shareable` is honest once the handle is frozen.
    // `Timeline` is the one handle that references a Ruby object (its `Store`),
    // so it marks that reference and is deliberately NOT frozen_shareable --
    // exactly as the Ruby `Timeline`, a frozen value over a mutable Store, is
    // itself not `Ractor.shareable?`.
    // -----------------------------------------------------------------------

    /// Map a pure-layer [`dag::DanglingDigest`] onto `Lain::Ext::Store::MissingObject`.
    /// The struct's `Display` is byte-equal to Ruby `Store#fetch`, so a corrupt
    /// chain raises the same class and the same message from every walk.
    fn missing_object(ruby: &Ruby, dangling: dag::DanglingDigest) -> Error {
        lookup_error(
            ruby,
            &["Lain", "Ext", "Store", "MissingObject"],
            dangling.to_string(),
        )
    }

    /// The `&Store` a `Lain::Ext::Store` Ruby value names. Collapses the
    /// repeated `store_ref(rb_self.store_value(ruby))` (and its
    /// `store_ref(store_value)` reuse form, when a caller already
    /// holds the `Value`) at every DAG-walking `Timeline` method into one
    /// named site.
    fn store_ref<'a>(store_value: Value) -> Result<&'a Store, Error> {
        TryConvert::try_convert(store_value)
    }

    /// A frozen Ruby String. Digests, roles, and reconstructed content strings
    /// are all frozen so a reconstructed `content`/`meta` tree is deeply
    /// immutable, matching the Ruby `Turn`.
    fn frozen_str(ruby: &Ruby, text: &str) -> Value {
        let string = ruby.str_new(text);
        string.freeze();
        string.as_value()
    }

    /// Rebuild a Ruby value from a [`Canon`], deeply frozen. Called on demand
    /// (e.g. `turn.content`), so the `Turn` handle itself never has to hold a
    /// Ruby reference -- which is what keeps it trivially `Ractor.shareable?`.
    /// Fallible only because [`num_to_ruby`] is: a `Canon::Num` this crate
    /// itself never wrote would otherwise be the sole silent corner of an
    /// FFI surface that is loud everywhere else.
    fn canon_to_ruby(ruby: &Ruby, canon: &Canon) -> Result<Value, Error> {
        Ok(match canon {
            Canon::Null => ruby.qnil().as_value(),
            Canon::Bool(true) => ruby.qtrue().as_value(),
            Canon::Bool(false) => ruby.qfalse().as_value(),
            Canon::Num(text) => num_to_ruby(ruby, text)?,
            Canon::Str(text) => frozen_str(ruby, text),
            Canon::Array(items) => {
                let array = ruby.ary_new_capa(items.len());
                for item in items {
                    array.push(canon_to_ruby(ruby, item)?)?;
                }
                array.freeze();
                array.as_value()
            }
            Canon::Object(pairs) => {
                let hash = ruby.hash_new();
                for (key, value) in pairs {
                    hash.aset(frozen_str(ruby, key), canon_to_ruby(ruby, value)?)?;
                }
                hash.freeze();
                hash.as_value()
            }
        })
    }

    /// Rebuild the Ruby number a [`Canon::Num`] text denotes, via the pure
    /// [`classify_num`] (cargo-tested without an embedded Ruby VM). A JSON
    /// float always carries `.`, `e`, or `E`; an integer never does -- so the
    /// text alone says which. Bignums round-trip through Ruby's own parser to
    /// keep arbitrary precision. `classify_num`'s `Err` arm is unreachable for
    /// text this crate produced itself (see `canonical.rs`'s `Canon::Num`
    /// docs) -- exactly why reaching it here must raise loudly rather than
    /// materialize `NaN` or `nil`.
    fn num_to_ruby(ruby: &Ruby, text: &str) -> Result<Value, Error> {
        match classify_num(text) {
            Ok(NumClass::Float(f)) => Ok(ruby.float_from_f64(f).as_value()),
            Ok(NumClass::Small(i)) => Ok(ruby.integer_from_i64(i).as_value()),
            Ok(NumClass::Big) => ruby.str_new(text).funcall("to_i", ()),
            Err(reason) => Err(Error::new(
                ruby.exception_runtime_error(),
                format!(
                    "Lain::Ext: {reason} -- Canon::Num text must be reader-produced, \
                     never handed to the FFI boundary unparsed"
                ),
            )),
        }
    }

    /// Read a role argument (String or Symbol) and validate it into a [`Role`],
    /// raising `Turn::InvalidRole` on anything that is not a wire role.
    fn read_role(ruby: &Ruby, value: Value) -> Result<Role, Error> {
        let raw = match coerce_text(ruby, value)? {
            Some(text) => text,
            None => {
                // SAFETY: see ruby_to_canon.
                let class = unsafe { value.classname() }.into_owned();
                return Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "Turn", "InvalidRole"],
                    format!("role must be one of {}, got a {class}", Role::names()),
                ));
            }
        };
        // `InvalidRole`'s `Display` (see `turn.rs`) IS this message; no
        // hand-built duplicate to keep in sync with the pure error type.
        Role::try_from(raw.as_str()).map_err(|invalid| {
            lookup_error(
                ruby,
                &["Lain", "Ext", "Turn", "InvalidRole"],
                invalid.to_string(),
            )
        })
    }

    /// A parent/head digest argument: `nil` (or absent) is a root/empty head, a
    /// String is a digest, anything else is a type error. This is the FFI-in
    /// boundary where a Ruby String becomes a [`Digest`].
    fn read_optional_digest(ruby: &Ruby, value: Option<Value>) -> Result<Option<Digest>, Error> {
        match value {
            None => Ok(None),
            Some(inner) if inner.is_nil() => Ok(None),
            Some(inner) => {
                let string = RString::from_value(inner).ok_or_else(|| {
                    Error::new(
                        ruby.exception_type_error(),
                        "digest must be a String or nil",
                    )
                })?;
                Ok(Some(validated_utf8(ruby, string)?.into()))
            }
        }
    }

    /// A meta argument, defaulting to `{}` when absent or nil.
    fn read_meta(ruby: &Ruby, value: Option<Value>) -> Result<Canon, Error> {
        match value {
            Some(inner) if !inner.is_nil() => ruby_to_canon(ruby, inner),
            _ => Ok(Canon::Object(Vec::new())),
        }
    }

    /// A causal_parents argument: absent or nil is the empty set, otherwise an
    /// Array whose every element is a digest String. Normalization (dedup,
    /// pinned sort order) happens in the pure layer, not here.
    fn read_causal_parents(ruby: &Ruby, value: Option<Value>) -> Result<Vec<Digest>, Error> {
        match value {
            Some(inner) if !inner.is_nil() => {
                let array = RArray::from_value(inner).ok_or_else(|| {
                    Error::new(
                        ruby.exception_type_error(),
                        "causal_parents must be an Array of digest Strings",
                    )
                })?;
                array
                    .into_iter()
                    .map(|element| {
                        let string = RString::from_value(element).ok_or_else(|| {
                            Error::new(
                                ruby.exception_type_error(),
                                "causal_parents must contain only digest Strings",
                            )
                        })?;
                        Ok(Digest::from(validated_utf8(ruby, string)?))
                    })
                    .collect()
            }
            _ => Ok(Vec::new()),
        }
    }

    /// A frozen node of the Timeline DAG, wearing the full Event envelope
    /// (T25's re-port: kind, both parent edges, correlation, and the carried,
    /// content-addressed payload). Holds only an `Arc<EventData>` -- pure
    /// immutable Rust, no Ruby reference -- so once frozen it is honestly
    /// `Ractor.shareable?` with no `mark` and no reachable mutable state.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Turn", free_immediately, frozen_shareable)]
    struct Turn {
        inner: Arc<EventData>,
    }

    impl DataTypeFunctions for Turn {}

    impl PartialEq for Turn {
        fn eq(&self, other: &Self) -> bool {
            self.inner.digest == other.inner.digest
        }
    }

    impl Eq for Turn {}

    impl std::hash::Hash for Turn {
        fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
            self.inner.digest.hash(state);
        }
    }

    impl Turn {
        fn wrap(ruby: &Ruby, inner: Arc<EventData>) -> Obj<Self> {
            let obj = ruby.obj_wrap(Turn { inner });
            obj.freeze();
            obj
        }

        fn new(ruby: &Ruby, kw: RHash) -> Result<Obj<Self>, Error> {
            type OptionalArgs = (Option<Value>, Option<Value>, Option<Value>, Option<Value>);
            let args = get_kwargs::<_, (Value, Value), OptionalArgs, ()>(
                kw,
                &["role", "content"],
                &["parent", "meta", "correlation", "causal_parents"],
            )?;
            let (role_value, content_value) = args.required;
            let (parent_value, meta_value, correlation_value, causal_value) = args.optional;
            let role = read_role(ruby, role_value)?;
            let content = ruby_to_canon(ruby, content_value)?;
            let parent = read_optional_digest(ruby, parent_value)?;
            let meta = read_meta(ruby, meta_value)?;
            let correlation = read_optional_digest(ruby, correlation_value)?;
            let causal_parents = read_causal_parents(ruby, causal_value)?;
            Ok(Turn::wrap(
                ruby,
                EventData::turn(role, content, parent, meta, correlation, causal_parents),
            ))
        }

        /// A carried-body field. The :turn constructor -- the only way this
        /// class is built -- always writes `role`, `content`, and `meta` into
        /// the body, so a miss here is unreachable via the FFI surface; it
        /// raises loudly all the same (`classify_num`'s garbage-arm
        /// philosophy) rather than materializing `nil`.
        fn body_field<'a>(ruby: &Ruby, rb_self: &'a Turn, key: &str) -> Result<&'a Canon, Error> {
            rb_self.inner.body_field(key).ok_or_else(|| {
                Error::new(
                    ruby.exception_runtime_error(),
                    format!("Lain::Ext: a :turn event's carried body must hold {key:?}"),
                )
            })
        }

        fn role(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            match Self::body_field(ruby, rb_self, "role")? {
                Canon::Str(role) => Ok(frozen_str(ruby, role)),
                _ => Err(Error::new(
                    ruby.exception_runtime_error(),
                    "Lain::Ext: a :turn event's role must be a wire string",
                )),
            }
        }

        fn content(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            canon_to_ruby(ruby, Self::body_field(ruby, rb_self, "content")?)
        }

        fn parent(ruby: &Ruby, rb_self: &Turn) -> Value {
            Self::optional_digest_value(ruby, &rb_self.inner.render_parent)
        }

        fn meta(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            canon_to_ruby(ruby, Self::body_field(ruby, rb_self, "meta")?)
        }

        fn digest(ruby: &Ruby, rb_self: &Turn) -> Value {
            frozen_str(ruby, rb_self.inner.digest.as_str())
        }

        fn kind(ruby: &Ruby, rb_self: &Turn) -> Value {
            // A Symbol, matching Ruby `Event#kind` -- the wire string is what
            // the digest hashes; the Symbol is the loud in-process enum.
            ruby.to_symbol(rb_self.inner.kind.as_str()).as_value()
        }

        fn payload_digest(ruby: &Ruby, rb_self: &Turn) -> Value {
            frozen_str(ruby, rb_self.inner.payload.digest.as_str())
        }

        fn correlation(ruby: &Ruby, rb_self: &Turn) -> Value {
            Self::optional_digest_value(ruby, &rb_self.inner.correlation)
        }

        fn causal_parents(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            let array = ruby.ary_new_capa(rb_self.inner.causal_parents.len());
            for digest in &rb_self.inner.causal_parents {
                array.push(frozen_str(ruby, digest.as_str()))?;
            }
            array.freeze();
            Ok(array.as_value())
        }

        fn optional_digest_value(ruby: &Ruby, digest: &Option<Digest>) -> Value {
            match digest {
                Some(digest) => frozen_str(ruby, digest.as_str()),
                None => ruby.qnil().as_value(),
            }
        }

        /// The envelope structure the digest was taken over, as Ruby
        /// `Event#payload` builds it -- rendered from the SAME
        /// `payload_canon()` the digest hashed, so the two cannot drift. One
        /// field is patched on the way through: Ruby's hash holds `kind` as a
        /// SYMBOL (the wire string is what the digest hashes -- Canonical
        /// collapses Symbol/String), and the byte-parity spec compares with
        /// `eq`, where `:turn != "turn"`.
        fn payload(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            let Canon::Object(pairs) = rb_self.inner.payload_canon() else {
                // Unreachable: envelope_canon always builds an object. Loud
                // regardless -- classify_num's garbage-arm philosophy.
                return Err(Error::new(
                    ruby.exception_runtime_error(),
                    "Lain::Ext: the envelope canon must be an object",
                ));
            };
            let hash = ruby.hash_new();
            for (key, value) in &pairs {
                let rendered = if key == "kind" {
                    Self::kind(ruby, rb_self)
                } else {
                    canon_to_ruby(ruby, value)?
                };
                hash.aset(frozen_str(ruby, key), rendered)?;
            }
            hash.freeze();
            Ok(hash.as_value())
        }

        fn root_p(&self) -> bool {
            self.inner.root()
        }

        // to_s is the human-facing projection; inspect keeps the class-tagged,
        // debug-oriented form -- the same convention Ruby's DegradedSet uses.
        // Not a loud site: a debug string must not raise, so an (FFI-
        // unreachable) roleless body renders "?" rather than raising -- the
        // same convention as Timeline#to_s's "(?)" length.
        fn to_s(&self) -> String {
            let digest = self.inner.digest.as_str();
            let prefix = digest.get(..19).unwrap_or(digest);
            format!("{} {prefix}...", self.inner.role_str().unwrap_or("?"))
        }

        fn inspect(&self) -> String {
            format!("#<Lain::Ext::Turn {}>", self.to_s())
        }
    }

    /// An append-only, content-addressed object database over an `rpds` map. The
    /// map is persistent (structural sharing), and the `Mutex` makes concurrent
    /// `put`s safe independently of the GVL. Holds no Ruby reference, so no
    /// `mark`; not shareable, because it is mutable.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Store", free_immediately)]
    struct Store {
        objects: Mutex<dag::StoreMap>,
    }

    impl DataTypeFunctions for Store {}

    impl Store {
        fn new(ruby: &Ruby) -> Obj<Self> {
            ruby.obj_wrap(Store {
                objects: Mutex::new(dag::StoreMap::new_sync()),
            })
        }

        fn locked(&self) -> std::sync::MutexGuard<'_, dag::StoreMap> {
            self.objects
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
        }

        /// Insert a node if its digest is absent, returning the digest. The
        /// address names the content, so a second write is a no-op.
        ///
        /// Deliberately UNvalidated -- this is the internal commit path, not
        /// the public boundary. `Timeline::commit` builds its node's parent
        /// from the committing Timeline's own head, which was validated when
        /// that Timeline was constructed, so the chain is inductively safe.
        /// The Ruby-facing [`Store::put`] wraps this shape with the
        /// referential-integrity check instead of sharing it.
        fn insert_arc(&self, turn: Arc<EventData>) -> Digest {
            let digest = turn.digest.clone();
            let mut map = self.locked();
            if !map.contains_key(&digest) {
                *map = map.insert(digest.clone(), turn);
            }
            digest
        }

        /// Whether the store holds `digest`. Takes a `&Digest` so the internal
        /// callers (`validate_head`) pass one directly; the Ruby-facing `key?`
        /// converts its String argument through this.
        fn contains(&self, digest: &Digest) -> bool {
            self.locked().contains_key(digest)
        }

        /// The public `put` boundary: refuse a node whose parent digest the
        /// store does not hold (see [`super::validate_put`]), then insert.
        /// One lock held across check AND insert -- no TOCTOU window for a
        /// concurrent put. A digest already present skips the check entirely:
        /// the store is append-only and content-addressed, so a re-put is a
        /// no-op and its parent was validated when it first entered.
        fn put(ruby: &Ruby, rb_self: &Store, turn: &Turn) -> Result<String, Error> {
            let digest = turn.inner.digest.clone();
            let mut map = rb_self.locked();
            if !map.contains_key(&digest) {
                validate_put(&map, &turn.inner).map_err(|dangling| {
                    lookup_error(
                        ruby,
                        &["Lain", "Ext", "Store", "MissingObject"],
                        dangling.to_string(),
                    )
                })?;
                *map = map.insert(digest.clone(), Arc::clone(&turn.inner));
            }
            // FFI-out boundary: the digest returns to Ruby as a String.
            Ok(digest.into())
        }

        fn fetch(ruby: &Ruby, rb_self: &Store, digest: String) -> Result<Obj<Turn>, Error> {
            let digest: Digest = digest.into();
            let found = rb_self.locked().get(&digest).map(Arc::clone);
            match found {
                Some(inner) => Ok(Turn::wrap(ruby, inner)),
                None => Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "Store", "MissingObject"],
                    format!("no object {digest:?} in store"),
                )),
            }
        }

        fn key_p(&self, digest: String) -> bool {
            self.contains(&digest.into())
        }

        fn size(&self) -> usize {
            self.locked().size()
        }
    }

    /// An immutable `(head, store)` handle over the DAG. References the Store
    /// Ruby object (hence `mark`), so it is not shareable -- like Ruby's.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Timeline", free_immediately, mark)]
    struct Timeline {
        head: Option<Digest>,
        store: Opaque<Value>,
    }

    impl DataTypeFunctions for Timeline {
        fn mark(&self, marker: &gc::Marker) {
            marker.mark(self.store);
        }
    }

    impl PartialEq for Timeline {
        fn eq(&self, other: &Self) -> bool {
            self.head == other.head
        }
    }

    impl Eq for Timeline {}

    impl std::hash::Hash for Timeline {
        fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
            self.head.hash(state);
        }
    }

    impl Timeline {
        fn wrap(ruby: &Ruby, head: Option<Digest>, store: Value) -> Obj<Self> {
            let obj = ruby.obj_wrap(Timeline {
                head,
                store: store.into(),
            });
            obj.freeze();
            obj
        }

        fn store_value(&self, ruby: &Ruby) -> Value {
            ruby.get_inner(self.store)
        }

        // WHY hand-rolled rather than `scan_args`: this parse's actual
        // contract is "first positional arg, if present, must be a Hash;
        // `expected keyword arguments` otherwise" -- it accepts any
        // Hash-shaped value there, not only Ruby's own keyword-argument
        // calling convention. `scan_args`'s `Kw` machinery parses real
        // keyword args (the VM-tagged kwargs hash) and raises its own,
        // differently-worded errors on a bad shape; routing this site through
        // it risks changing the exact Ruby-observable arity/error text this
        // sweep must not touch (see the card's escalation trigger), for no
        // behavior gain. `rewind`'s single optional positional `Int` has no
        // such ambiguity, so it does take `scan_args` above.
        fn empty(ruby: &Ruby, args: &[Value]) -> Result<Obj<Self>, Error> {
            let store_value = match args.first() {
                None => Store::new(ruby).as_value(),
                Some(first) => {
                    let kw = RHash::from_value(*first).ok_or_else(|| {
                        Error::new(ruby.exception_arg_error(), "expected keyword arguments")
                    })?;
                    let parsed = get_kwargs::<_, (), (Option<Value>,), ()>(kw, &[], &["store"])?;
                    match parsed.optional.0 {
                        Some(store) => store,
                        None => Store::new(ruby).as_value(),
                    }
                }
            };
            // A non-Store store must fail loudly at construction, not on first walk.
            let _: &Store = store_ref(store_value)?;
            Ok(Timeline::wrap(ruby, None, store_value))
        }

        fn empty_p(&self) -> bool {
            self.head.is_none()
        }

        fn head_digest(ruby: &Ruby, rb_self: &Timeline) -> Value {
            match &rb_self.head {
                Some(digest) => frozen_str(ruby, digest.as_str()),
                None => ruby.qnil().as_value(),
            }
        }

        fn store(ruby: &Ruby, rb_self: &Timeline) -> Value {
            rb_self.store_value(ruby)
        }

        fn head(ruby: &Ruby, rb_self: &Timeline) -> Result<Value, Error> {
            match &rb_self.head {
                None => Ok(ruby.qnil().as_value()),
                Some(digest) => {
                    let store: &Store = store_ref(rb_self.store_value(ruby))?;
                    let found = store.locked().get(digest).map(Arc::clone);
                    match found {
                        Some(inner) => Ok(Turn::wrap(ruby, inner).as_value()),
                        None => Err(lookup_error(
                            ruby,
                            &["Lain", "Ext", "Store", "MissingObject"],
                            // `digest: &Digest`, transparent `Debug` -> same bytes.
                            format!("no object {digest:?} in store"),
                        )),
                    }
                }
            }
        }

        fn commit(ruby: &Ruby, rb_self: Obj<Timeline>, kw: RHash) -> Result<Obj<Timeline>, Error> {
            let args = get_kwargs::<_, (Value, Value), (Option<Value>,), ()>(
                kw,
                &["role", "content"],
                &["meta"],
            )?;
            let (role_value, content_value) = args.required;
            let role = read_role(ruby, role_value)?;
            let content = ruby_to_canon(ruby, content_value)?;
            let meta = read_meta(ruby, args.optional.0)?;
            let store_value = rb_self.store_value(ruby);
            let store: &Store = store_ref(store_value)?;
            let correlation = Self::next_correlation(ruby, rb_self.head.as_ref(), store)?;
            let turn = EventData::turn(
                role,
                content,
                rb_self.head.clone(),
                meta,
                correlation,
                Vec::new(),
            );
            let digest = store.insert_arc(turn);
            Ok(Timeline::wrap(ruby, Some(digest), store_value))
        }

        /// The chain identity to stamp on the next turn -- the port of
        /// `Event::ChainWriter.correlation_of` (TL-2: a chain is named by its
        /// root event's digest). The root cannot contain its own address, so
        /// it carries no correlation and every descendant inherits either the
        /// head's correlation or, when the head IS the root, the head's own
        /// digest. `None` only on an empty Timeline, exactly as Ruby's
        /// `head &&` guard. A head digest the store no longer holds is
        /// corruption and raises, the same loud arm every walk has.
        fn next_correlation(
            ruby: &Ruby,
            head: Option<&Digest>,
            store: &Store,
        ) -> Result<Option<Digest>, Error> {
            match head {
                None => Ok(None),
                Some(head_digest) => {
                    let node =
                        store
                            .locked()
                            .get(head_digest)
                            .map(Arc::clone)
                            .ok_or_else(|| {
                                missing_object(ruby, dag::DanglingDigest(head_digest.clone()))
                            })?;
                    Ok(Some(
                        node.correlation
                            .clone()
                            .unwrap_or_else(|| head_digest.clone()),
                    ))
                }
            }
        }

        // `fork` is O(1) because a Timeline handle is already an immutable
        // pointer into the shared, content-addressed Store -- there is no
        // subtree to copy. Returning `rb_self` unchanged IS the fork; the two
        // handles are indistinguishable, and later commits on either diverge
        // from here as ordinary content-addressed writes.
        fn fork(rb_self: Obj<Timeline>) -> Obj<Timeline> {
            rb_self
        }

        fn checkout(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            digest: Value,
        ) -> Result<Obj<Timeline>, Error> {
            let head = read_optional_digest(ruby, Some(digest))?;
            let store_value = rb_self.store_value(ruby);
            let store: &Store = store_ref(store_value)?;
            validate_head(ruby, store, &head)?;
            Ok(Timeline::wrap(ruby, head, store_value))
        }

        fn rewind(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            args: &[Value],
        ) -> Result<Obj<Timeline>, Error> {
            // `scan_args` raises ArgumentError on 2+ positional args where the
            // old hand-rolled parse silently ignored the extras. Deliberate:
            // pure Ruby `Lain::Timeline#rewind(count = 1)` already enforces
            // this arity, so the swallowing was a latent Ruby/Ext divergence
            // -- cross-implementation parity outranks bug-for-bug preservation.
            let parsed = scan_args::<(), (Option<i64>,), (), (), (), ()>(args)?;
            let count = parsed.optional.0.unwrap_or(1);
            let store_value = rb_self.store_value(ruby);
            let store: &Store = store_ref(store_value)?;
            // One locked read for the whole walk, matching dag.rs's own
            // single-locked-read doctrine: re-acquiring the Mutex per step
            // would let another thread's `commit` interleave mid-rewind.
            let digest = {
                let map = store.locked();
                let mut digest = rb_self.head.clone();
                let mut remaining = count;
                while remaining > 0 {
                    // `None` absorbs (rewinding past the root lands on empty,
                    // per Ruby `Timeline#rewind`); a digest that is present but
                    // absent from the store is corruption and raises, distinct
                    // from a root.
                    digest = match digest {
                        None => None,
                        Some(current) => {
                            dag::parent_of(&map, &current).map_err(|e| missing_object(ruby, e))?
                        }
                    };
                    remaining -= 1;
                }
                digest
            };
            // `parent_of` validates the node stepped FROM, never the digest
            // landed ON: landing exactly on a dangle would hand back a poisoned
            // Timeline whose head the store does not hold. Ruby's rewind lands
            // via #checkout, which validates -- so must we, same message form.
            // (A fresh, separate lock: the loop's guard above already dropped,
            // since std's Mutex is not reentrant. The drop-then-relock gap is
            // unobservable from Ruby: between the two locks there is no Ruby
            // dispatch point -- `validate_head` reaches `store.key_p` as a
            // direct Rust call, no funcall/IO/yield -- so this whole method
            // runs as one uninterrupted stretch under the GVL and no other
            // thread's `store.put` can land in between.)
            validate_head(ruby, store, &digest)?;
            Ok(Timeline::wrap(ruby, digest, store_value))
        }

        fn ancestors(ruby: &Ruby, rb_self: &Timeline) -> Result<RArray, Error> {
            let store: &Store = store_ref(rb_self.store_value(ruby))?;
            let arcs = dag::ancestor_turns(&store.locked(), rb_self.head.as_ref())
                .map_err(|e| missing_object(ruby, e))?;
            turns_to_array(ruby, arcs)
        }

        fn to_a(ruby: &Ruby, rb_self: &Timeline) -> Result<RArray, Error> {
            let store: &Store = store_ref(rb_self.store_value(ruby))?;
            let mut arcs = dag::ancestor_turns(&store.locked(), rb_self.head.as_ref())
                .map_err(|e| missing_object(ruby, e))?;
            arcs.reverse();
            turns_to_array(ruby, arcs)
        }

        fn ancestor_digests(ruby: &Ruby, rb_self: &Timeline) -> Result<RArray, Error> {
            let store: &Store = store_ref(rb_self.store_value(ruby))?;
            let digests = dag::ancestor_digests(&store.locked(), rb_self.head.as_ref())
                .map_err(|e| missing_object(ruby, e))?;
            let array = ruby.ary_new_capa(digests.len());
            for digest in digests {
                array.push(frozen_str(ruby, digest.as_str()))?;
            }
            Ok(array)
        }

        fn length(ruby: &Ruby, rb_self: &Timeline) -> Result<usize, Error> {
            let store: &Store = store_ref(rb_self.store_value(ruby))?;
            Ok(dag::ancestor_turns(&store.locked(), rb_self.head.as_ref())
                .map_err(|e| missing_object(ruby, e))?
                .len())
        }

        fn include_p(ruby: &Ruby, rb_self: &Timeline, digest: String) -> Result<bool, Error> {
            let needle: Digest = digest.into();
            let store: &Store = store_ref(rb_self.store_value(ruby))?;
            Ok(dag::ancestor_turns(&store.locked(), rb_self.head.as_ref())
                .map_err(|e| missing_object(ruby, e))?
                .iter()
                .any(|turn| turn.digest == needle))
        }

        fn ancestor_of_p(ruby: &Ruby, rb_self: &Timeline, other: &Timeline) -> Result<bool, Error> {
            ensure_same_store(ruby, rb_self, other)?;
            let store: &Store = store_ref(rb_self.store_value(ruby))?;
            dag::ancestor_of(&store.locked(), rb_self.head.as_ref(), other.head.as_ref())
                .map_err(|e| missing_object(ruby, e))
        }

        fn meet(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            other: &Timeline,
        ) -> Result<Obj<Timeline>, Error> {
            ensure_same_store(ruby, &rb_self, other)?;
            let store_value = rb_self.store_value(ruby);
            let store: &Store = store_ref(store_value)?;
            let common = dag::meet(&store.locked(), rb_self.head.as_ref(), other.head.as_ref())
                .map_err(|e| missing_object(ruby, e))?;
            Ok(Timeline::wrap(ruby, common, store_value))
        }

        fn diverge_at(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            other: &Timeline,
        ) -> Result<Value, Error> {
            ensure_same_store(ruby, &rb_self, other)?;
            let store: &Store = store_ref(rb_self.store_value(ruby))?;
            let common = dag::meet(&store.locked(), rb_self.head.as_ref(), other.head.as_ref())
                .map_err(|e| missing_object(ruby, e))?;
            match common {
                None => Ok(ruby.qnil().as_value()),
                // `dag::meet` only ever returns a digest it found walking the
                // store's own ancestor chains (see `dag.rs`), so this second
                // lookup cannot miss for any well-formed Store. Post-T1 that
                // is exactly the shape a walk must not shrug off as `nil`: a
                // miss here means the Store mutated between the two locked
                // reads (or is corrupt in a way `meet` itself didn't catch),
                // and `Store::MissingObject` is the same loud answer every
                // other dangling-digest site in this module gives, not a
                // second, silent failure mode of its own.
                Some(digest) => {
                    let inner =
                        store.locked().get(&digest).map(Arc::clone).ok_or_else(|| {
                            missing_object(ruby, dag::DanglingDigest(digest.clone()))
                        })?;
                    Ok(Turn::wrap(ruby, inner).as_value())
                }
            }
        }

        // to_s is the human-facing projection; inspect keeps the class-tagged,
        // debug-oriented form -- the same convention Ruby's DegradedSet uses.
        fn to_s(ruby: &Ruby, rb_self: &Timeline) -> String {
            match &rb_self.head {
                None => "empty".to_string(),
                Some(digest) => {
                    let text = digest.as_str();
                    let prefix = text.get(..19).unwrap_or(text);
                    // `to_s`/`inspect` is not a loud walk site: a debug string
                    // must not raise. But a corrupt chain's length is unknowable,
                    // not zero, so it renders as `(?)` rather than a false `(0)`.
                    let length = store_ref(rb_self.store_value(ruby))
                        .ok()
                        .and_then(|store: &Store| {
                            dag::ancestor_turns(&store.locked(), Some(digest)).ok()
                        })
                        .map(|arcs| arcs.len().to_string())
                        .unwrap_or_else(|| "?".to_string());
                    format!("{prefix}... ({length})")
                }
            }
        }

        fn inspect(ruby: &Ruby, rb_self: &Timeline) -> String {
            format!("#<Lain::Ext::Timeline {}>", Self::to_s(ruby, rb_self))
        }
    }

    /// One FFI crossing for a whole chain: wrap each already-walked node into a
    /// frozen `Turn` handle and hand back a single Ruby Array.
    fn turns_to_array(ruby: &Ruby, arcs: Vec<Arc<EventData>>) -> Result<RArray, Error> {
        let array = ruby.ary_new_capa(arcs.len());
        for arc in arcs {
            array.push(Turn::wrap(ruby, arc))?;
        }
        Ok(array)
    }

    /// Raise `Store::MissingObject` unless `head` (when not a root/empty `None`)
    /// names an object the store holds. This is the landed-head validation both
    /// `checkout` and `rewind` perform before wrapping a Timeline, exactly as
    /// every Ruby Timeline lands through `Timeline#initialize`'s check.
    ///
    /// Deliberately tail-less ("... in store" omitted): this mirrors Ruby
    /// `Timeline#initialize` (lib/lain/timeline.rb), whose message is
    /// `no object #{digest.inspect}`, NOT `Store#fetch`'s longer form. The two
    /// Ruby sites differ, so the Ext sites match them per-site rather than
    /// unifying.
    fn validate_head(ruby: &Ruby, store: &Store, head: &Option<Digest>) -> Result<(), Error> {
        match head {
            // `store.contains` takes a `&Digest` directly -- no round-trip
            // through a String. `{target:?}` is transparent, so the message is
            // byte-identical to Ruby `Timeline#initialize`'s.
            Some(target) if !store.contains(target) => Err(lookup_error(
                ruby,
                &["Lain", "Ext", "Store", "MissingObject"],
                format!("no object {target:?}"),
            )),
            _ => Ok(()),
        }
    }

    /// Raise `Timeline::CrossStore` unless both Timelines name the SAME Store
    /// object. A `Store` defines no `==`, so Ruby `==` is `BasicObject`'s object
    /// identity -- exactly Ruby's `store.equal?(other.store)`. Named for what it
    /// does (raises), not merely what it checks -- every call site treats a
    /// return as "safe to proceed", never inspects an `Ok`/`Err` distinction by
    /// hand.
    ///
    /// WHY `unwrap_or(false)` here is safe (unlike `ruby_to_canon`'s equal
    /// checks): both operands are `Lain::Ext::Store` handles this crate wraps,
    /// not an arbitrary caller-supplied value, and the class defines no `==`
    /// override that could raise -- Ruby's own default is the C-level
    /// `rb_obj_equal` identity check, which cannot raise. Swallowing a
    /// hypothetical error here would only widen a `false` from "definitely
    /// different" to "different-or-erroring", and the fallthrough (`CrossStore`)
    /// is the correct outcome either way.
    fn ensure_same_store(ruby: &Ruby, a: &Timeline, b: &Timeline) -> Result<(), Error> {
        let same = a
            .store_value(ruby)
            .equal(b.store_value(ruby))
            .unwrap_or(false);
        if same {
            Ok(())
        } else {
            Err(lookup_error(
                ruby,
                &["Lain", "Ext", "Timeline", "CrossStore"],
                "cannot compare Timelines backed by different stores".to_string(),
            ))
        }
    }

    /// A String or Symbol id/text field of a build pair, coerced to UTF-8. Ids
    /// arrive as Ruby Strings (a memory item's id); Symbols are accepted for the
    /// same reason `read_role` accepts them. Anything else is a loud type error.
    fn read_pair_field(ruby: &Ruby, value: Value, what: &str) -> Result<String, Error> {
        match coerce_text(ruby, value)? {
            Some(text) => Ok(text),
            None => {
                // SAFETY: see ruby_to_canon; no Ruby code runs meanwhile.
                let class = unsafe { value.classname() }.into_owned();
                Err(Error::new(
                    ruby.exception_type_error(),
                    format!("{what} must be a String or Symbol, got a {class}"),
                ))
            }
        }
    }

    /// A frozen, immutable BM25 index. Wraps only `Arc<crate::bm25::Bm25Index>`
    /// -- no reachable Ruby object and, per the interior-mutability audit in
    /// `bm25.rs`, no `Cell`/`RefCell`/`Mutex`/lazy cache in any crate type it
    /// reaches (the one such source, the `cached`-memoized default tokenizer, is
    /// feature-disabled) -- so `frozen_shareable` is honest once frozen, exactly
    /// as it is for `Turn`.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Bm25", free_immediately, frozen_shareable)]
    struct Bm25 {
        inner: Arc<crate::bm25::Bm25Index>,
    }

    impl DataTypeFunctions for Bm25 {}

    impl Bm25 {
        fn wrap(ruby: &Ruby, inner: Arc<crate::bm25::Bm25Index>) -> Obj<Self> {
            let obj = ruby.obj_wrap(Bm25 { inner });
            obj.freeze();
            obj
        }

        /// `Lain::Ext::Bm25.build(pairs)` -- one batch crossing of the FFI
        /// boundary. `pairs` is an Array of `[id, text]` two-element Arrays.
        /// Degenerate batches raise the named `Bm25::EmptyCorpus` /
        /// `Bm25::DuplicateId` errors from the pure builder.
        fn build(ruby: &Ruby, pairs: RArray) -> Result<Obj<Self>, Error> {
            let mut batch: Vec<(String, String)> = Vec::with_capacity(pairs.len());
            for pair_value in pairs.into_iter() {
                let pair = RArray::from_value(pair_value).ok_or_else(|| {
                    Error::new(
                        ruby.exception_type_error(),
                        "each pair must be a [id, text] Array",
                    )
                })?;
                if pair.len() != 2 {
                    return Err(Error::new(
                        ruby.exception_arg_error(),
                        format!("each pair must be [id, text], got {} elements", pair.len()),
                    ));
                }
                let id = read_pair_field(ruby, pair.entry(0)?, "id")?;
                let text = read_pair_field(ruby, pair.entry(1)?, "text")?;
                batch.push((id, text));
            }
            // `BuildError`'s `Display` (see `bm25.rs`) IS the FFI-visible
            // message for both variants; no hand-built duplicate to drift.
            match crate::bm25::Bm25Index::build(batch) {
                Ok(index) => Ok(Bm25::wrap(ruby, Arc::new(index))),
                Err(err @ crate::bm25::BuildError::EmptyCorpus) => Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "Bm25", "EmptyCorpus"],
                    err.to_string(),
                )),
                Err(err @ crate::bm25::BuildError::DuplicateId(_)) => Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "Bm25", "DuplicateId"],
                    err.to_string(),
                )),
            }
        }

        /// `#search(query, k)` -> up to `k` `[id, score, matched_tokens]` triples,
        /// ranked by descending score with insertion-order tie-breaking. One FFI
        /// crossing: the whole ranked result is built into a single frozen Array.
        fn search(ruby: &Ruby, rb_self: &Bm25, query: String, k: usize) -> Result<RArray, Error> {
            let hits = rb_self.inner.search(&query, k);
            let out = ruby.ary_new_capa(hits.len());
            for (id, score, matched) in hits {
                let triple = ruby.ary_new_capa(3);
                triple.push(frozen_str(ruby, &id))?;
                triple.push(ruby.float_from_f64(f64::from(score)))?;
                let tokens = ruby.ary_new_capa(matched.len());
                for token in matched {
                    tokens.push(frozen_str(ruby, &token))?;
                }
                tokens.freeze();
                triple.push(tokens.as_value())?;
                triple.freeze();
                out.push(triple)?;
            }
            Ok(out)
        }
    }

    #[magnus::init]
    fn init(ruby: &Ruby) -> Result<(), Error> {
        let module = ruby.define_module("Lain")?;
        module.define_singleton_method("hello", function!(hello, 1))?;

        let ext = module.define_module("Ext")?;
        ext.define_singleton_method("init_tracing", function!(init_tracing, 2))?;
        ext.define_singleton_method("blake3_hex", function!(ffi_blake3_hex, 1))?;
        ext.define_singleton_method("canonical_dump", function!(canonical_dump, 1))?;
        ext.define_singleton_method("canonical_digest", function!(canonical_digest, 1))?;

        let share_probe = ext.define_class("ShareProbe", ruby.class_object())?;
        share_probe.define_singleton_method("new", function!(ShareProbe::new, 1))?;
        share_probe.define_method("value", method!(ShareProbe::value, 0))?;

        // Subclass Lain::Error, which `lib/lain.rb` requires before this
        // extension loads (see `lain/error`, then `lain/lain`). No fallback to
        // StandardError: a load-order regression that broke that ordering must
        // fail loudly, here, at require time -- not re-parent every Ext error
        // under a class none of Lain's `rescue Lain::Error` sites catch.
        let lain_error = ruby
            .class_object()
            .const_get::<_, RModule>("Lain")
            .and_then(|m| m.const_get::<_, ExceptionClass>("Error"))?;

        let bm25 = ext.define_class("Bm25", ruby.class_object())?;
        bm25.define_error("EmptyCorpus", lain_error)?;
        bm25.define_error("DuplicateId", lain_error)?;
        bm25.define_singleton_method("build", function!(Bm25::build, 1))?;
        bm25.define_method("search", method!(Bm25::search, 2))?;

        // Stateless structural search: no wrapped handle, so `AstGrep` is a bare
        // class with two singleton methods and one named error. `BadPattern`
        // subclasses `Lain::Error` like every other Ext error (see the Bm25 block
        // for why no fallback). The FFI wrappers live in `astgrep::ffi`.
        let astgrep = ext.define_class("AstGrep", ruby.class_object())?;
        astgrep.define_error("BadPattern", lain_error)?;
        astgrep.define_singleton_method("search", function!(crate::astgrep::ffi::search, 3))?;
        astgrep.define_singleton_method("dump", function!(crate::astgrep::ffi::dump, 2))?;

        let turn = ext.define_class("Turn", ruby.class_object())?;
        turn.define_error("InvalidRole", lain_error)?;
        turn.define_singleton_method("new", function!(Turn::new, 1))?;
        turn.define_method("role", method!(Turn::role, 0))?;
        turn.define_method("content", method!(Turn::content, 0))?;
        turn.define_method("parent", method!(Turn::parent, 0))?;
        // The render chain is the first-parent walk, so `parent` IS the render
        // edge -- both names answer it, as Ruby's `alias parent render_parent`.
        turn.define_method("render_parent", method!(Turn::parent, 0))?;
        turn.define_method("meta", method!(Turn::meta, 0))?;
        turn.define_method("digest", method!(Turn::digest, 0))?;
        turn.define_method("kind", method!(Turn::kind, 0))?;
        turn.define_method("payload_digest", method!(Turn::payload_digest, 0))?;
        turn.define_method("correlation", method!(Turn::correlation, 0))?;
        turn.define_method("causal_parents", method!(Turn::causal_parents, 0))?;
        turn.define_method("payload", method!(Turn::payload, 0))?;
        turn.define_method("root?", method!(Turn::root_p, 0))?;
        turn.define_method("==", method!(<Turn as typed_data::IsEql>::is_eql, 1))?;
        turn.define_method("eql?", method!(<Turn as typed_data::IsEql>::is_eql, 1))?;
        turn.define_method("hash", method!(<Turn as typed_data::Hash>::hash, 0))?;
        turn.define_method("to_s", method!(Turn::to_s, 0))?;
        turn.define_method("inspect", method!(Turn::inspect, 0))?;

        let store = ext.define_class("Store", ruby.class_object())?;
        store.define_error("MissingObject", lain_error)?;
        store.define_singleton_method("new", function!(Store::new, 0))?;
        store.define_method("put", method!(Store::put, 1))?;
        store.define_method("fetch", method!(Store::fetch, 1))?;
        store.define_method("key?", method!(Store::key_p, 1))?;
        store.define_method("size", method!(Store::size, 0))?;

        let timeline = ext.define_class("Timeline", ruby.class_object())?;
        timeline.define_error("CrossStore", lain_error)?;
        timeline.define_singleton_method("empty", function!(Timeline::empty, -1))?;
        timeline.define_method("empty?", method!(Timeline::empty_p, 0))?;
        timeline.define_method("head", method!(Timeline::head, 0))?;
        timeline.define_method("head_digest", method!(Timeline::head_digest, 0))?;
        timeline.define_method("store", method!(Timeline::store, 0))?;
        timeline.define_method("commit", method!(Timeline::commit, 1))?;
        timeline.define_method("fork", method!(Timeline::fork, 0))?;
        timeline.define_method("checkout", method!(Timeline::checkout, 1))?;
        timeline.define_method("rewind", method!(Timeline::rewind, -1))?;
        timeline.define_method("ancestors", method!(Timeline::ancestors, 0))?;
        timeline.define_method("ancestor_digests", method!(Timeline::ancestor_digests, 0))?;
        timeline.define_method("to_a", method!(Timeline::to_a, 0))?;
        timeline.define_method("length", method!(Timeline::length, 0))?;
        timeline.define_method("include?", method!(Timeline::include_p, 1))?;
        timeline.define_method("ancestor_of?", method!(Timeline::ancestor_of_p, 1))?;
        timeline.define_method("meet", method!(Timeline::meet, 1))?;
        timeline.define_method("&", method!(Timeline::meet, 1))?;
        timeline.define_method("diverge_at", method!(Timeline::diverge_at, 1))?;
        timeline.define_method("==", method!(<Timeline as typed_data::IsEql>::is_eql, 1))?;
        timeline.define_method("eql?", method!(<Timeline as typed_data::IsEql>::is_eql, 1))?;
        timeline.define_method("hash", method!(<Timeline as typed_data::Hash>::hash, 0))?;
        timeline.define_method("to_s", method!(Timeline::to_s, 0))?;
        timeline.define_method("inspect", method!(Timeline::inspect, 0))?;

        Ok(())
    }
}

#[cfg(test)]
mod num_class_tests {
    use super::{NumClass, classify_num};

    #[test]
    fn classifies_a_small_integer() {
        assert_eq!(classify_num("1").unwrap(), NumClass::Small(1));
    }

    #[test]
    fn classifies_a_negative_integer() {
        assert_eq!(classify_num("-3").unwrap(), NumClass::Small(-3));
    }

    #[test]
    fn classifies_decimal_float_text() {
        assert_eq!(classify_num("1.5").unwrap(), NumClass::Float(1.5));
    }

    #[test]
    fn classifies_exponent_float_text() {
        assert_eq!(classify_num("2e10").unwrap(), NumClass::Float(2e10));
    }

    #[test]
    fn classifies_a_bignum_beyond_i64() {
        // i64::MAX is 9223372036854775807; one digit further overflows it.
        assert_eq!(classify_num("99999999999999999999").unwrap(), NumClass::Big);
    }

    #[test]
    fn classifies_a_negative_bignum_beyond_i64() {
        assert_eq!(
            classify_num("-99999999999999999999").unwrap(),
            NumClass::Big
        );
    }

    #[test]
    fn rejects_non_numeric_garbage() {
        let err = classify_num("abc").expect_err("garbage text must not classify");
        assert!(err.contains("abc"), "unexpected message: {err}");
    }

    #[test]
    fn rejects_empty_text() {
        classify_num("").expect_err("empty text must not classify");
    }

    #[test]
    fn rejects_malformed_float_text() {
        // Contains '.' so it takes the float branch, but is not valid float text.
        let err = classify_num("1.2.3").expect_err("malformed float text must not classify");
        assert!(err.contains("1.2.3"), "unexpected message: {err}");
    }

    #[test]
    fn rejects_bare_sign_text() {
        classify_num("-").expect_err("a lone sign must not classify as a bignum");
    }
}

#[cfg(test)]
mod validate_put_tests {
    use super::{DanglingPut, validate_put};
    use crate::canonical::{Canon, build_object};
    use crate::dag::StoreMap;
    use crate::digest::Digest;
    use crate::event::{EventData, Role};
    use std::sync::Arc;

    fn text(body: &str) -> Canon {
        Canon::Array(vec![Canon::Object(
            build_object(vec![("text".to_string(), Canon::Str(body.to_string()))]).unwrap(),
        )])
    }

    fn node(body: &str, parent: Option<&Digest>) -> Arc<EventData> {
        EventData::turn(
            Role::User,
            text(body),
            parent.cloned(),
            Canon::Object(vec![]),
            None,
            Vec::new(),
        )
    }

    #[test]
    fn accepts_a_root() {
        assert_eq!(
            validate_put(&StoreMap::new_sync(), &node("a", None)),
            Ok(())
        );
    }

    #[test]
    fn accepts_a_child_whose_parent_is_present() {
        let root = node("a", None);
        let map = StoreMap::new_sync().insert(root.digest.clone(), Arc::clone(&root));
        assert_eq!(validate_put(&map, &node("b", Some(&root.digest))), Ok(()));
    }

    #[test]
    fn refuses_a_child_whose_parent_is_absent() {
        let absent = Digest::from("blake3:absent".to_string());
        let child = node("b", Some(&absent));
        assert_eq!(
            validate_put(&StoreMap::new_sync(), &child),
            Err(DanglingPut {
                parent: absent,
                child: child.digest.clone(),
            })
        );
    }

    // The causal set is a Store edge exactly as the render edge is (Ruby
    // `Store#parent_edges`); the refusal names the FIRST dangling edge, and
    // causal parents check in their pinned sorted order.
    #[test]
    fn refuses_a_child_whose_causal_parent_is_absent() {
        let root = node("a", None);
        let map = StoreMap::new_sync().insert(root.digest.clone(), Arc::clone(&root));
        let child = EventData::turn(
            Role::User,
            text("b"),
            Some(root.digest.clone()),
            Canon::Object(vec![]),
            None,
            vec![
                Digest::from("blake3:msg-b".to_string()),
                Digest::from("blake3:msg-a".to_string()),
            ],
        );
        assert_eq!(
            validate_put(&map, &child),
            Err(DanglingPut {
                parent: Digest::from("blake3:msg-a".to_string()),
                child: child.digest.clone(),
            })
        );
    }

    // The Display IS the FFI-visible message; Ruby `Store#put` pins the same
    // bytes (`no object #{parent.inspect} in store: putting #{digest.inspect}
    // would dangle`), and `Digest`'s transparent `Debug` is what keeps the two
    // byte-identical for plain digests.
    #[test]
    fn dangling_put_message_matches_ruby_string_inspect() {
        let child = node("b", Some(&Digest::from("blake3:absent".to_string())));
        let message = validate_put(&StoreMap::new_sync(), &child)
            .unwrap_err()
            .to_string();
        assert_eq!(
            message,
            format!(
                r#"no object "blake3:absent" in store: putting "{}" would dangle"#,
                child.digest
            )
        );
    }
}

#[cfg(test)]
mod tests {
    use super::build_env_filter;

    #[test]
    fn parses_bare_level() {
        let filter = build_env_filter("debug").expect("bare level should parse");
        assert_eq!(filter.to_string(), "debug");
    }

    #[test]
    fn parses_targeted_directive() {
        // A per-target directive plus a global fallback should parse.
        build_env_filter("lain=trace,warn").expect("targeted directive should parse");
    }

    #[test]
    fn rejects_empty_level() {
        let err = build_env_filter("   ").expect_err("blank level must be rejected");
        assert!(
            err.contains("must not be empty"),
            "unexpected message: {err}"
        );
    }

    #[test]
    fn rejects_invalid_level() {
        // A target with a non-existent level name is an invalid directive.
        let err = build_env_filter("lain=notalevel").expect_err("invalid level must be rejected");
        assert!(
            err.contains("invalid log level"),
            "unexpected message: {err}"
        );
    }
}

#[cfg(test)]
mod blake3_tests {
    use super::blake3_hex;

    // Official BLAKE3 test vector for the empty input.
    #[test]
    fn hashes_the_empty_string() {
        assert_eq!(
            blake3_hex(b""),
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        );
    }

    // Official BLAKE3 test vector for a 1024-byte input -- the first size that
    // spans more than one 1024-byte chunk boundary, so it exercises the tree
    // hashing the empty-string vector never reaches. Real canonical dumps easily
    // exceed one chunk. Input is byte `i % 251`; the expected digest was checked
    // independently with `b3sum`.
    #[test]
    fn hashes_a_multi_chunk_input() {
        let input: Vec<u8> = (0..1024).map(|i| (i % 251) as u8).collect();
        assert_eq!(
            blake3_hex(&input),
            "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"
        );
    }

    #[test]
    fn is_deterministic() {
        assert_eq!(blake3_hex(b"lain"), blake3_hex(b"lain"));
    }

    #[test]
    fn differs_for_different_input() {
        assert_ne!(blake3_hex(b"lain"), blake3_hex(b"not lain"));
    }

    #[test]
    fn returns_lowercase_hex() {
        let hex = blake3_hex(b"lain");
        assert_eq!(hex, hex.to_lowercase());
        assert_eq!(hex.len(), 64);
    }
}

#[cfg(all(test, unix))]
mod dup_tests {
    use super::dup_writer;
    use std::io::{Read, Seek, SeekFrom, Write};
    use std::os::unix::io::AsRawFd;

    /// The core output-discipline invariant, provable without a Ruby VM:
    /// dropping the writer we hand to `tracing` must NOT close the caller's fd.
    #[test]
    fn dup_writer_leaves_the_original_fd_open() {
        let path = std::env::temp_dir().join(format!("lain-dup-writer-{}.log", std::process::id()));
        let mut original = std::fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(true)
            .open(&path)
            .expect("open temp file");

        // Hand a dup of the caller's fd to the subscriber-side writer, use it,
        // then drop it. Only the dup's descriptor is closed.
        {
            let mut duped = dup_writer(original.as_raw_fd()).expect("dup should succeed");
            writeln!(duped, "from-dup").expect("write through dup");
            duped.flush().unwrap();
        }

        // If `dup_writer` had wrapped the original fd directly, it would now be
        // closed and this write would fail with EBADF. It must still work.
        writeln!(original, "from-original").expect("original fd must survive the dup drop");
        original.flush().unwrap();

        original.seek(SeekFrom::Start(0)).unwrap();
        let mut contents = String::new();
        original.read_to_string(&mut contents).unwrap();
        std::fs::remove_file(&path).ok();

        assert!(
            contents.contains("from-dup"),
            "missing dup write: {contents:?}"
        );
        assert!(
            contents.contains("from-original"),
            "original fd was closed by the dup drop: {contents:?}"
        );
    }

    #[test]
    fn dup_writer_rejects_a_bad_fd() {
        let err = dup_writer(-1).expect_err("dup(-1) must fail");
        assert!(
            err.raw_os_error().is_some(),
            "expected an OS error, got {err:?}"
        );
    }
}
