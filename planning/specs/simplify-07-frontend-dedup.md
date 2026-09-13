# Simplify 07 — one row ring, one presenter, one rail, and one reader of the status file

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson; TJ DeVries joins for the Lua

## Intent

The editor frontend has three independent implementations of "keep the last N renderings, stamp each
with a generation, resolve a cursor line to its owner" — while the Lua side it talks to **already has
the generic primitive**, 35 lines that every view could share. It has two spellings of one inbox row,
one of which can disagree with the other about a question's age. It pays two mirror methods plus a
refusal constant for every new view. And six places independently read `state.json`, compare a
deadline, and draw a warm/cold marker, one of them a 77-line shell script with a `jq` dependency.

This plan gives each of those one owner. It does not touch the changeset-review surface — that is
simplify-14's scope, and the two would collide.

Delivers: one `Neovim::ListView`; one `InboxRow` presenter; a rail table replacing 24 mirror methods
and 13 mechanical Lua constants; a runtime loader that lets Lua name its own chunks; a protocol digest
replacing a hand-maintained integer and its 100-line changelog; one `StatusFeed::Reading` with the HUD
published pre-rendered; and one hard-wrap value the manifest currently forces to be written twice.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`. `code` is non-blank, non-comment.

**The framing correction first: there is one live frontend and no polymorphism seam.**
`frontend.rb:10-21` is a bare module requiring six things. `Frontend::TTY` is **always** constructed
(`cli/wiring.rb:125`); `Frontend::Neovim` is `nvim && Neovim.new(...)` (`cli/repl.rb:127`) and **nests
inside** the TTY run rather than replacing it. There is no `Frontend::Null`, no base class, no
`NotImplementedError`, no registry. `LineEditor`, `Theme`, `Completion`, `PromptComposer` and
`ApprovalPolicy` are TTY collaborators. So nothing here is polymorphism to collapse — the duplication
is between *views*, not between frontends.

Measured: `frontend/**/*.rb` is **2,791 code** against 5,423 comment+blank (1.94:1), with **24,657
spec lines (8.8:1)**. `runtime/*.lua` is 2,056 code / 3,819 comment+blank.

**Three generation-stamped row rings, and they differ in shape as well as in size:**

| | inbox | approval | review |
|---|---|---|---|
| ring | `Renderings` class, `Rendering = Data.define(:generation, :owners)` | `Rendering = Data.define(:lines, :owners, :calls, :call_index)`, **no wrapper class** | `Rendering = Data.define(:generation, :rows)` |
| file | `inbox_view/renderings.rb:28-35` (class `:16-91`) | `approval_view.rb:179-193` | `review_view.rb:226-232` |
| `HELD` | `renderings.rb:49` — **16** | `approval_view.rb:125` — **8** | `review_view.rb:174` — **16** |
| memory | `@held` Array, `#remember(owners:)` `:72-75` | `@renderings` **Hash keyed by generation**, `#posted` `:382-392` with `shift if size > HELD` | `@held` Array, `#remember(rows)` `:400-403` |
| resolve | `Rendering#at` `renderings.rb:34`; `#digest_at` `:86`; view-level `:214` | `Rendering#at` `:185-188` (`Integer(line, exception: false)`) | `Rendering#at` `:230`; `#resolve` `:348-354` |
| Null | `module Unwired` `inbox_view.rb:157-161` | `DETACHED` `:109` + `module Detached` `:130-134` | `module Unwired` `:266-275` |
| mutex | `@slot = Mutex.new` `:181`, every public method synchronized | **none** — poll-fiber-owned, `DEFAULT_POLL_INTERVAL = 0.05` `:119` | `@slot` `:284` |

Staleness sentences, for the same three failure modes, in three vocabularies:
`gestures.rb:39-56` has `UNSHOWN`, `NO_SET`, `RETIRED`, `UNREADABLE`, `ANSWERED`, `NOTHING_NEXT`,
`NEXT_UNREADABLE`; `approval_view.rb:211-214` has `UNSHOWN`, `NO_ROW`, `UNKNOWN`, `SETTLED`;
`review_view.rb:187-203` has `NO_STAMP`, `UNISSUED`, `UNSHOWN`, `NO_FILE`, `NO_HUNK`, `UNREAD` with a
three-way pick at `#refused` `:359-364`. **`UNSHOWN` is near-identical prose in all three.**

Sizes: inbox 873 code across four files (spec 1,795); approval 479 (spec 1,236); review 475
(spec 1,660).

**The Lua side already has the primitive.** `runtime/45_views.lua:23-35` — the whole file is 35 lines:

    function _G.__lain.set_view(name, lines, gen)
      local buf = named_buf(name)
      if gen ~= nil then vim.b[buf].lain_view_generation = gen end
      ... shared-prefix diff ...
      set_lines(buf, shared, -1, vim.list_slice(lines, shared + 1, #lines))
      announce_render(name, buf)
    end

Its header comment (`:13-22`) claims the stamp is optional and that *"lain://inbox is the only such
view today"* — **stale**: `approval_view.rb` and `review_view.rb` both stamp
`b:lain_view_generation` through their own rails (`SET_APPROVAL`, `SET_REVIEW`).

**The hard-wrap constants are written twice because the manifest forbids the reference.**
`approval_view.rb`: `WIDTH = 96` `:78`, `INDENT = "  "` `:83`, `ELISION = "..."` `:87`,
`BODY = /.{1,#{WIDTH - INDENT.length}}/m` `:105`; wrap at `#lines_for` `:429-434` and `#body_for`
`:443`. `inbox_view.rb`: the same four at `:81`, `:88`, `:93`, `:104`; wrap in `Row#lines` `row.rb:38-42`,
`#elided` `:129`, `#body` `:131`. And `inbox_view.rb:83-87` names the cause:

> Spelled here rather than read off `{ApprovalView::INDENT}` because `neovim.rb`'s manifest loads this
> file FIRST, so a constant reference would resolve before that class exists.

Encoded a **third** time as `runtime/05_records.lua:26`'s `CONTINUATION = "^  "`, consumed at
`:49-51`. So the centralized-requires rule is directly producing this duplication.

**Two spellings of one inbox row, and they can disagree.** `frontend/tty.rb`'s `Inbox` (`:502`):
`NAME_WIDTH = 19` `:513`, `#line_for` `:658-661`, `#summarized` `:675-677`, `#clamped` `:688`,
`#age_of` `:691-697`. `inbox_view/row.rb:93`'s `#drawn`. **`#age_of`'s arithmetic is byte-identical to
`inbox_view.rb:439-445`** — but the TTY copy is the only one that formats it, so the two surfaces can
render different ages for the same question. They also use **two different break vocabularies**:
`tty.rb:679`'s `#one_line` uses `BREAKS` (`:528`), `row.rb:127`'s `#prose` uses
`InboxView::NEWLINES` (`:64`).

The sender clamp `19` appears at `inbox_view.rb:70`, `tty.rb:513`, and `cli/wiring/askers.rb:23`
(applied at `:122`).

**Every new view costs two mirror methods and a refusal constant.** `rpc_thread.rb` is **419 code
lines** (1,190 raw) with `RenderQueue` at `:39-327` and `RenderInlet` at `:335-461`. Twelve
`post_*` methods (`:168`, `:186`, `:203`, `:215`, `:219`, `:223`, `:241`, `:248`, `:253`, `:255`,
`:259`, `:268`), each one line pushing a `Command` with a Lua constant. Twelve mirrors on the inlet
(`:386`, `:388`, `:405`, `:409`, `:413`, `:417`, `:423`, `:427`, `:431`, `:433`, `:438`, `:444`), each
`refusable(SOME_DETACHED) { @queue.post_X(...) }`. Two helpers: `#deliver` `:450-454`,
`#refusable` `:456-460`.

All **13 Lua constants** are mechanically the same shape — two examples:

    SET_VIEW   = "local name, lines, gen = ...; if _G.__lain then _G.__lain.set_view(name, lines, gen) end"
    SET_THREAD = "local anchor_id, lines = ...; if _G.__lain then _G.__lain.set_thread(anchor_id, lines) end"

**Keep `ReviewWrite` (`:499-732`) and `Router` (`:755-821`) where they are** — inbound wire
normalization and inbound dispatch are distinct responsibilities, and under simplify-01's raised limits
a 419-line object holding "the editor transport" is one responsibility.

**The runtime loader maps lines back to files by hand.** `runtime_loader.rb` is 182 lines.
`#locate` `:97-102` searches `#spans` `:130-138`, which does `join("\n")` offset arithmetic;
`#unplaceable` `:112-117` has a special case for the blank separator that its own comment
(`:106-111`) calls **unreachable from a real Lua error** — kept only because *"a debugging tool that
contradicts itself is one nobody trusts."* **Keep the `NN_name.lua` prefix validation** — `#ordered`
`:83-87`, `#prefix_of` `:160-168`, `#refuse_collisions` `:170-178` — that is load-order correctness,
and `#module_names` `:140-158`'s dot-skip has a recorded reason (an emacs `.#20_buffers.lua` dangling
symlink).

**`PROTOCOL` is a hand-maintained integer with a 100-line in-source changelog.**
`frontend/neovim.rb:125` is `PROTOCOL = "15"`, with the history at `:25-124` (bump rule `:25-34`,
entries for `"2"` through `"15"`). Its twin is `runtime.lua:70`'s `RUNTIME_PROTOCOL = "15"` with a
mismatch warning at `:71-73`. **Ruby and Lua ship in the same gem** — `runtime_loader.rb:34-37` reads
the Lua from `__dir__` — so they cannot be out of step across a release. The one real risk, a stale
runtime already injected into a live nvim, is handled better by the liveness check at
`rpc_thread.rb:1082-1088`, which raises `SocketOwned` (`:24-33`) when `exec_lua` reports another
lain's channel.

**Six readers of `state.json`, and only three of them agree on anything:**

1. `tty.rb`'s `Warmth` `:449-498` — `WARM = "●"` `:450`, `COLD = "○"` `:451`, `#prefix` `:467-472`,
   `#read_deadline` `:481-489`, `#read_state` `:491-495` (`JSON.parse(File.read)` rescuing
   `Errno::ENOENT, JSON::ParserError`), `#warm?` `:497`.
2. `cli/command/status.rb` (75 lines) — its own `WARM` `:23`, `COLD` `:24`, `#warmth` `:67-71`; reads
   the **in-process** `env.status.state` (`:44`), not the file. **Its own comment at `:16-21` documents
   the duplication.**
3. `cli/up/hud.rb` — `JQ_FILTER` `:65-73` (a 7-line jq program using 🔥/❄),
   `JQ_MISSING_WARNING` `:75-76`, `#jq_status_right` `:113-115`, `#fallback_status_right` `:119-121`.
4. `plugin/nvim/lua/lain/init.lua` — `M.state_path()` `:150-163` re-deriving
   `("%s/status/%s/state.json"):format(base, project_hash())`, `M.status()` `:206-224`. **No deadline
   comparison and no glyph** — it returns the decoded table.
5. `plugin/tmux/scripts/lain-status` — **77 lines**, with `JQ_FILTER` at `:65-71` **byte-for-byte
   identical to the Ruby one**, pinned against it by `spec/plugin/tmux_plugin_spec.rb` (681 lines) per
   `:40-41`.
6. `frontend/prompt_composer.rb`'s `RunState` `:308` — `#to_h` `:338-341`, `#occupancy` `:355-360`,
   `#fleet` `:362-365`, `#compaction` `:394-398`. Reads the **live feed object**, no deadline, no glyph.

What `StatusFeed` publishes (`status_feed.rb`, 524 code; spec 1,688): `#state = observed.merge(measures)`
`:465`; `#observed` `:486-493` gives `cache_deadline`, `fleet`, `inbox_count`, `approvals_pending`,
`occupancy`, `unmeasured_turns`, `compactions`, `derivation_refusal_streak`, `run_tokens`, merged with
`@mode.published` (which supplies `mode_lighter`, `posture`, `layers`); `#measures` `:499-502` gives
`elapsed`, `idle`, `since_compaction`. `#default_path = ProjectDir.new.state_path` `:513`.

**Where docs and code disagreed.** `45_views.lua:13-22` claims the inbox is the only stamped view —
false, two others stamp through their own rails. `command/status.rb:16-21` admits its duplication
rather than resolving it. Both are corrected by the cards that touch them.

**Out of scope, and why.** The changeset-review surface — `review_view.rb`, `changeset_diff.rb`,
`thread_view.rb`, `RpcThread::ReviewWrite` (`:499-732`), and eight Lua modules — belongs to
simplify-14. **T1 therefore excludes `review_view.rb`** and folds only the inbox and approval rings; if
14 is declined, T1 grows a third caller. Said in Open decisions.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lib/lain/frontend.rb`,
  `lib/lain/frontend/neovim.rb`'s require block (the **manifest whose order causes T7's duplication**),
  `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`.
- **T7's whole point is a load-order change in `frontend/neovim.rb`'s manifest.** Its new leaf must be
  required **before** both `approval_view` and `inbox_view`. That is a wiring diff, and its position is
  the deliverable — a card cannot place it.
- `plugin/tmux/scripts/lain-status` and `plugin/nvim/lua/lain/init.lua` are **shipped plugin files, not
  `lib/`**. They are task scope for T6, but note `spec/plugin/tmux_plugin_spec.rb` pins the shell
  script against the Ruby filter byte-for-byte.
- This plan assumes **simplify-01 has landed**: T1 and T3 both produce objects over the current
  `Metrics/ClassLength`, and T1 leaves one spec covering two former subjects, which the current
  spec-mirror rule forbids.
- **simplify-14 runs before this plan, or is declined before it.** 14 deletes seven of the rails T3
  tables and one of the three rings T1 folds, so running 07 first means restructuring code 14 then
  removes. 14's own Prerequisites state the same ordering from the other side. If 14 is declined, say
  so here and T1 gains `review_view.rb` as a third caller (see **Open decisions**).
- **T6 runs before simplify-04's T2, which deletes `lib/lain/cli/up/hud.rb` outright.** T6 removes the
  jq filter and `JQ_MISSING_WARNING` from that file first, so 04's fold carries ~30 fewer lines into
  `up.rb`. The other order loses T6's work or forces it to be redone against `up.rb`.

## Open decisions

- **T1 excludes `review_view.rb`.** simplify-14 may delete it entirely, and building a shared ring for
  a view about to be removed is waste. If 14 is declined, T1 gains a third caller and the `HELD`
  reconciliation grows from two values (16 and 8) to three.
- **Whether `HELD` becomes one number.** Inbox and review hold 16, approval holds 8. The card keeps
  **both** as per-view configuration rather than picking one, because nothing in the grounding explains
  why approval holds half as many and inventing a reason is worse than carrying a parameter.
- **Whether the `jq` dependency goes.** T6 publishes a pre-rendered `hud` string, which makes the jq
  filter and `JQ_MISSING_WARNING` unnecessary — but the tmux script still needs *something* to read the
  file. `cat` suffices if the field is pre-rendered; the card confirms that before deleting the jq path.

## Waves

Wave 1: T4, T5, T6, T7
Wave 2: T2 (←T6, T7), T3
Wave 3: T1 (←T2, T7)
Critical path: T7 → T2 → T1

**T2 is in wave 2 because it collides with two wave-1 cards on two files**: T2 and T6 both edit
`frontend/tty.rb`, and T2 and T7 both edit `frontend/neovim/inbox_view.rb`. T1 is last because the
shared ring wants the shared wrap value T7 establishes and the row rendering T2 leaves behind — doing
it first means writing the ring against two copies of `INDENT` and then rewriting it.

## Tasks

### T1 — One generation-stamped list view for the inbox and the approval queue   [wave 3] [risk: high]

**Depends on:** T2, T7
**Files:** create `lib/lain/frontend/neovim/list_view.rb`,
`spec/lain/frontend/neovim/list_view_spec.rb`; modify
`lib/lain/frontend/neovim/inbox_view.rb`, `inbox_view/renderings.rb`, `inbox_view/gestures.rb`,
`lib/lain/frontend/neovim/approval_view.rb`, `spec/lain/frontend/neovim/inbox_view_spec.rb`,
`spec/lain/frontend/neovim/approval_view_spec.rb`
**Reuse:** `inbox_view/renderings.rb` (95 code) is the most complete of the three and is the shape to
generalize; `runtime/45_views.lua:23-35`'s `set_view` is the Lua-side primitive both already reach
through their rails
**Shared-file wiring:** `require_relative "neovim/list_view"` in `lib/lain/frontend/neovim.rb`, after
T7's fold leaf and before `inbox_view` and `approval_view`
**Reachable from:** `InboxView` is constructed in `CLI::Wiring`'s view assembly and `ApprovalView` from
`CLI::Repl`'s approval surface; AC 4 drives a gesture through a view built the way the REPL builds one,
against a real editor

One object owning: a ring of the last N stamped renderings, line→row resolution, and one `Detached`
Null. Three staleness outcomes — **no stamp**, **stamp too old**, **line is not a row** — named once
instead of in three vocabularies.

Two shape differences to reconcile honestly:

- **The ring's backing differs.** Inbox and review keep an `@held` **Array**; approval keeps a
  **Hash keyed by generation** and `shift`s it (`approval_view.rb:382-392`). Pick one and say why; a
  Hash keyed by generation is the more honest structure if a gesture can name any recent generation.
- **Approval has no mutex** (poll-fiber-owned, `DEFAULT_POLL_INTERVAL = 0.05` at `:119`) while inbox
  synchronizes every public method on `@slot` (`:181`). **Do not silently give approval a lock or take
  inbox's away.** If the shared object needs one, approval's fiber-ownership claim must be re-argued;
  if it does not, inbox's mutex is either unnecessary or guarding something the shared object should
  not own.

**This is the card that makes gesture resolution unit-testable without an editor** — `#at(line, generation:)`
returning a row or a typed staleness is a pure function, and today the only coverage is through a real
`nvim`.

**Acceptance criteria**

```gherkin
Scenario: a gesture on a current rendering resolves to its row
  Given a view that rendered three rows at generation 7
  When a gesture arrives for line 2 at generation 7
  Then the second row is resolved

Scenario: a gesture carrying an old generation is refused as stale
  Given a view that has re-rendered since generation 7
  When a gesture arrives for line 2 at generation 7
  Then it is refused, saying the view re-rendered

Scenario: a gesture on a line that is not a row is refused
  Given a view that rendered three rows
  When a gesture arrives for line 9
  Then it is refused, saying no row is there

Scenario: answering a parked approval in a live editor still settles it
  Given a live editor and a parked approval rendered into it
  When the approve gesture is pressed on its row
  Then the approval settles

Scenario: only the last N renderings are remembered
  Given a view whose ring holds 8
  When it renders 10 times
  And a gesture arrives for the first of those
  Then it is refused as stale
```
→ spec files: `spec/lain/frontend/neovim/list_view_spec.rb` (AC 1-3, AC 5 — all pure, no editor),
`spec/lain/frontend/neovim_runtime_spec.rb` (AC 4, the `:nvim`-tagged end-to-end)

**Escalation triggers**
- **The mutex asymmetry is the real risk.** `approval_view.rb` has none by design and
  `inbox_view.rb:181` synchronizes everything. If the shared object cannot serve both without a lock,
  **stop** — silently locking the approval poll fiber could change its `0.05` cadence, and silently
  unlocking the inbox reintroduces whatever race `@slot` was added for. Find why each is as it is
  before choosing.
- `approval_view.rb`'s `Rendering` carries `calls` and `call_index` as well as `owners`; the inbox's
  carries only `owners`. If the shared ring needs a payload type parameter, that is fine — but if it
  needs to *know* about tool calls, the abstraction is wrong and the views are not the same thing.
- `spec/lain/frontend/neovim_runtime_spec.rb` pins the three-way stamp gesture end to end at `:300`
  (inbox) and `:337` (approval). Those are `:nvim`-tagged and spawn a real editor per example; they are
  the only coverage that the rail actually carries the generation. If either fails, the Ruby refactor
  broke the wire, not just the object.
- If `review_view.rb` turns out to share a *staleness string* with one of the two in scope, do not
  unify it — simplify-14 may delete it, and a shared constant would then need un-sharing.

### T2 — One inbox row, so two surfaces cannot disagree about an age   [wave 2] [risk: medium]

**Depends on:** T6, T7
**Files:** create `lib/lain/tools/ask_human/inbox_row.rb`,
`spec/lain/tools/ask_human/inbox_row_spec.rb`; modify `lib/lain/frontend/tty.rb`,
`lib/lain/frontend/neovim/inbox_view/row.rb`, `lib/lain/frontend/neovim/inbox_view.rb`,
`lib/lain/cli/wiring/askers.rb`
**Reuse:** `tty.rb:691-697`'s `#age_of` and `inbox_view.rb:439-445`'s are **byte-identical
arithmetic** — one of them is the implementation; the other goes
**Shared-file wiring:** a manifest line in `lib/lain.rb` (or in `tools/ask_human.rb`'s index) placed
before both frontends
**Reachable from:** `Askers` (`cli/wiring/askers.rb:122`) applies the clamp on the live path, and both
frontends render from it; AC 3 drives the TTY drain and AC 4 the editor view, from one question set

`Row = Data.define(:from, :age, :summary)` with one `#to_s`. Each frontend adds only what is genuinely
its own — colour for the TTY, wrapping for the editor.

**The defect this closes:** `#age_of` exists in both, but only the TTY copy is reached when the TTY
renders and only the editor's when the editor does, so the two surfaces can show different ages for
the same question. The clamp width `19` is written three times (`inbox_view.rb:70`, `tty.rb:513`,
`askers.rb:23`).

Also reconcile the **two break vocabularies**: `tty.rb:528`'s `BREAKS` and `inbox_view.rb:64`'s
`NEWLINES`. They are matching different character sets for the same job — pick one and say which is
correct for a question's prose.

**Acceptance criteria**

```gherkin
Scenario: one question renders the same age on both surfaces
  Given a question asked ninety seconds ago
  When it is rendered for the terminal and for the editor
  Then both name the same age

Scenario: a long sender name is clamped to one width
  Given a sender name of forty characters
  When the row is rendered
  Then the sender is nineteen characters

Scenario: the terminal drain lists a pending question
  Given one pending question
  When the terminal inbox is drained
  Then its sender, age and summary appear

Scenario: the editor view lists the same question
  Given the same pending question
  When the editor inbox is rendered
  Then its sender, age and summary appear

Scenario: a question whose text spans lines renders as one row
  Given a question whose text contains a line break
  When the row is rendered
  Then it occupies one line
```
→ spec files: `spec/lain/tools/ask_human/inbox_row_spec.rb` (AC 1, AC 2, AC 5),
`spec/lain/frontend/tty_spec.rb` (AC 3), `spec/lain/frontend/neovim/inbox_view_spec.rb` (AC 4)

**Escalation triggers**
- The two break vocabularies may not be interchangeable: `BREAKS` (`tty.rb:528`) includes `\v`, `\f`,
  U+0085, U+2028 and U+2029; `NEWLINES` (`inbox_view.rb:64`) is `/\R+/`. If a question's prose can
  contain one that only one of them matches, picking either changes what the other surface renders —
  report which characters differ before choosing.
- `askers.rb:23`'s `NAME_WIDTH` is applied at `:122`, i.e. the clamp happens **before** the row reaches
  either frontend in that path. If the shared row clamps again, a name is clamped twice; if it does
  not, the third spelling is load-bearing and the card must say which layer owns the clamp.
- `inbox_view/row.rb`'s `#drawn` calls `#lstrip` on its result. If the shared `#to_s` does not, the
  editor's leading space reappears — a one-character difference that a spec asserting exact lines will
  catch and a human reading a table will not.

### T3 — One rail table, and one Lua dispatch   [wave 2] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/frontend/neovim/rpc_thread.rb`,
`lib/lain/frontend/neovim/runtime/45_views.lua` (or a new runtime module for the dispatch), and the
Lua modules whose functions are dispatched; modify
`spec/lain/frontend/neovim/rpc_thread_spec.rb`, `spec/lain/frontend/neovim_runtime_spec.rb`
**Reuse:** `#deliver` (`:450-454`) and `#refusable` (`:456-460`) are the two real behaviours and stay;
everything above them is a table
**Shared-file wiring:** none
**Reachable from:** `RenderInlet` is what every view calls, constructed by `RpcThread`; AC 3 drives a
render through a real editor, which is the only thing that proves the dispatch reaches Lua

Two mechanical collapses:

1. **24 methods become one table plus one `#post`.** Twelve `post_*` on `RenderQueue`, each one line
   pushing a `Command` with a Lua constant; twelve mirrors on `RenderInlet`, each
   `refusable(CONST) { @queue.post_X(...) }`. A `RAILS` table of `{lua:, refusal:, blocking:}` keyed by
   rail name replaces both. Every new view then costs **one table row**, not two methods and a constant.
2. **13 Lua constants become one.** Each is
   `"local <params> = ...; if _G.__lain then _G.__lain.<fn>(<params>) end"`. One generic
   `__lain.dispatch(fn, args)` constant replaces the lot.

**Keep `ReviewWrite` (`:499-732`) and `Router` (`:755-821`)** — inbound normalization and inbound
dispatch are distinct responsibilities, and under simplify-01's limits a 419-code-line transport object
is one responsibility.

**Acceptance criteria**

```gherkin
Scenario: a render reaches the editor
  Given a live editor with the runtime injected
  When lines are posted to a named view
  Then the buffer holds those lines

Scenario: posting to a detached editor is refused, not raised
  Given a render inlet whose queue is closed
  When a view is posted
  Then a refusal naming the detached surface comes back

Scenario: every rail in the table reaches its Lua function
  Given a live editor with the runtime injected
  When each rail in the table is posted
  Then each corresponding lain function was called

Scenario: a blocking rail waits and a non-blocking one does not
  Given a rail declared blocking and one declared not
  When each is posted
  Then the blocking one returned after delivery
  And the other returned before it
```
→ spec files: `spec/lain/frontend/neovim/rpc_thread_spec.rb` (AC 2, AC 4),
`spec/lain/frontend/neovim_runtime_spec.rb` (AC 1, AC 3 — `:nvim`-tagged)

**Escalation triggers**
- **AC 3 is the card's real gate.** A table-driven dispatch that compiles but names a Lua function
  wrongly fails only against a real editor. Do not accept this card on `rpc_thread_spec.rb` alone.
- Two of the twelve inlet methods (`post_render` `:386`, `post_view` `:388`) use **blocking
  `deliver`** rather than `refusable`. That is a real distinction — a render the caller must know
  landed — and the table needs it as a field, not an exception.
- The 13 constants are strings sent to `exec_lua`. If a generic dispatch changes **argument arity or
  order** for any rail, the Lua side receives the wrong values silently. Verify each rail's parameter
  list against its Lua function signature, not against its Ruby caller.
- `SET_QUESTION`, `SET_REVIEW`, `OPEN_CHANGESET`, `SET_THREAD` and `REVIEW_*` belong to the review and
  question surfaces. If simplify-14 deletes some, the table shrinks — but **do not pre-emptively omit
  them**; a missing rail is a silent no-op.

### T4 — Let Lua name its own chunks   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/frontend/neovim/runtime_loader.rb`,
`spec/lain/frontend/neovim/runtime_loader_spec.rb`
**Reuse:** Lua's own `load(chunk, chunkname)` reports the real filename and line — that is the
mechanism replacing the offset arithmetic
**Shared-file wiring:** none
**Reachable from:** `RuntimeLoader#source` is read at `rpc_thread.rb:954` (`RUNTIME`) and injected at
`:1086`; AC 1 drives a deliberate Lua error through a real editor and reads the reported location

`#locate` (`:97-102`), `#spans` (`:130-138`) and `#unplaceable` (`:112-117`) exist only to map a line
in the synthetic concatenation back to a source file, using `join("\n")` offset arithmetic — and
`#unplaceable`'s blank-separator branch is **documented as unreachable from a real Lua error**
(`:106-111`). Emitting each module as `assert(load(body, "@<path>"))()` makes Lua report the real
filename and line itself.

**Keep the prefix validation.** `#ordered` `:83-87`, `#prefix_of` `:160-168`,
`#refuse_collisions` `:170-178` are load-order correctness, and `#module_names` `:140-158`'s dot-skip
has a recorded reason (an emacs dangling symlink).

**Acceptance criteria**

```gherkin
Scenario: a Lua error names the module it came from
  Given a runtime module containing a deliberate error
  When the runtime is injected into a live editor
  Then the reported location names that module's filename

Scenario: a module without a two-digit prefix is refused
  Given a runtime directory holding a file with no numeric prefix
  When the runtime source is built
  Then it is refused, saying the prefix is the load order

Scenario: two modules at one load position are refused
  Given two runtime files sharing a numeric prefix
  When the runtime source is built
  Then it is refused, naming both

Scenario: an empty runtime directory is refused
  Given a runtime directory with no Lua modules
  When the runtime source is built
  Then it is refused, saying the runtime would be the handshake alone
```
→ spec files: `spec/lain/frontend/neovim/runtime_loader_spec.rb` (AC 2-4),
`spec/lain/frontend/neovim_runtime_spec.rb` (AC 1 — needs a real editor to produce a real Lua error)

**Escalation triggers**
- `exec_lua` receives **one chunk**. If wrapping each module in `assert(load(...))()` changes the shared
  upvalue scope — so that a module can no longer see a local another declared — the runtime breaks in a
  way that only a real editor shows. `runtime.lua`'s handshake is the first chunk and the most likely
  casualty.
- `rpc_thread.rb:1086`'s `exec_lua(RUNTIME.source, [@version, @protocol, @client.channel_id])` passes
  three arguments to the chunk. Per-module `load` calls change how those varargs reach each module —
  confirm the handshake still receives them.
- `#unplaceable`'s messages are user-facing debugging output. If they go, so does the ability to say
  "line N is the blank separator"; that is the intended loss, but say so rather than discovering it
  during a debugging session.

### T5 — Replace the protocol integer with a digest of the runtime it guards   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/frontend/neovim.rb`,
`lib/lain/frontend/neovim/runtime.lua`, `lib/lain/frontend/neovim/rpc_thread.rb`;
modify `spec/lain/frontend/neovim_runtime_spec.rb`
**Reuse:** `RuntimeLoader#source` (`:62-68`) is already the exact bytes being injected — its digest is
the version, and it **cannot be forgotten on a change**. `Ext.blake3_hex` is the project's digest.
**Shared-file wiring:** none
**Reachable from:** the handshake at `rpc_thread.rb:1086` passes the protocol to the injected chunk;
AC 1 and AC 2 both drive a real editor

`neovim.rb:125` is `PROTOCOL = "15"` with a **100-line in-source changelog** at `:25-124`, guarding
compatibility between a Ruby side and a Lua side that **ship in the same gem** — `runtime_loader.rb:34-37`
reads the Lua from `__dir__`, so they cannot diverge across a release.

The one real risk it addresses is a **stale runtime already injected into a live nvim**, and that is
already handled by the liveness check at `rpc_thread.rb:1082-1088`, which raises `SocketOwned`
(`:24-33`) naming the other lain's channel.

Replace with a digest of `RuntimeLoader#source`. Move the changelog to git, where CLAUDE.md says the
archive belongs.

**Acceptance criteria**

```gherkin
Scenario: a matching runtime attaches
  Given a live editor with no lain attached
  When lain attaches
  Then the handshake succeeds

Scenario: a runtime injected by a different lain version is detected
  Given a live editor holding a runtime from a different source
  When lain attaches
  Then it refuses, saying the injected runtime differs

Scenario: a second lain attaching to one editor is still refused by channel
  Given a live editor already attached to a running lain
  When a second lain attaches
  Then it refuses, naming the other channel

Scenario: the version changes when the runtime changes
  Given the runtime source
  When one module's bytes change
  Then the computed version changes
```
→ spec files: `spec/lain/frontend/neovim_runtime_spec.rb` (AC 1-3 — the file already has a
`"protocol lockstep"` group at `:793` and a `"one lain per editor"` group at `:1021`),
`spec/lain/frontend/neovim/runtime_loader_spec.rb` (AC 4)

**Escalation triggers**
- `runtime.lua:70`'s `RUNTIME_PROTOCOL` is a **literal in the Lua**, compared against the Ruby value at
  `:71-73`. A digest cannot be a literal on both sides — the Lua must receive it as an argument, which
  changes the handshake's shape. If it cannot, stop: a digest the Lua cannot check is not a guard.
- `neovim_runtime_spec.rb:793`'s `"protocol lockstep"` group exists to catch exactly the drift this card
  changes the mechanism for. Read it before rewriting it; if it asserts the two **literals** match, its
  replacement must assert something stronger, not weaker.
- The 100-line changelog records **fifteen protocol bumps** and what each changed. That is real history.
  Move it to a doc or a commit message; deleting it outright loses the only account of how the editor
  surface evolved.

### T6 — One reader of the status file, and publish the HUD pre-rendered   [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/status_feed/reading.rb`, `spec/lain/status_feed/reading_spec.rb`;
modify `lib/lain/status_feed.rb`, `lib/lain/frontend/tty.rb`, `lib/lain/cli/command/status.rb`,
`lib/lain/cli/up/hud.rb`, `lib/lain/frontend/prompt_composer.rb`,
`plugin/tmux/scripts/lain-status`, `plugin/nvim/lua/lain/init.lua`;
modify `spec/plugin/tmux_plugin_spec.rb`
**Reuse:** `StatusFeed#observed` (`status_feed.rb:486-493`) already assembles every field — adding one
pre-rendered `hud` string is one line there, and it is the only place that knows all the values
**Shared-file wiring:** a manifest line for `status_feed/reading.rb` in `lib/lain/status_feed.rb`
**Reachable from:** `StatusFeed#publish_if_changed` (`:509-511`) writes the file on the live chat path;
AC 3 drives the tmux script against a file a real `StatusFeed` wrote

Two moves:

1. **One `StatusFeed::Reading`** for the three Ruby readers that parse the file and compare a deadline
   — `tty.rb`'s `Warmth` (`:449-498`), `cli/command/status.rb` (`:67-71`), and
   `prompt_composer.rb`'s `RunState` (`:308`). Note `command/status.rb` reads the **in-process** state
   (`:44`) rather than the file, and `RunState` reads the live feed object — so `Reading` must work over
   either a parsed Hash or the feed, and the card should say which.
2. **Publish `hud` pre-rendered.** `StatusFeed` gains one field holding the rendered status line. Then
   `up/hud.rb`'s 7-line `JQ_FILTER`, its `JQ_MISSING_WARNING`, the **byte-identical filter** in
   `plugin/tmux/scripts/lain-status:65-71`, and `plugin/nvim/lua/lain/init.lua`'s re-derivation of
   `state_path` all collapse to reading one field.

`command/status.rb:16-21` **documents its own duplication**; that comment becomes unnecessary.

**Acceptance criteria**

```gherkin
Scenario: a warm cache shows the warm marker
  Given a status file whose cache deadline is in the future
  When the reading is taken
  Then it reports warm

Scenario: a cold cache shows the cold marker
  Given a status file whose cache deadline has passed
  When the reading is taken
  Then it reports cold

Scenario: the multiplexer status line needs no filter program
  Given a status file written by a real status feed
  When the multiplexer status script runs
  Then it prints the published status line
  And it invoked no filter program

Scenario: an absent or unparseable status file reports nothing rather than raising
  Given no status file
  When the reading is taken
  Then it reports nothing
  And nothing is raised

Scenario: the editor plugin reads the published line rather than deriving it
  Given a status file holding a published status line
  When the editor plugin asks for status
  Then it returns that line
```
→ spec files: `spec/lain/status_feed/reading_spec.rb` (AC 1, AC 2, AC 4),
`spec/plugin/tmux_plugin_spec.rb` (AC 3), `spec/plugin/nvim_plugin_spec.rb` (AC 5)

**Escalation triggers**
- `spec/plugin/tmux_plugin_spec.rb` (681 lines) pins the shell script's filter against the Ruby one
  **byte-for-byte** (`:40-41`). Changing both is correct; changing one is a silent divergence the spec
  will catch — but if the spec pins the *filter* rather than the *output*, it needs rewriting to pin
  the output instead, and that is a scope change worth reporting.
- **simplify-04's T2 deletes this file.** If 04 has already landed, `hud.rb` is gone and `JQ_FILTER`
  now lives in `lib/lain/cli/up.rb` — do the same work at the new address and say so, rather than
  reporting the file missing.
- `up/hud.rb`'s tmux `status-right` is a **shell string tmux evaluates**. If the pre-rendered field
  contains a `#` or a `%`, tmux will interpret it. Confirm the rendered HUD is escaped for tmux, or a
  model name with a `#` in it breaks the status line.
- `plugin/nvim/lua/lain/init.lua:150-163` re-derives `state_path` from a project hash. simplify-06's T2
  makes `ProjectDir` the sole path authority — a Lua re-derivation is outside that guard's reach and
  will stay outside it. Say so; the honest fix is the plugin reading a path lain tells it, not
  computing one.
- `RunState` (`prompt_composer.rb:308`) reads `derivation_refusal_streak` and asks
  `Compaction::Source::Derived.stalled?`. That is a **derived judgment**, not a field read. If
  `Reading` absorbs it, it is no longer just a reader — keep that in `RunState` and say why.

### T7 — One hard-wrap value, loaded before both views that need it   [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/frontend/neovim/fold.rb`, `spec/lain/frontend/neovim/fold_spec.rb`;
modify `lib/lain/frontend/neovim/approval_view.rb`,
`lib/lain/frontend/neovim/inbox_view.rb`, `inbox_view/row.rb`
**Reuse:** `approval_view.rb:429-443`'s `#lines_for`/`#body_for` and `row.rb:129-131`'s
`#elided`/`#body` are the same two expressions — one of them is the implementation
**Shared-file wiring:** `require_relative "neovim/fold"` in `lib/lain/frontend/neovim.rb`, **before**
both `approval_view` and `inbox_view`. This position is the card's whole point.
**Reachable from:** both views render on the live editor path; AC 3 drives the editor's fold detection,
which is where the Ruby indent and the Lua pattern must agree

`WIDTH = 96`, `INDENT = "  "`, `ELISION = "..."` and `BODY` are declared **identically** at
`approval_view.rb:78-105` and `inbox_view.rb:81-104`, and `inbox_view.rb:83-87` names the reason:

> Spelled here rather than read off `{ApprovalView::INDENT}` because `neovim.rb`'s manifest loads this
> file FIRST, so a constant reference would resolve before that class exists.

**So the centralized-requires rule is producing this duplication**, and the fix is a leaf loaded before
both — which is exactly what CLAUDE.md's own requires rule prescribes ("add the new file to its unit's
index... where its dependencies place it"). Note the same indent is encoded a **third** time as
`runtime/05_records.lua:26`'s `CONTINUATION = "^  "`, consumed at `:49-51`; the Ruby and Lua must agree
and the card should say which is authoritative.

**Acceptance criteria**

```gherkin
Scenario: a long line is elided and its remainder indented
  Given a line longer than the fold width
  When it is folded
  Then the first line ends with the elision
  And each continuation line begins with the indent

Scenario: a short line is unchanged
  Given a line shorter than the fold width
  When it is folded
  Then it comes back as one line, unindented

Scenario: the editor folds a record the same way both views wrap it
  Given a live editor
  And a long row rendered into the approval view and into the inbox
  When each is folded by the editor
  Then both fold at the same place

Scenario: one width and one indent are declared once
  When the fold value's constants are read
  Then the width, indent and elision each have one definition
```
→ spec files: `spec/lain/frontend/neovim/fold_spec.rb` (AC 1, AC 2, AC 4),
`spec/lain/frontend/neovim_runtime_spec.rb` (AC 3 — the `"folds"` group already exists at `:2270`)

**Escalation triggers**
- The manifest position is the deliverable. If `frontend/neovim.rb`'s require order cannot place a leaf
  before both views — because one of them is required from somewhere else first — **stop and report the
  order**, because that is the load-order problem `inbox_view.rb:83-87` describes and it may be worse
  than one duplicated constant.
- `runtime/05_records.lua:26`'s `CONTINUATION = "^  "` must match `INDENT`. `inbox_view.rb:83-87` says
  the spec pins *"the two spellings and the lua pattern to each other"* — find that assertion and make
  it pin one Ruby spelling to the Lua, not two.
- `BODY = /.{1,#{WIDTH - INDENT.length}}/m` interpolates at definition time. If the shared value makes
  `WIDTH` configurable, the regex must be built per width rather than once — and a per-call regex build
  on a render path is a cost worth measuring.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded**. T1 and T2 move examples between
  files and T4 deletes some; write the arithmetic.
- `bundle exec rubocop` clean with no new `rubocop:disable`.
- **`bundle exec rspec --tag nvim`** — T1, T3, T4, T5 and T7 each change something that only a real
  editor exercises, and `spec/lain/frontend/neovim_runtime_spec.rb` (3,588 lines, 101 examples) spawns
  `nvim --headless` per example. A green run without this tag proves almost nothing about this plan.
- `bundle exec rspec spec/plugin/` — T6 changes both shipped plugins, and the tmux script is pinned
  against the Ruby filter byte-for-byte.
- **Manual, human:** a full `lain up` cockpit — open it, park an approval, answer it in the editor,
  drain the inbox in the terminal, and read the tmux status line. T1, T2, T3 and T6 all land on that
  one screen, and **a tmux pane inherits the spec runner's PATH** (CLAUDE.md:245-247), which has
  already hidden a status-127 failure for the life of a feature. The suite cannot see this.
- **Manual, human:** compare a question's rendered age in the terminal and in the editor inbox at the
  same moment. That is T2's headline defect and no spec asserts the two agree today.
- Update `planning/qa/scenarios/` — `cockpit-surfaces.md` covers exactly this screen, and T5 changes
  the protocol mechanism a scenario may name.

## Execution log

**Base ref:** `main` at `b2f75202`. Every worktree is cut from that HEAD by hand, never by
`isolation: "worktree"` (which forks from `origin/main`, 270 commits behind).

**Grounding staleness.** The Grounding section was verified at `d2bb133c`; `main` is 270 commits
ahead of it, almost all of them simplify-01/-02/-03 landings. Line citations in the cards are
therefore approximate. Each implementer re-verifies its own card's cited `file:line` claims before
writing anything and reports drift: absorbable if the behavior is unchanged, escalated if the card's
premise no longer holds.

**Prerequisites checked at start:** simplify-01 `done`, simplify-02 `done` — both required by this
plan. simplify-03 was `in-progress` with twelve of thirteen cards landed; its last card touches
`tools/subagent.rb`, `cli/wiring/toolset_build.rb`, `cli/wiring/askers.rb`,
`tools/request_review.rb` and `cli/epic_submit/adjudication.rb`, so no card touching those was
started until it landed.

**The simplify-14 ordering, unresolved at start.** The Orchestrator contract requires 14 to run
before this plan or be declined before it. 14 was not selected for this run, and the human was
away when the question arose. Rather than guess, T1 and T3 — the only two cards 14 touches — are
sequenced **last**, so every other card lands either way and the decision is deferred to the point
where it actually binds. T4, T5, T6, T7 and T2 are unaffected: 14 deletes `review_view.rb` and the
review rails, not the inbox, the approval queue, the status file or the runtime loader.

### A card premise that did not survive contact

**The chunk-naming card's mechanism is unachievable at this card's size, and the disproof is worth
keeping.** The card proposed replacing the loader's offset arithmetic with Lua's own
`load(chunk, chunkname)`, which reports a real filename and line. On the shipped 22-module runtime
that dies at the second module — `05_records.lua:82: table index is nil` — because the modules
deliberately share top-level Lua `local`s across files, a rule `runtime.lua`'s own header states,
and separate `load()` chunks cannot see each other's locals. `_ENV` joining does not reach them.
Two agents reproduced this independently.

Making the card's mechanism work therefore requires converting all 22 modules to communicate
through an explicit shared table, and only then naming the chunks. That is a real card and
probably a good one — it is the only route to Lua naming every error, at any time, with a full
traceback, and to deleting the arithmetic for good — but it is a 22-file Lua change and it is not
this one.

What landed instead wraps the module bodies in one `xpcall` that preserves the shared lexical
scope, and carries the same offset arithmetic into the runtime so the translation happens
automatically rather than on request. **The arithmetic did not go away; it changed address**, and
the plan should not pretend otherwise: the file grew from 182 to 234 lines, non-comment code from
78 to 102.

The panel's finding that forced a second round is worth recording separately, because it is the
kind a green suite cannot show. The first draft translated only **load-time** errors, which are
the rare shape — in a live cockpit nearly every runtime error is deferred through a command
callback, an autocmd or a rail, and `xpcall` has returned long before those run. It also deleted
the one tool that could decode a deferred line on request, and replaced a real traceback with the
error handler's own line number. For the common shape it was **worse than no change at all**: an
opaque location became a confident and wrong one.

### Findings escalated for their own cards

**Nothing in lain reports cache warmth live any more, and three files said otherwise.** Publishing
the HUD pre-rendered removed the jq filter that re-evaluated `now` on every 5-second tmux tick.
That filter was, it turns out, the only live warmth indicator in the product: the TTY prompt
composes its string once per input cycle and hands it to Reline, so its own marker is stamped at
the turn boundary and does not refresh while a human sits idle. The card's own comments, the
README and the shipped tmux script all claimed the prompt stayed live; all three were corrected.

The staleness is unbounded and always optimistic — a publish fires only when the observed state
changes, so an idle session keeps the 🔥 its last turn earned, and it is guaranteed wrong from 300
seconds after the last cache-touching turn. A reader concludes the cached prefix is still warm,
sends, and pays for a full uncached prefix. That is the decision the marker exists to inform.

It ships anyway, because keeping jq to preserve freshness reinstates the two-spellings-of-one-HUD
duplication this card exists to remove, and nothing is corrupted. **The fix is a periodic
republish, and it is its own card**: a write-and-rename every N seconds needs a timer `StatusFeed`
does not own and a rule for how that interacts with the `observed` change-token discipline.
Worth doing for a reason wider than this marker — `elapsed`, `idle` and `since_compaction` have
always had the same property, stamped at publish and never refreshed, so one periodic republish
corrects four fields at once.


### Close-out — six of seven, with T3 held for a decision

T2, T4, T5, T6, T7 and T1 landed. **T3 is not done, and it is not blocked on anything I can settle.**

**The simplify-14 question, deferred at the start and resolved only halfway.** 07's contract says 14
runs before this plan or is declined before it. 14 was not selected for this run and the human was
away, so rather than guess, the two affected cards were sequenced last and the decision deferred to
the point where it actually binds. It then bound differently for each:

- **T1 was safe either way.** The card is written to exclude `review_view.rb` — the file 14 would
  delete — so building the shared ring for exactly two callers is correct whichever way 14 goes. It
  gains a third caller only if 14 is declined, and that is additive. Landed as written.
- **T3 is not.** It tables the Lua rails, and 14 deletes **seven of them**. Running it now
  restructures code 14 removes. Held.

So T3 wants one answer: **is simplify-14 going to run?** If yes, run 14 first and re-ground T3
against what survives. If no, T3 runs as written and T1 gains `review_view.rb` as a third caller,
with the `HELD` reconciliation growing from two values to three.

**What T3 inherits either way**, found by T1's card and panel and left deliberately:
`runtime/45_views.lua:13-22` is stale in both its sentences — it claims `lain://inbox` is the only
stamped view and that every other view sends nothing, and `62_approval.lua:154` and
`46_sidebar.lua:82` both write `b:lain_view_generation` directly.

**One defect this plan found and did not fix, recorded above in full:** nothing in lain reports
cache warmth live any more. The jq filter T6 removed was the only surface re-evaluating a deadline,
and the terminal prompt composes once per input cycle rather than refreshing. The fix is a periodic
republish and it is its own card — worth doing for a reason wider than the marker, since `elapsed`,
`idle` and `since_compaction` have always had the same property.

**One correctness argument corrected rather than shipped.** T1's ring claimed lock-freedom on the
grounds that its holders are fibers of one reactor thread. There are three callers, not two, and
`#prime` runs on the drain thread with nothing ordering it against the watch fiber. The race is
pre-existing and was left; the sentence was not.


### The simplify-14 question, answered

**2026-09-13, by the human: 14 is unlikely to run, so T3 goes ahead as written.** The rails it tables
include the seven the review surface uses; if 14 is ever revived it will delete a table rather than
a scatter, which is the cheaper direction to discover.

The other half of the declined-14 path is **not** taken here and stays available: 07's T1 shipped
for two callers, and the plan says a decline lets it gain `review_view.rb` as a third, growing the
`HELD` reconciliation from two values to three. That is purely additive and was not asked for.


### Close-out — all seven landed

T3 ran after the human declined simplify-14 on 2026-09-13, and it closed the chunk.

**Three cards refused part of what they were asked, and every refusal was upheld on measurement.**
T3 kept the view rail a method (a sanitize column true for 2 of 13 and an arity column that is a
range for 1 is worse than the method), T1 built its ring for two callers rather than three, and T4's
prescribed mechanism turned out unavailable at this card's size.

**One refusal was upheld while its ARGUMENT was disproved, and that distinction is the chunk's most
useful lesson.** T3 kept the refusal sentences at their doors partly on the grounds that tabling
them would silently blind the width gate. The panel moved one in and **the gate reddened** — it
follows the keyword wherever it appears, not the call site. The outcome stands on manifest order
(three of ten views load after `rpc_thread.rb`, so naming them there raises at boot) and per-surface
naming. The bad reason was struck rather than left, because *"never put a sentence in a data table"*
is a false constraint that would deter a correct refactor later.

**The failure this chunk kept finding.** Four separate times, a change left the suite green while
removing the thing that was checking: a discipline scan that stopped seeing nine commands, a
deleted spec that was the only cover for a live `Agent` invariant, a `not_to include` over names
that no longer exist, and a live editor example that *created* whatever its table named. Green is
not evidence that nothing was lost, and on this chunk it was wrong about that four times.

**A packaging gap this chunk surfaced and did not close.** `lain.gemspec` builds `spec.files` from
`git ls-files`, while the runtime loader globs the directory — so an untracked runtime module passes
every spec, passes the hook (the pre-commit stash does not remove untracked files), and ships a
runtime whose `dispatch` does not exist. The `if _G.__lain` guard still passes and every render
becomes a silent no-op. One example comparing `git ls-files -C <runtime dir>` against
`RuntimeLoader#module_names` would close it. Its own card.
