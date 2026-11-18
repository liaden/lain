# lain-remote

The phone app that answers what lain is waiting on. It is built with Rust and Dioxus 0.7, runs on
the desktop today and builds for Android, and shows as `lain` on the phone. It connects over the
tailnet to the relay in `crates/lain-daemon`, using the message types in `crates/lain-wire`.

## Build

The crate is `lain-remote`, a binary. It is a Cargo workspace of its own, so run cargo from this
folder:

```bash
cargo build
dx serve --platform desktop                          # where dx is installed
bin/android-setup                                    # once: JDK, SDK, NDK, Rust target, dx
dx build --platform android --target aarch64-linux-android
```

## Tests

```bash
(cd ../.. && cargo build -p lain-daemon) && cargo test
```

The tests in `src/client.rs` start a real `lain-daemon relay --unix`. With no binary a test skips
and passes, so set `LAIN_REMOTE_REQUIRE_RELAY=1` to make a missing binary fail. The relay needs
Landlock.

## Layout

- `main.rs`: the Dioxus shell and the screen state.
- `client.rs`: the relay client, one authenticated connection holding the agenda by cursor. No
  dioxus in it.
- `ui/agenda.rs`, `ui/item.rs`, `ui/settings.rs`: view state as plain functions and types, and the
  components that draw it.

Pairing happens in the Settings screen. `LAIN_REMOTE_ADDR` and `LAIN_REMOTE_TOKEN` are the
fallback when nothing is saved.

## Constraints

- `lain-wire` is a path dependency, and payloads go through `lain_wire::encode` and `decode`.
- Reading and answering use separate connections, because a long poll cannot be cancelled to send.
- The workspace is excluded from lain's, so Dioxus stays out of lain's lockfile and `deny.toml`.

See [CLAUDE.md](CLAUDE.md) for the checks and patterns, and [phone approvals](../../docs/users/remote.md)
for setup from lain's side.
