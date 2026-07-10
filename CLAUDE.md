# Working on Lain

Lain is an agent harness built as a **study bench**. The agent is the vehicle; the bench is
the deliverable. Optimize for making context strategies, tool designs, and orchestration
tactics swappable, observable, and comparable — not for making the agent good.

The approved design plan lives at `~/.claude/plans/jiggly-greeting-avalanche.md`. Read it
before making architectural decisions. It records *why*, including several conclusions that
cost real debugging to reach.

## Toolchain

The shell's default `ruby` is the wrong one (system 3.2.3). This project needs 4.0.5:

```bash
export PATH="$HOME/.rubies/ruby-4.0.5/bin:$PATH"
```

`bundle install` and `gem` write outside the repo, so they need the sandbox disabled.
`ruby-4.0.1` is also installed and is **unusable** for native gems — its `RbConfig` points at
a deleted Homebrew `gmkdir`/`ginstall`.

```bash
bundle exec rspec              # 297 examples; :integration excluded by default
bundle exec rubocop -a         # safe autocorrect; see the warning below
bundle exec rake compile       # builds the Rust extension into lib/lain/lain.so
cargo test && cargo clippy --all-targets -- -D warnings
pre-commit run --all-files     # what the git hook runs
```

Integration specs hit the real API and cost money. They run only with **both**:

```bash
LAIN_INTEGRATION=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec
```

## RuboCop

Use `rubocop -a`. Do **not** reach for `-A` without reading the diff.

`-a` applies only cops marked `Safe: true`. `-A` also applies unsafe ones, and at least one of
those is actively dangerous here: `Style/RedundantSelfAssignment` (`Safe: false`) flagged
`@timeline = @timeline.append(...)` on the assumption that `append` mutates its receiver, as
`Array#append` does. Ours was pure. The "correction" would have discarded every turn with no
test failure. The method is now `Timeline#commit`, which both reads correctly and sidesteps
the cop.

**Never loosen a `Metrics/*` limit to make code pass.** Extract a collaborator with a real,
separate responsibility (see `Agent::Budget`, `Agent::ToolRunner`). Config that encodes a
*reasoned policy* is fine — `Metrics/ParameterLists: CountKeywordArgs: false`,
`Naming/BlockForwarding: explicit`.

## Code style

- **No `next`, `break`, or `redo`** unless genuinely unavoidable. `raise ... unless cond` beats
  `next if cond`; `select` then `each` beats `next unless`; `digest &&= step` beats
  `break if digest.nil?`.
- **No ActiveSupport core extensions in `lib/`** for their own sake. `activemodel` is a
  dependency for declarative validation of tool input *shape*; reach for it there, not to save
  three characters elsewhere.
- **Doc comments explain WHY, not what.** Match `lib/lain/timeline.rb` and
  `lib/lain/canonical.rb`.
- **Value objects are deeply frozen.** `Ractor.shareable?(turn)` must stay `true` — it is the
  mechanical statement of "no reachable mutable state", and it broke once because
  `Symbol#to_s` and string interpolation both return *mutable* Strings. There is a spec.

## Output discipline

Only the frontend may touch `$stdout`/`$stderr`. Everything else writes to an injected
`Lain::Sink` or pushes attributed events onto a `Lain::Channel`. `spec/output_discipline_spec.rb`
parses the AST of every file in `lib/` and fails on `puts`/`print`/`warn`/`$stdout`/`$stderr`
outside `lib/lain/frontend/`. The Rust extension denies `clippy::print_stdout` and
`clippy::print_stderr` at the crate root.

This is not fussiness: the Journal is NDJSON, it is the experiment record, and one stray
warning interleaved into it makes `JSON.parse` fail on that line. We found this the hard way.

## Testing

Write specs alongside the code — unit specs plus lightweight `:integration` specs that hit the
live API.

**Each spec must `require` its own subject** (`require "lain/agent"`), not rely on `lain.rb`
wiring. `pre-commit` stashes tracked-but-unstaged changes before running hooks, so a spec that
depends on `lain.rb` will fail during an unrelated commit when `lain.rb` is stashed back to
`HEAD`. Specs that load themselves are immune.

## Committing

Commit directly on `main`, in logical chunks, with terse high-signal messages. No trailers.

**Commit in dependency order.** Because pre-commit stashes unstaged tracked changes and runs
the full suite against the staged tree, a commit whose staged files reference not-yet-committed
changes will fail. Commit the leaf first. If a hook fails, the files stay staged — `git reset`
before the next `git add`, or they get swept into the wrong commit.

## Architecture, in one breath

`Canonical` gives deterministic bytes, which serve turn hashing *and* prompt-cache stability —
one function, two invariants. `Turn`/`Store`/`Timeline` form a lossless content-addressed
Merkle DAG, so `fork` is O(1) and `diverge_at` localizes a cache break. `Context#render` is a
**pure** function `(Timeline, Toolset, Workspace) → Request`; purity and cache-hit are the same
constraint. Tool calls are `Effect`s interpreted by a `Handler`; `Middleware` is the Rack-idiom
public API over that, and it is a property-tested monoid. Tools are capabilities, not
permissions. `Provider` is one round trip, never a loop — Lain owns the loop, because the loop
is the object of study.

`Workspace` is **sent, not stored**: it renders into the Request and is never appended to the
Timeline. Subagents get a *fresh* Timeline root whose `meta["spawned_from"]` names the parent's
head, so causal lineage survives while the child never inherits the parent's prompt.

## Known traps (verified, not remembered)

- Anthropic's stream accumulator is `accumulated_message`, **not** `get_final_message`. The
  stream is single-pass and `accumulated_message` mutates its snapshot.
- On the **streaming** path with raw-hash tool schemas, `tool_use.input` arrives as a raw JSON
  **String**. `Provider::Anthropic` parses it; nothing above the Provider may see it.
- The system keyword is `system_:` (trailing underscore). Content-block `.type` is a **Symbol**.
- `:model_context_window_exceeded` and `:compaction` are **Beta-only** stop reasons. The
  non-beta enum is `:end_turn :max_tokens :stop_sequence :tool_use :pause_turn :refusal`, and it
  is non-exhaustive — always have an `else`.
- Anthropic's minimum cacheable prefix is 4096 tokens. A short system prompt silently will not
  cache, with no error.
- `require "active_support/core_ext"` fails unless `require "active_support"` comes first.
