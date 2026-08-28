# Working on Lain

Lain is an agent harness built as a **study bench**. The agent is the vehicle; the bench is
the deliverable. Optimize for making context strategies, tool designs, and orchestration
tactics swappable, observable, and comparable — not for making the agent good.

The approved design plan lives at `~/.claude/plans/jiggly-greeting-avalanche.md`. Read it
before making architectural decisions; it records *why*.

This file is the **rules**. The evidence behind them lives next door, and each rule below
links to its own:

| | |
|---|---|
| `ARCHITECTURE.md` | how the system is put together, subsystem by subsystem |
| `docs/toolchain-traps.md` | failures that are not what they look like — read before believing a red suite |
| `docs/spec-suite-performance.md` | worker counts, profiling, allocations; read before changing how the suite runs |
| `docs/rust-bindings.md` | the five tests a capability passes before it earns a binding |

## Toolchain

The shell's default `ruby` is the wrong one. This project needs **4.0.6, from mise** — 4.0.5
crashes the VM under `rake pspec`. `.envrc` handles an interactive shell that has `cd`'d in;
non-interactive callers (agents, scripts) prefix with `direnv exec .` or export it themselves:

```bash
eval "$(mise env -s bash ruby@4.0.6)"
export LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib   # OpenSSL; see toolchain-traps
export TMPDIR="$HOME/tmp/lain"                          # same filesystem as the repo, required
```

```bash
bundle exec rake pspec         # THE suite command: 21-27s. Bare `rspec` is the same examples
                               # SERIALLY at ~3m17s -- 8x slower, no extra signal.
bundle exec rspec path/to/one_spec.rb   # one file or one example: use this, not a bare `rspec`
bundle exec rubocop -a         # safe autocorrect only; never -A
bundle exec rake compile       # builds the Rust extension into lib/lain/lain.so (needs clang)
cargo test && cargo clippy --all-targets -- -D warnings
pre-commit run --all-files     # what the git hook runs
bundle exec rake spec:flakes   # 16 whole-suite runs in random orders; a hunt, not a gate
```

Opt-in tiers, both excluded by default:

```bash
LAIN_INTEGRATION=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec   # :api_integration -- costs money
bundle exec rake core:build && bundle exec rspec --tag core     # :core -- needs the daemon
```

Rules, with the evidence in [`docs/toolchain-traps.md`](docs/toolchain-traps.md):

- **Do NOT use `~/.rubies/ruby-4.0.6`** — dead `$LOAD_PATH`, and forcing it with `RUBYLIB` is
  worse than the breakage. **If the suite fails in a way you did not cause, check the
  interpreter before believing it.**
- **`TMPDIR` is shared mutable state between concurrent agents.** A red `pspec` is not evidence
  until nothing else is running: `pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'`
  must read 0 (`ps | grep` over-counts and deadlocks two waiters), and `pgrep -f '[p]re-commit'`
  too — the hook autostashes repo-wide, so another worktree's `git status` lies while it runs.
- **`LAIN_SPEC_WORKERS=12`** is the measured optimum *on this box*; `physical - 1` is the worst
  count tried. The wall is a MAX over files, not a sum, so **never shard a spec to game the
  packer** — one spec file per code file at the mirrored path. See
  [`docs/spec-suite-performance.md`](docs/spec-suite-performance.md) before optimising anything
  here; profile first, and a cost inside the SUBJECT is an application finding, not a spec one.
- **Check the example COUNT, not just the failure count.** `parallel_tests` reports only the
  examples that SURVIVED, so a dead worker, an OOM kill and a `SystemExit` all look like a pass.

## RuboCop

`rubocop -a` applies only `Safe: true` cops. **`-A` is dangerous here** — an unsafe cop once
proposed a "correction" that would have discarded every turn with no test failure.

**Never loosen a `Metrics/*` limit to make code pass.** Extract a collaborator with a real,
separate responsibility (see `Agent::Budget`, `Agent::ToolRunner`) — a tripped cop is usually
telling you an object is missing. Config that encodes a *reasoned policy* is fine
(`Metrics/ParameterLists: CountKeywordArgs: false`, `Naming/BlockForwarding: explicit`).

## Code style

- **No `next`, `break`, or `redo`** unless genuinely unavoidable. `raise ... unless cond` beats
  `next if cond`; `select` then `each` beats `next unless`; `digest &&= step` beats
  `break if digest.nil?`.
- **`Enumerable` and `Enumerator` are the good abstractions.** A method that yields composes.
  `include Enumerable` over reimplementing `map`; return an `Enumerator` rather than an Array a
  caller may not want; `each_with_object`/`inject` before an accumulator you mutate by hand.
  `Enumerator::Lazy` is how a Timeline walk stays O(1) in memory.
- **SOLID, read through Sandi Metz.** Small objects, one responsibility each; depend on
  messages, not on types; inject collaborators rather than construct them.
- **Null Object over `nil` checks.** `Sink::Null` is the exemplar — no caller ever writes
  `if sink`. A `nil` guard repeated at three call sites is an object waiting to be named.
- **TDD is what finds the seam.** Writing the spec first makes a dependency visible and forces
  it to be injected. `Provider::Mock` and `Effect::Handler::Mock` exist because specs needed them.
- **ActiveSupport is welcome where it earns its place** — `ActiveSupport::Concern` especially.
  Judge each core extension on whether it preserves **loud failure**: `StringInquirer` was
  rejected because `method_missing` makes a typo (`.setled?`) return `false` in silence.
- **Tool input goes through `Tool::Input`** (ActiveModel): one declaration yields both the JSON
  Schema the model sees and the local validation, so they cannot drift. Those validations check
  **shape, not safety** — read the comment atop `lib/lain/tool/input.rb` before adding a
  validator that sounds like a security control. It is not one.
- **Comments are minimal, and explain WHY.** If a reader cannot tell *what* the code does, that
  is a defect in the code — extract a named method until it reads. Comment only what is
  *forced*: a wire-format quirk, a cop's false positive, a performance shape. Match
  `lib/lain/timeline.rb`.
- **Value objects are deeply frozen.** `Ractor.shareable?(event)` must stay `true` — the
  mechanical statement of "no reachable mutable state". There is a spec.

## Comments

The rule above says a comment explains WHY. These say how much of it there may be, and what
one is allowed to cite. `bin/comment-census` measures all three and is the worklist.

- **Density is set by an exemplar, not by a ratio.** `lib/lain/timeline.rb` is the measured
  shape: **0.82 prose:code, longest comment block 24 lines**. Write toward that file rather
  than toward a number — the mandate is *whatever comments remain are genuinely useful*, and
  a ratio met by deleting a reason is a failure wearing a pass's clothes. For scale, the
  census reads `lib/` today at 68,713 prose lines against 44,873 code lines (1.53:1), with
  520 of 709 files (73%) carrying more comment than code.

- **YARD tags are exempt from all of it.** ~3,900 lines across `lib/` and `spec/`, and they
  carry the shape a reader skims by: `@param`, `@return`, `@!attribute` and their kin are
  never what a density argument is about. The census counts them as their own figure for
  exactly this reason.

- **Ticket references are banned in comments — every project-internal `<LETTER><NUMBER>`
  scheme.** `T15`, `F31`, `B12`, `E4`, `AC 2`, `OM-6`, `CE-5`, `RES2`: all out, and there is
  **no exempt tier**. QA finding numbers go with the rest, on the human's ruling that a
  citation's value is ephemeral while the work is in flight and that git history is the
  archive afterwards. **What replaces a citation is the reason in words** — never delete the
  surrounding sentence to lose a number, and a comment that only ever said "F31" was
  carrying no reason at all, so that one goes whole.
  - **Scope**, and exactly what the checker scans: `lib/`, `spec/`, `lib/lain/frontend/neovim/runtime/*.lua`.
  - **Not Rust.** `///` and `//!` under `ext/lain` and `crates/` are doc *attributes* held up
    by `#![deny(missing_docs)]`: deleting one is a denied lint and orphaning one is a compile
    error. A rule wider than its enforcement is false on landing, so this one stops at Ruby
    and Lua — and `spec/lain/comment_census_spec.rb` reads the scope named here back out of
    this file and compares it against what `bin/comment-census --check-tickets` really opens.
  - **A third-party identifier is not a ticket, and the letter cannot decide which is which.**
    `E4` is an enhancement note of ours; `E382` is nvim refusing `:write` on a `nofile`
    buffer. `C1` is a plan ticket in twelve comments here and Unicode's C1 control block in a
    thirteenth. So the classifier is **enumerated, not heuristic**, and a shape it cannot
    place is reported UNCLASSIFIED rather than swept — teach it before you sweep.

## Output discipline

Only the frontend may touch `$stdout`/`$stderr`. Everything else writes to an injected
`Lain::Sink` or pushes attributed events onto a `Lain::Channel`.
`spec/output_discipline_spec.rb` fails on `puts`/`print`/`warn`/`$stdout`/`$stderr` anywhere in
`lib/` outside `lib/lain/frontend/`; the Rust crates deny `clippy::print_stdout`/`print_stderr`.
Not fussiness: the Journal is NDJSON and it is the experiment record — one stray warning
interleaved into it makes `JSON.parse` fail on that line.

## Requires

Internal requires are centralized, never scattered. `lib/lain.rb` is the load-order manifest, in
topological dependency order — that one ordered list is where a circular dependency has to show
itself, because scattered `require` hides cycles behind idempotent early returns. A `foo.rb` with
a sibling `foo/` is that subtree's index and requires `foo/*` itself, WHERE load order dictates.
**Leaf files carry no internal requires at all**; external gem/stdlib requires stay in the leaf
files that use them, documenting real dependencies.

So: never add an internal `require_relative` to a leaf file. Add the new file to its unit's index,
and a new unit to `lain.rb` where its dependencies place it (a load-time `NameError` means the
entry is too early).

## Testing

Write specs alongside the code. Three levels, and the middle one is where this codebase's real
defects have lived:

- **unit** — one subject, collaborators doubled. The default, and 97.5% of the examples.
- **`:seam`** — two or more REAL components with no double between them, driving a real local
  resource (git, an editor, the compiled extension, a live fd). No network, runs by DEFAULT.
  `spec/lain/seams/` is for seams belonging to no single subject; one with an obvious subject
  stays at its mirror path and carries the tag. 2.5% of the suite but ~35% of a serial run —
  which is what makes `--tag '~seam'` a useful inner loop.
- **`:api_integration`** — hits the live API, costs money, opt-in. Named for what it integrates
  WITH: calling both tiers "integration" hid the distinction that matters, which is that one of
  them can fail because somebody else's service is down.

Specs require nothing internal: `spec/spec_helper.rb` does `require "lain"`. The corollary is the
commit-grouping rule below.

## Committing

Commit directly on `main`, in logical chunks, with terse high-signal messages. No trailers.

**Commit in dependency order.** pre-commit stashes unstaged tracked changes and runs the suite
against the staged tree, so a commit whose staged files reference not-yet-committed changes will
fail. Commit the leaf first. If a hook fails the files stay staged — `git reset` before the next
`git add`, or they get swept into the wrong commit.

**A new lib file, its index/manifest line, and its spec land in the SAME commit.** Specs load
through `lain.rb`, so an unstaged manifest edit gets stashed to `HEAD` while untracked specs
still run, and the spec's constant won't resolve.

## Architecture, in one breath

Full treatment in [`ARCHITECTURE.md`](ARCHITECTURE.md).

`Canonical` gives deterministic bytes, serving turn hashing *and* prompt-cache stability — one
function, two invariants. `Event`/`Store`/`Timeline` form a lossless content-addressed Merkle
DAG, so `fork` is O(1) and `diverge_at` localizes a cache break. **There is no `Lain::Turn`**: it
collapsed into `Lain::Event`, kind-tagged `:turn`, over a closed
`KINDS = %i[turn spawn message snapshot]`. `Context#render` is a **pure** function
`(Timeline, Toolset, Workspace) → Request`; purity and cache-hit are the same constraint. Tool
calls are `Effect`s interpreted by an `Effect::Handler`, with `Middleware` the Rack-idiom public
API over that (a property-tested monoid). Tools are capabilities, not permissions. `Provider` is
one round trip, never a loop — Lain owns the loop, because the loop is the object of study.

- **`Workspace` is sent, not stored**: it renders into the Request, never onto the Timeline. A
  subagent gets a *fresh* root whose `meta["spawned_from"]` names the parent's head, so lineage
  survives while the child never inherits the parent's prompt.
- **`Project` splits root from cwd**: **root** is the authority boundary (what `.lain/` governs),
  **cwd** is where a relative path resolves. `$HOME` is never *inferred* as a root.
- **The secret boundary is three places, and the split is forced** — a path classifier answers
  before a file is opened, a region detector cannot until it has the bytes. Gate on the effect
  (`Sensitivity::Policy`), filter on the result (`Middleware::WithholdSecretPaths`), mask on the
  content (`Middleware::RedactSecretReads`). **Tier-1 `read_file`/`grep`/`glob`/`list_files` do
  not check paths** — the boundary is one place a reader can find, not a check in every tool.
  And there is exactly one `Filter.new` in `lib/`: `Sensitivity::Policy` builds its own in
  `#initialize` and nothing exposes the classifier, so a gate that refuses a read while the
  listing enumerates the same path is unrepresentable rather than merely untested.

## Rust

**Rust is here for its data model and for capabilities Ruby has no good answer to, not for
speed.** The placement rule: **anything async, I/O-bound, or isolation-relevant lives out of
process (`crates/lain-core`, msgpack-RPC over a Unix socket); in-process work (`ext/lain`,
magnus) must be pure, synchronous, and must not own the terminal.**

Before binding anything, read [`docs/rust-bindings.md`](docs/rust-bindings.md) for the five
tests it must pass, then `ext/lain/CLAUDE.md` before writing the code.

## Known traps

Headlines only. Every one is verified, and the full account of each is in
[`docs/toolchain-traps.md`](docs/toolchain-traps.md) — read it there before working around one.

- Anthropic's stream accumulator is `accumulated_message`, **not** `get_final_message`.
- On the **streaming** path with raw-hash tool schemas, `tool_use.input` arrives as a JSON
  **String**; `Provider::Anthropic` parses it and nothing above the Provider may see it.
- The system keyword is `system_:` (trailing underscore); content-block `.type` is a **Symbol**.
- `:model_context_window_exceeded` and `:compaction` are **Beta-only** stop reasons, and the
  enum is non-exhaustive — always have an `else`.
- Anthropic's minimum cacheable prefix is 4096 tokens; a short system prompt silently will not
  cache, with no error.
- `require "active_support/core_ext"` raises unless `require "active_support"` comes first.
- Constants defined **inside a `Data.define(...) do ... end` block** are scoped to the enclosing
  module, not the Data class. Reopen the class instead.
- **A reopened class gets exactly ONE docstring, and it goes on the REOPEN** — YARD silently
  discards the rest. YARD also reads `@word` at the start of a comment line as a **tag**, so
  write a prose reference to a keyword argument inline, never as a line's first token.
- **`rm .git` before running anything in a COPY of a linked worktree** — its `.git` is a pointer
  file, so the specs drive git against the *original's* admin dir. One run deleted the copy.
- **A class named for a top-level constant SHADOWS it** for everything lexically inside the
  enclosing namespace. Root-qualify (`::Lain::Sensitivity`) at such a site.
- **`pre-commit` exports `GIT_INDEX_FILE`** into every hook, so a fixture that shells to `git`
  without scrubbing builds against lain's index — passes every normal run, fails at commit time.
- **Mutation harnesses lie by default here.** Same-size mutants collide with bootsnap's
  `(mtime-seconds, size)` key and run against stale bytecode. Stamp mtimes, wrap the run in
  `ensure`, and score on **the count EQUALLING the captured baseline** — a mutant that does not
  load is an unrun one, not a surviving one.
- **A generic filename in a shared scratchpad is shared mutable state between agents.** Name
  scratch files uniquely; the failure mode is a confident green from the wrong tree.
- **A tmux pane inherits the SPEC RUNNER's PATH, so a pane spec can pass on a binary production
  never sees.** `bundle exec` puts an installed `lain` on it, and a bare `lain watch` therefore
  worked in every spec for the life of a feature while dying of status 127 in a real cockpit.
- **Do not read the tree while a suite run is in flight** — a read can miss edits already on
  disk. Re-check after the run, not during.
- **`ls-files` truncates against the PROCESS directory.** `-C <dir>` is the fix; `--full-name`
  is not.
- **A `SystemExit` inside an example truncates the run and still reports "0 failures".** Pass
  `debug: true` to any Thor `.start` in a spec.
- **Record a flaky spec by NAME, never by line number** — lines drift within days, and a stale
  entry reads as "not a known flake". The current list, and the retired ones, are in
  `docs/toolchain-traps.md`.
- **Never name a `.toml` explicitly on a `rubocop` command line.** It gets parsed as Ruby and
  "corrected"; an `Exclude` entry does not save you. A bare `bundle exec rubocop` is safe.
