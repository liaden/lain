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
    use super::build_env_filter;
    use magnus::{function, prelude::*, Error, Ruby};

    /// Install a global JSON-emitting `tracing` subscriber that writes NDJSON
    /// (one flat JSON object per line) to stderr, filtered by `level`.
    ///
    /// Idempotent: the underlying `try_init` only succeeds once per process. A
    /// second call is reported as a no-op (`false`) rather than panicking or
    /// aborting the Ruby VM. Invalid level strings surface as a Ruby
    /// `ArgumentError`.
    ///
    /// Returns `true` if this call installed the subscriber, `false` if a
    /// global subscriber was already present.
    fn init_tracing(ruby: &Ruby, level: String) -> Result<bool, Error> {
        let filter =
            build_env_filter(&level).map_err(|msg| Error::new(ruby.exception_arg_error(), msg))?;

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
            .with_writer(std::io::stderr)
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
        ext.define_singleton_method("init_tracing", function!(init_tracing, 1))?;

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
