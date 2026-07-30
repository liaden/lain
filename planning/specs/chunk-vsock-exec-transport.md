# Chunk — the vsock-native exec transport

status: done
commit-mode: orchestrator-commits
language: ruby + rust
panel: Ruby — Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson;
Rust — Raph Levien, Andrew Gallant, Frank McSherry, Ashley Williams

## Intent

Make Lain's out-of-process exec boundary reachable over `AF_VSOCK`, so `lain-core` can run
inside a guest and the RPC crosses a hypervisor boundary unchanged. This is the
**backend-agnostic** half of the microVM work: the guest-side listener is identical for
Firecracker, libkrun, QEMU/KVM, Cloud Hypervisor, and the kernel's own `vsock_loopback`, so
this chunk commits to no hypervisor and defers the libkrun-vs-Firecracker decision entirely.

Satisfies the ROADMAP M5 line **"Isolation as a swappable backend; egress as an observable
Effect; credential brokering"** — specifically its "microVM / container / bwrap as a *compared*
knob (not just an exec seam)" clause, by building the transport the comparison needs. Grounded
in `references/firecracker-microvm-isolation.md` §4b, §6, §7.

**Out of scope, deliberately:**
- No `Isolation` backend is added, so `BACKENDS` and the exact-ordered-array assertion at
  `spec/lain/cli/isolation_backend_spec.rb:107` are untouched.
- No streaming / msgpack-RPC Notification frames.
- No rootfs, kernel image, or hypervisor launch; no egress filtering.
- **No Firecracker-specific transport.** The `CONNECT <port>\n` / `OK <n>\n` handshake is six
  lines, is already proven in `spike/vsock_relay_poc.rb`, and has no consumer until a
  hypervisor is chosen — and the cited research currently favours libkrun
  (`references/firecracker-microvm-isolation.md:141`, §7 Q5). It belongs to the
  hypervisor-selection chunk. The contract is still exercised in **both** of its shapes here,
  because `Child` *spawns* a daemon and `Transport::Vsock` *attaches* to one; that variation,
  not a third implementation, is what keeps the seam honest.
- **Bench CLI wiring** moved to its own chunk, `chunk-bench-arms-subcommand.md` — it shares no
  file, no dependency edge, and no failure mode with this work, and it spends real API money.

## Grounding

Verified against the working tree on **2026-07-28** (not the `.claude/worktrees/*` staging
copies), by three parallel exploration passes, two executed spikes, and a nine-persona panel
review that corrected four grounding errors (recorded below).

**The seam already half-exists.** `Core::Client.new(child:, socket:, version:)` is public and
accepts an arbitrary socket (`lib/lain/core/client.rb:76`); only `.start` hard-wires
`Child.new(paths:, binary:)` (`client.rb:70-74`). `Child#start` returns a connected `UNIXSocket`
with "ownership passed to caller" (`child.rb:55`). This chunk widens that injection point
rather than inventing it.

**`Client#stop` is `@child.stop; @reader.wait; @socket.close`** (`client.rb:140-145`) — it waits
for the reader fiber *before* closing the socket. `Child` makes that terminate by TERMing the
daemon, which drops the connection. `spike/vsock_loopback_poc.rb` deadlocked here with a no-op
`#stop`. **The plan's first draft promoted this into a contract clause ("every transport's
`#stop` must EOF the wire"); the panel was right that this is an accident of statement ordering
being published as an obligation.** T1 instead has the *client* collapse its own read side
before waiting, which dissolves the obligation entirely — see T1.

**`Client#pid` has no consumer in `lib/` or `exe/`.** Its only readers are
`spec/lain/core/client_spec.rb:75` and `spec/lain/tools/core_exec_spec.rb:176`, both
`Process.kill("KILL", client.pid)`. Once `.start` takes an injected transport, the caller
already holds the `Child` and can kill it directly, so `#pid` becomes dead API rather than
nil-returning API. T1 deletes it.

**The Rust side is concretely typed, more deeply than the first draft claimed.** `main.rs:54`
binds `tokio::net::UnixListener` off argv (`lain-core <socket_path> [tracing_path]`); but the
concreteness runs all the way down — `rpc::serve(listener: UnixListener) -> Infallible`
(`rpc.rs:114`), `serve_connection(stream: UnixStream)` (`rpc.rs:135`), and **both type aliases**:

```rust
type Sink   = SplitSink<Framed<UnixStream, Codec>, Value>;   // rpc.rs:128
type Stream = SplitStream<Framed<UnixStream, Codec>>;        // rpc.rs:129
```

Generalizing the listener therefore forces the connection type and both aliases with it. Two
consequences the first draft missed: `tokio-util` is `features = ["codec"]` only, so
`tokio_util::net::Listener` is not available without a feature bump; and even with it,
`tokio_vsock::VsockListener` could not implement it — foreign trait, foreign type, orphan rule.
A **local** trait is therefore the sanctioned approach, and T2 specifies it rather than leaving
a sub-agent to invent one. `main.rs:63`'s `match never {}` **does** survive, because the
`Infallible` return type is unchanged.

**Spikes already de-risked the transport claim** (`references/firecracker-microvm-isolation.md`
§6). `spike/vsock_relay_poc.rb`: an unmodified `Core::Client` runs ping / exec / cwd /
env-scrub / server-timeout / 8-way concurrent msgid demux through a relay impersonating
Firecracker's handshake (6/6). `spike/vsock_loopback_poc.rb`: the same over genuine `AF_VSOCK`
(7/7), plus a 1 MiB payload and binary-clean stdout. **Read both before starting any card.**
They are also *consumers of the API this chunk changes* — see T1's Files.

Facts a card would otherwise get wrong:
- **`vsock_loopback` autoloads.** No `sudo modprobe` — the first `socket(AF_VSOCK, SOCK_STREAM,
  0)` in any process pulls in `vsock` + `vsock_loopback` unprivileged on kernel 6.8.0-136.
- **Ruby has `Socket::AF_VSOCK == 40` but no `sockaddr_vm` helper.** The 16-byte struct is
  hand-packed: `[Socket::AF_VSOCK, 0, port, cid, 0, 0, 0, 0].pack("SSLLCCCC")`. Constants:
  `VMADDR_CID_ANY = 0xFFFFFFFF`, `VMADDR_CID_LOCAL = 1`, `VMADDR_CID_HOST = 2`.
- **vsock ports are a host-global namespace with no per-test scoping.** Both spikes hardcode
  `PORT = 5252`. The Unix path solved the equivalent problem deliberately — every example gets a
  throwaway `XDG_RUNTIME_DIR` so "parallel workers cannot collide"
  (`spec/lain/core/client_spec.rb:12-13`). vsock has no such scoping, so **port allocation is an
  explicit deliverable** (T4), not a detail. Without it, two concurrent runs collide and a
  leaked daemon makes T5's "nothing is listening" scenario pass for the wrong reason.
- **`sh` is dash.** Its `printf` implements POSIX `\ooo` but not bash's `\xNN`; with hex it
  emits the escape text verbatim, which reads exactly like a transport corrupting bytes.
- **Transport latency is below measurement noise** (60–160 µs, vsock sometimes *faster* than
  unix). No spec may assert on it; any threshold will flake.
- **`.start`'s full signature is `(paths:, binary:, version:, handshake_budget:)`** — and
  `version:`/`handshake_budget:` are load-bearing at `client_spec.rb:145` and `:164`. It has
  **seven** call sites, all in two spec files: `client_spec.rb:19, 114, 130, 145, 164` (only
  :114, :130, :145 pass `binary:`; the rest route through the `with_client` helper at :19) and
  `core_exec_spec.rb:74, 172`. Nothing in `lib/` or `exe/` constructs `Core::Client` or
  `Tools::CoreExec`.
- **`.pre-commit-config.yaml:45-50` runs `cargo test` unconditionally** on any `.rs` change
  (`types: [rust]`, `pass_filenames: false`). A Rust vsock test with no availability gate would
  fail every Rust commit on a host without vsock — including the work MacBook, whose eligibility
  is still unknown. T4 gates it.
- **`:core` specs skip (never fail) when the binary is absent** (`spec/support/tags.rb:118-126`),
  opted into by `--tag core` overriding the config-level exclusion. **A CLI `--tag` lifts the
  exclusion only for that tag**, so an example tagged `:core, :vsock` stays excluded under
  `--tag vsock` and the run passes green having executed nothing. T3 resolves this: `:vsock`
  examples carry `:vsock` **only**, and T3's before-hook checks the binary as well as the probe.
- **`rake core:build` is exactly `cargo build -p lain-core`** (`Rakefile:48-59`).

### Staleness re-verification, 2026-07-28 (orchestrator, at execution time)

Four corrections. The first three are absorbed into the cards below; the fourth **replaces a T5
acceptance criterion**. Everything else in this Grounding was re-checked and holds verbatim —
`client.rb:70-74` `.start`, `client.rb:140-145` `#stop`, `client.rb:94` `#pid`, `child.rb:55/79-81`,
`rpc.rs:114/128-129/135`, `main.rs:54/63`, `tokio-util = features ["codec"]` only,
`tags.rb:106-126`, `.pre-commit-config.yaml:45-50` unconditional `cargo test`.

1. **The two spikes do not exist.** `spike/` holds `astgrep-probe`, `scip-probe`, `fixtures`,
   `ts_query.lua` — there is no `vsock_relay_poc.rb` or `vsock_loopback_poc.rb`, in the tree, in
   git history, or on any branch. Their *findings* survive verbatim in
   `references/firecracker-microvm-isolation.md` §6 (the `pack("SSLLCCCC")` struct, the CID
   constants, the autoload fact, the 60–160 µs latency finding, the collapse-both-directions
   teardown lesson), and that section is now the citable source wherever a card said "port from
   the spike". Consequences: T1's **Files** drops both spikes; T5's **Reuse** points at §6;
   integration check 7 is void. The spikes were this chunk's independent oracle, so **T6 is now
   the chunk's only end-to-end proof — its risk rises from medium to high** and it gets the full
   adversarial review. T6's card text claiming "every technical claim here is already green in
   `spike/vsock_loopback_poc.rb`" is no longer checkable; treat those claims as unproven.
2. **`.start` has exactly the seven call sites the plan names**, all in `client_spec.rb` and
   `core_exec_spec.rb`. With the spikes gone there is no third consumer at all — T1's escalation
   trigger about "a third caller" is satisfied, tighter than written.
3. **Port policy is now verified, not recommended** (T4). `VMADDR_PORT_ANY` is `0xFFFFFFFF`, **not
   0** — binding port 0 raises `EACCES`, and so does every port below 1024 (privileged). Binding
   `VMADDR_PORT_ANY` succeeds, assigns a unique ascending port per bind, and `getsockname`
   round-trips it. That is exactly the ephemeral scheme T4 recommends, so T4 implements a checked
   design rather than choosing one.
4. **⚠️ `connect()` to a dead vsock port usually SUCCEEDS on `vsock_loopback`.** Measured on this
   kernel, dialing `VMADDR_CID_LOCAL` on a port with no listener returned **CONNECTED 4 times in
   5**, `ECONNRESET` once — with and without unrelated listeners open. So a transport **cannot**
   detect "nothing is listening" at connect time, and any rescue written around `ECONNREFUSED`
   (the TCP/Unix intuition) is wrong. This invalidates T5's fifth scenario as drafted; see the
   replacement on that card. A nonexistent CID gives `ENODEV`, deterministically.

   **Narrowed by T5's own measurement — the original wording here was too strong.** This entry
   first said that dialing `VMADDR_CID_HOST(2)` from the host "connects and then fails `ENOTCONN`
   on write". That was measured against a port with **nothing listening**, so the `ENOTCONN` was a
   consequence of the dead port, not of the CID. Re-measured by T5 against a live `CID_ANY`
   listener, `CID_HOST` works fine: ping, exec, a 1 MiB payload and 8-way demux all pass. So the
   two CIDs are **not** behaviourally distinguishable against a live listener, and only the
   transport's own diagnostic message tells them apart. `VMADDR_CID_LOCAL` remains the right
   default to dial; the reason is convention and legibility, not that `CID_HOST` fails.

**Where docs and code disagreed, and which won.** ROADMAP:830-841 records Deviation 8,
"isolation reached no consumer." Half stale: `--isolation` **is** a real, tested `lain chat`
flag today (`exe/lain:258` → `lib/lain/cli/wiring.rb:125`), closed by the 2026-07-26 follow-up.
Still true for the bench. **Code won** — and the bench half is now its own chunk, which also
avoids overclaiming: `Bench::CLI#arm_sweep_report` (`bench/cli.rb:66`) is a *second* doorless
report, so no single card "closes" the deviation.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only — no card lists these under **Files**):
  - `crates/lain-core/Cargo.toml` — T2 hands back any dependency/feature change, T4 hands back
    `tokio-vsock`. **Two cards, two waves**: apply T2's before T4 starts. — *Resolved at execution
    time: T2 needed **no** Cargo.toml change (the local trait is precisely what avoids the
    `tokio-util` `net` feature, and its `TcpListener` test rides tokio's existing `net`). So this
    file has one writer, T4, and the serialization concern is moot. T4 is still ordered after T2,
    but on the `rpc.rs` **code** dependency — T4 writes `impl Accept for VsockListener`, so T2 must
    be committed to main before T4's worktree is forked or the trait will not be there.*
  - `spec/support/tags.rb` — T3 hands back the `:vsock` filter + before-hook.
  - `lib/lain.rb`, `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, `Rakefile` — no change
    expected. A card needing an edit here has mis-scoped: stop and escalate.
- `lib/lain/core/transport.rb` is created by T1 (wave 1) and modified by T5 (wave 3). The waves
  serialize them, so there is no conflict — but the general "one card per index file" rule does
  **not** hold here, and a future card adding a second transport in the same wave as another
  must escalate rather than assume it does.
- `lib/lain/core.rb` is a card-owned unit index touched only by T1.
- Deviation from the default process: none.

## Open decisions

None. The one genuinely open question the first draft carried — *who closes the wire, the client
or the transport?* — is resolved in T1 in favour of the client, and the reasoning is recorded
there so a reviewer can overturn it with evidence rather than taste.

## Progress

| Card | Implemented | Panel verdict | On `main` |
|---|---|---|---|
| T1 | ✅ | APPROVE-WITH-FIXES → applied | ✅ `0e07a5f` |
| T2 | ✅ | APPROVE-WITH-FIXES → applied | ✅ `048f935` |
| T3 | ✅ | APPROVE-WITH-FIXES → applied | ✅ `c338bf3` (+ `3cb3a15` CID comment) |
| T4 | ✅ | APPROVE-WITH-FIXES (1 blocker) → applied | ✅ `1c8734e` |
| T5 | ✅ | APPROVE-WITH-FIXES (3 blockers) → applied | ✅ `8fa9058` |
| T6 | ✅ | APPROVE-WITH-FIXES → applied | ✅ `f844d6c` |

**All six cards landed.** Integration checks 1–6 pass: default suite 5801/0/2 with `:vsock` not
run; `:core` 17/0 (Unix path unregressed); `--tag vsock` **19/0, non-zero as required**; `:vsock`
skips (19 pending, 0 failures) when the probe is stubbed unavailable; rubocop 837 files clean,
`cargo test` 5 binaries green, clippy clean; `pre-commit run --all-files` all 12 hooks pass.
Check 7 is void (the spikes do not exist). Checks 8 (Joel's MacBook question) and 9 (docs) below.

Run alongside `chunk-bench-arms-subcommand.md`; the two chunks share no file and interleave freely.

## Waves

```
Wave 1: T1, T2, T3          (no unmet deps)
Wave 2: T4 (←T2)
Wave 3: T5 (←T1, T3, T4)
Wave 4: T6 (←T5)
```

Critical path: **T2 → T4 → T5 → T6** (4 cards). T1 and T3 are slack; both must land before T5.

Rust (T2, T4) and Ruby (T1, T3) advance independently until T5 joins them. An orchestrator short
on parallelism starts T2 first, since it gates the longest chain.

## Tasks

### T1 — Name the transport contract and make it injectable at `Client.start` [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/core/transport.rb`, `lib/lain/core/transport/mock.rb`,
`spec/lain/core/transport_spec.rb`; modify `lib/lain/core/client.rb`, `lib/lain/core.rb`,
`spec/lain/core/client_spec.rb`, `spec/lain/tools/core_exec_spec.rb`
**Reuse:** `Lain::Core::Child` (`lib/lain/core/child.rb`) is the incumbent implementation of this
contract — do **not** rewrite or rename it; it becomes "the transport that spawns a local
daemon." `Lain::Provider::Mock` (`lib/lain/provider/mock.rb`) is the pattern for a lib-resident
test double.
**Shared-file wiring:** none (`lib/lain/core.rb` is card-owned; add
`require_relative "core/transport"` **before** `core/client`)

`Core::Transport` is a documented contract plus a `Mock`, not a class hierarchy — `Child`
already satisfies it. Two messages only:

- `#start -> IO` — a connected, ready socket; ownership passes to the caller.
- `#stop -> Object` — release whatever this transport provisioned. The return value describes
  the termination and reaches `Core::Died`.

Three deliberate reductions from the first draft, each reversing something the panel flagged:

1. **`#pid` is not in the contract, and is deleted from `Client`.** Its only readers are two
   specs that `Process.kill` the daemon; with an injected transport the caller already holds the
   `Child`. A nil-returning `#pid` would pin nothing, and a Null Object for it would launder a
   message that does not belong on this object.
2. **`#stop` carries no liveness obligation.** Instead `Client#stop` collapses its **own** read
   side before `@reader.wait`, so the reader EOFs because the client shut its half — the same
   "collapse both directions" rule `spike/vsock_relay_poc.rb:104-107` learned. `Child#stop`
   stays TERM-then-reap for the daemon's sake; an attaching transport's `#stop` is free to just
   release its end. This is what makes the contract implementable by things that do not own a
   process.
3. **`.start` keeps `version:` and `handshake_budget:`**; only `paths:`/`binary:` collapse into
   `transport:`.

**Acceptance criteria:**

```gherkin
Scenario: stopping a client whose transport owns no process still terminates
  Given a client built over a transport that only holds a socket
  When the client is stopped
  Then the stop completes promptly
  And a subsequent call reports the client stopped

Scenario: a transport's termination description reaches the operator
  Given two transports that describe their termination differently
  When each one's wire dies with a call in flight
  Then the two raised errors read differently enough to tell the causes apart

Scenario: the incumbent transport is unchanged
  Given a Child constructed with paths and a binary
  When a client is started over it
  Then it spawns, handshakes, execs, and stops exactly as before

Scenario: a version mismatch is still refused at the handshake
  Given a transport connected to a daemon reporting another protocol version
  When a client is started over it
  Then it raises naming both versions
  And it leaves no daemon running and no reader fiber captive
```
→ spec file: `spec/lain/core/transport_spec.rb` (contract + `Mock`); the third and fourth
scenarios are re-verified by the existing `spec/lain/core/client_spec.rb`, updated to `transport:`

**Escalation triggers:**
- Collapsing the client's own read side before `@reader.wait` may drop a response that was
  in flight when `#stop` was called. The existing code closes the socket immediately afterward,
  so the window is not new — but if a currently-passing example in `client_spec.rb` starts
  failing because a response is lost, **stop**: that is a semantic change to voluntary teardown,
  not a test to adjust.
- `Client#perish` (`client.rb:221`) already calls `@child.stop` on the wire-death path, so a
  transport's `#stop` can run twice (once from `perish`, once from `stop`). If pinning
  idempotence would change `Child`'s existing reap-memo (`child.rb:79-81`), stop and confirm.
- If a **third** `.start` or `Client.new` caller appears outside the two spec files, the grounding
  was wrong — stop before changing the signature. (Re-verified at execution time: there are
  exactly seven call sites, all in those two files.)

---

### T2 — Generalize the daemon's listener and connection types [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `crates/lain-core/src/rpc.rs`, `crates/lain-core/src/main.rs`
**Reuse:** `rpc::support` (`rpc.rs:300-444`, `#[cfg(test)]`) is the existing test harness —
extend it rather than writing a second one. The accept-error path (log, `ACCEPT_RETRY_DELAY`,
never crash) and the `serve_connection` reader/writer split are behavioural invariants to
preserve, not code to redesign.
**Shared-file wiring:** `crates/lain-core/Cargo.toml` — only if the chosen approach needs a
feature or dependency change; hand back the line with the house-style comment saying why

`serve` takes `UnixListener` concretely (`rpc.rs:114`), `serve_connection` takes `UnixStream`
(`rpc.rs:135`), and the `Sink`/`Stream` aliases (`rpc.rs:128-129`) are typed to `UnixStream`.
All four move together.

**Define a local trait** (e.g. an `Accept` with an associated connection type). This is not a
free choice: `tokio_util::net::Listener` needs a `net` feature tokio-util does not currently
carry, and the orphan rule forbids implementing it for `tokio_vsock::VsockListener` in T4
anyway. A sub-agent must not substitute a different abstraction without escalating.

**Acceptance criteria:**

```gherkin
Scenario: the Unix path is unchanged
  Given a daemon serving over a Unix socket
  When a client pings and execs
  Then the responses match the pre-change behaviour exactly

Scenario: a second, unrelated listener type serves the same protocol
  Given a listener of a different concrete type wired into the same serve loop
  When a client connects to it and pings
  Then it receives the daemon's version
  And no protocol code was duplicated to make that work

Scenario: a transient accept error does not kill the daemon
  Given an accept call that fails once
  When the server retries after its delay
  Then the next connection is served normally
  And the daemon is still alive
```
→ spec file: `crates/lain-core/src/rpc.rs` `#[cfg(test)] mod tests` (extend in place). The second
scenario drives a `TcpListener` under `#[cfg(test)]` — it needs no new dependency and is a
compile-level proof that the seam is genuinely generic rather than a rename.

**Escalation triggers:**
- `main.rs:63` destructures `rpc::serve`'s return with `match never {}`, which depends on the
  `Infallible` return type. Grounding says it survives; if the chosen abstraction forces that
  return type to change, **stop** — the `tokio::select!` shutdown arm depends on it, and that
  arm is what makes `kill_on_drop` reap in-flight children.
- `#![forbid(unsafe_code)]` is set at the crate root. Any approach needing `unsafe` is wrong.
- If generalizing appears to require boxing every connection (`dyn` + allocation per accept),
  stop and confirm — this is a per-connection hot path and the house rule is that a binding
  earns its cost.

---

### T3 — Supply the vsock spec harness: probe, daemon helper, and tag [wave 1] [risk: low]

**Depends on:** none
**Files:** create `spec/support/vsock_availability.rb`, `spec/support/vsock_daemon.rb`,
`spec/support_vsock_availability_spec.rb`
**Reuse:** `spec/support/tags.rb:106-126` (the `:core` tag) is the exact pattern — exclude by
default, opt in with `--tag`, **skip rather than fail** when the environment cannot supply the
precondition. `spec/support/ollama_tag.rb` is a second instance. The spike named here as the daemon-helper
reference does not exist (Staleness §1); use `lib/lain/core/child.rb#start` (spawn + bounded
readiness retry) and `crates/lain-core/tests/lifecycle.rs` (driving the real compiled binary)
instead.
**Shared-file wiring:** `spec/support/tags.rb` — a `config.filter_run_excluding(:vsock)` plus a
`config.before(:each, :vsock)` hook that skips unless **both** `VsockAvailability.available?`
and `File.executable?(Lain::Core::Child::BINARY)`, with a message naming which one is missing

Two collaborators, both consumed by T5 and T6, neither of which should invent its own:

- **`VsockAvailability.available?`** — answers "can this host bind an `AF_VSOCK` socket?" by
  *trying it and rescuing*, never by parsing `lsmod` or shelling out. Must not leak a descriptor
  per call; it runs once per tagged example.
- **`VsockDaemon`** — spawns `lain-core` on a vsock port, waits for readiness, exposes the port
  and pid, and tears down. This is the piece T5 and T6 would otherwise each hand-roll, and it is
  where T4's port-allocation scheme is consumed.

`:vsock` examples carry that tag **only** — never `:core` as well — because a CLI `--tag` lifts
the config-level exclusion for that tag alone, so a doubly-tagged example would stay excluded and
the run would pass green having executed nothing.

**Acceptance criteria:**

```gherkin
Scenario: the probe answers without raising, on any host
  Given a host with or without vsock support
  When the availability predicate is asked
  Then it answers true or false and never raises

Scenario: repeated probing leaks no descriptors
  Given the availability predicate is asked many times
  When the process's open descriptors are counted before and after
  Then the count is unchanged

Scenario: an unavailable host skips rather than fails
  Given a host where the precondition cannot be met
  When a vsock-tagged example runs
  Then it is reported as skipped, not failed
  And the message distinguishes a missing kernel transport from a missing binary

Scenario: vsock specs do not run by default
  Given the suite is run with no tag filter
  When the run completes
  Then no vsock-tagged example was executed

Scenario: the daemon helper yields a reachable daemon and reclaims it
  Given the helper is asked for a daemon
  When a client connects to the port it reports
  Then the daemon answers
  And after teardown no daemon process from that helper survives
```
→ spec file: `spec/support_vsock_availability_spec.rb` (top-level, matching the repo's one
precedent for speccing a spec-support file, `spec/support_matchers_spec.rb` — there is no
`spec/lain/support/` directory)

**Escalation triggers:**
- The "unavailable host" scenario cannot be arranged on this host, where `vsock_loopback`
  autoloads. It must be driven by stubbing the predicate, **not** by faking kernel state — if
  that seems impossible, stop rather than deleting the scenario.
- The daemon helper depends on T4's port-allocation scheme but is in an earlier wave. Build it
  against the scheme T4 specifies; if T4 lands a different scheme, the helper must be revised —
  flag this to the orchestrator rather than pinning a port literal.
- If `:vsock` examples run under a bare `bundle exec rspec` after the wiring lands, the exclusion
  is wrong — stop; a tag that silently runs everywhere defeats its purpose.

---

### T4 — Bind AF_VSOCK in the daemon, with a scheme and a port policy [wave 2] [risk: medium]

**Depends on:** T2
**Files:** modify `crates/lain-core/src/main.rs`; create `crates/lain-core/tests/vsock_listen.rs`
**Reuse:** `tokio-vsock` 0.7.2 (Apache-2.0 — already in `deny.toml`'s allowlist; ~7.1M downloads,
`rust-vsock` org) supplies `VsockListener` with the `accept()` shape T2's trait expects.

**The crate was compiled and run against this repo's pins by the orchestrator before this card was
issued.** All of the following is measured, not inferred — build on it, do not re-derive it:

- `tokio-vsock = "0.7"` resolves to **0.7.2 against the pinned `tokio` 1.53.1 with no feature
  bump and no tokio change**, pulling in `vsock` 0.5.4. The card's "if it does not compile against
  pinned tokio, stop" trigger is therefore already cleared.
- `VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, u32::MAX))` binds **ephemerally**
  (`u32::MAX` is `VMADDR_PORT_ANY`), and `listener.local_addr()` reads the assigned port back —
  that is the mechanism by which the daemon can report its port.
- `accept()` yields `(VsockStream, VsockAddr)`, structurally the same shape as
  `UnixListener::accept()`'s `(UnixStream, SocketAddr)`, so **T2's trait should fit without
  reshaping**. If it does not, that is a T2 defect worth escalating rather than working around.
- The crate re-exports `VMADDR_CID_ANY` and `VMADDR_CID_LOCAL`; a full bind → connect → echo
  round trip over loopback succeeded unprivileged.
`main.rs`'s `BIND_ERROR`/`USAGE_ERROR` vocabulary (`main.rs:24-26`) and `init_tracing` are
unchanged. `crates/lain-core/tests/lifecycle.rs` is the pattern for driving the real compiled
binary via `CARGO_BIN_EXE_lain-core`.
**Shared-file wiring:** `crates/lain-core/Cargo.toml` — `tokio-vsock = "0.7"` with the
house-style comment explaining why the crate is here

Argv today is `lain-core <socket_path> [tracing_path]`. Extend the first argument to a scheme: a
bare filesystem path stays Unix (**unchanged**, so `Child`, `rake core:build`, and every `:core`
spec are unaffected), and `vsock:<port>` binds `AF_VSOCK` on `VMADDR_CID_ANY`.

**Port allocation is part of this card, not a detail.** vsock ports are a host-global namespace
with no equivalent of the throwaway `XDG_RUNTIME_DIR` the Unix specs use, so concurrent runs and
leaked daemons collide. The ephemeral scheme was **measured at execution time and works** — build
it, do not re-litigate it:

- `VMADDR_PORT_ANY` is **`0xFFFFFFFF`, not 0**. Binding port 0 raises `EACCES`, as does every port
  below 1024 (privileged). A card that reaches for port 0 as "ephemeral" is reproducing a TCP
  habit vsock does not share.
- Binding `VMADDR_PORT_ANY` succeeds unprivileged, assigns a unique ascending port per bind, and
  the assigned port round-trips through `getsockname`.

**The reporting contract is RATIFIED, not yours to choose.** T3 shipped `VsockDaemon` against it
in wave 1, so this is now a two-sided contract and T4 implements the daemon half exactly:

> `lain-core vsock:<port-or-nothing> <tracing_path>` binds `AF_VSOCK` on `VMADDR_CID_ANY` — an
> explicit port if given, `VMADDR_PORT_ANY` otherwise. Once bound, it writes the assigned port as
> **decimal text** to `"#{tracing_path}.port"`. **That file's existence is the readiness signal.**

Write the port file only *after* the bind succeeds — its existence is what `VsockDaemon` polls, so
a file that appears before the listener is ready is a race, not an optimization. A bare filesystem
path as the first argument stays Unix and is **unchanged**, so `Child`, `rake core:build`, and
every `:core` spec are unaffected.

**The write must be ATOMIC — write to a temp path in the same directory and `rename(2)` into
place.** This was added after T3's review measured why it matters: a torn read is *undetectable*
here, because **every prefix of a vsock port parses cleanly**. Ports are ~10 digits near `u32`
max (measured: `2959002882`), so a reader catching the file mid-write gets `2`, `29`, `295`,
`2959`… — each a valid `Integer`, none an error. The consumer cannot defend against this no matter
how carefully it parses; only an atomic publish closes it. A partial read therefore yields a
*wrong port* and a baffling downstream connect failure, not a retry.

Relatedly, emit the port as **bare decimal with no leading zeros**: the consumer parses with an
explicit base-10 radix, but `Integer("012345")` is octal `5349` in Ruby, so a zero-padded field
would be misread by any less careful reader.

If you find this contract genuinely unimplementable, **stop and escalate** rather than changing it
unilaterally — T3's `#wait_for_port`/`#ready_path` are written against it, and T5/T6 consume
`VsockDaemon#port`/`#pid` rather than the mechanism, so a change costs a revision in another
card's landed file.

**Acceptance criteria:**

```gherkin
Scenario: a bare path still binds a Unix socket
  Given the daemon is started with a filesystem path
  When a client connects over that Unix socket
  Then it pings successfully, exactly as before this card

Scenario: a vsock scheme binds a vsock listener
  Given the daemon is started with a vsock scheme
  When a client connects over AF_VSOCK to the loopback CID on the daemon's port
  Then it pings successfully and receives the daemon's version

Scenario: the daemon makes its port discoverable
  Given the daemon is started without a fixed port
  When it has bound successfully
  Then the port it is listening on is recoverable by the process that started it

Scenario: two daemons started concurrently do not collide
  Given two daemons are started at the same time under the port policy
  When both have bound
  Then each is reachable on its own port
  And neither displaced the other

Scenario: a malformed scheme is refused in words at startup
  Given the daemon is started with a vsock scheme carrying a non-numeric port
  When it tries to bind
  Then it exits with the usage-error code
  And the tracing file names the offending argument
```
→ spec file: `crates/lain-core/tests/vsock_listen.rs`

**Escalation triggers:**
- **`cargo test` runs unconditionally in the pre-commit hook** (`.pre-commit-config.yaml:45-50`,
  `types: [rust]`). This test must skip — not fail — when the host cannot provide vsock, or every
  Rust commit breaks on a host without it (including, possibly, the work MacBook). Rust has no
  RSpec-style skip: returning early with a logged reason is acceptable, silently passing is not.
  If a clean skip proves impossible, **stop** — do not ship a test that hard-fails.
- `Child::BINARY`, `rake core:build`, and all `:core` specs assume `lain-core <path>` keeps
  working. If the scheme makes a bare path ambiguous (a relative path containing a colon), stop
  and confirm the disambiguation rule.
- If `tokio-vsock` 0.7.2 does not compile against the pinned `tokio` 1.53 features, stop — do not
  bump tokio to accommodate it.
- If binding `AF_VSOCK` needs privileges on the target kernel, stop: the chunk's premise is that
  this needs no root.

---

### T5 — Add the AF_VSOCK transport [wave 3] [risk: medium]

**Depends on:** T1, T3, T4
**Files:** create `lib/lain/core/transport/vsock.rb`, `spec/lain/core/transport/vsock_spec.rb`;
modify `lib/lain/core/transport.rb`
**Reuse:** the spike is gone (see Staleness §1); **`references/firecracker-microvm-isolation.md`
§6:324-326 is the citable source** for the 16-byte struct — `[Socket::AF_VSOCK, 0, port, cid, 0,
0, 0, 0].pack("SSLLCCCC")`, `VMADDR_CID_ANY = 0xFFFFFFFF`, `VMADDR_CID_LOCAL = 1`,
`VMADDR_CID_HOST = 2`, all re-verified against this kernel at execution time.
`spec/support/vsock_daemon.rb` and the `:vsock` tag (T3) supply the daemon and the gating; do not
hand-roll either. T4's scheme is how that daemon is started. **Dial `VMADDR_CID_LOCAL`** — dialing
`VMADDR_CID_HOST` from the host connects and then fails `ENOTCONN` on first write.
**Shared-file wiring:** none

Connects to `(cid, port)` over `AF_VSOCK`. Ruby exposes `Socket::AF_VSOCK` but no `sockaddr_vm`
helper, so the 16-byte struct is hand-packed.

**Corrected at execution time — this card originally said "`#stop` releases its end", and T1's
landed contract says the opposite.** Read `lib/lain/core/transport.rb` on `main` before writing a
line; it is the authority and it is explicit:

- `#start` hands the socket away. **Ownership passes to the caller** — the client closes it, and a
  transport must not read, write, or close it afterwards.
- **The socket is therefore never among the things `#stop` releases.** A transport that merely
  *attaches* to a daemon someone else started — exactly this card — **owns nothing by the time
  `#stop` runs: it releases nothing and only reports.** Closing the socket in `#stop` would be
  closing an fd it no longer owns.
- `#stop`'s return value is interpolated into `Core::Died`'s message, so an operator reads it.
  `Child` returns a `Process::Status`; **this transport returns whatever names the far end it was
  dialing** — the CID and port. That is what AC 2 of T1 ("two transports that describe their
  termination differently") is pinning, and this card is the second of those two.
- `#stop` is called **more than once** per client (`Client#perish` on wire death, `Client#stop` on
  voluntary teardown, and a voluntary stop runs both), so it must be idempotent and keep answering.
- There is **no obligation not to raise**: `Client#stop` completes teardown in an `ensure`, so
  failing loudly is safe and will not strand the reader fiber.

**Also measured at execution time (T4 review): the kernel REUSES a just-freed ephemeral vsock
port** — a daemon restart was observed getting the identical number. Any assertion that assumes a
fresh port differs from a dead one is unsound and will flake; T4 hit exactly this and had to
restructure a restart assertion around it.

**Acceptance criteria:**

```gherkin
Scenario: the boundary works over a real vsock stream
  Given a lain-core daemon listening on a vsock port
  When a client connects over AF_VSOCK to the loopback CID
  Then it pings and receives the daemon's version

Scenario: arbitrary bytes survive the transport
  Given a command whose stdout contains NUL and high bytes
  When it is run across the vsock boundary
  Then the bytes arrive unaltered

Scenario: a large payload is not truncated
  Given a command producing one mebibyte of stdout
  When it is run across the vsock boundary
  Then the full payload arrives intact

Scenario: concurrent calls interleave without losing frames
  Given eight commands issued concurrently over one vsock connection
  When all of them complete
  Then every response is delivered to its own caller

Scenario: dialing where nothing listens fails at the handshake, not at connect
  Given a port the harness has confirmed has no listener
  When a client is started over a transport dialing it, under a handshake budget
  Then the start fails within that budget
  And the failure names the CID and port
  And no reader fiber is left captive
```
→ spec file: `spec/lain/core/transport/vsock_spec.rb`, tagged `:vsock` **only**

**On that last scenario — read this before writing it.** It was rewritten at execution time
because the drafted version asserted something untrue of this kernel. Measured: `connect()` to a
dead port on `VMADDR_CID_LOCAL` **succeeded 4 runs in 5** (`ECONNRESET` the fifth), so
`vsock_loopback` gives no reliable connect-time refusal and there is nothing to rescue. Do **not**
rescue `ECONNREFUSED` — that is the TCP/Unix intuition and it never fires here. The honest failure
mode is the one the codebase already has vocabulary for: the handshake gets no reply and
`handshake_budget:` expires, exactly as `client_spec.rb:145` pins for a mute daemon. The transport
may still surface a connect-time `SystemCallError` when it happens to get one — just never
*depend* on it.

**Escalation triggers:**
- Do **not** assert on latency. Measured round trips were 60–160 µs with vsock sometimes faster
  than Unix; any threshold will flake.
- If a connect-time refusal *does* prove reliable on this host, say so rather than quietly
  restoring the drafted scenario — the orchestrator measured otherwise and wants the contradiction.
- If `sockaddr_vm` packing must differ from the spike's `pack("SSLLCCCC")`, stop — the struct
  layout is kernel ABI and a silent mismatch binds the wrong address.
- If a spec needs `sudo` or a module load to pass, stop: the chunk's premise is that
  `vsock_loopback` autoloads unprivileged.

---

### T6 — Prove the exec boundary over vsock with the existing differential [wave 4] [risk: high]

**Depends on:** T5
**Files:** modify `spec/lain/tools/core_exec_spec.rb`
**Reuse:** **the `differential(command, worker_env, **input_extra)` and
`expect_identical(bash, core)` helpers already in that file** (`core_exec_spec.rb:89-101`) are the
acceptance oracle — run them against a vsock-connected client rather than writing new comparison
logic. `expect_identical` already byte-compares via `.b`, because msgpack `bin` and mixlib's
UTF-8-tagged strings agree byte-for-byte while differing in encoding. `spec/support/vsock_daemon.rb`
(T3) supplies the daemon. The pattern mirrors `spec/lain/rust/timeline_spec.rb` rerunning the Ruby
Timeline's shared examples against the Rust port.
**Shared-file wiring:** none

The chunk's acceptance test: the *same* differential that pins `Tools::Bash` against
`Tools::CoreExec` over a Unix socket must pass unchanged with the daemon reached over vsock.

**Risk was raised from medium to high at execution time.** The draft rated it medium because
"every technical claim here is already green in `spike/vsock_loopback_poc.rb`" — that spike does
not exist (Staleness §1), so the 1 MiB payload, the `[0, 1, 254, 255]` binary-clean stdout, the
8-way demux and the server-side timeout are **claims recorded in a reference doc, not results you
can re-run**. This card is the chunk's only end-to-end proof. Build it as the proof, not as
wiring, and expect the full adversarial review.

Posture-parity cases (nonexistent cwd, timeout partial output) stay posture parity — they were
ruled structurally impossible to make byte-identical, and this card must not "fix" them.

**Acceptance criteria:**

```gherkin
Scenario: the differential passes over vsock
  Given a lain-core daemon reached over AF_VSOCK
  When the existing differential cases run against it
  Then every byte-identity case holds exactly as it does over a Unix socket

Scenario: the transport does not change posture parity
  Given a command with a nonexistent working directory
  When it runs over vsock
  Then the failure has the same posture it has over a Unix socket

Scenario: boundary death over vsock is a tool error, not a raise
  Given a call in flight over vsock
  When the daemon is killed
  Then the tool returns an error result naming the boundary failure
  And nothing raises past the agent loop
```
→ spec file: `spec/lain/tools/core_exec_spec.rb`, a new `:vsock`-tagged describe block alongside
the existing `:core` one

**Escalation triggers:**
- If a byte-identity case passes over Unix but fails over vsock, **stop immediately and
  escalate** — that is the chunk's central claim failing, not a spec to adjust.
- The existing `:core` differential block must keep passing unchanged. If sharing setup between
  the two blocks would alter the `:core` path, duplicate the setup instead and say so.
- The third scenario cannot reuse `core_exec_spec.rb:176`'s `Process.kill("KILL", client.pid)` —
  T1 deletes `Client#pid`, and this transport attaches rather than spawns. Kill the daemon
  through `VsockDaemon` (T3) instead. If that helper cannot express it, stop.
- `sh` is dash: a byte-level case must use POSIX `\ooo` octal escapes, never `\xNN`. A case that
  appears to show byte corruption should be checked against this before being reported as one.

## Follow-ups raised in review (not this chunk's work)

- **The peer address is discarded irrecoverably** (Raph Levien, T2 review). `serve`'s accept arm
  drops the address — right for today, since `serve` never used it. But **on vsock the peer CID is
  the only identity the transport carries**, and this is an isolation boundary. Recovering it later
  means adding an associated `Address` type to `Accept` plus every impl. Accepted knowingly here;
  it belongs to whichever M5 card first needs to know *which guest* is calling.
- **`Accept` is not dyn-compatible, by construction** (RPITIT; confirmed `E0038`). That is exactly
  what discharges the no-boxing rule, so it is a feature. The consequence to write down: listening
  on unix *and* vsock **simultaneously** cannot type-erase and would need an enum. No card here
  needs it; a "serve both families at once" card would.
- **The clean-EOF writer drain has no test** (Andrew Gallant, T2 review). Always aborting the
  writer instead of draining leaves the suite green. **Pre-existing, not introduced by T2** — but
  the T2 card named the reader/writer split as a behavioural invariant to preserve, and the suite
  cannot currently enforce that half. Worth a ticket.
- **A skipped Rust scenario reads as `ok` in default `cargo test` output** (Ashley Williams, T4
  review). Four vsock scenarios report `ok` having executed nothing on a vsock-less host — the
  Rust half of the same "green having executed nothing" trap the `:vsock` tag section is written
  around. The panel's fix — a `build.rs` probing `AF_VSOCK` and emitting
  `cargo:rustc-cfg=has_vsock`, plus `#[cfg_attr(not(has_vsock), ignore = "…")]` — gives real
  libtest `ignored` counts with no new dependency. **Declined for now** and recorded here because
  the reasoning may not survive contact with a future need: this crate is cross-compiled to a musl
  static binary for a **microVM guest rootfs**, so a *build-time* capability probe bakes the build
  host's vsock support into the artifact — build on a vsock-less host, get `not(has_vsock)`, for a
  guest that certainly has it. Today it would touch only test attributes, but it is a
  build-time/run-time capability skew in the one crate where that distinction is the subject.
  `LAIN_VSOCK_REQUIRED=1` plus two never-skip scenarios hold the floor meanwhile.
- **Service discovery hangs off the diagnostics argument** (Raph Levien, T4 review).
  `<tracing_path>.port` gives one argv slot two responsibilities — where the daemon writes its logs
  *and* where it publishes its identity. That coupling is what made the "no tracing path" hole
  possible at all (`/dev/null` is a fine tracing path and a nonsensical discovery root). The
  contract is ratified and T3 ships against it, so it was not T4's to change; a future card that
  gives discovery its own argument should take it.
- **⚠️ `Client#collapse` can park forever, and a wedged run hangs pre-commit instead of failing it**
  (Jeremy Evans, T5 review — the most operationally serious item on this list). `client.rb:166-168`
  says shutting our own half "is the one move available whatever is on the other side"; that is
  measurably not universal. Against a socket whose reader is blocked in a way `close_read` does not
  EOF, `@reader.wait` is unbounded: measured, `connect(2)` returned at 0.021s and the main thread
  was still parked inside `Async::Scheduler#run_once` at 20.1s. Worse, **the wedged run ignored the
  SIGTERM its `timeout` sent and was still alive 44 minutes past a 45-second deadline**, needing a
  second signal. So this fails *closed* in the worst way — CI and the pre-commit hook hang rather
  than going red. T5 is merely where it surfaced: it is the first transport that owns nothing and
  therefore leans on the collapse entirely. The fix belongs to `Client` (a bounded wait, then
  force the close).
- **`Client::HandshakeTimeout` does not name the far end, so a mute daemon is unattributable**
  (Jeremy Evans, T5 review). Against a far end that accepts and stays silent — a wedged `lain-core`
  in a guest, which is exactly the shape this chunk exists to serve — the raised error is
  `HandshakeTimeout`, whose message carries no CID and no port. `Core::Died` gets the transport's
  own report; `HandshakeTimeout` should too. T5's fifth AC ("the failure names the CID and port")
  holds today **only because `vsock_loopback` resets sub-millisecond**, which is not a property of
  any real hypervisor vsock — so this ticket is a precondition for trusting that AC once a
  hypervisor is in the picture.
- **`Child::Unreachable` and `Vsock::Unreachable` share a name but no supertype** (Sandi Metz, T5
  review), so no caller can rescue "provisioning failed" generically — which is why T5's fifth
  example has to reach for the broad `Lain::Error`. Consistent with T1's landed contract, so not a
  defect; worth a line in the contract, or a shared ancestor.
- **The `expect_identical` oracle is mechanically inert — the literal assertions carry the proof**
  (Aaron Patterson, T6 review). Replacing `expect_identical`'s two assertions with a no-op
  **survives 6/6 runs, reddening nothing**; replacing the *core* arm with `Bash` is noticed by only
  1 of 5 differential examples, and that one is the posture-parity case rather than a byte-identity
  one. **Pre-existing and inherited verbatim** — the same two mutations behave identically against
  the landed `:core` block (3/3 each), so T6 copied it faithfully. The byte-identity ACs are still
  genuinely met: deleting NUL from the wire's stdout kills 6/6 and reds exactly the right example.
  But the differential's name promises a comparison that contributes nothing, in the repo's
  headline exec-boundary spec. Worth a card: make the comparison load-bearing, or rename it.
- **`VsockDaemon#stop` has no reap memo and re-signals a pid it already reaped** (Sandi Metz, T6
  review) — on **every** execution of the boundary-death example, not only on failure. Strictly
  worse than the `Child#stop` defect below, which at least memoizes (`@status ||= Process.wait2`).
  Harmless across ~120 measured lifecycles (`ESRCH`/`ECHILD` are rescued) but it is now a
  three-site pattern. One line in `spec/support/vsock_daemon.rb`: nil the pid after the reap.
- **`expect_attached_to` stops discriminating the moment a relay exists** (Linus Torvalds, T6
  review). It pins *which daemon answered* (`$PPID` == `VsockDaemon#pid`), not *which address
  family carried the bytes* — demonstrated with a `UNIXServer` relay forwarding to the vsock
  daemon, through which an **AF_UNIX** client passes the check cleanly. Unreachable today, since
  `Transport::Vsock#start` can only build an `AF_VSOCK` socket. **But the deferred
  hypervisor-selection card is precisely a `CONNECT`/`OK` relay**, so whoever lands it must
  strengthen this pin in the same change or T6's seven examples quietly stop proving their subject.
- **Two `Child` defects surfaced by T1's review, not T1's to fix.** `Child#stop` re-signals an
  already-reaped pid on every repeat call — between reap and the next `#stop` that pid is free for
  the OS to reuse. And `Child#stop` before `#start` returns `nil`, so `Core::Died` renders
  `"lain-core died: "` with a trailing colon and nothing after it. Both pre-existing; T1 correctly
  left `child.rb` byte-unchanged. But T1 promoted "call `#stop` as often as you like" from a
  tolerated accident to a **written promise**, which is what makes the first one worth a ticket.

## Integration checks

After the last wave, before the chunk is called done:

1. `bundle exec rspec` — the default suite green, with `:vsock` examples **not** run.
2. `bundle exec rake core:build && bundle exec rspec --tag core` — the pre-existing `:core` suite
   unchanged and green, proving the Unix path did not regress.
3. `bundle exec rspec --tag vsock` — green, and **confirm it executed a non-zero number of
   examples** (the doubly-tagged-exclusion trap makes a green run of zero examples possible).
4. Confirm `:vsock` examples **skip** rather than fail when the probe is stubbed unavailable.
5. `bundle exec rubocop` and `cargo test && cargo clippy --all-targets -- -D warnings`.
6. `pre-commit run --all-files`.
7. ~~Run both spikes.~~ **Void** — neither spike exists (Staleness §1). The independent-oracle
   role passes to T6, which is why its risk was raised.
8. **Manual pass owed to Joel:** confirm whether the work MacBook is M3+ on macOS 15+. That
   decides whether Lima-nested-Firecracker is available at all for the hypervisor-selection
   chunk; if it is M1/M2, the backend decision collapses to libkrun. Nothing automated covers it.
9. Update `references/firecracker-microvm-isolation.md` §6 to mark its stated residual
   ("lain-core binding AF_VSOCK natively") closed, and add the ROADMAP index line for this chunk.
