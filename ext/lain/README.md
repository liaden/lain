# ext/lain

The in-process Rust extension, built with magnus into `lib/lain/lain.so`. It holds lain's data
model (the content-addressed event store and timeline, `Canonical` hashing) plus a few pure
capabilities: BM25, fuzzy matching, AST search, the prompt formatter, TOML parsing and secret-region
scans. Ruby reaches it as `Lain::Ext::*`, loaded from `lib/lain.rb`.

## Build

The crate is `lain`, a `cdylib`:

```bash
bundle exec rake compile      # builds into lib/lain/lain.so; also builds lain-fence on Linux
```

## Tests

```bash
cargo test -p lain
cargo clippy --all-targets -- -D warnings
```

`cargo test` never compiles the magnus surface, so a green run does not prove the bindings load.
Run `bundle exec rake compile` and the specs for the Ruby side too. `ext/lain/CLAUDE.md` has the
full list of checks and the warning behind this one.

## Layout

- `lib.rs`: the crate root and the magnus entry point. Printing is a hard error here.
- `canonical.rs`, `digest.rs`, `event.rs`, `dag.rs`, `graph.rs`, `algebra.rs`: the event envelope,
  content address, and the ancestry and order queries over one store.
- `bm25.rs`, `fuzzy.rs`, `astgrep.rs`, `treesitter.rs`, `regions.rs`, `prompt.rs`, `toml_table.rs`:
  the pure capabilities named above.
- `read_text.rs`, `read_bytes.rs`: the 2 ways data enters from Ruby.
- `nogvl.rs`: runs a pure job with the GVL released.
- `local.rs`, `corpus.rs`, `test_sources.rs`: shared thread-local helpers and test support.

## Constraints

This crate is pure and synchronous, and it must not own the terminal. Anything async, I/O-bound
or isolation-relevant goes out of process, in `crates/lain-daemon`. A new binding has to pass the
5 tests in [docs/devs/rust-bindings.md](../../docs/devs/rust-bindings.md).

Read [CLAUDE.md](CLAUDE.md) in this folder before writing code, and
[architecture](../../docs/devs/architecture.md) for where the data model sits.
