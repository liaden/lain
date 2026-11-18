# lain-rpc

The msgpack-RPC envelope and a tokio server for it: requests `[0, msgid, method, params]`,
responses `[1, msgid, error, result]` and server pushes `[2, method, params]`. It is the same idiom
the Neovim client speaks. Its one user in this repo is `crates/lain-daemon`; Ruby reaches it
through the daemon, in `lib/lain/core/client.rb`.

## Build

It is a library, `lain-rpc`, built with the workspace:

```bash
cargo build -p lain-rpc
```

## Tests

```bash
cargo test -p lain-rpc
```

The `test-support` feature exposes in-process servers and a client. The daemon's tests turn it on
as a dev dependency; it is never a production dependency.

## Layout

- `lib.rs`: the envelope and the server. Each request on a connection is handled as its own task,
  and responses carry the msgid and may complete out of order.
- `push.rs`: frames the server originates, sent to the one connection a handler holds a `Push` for.
- `support.rs`: in-process servers and a client for tests (feature `test-support`).

## Constraints

- The crate never prints. Diagnostics go to the `tracing` subscriber the binary installs.
- Async runs out of process, so this crate is for `lain-daemon` and not for `ext/lain`; see
  [`../../ext/lain/CLAUDE.md`](../../ext/lain/CLAUDE.md).

Related: [architecture](../../docs/devs/architecture.md).
