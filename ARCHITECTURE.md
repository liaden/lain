# Architecture

This is a map, not a second copy of the pitch. For *why* lain exists and what it optimizes for,
read the README's "What Lain is, and what it is not" and "Architecture, in one breath" — this
document does not restate either. What follows names, for each moving part, the files that
actually implement it at `HEAD`, so an engineer can go straight from a concept to the code.

A note on staleness before anything else: the README's Status table (M0/M1, "no `lib/lain/tools/`,
no `exe/lain`") describes an earlier point in the project and is well behind the code below —
`lib/lain.rb`'s manifest alone requires 60+ units, `lib/lain/tools/` has twenty-odd tools, and
`exe/lain` is a working Thor CLI. Where a doc and the code disagree, this document follows the
code, per `CLAUDE.md`'s own instruction to treat aspirational README examples as target design.

## The data spine: Canonical, Event (Turn), Store, Timeline

| Concept | Primary files |
|---|---|
| Deterministic serialization | `lib/lain/canonical.rb` |
| Content addressing (digest mixin) | `lib/lain/content_addressed.rb` |
| The envelope that generalizes `Turn` | `lib/lain/event.rb`, `lib/lain/event/payload.rb` |
| The append-only object database | `lib/lain/store.rb` |
| The (head digest, store) pointer | `lib/lain/timeline.rb` |
| Deep immutability | `lib/lain/freezable.rb` |

`Lib::Canonical` produces deterministic bytes (sorted keys, stable array order, BLAKE3 digest)
and serves two invariants at once: event identity and prompt-cache stability. This is the same
"one function, two invariants" claim `CLAUDE.md`'s "Architecture, in one breath" makes about
`Canonical` and turn hashing.

One thing has moved since that paragraph was written: there is no standalone `Turn` class in the
current tree. `Lain::Event` (`lib/lain/event.rb`) is a CloudEvents-shaped envelope with a closed
`KINDS` set (`turn spawn message snapshot`); `Event.turn(...)` is what `Turn.new` used to be, and
`Timeline#commit` (`lib/lain/timeline.rb`) calls exactly that. The Merkle-DAG properties `CLAUDE.md`
describes — O(1) `fork`, `diverge_at`, `meet` as a semilattice operation — are unchanged and still
live on `Timeline`; they are just built over `Event` now rather than a separate `Turn` type. Two
edges are worth knowing apart, because the render chain and the causal graph deliberately diverge:
`render_parent` is the single first-parent edge the model sees; `causal_parents` is a set used by
`:spawn`/`:message` events (subagent lineage, see below) that never enters any render chain. Both
edges are referential-integrity-checked by `Store#put`.

`Store` (`lib/lain/store.rb`) is the append-only, content-addressed map underneath; `Timeline` is
only ever a `(head_digest, store)` pair, which is what makes `#fork` free — it returns `self`,
because immutability makes forking and identity the same operation.

## `Context#render` is a pure function

Primary files: `lib/lain/context.rb`, `lib/lain/context/base.rb`, and the combinators under
`lib/lain/context/` — `cache_breakpoints.rb`, `reminder.rb`, `prune.rb`, `compact.rb`,
`dedupe_tool_calls.rb`, `purge_failed_inputs.rb`, `protected_patterns.rb`, `recall.rb`,
`mailbox.rb`, `message_envelope.rb`, `tail_injection.rb`. `lib/lain/workspace.rb` and
`lib/lain/request.rb` are the two collaborators purity is defined against.

`Context#render` is the pure function `(Timeline, Toolset, Workspace) -> Request` that `CLAUDE.md`
names. Purity means no `Time.now`, no session ids, no `Dir.pwd` inside `#render` — the same
constraint prompt caching imposes on the encoded request, so purity and cache-hit-ability are one
requirement, not two. `Context.pipeline` (in `context.rb`) composes the combinator chain — today
`Reminder.new(workspace:) >> CacheBreakpoints.new` — with `Middleware::Composable`'s `>>` operator
(see below), so `Context::REQUIRES` is *derived* from the same pipeline `#render` runs rather than
hand-maintained separately. `Workspace` (`lib/lain/workspace.rb`) is the "sent, not stored" state —
todos, staleness ledger, budget countdown — that `Reminder` folds into the request tail; it is
never appended to the `Timeline`, which is the mechanism behind `CLAUDE.md`'s "Workspace is sent,
not stored" line.

## Effects, handlers, Gate, and Middleware

Primary files: `lib/lain/effect.rb`; `lib/lain/effect/handler.rb` and its children
`lib/lain/effect/handler/{live,gate,mock,recorded,summarizing}.rb`; `lib/lain/middleware.rb` and
`lib/lain/middleware/{env,journal_requests,journal_turns,skill_dispatch,refuse_secret_writes}.rb`;
the loop side, `lib/lain/agent/tool_runner.rb`.

A tool call (or model call) is built as an `Effect` — frozen `Data` values in `lib/lain/effect.rb`
(`Effect::ToolCall`, `Effect::ModelCall`, `Effect::Approval`) — and interpreted by an
`Effect::Handler` (`lib/lain/effect/handler.rb`). Handlers compose by decoration: each holds an
optional `inner` and delegates whatever it does not itself handle, exactly the chain-of-
responsibility shape `Middleware::Composed` uses one layer up. `Effect::Handler::Live`
(`lib/lain/effect/handler/live.rb`) actually dispatches a tool; `Effect::Handler::Gate`
(`lib/lain/effect/handler/gate.rb`) wraps an inner handler and asks an injected `policy`
(`ApproveAll`, `DenyAll`, or a real interactive queue) before letting a tier-gated `ToolCall`
through — it holds no `Toolset` of its own, and instead asks its `inner` what a tool name resolves
to, so gating and dispatch can never disagree about what a name means. `Effect::Handler::Mock` and
`Effect::Handler::Recorded` are the deterministic-replay handlers `CLAUDE.md`'s "deterministic
replay is simply a recorded handler" line refers to.

`Lain::Middleware` (`lib/lain/middleware.rb`) is the Rack/Sidekiq/Faraday-idiom public API over
that same composition: `Composable#>>`, `Composed`, and `Base` are a property-tested monoid
(associative, `Identity` pass-through). Four middleware phases ride this API today: model, tool,
turn, and repl. `lib/lain/middleware/journal_requests.rb` and `journal_turns.rb` are the model/turn
phases that write into the session record (see disk layout below); `refuse_secret_writes.rb` is a
tool-phase middleware that withholds a credential-shaped `memory_write` before it reaches the
recorder; `skill_dispatch.rb` is the repl-phase middleware a `@role/skill` line folds through.
`Agent::ToolRunner` (`lib/lain/agent/tool_runner.rb`) is where `Effect::Handler#middleware_app`
(the adapter that lets a `Handler` terminate a `Middleware::Stack`) actually gets driven from the
loop. The loop itself — `Lain::Agent` (`lib/lain/agent.rb`), `Agent::Budget`,
`lib/lain/agent/loop_machine.rb` — is a `state_machines` state machine, generated to
[`docs/agent-state-machine.md`](docs/agent-state-machine.md) by a spec that fails the build on
drift; that document is the source for `stop_reason` handling and is not repeated here.

## The Provider boundary

Primary files: `lib/lain/provider.rb`; `lib/lain/provider/{anthropic,anthropic_raw,anthropic_encoding,bedrock,bedrock_raw,ollama,mock,http}.rb`; `lib/lain/request.rb`,
`lib/lain/response.rb`, `lib/lain/usage.rb`, `lib/lain/cache_profile.rb`.

`Provider` (`lib/lain/provider.rb`) is one round trip, never a loop: `#capabilities`, `#encode`,
`#complete`. Capabilities are machine-checked rather than documented — `Provider::CAPABILITIES` is
a closed list, a `Context` combinator declares `#requires`, and a mismatch is resolved by an
explicit `:strict`/`:degrade`/`:simulate` policy rather than a silent no-op. `Provider::Anthropic`
is the official-SDK path kept as the correctness oracle; `Provider::AnthropicRaw` /
`anthropic_encoding.rb` are the forked-transport path being byte-diffed against it;
`Provider::Bedrock` / `bedrock_raw.rb` and `Provider::Ollama` are the other two live backends;
`Provider::Mock` is the deterministic test double. `docs/porting-providers.md` and `docs/ollama.md`
carry the provider-specific detail (wire quirks, local smoke-testing) — read those rather than
looking for it here. `Lain::Request` / `Lain::Response` (provider-neutral value objects) and
`Lain::Usage` (a property-tested commutative monoid) are what every provider translates to and
from; `CacheProfile` (`lib/lain/cache_profile.rb`) is the per-provider cache-economics object
`StatusFeed` (below) reads real TTL numbers from.

## Repl collaborator graph

Primary files (post-`T1` extraction — see the note below): `lib/lain/cli/repl.rb`,
`lib/lain/cli/wiring.rb`, `lib/lain/cli/live_views.rb`, `lib/lain/cli/human_replies.rb`.

> **These four paths do not exist in this worktree yet.** As of this writing the classes they will
> hold — `Repl`, `Wiring`, `LiveViews`, `HumanReplies` — are defined inline in `exe/lain`, a
> ~785-line file whose own header says the extraction is deliberate ("Extracted from the Thor
> class because a conversation is its own responsibility"). A sibling task card (`T1` in the same
> chunk this card belongs to) is relocating them to the four paths above with no behavior change.
> The graph described here is accurate to that inline code today and is expected to still be
> accurate once `T1` lands — only the file paths move.

`LainCLI#chat` (in `exe/lain`) stays a thin flag-parse-and-close bracket. Everything it delegates
to is one of four collaborators:

- **`Wiring`** assembles one chat's collaborators over an already-open `Chronicle`
  (`lib/lain/cli/chronicle.rb`): the toolset (`base_tools` plus a research `Tools::Subagent`, an
  `AskHuman` reply tool, and `RunSkill`), the `Effect::Handler::Gate` wrapping
  `Effect::Handler::Live` (`build_agent`), the `Supervisor` (`lib/lain/supervisor.rb`), the
  `Skill::RoleSpawn` seam (`lib/lain/skill/role_spawn.rb`) a `@role/skill` line folds through, and
  the `Approval::Queue` (`lib/lain/approval/queue.rb`) `--yolo` bypasses. It hands back a built
  `Agent` and exposes the `ask_human`/`questions` seams `Repl` needs.
- **`Repl`** owns one conversation: reads `you>` prompts through `CLI::Conductor`
  (`lib/lain/cli/conductor.rb`, the shutdown/signal bracket — see `lib/lain/cli/shutdown.rb` and
  `lib/lain/cli/signals.rb`), routes each line through the repl-phase `Middleware::Stack`
  (`CLI::ReplMiddleware.build`, `lib/lain/cli/repl_middleware.rb`), and runs the ask itself
  (`Agent#ask`) inside an `Async` `Sync` block alongside the approval-watch and human-reply
  fibers. It hosts the `Supervisor`'s reactor task for the conversation's life (`OM-6`: an actor's
  fiber must outlive any single ask) and nests an optional `Frontend::Neovim`
  (`lib/lain/frontend/neovim.rb`) inside the `Frontend::TTY` (`lib/lain/frontend/tty.rb`) run.
- **`HumanReplies`** is the `ask_human` reply surface: a TTY drain loop plus, when `--nvim` is
  attached, an `:LainReply` consumer reading the editor's command inbox — `AskHuman::Notifying`
  (`lib/lain/tools/ask_human.rb`) is the tool both surfaces resolve.
- **`LiveViews`** builds the `--nvim`/`--journal` tee: a `Channel::DropOldest`
  (`lib/lain/channel/drop_oldest.rb`) for the editor and a `StatusFeed`
  (`lib/lain/status_feed.rb`) for the tmux HUD, fanned through one `CLI::JournalTee`
  (`lib/lain/cli/journal_tee.rb`) — see the fan-out section below.

`CLI::Backend` (`lib/lain/cli/backend.rb`) is the provider/model/sampler resolution both `chat` and
`bench record` share, and is the one piece of this graph that is *not* part of the extraction —
it already lives in `lib/`.

## Channel / JournalTee / StatusFeed fan-out

Primary files: `lib/lain/channel.rb`, `lib/lain/channel/drop_oldest.rb`,
`lib/lain/cli/journal_tee.rb`, `lib/lain/status_feed.rb`, `lib/lain/journal.rb`.

Two consumers, two policies, deliberately split. `Lain::Journal` (`lib/lain/journal.rb`) is the
lossless record: it writes synchronously, under a mutex, to its own fd — see the disk-layout
section below for what that fd is. `Lain::Channel` (`lib/lain/channel.rb`) is a `SizedQueue`-backed
event queue with blocking backpressure, the right default for a consumer that must not miss an
event but can tolerate throttling its producer. `Channel::DropOldest`
(`lib/lain/channel/drop_oldest.rb`) is the frontend's variant: it drops the oldest event on
overflow and surfaces a `Telemetry::Dropped` marker rather than block, because a blocked producer
on the render path would be a deadlock if the drain thread ever raised.

`CLI::JournalTee` (`lib/lain/cli/journal_tee.rb`) is the fan-out adapter: one `#<<` writes to the
durable `Journal` first (it must always land — it is the experiment record), then attempts every
live-view sink in order, capturing rather than short-circuiting on a `ClosedQueueError` (quitting
Neovim closes its `Channel`) so one dead sink never starves the others. `StatusFeed`
(`lib/lain/status_feed.rb`) is one such sink: it derives a small state struct (cache-warmth
deadline, the fleet of live spawns, the human-inbox count) from the events it observes and
republishes it to `.lain/state.json` for the tmux/TTY/nvim renderers — a project artifact next to
`.git/`, not resolved through `Paths`.

## Subagent, Supervisor, and isolation

Primary files: `lib/lain/tools/subagent.rb`; `lib/lain/supervisor.rb`,
`lib/lain/supervisor/restart.rb`; `lib/lain/isolation.rb` and
`lib/lain/isolation/{lease,null,worktree,journal,services,db_index,compose}.rb`;
`lib/lain/skill/role_spawn.rb`.

`Tools::Subagent` (`lib/lain/tools/subagent.rb`) is an ordinary tool — possession is authorization
to spawn a child `Agent`. The child runs a full, independent loop over the *shared* `Store` but a
*fresh* `Timeline` root, so the parent's prompt never inherits the child's turns. Two `Event`s
record the causal lineage the render chain omits: a `:spawn` event names the parent head the child
was spawned from, and a `:message` event carries the child's result back — neither is in any
render chain, so `Timeline#meet` and the first-parent walk are untouched by spawning. `max_depth`
is a hard, transitively-decrementing ceiling enforced at construction, not at call time.
`Skill::RoleSpawn` (`lib/lain/skill/role_spawn.rb`) is the sibling seam a `@role/skill` repl line
folds through — same attenuated-union, same spooled provider, chosen per call rather than per
toolset.

`Supervisor` (`lib/lain/supervisor.rb`) is the orchestration reactor *above* the `Agent` (its doc
comment labels this `OM-6`): a model-dispatched `mode: :actor` subagent spawns its fiber on
whatever `Async::Task.current` is at launch time, so it must be adopted under a task that outlives
any single `Agent#ask` — the `Supervisor` owns that outliving task and is also the fleet's
registry (role, state, head digest per adoption), which is what a HUD or a graceful drain
(`CLI::Shutdown`) enumerates. `Supervisor::Null` is the wired-nothing default that keeps a
non-actor subagent's refusal exactly as it was without the reactor. `Isolation`
(`lib/lain/isolation.rb`) answers a separate question — what host-side execution context a worker
leases — behind one message, `acquire(worker_id) -> Lease`: `Isolation::Null` is the shared-process
baseline, `Isolation::Worktree` provisions an isolated git checkout per worker, and
`isolation/{journal,services,db_index,compose}.rb` are strategies that enrich either. This
concurrency posture — why fibers (`async`) rather than threads or Ractors, and where the
cancellation guarantees come from — is argued at length in
[`docs/concurrency.md`](docs/concurrency.md); this section only names where the objects live.

## Session NDJSON and WAL disk layout

Primary files: `lib/lain/paths.rb`; `lib/lain/journal.rb`; `lib/lain/session_record.rb` and
`lib/lain/session_record/{scribe,replay,salvage}.rb`; `lib/lain/provider/response_wal.rb`;
`lib/lain/cli/chronicle.rb`, `lib/lain/cli/resume.rb`; `lib/lain/bench/session.rb`.

`Paths` (`lib/lain/paths.rb`) is the one naming authority. A live session's NDJSON file lands under
`$XDG_STATE_HOME/lain/sessions/<project-hash>/` (`Paths#sessions_dir`, `project_hash` = first 12
hex chars of `SHA256(expand_path(project_dir))`) as a timestamped file `Journal.open` creates. Its
companion write-ahead log sits *beside* it — `Paths.wal_for(ndjson_path)` strips whatever
extension the NDJSON path carries and appends `.wal`, so `<stem>.ndjson` gets `<stem>.wal`; both
`CLI::Chronicle#spool` (the writer) and `CLI::Resume`'s salvager (the reader) derive the same path
from the same session file so they can never name different files.

`Journal` (`lib/lain/journal.rb`) is the NDJSON writer: one event per line, synchronous, under a
mutex, on its own fd, never stderr — a serialization failure is caught and replaced in-line with a
self-describing `journal_error` record rather than tearing a line or dropping the event.
`SessionRecord` (`lib/lain/session_record.rb`) defines the on-disk shape written *through* that
journal: a `session` header written first with `head: nil` (open), then one `turn` record per
committed `Event`, plus live-only record types (`Telemetry::Message`,
`SessionClosed`, `RunInterrupted`) an older reader skips by construction.
`SessionRecord::Scribe` (`lib/lain/session_record/scribe.rb`) is the live writer attached to an
already-open `Journal`; `SessionRecord::Replay` reloads a session; `SessionRecord::Salvage`
(`lib/lain/session_record/salvage.rb`) recovers a paid-for-but-uncommitted response from the `.wal`
when a session resumes open after a crash — it is the reader side of `Provider::ResponseWal`
(`lib/lain/provider/response_wal.rb`), which frames each round trip's *raw* wire bytes (not a
re-serialization) between an RS-delimited header and terminator record, so a salvage pass can
re-parse exactly what the provider sent even if the process died mid-turn. `Bench::Session`
(`lib/lain/bench/session.rb`) is the format's other writer — a recorded bench run and a live chat
are byte-compatible on purpose, so one loader reads both.

## `ext/lain` vs `crates/lain-core`: the placement rule

Primary files: `ext/lain/CLAUDE.md`; `ext/lain/src/{lib,canonical,digest,dag,event,bm25,astgrep,treesitter}.rs`; `crates/lain-core/src/{main,rpc,exec}.rs`; `lib/lain/core.rb`,
`lib/lain/core/{child,client}.rb`.

The rule, verbatim from `CLAUDE.md`: **anything async, I/O-bound, or isolation-relevant lives out
of process (`crates/lain-core`, msgpack-RPC over a Unix socket); data-structure work lives
in-process (`ext/lain`, magnus, pure and synchronous).** `ext/lain/CLAUDE.md` restates the same
line and adds the mechanical reason: driving an async runtime from inside an FFI call while
holding the GVL is a known footgun, and an in-process sandbox is not a sandbox. `ext/lain` denies
`clippy::print_stdout`/`print_stderr` at the crate root — same posture as
`spec/output_discipline_spec.rb` enforces on the Ruby side — but does **not** forbid `unsafe`:
`lib.rs` has eight `unsafe` sites, confined to the magnus/libc FFI boundary (`libc::dup` and
`File::from_raw_fd` for the tracing fd; magnus calls like `classname`/`as_slice`).
`#![forbid(unsafe_code)]` lives on `crates/lain-core` instead, whose `main.rs` carries it at the
crate root alongside the same print-stdout/print_stderr denies.

`ext/lain/src/` today holds `canonical.rs`/`digest.rs` (the Rust side of `Canonical` hashing),
`dag.rs`/`event.rs` (the persistent Merkle DAG), and `bm25.rs`/`astgrep.rs`/`treesitter.rs` (pure,
synchronous data-structure work — in-memory BM25 and AST/structural-search backing for
`lib/lain/structural/`). `crates/lain-core` is a separate binary: `main.rs` is a msgpack-RPC daemon
on a Unix socket whose path arrives via argv (path *policy* stays in Ruby — `Paths#runtime_dir` —
the daemon never computes its own); `exec.rs` and `rpc.rs` are the out-of-process, isolation-
relevant exec boundary the placement rule reserves for this side. `lib/lain/core.rb` is the Ruby
half: `Core::Child` owns the daemon's process lifecycle, `Core::Client` owns the wire (one
reader-loop fiber demuxing an `msgid -> Promise` map over out-of-order completions). Both `ext/lain`
and `crates/lain-core` are real, built crates today, not the "NOT BUILT" placeholders the README's
topology diagram still marks them as (see the staleness note at the top of this document).
