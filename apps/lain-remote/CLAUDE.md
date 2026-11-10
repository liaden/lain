# lain-remote

Sideloaded phone app that answers what lain is waiting on. Rust + Dioxus 0.7, desktop first, Android later.
It talks to `lain-core relay` over the tailnet; the wire types come from `lain-wire`.
On the phone it is labelled `lain` (`Dioxus.toml`); `lain-remote` is only the crate's name.
It is a Cargo workspace of its own, excluded from lain's, so Dioxus stays out of lain's lockfile and deny config.

## Build

```bash
cargo build                                         # from this directory: the app is its own workspace
(cd ../.. && cargo build -p lain-core) && cargo test  # the tests drive a real relay, see below
cargo clippy --all-targets -- -D warnings
cargo fmt -- --check
cargo deny check                                    # this directory's deny.toml: the root's plus 2 Dioxus ignores
dx serve --platform desktop                         # where dx exists
```

The Android SDK is not installed here either, so nothing on this box builds for Android.
Pair in the Settings screen (saved 0600 at `$LAIN_REMOTE_CONFIG`, else `$XDG_CONFIG_HOME/lain-remote/settings`, else `~/.config/lain-remote/settings`);
`LAIN_REMOTE_ADDR` and `LAIN_REMOTE_TOKEN` are the fallback when nothing is saved. The token is never logged or shown after saving.

## Tests find lain-core

`src/client.rs` tests start a real `lain-core relay` on 127.0.0.1 and publish through its Unix socket,
the way lain does. The binary is `$LAIN_CORE_BIN`, default the workspace's `target/debug/lain-core`.
With no binary a test prints a skip message naming `rake core:build` and passes, so a green run
with `skipping:` in `cargo test -- --nocapture` proved nothing. Set `LAIN_REMOTE_REQUIRE_RELAY=1` (any value)
and a missing binary fails the test instead; use it wherever a skip must not pass.

Each test gets its own port, tempdir and 0600 devices file in its own 0700 directory, and kills its relay on drop.
The relay confines itself with Landlock, so a kernel without it fails the tests at startup, not at the first call.

## Wire

- `lain-wire` is a path dependency, so the app and the relay always build from the same commit. A sideloaded
  APK is not rebuilt when lain is, so its `Hello` carries `WIRE_VERSION` and the relay refuses a mismatch.
- Never build a msgpack map by hand. Payloads go through `lain_wire::encode` and `decode`.
- The relay answers `[1, msgid, error, result]`; an error is a string.

## Code patterns

- `src/client.rs` is the tested core: no dioxus in it. `src/main.rs` is the Dioxus shell and the screen state.
- `src/ui/{agenda,item,settings}.rs` each keep their view state as plain functions and types with the tests; the components only draw it.
- Deep links (`lain-remote://item/<id>`) are not wired and stay for the manual pass: Dioxus 0.7 has no hook for them on Android or Linux without platform code; iOS and macOS get `Event::Opened` through `use_wry_event_handler`.
- Reading and answering use separate connections, because a long poll in flight cannot be cancelled to send.
- Comments explain why only. Commit messages never name plan cards.
