#![deny(clippy::print_stdout, clippy::print_stderr)]
//! Output discipline is enforced at the crate root: `print_stdout` /
//! `print_stderr` are hard errors so no Rust code here can smear plain text
//! onto a stream the Ruby-side Journal may be parsing as NDJSON. Diagnostics go
//! through `tracing`, whose writer is a caller-supplied fd (see
//! [`ffi::init_tracing`]).

use tracing_subscriber::EnvFilter;

mod canonical;
mod dag;
mod turn;

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
    use super::{blake3_hex, build_env_filter, dup_writer};
    use crate::canonical::{self, Canon};
    use crate::dag;
    use crate::turn::{self, TurnData};
    use magnus::{
        function, gc, method,
        prelude::*,
        r_hash::ForEach,
        scan_args::get_kwargs,
        typed_data::{self, Obj},
        value::Opaque,
        DataTypeFunctions, Error, ExceptionClass, Float, Integer, RArray, RClass, RHash, RModule,
        RString, Ruby, Symbol, TryConvert, TypedData, Value,
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
        fn file(&self) -> std::sync::MutexGuard<'_, std::fs::File> {
            self.0
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
        }
    }

    impl Write for SharedWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.file().write(buf)
        }

        /// Overridden deliberately. The default `write_all` loops over `write`,
        /// re-acquiring the mutex on each partial write -- so a second thread
        /// could slip a whole event between two fragments of this one. Regular
        /// files seldom write partially, but stderr is typically a pipe or tty,
        /// where they do. Holding the lock across the entire buffer is what
        /// actually keeps one event on one NDJSON line.
        fn write_all(&mut self, buf: &[u8]) -> std::io::Result<()> {
            self.file().write_all(buf)
        }

        fn flush(&mut self) -> std::io::Result<()> {
            self.file().flush()
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

    /// Build the `Lain::Canonical::<name>` exception with `message`. Looked up at
    /// raise-time (not ext-init) because `canonical.rb` defines these classes
    /// after it requires this extension. A lookup failure surfaces as the
    /// underlying `NameError` rather than being swallowed.
    fn canonical_error(ruby: &Ruby, name: &str, message: String) -> Error {
        let class = ruby
            .class_object()
            .const_get::<_, RModule>("Lain")
            .and_then(|m| m.const_get::<_, RModule>("Canonical"))
            .and_then(|m| m.const_get::<_, magnus::ExceptionClass>(name));
        match class {
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
        if value.is_nil() {
            Ok(Canon::Null)
        } else if value.equal(ruby.qtrue()).unwrap_or(false) {
            Ok(Canon::Bool(true))
        } else if value.equal(ruby.qfalse()).unwrap_or(false) {
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
            Err(canonical_error(
                ruby,
                "UnsupportedType",
                format!("cannot canonicalize {class}"),
            ))
        }
    }

    fn canon_float(ruby: &Ruby, float: Float, value: Value) -> Result<Canon, Error> {
        // JSON has no NaN/Infinity; a hash over one would not round-trip. Checked
        // before rendering so the error is `NonFiniteFloat`, not JSON's own.
        if !float.to_f64().is_finite() {
            return Err(canonical_error(
                ruby,
                "NonFiniteFloat",
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
        let object = canonical::build_object(pairs)
            .map_err(|ambiguous| canonical_error(ruby, "AmbiguousKey", ambiguous.message()))?;
        Ok(Canon::Object(object))
    }

    fn canon_key(ruby: &Ruby, key: Value) -> Result<String, Error> {
        if let Some(text) = coerce_text(ruby, key)? {
            Ok(text)
        } else {
            // SAFETY: see `ruby_to_canon`.
            let class = unsafe { key.classname() }.into_owned();
            Err(canonical_error(
                ruby,
                "UnsupportedType",
                format!("hash keys must be String or Symbol, got {class}"),
            ))
        }
    }

    /// A validated UTF-8 `String`, transcoding from the string's own encoding
    /// exactly as `Canonical#utf8` does: `RString::to_string` takes the valid
    /// UTF-8 fast path or `rb_str_conv_enc`, and errors on bytes that are not
    /// convertible -- which is precisely when Ruby raises.
    fn utf8(ruby: &Ruby, string: RString) -> Result<String, Error> {
        string.to_string().map_err(|_| {
            canonical_error(
                ruby,
                "UnsupportedType",
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
            Ok(Some(utf8(ruby, string)?))
        } else if let Some(symbol) = Symbol::from_value(value) {
            Ok(Some(utf8(ruby, symbol.funcall("to_s", ())?)?))
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
    // `Turn` holds only immutable Rust state (an `Arc<TurnData>`: no reachable
    // Ruby object), so `frozen_shareable` is honest once the handle is frozen.
    // `Timeline` is the one handle that references a Ruby object (its `Store`),
    // so it marks that reference and is deliberately NOT frozen_shareable --
    // exactly as the Ruby `Timeline`, a frozen value over a mutable Store, is
    // itself not `Ractor.shareable?`.
    // -----------------------------------------------------------------------

    /// Build a `Lain::Ext::<class>::<error>` exception with `message`. Looked up
    /// at raise-time; a lookup failure surfaces as the underlying `NameError`.
    fn ext_error(ruby: &Ruby, class_name: &str, error_name: &str, message: String) -> Error {
        let looked = ruby
            .class_object()
            .const_get::<_, RModule>("Lain")
            .and_then(|m| m.const_get::<_, RModule>("Ext"))
            .and_then(|m| m.const_get::<_, RClass>(class_name))
            .and_then(|c| c.const_get::<_, ExceptionClass>(error_name));
        match looked {
            Ok(exception) => Error::new(exception, message),
            Err(lookup_failure) => lookup_failure,
        }
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
    fn canon_to_ruby(ruby: &Ruby, canon: &Canon) -> Value {
        match canon {
            Canon::Null => ruby.qnil().as_value(),
            Canon::Bool(true) => ruby.qtrue().as_value(),
            Canon::Bool(false) => ruby.qfalse().as_value(),
            Canon::Num(text) => num_to_ruby(ruby, text),
            Canon::Str(text) => frozen_str(ruby, text),
            Canon::Array(items) => {
                let array = ruby.ary_new_capa(items.len());
                for item in items {
                    // Pushing to a fresh, un-shared array cannot fail.
                    let _ = array.push(canon_to_ruby(ruby, item));
                }
                array.freeze();
                array.as_value()
            }
            Canon::Object(pairs) => {
                let hash = ruby.hash_new();
                for (key, value) in pairs {
                    let _ = hash.aset(frozen_str(ruby, key), canon_to_ruby(ruby, value));
                }
                hash.freeze();
                hash.as_value()
            }
        }
    }

    /// Rebuild the Ruby number a [`Canon::Num`] text denotes. A JSON float always
    /// carries `.`, `e`, or `E`; an integer never does -- so the text alone says
    /// which. Bignums round-trip through Ruby's own parser to keep arbitrary
    /// precision. The fallbacks are unreachable for text produced by the reader.
    fn num_to_ruby(ruby: &Ruby, text: &str) -> Value {
        if text.contains(['.', 'e', 'E']) {
            ruby.float_from_f64(text.parse::<f64>().unwrap_or(f64::NAN))
                .as_value()
        } else if let Ok(small) = text.parse::<i64>() {
            ruby.integer_from_i64(small).as_value()
        } else {
            ruby.str_new(text)
                .funcall("to_i", ())
                .unwrap_or_else(|_| ruby.qnil().as_value())
        }
    }

    /// Read a role argument (String or Symbol) and validate it, raising
    /// `Turn::InvalidRole` on anything that is not a wire role.
    fn read_role(ruby: &Ruby, value: Value) -> Result<String, Error> {
        let raw = match coerce_text(ruby, value)? {
            Some(text) => text,
            None => {
                // SAFETY: see ruby_to_canon.
                let class = unsafe { value.classname() }.into_owned();
                return Err(ext_error(
                    ruby,
                    "Turn",
                    "InvalidRole",
                    format!(
                        "role must be one of {}, got a {class}",
                        turn::ROLES.join(", ")
                    ),
                ));
            }
        };
        turn::validate_role(&raw).map_err(|invalid| {
            ext_error(
                ruby,
                "Turn",
                "InvalidRole",
                format!(
                    "role must be one of {}, got {:?}",
                    turn::ROLES.join(", "),
                    invalid.0
                ),
            )
        })
    }

    /// A parent/head digest argument: `nil` (or absent) is a root/empty head, a
    /// String is a digest, anything else is a type error.
    fn read_optional_digest(ruby: &Ruby, value: Option<Value>) -> Result<Option<String>, Error> {
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
                Ok(Some(utf8(ruby, string)?))
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

    /// A frozen node of the Timeline DAG. Holds only an `Arc<TurnData>` -- pure
    /// immutable Rust, no Ruby reference -- so once frozen it is honestly
    /// `Ractor.shareable?` with no `mark` and no reachable mutable state.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Turn", free_immediately, frozen_shareable)]
    struct Turn {
        inner: Arc<TurnData>,
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
        fn wrap(ruby: &Ruby, inner: Arc<TurnData>) -> Obj<Self> {
            let obj = ruby.obj_wrap(Turn { inner });
            obj.freeze();
            obj
        }

        fn new(ruby: &Ruby, kw: RHash) -> Result<Obj<Self>, Error> {
            let args = get_kwargs::<_, (Value, Value), (Option<Value>, Option<Value>), ()>(
                kw,
                &["role", "content"],
                &["parent", "meta"],
            )?;
            let (role_value, content_value) = args.required;
            let (parent_value, meta_value) = args.optional;
            let role = read_role(ruby, role_value)?;
            let content = ruby_to_canon(ruby, content_value)?;
            let parent = read_optional_digest(ruby, parent_value)?;
            let meta = read_meta(ruby, meta_value)?;
            Ok(Turn::wrap(ruby, TurnData::new(role, content, parent, meta)))
        }

        fn role(ruby: &Ruby, rb_self: &Turn) -> Value {
            frozen_str(ruby, &rb_self.inner.role)
        }

        fn content(ruby: &Ruby, rb_self: &Turn) -> Value {
            canon_to_ruby(ruby, &rb_self.inner.content)
        }

        fn parent(ruby: &Ruby, rb_self: &Turn) -> Value {
            match &rb_self.inner.parent {
                Some(digest) => frozen_str(ruby, digest),
                None => ruby.qnil().as_value(),
            }
        }

        fn meta(ruby: &Ruby, rb_self: &Turn) -> Value {
            canon_to_ruby(ruby, &rb_self.inner.meta)
        }

        fn digest(ruby: &Ruby, rb_self: &Turn) -> Value {
            frozen_str(ruby, &rb_self.inner.digest)
        }

        fn payload(ruby: &Ruby, rb_self: &Turn) -> Value {
            canon_to_ruby(ruby, &rb_self.inner.payload_canon())
        }

        fn root_p(&self) -> bool {
            self.inner.root()
        }

        fn to_s(&self) -> String {
            let digest = &self.inner.digest;
            let prefix = digest.get(..19).unwrap_or(digest);
            format!("#<Lain::Ext::Turn {} {prefix}...>", self.inner.role)
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
        fn insert_arc(&self, turn: Arc<TurnData>) -> String {
            let digest = turn.digest.clone();
            let mut map = self.locked();
            if !map.contains_key(&digest) {
                *map = map.insert(digest.clone(), turn);
            }
            digest
        }

        fn put(&self, turn: &Turn) -> String {
            self.insert_arc(Arc::clone(&turn.inner))
        }

        fn fetch(ruby: &Ruby, rb_self: &Store, digest: String) -> Result<Obj<Turn>, Error> {
            let found = rb_self.locked().get(&digest).map(Arc::clone);
            match found {
                Some(inner) => Ok(Turn::wrap(ruby, inner)),
                None => Err(ext_error(
                    ruby,
                    "Store",
                    "MissingObject",
                    format!("no object {digest:?} in store"),
                )),
            }
        }

        fn key_p(&self, digest: String) -> bool {
            self.locked().contains_key(&digest)
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
        head: Option<String>,
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
        fn wrap(ruby: &Ruby, head: Option<String>, store: Value) -> Obj<Self> {
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
            let _: &Store = TryConvert::try_convert(store_value)?;
            Ok(Timeline::wrap(ruby, None, store_value))
        }

        fn empty_p(&self) -> bool {
            self.head.is_none()
        }

        fn head_digest(ruby: &Ruby, rb_self: &Timeline) -> Value {
            match &rb_self.head {
                Some(digest) => frozen_str(ruby, digest),
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
                    let store: &Store = TryConvert::try_convert(rb_self.store_value(ruby))?;
                    let found = store.locked().get(digest).map(Arc::clone);
                    match found {
                        Some(inner) => Ok(Turn::wrap(ruby, inner).as_value()),
                        None => Err(ext_error(
                            ruby,
                            "Store",
                            "MissingObject",
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
            let turn = TurnData::new(role, content, rb_self.head.clone(), meta);
            let store_value = rb_self.store_value(ruby);
            let store: &Store = TryConvert::try_convert(store_value)?;
            let digest = store.insert_arc(turn);
            Ok(Timeline::wrap(ruby, Some(digest), store_value))
        }

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
            let store: &Store = TryConvert::try_convert(store_value)?;
            if let Some(target) = &head {
                if !store.key_p(target.clone()) {
                    return Err(ext_error(
                        ruby,
                        "Store",
                        "MissingObject",
                        format!("no object {target:?}"),
                    ));
                }
            }
            Ok(Timeline::wrap(ruby, head, store_value))
        }

        fn rewind(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            args: &[Value],
        ) -> Result<Obj<Timeline>, Error> {
            let count = match args.first() {
                Some(value) => i64::try_convert(*value)?,
                None => 1,
            };
            let store_value = rb_self.store_value(ruby);
            let store: &Store = TryConvert::try_convert(store_value)?;
            let mut digest = rb_self.head.clone();
            let mut remaining = count;
            while remaining > 0 {
                digest = digest.and_then(|current| dag::parent_of(&store.locked(), &current));
                remaining -= 1;
            }
            Ok(Timeline::wrap(ruby, digest, store_value))
        }

        fn ancestors(ruby: &Ruby, rb_self: &Timeline) -> Result<RArray, Error> {
            let store: &Store = TryConvert::try_convert(rb_self.store_value(ruby))?;
            let arcs = dag::ancestor_arcs(&store.locked(), rb_self.head.as_deref());
            Ok(turns_to_array(ruby, arcs))
        }

        fn to_a(ruby: &Ruby, rb_self: &Timeline) -> Result<RArray, Error> {
            let store: &Store = TryConvert::try_convert(rb_self.store_value(ruby))?;
            let mut arcs = dag::ancestor_arcs(&store.locked(), rb_self.head.as_deref());
            arcs.reverse();
            Ok(turns_to_array(ruby, arcs))
        }

        fn ancestor_digests(ruby: &Ruby, rb_self: &Timeline) -> Result<RArray, Error> {
            let store: &Store = TryConvert::try_convert(rb_self.store_value(ruby))?;
            let digests = dag::ancestor_digests(&store.locked(), rb_self.head.as_deref());
            let array = ruby.ary_new_capa(digests.len());
            for digest in digests {
                array.push(frozen_str(ruby, &digest))?;
            }
            Ok(array)
        }

        fn length(ruby: &Ruby, rb_self: &Timeline) -> Result<usize, Error> {
            let store: &Store = TryConvert::try_convert(rb_self.store_value(ruby))?;
            Ok(dag::ancestor_arcs(&store.locked(), rb_self.head.as_deref()).len())
        }

        fn include_p(ruby: &Ruby, rb_self: &Timeline, digest: String) -> Result<bool, Error> {
            let store: &Store = TryConvert::try_convert(rb_self.store_value(ruby))?;
            Ok(dag::ancestor_arcs(&store.locked(), rb_self.head.as_deref())
                .iter()
                .any(|turn| turn.digest == digest))
        }

        fn ancestor_of_p(ruby: &Ruby, rb_self: &Timeline, other: &Timeline) -> Result<bool, Error> {
            same_store(ruby, rb_self, other)?;
            let store: &Store = TryConvert::try_convert(rb_self.store_value(ruby))?;
            Ok(dag::ancestor_of(
                &store.locked(),
                rb_self.head.as_deref(),
                other.head.as_deref(),
            ))
        }

        fn meet(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            other: &Timeline,
        ) -> Result<Obj<Timeline>, Error> {
            same_store(ruby, &rb_self, other)?;
            let store_value = rb_self.store_value(ruby);
            let store: &Store = TryConvert::try_convert(store_value)?;
            let common = dag::meet(
                &store.locked(),
                rb_self.head.as_deref(),
                other.head.as_deref(),
            );
            Ok(Timeline::wrap(ruby, common, store_value))
        }

        fn diverge_at(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            other: &Timeline,
        ) -> Result<Value, Error> {
            same_store(ruby, &rb_self, other)?;
            let store: &Store = TryConvert::try_convert(rb_self.store_value(ruby))?;
            let common = dag::meet(
                &store.locked(),
                rb_self.head.as_deref(),
                other.head.as_deref(),
            );
            match common {
                None => Ok(ruby.qnil().as_value()),
                Some(digest) => {
                    let found = store.locked().get(&digest).map(Arc::clone);
                    Ok(found
                        .map(|inner| Turn::wrap(ruby, inner).as_value())
                        .unwrap_or_else(|| ruby.qnil().as_value()))
                }
            }
        }

        fn to_s(ruby: &Ruby, rb_self: &Timeline) -> String {
            match &rb_self.head {
                None => "#<Lain::Ext::Timeline empty>".to_string(),
                Some(digest) => {
                    let prefix = digest.get(..19).unwrap_or(digest);
                    let length = TryConvert::try_convert(rb_self.store_value(ruby))
                        .map(|store: &Store| {
                            dag::ancestor_arcs(&store.locked(), Some(digest)).len()
                        })
                        .unwrap_or(0);
                    format!("#<Lain::Ext::Timeline {prefix}... ({length})>")
                }
            }
        }
    }

    /// One FFI crossing for a whole chain: wrap each already-walked node into a
    /// frozen `Turn` handle and hand back a single Ruby Array.
    fn turns_to_array(ruby: &Ruby, arcs: Vec<Arc<TurnData>>) -> RArray {
        let array = ruby.ary_new_capa(arcs.len());
        for arc in arcs {
            // Pushing to a fresh array cannot fail.
            let _ = array.push(Turn::wrap(ruby, arc));
        }
        array
    }

    /// Raise `Timeline::CrossStore` unless both Timelines name the SAME Store
    /// object. A `Store` defines no `==`, so Ruby `==` is `BasicObject`'s object
    /// identity -- exactly Ruby's `store.equal?(other.store)`.
    fn same_store(ruby: &Ruby, a: &Timeline, b: &Timeline) -> Result<(), Error> {
        let same = a
            .store_value(ruby)
            .equal(b.store_value(ruby))
            .unwrap_or(false);
        if same {
            Ok(())
        } else {
            Err(ext_error(
                ruby,
                "Timeline",
                "CrossStore",
                "cannot compare Timelines backed by different stores".to_string(),
            ))
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

        // Subclass Lain::Error where it exists (it is required before this
        // extension loads); fall back to StandardError so init never fails on it.
        let lain_error = ruby
            .class_object()
            .const_get::<_, RModule>("Lain")
            .and_then(|m| m.const_get::<_, ExceptionClass>("Error"))
            .unwrap_or_else(|_| ruby.exception_standard_error());

        let turn = ext.define_class("Turn", ruby.class_object())?;
        turn.define_error("InvalidRole", lain_error)?;
        turn.define_singleton_method("new", function!(Turn::new, 1))?;
        turn.define_method("role", method!(Turn::role, 0))?;
        turn.define_method("content", method!(Turn::content, 0))?;
        turn.define_method("parent", method!(Turn::parent, 0))?;
        turn.define_method("meta", method!(Turn::meta, 0))?;
        turn.define_method("digest", method!(Turn::digest, 0))?;
        turn.define_method("payload", method!(Turn::payload, 0))?;
        turn.define_method("root?", method!(Turn::root_p, 0))?;
        turn.define_method("==", method!(<Turn as typed_data::IsEql>::is_eql, 1))?;
        turn.define_method("eql?", method!(<Turn as typed_data::IsEql>::is_eql, 1))?;
        turn.define_method("hash", method!(<Turn as typed_data::Hash>::hash, 0))?;
        turn.define_method("to_s", method!(Turn::to_s, 0))?;
        turn.define_method("inspect", method!(Turn::to_s, 0))?;

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
        timeline.define_method("inspect", method!(Timeline::to_s, 0))?;

        Ok(())
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
