# lain-daemon: 1 per-user Rust daemon for sessions, the phone, headless runs and fast spawning

status: in-progress
base: 7eea39c5e92903ae975887cb5ce268c75926fd2f
commit-mode: orchestrator-commits
language: rust, ruby
panel: Rust (Linus Torvalds, Raph Levien, Andrew Gallant, Frank McSherry, Ashley Williams); Ruby (Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson)

## Intent

Carry out `planning/lain-daemon-research-2026-11.md`, option 1, all 3 phases, with the user's rulings of 2026-11-16.

1. **Phase 1: routing (D1 to D15, D25).**
   - A per-user `lain-daemon` holds the registry of live chats.
   - It routes review-queue offers and every session's approvals.
   - It runs the phone relay as a confined worker and sends ntfy itself, so you have 1 phone address and 1 buzz per item.
   - The `lain-core` binary retires. Its RPC framework becomes the `lain-rpc` library.
2. **Phase 2: headless runs (D16 to D20, D26).**
   - The daemon starts and supervises headless sessions (an epic, the review poll, a chore drain) from a closed set of run kinds.
   - A run parks its gated calls and questions and routes them to you, instead of refusing them.
   - This works only where the run's bash is sandboxed (user ruling, 2026-11-16).
3. **Phase 3: fast spawning (D21 to D23).** A warmed Ruby parent forks headless sessions, and restarts itself when lain's own install changes. D23 measures exec first, so the fork work starts from a known cost.

**Prerequisite:** `planning/specs/review-queue-hud.md` is `done`. This plan takes over 4 of its pieces, and deletes each once its replacement passes:

- T31's live records (D7);
- T24's input-socket offer and T25's socket delivery (D13);
- the dotfiles poll timer (D19).

The ROADMAP line is under `## Status` as "lain-daemon".

## Grounding

2026-11-16, `main` at `6fd74370`. This plan is written before `review-queue-hud.md` runs; re-read every file that plan touched before starting. Read:

- `CLAUDE.md` and `ARCHITECTURE.md`'s lain-core section;
- the research report, its sources and its spike;
- a code survey of `crates/lain-core`, the relay's Ruby side, `ChatLaunch`, and the headless refusal sites.

A panel (REQUEST-CHANGES, folded in) traced a headless epic's approval from `lain daemon run` to the phone and back.

**Probed or measured:**

- **Forking after `require "lain"`.**
  - Fork-safe: 1 thread, 6 fds, no reactor.
  - A fork takes about 3 ms, where a `require "lain"` takes 0.8 to 1.5 s.
  - With `Process.warmup`, a child keeps 77% of its pages shared after 25 s of a synthetic workload (Journal parsing, `Canonical.dump`, masking). It dirties 30 to 40 MB, nearly all in its first second, with 0 major GCs and +444 old objects.
  - Not measured: `exe/lain`'s Thor parse, config load and registration on top of the fork. D23 measures that.
  - Evidence: `planning/lain-daemon-research-2026-11/zygote.rb` and `gcchild.rb`.
- **macOS check.** `lain-core` and `lain-fence` type-check for `aarch64-apple-darwin` once their Linux-only code is gated (`review-queue-hud.md` T1).

**Read, with paths.** All Rust paths are under `crates/lain-core/` unless named.

- **`src/rpc.rs`** (1,966 lines, tests from 1,061) has no `crate::` dependency. Its parts:
  - `Codec` (`:61`) and the limits (`:81-94, 262-437`);
  - `trait Accept` (`:299`), `trait Session` (`:319`, only `closed()`) and `trait Handler` (`:333-360`), whose `hello` is `async fn hello(&self, params: Vec<Value>) -> Result<(Value, Self::Session), RpcError>`, with `type Session: Session + Default`;
  - `serve` (`:387`).

  Everything is `pub(crate)`. The test support module (`:825`) is `#[cfg(test)]`.
- **`RpcError`** (`:787`) mixes protocol variants with relay ones: `BadToken`, `WireVersion`, `AlreadySettled`, `NotOpen` and `TooLarge`.
- **Pushes.** A `[2, ...]` frame is answered as an invalid request (`:20-23, 679-687`), and `respond_to` (`:651`) sends exactly 1 response per frame. Ruby's `Core::Client#deliver` (`lib/lain/core/client.rb:216-222`) silently drops a frame that is not a response.
- **Ruby client.** `Core::Client` needs an Async reactor (`client.rb:72`). A chat's reactor starts at `Sync do` in `Repl#run` (`cli/repl.rb:122`), inside `ConversationScope#open`'s lifetime. `Wiring#remote_surface` is built before it (`wiring.rb:976-984`).
- **`ping`** returns the holding crate's `CARGO_PKG_VERSION` (`:776`), and Ruby pins `PROTOCOL_VERSION = "0.1.0"` exactly (`client.rb:18`).
- **Lints** are crate attributes in `src/main.rs:13-14`: `#![forbid(unsafe_code)]` and `#![deny(clippy::print_stdout, clippy::print_stderr)]`. `crates/lain-wire/src/lib.rs:6` also has `#![deny(missing_docs)]`. Under `forbid(unsafe_code)`, a child's extra fd needs an `unsafe` `pre_exec`, so sockets go to children as their stdin.
- **The relay** (`src/relay.rs`, `relay/agenda.rs`, `relay/devices.rs`):
  - it binds a Unix side (`agenda.publish`, `answers.next`) and a Tailnet side (`hello`, `agenda.next`, `answer.send`);
  - `listen_rule` (`:69`) accepts loopback or `tailscale0`;
  - devices are reread every 1 s (`devices.rs:154, 217-218`);
  - Landlock confinement (`:214-243`).
- **`lain-core` references** (`rg lain-core`):
  - `Up::Relay::BINARY` (`cli/up.rb:1130`);
  - `spec/support/core_daemon.rb` and `RemoteSurfaceSpecSupport::Relay` (`spec/lain/approval/remote_surface_spec.rb`);
  - `Rakefile:90-95`;
  - `tests/lifecycle.rs`;
  - `.pre-commit-config.yaml:79, 122`;
  - `.github/workflows/main.yml:198`;
  - `apps/lain-remote/src/client.rs:249-313` (its tests spawn the relay);
  - `lib/lain/core/transport/unix.rb:8, 16`;
  - `bin/setup:19`, `bin/spec-census:602`, `deny.toml:45, 59`;
  - `CLAUDE.md`'s `:core` lines, `docs/rust-bindings.md`, `docs/concurrency.md`, `docs/GLOSSARY.md`.
- **`RemoteSurface`** (`lib/lain/approval/remote_surface.rb`):
  - it is per chat, built with `config.remote_relay` and a queue (`:80`);
  - it publishes deltas every 0.25 s from `Remote::Agenda#refresh` (`remote/agenda.rb:89-95`), which polls 3 sources, including `Gates#each` (`:262-271`), which rereads every journal in the project;
  - it rescues `Refused` from a publish (`:213-219`);
  - it treats `Core::Died` as the end (`:34, 104-105`);
  - it filters answers by a random prefix (`:156`), and sends ntfy after 60 s.

  Gate items are project-wide, so 2 chats in 1 root publish the same gate twice.
- **Config.** `remote relay:` and `remote ntfy:` are project-file verbs (`config/builder.rb:148, 201-207`).
- **Headless.** `Wiring#attended?` (`wiring.rb:176-180`) is the 1 reading of `--non-interactive`, threaded to 14 readers. An unattended session gets:
  - no `Parked::Queue` (`cli/switchboard.rb:265-272`);
  - a 1-rung `Unattended` ladder (`:560, 918`);
  - `Judged::Unattended` (`approval/judged.rb:130`);
  - `Parked::Queue::Unattended` (`approval/parked/queue.rb:539`);
  - `Tools::AskHuman::Unattended` (`cli/wiring/askers.rb:83`).

  `ApprovalSurfaces#watch` always starts the terminal surface when there is a queue (`cli/repl/approval_surfaces.rb:77-80`). The refusals are pinned in `spec/lain/cli/switchboard_spec.rb` (206, 286-298, 327, 951-987, 1025), `spec/lain/tools/ask_human/unattended_spec.rb`, `spec/lain/approval/parked/queue_spec.rb:1950` and `spec/lain/approval/judged_spec.rb:1183-1202`.
- **Sandbox.** `Confine::Profile::UNCONFINED = %i[none traced]` and `Profile.confines?` (`confine/profile.rb:39, 213`); `Sandbox#confines?` (`sandbox.rb:55`). Confined profiles grant no daemon or state socket (`profile.rb:162, 466`).
- **Chat lifecycle.** `ChatLaunch#call` (`cli/chat_launch.rb:104-118`) runs `close_session` (`:340`) in `ensure`. A pre-flight run opens no record. The session id is the journal's file name (`journal.rb:160`).
- **The existing fork.** `ChatPreflightFork` (`exe/lain:1706-1800`):
  - `setpgid`;
  - reopen stdio (`:1783-1786`);
  - `Dir.chdir`, `ENV.update`, `Config.forget!`;
  - `LainCLI.start`;
  - `exit!`.
- **Headless chats today.** `Chores::Runner` runs `RbConfig.ruby exe/lain chat --root R --cwd R --non-interactive --approval auto --max-cost N --prompt P` (`chores/runner.rb:162`).
- **The `:core` tier** is excluded by default (`spec/support/tags.rb:218`), and neither CI nor pre-commit runs it.

**Where docs and code disagreed:**

- `lib/lain/core.rb` says the daemon "has no production door today", but the relay is one. **Code wins.** D14 removes the claim.
- The 2026-10-17 ruling kept "the lain-core wire layer". The 2026-11-16 ruling retires the binary and keeps the layer as `lain-rpc`, `lain-wire` and `Core::Client`. **The newer ruling wins.**

**Paths.** A path marked `(new)` is created by the first card that names it. Everything under `crates/lain-daemon/`, `crates/lain-rpc/` and `lib/lain/daemon/` is new in this plan. `lib/lain/live_sessions*`, `lib/lain/review/queue/*` and `lib/lain/cli/exe/*` come from `review-queue-hud.md`.

## Compatibility

| Surface | Verdict | Evidence |
|---|---|---|
| `lain-core` binary, `rake core:build` | free to break (ruling 2026-11-16) | Unpublished. Every reference is listed in Grounding, all in this repo. |
| msgpack-RPC framing | free to extend | Adds server-to-client pushes `[2, method, params]` (D2). Requests and responses are unchanged, and `agenda.publish` stays a request so a refusal still reaches the caller. |
| `PROTOCOL_VERSION` handshake | must keep the exact pin | The daemon answers `ping` with `0.1.0`. A separate `daemon.info` method returns the build id and launch digest (D4, D6). |
| `lain-wire` `WIRE_VERSION` | free to break, goes to 2 (D8) | Its users are the relay (moving), `apps/lain-remote` (D8, D15) and Ruby's `Remote::Wire` mirror. An old app gets `WireVersion`. |
| `remote relay:` and `remote ntfy:` | free to move to the user file (D10) | 1 phone listener per machine. A project file that still sets them is refused, naming the user file. |
| Devices file `state_home/remote/devices` | must keep | Paired phones. Same path and format. |
| `--non-interactive` refusals | must keep without `--human remote` | Every pinned refusal stays (D26, D17). |
| `review-queue-hud.md` pieces | replaced as planned | T31's `live/` files (D7), T24's input-socket offer and T25's socket delivery (D13), and the dotfiles poll timer (D19). Each is deleted after parity, per the 2026-11-10 ruling. |
| herdr CLI 0.9.5 | must keep | External. D20 adds workspace tokens with source `lain-daemon`. |

No must-keep surface, if broken, would remove a card or about 20% of the plan.

## Spike findings

| Question | Result | Evidence |
|---|---|---|
| Is a booted lain parent fork-safe, and what does a fork cost? | Yes. 3 ms against 0.8 to 1.5 s for `require "lain"`. 77% shared after 25 s of a synthetic workload with warmup. | `planning/lain-daemon-research-2026-11/zygote.rb`, `gcchild.rb` |
| Do `lain-core` and `lain-fence` type-check for macOS? | Yes, after `review-queue-hud.md` T1 | `planning/specs/review-queue-hud/mac-cargo-spike.patch` |

Not spiked; each is a stop condition on its card:

- the peer pid on macOS (tokio `UCred::pid`): D1;
- `ureq` with `rustls` under `cargo deny`: D12;
- Landlock on a worker whose socket arrives as stdin: D9;
- exec against fork spawn cost through `exe/lain`: D23.

## Threat model

The daemon's local socket is `runtime_dir/daemon/daemon.sock`, mode 0700, and it checks the peer's uid. Every process running as you passes that check, including the agent's bash children. What each can do:

| Who | Can | Can't |
|---|---|---|
| Any same-uid process | register itself (peer pid must match, D5); publish items stamped with its own registration's project and pid; send an offer, which a chat shows only after your keypress | answer an approval or question (no local method does, D5); start a run with an argv it wrote (D16); register as another process |
| The phone | answer, with a paired device token over loopback or `tailscale0` | anything else |
| The agent's bash, confined profile (Linux) | nothing on the daemon socket; it is not granted | |
| The agent's bash, `traced` or `none` profile (Linux), or any profile on macOS | write the devices file and connect over loopback as a phone | approve its own headless run: `--human remote` refuses to start without containment, and denies any bash call that would run unconfined (D17, ruling 2026-11-16) |

An attended chat keeps today's exposure: a desk chat already answers its own prompts at the terminal.

## Shared files

Only the main session edits these. Cards hand back 1-line diffs.

- `Cargo.toml` (root): add `./crates/lain-rpc` (D1) and `./crates/lain-daemon` (D4), and remove `./crates/lain-core` (D14).
- `exe/lain`: `subcommand "daemon", Lain::CLI::DaemonCommand` (D18).
- `docs/commands.md`: `lain daemon`, `--human remote`, the `remote` verb in the user file, and the removed `lain-core` notes.
- `ARCHITECTURE.md`: the lain-core section becomes lain-rpc, lain-daemon and the relay worker (D14).
- `CLAUDE.md`: the `:core` lines name `rake daemon:build` (D14).
- `ROADMAP.md`: the Status line.

`lib/lain/cli/wiring.rb` is not shared here. D7, D11, D26 and D17 edit it in that order.

## Rejected options

- **Grow `lain-core` into the daemon.** User ruling: retire it. A future code-mode handle store is its own supervised worker.
- **The phone listener inside the main daemon process.** The relay's Landlock confinement can't hold in a process that spawns runs and makes HTTPS calls. The listener stays a confined worker, `lain-daemon relay`, whose socket arrives as its stdin.
- **A local socket method that answers approvals.** User ruling: answers come only through the phone's device token or the chat's own terminal and nvim.
- **`run.start` with a raw argv, or an unchecked slug or root.** The daemon builds every argv from a closed set of kinds and refuses anything it can't check (D16).
- **`agenda.publish` as a push notification.** A notification has no reply, so a `TooLarge` refusal would be lost (`remote_surface.rb:213-219`). Only answers and offers are pushed.
- **Event-driven agenda sources.** `Remote::Agenda#refresh` polls 3 sources, 1 of them by rereading journals. Making them push is its own work. The 0.25 s publish sweep stays, and only the answers long-poll goes away (D11).
- **Durable state in the daemon.** Chats re-register and republish after a restart, and the journal stays the record.
- **A systemd or launchd unit for the daemon itself.** Ruby starts it on demand under a lock (D6). A login hook runs `lain daemon ensure` so the review count stays fresh after a reboot (E3).
- **Forking interactive chats.** They bind a controlling terminal, raw mode and process signals. herdr and tmux own PTYs.
- **`PR_SET_CHILD_SUBREAPER` for forked runs.** It is Linux-only. The spawner reports its children's exits instead (D21, D22).
- **Wall-clock thresholds in specs.** Ruling 2026-10-27. Ordering is asserted in specs, and timings live in `bin/hot-path-bench` rows (D23).

## Open decisions

- **The input socket still accepts raw `line` frames from any same-uid client.** It predates this plan. D13 moves offers off it. Closing it is a later card.
- **A code-mode handle worker.** It is planned elsewhere, and no card depends on it.
- **Headless remote answers on macOS.** D17 refuses them there until the Mac sandbox can contain bash. This is a later goal (ruling 2026-11-16).

## Dependency graph

```mermaid
flowchart LR
  D1 --> D2
  D2 --> D3
  D1 --> D4
  D4 --> D5
  D4 --> D6
  D4 --> D25
  D6 --> D25
  D3 --> D7
  D5 --> D7
  D25 --> D7
  D5 --> D9
  D9 --> D8
  D7 --> D11
  D8 --> D11
  D10 --> D11
  D11 --> D12
  D7 --> D13
  D8 --> D13
  D9 --> D13
  D11 --> D13
  D11 --> D14
  D12 --> D14
  D8 --> D15
  D11 --> D26
  D12 --> D26
  D26 --> D17
  D12 --> D17
  D12 --> D16
  D13 --> D16
  D17 --> D16
  D16 --> D18
  D6 --> D18
  D16 --> D19
  D18 --> D20
  D19 --> D20
  D16 --> D23
  D20 --> D21
  D23 --> D21
  D21 --> D22
  D19 --> D22
  D13 --> D24
  D14 --> D24
  D15 --> D24
  D22 --> D24
```

D1 and D10 have no dependencies.

## Tasks

### D1: Move the RPC framework out of lain-core into a `lain-rpc` library          [risk: medium]

**Depends on:** none
**Files:**
- `crates/lain-rpc/Cargo.toml` (new), `crates/lain-rpc/src/lib.rs` (new), `crates/lain-rpc/src/support.rs` (new)
- `crates/lain-core/Cargo.toml`, `crates/lain-core/src/main.rs`, `crates/lain-core/src/rpc.rs` (deleted), `crates/lain-core/src/relay.rs`
- `Cargo.lock`

**Reuse:** `src/rpc.rs` whole, with its 27 tests; tokio `UnixStream::peer_cred`; the lint attributes of `src/main.rs:13-14`, plus `#![deny(missing_docs)]` as `lain-wire` has.
**Shared-file wiring:** root `Cargo.toml`: add `"./crates/lain-rpc"` to `members`.
**Reachable from:** `lain-core`'s `main.rs` and `relay.rs` `use lain_rpc::{...}`. The `lain-core` binary still serves `ping` and the relay.

**Acceptance criteria**

```gherkin
Scenario: lain-core behaves the same over the library
  When `cargo test -p lain-core -p lain-rpc` runs
  Then the 27 framework tests pass in lain-rpc, the relay and lifecycle tests pass in lain-core, and the total matches before the move

Scenario: ping keeps the pinned version
  Given a server built with `serve(listener, handler, "0.1.0")`
  Then ping's version is "0.1.0" whatever lain-rpc's own crate version is

Scenario: relay vocabulary leaves the framework
  Then lain-rpc's error enum holds protocol variants plus 1 `Refused { code, message }`
  And the relay maps BadToken, WireVersion, AlreadySettled, NotOpen and TooLarge onto it with the same wire messages

Scenario: every connection knows its peer
  Then a handler's hello and its session see the connecting peer's uid and pid, for Unix connections
```

Spec file: `crates/lain-rpc/src/lib.rs` tests, `crates/lain-core/tests/lifecycle.rs`

**Interface** (final for D2 and D5; later cards add no trait methods)

```rust
pub struct Peer { pub uid: Option<u32>, pub pid: Option<u32> }      // Unix: SO_PEERCRED / getpeereid + LOCAL_PEERPID; TCP: None
pub struct Conn { pub peer: Peer, pub push: Push }                   // Push is inert until D2
pub trait Session: Send + Sync + 'static {
    fn opened(conn: &Conn) -> Self;
    fn closed(&self) -> impl Future<Output = ()> + Send { std::future::pending() }
}
pub trait Handler: Send + Sync + 'static {
    type Session: Session;
    fn requires_hello(&self) -> bool { false }
    fn hello(&self, conn: &Conn, params: Vec<Value>) -> impl Future<Output = Result<(Value, Self::Session), RpcError>> + Send;
    fn call(&self, session: &Self::Session, method: &str, params: Vec<Value>) -> impl Future<Output = Result<Value, RpcError>> + Send;
}
pub async fn serve<A: Accept, H: Handler>(listener: A, handler: H, version: &'static str) -> Infallible;
#[cfg(feature = "test-support")] pub mod support; // start_server, TestClient, request, response_parts
```

**Stop and report if:**
- `peer_cred().pid()` is `None` on macOS under `cargo check --target aarch64-apple-darwin`'s tokio. Report it; D5 then refuses registration there rather than skip the check.
- A relay test needs a framework internal that `test-support` can't expose without making it public API.

### D2: Push frames from the server to 1 connection          [risk: high]

**Depends on:** D1
**Files:** `crates/lain-rpc/src/lib.rs`, `crates/lain-rpc/src/push.rs` (new)
**Reuse:** `write_responses` and its semaphore (`rpc.rs:641-651`); the per-connection writer task.
**Shared-file wiring:** none
**Reachable from:** `serve`. Each connection's `Conn.push` reaches its writer, and a handler keeps it in the session it opens.

**Acceptance criteria**

```gherkin
Scenario: the server pushes to 1 connection
  Given a session holding its Push
  When the handler pushes ("answer", [x])
  Then that client reads [2, "answer", [x]], and other clients read nothing

Scenario: a slow client can't stall the server
  Given a client that never reads
  When 300 pushes are sent to it
  Then the push queue's bound (256) closes that connection, and others keep their responses

Scenario: a push and a response never interleave
  Then both go through the connection's 1 writer, whole frame by whole frame

Scenario: a client can't send pushes
  Then a [2, ...] frame from a client gets the arity or kind error, as rpc.rs did
```

Spec file: `crates/lain-rpc/src/push.rs` tests, `crates/lain-rpc/src/lib.rs` tests

**Interface**

```rust
pub struct Push { /* bounded mpsc (256) to the connection's writer, separate from response permits */ }
impl Push { pub fn send(&self, method: &str, params: Vec<Value>) -> Result<(), Closed>; } // try_send; Closed when full or gone
```

**Stop and report if:**
- A response permit has to be taken for a push to keep frame order. Report the design before changing the permit rule.

### D3: Receive pushed frames in `Core::Client`          [risk: medium]

**Depends on:** D2
**Files:** `lib/lain/core/client.rb`, `spec/lain/core/client_spec.rb`
**Reuse:** `Client#call`'s msgid demux and `drain`/`deliver` (`client.rb:93, 216-222`).
**Shared-file wiring:** none
**Reachable from:** `Lain::Daemon::Registration` (D7), which builds `Core::Client.start(transport:, pushes:)` inside the chat's reactor.

**Acceptance criteria**

```gherkin
Scenario: a pushed frame reaches the subscriber queue
  Given a client started with a pushes queue
  When the server pushes [2, "offer", [r]]
  Then the queue receives ("offer", [r]) once, and pending calls still resolve by msgid

Scenario: no subscriber
  Given a client started without a pushes queue
  Then a pushed frame is dropped, and 1 note says so (today the drop is silent)

Scenario: the reader never blocks on a subscriber
  Then pushes go into an Async::Queue the caller drains; the reader fiber never runs subscriber code
```

Spec file: `spec/lain/core/client_spec.rb` (a mock transport; a `:core` block once D25 lands)

**Stop and report if:**
- A pushed frame's arrival reorders a response that follows it.

### D4: Create the `lain-daemon` binary          [risk: medium]

**Depends on:** D1
**Files:** `crates/lain-daemon/Cargo.toml` (new), `crates/lain-daemon/src/main.rs` (new), `crates/lain-daemon/tests/lifecycle.rs` (new), `Cargo.lock`, `Rakefile`, `spec/rakefile_spec.rb`
**Reuse:** `lain-core`'s `main.rs` (argv, tracing to a file, `shutdown_signal`, exit codes), `relay.rs`'s `clear_stale_socket`, and `lain-rpc::serve`.
**Shared-file wiring:** root `Cargo.toml`: add `"./crates/lain-daemon"` to `members`.
**Reachable from:** `Lain::Daemon.ensure` (D6) runs it through `Daemon::Launch`. `rake daemon:build` builds it.

**Acceptance criteria**

```gherkin
Scenario: the daemon answers on its socket
  When `lain-daemon --socket <0700 dir>/daemon.sock --trace <dir>/daemon.trace --launch-digest abc` starts
  Then ping returns version "0.1.0" and its pid, and daemon.info returns its build id (crate version and git sha) and the launch digest "abc"

Scenario: a second daemon refuses
  Given a live daemon on the socket
  When another starts on the same path
  Then it exits 1 naming the socket in use, and the first keeps serving

Scenario: SIGTERM is clean
  Then the daemon exits 0 and removes its socket

Scenario: it never writes to a terminal
  Then the crate denies clippy print_stdout and print_stderr and missing_docs, and forbids unsafe code
```

Spec file: `crates/lain-daemon/tests/lifecycle.rs`, `spec/rakefile_spec.rb` (`daemon:build`)

**Stop and report if:**
- The binary has to compute its own socket path. Path policy stays in Ruby (`Paths#runtime_dir`).

### D5: Register sessions, checking who is calling          [risk: high]

**Depends on:** D4
**Files:** `crates/lain-daemon/src/main.rs`, `crates/lain-daemon/src/registry.rs` (new), `crates/lain-wire/src/lib.rs`
**Reuse:** `Conn.peer` (D1); `Liveness`'s `pid, start, host` triple, with the start read the same way (`/proc/<pid>/stat` field 22 on Linux, `ps -o lstart=` on macOS).
**Shared-file wiring:** none
**Reachable from:** the daemon's local `Handler`, built in `main.rs`, method `session.register`. The session opened for the connection holds its `Conn`, so the call sees the peer.

**Acceptance criteria**

```gherkin
Scenario: a chat registers itself
  Given a connection from pid 4242
  When it calls session.register with session_id (its journal stem), pid 4242, host, root, cwd, input socket, journal, attended, started_at
  Then the daemon reads pid 4242's start itself, keys the record by session_id, and session.list shows it

Scenario: a process can't register as another
  Given a connection from pid 5000 registering pid 4242
  Then it is refused, and nothing is listed

Scenario: a registered session's children can't register
  Given session A registered by pid 4242
  When pid 4300, whose parent chain reaches 4242, registers
  Then it is refused, naming the parent session

Scenario: items carry the registration's identity, not the payload's
  When a session publishes an item claiming project "other"
  Then the agenda shows the registration's root as its project

Scenario: no local method answers anything
  When a local client calls answer.send, agenda.next or any phone method
  Then it gets UnknownMethod

Scenario: a session ends when its connection does
  Then session.list drops it when the connection closes
```

Spec file: `crates/lain-daemon/src/registry.rs` tests, `crates/lain-daemon/tests/lifecycle.rs`

**Interface**

```rust
// lain-wire
pub struct Register { pub session_id: String, pub pid: u32, pub host: String, pub root: String, pub cwd: String,
                      pub input_socket: Option<String>, pub journal: Option<String>, pub attended: bool, pub started_at: String }
```

**Stop and report if:**
- The parent chain can't be read on macOS without `unsafe` (`kern.proc` via libc). Shell to `ps -o ppid=` instead, and report the cost.

### D6: Start the daemon on demand from Ruby, with 1 launch value          [risk: high]

**Depends on:** D4
**Files:**
- `lib/lain/daemon.rb` (new), `lib/lain/daemon/launch.rb` (new), `lib/lain/paths.rb`
- `spec/lain/daemon_spec.rb` (new), `spec/lain/daemon/launch_spec.rb` (new), `spec/support/lain_daemon.rb` (new)

**Reuse:**
- `Core::Transport::Unix` (0700 directory and peer-uid checks);
- `FileLock`;
- `GcSchedule`'s detached spawn (`cli/gc_schedule.rb:29`);
- `Exec::ChildEnv`'s allowlist idea, with its own list.

**Shared-file wiring:** none
**Reachable from:** `::Lain::Daemon.ensure(paths:)`, called by D7's registration and every `lain daemon` command. Always root-qualified inside `Lain::CLI`.

**Acceptance criteria**

```gherkin
Scenario: no daemon, one is started
  Given no daemon socket
  When Daemon.ensure runs
  Then it starts lain-daemon with setsid, cwd "/", stdio on /dev/null, unsetenv_others and the launch's env allowlist, waits for ping, and returns a connected client

Scenario: 4 callers at once start 1 daemon
  Then exactly 1 daemon runs, and all 4 connect to it

Scenario: a daemon from another launch is replaced when idle
  Given a running daemon whose daemon.info launch digest differs from this launch's
  When ensure runs and the daemon reports no live runs
  Then it is stopped and a new one started
  And with live runs, it is kept, and 1 note says a restart is pending

Scenario: an unbuilt binary degrades loudly
  Then ensure returns Daemon::Absent with a note naming `rake daemon:build`, and Absent's registration is a Null registration

Scenario: specs don't leak daemons
  Then Daemon.ensure returns Absent in specs unless the example opts in with :daemon, and an opted-in example gets its own runtime dir and its daemon is reaped
```

Spec file: `spec/lain/daemon_spec.rb`, `spec/lain/daemon/launch_spec.rb`

**Interface**

```ruby
module Lain::Daemon
  def self.ensure(paths:, launch: Launch.current(paths:), notes: Sink::Null.new) = ... # => Core::Client | Absent
  def self.socket(paths:) = ...                       # runtime_dir/daemon/daemon.sock
  Launch = Data.define(:binary, :socket, :trace, :ruby, :lain, :env, :flags) # flags grow per card: relay (D11), ntfy (D12), runs (D16), poll (D19)
  class Launch; def argv = ...; def digest = ...; end # digest over binary mtime and size, ruby, lain, env names and flags
  class Absent; def registration(...) = Registration::Null.new; end
end
```

**Stop and report if:**
- `Paths#runtime_dir` falls back to `/tmp/lain` (macOS) and the 0700 check fails on an existing directory.
- 2 callers with different `XDG_RUNTIME_DIR` would start 2 daemons. Report it; the socket path is the caller's.

### D25: Run the `:core` tier in CI and pre-commit          [risk: low]

**Depends on:** D4, D6
**Files:** `.github/workflows/main.yml`, `.pre-commit-config.yaml`, `spec/support/tags.rb`, `spec/support/lain_daemon.rb`
**Reuse:** the existing `:core` tag and its skip (`tags.rb:205-225`); the ruby-checks hook (`.pre-commit-config.yaml:122`).
**Shared-file wiring:** none
**Reachable from:** CI's Ruby job, and the pre-commit hook on `crates/lain-(rpc|daemon|wire)/`, `lib/lain/daemon*`, `lib/lain/core/` and `lib/lain/approval/remote_surface.rb`.

**Acceptance criteria**

```gherkin
Scenario: CI runs the daemon tier
  Then CI runs `rake daemon:build && bundle exec rspec --tag core --tag daemon`, and a missing binary fails the job rather than skipping

Scenario: pre-commit runs it on daemon changes
  When a commit stages a file under crates/lain-daemon/
  Then the hook builds the daemon and runs the :core and :daemon tags
```

Spec file: none (CI and hook config); the tags' behaviour is pinned in `spec/support/tags.rb`'s own examples if any, else by the job.

**Stop and report if:**
- The tier's wall time on this box exceeds 60 s. Report it before adding it to every matching commit.

### D7: Register every chat with the daemon          [risk: high]

**Depends on:** D3, D5, D25
**Files:**
- `lib/lain/daemon/registration.rb` (new), `lib/lain/cli/chat_launch.rb`, `lib/lain/cli/repl/conversation_scope.rb`, `lib/lain/cli/wiring.rb`, `lib/lain/live_sessions.rb`, `lib/lain/live_sessions/record.rb`
- `spec/lain/daemon/registration_spec.rb` (new), `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/cli/repl/conversation_scope_spec.rb`, `spec/lain/live_sessions_spec.rb`

**Reuse:** `LiveSessions::Record` (T31) as the payload; `Liveness::Writer.current`; `Core::Client` with a pushes queue (D3).
**Shared-file wiring:** none
**Reachable from:** `ChatLaunch` builds a `Daemon::Registration` value (or `Registration::Null` when `ensure` returns `Absent`) and passes it through `@wiring_factory`. `ConversationScope#open`, inside the chat's reactor, connects it, and `#close` stops it.

**Acceptance criteria**

```gherkin
Scenario: a chat is listed while it runs
  When a chat starts
  Then the daemon's session.list holds its record, keyed by its journal stem, and after it closes, it doesn't

Scenario: the file registry is gone
  Then nothing writes state_home/live/, and LiveSessions#each reads session.list

Scenario: subscribers get pushes by method
  Then Registration#on("answer") and #on("offer") hand each pushed frame to its 1 subscriber

Scenario: a daemon restart re-registers and tells subscribers
  When the daemon is killed and started again
  Then the registration reconnects and re-registers before it delivers anything else, and its subscribers get a :reconnected event

Scenario: no daemon, no crash
  Given Absent
  Then the chat runs, LiveSessions#each is empty, and 1 note says the queue can't find chats
```

Spec file: `spec/lain/daemon/registration_spec.rb` (`:daemon`), `spec/lain/cli/chat_launch_spec.rb`

**Interface**

```ruby
class Lain::Daemon::Registration
  def initialize(record:, ensure:, notes:) = ...
  def open(task) = ...            # connect + register inside the reactor; reconnect loop
  def close = ...
  def call(method, *params) = ... # requests, for example agenda.publish
  def on(method, &handler) = ...  # push subscribers; :reconnected is also delivered here
  class Null; def open(_) = nil; def close = nil; def call(*) = nil; def on(*) = nil; end
end
```

**Stop and report if:**
- Parity fails: a case `review-queue-hud.md` T31's spec covered is not covered here. Keep T31's writer until it passes.

### D9: Run the phone relay as a confined daemon worker          [risk: high]

**Depends on:** D5
**Files:**
- `crates/lain-daemon/src/main.rs`, `crates/lain-daemon/src/relay.rs` (new; moved), `crates/lain-daemon/src/relay/agenda.rs` (new; moved), `crates/lain-daemon/src/relay/devices.rs` (new; moved), `crates/lain-daemon/src/registry.rs`
- `crates/lain-daemon/tests/relay.rs` (new), `crates/lain-daemon/Cargo.toml`

**Reuse:** lain-core's relay code and its 47 tests; `listen_rule`; `confine`; the `Lain` and `Phone` handlers.
**Shared-file wiring:** none
**Reachable from:**
- The daemon starts `lain-daemon relay --listen A --devices-file F` as a child, with its end of a socketpair as the child's stdin, when it was launched with `--relay A --devices-file F`.
- The main daemon forwards each session's `agenda.publish` to the worker, tagged with the session, and pushes each answer back on the owning session's connection.
- `lain-daemon relay --unix S ...` stays as a standalone mode for `apps/lain-remote`'s tests.

**Acceptance criteria**

```gherkin
Scenario: the worker is confined as the relay was
  When the daemon starts its relay worker
  Then the worker applies Landlock to the devices directory and nothing else writable, and exits 3 if the kernel enforces nothing
  And the main daemon keeps running, and daemon.info reports the relay as unavailable

Scenario: answers go only to their session
  Given sessions A and B each publishing 1 parked call
  When the phone answers A's item
  Then only A's connection gets the answer push

Scenario: a gate shared by 2 chats is 1 item
  Given 2 sessions in 1 root publishing the same gate (same artifact digest)
  Then the worker's agenda holds it once, and an answer reaches the newest of the 2

Scenario: the relay's old guarantees hold
  Then the moved tests pass: tailnet-or-loopback only, a revoke closing the device's connection, constant-time token check, a stale cursor getting a reset
```

Spec file: `crates/lain-daemon/tests/relay.rs`, the moved unit tests in `crates/lain-daemon/src/relay.rs`

**Stop and report if:**
- Landlock can't be applied after the worker receives its socket as stdin. Report the ABI behaviour; don't drop the confinement.

### D8: Put sessions on the wire, version 2          [risk: high]

**Depends on:** D9
**Files:**
- `crates/lain-wire/src/lib.rs`, `crates/lain-daemon/src/relay.rs`, `crates/lain-daemon/src/relay/agenda.rs`
- `apps/lain-remote/src/client.rs`, `lib/lain/remote/wire.rb`, `spec/lain/remote/wire_spec.rb`

**Reuse:** lain-wire's map and 1-key-enum encoding; `Remote::Wire`'s declarative mirror.
**Shared-file wiring:** none
**Reachable from:** the relay worker's `Phone` handler; the app's `Session::connect`.

**Acceptance criteria**

```gherkin
Scenario: the phone sees which session an item is from
  Given sessions A and B each publishing 1 item
  When the phone reads agenda.next
  Then each item carries its session and project, from the registration

Scenario: the same bytes in Rust and Ruby
  Then AgendaItem's session and project, and Answer's session, round-trip identically through lain-wire and Remote::Wire

Scenario: an old phone is told
  Given an app sending wire_version 1
  Then hello is refused with WireVersion, naming the app update

Scenario: the app builds
  Then `cargo build` and the app's tests pass in apps/lain-remote against wire 2, with its relay harness using `lain-daemon relay --unix`
```

Spec file: `crates/lain-wire/src/lib.rs` tests, `spec/lain/remote/wire_spec.rb`

**Stop and report if:**
- Ruby's msgpack decodes a field differently from serde. Pin the bytes in both specs.

### D10: Move `remote relay:` and `remote ntfy:` to the user config          [risk: low]

**Depends on:** none
**Files:** `lib/lain/config/builder.rb`, `lib/lain/config.rb`, `lib/lain/cli/up.rb`, `spec/lain/config/builder_spec.rb`, `spec/lain/cli/up_spec.rb`
**Reuse:** `USER_VERBS` (`builder.rb:54`) and the user-file reader; `refuse_project_only`'s wording.
**Shared-file wiring:** `docs/commands.md`: the `remote` verb moves to the user file.
**Reachable from:** `Config.remote(paths:)`, read by `Up::Relay` until D11, and by `Daemon::Launch` after.

**Acceptance criteria**

```gherkin
Scenario: the user file sets the relay
  Given `remote relay: "100.64.0.1:7820", ntfy: "https://ntfy.sh/x"` in the user config
  Then Config.remote(paths:) returns both, and `lain up` starts its relay from them

Scenario: a project file is told where it moved
  Given `remote relay: ...` in a project .lain/config.rb
  Then loading refuses, naming the user config path
```

Spec file: `spec/lain/config/builder_spec.rb`, `spec/lain/cli/up_spec.rb`

**Stop and report if:**
- `spec/docs_config_examples_spec.rb` evaluates the `remote` example as a project verb.

### D11: Publish approvals and receive answers through the registration          [risk: high]

**Depends on:** D7, D8, D10
**Files:**
- `lib/lain/approval/remote_surface.rb`, `lib/lain/daemon/launch.rb`, `lib/lain/cli/up.rb`, `lib/lain/cli/wiring.rb`
- `spec/lain/approval/remote_surface_spec.rb`, `spec/lain/cli/up_spec.rb`, `spec/lain/daemon/launch_spec.rb`

**Reuse:** `Remote::Agenda` and `Agenda::View` unchanged; `RemoteSurface`'s retract and degrade paths; `Registration#call` and `#on` (D7).
**Shared-file wiring:** none
**Reachable from:**
- `Wiring#remote_surface` builds `RemoteSurface.for(config:, registration:, queue:, ...)` over the chat's `Daemon::Registration`, for every chat with a queue, when the user config sets `remote relay:`.
- `Daemon::Launch` adds `--relay` and `--devices-file` from `Config.remote(paths:)`.

**Acceptance criteria**

```gherkin
Scenario: answers arrive as pushes
  Given a chat registered and a paired phone
  When a call parks and the phone approves
  Then the publish goes out on the next 0.25 s sweep as an agenda.publish request, and the answer arrives as a push, with no answers long-poll

Scenario: a refusal still reaches the surface
  Given an item the worker refuses as TooLarge
  Then RemoteSurface sees the refusal, as today

Scenario: after a daemon restart the phone sees everything again
  When the registration delivers :reconnected
  Then the surface republishes its open items from cursor 0, and doesn't degrade

Scenario: the per-project relay and its prefix are gone
  Then `lain up` opens no relay window, Up::Relay is deleted, no code reads remote-<hash>/relay.sock, and the surface keeps no id prefix

Scenario: the phone specs pass against the daemon
  Then remote_surface_spec's built-relay block (approve, masking, desk wins, phone loses as remote_answer_lost, retract on stop, degrade on death) passes against lain-daemon
```

Spec file: `spec/lain/approval/remote_surface_spec.rb` (`:daemon`)

**Stop and report if:**
- A call settled at the desk while the phone answers stops journaling `remote_answer_lost`. That record is pinned.

### D12: Send ntfy from the daemon, once per item          [risk: medium]

**Depends on:** D11
**Files:**
- `crates/lain-daemon/src/main.rs`, `crates/lain-daemon/src/ntfy.rs` (new), `crates/lain-daemon/src/agenda_watch.rs` (new), `crates/lain-daemon/Cargo.toml`, `Cargo.lock`, `deny.toml`
- `lib/lain/remote/ntfy.rb` (deleted), `spec/lain/remote/ntfy_spec.rb` (deleted), `lib/lain/approval/remote_surface.rb`, `lib/lain/daemon/launch.rb`
- `spec/lain/approval/remote_surface_spec.rb`, `spec/lain/cli/wiring_spec.rb`

**Reuse:** `Remote::Ntfy`'s title, sanitising, `Actions` header and 60 s delay, ported; `ureq` with `rustls`.
**Shared-file wiring:** none
**Reachable from:**
- `agenda_watch.rs` keeps each item's open time and fires 1 POST at 60 s with no answer.
- `Daemon::Launch` adds `--ntfy URL` from `Config.remote(paths:)`.

**Acceptance criteria**

```gherkin
Scenario: 2 chats, 1 buzz per item
  Given chats A and B, each with 1 call parked over 60 s, and a gate both publish
  Then exactly 3 POSTs go out, 1 per distinct item, and none on a re-publish after a reconnect

Scenario: the buzz carries nothing of the item
  Then the body is "Open lain to answer.", the title is "lain <kind> waiting on <requester>" in ASCII, and the action opens lain-remote://item/<id>

Scenario: ntfy is down
  Then the daemon writes 1 trace line per distinct error, and the agenda is unaffected
```

Spec file: `crates/lain-daemon/src/ntfy.rs` tests (a local HTTP stub), `crates/lain-daemon/src/agenda_watch.rs` tests (paused tokio clock)

**Stop and report if:**
- `cargo deny` refuses `ureq` or `rustls`. Report the licence or advisory before choosing another client.

### D13: Route review-queue offers through the daemon          [risk: high]

**Depends on:** D7, D8, D9, D11
**Files:**
- `crates/lain-daemon/src/registry.rs`, `crates/lain-wire/src/lib.rs`
- `lib/lain/review/queue/delivery.rb`, `lib/lain/cli/input_socket.rb`, `lib/lain/frontend/intake/offer.rb`
- `spec/lain/review/queue/delivery_spec.rb`, `spec/lain/cli/input_socket_spec.rb`, `spec/lain/frontend/intake/offer_spec.rb`

**Reuse:** `Review::Queue::Request` and its `to_h` (T23); `Intake#offer` (T24); newest-attended-in-root (T25); `Registration#on("offer")` (D7).
**Shared-file wiring:** none
**Reachable from:** `lain queue open <id>` → `Delivery` → `Daemon.ensure` → `offer.send { root, request }`. The daemon pushes `offer` to the newest attended session in that root. That chat's registration hands it to `Intake#offer`, which runs `Request.load` before showing anything.

**Acceptance criteria**

```gherkin
Scenario: the offer reaches the chat in its checkout
  Given 2 attended chats registered in /work/api, started 09:00 and 10:00
  When `lain queue open pr:fuze/api#12` runs
  Then the 10:00 chat shows the offer and still needs a keypress, and the command's output names the 09:00 chat

Scenario: the request is opaque to the daemon
  Then lain-wire's Offer is { root: String, request: Map }, the daemon never reads request's fields, and the chat refuses a request that fails Request.load

Scenario: the input socket no longer takes offers
  Then InputSocket has no offer frame, and Delivery never opens an input socket
```

Spec file: `spec/lain/review/queue/delivery_spec.rb` (`:daemon`), `crates/lain-daemon/src/registry.rs` tests

**Stop and report if:**
- Parity fails against T25's spec cases. Keep the socket path until it passes.

### D14: Retire the `lain-core` binary          [risk: medium]

**Depends on:** D11, D12
**Files:**
- `crates/lain-core/` (deleted), `Rakefile`, `spec/rakefile_spec.rb`, `spec/support/core_daemon.rb` (deleted), `spec/support/tags.rb`
- `lib/lain/core.rb`, `lib/lain/core/client.rb`, `lib/lain/core/transport/unix.rb`, `spec/lain/core/client_spec.rb`
- `.github/workflows/main.yml`, `.pre-commit-config.yaml`, `bin/setup`, `bin/spec-census`, `deny.toml`
- `docs/rust-bindings.md`, `docs/concurrency.md`, `docs/GLOSSARY.md`

**Reuse:** `spec/support/lain_daemon.rb` (D6) in place of `CoreDaemon`.
**Shared-file wiring:** root `Cargo.toml`: remove `"./crates/lain-core"`. `ARCHITECTURE.md`: the lain-core section becomes lain-rpc, lain-daemon and the relay worker. `CLAUDE.md`: the `:core` lines name `rake daemon:build`.
**Reachable from:** not applicable; this card deletes.

**Acceptance criteria**

```gherkin
Scenario: nothing names lain-core
  When the repo is grepped for lain-core or core:build, outside planning/ and references/
  Then there are 0 hits, and `rake daemon:build` builds lain-daemon

Scenario: the :core tier runs against the daemon
  When `bundle exec rspec --tag core` runs
  Then every example that booted lain-core passes against lain-daemon, with the same count
```

Spec file: `spec/rakefile_spec.rb`, `spec/lain/core/client_spec.rb`

**Stop and report if:**
- `review-queue-hud.md` T1's macOS gating in lain-core has no counterpart in lain-daemon's relay worker.

### D15: Group the phone app's agenda by session and open items from ntfy          [risk: medium]

**Depends on:** D8
**Files:** `apps/lain-remote/src/client.rs`, `apps/lain-remote/src/ui/agenda.rs`, `apps/lain-remote/src/main.rs`
**Reuse:** the app's agenda view and `Session` cursor; Dioxus routing.
**Shared-file wiring:** none
**Reachable from:** the app's main view, and its `lain-remote://item/<id>` handler.

**Acceptance criteria**

```gherkin
Scenario: items are grouped
  Given items from 2 sessions in 2 projects
  Then the agenda shows a header per project and session, with each item under it

Scenario: an ntfy link opens its item
  When the app opens lain-remote://item/<id>
  Then it selects that item, or says it is already settled
```

Spec file: `apps/lain-remote` tests (its own workspace, run by CI's lain-remote job)

**Stop and report if:**
- The Android build can't register the `lain-remote://` scheme from Dioxus 0.7 config.

### D26: Replace `attended?` with a `Human` value          [risk: high]

**Depends on:** D11, D12
**Files:**
- `lib/lain/cli/human.rb` (new), `lib/lain/cli/wiring.rb`, `lib/lain/cli/repl/approval_surfaces.rb`, `lib/lain/cli/switchboard.rb`, `lib/lain/cli/wiring/askers.rb`
- `spec/lain/cli/human_spec.rb` (new), `spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/repl/approval_surfaces_spec.rb`, `spec/lain/cli/switchboard_spec.rb`

**Reuse:** `Wiring#attended?`'s 14 readers (`wiring.rb:176-180`), each mapped to the `Human` question it really asks.
**Shared-file wiring:** none
**Reachable from:** `Wiring` builds `Human.from(options)` once and passes it where `attended?` went.

**Acceptance criteria**

```gherkin
Scenario: today's 2 modes keep every behaviour
  Then Human.from without --non-interactive is :terminal, with it is :none, and every existing spec of the 14 readers passes unchanged

Scenario: the questions are named
  Then each reader asks a named question (Human#answers_at_terminal?, #can_be_asked?, #ladder_refuses?) rather than comparing kinds
```

Spec file: `spec/lain/cli/human_spec.rb`, `spec/lain/cli/wiring_spec.rb`

**Interface**

```ruby
class Lain::CLI::Human
  KINDS = %i[terminal remote none].freeze
  def self.from(options) = ...      # :remote arrives in D17
  def answers_at_terminal? = ...
  def can_be_asked? = ...
  def ladder_refuses? = ...
end
```

**Stop and report if:**
- A reader of `attended?` means something none of the 3 questions covers. Name it and add the question; don't compare kinds at the call site.

### D17: Park and route a headless session's asks with `--human remote`          [risk: high]

**Depends on:** D26, D12
**Files:**
- `lib/lain/cli/human.rb`, `lib/lain/cli/wiring.rb`, `lib/lain/cli/repl/approval_surfaces.rb`, `lib/lain/cli/exe/asking_flags.rb`, `lib/lain/cli/chat_launch.rb`, `lib/lain/confine/sandbox.rb`
- `spec/lain/cli/human_spec.rb`, `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/approval/remote_surface_spec.rb`, `spec/lain/cli_spec.rb`

**Reuse:**
- `Approval::Parked::Queue` with its 300 s default and the hold-on-silence rule (ruling 2026-11-03);
- `RemoteSurface` (D11) as the only surface;
- `Tools::AskHuman`'s real path;
- `Confine::Profile.confines?` and `Sandbox#confines?`.

**Shared-file wiring:** none
**Reachable from:** `lain chat --non-interactive --human remote`, as D16's run kinds launch it. `Human.from` returns `:remote`, and `Wiring` builds the queue and asker as for an attended chat, with `RemoteSurface` as their only surface.

**Acceptance criteria**

```gherkin
Scenario: a gated call parks and you answer from the phone
  Given a headless chat with --human remote, a confining sandbox, and a registered daemon with a relay
  When the judge abstains on a call
  Then the call parks, reaches the phone, and your approve runs it, journaled with authority human and surface remote:<device>

Scenario: no terminal surface starts
  Then under :remote, ApprovalSurfaces starts RemoteSurface only, not the terminal policy

Scenario: ask_human waits for you
  Then the agent's question reaches the agenda, and your answer returns to it

Scenario: silence holds
  When nobody answers in 300 s
  Then the call is held, not approved

Scenario: refused without containment (ruling 2026-11-16)
  Given the sandbox can't confine (fence missing, or macOS)
  Then the chat refuses to start, naming the missing containment and the threat it closes

Scenario: no unconfined bash under --human remote
  When an approved bash call would run under the traced or none profile
  Then it is denied, naming --human remote

Scenario: the confined profile can't reach the phone path
  Then a confined bash call can't write state_home/remote/devices, and can't connect to the relay's loopback port

Scenario: without the flag nothing changes
  Then every pinned --non-interactive refusal passes unchanged

Scenario: --human remote needs a relay
  Given the daemon reports no relay
  Then the chat refuses to start, naming `remote relay:` in the user config
```

Spec file: `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/approval/remote_surface_spec.rb` (`:daemon`), `spec/lain/confine/sandbox_spec.rb` (the 2 reach checks, `:seam`)

**Stop and report if:**
- A confined profile can reach the devices file or the relay port. That is a security finding: stop and report it.
- A parked call in a headless session blocks the conductor differently from an attended one.

### D16: Supervise headless runs from a closed set of kinds          [risk: high]

**Depends on:** D12, D13, D17
**Files:** `crates/lain-daemon/src/main.rs`, `crates/lain-daemon/src/supervisor.rs` (new), `crates/lain-wire/src/lib.rs`, `crates/lain-daemon/tests/supervisor.rs` (new), `lib/lain/daemon/launch.rb`, `spec/lain/daemon/launch_spec.rb`
**Reuse:** `Chores::Runner`'s argv (`chores/runner.rb:162`); `std::process::Command` with `process_group(0)`.
**Shared-file wiring:** none
**Reachable from:**
- the daemon's local handler: `run.start { kind, root, args }`, `run.list`, `run.stop`;
- `Daemon::Launch` adds `--ruby`, `--lain`, `--max-cost` (from the user config) and the run env allowlist.

**Acceptance criteria**

```gherkin
Scenario: a run kind builds its own argv
  When run.start { kind: "epic", root: R, args: { slug: "research-x" } } arrives
  Then the daemon runs `<ruby> <lain> chat --root R --cwd R --non-interactive --approval auto --human remote --max-cost N --prompt "/implement-epic research-x"` in its own process group, with the allowlisted env and output to state_home/daemon/runs/<id>.log

Scenario: inputs are checked, not trusted
  Then run.start is refused when the kind is unknown, when argv, approval or env keys are passed, when the slug doesn't match [a-z0-9-]+ or names no epic under R, or when R has no lain project marker

Scenario: exits are recorded
  When a run exits 3
  Then run.list shows status 3 and its log, and its session left the registry

Scenario: stopping a run stops its group
  When run.stop runs
  Then the group gets TERM, then KILL after 10 s
```

Spec file: `crates/lain-daemon/tests/supervisor.rs`, `spec/lain/daemon/launch_spec.rb`

**Interface**

```rust
pub enum RunKind { Epic { slug: String }, ReviewPoll, Chores }
pub struct Run { pub id: String, pub kind: RunKind, pub root: PathBuf, pub pid: u32, pub started: SystemTime, pub ended: Option<i32>, pub log: PathBuf }
```

**Stop and report if:**
- Checking that the epic exists needs lain's epic home rules in Rust. Then the slug check is the regex only, and the run's own chat refuses a missing epic. Report it.

### D18: Add `lain daemon` for status, runs and restarts          [risk: medium]

**Depends on:** D16, D6
**Files:** `lib/lain/cli/daemon_command.rb` (new), `spec/lain/cli/daemon_command_spec.rb` (new), `spec/lain/cli_spec.rb`
**Reuse:** `Lain::CLI::HerdrLink` (a Thor class in `lib/`, printing with `say`); `Lain::CLI::Exe::Boundary`.
**Shared-file wiring:** `exe/lain`: `subcommand "daemon", Lain::CLI::DaemonCommand`. `docs/commands.md`: `### lain daemon`.
**Reachable from:** `lain daemon status|runs|ensure|restart|stop RUN` and `lain daemon run epic SLUG|chores`. The run's root is the current project (`Project::Resolver.default_project`).

**Acceptance criteria**

```gherkin
Scenario: status shows sessions and runs
  Then `lain daemon status` prints the daemon's pid, uptime, build, whether the relay is up, each registered session and each run

Scenario: an epic runs with the terminal closed
  When `lain daemon run epic research-x` runs in a project and the terminal closes
  Then the run keeps going, and `lain daemon runs` shows it

Scenario: restart waits for runs
  When `lain daemon restart` runs with 1 live run
  Then it refuses, naming the run, unless --force is given

Scenario: no daemon binary
  Then each command exits 1 naming `rake daemon:build`
```

Spec file: `spec/lain/cli/daemon_command_spec.rb`, `spec/lain/cli_spec.rb`

**Stop and report if:**
- `/implement-epic` in a headless session needs a gesture `--human remote` can't route, for example an nvim review. Report which step.

### D19: Run the review poll as a daemon task          [risk: low]

**Depends on:** D16
**Files:** `crates/lain-daemon/src/supervisor.rs`, `crates/lain-daemon/src/periodic.rs` (new), `crates/lain-daemon/tests/supervisor.rs`, `lib/lain/daemon/launch.rb`, `spec/lain/daemon/launch_spec.rb`
**Reuse:** `RunKind::ReviewPoll`, which runs `lain queue poll` as a process (`review-queue-hud.md` T28).
**Shared-file wiring:** none
**Reachable from:** the daemon's start with `--poll-every 300`, which `Daemon::Launch` adds when the user config has a `github` verb.

**Acceptance criteria**

```gherkin
Scenario: the poll runs every 5 minutes
  Given a daemon started with --poll-every 300 (paused tokio clock)
  Then 1 ReviewPoll run starts at 0 s, 300 s and 600 s

Scenario: a slow poll isn't doubled
  Given a poll still running at the next tick
  Then that tick is skipped, with 1 trace line

Scenario: the gh account reaches the poll
  Given LAIN_GH_ACCOUNT in the launch's env allowlist
  Then the poll run's env has it
```

Spec file: `crates/lain-daemon/tests/supervisor.rs`, `spec/lain/daemon/launch_spec.rb`

**Stop and report if:**
- The review count goes stale after a reboot because nothing ran `lain daemon ensure`. E3 covers it; report if it doesn't.

### D20: Show headless runs in herdr          [risk: low]

**Depends on:** D18, D19
**Files:** `lib/lain/cli/daemon_command.rb`, `crates/lain-daemon/src/supervisor.rs`, `spec/lain/cli/daemon_command_spec.rb`, `crates/lain-daemon/tests/supervisor.rs`
**Reuse:** `Herdr::Workspaces#token` (`review-queue-hud.md` T27).
**Shared-file wiring:** none
**Reachable from:** the supervisor runs `lain daemon herdr-sync` when a run starts, ends, parks or unparks. Parks and unparks are seen from the run session's publishes. The command reads `run.list` and sets the `runs` token on the `lain` workspace.

**Acceptance criteria**

```gherkin
Scenario: the lain workspace lists runs
  Given 1 epic run working and 1 blocked on you
  When herdr-sync runs
  Then the `lain` workspace token reads "epic research-x: blocked; chores: working"

Scenario: no herdr, or no lain workspace
  Then herdr-sync does nothing and exits 0
```

Spec file: `spec/lain/cli/daemon_command_spec.rb`, `crates/lain-daemon/tests/supervisor.rs`

**Stop and report if:**
- herdr-sync runs more than once a second during a busy run. Coalesce in the supervisor.

### D23: Measure run spawning          [risk: low]

**Depends on:** D16
**Files:** `bin/hot-path-bench`, `docs/spec-suite-performance.md`
**Reuse:** `bin/hot-path-bench`'s rows, ceilings and 3-log rule.
**Shared-file wiring:** none
**Reachable from:** `bin/hot-path-bench --record`.

**Acceptance criteria**

```gherkin
Scenario: the exec cost is known before fork work starts
  Then hot-path-bench has a spawn_exec row (run.start to the run's registration), with a ceiling seeded from 3 logs at a load under 2
```

Spec file: none (bench rows; ceilings recorded per CLAUDE.md).

**Stop and report if:**
- spawn_exec is under 300 ms on this box. Report it: phase 3 may not be worth its cost, and the user decides.

### D21: Preload a warmed Ruby spawner          [risk: high]

**Depends on:** D20, D23
**Files:** `lib/lain/cli/daemon_command.rb`, `lib/lain/daemon/spawner.rb` (new), `spec/lain/daemon/spawner_spec.rb` (new)
**Reuse:**
- `ChatPreflightFork`'s child steps (`exe/lain:1706-1800`);
- `Process.warmup`;
- the spike's script;
- the Journal rule: no Journal open in the parent.

**Shared-file wiring:** none
**Reachable from:** `lain daemon spawner`, a hidden command the daemon starts with a socketpair end as its stdin.

**Acceptance criteria**

```gherkin
Scenario: a spawn request forks a session
  Given a spawner booted and warmed
  When it reads {argv, env, cwd, log} on stdin
  Then it forks a child that runs setsid, reopens stdout and stderr onto the run's log, chdir, ENV.replace(env), Config.forget!, re-installs traps, runs LainCLI.start(argv) and leaves with exit!
  And it writes {pid} back, then {pid, status} when the child exits

Scenario: the parent stays a blank slate
  Then after 10 spawns the spawner holds 1 thread, no Journal and no reactor

Scenario: lain's own code changed
  Given the install digest (path, mtime and size of every file under lib/, exe/lain and lib/lain/lain.so) differs from the one taken at boot
  When the next request arrives
  Then the spawner replies :stale and exits, and the daemon restarts it before retrying
```

Spec file: `spec/lain/daemon/spawner_spec.rb` (`:seam`, real fork)

**Stop and report if:**
- A forked child inherits a Rust extension mutex held at fork (`ext/lain/src/nogvl.rs:181, 326`). The spawner must take requests only on its main thread, with no extension call in flight.

### D22: Fork runs from the spawner          [risk: high]

**Depends on:** D21, D19
**Files:** `crates/lain-daemon/src/supervisor.rs`, `crates/lain-daemon/src/spawner.rs` (new), `crates/lain-daemon/tests/supervisor.rs`, `bin/hot-path-bench`
**Reuse:** `Run` and its exit handling (D16), fed from the spawner's `{pid, status}` replies.
**Shared-file wiring:** none
**Reachable from:** `Supervisor::start`, which asks the spawner when it is up and falls back to exec when it isn't.

**Acceptance criteria**

```gherkin
Scenario: a forked run registers before its first turn
  Given a live spawner
  When run.start runs
  Then the run's session registers before its journal records a request

Scenario: the spawner dies
  When the spawner exits
  Then the next run starts by exec, and the daemon restarts the spawner

Scenario: exits are recorded
  Then a forked run's exit status reaches run.list through the spawner

Scenario: the gain is measured
  Then hot-path-bench has spawn_fork and, on Linux, spawn_fork_private_mb rows, seeded per CLAUDE.md
```

Spec file: `crates/lain-daemon/tests/supervisor.rs`

**Stop and report if:**
- spawn_fork isn't at least 5 times faster than spawn_exec. Report it before keeping the spawner on by default.
- A run's process group is the spawner's, so `run.stop` would kill the spawner.

### D24: Write QA scenarios for the daemon          [risk: low]

**Depends on:** D13, D14, D15, D22
**Files:** `planning/qa/scenarios/daemon.md` (new), `planning/qa/scenarios/review-queue.md`, `planning/qa/README.md`
**Reuse:** the scenario format in `planning/qa/scenarios/review-queue.md`.
**Shared-file wiring:** none
**Reachable from:** `/manual-qa`.

**Acceptance criteria**

```gherkin
Scenario: every surface has a happy and an unhappy path
  Then daemon.md drives all of these:
    on-demand start, a launch-digest restart, and killing the daemon mid-session;
    2 chats on 1 phone, with answers reaching the right one and a shared gate shown once;
    ntfy once per item;
    a queue offer to the right chat;
    `lain daemon run epic` with the terminal closed, asking you on the phone;
    silence holding a call;
    the poll as a daemon task, and after a reboot (E3);
    herdr's `lain` workspace;
    a spawner restart after editing lain;
    a fake session registered from inside a chat's bash, which must be refused;
    the agent's bash under the traced profile trying to answer through the daemon or the devices file, which must fail
```

Spec file: none (QA documents).

**Stop and report if:**
- A scenario needs a paired phone and none is available. Mark it manual-only.

## Main-session dotfiles steps

Run after D19 lands, in the dotfiles bare repo (`git --git-dir=$HOME/.cfg --work-tree=$HOME`), staging by explicit path:

- **E1.** Remove `lain-queue-poll.{service,timer}` and run `systemctl --user disable --now lain-queue-poll.timer`. Remove the `com.lain.queue-poll` launchd plist.
- **E2.** Add `remote relay:` and `remote ntfy:` to `~/.config/lain/config.rb`, and run `lain trust --user`.
- **E3.** Add a login hook that runs `lain daemon ensure`. Here that is a oneshot `lain-daemon-ensure.service` wanted by `default.target`. On the Mac it is a launchd agent with `RunAtLoad`. The review count then stays fresh after a reboot.

## Integration checks

- `bundle exec rake pspec` green. Check the example count, not only the failure count.
- `bundle exec rspec --tag core --tag daemon` green against `lain-daemon`.
- `cargo clippy --all-targets -- -D warnings` and `cargo test`.
- `cargo check --target aarch64-apple-darwin --all-targets -p lain-wire -p lain-rpc -p lain-daemon -p lain-fence`.
- `pre-commit run --all-files` and `bin/zeitwerk-census --check`.
- `bin/hot-path-bench --check` with the D22 and D23 rows.
- **Manual QA:** `/manual-qa planning/qa/scenarios/daemon.md`, with the paired phone.
- **On the Mac:** add a daemon step to `lain-macos-bringup.md`. `--human remote` is expected to refuse there.

## Execution log

### Setup (2026-11-17)

- **Base:** `main` at `7eea39c5e92903ae975887cb5ce268c75926fd2f`. `review-queue-hud.md` is `done` (head `38d3f560`). Re-checked the grounding the first ready cards touch: `crates/lain-core/src/rpc.rs` (1,966 lines, the `pub(crate)` traits at the cited lines, `main.rs` lint attributes) and `config/builder.rb` (`USER_VERBS`, `remote`, `refuse_project_only`) still match. `Config.github` and `Up::Relay`'s lines moved; later cards re-read their own grounding.
- **Worktrees at start:** the main checkout, `/home/tara/w/ir`, and 82 stale `tmp/worktrees/<id>` from earlier plans. This run uses `tmp/worktrees/ldm-D<n>` and `card/ldm-D<n>`.
- **Pre-staged user work, unstaged for the run:** `.gitmodules`, `references/repos/cliffcompaction` (gitlink `b48d660a`), `references/repos/pi` (gitlink `36be9c61`). Re-stage at close-out with `git add .gitmodules references/repos/cliffcompaction references/repos/pi`, then check `git ls-files -s` against those SHAs.
- **Hook:** unchanged from the review-queue run. `bundle exec rake compile check` (rubocop plus `rake pspec`) on any Ruby or Rust file; cargo fmt, clippy and test on Rust; `remote-test` (the phone app's tests) on `crates/lain-(wire|core)/` and `Cargo.*`; `cargo deny` on `Cargo.*` and `deny.toml`; `yard-lint --staged`; `bin/lint-gherkin-docs` on plan docs; `bin/lint-commit-msg`. The suite cannot run beside other tests; the example count comes from `tmp/parallel_runtime_rspec.log` and the hook log.
- **Ratchet specs:** every top-level `spec/*_spec.rb` plus the 35 nested scanners listed in `~/tmp/lain/ldm-ratchet-scan.txt`, plus `bin/zeitwerk-census --check` for a card that adds a constant.
- **Build outputs copied at cut:** `lib/lain/lain.so`, `target/release/lain-fence`, `tmp/parallel_runtime_rspec.log`; a Rust card also gets a copy of `target/debug`.
- **Quiet wait:** no test runner, load under 4, memory PSI under 5, 7 GB available, 3 readings 10 s apart (the review-queue run's rule).
- **Concurrency cap:** 15 GB RAM, so about 5 agents with a landing counted as 1.
- **Paths that need user approval:** none in the cards; E1 to E3 run in `~/.cfg` after D19.

### Run log
