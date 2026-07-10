#![deny(clippy::print_stdout, clippy::print_stderr)]
//! Output discipline is enforced at the crate root: `print_stdout` /
//! `print_stderr` are hard errors so no Rust code here can smear plain text
//! onto a stream the Ruby-side Journal may be parsing as NDJSON. Diagnostics go
//! through `tracing`, whose writer is a caller-supplied fd (see
//! [`ffi::init_tracing`]).

use tracing_subscriber::EnvFilter;

mod canonical;

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
    use magnus::{
        function, method, prelude::*, r_hash::ForEach, DataTypeFunctions, Error, Float, Integer,
        RArray, RHash, RModule, RString, Ruby, Symbol, TypedData, Value,
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
    /// immutable `u64` and nothing else, so it is the minimal proof that the
    /// mechanism works before the real port depends on it. If a magnus upgrade
    /// ever breaks the flag, the tiny `share_probe_spec` fails here rather than
    /// deep inside `Turn`.
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
        } else if let Some(string) = RString::from_value(value) {
            Ok(Canon::Str(utf8(ruby, string)?))
        } else if let Some(symbol) = Symbol::from_value(value) {
            Ok(Canon::Str(utf8(ruby, symbol.funcall("to_s", ())?)?))
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
        if let Some(string) = RString::from_value(key) {
            utf8(ruby, string)
        } else if let Some(symbol) = Symbol::from_value(key) {
            utf8(ruby, symbol.funcall("to_s", ())?)
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
