# Survey notes — 2026-08-25 — `lib/lain/agent.rb`

The human's own notes from the paired `/survey` session, extracted **outside the journal** per
`survey-dogfood-2026-08-25.md` §1b.

**These were UNFILED when extracted.** `annotation_placed` count in the journal was **0** — nothing
had been through `:LainNoteDone`, so every note below existed only as a live extmark in nvim and a
crash would have taken all five. Recovered read-only from the runtime's `review_notes.by_buf` table
(reached through the `_G.__lain.review_notes_held` closure) rather than by driving the editor.

All five are on `lib/lain/agent.rb`, in placement order.

---

## N1 — `agent.rb:167` — bundle the constructor's collaborators?

> Should we be able to capture an arg here that is `Agent::Environment`? Should parts of
> `workspace` and `tool_runner` be bound together?

**Anchor:** `def initialize(toolset:, context:, instrumentation: Collaborators::OMITTED,` — the head
of a constructor taking **15 keywords plus `**instrumented`**.

**Checked.** The precedent already exists: `Agent::Collaborators` is exactly this kind of bundling
object, and `wire_callers` already funnels eight of the keywords through it. So N1 is not a new
idea so much as the question of where that bundling should stop.

**The tension worth knowing before deciding.** `.rubocop.yml:131-132` sets
`Metrics/ParameterLists: CountKeywordArgs: false`, and `CLAUDE.md` cites that as an example of
"config that encodes a *reasoned policy*". But the same file also says **"a tripped cop is usually
telling you an object is missing"**. Here the cop that would have said so was configured off. Both
positions are defensible; they are currently both in force, on the same constructor.

---

## N2 — `agent.rb:178` — why not a default argument?

> why isn't this a default value for the argument?

**Anchor:** `@timeline = timeline || Timeline.empty(store: Store.new)`

**Checked, and there is a concrete answer.** Ruby evaluates default arguments per call, so
`timeline: Timeline.empty(store: Store.new)` would allocate a fresh Store per call exactly as this
does. The two are equivalent **except** in what an explicit `timeline: nil` means: with a default
argument, an explicitly-passed `nil` wins and the Agent gets no timeline at all; with `||`, it gets
a fresh one.

**And explicit `nil` is a live call shape.** `cli/wiring/agent_build.rb:49` declares
`def build(..., timeline: nil, views: nil)` and passes it straight through, as do
`bench/arm_sweep/recordings.rb:82` and `frontend/neovim/buffers.rb:237`. So the `||` is load-bearing
for pass-through callers, and the change N2 asks about would be a behaviour change rather than a
tidy-up. Worth a comment at that line saying so — which is a *smaller* comment than most of what
E4 measures.

---

## N3 — `agent.rb:167` — ActiveModel attributes instead of OMITTED sentinels?

> Why aren't we using ActiveModel here for this given we can set default values with
> `attribute :model_caller, default: Collaborators::OMITTED` and similar

**Checked, both directions.**

- **For:** `CLAUDE.md` says "ActiveSupport is welcome where it earns its place", and the codebase
  already does this exact thing — `Tool::Input` is ActiveModel precisely so "one declaration yields
  both the JSON Schema the model sees and the local validation, so they cannot drift". The
  declaration-with-defaults shape N3 describes is already idiomatic here.
- **Against:** `Tool::Input` models *data crossing a wire*; `Agent` is a live object graph of
  injected collaborators. And `CLAUDE.md`'s stated test for an ActiveSupport import is whether it
  **preserves loud failure** — `StringInquirer` was rejected because `method_missing` makes `.setled?`
  return `false` in silence. Whether `ActiveModel::Attributes`' coercion passes that test on
  collaborator objects (as opposed to typed scalars) is the question to answer first.

---

## N4 — `agent.rb:357` — `delegate` instead of three assignments?

> These could all be just `delegate` definitions instead?

**Anchor:** `@accounting = resolved.accounting`, last of `@model_caller` / `@tool_runner` /
`@accounting` in `wire_callers`.

**Checked.** `resolved` is a method-local and is **not retained**, so delegation is not a drop-in:
it would mean keeping `@resolved` and delegating three readers to it — trading three ivars for one
ivar plus three delegations. Since `Collaborators` is resolved eagerly and not mutated afterwards,
there is no behavioural difference, so this is a genuine style/simplification call rather than a
correctness one. The eager resolution is deliberate and documented (`agent.rb:344-345`: "Both
resolve eagerly, so a wiring mistake raises HERE and not on the first turn"), and delegation would
preserve that as long as `Collaborators.new` still runs in `wire_callers`.

---

## N5 — `agent.rb:461` — guard the `__send__` against method collision — **ALREADY CLOSED**

> should we have some safety here on this to make sure it is a transition method as defined by
> LoopMachine versus other methods that may end up colliding by accident

**Anchor:** `__send__(:"#{response.stop_reason}!")`

**This was the right thing to worry about.** `__send__` reaches **private** methods, so a
`stop_reason` of `exit` would become `Kernel#exit!` and kill the process with no `at_exit` — and
`CLAUDE.md` records that a `SystemExit` "truncates the run and still reports '0 failures'". A raw
wire value reaching that send would be a genuinely nasty failure.

**It cannot reach it.** Verified rather than taken from the comment: `Response` normalizes at
construction — `response.rb:54`, `stop_reason: StopReason.normalize(stop_reason)` — closing the
provider's open enum to `StopReason::ALL` (`response.rb:30`, `KNOWN + [UNKNOWN]`), and `LoopMachine`
declares one event per member. So `"exit"` from a provider becomes `:unknown` and fires
`unknown!`, which fails to `:failed`. `spec/lain/agent_spec.rb:325` pins exactly this with
`stop_reason: "something_new_in_2027"`.

**So the safety N5 asks for exists — one layer up, at the boundary rather than the send site.**
The residual question is only whether that is discoverable *here*: the guarantee lives in
`response.rb` and the reader at `agent.rb:461` learns it from a comment. Nothing enforces the
coupling mechanically at this line.

---

## N6 — `cli/watch.rb:41` — ActiveModel with validators, here and across CLI?

> This could be an ActiveModel class and have validators on it? Possibly other classes within CLI
> as well?

**Anchor:** `def initialize(selector:, sink:, path: nil, paths: Paths.new, view: View.new,` — seven
keywords, followed immediately by a hand-rolled guard:

```ruby
raise EmptySelector, "selector must be a spawn-digest prefix, got #{selector.inspect}" if selector.to_s.empty?
```

**Checked.** That guard is exactly what a validator expresses declaratively, and the note's "possibly
other classes" instinct is right: **81 hand-rolled raise-on-bad-argument guards** across `lib/`, a
dense cluster in `cli/` (`watch.rb:43,122`, `backend.rb:578`, `epic_land.rb:279,323`, `review.rb:246`,
`epic.rb:261`, `epic_queue.rb:119`, …). Each names its own error class, which is a real virtue the
guards have and a generic validator would have to preserve.

**Same open question as N3, one layer out** — and the same `CLAUDE.md` test applies: an ActiveSupport
import is judged on whether it **preserves loud failure**. These guards are loud and specifically
named today; `Tool::Input`'s precedent is the argument for, and the risk is trading named refusals for
a generic validation-error bag.

---

## N7 — `response/tool_use.rb:41` — `block` is an overloaded name, and the YARD is missing

> `block` here makes me think of a ruby block and that is confusing. Also, we are lacking yard
> documentation here that describes what type we do expect here...

**Anchor:** `def self.wrap(block)`

**On the name — there is a defence, and it is partial.** `block` is the *wire* vocabulary: an
Anthropic **content block**, `{"type" => "tool_use", "id" =>, "name" =>, "input" =>}`. The class
docstring opens "A read-only view over ONE tool_use block", and the method's own refusal says "a
tool_use lens wraps a Hash **block**". So it is the domain term, used consistently. The note's point
still stands: in Ruby, `block` is one of the most overloaded words there is, and a reader meeting
`def self.wrap(block)` cold cannot tell a content block from a `&block` without reading upward.

**On the missing YARD — confirmed, and this one is sharp.** `.wrap` carries **~14 lines of prose and
zero tags**. No `@param`, no `@return`, no `@raise`. Yet its contract is entirely tag-shaped and is
genuinely non-obvious:

- `@param block [Hash, ToolUse]` — it accepts *either*, and is idempotent on the second
- `@return [ToolUse]`
- `@raise [ArgumentError]` on anything else

**This note independently confirms E4's central split.** E4 measured comments at 90% prose / 10%
YARD; `wrap` is that ratio at its extreme — abundant reasoning about *why* the door is narrow, and
nothing at all stating *what it takes*. The human's own reading found the gap the measurement
predicted, which is about as good a corroboration as either gets.

---

## N8 — `response/tool_use.rb:63` — why not `delegate :to_json, :fetch, to: :@hash`?

> is there a reason we cannot do a `delegate :to_json, :fetch, to: :@hash` here instead of defining
> the functions ourselves?

**Anchor:** `def to_json(...) = @hash.to_json(...)`, with `def fetch(...) = @hash.fetch(...)` below.

**Checked, and the answer is: no reason — the idiom is already in the tree, including this exact
form.** `delegate` is used at `workspace.rb:49`, `channel.rb:148`, `capability/degraded_set.rb:34`,
`cli/switchboard.rb:361` (which delegates a list *including* `fetch`), and — the direct precedent —
**`agent.rb:68`: `delegate :usage, to: :@accounting`**, delegation to an instance variable, exactly
what N8 proposes.

**The one real cost, and it is small.** `tool_use.rb` currently requires only `json`. `delegate`
needs `active_support/core_ext/module/delegation`, which per the house requires rule would be a new
external require in this leaf file — the same line `workspace.rb:3` already carries. Watch
`CLAUDE.md`'s trap that `require "active_support/core_ext"` raises unless `require "active_support"`
precedes it; the specific-path form used elsewhere in tree avoids it.

**What must not be lost:** the comment above `to_json` is load-bearing — "Delegated, never inherited:
without this a lens serializes as the `to_s` of its own object header — VALID JSON carrying a debug
string, which the NDJSON Journal accepts in silence where a raise would be caught." That reasoning
belongs above the `delegate` line if the change is made; it is the rare comment E4 would defend
without hesitation.

---

## N9 — `shell/parse.rb:92` — a Rust parser for the shell? — **ALREADY IS ONE**

> Could we use a rust based parser that might be more efficient in memory usage?

**This is already implemented, and `Shell::Parse` is not the parser.** It drives
`Structural::Matcher`, whose docstring calls itself "the single Ruby seam over `Lain::Ext::AstGrep`
(T1): no other unit may…" — and `Ext::AstGrep` is a **compiled in-process Rust binding**,
`ext/lain/src/astgrep.rs`, built on `ast-grep-core = "=0.44.1"` and `ast-grep-language` (which
supplies ~26 bundled **tree-sitter** grammars). The bash grammar is tree-sitter-bash; `parse.rb`
even reasons about an upstream grammar bug by number (`tree-sitter-bash#315`).

**So the Ruby that remains is the INTERPRETATION layer, and it is where it belongs.** `parse.rb`
decides what counts as coverage, what is a stage, which spans tile their children, whether a
redirection is a term — judgement over a parse tree Rust already produced. `CLAUDE.md`'s placement
rule wants exactly that split, and `parse.rb`'s own comment makes the same argument in the security
register: a "suspicious leading word" heuristic here "would be precisely the comforting lie
`Tool::Input` argues against".

**Nothing to do — but the note is evidence for E4.** A reader looking straight at `class Parse`,
inside 362 lines that are mostly prose, could not tell that the parsing is already in Rust. The
information exists (`AstGrep` is named at `parse.rb`'s call sites) but not where the eye lands.

---

## N10 — `skill/invocation.rb:69` — a Rust parser for skill invocation? — **fails the admission test**

> Can we make some of the parsing/finding of the skill itself as a rust parser that may work more
> efficiently and use less memory?

**Anchor:** `INLINE = %r{\A/(?<skill>#{IDENTIFIER})(?:\s+(?<args>.*))?\z}m`

**Checked against `docs/rust-bindings.md`'s five tests**, which must *all* hold:

| test | verdict |
|---|---|
| 1. pure, synchronous work — "a data structure, **a parser**, a matcher" | **passes** |
| 2. Ruby's object model makes it **asymptotically** worse | **FAILS** — one regex over one short line; Ruby's engine is already C, and there is no complexity gap to argue from |
| 3. hot **per-turn**, not per-session | **FAILS** — it runs once per *human input line*, which is rarer than per turn |
| 4. boundary crossed in **batches**, not per element | fails in spirit — one tiny string per call, so FFI conversion dominates any gain |
| 5. survives the same tests, Ruby version kept | would be satisfiable |

**The motivation is the exact one the doc rejects**, and it says so twice: "Rust is here for its data
model and for capabilities Ruby has no good answer to, **not for speed**", and "'Rust is faster' is
not [the argument]" — "a benchmark is how we *check* the reason, never the reason itself".

So N10 is a **keep-it-in-Ruby** by the project's own admission test. Recorded because the *asking*
is worth keeping: N9 and N10 look like one idea and are not — one was already done for a reason that
passes, the other fails on tests 2 and 3.

---

## N11 — `supervisor/restart.rb:148` — rescue then re-raise the same error

> We capture the a corrupt error and then proceed to raise the same error all over again and I do
> not know if this is helping us too much specifically

**Anchor:**

```ruby
rescue Bench::Session::Corrupt, Store::MissingObject => e
  raise Bench::Session::Corrupt, "cannot restart #{role.inspect} from its session record: #{e.message}"
```

**It is doing two real things, and one of them is not "the same error".**

1. **Class normalisation.** `Store::MissingObject` becomes `Bench::Session::Corrupt`, so callers take
   one door. The comment above says exactly that: "Both land as `Bench::Session::Corrupt`, which
   `#call` already documents as its raise and the other two doors already take."
2. **Context.** It names the *role* being restarted, which the inner error cannot know.

**But the note's suspicion survives in its sharpest form.** For the `Bench::Session::Corrupt` arm the
class really is identical on both sides, so that arm is **message enrichment only** — and the comment
concedes the other arm may be dead: "The MissingObject arm is **defensive now that both folds
shape-check the causal edge**." If `MissingObject` is genuinely unreachable, the whole rescue reduces
to prefixing a role name, which is the thing the note is questioning.

**What would settle it:** whether `Store::MissingObject` can still reach this rescue. If it cannot,
the normalisation argument is retired and only the role prefix justifies the block; if it can, the
rescue is load-bearing and only the naming reads oddly.

**One thing NOT wrong with it:** re-raising inside a `rescue` preserves the original as `cause`
automatically, so the inner error is not lost — only the backtrace origin moves.

---

## Cross-cutting

**Eleven notes, and they cluster.** Six are about **object assembly** — N1, N2, N3, N4 on
`Agent#initialize`/`wire_callers`, N6 on `Watch#initialize`, N8 on how a lens forwards. Two ask for
**Rust parsers** (N9, N10) and split cleanly: one was already done, the other fails the admission
test. Three are one-offs: N5 (`__send__` safety, already closed), N7 (naming + missing YARD), N11
(a rescue that may have outlived its reason).

**Three of the eleven resolved to "already handled"** — N5, N9, and arguably half of N11. That is
not wasted reading: in each case the guarantee exists somewhere the reader could not see it from
where they were standing, which is E4's thesis arriving from the other direction.

---

# Do these generalize?

Each note re-asked as "is this one site or a pattern?", measured across `lib/`.

## N1 / N3 — **generalizes strongly.** 58 constructors take ≥8 keyword arguments

| kw | site |
|---:|---|
| 26 | `lib/lain/agent.rb:167` |
| 23 | `lib/lain/cli/repl.rb:40` |
| 18 | `lib/lain/frontend/neovim.rb:214` |
| 17 | `lib/lain/frontend/tty.rb:89` |
| 16 | `lib/lain/tools/subagent.rb:524`, `cli/up.rb:675`, `cli/epic_land.rb:186`, `cli/command/surface.rb:59` |
| 15 | `provider/ollama.rb:278`, `cli/wiring/toolset_build.rb:305`, `cli/chat_launch.rb:63`, `agent/instrumentation.rb:44` |

`agent.rb` is the extreme, not an outlier — this is the house shape for an assembly object. Any
answer to N1 or N3 is therefore a **codebase-wide** decision, not a refactor of one constructor, and
that raises the stakes on the `Metrics/ParameterLists: CountKeywordArgs: false` policy: the cop is
off everywhere, so 58 sites grew without it ever objecting.

## N2 — **generalizes strongly, and reframes the note.** 38 sites, 29 with a `nil`-defaulted param

`@x = arg || Default` appears **38 times** in `lib/`, and in **29** of them the parameter is
declared `<name>: nil` in the same file. Examples: `tool.rb:304`, `embedder/ollama.rb:87-88`,
`provider/bedrock.rb:80-81`, `provider/ollama.rb:287-289`, `provider/anthropic.rb:99`,
`provider/http/provider.rb:71`.

So this is not an oddity at `agent.rb:178` — it is the project's **standard inject-or-build idiom**,
applied consistently: *"take the collaborator if you were given one, otherwise build the real one,
and let an explicit `nil` still mean 'build it'."* That is precisely what a default argument cannot
express, and it is what makes the pass-through callers in N2 work. The note's question has a
house-wide answer; what is missing is that the answer is written down nowhere — not in `CLAUDE.md`'s
style section, which covers Null Object and injection but not this shape.

## N4 — **does NOT generalize.** Exactly one site in the tree

A scan for runs of ≥3 mirror-name assignments from one receiver (`@x = obj.x`) finds **one**:
`agent.rb:355-357`, the very lines the note is on. So N4 is a genuine local tidy-up with no wider
pattern behind it — which also means it is the cheapest of the five to act on and the least
consequential to skip.

## N5 — **generalizes to exactly one sibling, and it is safe for the same reason**

Dynamic sends with an interpolated method name exist at **two** sites in `lib/`:

1. `agent.rb:461` — `__send__(:"#{response.stop_reason}!")`, closed by `StopReason.normalize` at
   `Response` construction.
2. `provider/http/configuration.rb:153` — `public_send("#{key}=", value)`, where `key` iterates
   `self.class.send(:defaults)`, a registry populated only by the `option :name, default`
   declarations in that same class. The vocabulary is closed by the DSL, so no external value can
   reach the send.

**The pattern is consistent and the discipline is real: close the vocabulary at the boundary, not at
the send.** Worth noting as a generalization because it is a *good* pattern applied twice — and
because in both cases the guarantee lives in another file and is conveyed to the reader only by a
comment. If that coupling is ever wanted mechanically, there are exactly two sites to change.

---

## What the generalization pass says overall

Three of the five notes are about **assembly** — how objects get their collaborators — and two of
those (N1/N3, N2) are house-wide patterns rather than local choices. The one note about the **loop**
(N5) resolved to "already correct, twice". The reader's attention snagging on constructors, in a
codebase where 58 of them take 8+ keywords, is the signal worth keeping.
