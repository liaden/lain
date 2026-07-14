# T4 — rubocop config evaluation: hash shorthand + thread_safety

Report-only card. No `lib/` edits, no `.rubocop.yml`/`Gemfile` edits landed here — the
orchestrator applies Part 1's diff between waves. Part 2 is **BLOCKED-ON-DISCUSSION**; nothing
in it is meant for mechanical application.

Toolchain: `export PATH="$HOME/.rubies/ruby-4.0.5/bin:$PATH"`, `bundle exec rubocop 1.88.2`.

---

## Part 1 — `Style/HashSyntax` `EnforcedShorthandSyntax`: RESOLVED, recommend `always`

### What triggered it

`lib/lain/agent/tool_runner.rb:51` currently reads:

```ruby
env = @middleware.call({ effect: effect, context: context }, &@handler.to_app)
```

Joel's review comment: *"I'm editing the below line to use a more modern ruby style. Rubocop
may need to be configured to set that rule"* — i.e. he wants `{ effect:, context: }`, and wants
the cop to hold the line, not just tolerate it. Current `.rubocop.yml` sets no
`EnforcedShorthandSyntax`, so the cop default (`either`) applies — it never flags either style,
so nothing currently enforces his preference anywhere else in the tree.

### Method

Ran `bundle exec rubocop --format simple` against the whole tree three times, changing only
`Style/HashSyntax: EnforcedShorthandSyntax` in `.rubocop.yml` between runs (reverted via
`git checkout -- .rubocop.yml` after each experiment). Baseline (no override, i.e. `either`):
**0 offenses** (247 files, clean).

| `EnforcedShorthandSyntax` | Offenses | Files | Notes |
|---|---:|---:|---|
| `either` (current default) | 0 | 0 | Never flags either style — does not enforce anything |
| `either_consistent` | 13 | 2 | Only flags hashes mixing explicit/implicit in the same literal |
| `always` | 553 | 119 | Flags every hash where a value is a bare local/method matching its key |
| `always` + vendored exclude (proposed) | 536 | 111 | Same, minus the 8 vendored `lib/lain/provider/http/**` files (17 offenses) |

### `either_consistent` in detail

Only fires on internal mix-and-match within one hash literal; it does **not** touch
`tool_runner.rb:51` (both keys already uniformly explicit — not mixed) or any hash where no
value happens to repeat its key's name. The 13 offenses are:

- `lib/lain/provider/http/provider.rb` — 12 offenses (vendored, 3 call sites: lines 96, 97,
  155, 157). Excluded from consideration either way; vendored files keep upstream shape.
- `lib/lain/provider/anthropic_raw.rb:165` — 1 offense, the only non-vendored hit:
  `Event::ProviderRetry.new(attempt: retry_count + 1, will_retry_in:, status: env[:status], reason: exception.class.name)`
  mixes an implicit `will_retry_in:` with three explicit keys; `either_consistent` would push
  it back to fully explicit.

**Verdict: `either_consistent` does not do what Joel asked for.** It would leave
`tool_runner.rb:51` untouched (both keys are already internally consistent, just not
shorthand), so his own edit would still need to be hand-applied everywhere else with no cop
support behind it.

### `always` in detail

`always` autocorrects any hash value that is *exactly* a bare local variable or zero-arg method
call sharing its key's name (`{ effect: effect }` → `{ effect: }`) — it does not touch
non-matching values (`status: env[:status]` stays explicit; confirmed `anthropic_raw.rb:165`
produces **zero** offenses under `always`, since `will_retry_in:` is already shorthand and no
other key in that hash qualifies). This is exactly the transform `tool_runner.rb:51` needs:

```
lib/lain/agent/tool_runner.rb:51 (2 offenses under `always`, autocorrects to)
  env = @middleware.call({ effect:, context: }, &@handler.to_app)
```

Confirmed the escalation trigger from the card: **`always` DOES rewrite the vendored
`lib/lain/provider/http/**` tree** (8 lib files, 17 of the 553 raw offenses:
`connection.rb`, `error_middleware.rb`, `message.rb`, `stream_accumulator.rb`,
`providers/anthropic/chat.rb`, `providers/anthropic/chat/response_parsing.rb`,
`providers/anthropic/chat/thinking_payload.rb`, `providers/anthropic/tools.rb`). Per CLAUDE.md
and the plan's vendoring policy, these keep upstream shape — the config below excludes them from
this cop specifically (not from rubocop generally). `spec/lain/provider/http/**` is **not**
vendored (it's Lain's own spec suite) and is **not** excluded — it converges along with
everything else.

### Recommendation: `always`, with a `Style/HashSyntax`-scoped exclude for vendored HTTP

`always` is the only setting that actually enforces the style Joel demonstrated, it is a
narrow/mechanical transform (only self-referential key/value pairs qualify — verified nothing
resembling "every hash gets rewritten"), and `Style/HashSyntax` is `Safe: true` (confirmed via
`rubocop --show-cops`), so `-a` needs no manual review of the diff.

**Verification performed** (not left in the working tree — done in a scratch copy at
`/tmp/.../scratchpad/repo-copy`, `.rubocop.yml` here was reverted after each experiment):

1. Applied the diff below to a full repo copy.
2. `bundle exec rubocop -a` → `536 offenses corrected`, `0` remaining.
3. `bundle exec rubocop` again → `247 files inspected, no offenses detected`.
4. `bundle exec rspec` on the corrected copy → `1170 examples, 0 failures` (copied the
   prebuilt `lib/lain/lain.so` in rather than rebuilding the Rust extension).

### `.rubocop.yml` diff (apply verbatim)

```diff
--- a/.rubocop.yml
+++ b/.rubocop.yml
@@ -32,3 +32,10 @@
 # name that explains the shape.
 Naming/BlockForwarding:
   EnforcedStyle: explicit
+
+# Joel's `{ effect:, context: }` in tool_runner.rb is the style we want everywhere a
+# hash value merely repeats its key -- `always` is the only shorthand setting that
+# actually enforces it (`either`/`either_consistent` tolerate the old form). Vendored
+# HTTP code keeps upstream shape, so it is excluded from this cop specifically.
+Style/HashSyntax:
+  EnforcedShorthandSyntax: always
+  Exclude:
+    - "lib/lain/provider/http/**/*"
```

### Autocorrect pass required after applying the diff

```bash
bundle exec rubocop -a
```

Expected: `536 offenses corrected`, then a clean `bundle exec rubocop` run (`247 files
inspected, no offenses detected`) — satisfying the card's acceptance criterion (zero offenses
outside `lib/lain/provider/http/**`, which is untouched by design).

**Full file list the autocorrect touches** (111 files — 40 `lib/`, 69 `spec/`, 2 scripts;
`lib/lain/provider/http/**` and its specs are listed separately below):

<details>
<summary>lib/ (40 files)</summary>

```
lib/lain/agent.rb
lib/lain/agent/accounting.rb
lib/lain/agent/model_caller.rb
lib/lain/agent/tool_runner.rb
lib/lain/bench/cli.rb
lib/lain/bench/dry_replay.rb
lib/lain/bench/live_replay.rb
lib/lain/bench/rewrites.rb
lib/lain/bench/session.rb
lib/lain/bench/session/loader.rb
lib/lain/bench/speculative.rb
lib/lain/bench/variance.rb
lib/lain/bench/variance_fixtures.rb
lib/lain/capability/policy.rb
lib/lain/channel/drop_oldest.rb
lib/lain/compare.rb
lib/lain/context.rb
lib/lain/effect.rb
lib/lain/event.rb
lib/lain/grader/fixture.rb
lib/lain/handler/approving.rb
lib/lain/handler/live.rb
lib/lain/handler/mock.rb
lib/lain/handler/recorded.rb
lib/lain/journal.rb
lib/lain/ledger.rb
lib/lain/ledger/index.rb
lib/lain/memory/bm25.rb
lib/lain/memory/index.rb
lib/lain/memory/manifest.rb
lib/lain/middleware/refuse_secret_writes.rb
lib/lain/price_book.rb
lib/lain/response.rb
lib/lain/sink.rb
lib/lain/timeline.rb
lib/lain/tool.rb
lib/lain/tool/contracts.rb
lib/lain/tool/input.rb
lib/lain/tools/bash.rb
lib/lain/tools/todo_write.rb
```
</details>

<details>
<summary>spec/ (69 files)</summary>

```
spec/lain/agent_spec.rb
spec/lain/agent/accounting_spec.rb
spec/lain/agent_state_machine_diagram_spec.rb
spec/lain/agent_state_machine_spec.rb
spec/lain/agent_turn_middleware_spec.rb
spec/lain/bench/cli_spec.rb
spec/lain/bench/dry_replay_spec.rb
spec/lain/bench/live_record_spec.rb
spec/lain/bench/live_replay_spec.rb
spec/lain/bench/rewrites_spec.rb
spec/lain/bench/session_spec.rb
spec/lain/bench/speculative_spec.rb
spec/lain/bench/variance_fixture_spec.rb
spec/lain/bench/variance_spec.rb
spec/lain/capability/policy_spec.rb
spec/lain/compare_spec.rb
spec/lain/context/cache_breakpoints_spec.rb
spec/lain/context/compact_spec.rb
spec/lain/context/prune_spec.rb
spec/lain/context/recall_spec.rb
spec/lain/context/reminder_spec.rb
spec/lain/context_spec.rb
spec/lain/event_spec.rb
spec/lain/frontend/approval_policy_spec.rb
spec/lain/frontend/tty_spec.rb
spec/lain/grader/fixture_spec.rb
spec/lain/grader/rubric_spec.rb
spec/lain/handler/approving_spec.rb
spec/lain/handler/recorded_spec.rb
spec/lain/handler_spec.rb
spec/lain/journal_spec.rb
spec/lain/ledger_spec.rb
spec/lain/memory/bm25_spec.rb
spec/lain/memory/index_spec.rb
spec/lain/memory/item_spec.rb
spec/lain/memory/journal_memory_root_spec.rb
spec/lain/memory/manifest_spec.rb
spec/lain/memory/recorder_spec.rb
spec/lain/middleware/journal_requests_spec.rb
spec/lain/middleware/refuse_secret_writes_spec.rb
spec/lain/middleware_spec.rb
spec/lain/price_book_spec.rb
spec/lain/provider/anthropic_encoding_spec.rb
spec/lain/provider/anthropic_raw_spec.rb
spec/lain/provider/anthropic_spec.rb
spec/lain/provider/http/connection_logging_spec.rb
spec/lain/provider/http/error_handling_spec.rb
spec/lain/provider/http/error_middleware_spec.rb
spec/lain/provider/http/stream_accumulator_spec.rb
spec/lain/provider/http/streaming_spec.rb
spec/lain/provider/mock_spec.rb
spec/lain/repl_middleware_spec.rb
spec/lain/request_spec.rb
spec/lain/rust/speculative_spec.rb
spec/lain/rust/timeline_spec.rb
spec/lain/seams/accounting_seam_spec.rb
spec/lain/seams/memory_snapshot_seam_spec.rb
spec/lain/seams/tools_agent_spec.rb
spec/lain/timeline_spec.rb
spec/lain/tool/invocation_spec.rb
spec/lain/tools/bash_spec.rb
spec/lain/tools/edit_file_spec.rb
spec/lain/tools/list_files_spec.rb
spec/lain/tools/memory_read_spec.rb
spec/lain/tools/memory_write_spec.rb
spec/lain/tools/read_file_spec.rb
spec/lain/tools/todo_write_spec.rb
spec/support/mock_recording.rb
spec/support/shared_examples/provider_parity.rb
```

Note: `spec/lain/provider/http/*_spec.rb` (5 files above) are in this list on purpose — they
are Lain's own specs *of* the vendored code, not vendored themselves, so they converge.
</details>

<details>
<summary>scripts (2 files)</summary>

```
bin/regenerate-session-fixtures
exe/lain
```
</details>

**Excluded (vendored, untouched by this cop, 8 files — must remain outside `bundle exec
rubocop`'s zero-offense surface per the card's own acceptance criterion):**

```
lib/lain/provider/http/connection.rb
lib/lain/provider/http/error_middleware.rb
lib/lain/provider/http/message.rb
lib/lain/provider/http/stream_accumulator.rb
lib/lain/provider/http/providers/anthropic/chat.rb
lib/lain/provider/http/providers/anthropic/chat/response_parsing.rb
lib/lain/provider/http/providers/anthropic/chat/thinking_payload.rb
lib/lain/provider/http/providers/anthropic/tools.rb
```

---

## Part 2 — `rubocop-thread_safety`: BLOCKED-ON-DISCUSSION

### Escalation trigger fired

The card's trigger: *"rubocop-thread_safety flags more than ~10 sites — that's a design
conversation, not a lint sweep; stop at the inventory and mark the report
BLOCKED-ON-DISCUSSION."* It ran **18 offenses across 14 distinct lines in 9 files** (12
offenses / 7 files once the vendored `lib/lain/provider/http/**` dispositions are set aside by
existing policy) — over the threshold under every reasonable count. Per the trigger, this
section is the inventory plus my read of the shape of the problem, not a ship-ready
adopt/reject with a diff.

### Method

`rubocop-thread_safety` is not in the `Gemfile`/lockfile. Installed standalone —
`gem install --user-install rubocop-thread_safety` (0.7.3, into `~/.gem/ruby/4.0.0`, which the
default `GEM_PATH` for `ruby-4.0.5` already includes; no bundler/Gemfile/lockfile change was
made or needed) — and ran it outside Bundler (the project's shell has a `bundled_rubocop` alias
that forces `bundle exec`, which would have failed since the plugin isn't in the lockfile):

```bash
ruby -e '
  require "rubocop"
  require "rubocop-thread_safety"
  exit RuboCop::CLI.new.run(["--no-color", "--format", "simple", "lib/"])
'
```

This picks up the repo's `.rubocop.yml` (`TargetRubyVersion`, excludes, etc.) normally via
RuboCop's own config discovery; only the plugin's `require` is injected out-of-band. The gem
ships 5 cops via its `config/default.yml`: `ThreadSafety/ClassAndModuleAttributes`,
`ThreadSafety/ClassInstanceVariable`, `ThreadSafety/MutableClassInstanceVariable`,
`ThreadSafety/NewThread`, `ThreadSafety/DirChdir`, `ThreadSafety/RackMiddlewareInstanceVariable`
(the last is `Include`-scoped to `app|lib/middleware(s)/**`, which we don't have — never fires
here). Result: `122 files inspected, 18 offenses detected`, all from `ClassInstanceVariable`
(17) and `NewThread` (1). `ClassAndModuleAttributes`, `MutableClassInstanceVariable`, and
`DirChdir` found nothing.

### Confirmed: the deliberate designs the card named are untouched

Neither `lib/lain/channel/drop_oldest.rb` (`@mutex = Mutex.new` guarding a plain instance-level
buffer) nor `lib/lain/store.rb` / `lib/lain/journal.rb` (`@monitor = Monitor.new`) appear
anywhere in the 18 offenses. `ThreadSafety/ClassInstanceVariable` only looks at **class-level**
ivars (`class << self` / `def self.x` / `module_function` bodies) — regular per-instance ivars
under an explicit `Mutex`/`Monitor`, which is exactly what these two do, are a different shape
the cop doesn't model at all. The plugin does not fight that design; it has nothing to say
about it.

### Full inventory (every offense)

| File | Line(s) | Cop | What it is | Vendored? | Lean |
|---|---|---|---|:---:|---|
| `lib/lain/frontend/tty.rb` | 67 | `NewThread` | `Thread.new { render_until_closed }` in `TTY#run` — background drain thread for the alternate-screen renderer, documented at length in the surrounding comment | no | **keep** — this *is* the framework here; there is no Sidekiq to defer to. Candidate for a targeted inline disable with a one-line "why," not a tree-wide policy change |
| `lib/lain/price_book.rb` | 67 | `ClassInstanceVariable` | `def self.default; @default ||= new(prices: DEFAULTS); end` — memoized singleton, same shape as `Workspace.empty` | no | same disposition as `Workspace.empty` (T6 owns the fix) — bundle into whatever convention T6 settles |
| `lib/lain/usage.rb` | 24 | `ClassInstanceVariable` | `def self.zero; @zero ||= new(...); end` inside a `Data.define` block — memoized zero-value singleton | no | same shape/disposition as above |
| `lib/lain/workspace.rb` | 32 | `ClassInstanceVariable` | `def self.empty; @empty ||= new; end` — the exact site Joel's comment named | no | **this is the one the review comment is about** — T6 owns the fix; not this card's to resolve |
| `lib/lain/tool.rb` | 45–46 (4 hits) | `ClassInstanceVariable` | `class << self; def input_model(klass = nil); @input_model = klass unless klass.nil?; return @input_model if defined?(@input_model) && @input_model; ...; end; end` — inheritable per-subclass DSL registration (`Tool::Input` declaration), read/written only at class-definition time | no | **keep**, same idiom family as the two below — see "class-level DSL memoization" note |
| `lib/lain/tool/contracts.rb` | 60, 64 | `ClassInstanceVariable` | `def own_preconditions; @own_preconditions ||= []; end` / `own_postconditions` — per-class contract-list registries, populated by macro calls at load time | no | **keep**, same idiom |
| `lib/lain/tool/input.rb` | 59, 64 | `ClassInstanceVariable` | `def model_name; @model_name ||= ActiveModel::Name.new(...); end` / `def fields; @fields ||= superclass...; end` — per-class field/ActiveModel-name registries | no | **keep**, same idiom |
| `lib/lain/provider/http/configuration.rb` | 59, 60 | `ClassInstanceVariable` | `def option_keys = @option_keys ||= []` / `def defaults = @defaults ||= {}` — a small config-DSL mixin | **yes** | **exclude** — vendored, upstream shape |
| `lib/lain/provider/http/streaming.rb` | 50 (×2), 73 (×2) | `ClassInstanceVariable` | `module_function` methods referencing `@sink`/`@stream_debug` — module-level config shared across the SSE engine's helper methods | **yes** | **exclude** — vendored, upstream shape |

18 raw hits = 17 `ClassInstanceVariable` + 1 `NewThread`; 6 of the 17 sit in the two vendored
`provider/http/**` files and are already dispositioned by the existing vendoring policy, not by
this evaluation.

### Why this is a design conversation, not a lint sweep

Excluding the vendored 6, the remaining 12 offenses across 7 files are **two recurring,
deliberate idioms**, not 12 independent bugs:

1. **Class-level lazy-memoized DSL registries** (`Tool.input_model`, `Tool::Contracts#own_pre/postconditions`,
   `Tool::Input#model_name`/`#fields`) — `@ivar ||= ...` on a `class << self` method, populated
   by macro calls once at class-definition time and read thereafter. This is the same pattern
   Rails itself uses internally (`class_attribute`, memoized class readers) and is exactly what
   `ActiveSupport::Concern`-based DSLs look like. The plugin cannot distinguish "populated once
   at load time" from "populated per-request under concurrent load" — it flags the shape, not
   the actual hazard, because it can't see when the mutation happens.
2. **Class-level memoized singletons** (`Workspace.empty`, `PriceBook.default`, `Usage.zero`) —
   the exact `@x ||= new(...)` shape Joel's own comment called out. This is a **known,
   already-tracked** review item (T6 owns fixing `Workspace.empty`; `PriceBook.default` and
   `Usage.zero` are new findings this card surfaces, same shape, not yet on any card).

Adopting the plugin as configured today means either (a) `# rubocop:disable
ThreadSafety/ClassInstanceVariable` chaff at 7 sites for idiom #1, which just launders the
lint rather than fixing anything, or (b) actually redesigning class-level DSL memoization
(e.g. a `Concurrent::Map`-backed registry, or moving registration to a load-time `included`
hook that never re-runs after boot) — a real design decision about how much runtime safety
these DSL macros need, which is exactly what the escalation trigger is for.

### Recommendation

**Adopt/reject: deferred — do not wire the gem into `Gemfile`/`.rubocop.yml` from this card.**
My lean, for the discussion: **adopt**, scoped narrowly. The plugin correctly separates the
"deliberate, already-guarded" designs (DropOldest, Store/Journal Monitor — it says nothing
about them) from a genuine, repeated pattern (unguarded class-level lazy memoization) that
*is* worth a considered answer, even if the answer for the DSL-registry sites turns out to be
"these only ever mutate before the first tool call, add a comment and a targeted disable." The
`Workspace.empty` disposition (T6) and the `PriceBook.default`/`Usage.zero` siblings this card
surfaces should be decided together, as one convention, not three separate patches.

**If/when adopted**, wiring would look like (illustrative only — not for mechanical
application by this card):

```ruby
# Gemfile, group :development
gem "rubocop-thread_safety", "~> 0.7", require: false
```

```yaml
# .rubocop.yml, top of file
require:
  - rubocop-thread_safety
```

...plus per-site `Exclude`/disable decisions for whichever of the 12 non-vendored offenses the
design conversation keeps as-is, and an `Exclude` for `lib/lain/provider/http/**` matching
Part 1's vendored carve-out. None of this is applied here.

---

## Summary for the orchestrator

- **Part 1 is ready to merge**: apply the `.rubocop.yml` diff above, then `bundle exec rubocop
  -a` (536 offenses, all `Style/HashSyntax`, all `Safe: true`). Verified end-to-end (autocorrect
  + re-lint + full `rspec`) in an isolated scratch copy; not applied to this worktree.
- **Part 2 is BLOCKED-ON-DISCUSSION**: no Gemfile/`.rubocop.yml` change from this card. Full
  18-offense inventory above is ready to hand to whoever has that conversation. Flags two new
  `Workspace.empty`-shaped sites (`PriceBook.default`, `Usage.zero`) worth folding into T6's
  ruling rather than treating as a separate finding.
- `.rubocop.yml` in this worktree is unmodified (reverted via `git checkout -- .rubocop.yml`
  after every experiment); no other files were touched.
