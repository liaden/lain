# lain-remote

Sideloaded phone app that answers what lain is waiting on. Rust + Dioxus 0.7, desktop first, Android later.
It talks to the `lain-daemon` relay over the tailnet; the wire types come from `lain-wire`.
On the phone it is labelled `lain` (`Dioxus.toml`); `lain-remote` is only the crate's name.
It is a Cargo workspace of its own, excluded from lain's, so Dioxus stays out of lain's lockfile and deny config.

## Build

```bash
cargo build                                         # from this directory: the app is its own workspace
(cd ../.. && cargo build -p lain-daemon) && cargo test  # the tests drive a real relay, see below
cargo clippy --all-targets -- -D warnings
cargo fmt -- --check
cargo deny check                                    # this directory's deny.toml: the root's plus 2 Dioxus ignores
dx serve --platform desktop                         # where dx exists
```

## Android

```bash
bin/android-setup                                   # once: JDK 17, SDK, NDK, Rust target, dx; prints 3 exports for .envrc
dx build --platform android --target aarch64-linux-android
adb install -r target/dx/lain-remote/debug/android/app/app/build/outputs/apk/debug/app-debug.apk
```

Everything lands under `$HOME` (`~/Android/Sdk`, mise's JDK), with no sudo; rerunning skips what is there.
The newer cmdline-tools replace `sdkmanager` with `android sdk`, which sends usage metrics unless given `--no-metrics`.
The `desktop` feature builds for Android as is: wry is the mobile renderer too. A cold build takes about 3.5 minutes.
CI's `lain-remote android` job builds the same debug APK on the runner's own SDK and keeps it as an artifact for 7 days.
dx 0.7.10 maps `[deep_links] schemes` in `Dioxus.toml` to an Android intent-filter; the app does not declare it yet.
Pair in the Settings screen (saved 0600 at `$LAIN_REMOTE_CONFIG`, else `$XDG_CONFIG_HOME/lain-remote/settings`, else `~/.config/lain-remote/settings`);
`LAIN_REMOTE_ADDR` and `LAIN_REMOTE_TOKEN` are the fallback when nothing is saved. The token is never logged or shown after saving.

## Tests find lain-daemon

`src/client.rs` tests start a real `lain-daemon relay --unix` on 127.0.0.1 and publish through its Unix socket.
The binary is `$LAIN_DAEMON_BIN`, default the workspace's `target/debug/lain-daemon`.
With no binary a test prints a skip message naming `cargo build -p lain-daemon` and passes, so a green run
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
- `lain-remote://item/<id>` is parsed once, in `ui::agenda::link_id`, held by `Links` until the first agenda page is in and the app is paired, and fed from `Event::Opened` in `main.rs`. Android and Linux registration of the scheme (an intent-filter plus platform code) is not done and stays for the manual pass.
- Reading and answering use separate connections, because a long poll in flight cannot be cancelled to send.
- Comments explain why only. Commit messages never name plan cards.
