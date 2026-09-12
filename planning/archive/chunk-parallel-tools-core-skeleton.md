# Parallel tool execution & the lain-core exec skeleton

status: done  (landed 2026-07-21: 8200f38 E1, f3fb25e E2, d48c3f7 E3, cadc90d C1, 3b8c047 C1-group-semantics, 0059ef9 msgpack dep, 1854b1c C2, eadaa4d C3; all integration checks green; manual passes owed: bin/demo-core + a real parallel-reads chat session)
commit-mode: orchestrator-commits
language: ruby + rust
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson (Ruby) ·
Raph Levien · Andrew Gallant · Frank McSherry · Ashley Williams (Rust) — one review sub-agent
embodies both rosters; Rust personas review C-cards, Ruby personas review E-cards and C2/C3's
Ruby half.

> Panel-reviewed 2026-07-21 (verdict REVISE, all findings applied): E2 rewritten to barrier
> semantics (the reorder-vs-wire-order defect), E1/E2 de-collided into sequential waves, C1
> gains the concurrency (msgid demux), timeout, error-surface, and bin-payload contract C2/C3
> depend on, the workspace grounding error fixed (root Cargo.toml already a workspace), C2's
> client demux design named, `Core::Process` renamed `Core::Child`, `:core` tag decided
> up front, daemon stderr routing stated.

## Intent

Two coupled latency/architecture deliverables from ROADMAP M6 ("exec-boundary hardening and
parallel tools remain `[planned]`", ROADMAP:402). **(E)** Widen within-turn parallel tool
execution — the dispatch machinery already exists (`ToolRunner#gather`); what's missing is
opt-in beyond `Subagent`, contiguous-run parallelism for mixed turns, and pinned fiber-safety
invariants. **(C)** Stand up `crates/lain-core` — the out-of-process exec boundary the design
plan names (tokio, msgpack-RPC over a Unix socket, the same transport idiom as the Neovim
frontend) — as a skeleton with one tool round-tripping through it as proof of boundary.
**Explicitly NOT in scope: confinement.** No sandbox claims are made anywhere in this chunk;
`WorkerEnv`'s "override, not confinement" posture (`worker_env.rb:9-18`) carries over verbatim,
and every doc/comment this chunk writes must repeat it. Hardening is a later chunk.

## Grounding

Verified against code on **2026-07-21** by a parallel `Explore` pass (tool-exec concurrency),
corrected by panel review same day. Code is source of truth. Key findings this plan is built
on:

- **Within-turn concurrent dispatch is BUILT** (commit `93e702d`): `ToolRunner#run` forks to
  `gather`/`sequential` (`lib/lain/agent/tool_runner.rb:28-31`); `#gather`
  (`tool_runner.rb:74-79`) fans tool_use blocks out as sibling `Async` tasks and restores
  tool_use order via `map(&:wait)` (`tool_runner.rb:78`). Gating is **all-or-nothing**:
  `gatherable?` requires `uses.size > 1 && uses.all?(&parallel_safe?)`
  (`tool_runner.rb:85-87`). **Only `Subagent` opts in** (`tools/subagent.rb:122`); the base
  default is false (`lib/lain/tool.rb:109-112`).
- **ShellOut cooperates with the fiber scheduler** — the 5-0.1/5-0.3 spikes concluded no
  thread offload is needed (`docs/concurrency.md:172-215`, `:358-388`; spike specs
  `spec/spikes/async_shellout_*_spec.rb`). `Tools::Bash` runs as an ordinary Async task.
  Plain `UNIXSocket` IO parks fibers the same way (Async hooks `io_wait`/`io_read` for core
  IO) — parking is sound; response **demultiplexing** is the part a client must build (C2).
- **Ordering is pinned in exactly two places**: `tool_runner.rb:78` (`map(&:wait)`) and gate 2
  ("all results in ONE user message", `agent.rb:266-287`). The provider formatter does not
  re-sort (`provider/http/providers/anthropic/chat/message_formatting.rb:27-28`).
- **Shared mutable state reachable from concurrent tools** — the fiber-only safety set:
  `Session` read/write `Set`s + todo state threaded to every tool as `context:`
  (`session.rb:56-57`, `agent.rb:285`); `Session::Journaled#record_read`'s
  check-then-mutate documented fiber-safe by no-yield-between (`session.rb:306-309`);
  `Approval::Queue`'s `@parked` plain-Array mutation (`approval/queue.rb:108,140-159`);
  `Journal` and `Store` already hold Monitors (`journal.rb:120,134-143`; `store.rb:19,33-53`
  — the Store's is documented "provably redundant" under fibers, kept deliberately).
  `WorkerEnv` is deeply frozen/shareable (`worker_env.rb:29-42`) — safe; the hazard is
  process-global `Dir.pwd` if any tool ever chdirs (`worker_env.rb:37`), and `WorkerEnv`'s
  one removal lever is **explicit-nil scrub** (`worker_env.rb:14-18`) — the RPC env contract
  must preserve it (C1).
- **Concurrent gated tools already behave**: each parks its own fiber on its own `Pending`;
  first-answer-wins is single-shot (`queue.rb:68-77`); denial returns `Tool::Result.error`,
  never raises (`effect/handler/gate.rb:64-71`).
- **`crates/` does not exist, but the root `Cargo.toml` DOES — and it is already a workspace**
  with `members = ["./ext/lain"]`. Pre-commit runs `cargo test`/`clippy` from the repo root
  against the workspace, and the `cargo-deny` hook watches the root `Cargo.lock`. So
  `crates/lain-core` **must be a workspace member from its first commit** — a non-member
  crate is invisible to the hooks (violating this plan's own integration checks), and cargo
  inside a nested non-member directory errors without an empty `[workspace]` opt-out.
  No msgpack, no `UNIXSocket` RPC exec code exists anywhere in `lib/`/`ext/` except the
  Neovim frontend *client* (`frontend/neovim/rpc_thread.rb`), not reusable as our server.
  The placement rule (`ext/lain/CLAUDE.md:8-10`): async/IO/isolation work is out-of-process,
  never magnus.
- **`Paths#runtime_dir` exists and is unused** (`paths.rb:49-52`, `/tmp/lain` fallback per
  spec) — the socket home this chunk finally gives a caller.
- **Truncated backtraces under fiber-hosted dispatch** are a named, accepted cost
  (`docs/concurrency.md:308-316,384-388`) — carried forward, not fixable here.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  - `lib/lain.rb` — manifest line for the new `core` unit (C2).
  - Root `Cargo.toml` — one-line members addition (`"./crates/lain-core"`), applied with C1's
    commit. Root `Cargo.lock` will grow lain-core's deps; that is expected and puts them
    under the existing `cargo-deny` hook.
  - `Rakefile` (or the task home the repo uses) — a `core:build` task compiling
    `crates/lain-core` for the `:core`-tagged specs (C2's commit).
  - `spec/spec_helper.rb` — one-line `:core` tag exclusion mirroring `:integration`
    (orchestrator, with C2).
  - `lain.gemspec`, `.rubocop.yml`, `CLAUDE.md` — untouched expected, except CLAUDE.md's
    toolchain block gains the `:core` tag note (orchestrator, one line).
- Deviations from the default process:
  - C1 is Rust-only: panel review runs the Rust personas; no Ruby specs in that card
    (`cargo test` is its suite).
  - `:core`-tagged specs need the compiled daemon; they are excluded by default (like
    `:integration`) and run in integration checks via `rake core:build && rspec --tag core`.
  - The E-cards and C-cards are independent streams — waves interleave them freely.

## Open decisions

None gating. (Confinement policy, egress observation, and credential brokering are explicitly
out of scope — a later chunk; recorded here so no card grows them.)

## Waves

Wave 1: E1, C1   (no unmet deps)
Wave 2: E2 (←E1), C2 (←C1)
Wave 3: E3 (←E1,E2), C3 (←C2)
Critical path: C1 → C2 → C3 (tied with E1 → E2 → E3)

## Tasks

### E1 — Opt read-only tools into parallel_safe?          [wave 1] [risk: low] ✅ LANDED 8200f38

> Panel: APPROVE, no fixes. Orchestrator scope call: `tool.rb`'s base `parallel_safe?` comment
> ("nothing here executes in parallel yet") was made false by this very card — amended in the
> same commit. Panel NIT carried: `ast_search`/`code_outline`/`file_symbols` don't resolve
> `input.path` against `worker_env.cwd` like the rest of the tier-1 family (pre-existing;
> ticket someday).

**Depends on:** none
**Files:** `lib/lain/tools/read_file.rb`, `lib/lain/tools/list_files.rb`,
`lib/lain/tools/glob.rb`, `lib/lain/tools/grep.rb`, `lib/lain/tools/memory_read.rb`,
`lib/lain/tools/ast_search.rb`, `lib/lain/tools/ast_dump.rb`, `lib/lain/tools/test_pattern.rb`,
`lib/lain/tools/code_outline.rb`, `lib/lain/tools/file_symbols.rb`,
`spec/lain/tools/parallel_safety_spec.rb` (create)
**Reuse:** `Tool#parallel_safe?` default (`lib/lain/tool.rb:109-112`); `Subagent`'s opt-in as
the precedent (`lib/lain/tools/subagent.rb:122`); the instrumented-fake idiom of
`spec/lain/tools/subagent_concurrency_spec.rb` for concurrency observations.
**Shared-file wiring:** none

Each listed tool declares `parallel_safe? = true` with a WHY comment stating the audit
conclusion (reads only, no Session write-set mutation, no process-global state). The spec
pins the **full shipped-toolset partition** — every tool in the base toolset enumerated on
one side or the other (`subagent` stays true, as today; `bash`, `edit_file`, `write_file`,
`todo_write`, `memory_write`, `run_skill`, `ask_human`, and the web tools stay false unless
the audit proves otherwise) — so a future tool must choose deliberately or the spec names it.
Concurrency behavior is observed through instrumented fake tools marked `parallel_safe?`
(deterministic), not through real file IO (which may complete without a scheduler yield).
The bash-`cd` isolation property lands here too: a `cd` affects only its own subprocess
(ShellOut `cwd:`), never harness `Dir.pwd`.

**Acceptance criteria** (test-engineer turns these into failing specs first):

```gherkin
Scenario: parallel-safe tools gather concurrently
  Given a toolset with two instrumented fake tools marked parallel_safe?
  When the ToolRunner runs a turn calling both
  Then both dispatches begin before either result resolves
  And the committed user turn carries results in tool_use order
```
→ spec file: `spec/lain/tools/parallel_safety_spec.rb`

```gherkin
Scenario: the full toolset partition is pinned
  Given every tool shipped in the base toolset
  When each is asked parallel_safe?
  Then the spec's enumerated true-set and false-set together cover the whole toolset exactly
  And a tool present in neither list fails the spec by name
```
→ spec file: `spec/lain/tools/parallel_safety_spec.rb`

```gherkin
Scenario: no tool mutates the process working directory
  Given the bash tool running `cd /tmp && pwd`
  When the result resolves
  Then the subprocess reports /tmp and Dir.pwd in the harness is unchanged
```
→ spec file: `spec/lain/tools/parallel_safety_spec.rb`

**Escalation triggers:**
- Any listed tool turns out to mutate `Session` state (e.g. a read tool calling
  `record_write`) — stop; that tool leaves the list and the finding goes in the plan doc.
- If the structural tools (`ast_*`, `file_symbols`) hold any shared ext-side state that makes
  concurrent calls unsafe (check the `Ext::` bindings' stateless claim), stop — the ext
  contract is Rust-owned.

### E2 — Contiguous-run parallelism for mixed turns          [wave 2] [risk: medium] ✅ LANDED f3fb25e

> Panel: APPROVE (7 adversarial probes incl. stop-mid-run-2 → stop-commits-nothing holds
> across run boundaries). Two NITs applied pre-land: `#safety_by_name` single-owner safety
> map (one lookup per distinct name per turn, `fetch` fails loud on unlisted names; kept
> per-turn because deferred disclosure adds tools mid-session), readable red-path matchers.
> `gatherable?` survives as the live per-run gate.

**Depends on:** E1
**Files:** `lib/lain/agent/tool_runner.rb`, `spec/lain/agent/tool_runner_spec.rb`
**Reuse:** `#gather`/`#sequential`/`gatherable?` (`tool_runner.rb:62-94`); the ordering pin
(`tool_runner.rb:78`); gate-2 reasoning (`agent.rb:266-283`).
**Shared-file wiring:** none

A mixed turn currently serializes entirely (`gatherable?` requires `all?`). Relax it with
**barrier semantics**: partition the tool_use list into maximal *contiguous* runs of
parallel-safe tools; each safe run gathers concurrently; each unsafe tool is a barrier that
runs alone, strictly after everything before it and before everything after it. Execution
order therefore never diverges from wire order — `[safe_a, unsafe_b, safe_c]` runs a, then
b, then c exactly as sequential would (a run of one gains nothing), while
`[safe_a, safe_b, unsafe_c, safe_d]` overlaps only a with b. A WHY records the rejected
alternative (safe-subset-first reorders execution against the wire order the model sees —
a silent causal lie when the unsafe tool writes what a later safe tool reads).

**Acceptance criteria:**

```gherkin
Scenario: contiguous safe runs overlap, barriers do not
  Given a turn with tool_use blocks [safe_a, safe_b, unsafe_c, safe_d] (instrumented fakes)
  When the ToolRunner runs the turn
  Then safe_a and safe_b dispatch concurrently
  And unsafe_c dispatches only after both resolve, and safe_d only after unsafe_c resolves
  And the user turn carries results in wire order
```
→ spec file: `spec/lain/agent/tool_runner_spec.rb`

```gherkin
Scenario: execution order equals wire order around a barrier
  Given a turn [safe_writer_probe, unsafe_writer, safe_reader_probe] where the unsafe tool mutates state the last tool reads
  When the turn runs
  Then the safe reader observes the post-mutation state (as full sequential would)
```
→ spec file: `spec/lain/agent/tool_runner_spec.rb`

```gherkin
Scenario: degenerate turns are strictly sequential
  Given a single-tool turn and an all-unsafe turn
  When each runs
  Then dispatch is strictly sequential and results are in wire order
```
→ spec file: `spec/lain/agent/tool_runner_spec.rb`

**Escalation triggers:**
- `spec/lain/tools/subagent_concurrency_spec.rb:112-194` pins one-ordered-user-turn,
  stop-commits-nothing, and attribution under the CURRENT gather semantics — if any of the
  three needs a change rather than an extension, stop and confirm.
- If run-partitioning makes `gatherable?` meaningless (dead code) rather than a degenerate
  case, stop before deleting a method other specs reference.

### E3 — Pin the fiber-safety invariants          [wave 3] [risk: medium] ✅ LANDED d48c3f7

> Panel: APPROVE-WITH-FIXES (mechanical, applied pre-land). Panel independently reproduced
> both yield-injection reds; lib diffs verified comment-only; no lock added — neither
> escalation trigger fired. Honest-bound comment now names its numbers (0.1s window vs μs
> reactor latency; a >100ms GC/CI stall is the eater). Follow-up ticket candidate: nine spec
> files hand-roll the entered/release gated-fixture idiom — parameterize once in support/.

**Depends on:** E1, E2
**Files:** `spec/lain/session_concurrency_spec.rb` (create),
`spec/lain/approval/queue_concurrency_spec.rb` (create), `docs/concurrency.md`,
`lib/lain/session.rb` (WHY comments only), `lib/lain/approval/queue.rb` (WHY comments only)
**Reuse:** the documented no-yield claim (`session.rb:306-309`); `Approval::Queue`'s
sibling-surface design (`queue.rb:112-121,140-159`); the spike-spec idiom
(`spec/spikes/async_shellout_spike_spec.rb`).
**Shared-file wiring:** none

The safety of E1/E2 rests on cooperative fibers: Session's check-then-mutate has no yield
point and `@parked` is mutated only between IO yields. Pin each as a spec and extend
`docs/concurrency.md` with a "parallel tools" section recording the invariant set, the
barrier semantics WHY, and the `Dir.pwd` hazard.

**Acceptance criteria:**

```gherkin
Scenario: concurrent session reads keep the read-set coherent
  Given a Session::Journaled shared by two concurrently gathered read tools
  When both record a read of the same path
  Then the read-set holds the path once and exactly one session_read record is journaled
```
→ spec file: `spec/lain/session_concurrency_spec.rb`

```gherkin
Scenario: N gated tools park N independent pendings
  Given two approval-gated tools dispatched concurrently
  When one is approved and the other times out
  Then the approved tool's result is ok and the timed-out tool's result is an error
  And two approval_decision records journal with distinct verdicts
```
→ spec file: `spec/lain/approval/queue_concurrency_spec.rb`

**Escalation triggers:**
- If a spec can only pass by adding a **new** lock to `Session` or `Approval::Queue`, stop —
  a new lock required for correctness means the documented no-yield claim
  (`session.rb:306-309`) has failed, and that diagnosis belongs to the human. (The existing
  Store/Journal Monitors are deliberate and not evidence of failure.)
- If `Session::Journaled#record_read` turns out to have a yield point (any IO between check
  and mutate), stop: the documented claim is wrong and E1/E2 are unsound until fixed.

### C1 — Stand up crates/lain-core: msgpack-RPC exec server          [wave 1] [risk: medium] ✅ LANDED cadc90d

> Panel: APPROVE-WITH-FIXES. Substantive (probes→specs): non-u32 msgid silently answered as
> msgid 0 (misdelivery); timeout racing child exit reported `timed_out: true` with real exit 0
> — orchestrator ruled truth-wins (`timed_out: true` means "we killed it", nothing else);
> SIGTERM orphans in-flight children (no signal handler → kill_on_drop never fires).
> Mechanical: depth-cap comment 2x off (effective nesting 32); accept-error busy-loop;
> notification-frame doc; non-UTF-8 env/argv doc. **Carried seam (next chunk): no
> cancellation/concurrency bound on in-flight exec** (detached handler tasks survive client
> disconnect; pipelining client can spawn unbounded children).
> Fix round re-reviewed → APPROVE. Panel ruled the implementer's deviation correct: error
> replies echo the offending msgid slot **verbatim** (0 only when the frame carries no id
> slot) — literal-0 would misdeliver onto a conforming msgid-0 caller. timed_out semantics:
> true ⇔ we killed it (`signal == SIGKILL` after try_wait-first). SIGTERM/SIGINT handler
> shuts the runtime down so kill_on_drop reaps in-flight children; integration test via
> CARGO_BIN_EXE (in-src path lookup is stale-binary-prone).

**Depends on:** none
**Files:** `crates/lain-core/Cargo.toml` (create), `crates/lain-core/src/main.rs` (create),
`crates/lain-core/src/rpc.rs` (create), `crates/lain-core/src/exec.rs` (create)
**Reuse:** `ext/lain/CLAUDE.md` house rules (crate-root `print_stdout`/`print_stderr` denies,
thiserror error idiom, exact-pinned deps); the msgpack-RPC wire shape the Neovim client
already speaks (4-element request array `[0, msgid, method, params]`); `rmpv` +
`tokio_util::codec::Decoder` for incremental decode (msgpack is self-delimiting — there is
no framing to invent; `UnexpectedEof` during decode means need-more-bytes).
**House rule (Joel, 2026-07-21): NO `unsafe` in our Rust — the crate root carries
`#![forbid(unsafe_code)]`.** If a design corner seems to need `unsafe`, either take the
safe-Rust performance hit or pull a mature open-source crate that abstracts it (more eyes =
inherently safer); nothing in this card's scope (tokio net/process, rmpv) needs any.
**Shared-file wiring:** root `Cargo.toml` members line `"./crates/lain-core"` (orchestrator,
same commit — the crate MUST be a workspace member from its first commit or the root
pre-commit hooks never see it).

A workspace-member tokio binary: listens on a socket path given by argv (never computes its
own — path policy is Ruby's, via `Paths#runtime_dir`), stderr is never inherited-terminal
output (tracing goes to a file path given by argv, or `/dev/null` when absent — the Journal
interleaving wound stays closed). Serves `ping` → `{version, pid}` and `exec`
`{argv, cwd, env, timeout_ms}` → `{stdout: bin, stderr: bin, exit_status, timed_out}`:

- **Concurrent by design:** requests on one connection are handled as independent tasks;
  responses carry the request's msgid and may complete out of order. (C2's client depends on
  this — it is part of the protocol contract, not an optimization.)
- **Timeout is server-side:** at `timeout_ms` the child is killed (kill-on-timeout, matching
  ShellOut's semantics) and the response says so; no orphaned children.
- **Env override, not confinement** (doc comment verbatim): merged over the child's inherited
  env; a msgpack **nil value removes the key** (the `WorkerEnv` explicit-nil scrub,
  `worker_env.rb:14-18`) — nil is remove, never empty-string.
- **stdout/stderr are msgpack `bin`**, not `str` — subprocess output is arbitrary bytes.
- **Two error surfaces, both specified:** a *decodable but invalid* request (non-array, bad
  arity, unknown method) gets an RPC error response (msgid echoed when recoverable, 0 when
  the frame carried none); *undecodable bytes* poison the stream — the connection closes,
  the server survives, other connections unaffected.

`clippy --all-targets -- -D warnings` clean; `#![forbid(unsafe_code)]` at the crate root;
`cargo test` covers ping, exec round-trip, out-of-order msgid completion, timeout-kill,
nil-env-scrub, bin payloads, invalid-request error replies, and poisoned-stream close.

**Acceptance criteria:**

```gherkin
Scenario: exec round-trips bytes and status
  Given lain-core serving on a tempdir socket
  When a test client calls exec with argv ["sh", "-c", "echo out; echo err >&2; exit 3"]
  Then the response carries stdout bytes "out\n", stderr bytes "err\n", exit_status 3, timed_out false
```
→ test: `crates/lain-core/src/exec.rs` (`#[cfg(test)]`)

```gherkin
Scenario: two in-flight execs complete out of order, matched by msgid
  Given one connection with exec(sleep 0.3) sent before exec(true)
  When both responses arrive
  Then the fast command's response arrives first and each response's msgid matches its request
```
→ test: `crates/lain-core/src/rpc.rs` (`#[cfg(test)]`)

```gherkin
Scenario: timeout kills server-side
  Given an exec of a long sleep with timeout_ms 100
  When the response arrives
  Then timed_out is true and the child process no longer exists
```
→ test: `crates/lain-core/src/exec.rs` (`#[cfg(test)]`)

```gherkin
Scenario: a nil env value removes the variable
  Given exec of ["sh", "-c", "echo ${SECRET:-absent}"] with env {"SECRET" => nil} and SECRET set in the daemon's env
  Then stdout is "absent\n"
```
→ test: `crates/lain-core/src/exec.rs` (`#[cfg(test)]`)

```gherkin
Scenario: invalid requests err, undecodable bytes close, the server survives both
  Given a connection sending a valid-msgpack non-array then a ping, and a second connection sending garbage bytes
  Then the first connection receives an error response then a ping answer
  And the second connection closes while a third connection's ping still answers
```
→ test: `crates/lain-core/src/rpc.rs` (`#[cfg(test)]`)

**Escalation triggers:**
- If adding the member breaks `ext/lain`'s `rake compile` or changes its clippy surface
  (workspace-level lint/profile bleed), stop — the orchestrator owns the workspace layout.
- If `cargo-deny` rejects a dependency of the chosen msgpack/tokio stack, stop and surface
  the alternatives rather than loosening the deny config.

### C2 — Lain::Core::Client — spawn, connect, demux, die loudly          [wave 2] [risk: medium] ✅ LANDED 1854b1c

> Panel: APPROVE-WITH-FIXES. Substantive: malformed frame kills the reader silently (hangs
> all callers; Async's console logger leaks JSON to stderr — outside the AST spec's reach);
> perish hangs in wait2 vs a close-but-alive daemon (must force the exit it reports);
> unbounded ping handshake after bounded connect. S4: stale-socket rm_f silently steals a
> LIVE daemon's path + boot-race cross-wiring — honest comment now, **probe-connect-then-
> refuse deferred to the pinned-daemon/adoption chunk**. Also deferred: KILL escalation in
> Child#stop (supervisor chunk). IO::Buffer warning absorption ruled HONEST (frontend-owner
> flag carried). msgpack gemspec declaration landed separately as 0059ef9.

**Depends on:** C1
**Files:** `lib/lain/core.rb` (create — unit index), `lib/lain/core/client.rb` (create),
`lib/lain/core/child.rb` (create), `spec/lain/core/client_spec.rb` (create)
**Reuse:** `Paths#runtime_dir` (`paths.rb:49-52`) + `project_hash` (`paths.rb:56-58`) for the
socket path (`<runtime_dir>/core-<project_hash>.sock`); plain `UNIXSocket` IO (fiber-parking
per the grounding); `Lain::Promise` for pending calls; the error-taxonomy convention (a
refusal subclasses `Lain::Error` next to its owner, e.g. `Paths::Unwritable`).
**Shared-file wiring:** `lib/lain.rb` manifest line for the `core` unit; `spec/spec_helper.rb`
`:core` tag exclusion; `Rakefile` `core:build` task (orchestrator).

`Core::Child` (NOT `Core::Process` — that constant would shadow `::Process` for the whole
namespace) owns the daemon lifecycle: `Process.spawn` with socket path + tracing path argv
(tracing file under `runtime_dir`, stderr `:close` — never the parent's stderr), bounded
connect retry, reap on stop. `Core::Client` owns the wire: **one reader-loop fiber** drains
the socket and resolves an msgid→Promise map; `#call(method, params)` writes a frame,
registers its promise, and awaits — so N concurrent callers interleave safely by
construction (the demux design C1's out-of-order contract requires). Version handshake via
`ping` on connect: exact string match against the client's pinned protocol version, mismatch
raises naming both. A dead/killed child fails every in-flight and subsequent call with
`Core::Died` carrying the exit status or signal. Specs are `:core`-tagged (excluded by
default; `rake core:build` compiles the daemon).

**Acceptance criteria:**

```gherkin
Scenario: concurrent calls demux by msgid
  Given a client connected to a real lain-core child
  When two fibers call exec concurrently (sleep 0.3 and true)
  Then each fiber receives its own command's result and total wall-clock is close to the longer sleep, not the sum
```
→ spec file: `spec/lain/core/client_spec.rb` (`:core`)

```gherkin
Scenario: a killed child fails loudly with the cause
  Given a client with an in-flight exec call
  When the lain-core process is killed with SIGKILL
  Then the in-flight call raises Core::Died naming the signal and a subsequent call raises Core::Died
```
→ spec file: `spec/lain/core/client_spec.rb` (`:core`)

```gherkin
Scenario: the socket and tracing file land under the XDG runtime dir
  Given a client built with an injected Paths whose XDG_RUNTIME_DIR is a tempdir
  When it spawns lain-core
  Then the socket is <tempdir>/lain/core-<project_hash>.sock and nothing was written to the parent's stderr
```
→ spec file: `spec/lain/core/client_spec.rb` (`:core`)

**Escalation triggers:**
- If fiber-parking IO on `UNIXSocket` does NOT cooperate with the Async scheduler (reactor
  stalls under the concurrency spec), stop — that contradicts the spike-verified premise and
  the transport choice needs rethinking, not a thread.
- If the reader-loop fiber outliving an `Agent#ask`'s per-call `Sync` block causes captive-
  fiber problems (the Supervisor exists precisely because of this shape), stop and reconcile
  with the Supervisor's ownership model before parenting the fiber elsewhere.

### C3 — Round-trip one tool through the boundary          [wave 3] [risk: medium] ✅ LANDED eadaa4d

> Escalation resolved on main (3b8c047, below). Panel APPROVE-WITH-FIXES → fix round →
> APPROVE: spawn-shaped Refused → error result (posture parity pinned; byte-identity is
> structurally impossible for spawn failure — ruled), timeout errors carry kill-time partial
> output (mixlib shape), `WorkerEnv#resolve` + `Bash.render_output` extractions make
> differential drift structurally impossible, client-side `with_timeout(timeout + grace)`
> backstop (the caller owns its deadline). Forward note: when the RPC protocol grows, an
> error-kind field replaces the spawn-failed prefix match.

> C3's differential probes found tri-fold divergence, one root: exec.rs kills/captures the
> DIRECT CHILD where ShellOut group-kills (setsid) and ends capture at direct-child exit.
> Symptoms: `(sleep 0.5; echo late) & echo early` → bash `early\n` vs daemon `early\nlate\n`
> (drain-to-EOF); timed-out replies held until orphaned grandchildren release pipes; timeout
> SIGKILL orphans grandchildren. **Orchestrator ruling:** C1's own card said "kill-on-timeout,
> matching ShellOut's semantics; no orphaned children" — the daemon is in defect against its
> own contract. Fix in exec.rs (C1 owner): process-group spawn, group-kill on timeout, capture
> ends at direct-child exit (drain-to-EOF rejected: grandchildren extend capture arbitrarily
> and hold the reply hostage). No wire change; no Ruby normalization. Scope expansion
> authorized: C3 adds core_exec to E1's partition spec false-set (the spec's designed
> new-tool tripwire fired as intended).

**Depends on:** C2
**Files:** `lib/lain/tools/core_exec.rb` (create), `spec/lain/tools/core_exec_spec.rb`
(create), `bin/demo-core` (create)
**Reuse:** `Tools::Bash`'s **`Tool::Input` class, shared not copied** (schema drift would
quietly invalidate the differential — extract/reuse the exact input class); tier-3
`requires_approval?` gating (`bash.rb:57-59`); `WorkerEnv` cwd/env threading
(`worker_env.rb:29-42`); the `bin/demo-*` convention (`bin/demo-supervision`,
`bin/demo-fanout`).
**Shared-file wiring:** `lib/lain/tools.rb` index line for `core_exec` (orchestrator).

`Tools::CoreExec`: Bash's input schema (shared class), tier 3, approval-gated, executes via
`Core::Client#call(:exec, ...)` with `WorkerEnv` cwd/env — including the explicit-nil scrub
mapped to msgpack nil. Not added to `base_tools` — a comparison arm, constructed explicitly.
The differential spec runs identical commands through `Tools::Bash` and `Tools::CoreExec`
and asserts identical result content, including a nil-scrub case and a non-UTF-8-output
case (the `bin` payload contract). `bin/demo-core` spawns lain-core, runs both paths, kills
the child mid-command to demonstrate the loud error. The tool's doc comment repeats: this is
a transport boundary, **not** a sandbox.

**Acceptance criteria:**

```gherkin
Scenario: differential — core exec matches bash byte-for-byte
  Given the same commands run through Tools::Bash and Tools::CoreExec under one WorkerEnv
  When both results resolve for a text command, a non-UTF-8-output command, and a nil-scrubbed-env command
  Then stdout, stderr, and exit status in the Tool::Result content are identical in every case
```
→ spec file: `spec/lain/tools/core_exec_spec.rb` (`:core`)

```gherkin
Scenario: boundary death is a tool error, not a hang
  Given a CoreExec call in flight
  When lain-core dies
  Then the tool returns Tool::Result.error naming Core::Died within the tool timeout
```
→ spec file: `spec/lain/tools/core_exec_spec.rb` (`:core`)

**Escalation triggers:**
- If output-discipline or attribution requirements (live_stdout attributed at source, like
  Bash's `tool_output` telemetry) can't be met without streaming support in the RPC protocol,
  stop — protocol growth is a C1 design change, not a C3 patch.
- If the differential finds divergence between ShellOut and tokio::process capture beyond
  the specified cases, stop and record it — "identical bytes" is the card's point; do not
  paper over with normalization.

## Integration checks

- `bundle exec rspec` — full suite green; `:core` excluded by default, then
  `rake core:build && bundle exec rspec --tag core` green.
- `bundle exec rubocop` — clean, no `Metrics/*` loosening.
- `cargo test && cargo clippy --all-targets -- -D warnings` — one root invocation now covers
  both workspace members (`ext/lain` + `crates/lain-core`).
- `pre-commit run --all-files` — all hooks pass (cargo-deny now sees lain-core's deps in the
  root lock).
- Output-discipline spec still green; `crates/lain-core` crate root denies
  `clippy::print_stdout`/`print_stderr` AND carries `#![forbid(unsafe_code)]` (grep-check
  both).
- **Manual pass (Joel):** run `bin/demo-core`; confirm the differential output, the loud
  mid-command kill, and that no lain-core process, socket, or tracing file grows unbounded
  or survives exit (`ls $XDG_RUNTIME_DIR/lain/`).
- **Manual pass (Joel):** one real chat session with parallel-safe tools — confirm a turn
  with several reads feels faster and the transcript interleaving reads sanely.
