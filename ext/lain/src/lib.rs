#![deny(clippy::print_stdout, clippy::print_stderr)]
//! Output discipline is enforced at the crate root: `print_stdout` /
//! `print_stderr` are hard errors so no Rust code here can smear plain text
//! onto a stream the Ruby-side Journal may be parsing as NDJSON. Diagnostics go
//! through `tracing`, whose writer is a caller-supplied fd (see
//! [`ffi::init_tracing`]).

use tracing_subscriber::EnvFilter;

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
    use super::{build_env_filter, dup_writer};
    use magnus::{function, prelude::*, Error, Ruby};
    use std::io::Write;
    use std::sync::{Arc, Mutex};

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

    #[magnus::init]
    fn init(ruby: &Ruby) -> Result<(), Error> {
        let module = ruby.define_module("Lain")?;
        module.define_singleton_method("hello", function!(hello, 1))?;

        let ext = module.define_module("Ext")?;
        ext.define_singleton_method("init_tracing", function!(init_tracing, 2))?;

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
