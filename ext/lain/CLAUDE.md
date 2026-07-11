# Working on `ext/lain` (the in-process Rust extension)

This crate is **pure and synchronous**. It exists for Rust's *data model* — ownership, cheap
immutability, structural sharing — not for speed. See the root `CLAUDE.md` section "Rust, and
which data structures earn a binding" for the five tests a structure must pass before it gets a
binding at all.

Anything **async, I/O-bound, or isolation-relevant** belongs in `crates/lain-core` (tokio,
msgpack-RPC over a Unix socket), not here. Driving an async runtime from inside a magnus FFI call
while holding the GVL is a known footgun, and an "in-process sandbox" is not a sandbox.

## Toolchain

```bash
cargo test                                  # 39/39 today; must not regress
cargo clippy --all-targets -- -D warnings   # warnings are errors
cargo fmt -- --check                        # pre-commit runs this, not `cargo fmt`
cargo deny check                            # wildcard versions are banned; pin every dep
bundle exec rake compile                    # builds into lib/lain/lain.so (gitignored)
```

All four run in `pre-commit` on **every** worktree, because `core.hooksPath` is unset and
`.git/hooks` is shared. There is no "I'll format it later."

## Hard rules

- **Stable channel only. No `#![feature]`.** A subagent has already shipped `#![feature]` here
  and it does not build. If you reach for a nightly feature, the design is wrong.
- **Output discipline is a crate-root `deny`.** `clippy::print_stdout` and `clippy::print_stderr`
  are hard errors. This is not fussiness: the Journal is NDJSON, it is the experiment record, and
  one stray line makes `JSON.parse` fail on that line. We learned it the hard way — the subscriber
  wrote to stderr and Bundler interleaved a plain-text warning into it. Diagnostics go through
  `tracing`, whose writer is a caller-supplied fd.
- **Pin every dependency.** `cargo deny` bans wildcards. `libc` is pinned at `0.2` for exactly
  this reason, and it is here solely for `dup(2)`.
- **`cargo fmt` before you commit**, not after the hook rejects you.

## The two invariants that cost real debugging

**1. The fd is `dup`'d, and we own only the dup.** `init_tracing` takes a caller-supplied fd and
calls `libc::dup` before `File::from_raw_fd`. Dropping the Rust side must never close the
descriptor Ruby still owns. Cloning `SharedWriter` is an `Arc` bump — never another `dup`, or
every event leaks an fd.

**2. `SharedWriter::write_all` is overridden deliberately.** The default implementation loops over
`write`, re-acquiring the mutex per partial write. stderr is usually a pipe or a tty, where
partial writes genuinely happen, so two `tracing` spans could interleave and tear a single NDJSON
line in half. The override holds the lock across the whole buffer. **Do not "simplify" it away** —
it looks redundant and is not, which is why the comment above it says so.

## Testing shape

Keep the logic in **plain Rust functions with no `magnus` types in their signatures**, and put the
FFI surface in a separate module. `build_env_filter` and `dup_writer` are the pattern: they are
unit-testable without an embedded Ruby VM, which is why `cargo test` runs at all. A function that
takes a `Ruby` or returns a `magnus::Error` cannot be tested in `cargo test`; push the decision out
of it and test the decision.

## When porting a Ruby structure down here (M4)

`Timeline` ships as pure Ruby first. The port is correct **only** when the existing `Regular` and
`MeetSemilattice` property tests pass unchanged against *both* implementations — that is the
acceptance test, and it is why the Ruby version is not deleted when the Rust one lands.

> ⚠️ **A magnus-wrapped `TypedData` object is not `Ractor.shareable?` for free.** `Ractor.shareable?(turn)`
> must stay `true` — it is the mechanical statement of "no reachable mutable state", and there is a
> spec. Establish shareability deliberately; do not weaken the spec to accommodate the port.

Batch across the boundary. A per-node FFI call in a DAG walk loses to plain Ruby, because
conversion cost dominates almost every naive binding. If a port is not asymptotically better, it is
not better.
