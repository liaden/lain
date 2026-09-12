# Chunk: round-11 survey surfaces — what a survey IS, and who may park

status: done
commit-mode: orchestrator-commits
language: ruby (with real Lua in the nvim runtime)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson, TJ DeVries (Neovim seat, added for this chunk)

## Intent

Discharges [`../qa-findings-round11-2026-08-25.md`](../qa-findings-round11-2026-08-25.md) — the
first end-to-end drive of `planning/qa/scenarios/survey.md`, and the drive that finally reached the
docent thread pane owed since round 7.

Three of the seven findings are the same shape at three depths: **an object is asked a question its
vocabulary cannot answer, so a caller guesses.** A `Role`'s `only:` list cannot say "this arm must
never park", so `ChildBuilder` hands the docent an `ask_human` and the thread pane hangs forever
(F64). A `Source` cannot say "I have no old side", so the editor builds a third window for a buffer
that is structurally guaranteed empty (F65). An `Outbox` cannot say "the round I hold has been
judged", so a settled survey locks a chat out of `/review` for the rest of its life (F67). This
chunk gives each of those three objects the word it was missing; the remaining cards are refusal
quality and one path-rendering asymmetry.

It is scheduled **before** `planning/survey-dogfood-2026-08-25.md`, which says in its own words:
*"Run it before this session, agent-driven, on the LOCAL arm — `/manual-qa survey`. … Fix what it
finds, then pair."* That pairing session drives a survey of lain's real `lib/` on the metered cloud
arm, so every card here is on the path a human is about to walk.

**Ruling carried in from the round (2026-08-25, from the human):** `/survey` opening the **raw
file** is CORRECT and is not a defect. A survey is a survey of the *state* of a project; `/review`
is diff-oriented. F65 is therefore **not** "the surface leaks bytes" — it is that the survey borrows
a two-sided diff layout it has no use for, wasting a whole window, and that `Projection`'s docstring
overclaims in a way that made a QA driver read the correct behaviour as a leak. Both halves are
fixed here; neither is fixed by masking the file.

## Grounding

Verified 2026-08-25 by five parallel code explorations plus the QA round itself. Every claim below
was read in the code, not inferred from docs.

**The layout is not source-aware anywhere, on either side.**
- `SLOTS = { "sidebar", "old", "new" }` — `runtime/41_layout.lua:51`. Fixed at three, and
  load-bearing beyond layout: `index_of` drives `anchor`'s left/right decision (`:56-63`, `:123-138`)
  and `review_place` refuses unknown slots by name (`:244-247`).
- `review_panes.ensure` opens every missing slot unconditionally (`41_layout.lua:193-199`). **Its
  only input is slot order** — no source, no changeset, no flag.
- Every `Corpus` file is built `old_path: nil` (`review/source/corpus.rb:416-420`, `#lazy`; the
  `:451-455` range is `rendered_bound`'s doc — corrected after panel review), and
  `Changeset#old_side` returns `[]` for those (`review/changeset.rb:124-129`). So the OLD window,
  its buffer, its `diffthis` and its fold computation all happen for a side that **cannot** hold
  anything. `spec/lain/frontend/neovim/changeset_diff_spec.rb:323` pins that empty post today.
- **`#diff_origin` is NOT the port to reuse.** `Corpus#diff_origin` (`corpus.rb:389`) and
  `LocalBranch#diff_origin` (`local_branch.rb:136`) both answer `DiffOrigin.already_local` — byte
  identical. It means "did anything fall back", and its one consumer renders a text note
  (`cli/review.rb:200`).
- `source` **never crosses the wire.** The constant block at `rpc_thread.rb:85-116` holds
  `set_review(lines, generation)`, `review_focus` (no args), `open_changeset(path, old_lines, line,
  revisions)` and `set_thread(anchor_id, lines)`. The only per-source datum already in the editor is
  the leaked constant `revisions["old"] == "corpus-as-it-stands-v1"`.
- **That is NOT the rail set the pinned lists hold, and a card working from it would update the wrong
  thing** (panel, SHOULD-FIX-11). `spec/lain/review/surface/neovim_spec.rb:255` pins
  `%i[set_review open_changeset set_thread review_refused]`; `spec/lain/frontend/neovim_runtime_spec.rb:796-798`
  pins `set_review open_changeset set_thread`. **`review_focus` is in neither; `review_refused` is in
  the constant block's four but not in this plan's original list.** T4 works from the pinned lists.
- **`review_panes.ensure()` runs at `set_review` time, before any `<CR>`** — its first caller in a
  survey is the sidebar render (`46_sidebar.lua:88` → `review_place("sidebar", buf)`). So the wasted
  OLD window exists from **first paint**, and a fact delivered only on `open_changeset` arrives too
  late to prevent it. This is why T4 puts `sides` on **`set_review`** (panel, BLOCKER-2).
- **The docent thread pane IS the `old` slot on a survey.** `OPPOSITE = { old = "new", new = "old" }`
  (`51_thread.lua:130`); `:LainThread` computes `OPPOSITE[b:lain_review_side]` and places through
  `review_thread.window(slot, ...)` → `_G.__lain.review_place(slot, ...)` (`51_thread.lua:452-458`).
  `set_thread`'s validator says it outright: *"the thread shows in the OPPOSITE pane, and there is no
  opposite of a third side"* (`:166-168`), and `thread_view_spec.rb:1334-1335` asserts the thread
  lands in `slots["old"]`. **A one-sided round that removed `old` from the slot VOCABULARY would make
  `review_place` refuse by name (`41_layout.lua:244-247`) — an `error()` inside a `define`d command,
  i.e. round 7's F31 traceback-and-modal shape, on the surface this chunk exists to fix.** T11 is
  built around this (panel, BLOCKER-3). `review_thread.rediff()` also hard-codes
  `{ "old", "new" }` (`51_thread.lua:470`).
- **`ChangesetDiff#drawn` holds a `Changeset`, not a `Source`** (`changeset_diff.rb:163`), and
  `Changeset` keeps `@source` private deliberately — *"The question goes to `@source` and the source
  stays private"* (`changeset.rb:188`). `#supports?` (`changeset.rb:196`) is the existing delegator
  precedent and the exact shape `#sides` needs (panel, BLOCKER-1).
- **`Delivery` already settles on every reachable exit.** `#answer` (`docent.rb:586-593`) has three —
  `refuse(SAID_NOTHING)`, `refuse(words)`, `record(words)` — and `#call` (`:549-556`) adds
  `rescue StandardError, ScriptError => refuse` and `ensure => abandon`. **So "the delivery finishes
  without recording one" cannot happen.** The real gap is that `#abandon` (`:619-627`) settles in
  memory and on the record but **deliberately does not render** (`:620-621`), so a `/stop` mid-flight
  leaves `PENDING` on a screen the human is still looking at — **but that too already settles in
  memory, on the record and on replay** (`docent.rb:622-627`, `:338-342`, `:720`, pinned at
  `docent_spec.rb:824`), so the only unfixed sliver is the pixels at the instant of the stop, with no
  fiber left to redraw them. **T2 is WITHDRAWN** (panel, BLOCKER-6 then BLOCKER-11).
- **`refuse_oversized!` raises inside `Corpus#initialize`** (`corpus.rb:328`), where **no `Changeset`
  exists yet** — the corpus is still being constructed. `Bounds#cumulative_advice(view)`
  (`bounds.rb:386-389`) takes a changeset-shaped view, and `fits?` → `view.partitions` →
  `Corpus#files` → `#lazy` → `reads.fetch` is a **full streamed read of every file**
  (`corpus.rb:456-460`). So dynamic narrowing advice is not merely expensive here, it is structurally
  unavailable, and it would destroy the measured no-walk property. T13 is re-cut (panel, BLOCKER-8).
- **`ChildBuilder` never sees a `Role`.** `RoleSpawn#build_subagent` (`skill/role_spawn.rb:71-77`)
  passes `policy: role.spawn_policy(prefix:)` and `persona:`; `ChildBuilder#initialize`
  (`subagent.rb:610-616`) holds `@seam, @toolset, @policy, @budget, @persona, @name`.
  `SpawnPolicy = Data.define(:prefix, :posture, :only)` (`tool/spawn_policy.rb:30`) is the channel,
  and it is **deeply frozen** — CLAUDE.md's `Ractor.shareable?` rule applies (panel, BLOCKER-4).
- **`granted` is called TWICE** in `spawned` (`subagent.rb:661-664`) — once on
  `permitted(@policy.attenuate(union))` and once on the raw `union`, and under the `handler_union`
  posture (`spawn_policy.rb:267-273`) it is the **union** that is rendered (panel, BLOCKER-5).
- **`review_view/` does not exist and `review_view.rb` carries zero `require_relative`** — it is a
  leaf, required from `frontend/neovim.rb:599`. The original T7 asserted a subtree index that is not
  there; corrected (panel, SHOULD-FIX-6).
- **`OpenedBanner.call(headline)` takes a headline String and nothing else** (`opened_banner.rb:48`).
  It has **no access to the round**, and its two callers are `cli/command/review.rb:319` and
  `cli/command/survey.rb:409` — **both of which T6 also edits** (panel, SHOULD-FIX-8).
- **`plugin/nvim/doc/lain.txt` documents both a three-window layout (`:689`) and
  `:LainReply` answering the OLDEST question (`:296`)** — T11 falsifies the first, T3 the second. It
  is a spec-pinned surface (`review_view_spec.rb:489-531`, `deletability_spec.rb:106`), not optional
  tidying (panel, SHOULD-FIX-10).
- **A stated rule this chunk must respect:** `review_focus` takes no arguments deliberately —
  *"where the human is put is the editor's own question, and a Ruby-side answer would be a second
  opinion about a layout only the editor can see"* (`rpc_thread.rb:231-234`). T4/T11 are built to
  honour it: Ruby sends **a fact about the round**, the editor makes **the layout decision**.

**The docent parks, and four things go wrong in a chain.**
- `Role.new(name: :diff_docent, only: %i[read_file list_files glob grep])` — `role/catalog.rb:56`.
  Its own comment (`catalog.rb:47-55`) argues the invariant: *"it answers while a human is mid-review
  and a tier-3 tool would park it at the approval gate."* **The intended property is "never parks";
  `only:` can only express "what it may touch".**
- `ChildBuilder#granted` (`tools/subagent.rb:698-701`) appends the child's own `ask_human` **outside**
  the attenuation, keyed only on session posture — deliberately, because no catalog role names
  `ask_human` in `only:` (its doc, `subagent.rb:672-697`). `ask_human` is in `plan`'s READ_ONLY
  (`mode/posture.rb:137-148`), so every child holds it, docent included.
- `docent_spec.rb:1024-1034` asserts attenuation over `Role::Catalog.fetch(ROLE).attenuate(union)` —
  **the role, never the built child**. That is why the grant is invisible to a green suite.
- The default answerer is `Skill::RoleSpawn#call` → `build_subagent(...).run(prompt)`
  (`skill/role_spawn.rb:64`) — a **synchronous run-to-final-result**. A child parked in
  `AskHuman#awaited` (`tools/ask_human.rb:611`) never returns, so `Delivery#call`
  (`review/docent.rb:549-556`) never reaches `record` (`:601`), `refuse` (`:607`) or `abandon`
  (`:622`), and `PENDING = "(thinking -- the answer will replace this line)"` (`docent.rb:131`)
  stands until the reactor stops.
- `:LainReply` sends **only the answer** (`runtime/70_inbox.lua:7-15`), so
  `human_replies.rb:487` falls back to `@inbox.oldest.digest`. An editor-originated question rides
  `Askers#announce` to `@questions` and to `InboxView` via the record stream, but nothing `gather`s
  it into `HumanReplies::Pending` — so `oldest` is `Unlisted` and `digest` is `nil`
  (`human_replies.rb:984`, `:47-49`), producing `Directory.unanswerable(nil)` (`directory.rb:66-71`).
  **`:LainOpen` already names its digest** via `digest_at` over `Renderings`
  (`human_replies.rb:825-828`) — the asymmetry is the seam.
- Second-order bug found in passing: `resolve_reply` (`human_replies.rb:383-388`) **settles on the
  refusal** — `@views.answered(nil)` and `@inbox.retire(nil)` with a nil digest.

**The outbox has no word for "judged".**
- `Outbox#open?` is literally `!@held.nil?` (`review/submit/outbox.rb:119`). No settled/closed state
  exists; `Nowhere` is an `Error`, not a state object.
- `Held = Data.define(:session, :number, :label)` (`outbox.rb:91`) — **the session is already held**,
  and `Session#verdict` answers `Verdict::None` until judged (`review/session.rb:298`,
  `def verdict = @judgement.verdict`; `:186-198` is the `attr_reader` block — corrected after panel
  review).
  `Verdict::None#empty?` is `true` and a recorded verdict is a `VERDICTS` String, so
  `verdict.empty?` reads "nothing concluded" **with no type test** (`review/verdict.rb:20-35`).
- `wrote_verdict` (`review/handover.rb:308-314`) → `Session#submit` (`session.rb:470-477`) mutates
  the **session** only. **No object on that path holds the outbox**, so both guards
  (`command/survey.rb:337-341`, `command/review.rb:242-246`) still fire afterwards.
- **No spec anywhere settles a round and then tries the other command** — the combination is
  unpinned in both directions.

**The note rail's batching is deliberate and must not be broken.**
- `:LainNote` makes **zero** RPC calls (`runtime/48_annotate.lua:412-439`); the only wire call on the
  rail is the single batch at `:LainNoteDone` (`48_annotate.lua:537`).
- The reason is ordering: *"ORDER IS THE OUTPUT … Extmark order is POSITIONAL … tidy, plausible, and
  the wrong answer"* (`48_annotate.lua:7-15`), pinned by `handover_spec.rb:1108-1160` (the 5, 9, 2, 3
  assertion) and by `qa/scenarios/cockpit-surfaces.md:355-375`.
- The anchor id is **minted at hand-back** (`handover.rb:437-440`, `anchor.rb:111` `SecureRandom.uuid`),
  so a thread genuinely cannot exist before it. **T5 therefore fixes the refusal, not the timing.**
- The facts `:LainThread` needs ARE locally available: the runtime is one concatenated chunk
  (`runtime_loader.rb:6-30`) and `48_annotate.lua` sorts before `51_thread.lua`, and independently
  `nvim_create_namespace("lain_review_notes")` is idempotent (`48_annotate.lua:79-82`).

**Refusal quality.**
- `check_unknown_options!` is declared **nowhere** in `exe/lain` (grep-confirmed). Thor therefore
  leaves `--permissive` in the positional remainder, `open` has arity 1, and Thor composes
  `"survey open"` from `command.ancestor_name` + `command.name` after `default_command :open`
  (`exe/lain:370`) — which is how a verb the human never typed enters the sentence.
- **`--yolo` the flag is gone**, but `spec/lain/cli_spec.rb:312-335` survives as a regression guard
  and asserts Thor's **arity wording** (`/was called with arguments.*--yolo/m`), with a comment
  saying that shape is deliberate *because* `check_unknown_options!` is absent. Adding it changes
  that message. The spec's own stated intent — *"what matters at this seam is that the removal is
  LOUD"* — is better served by asserting the property. **T8 owns that edit.**
- `Session::Scope` interpolates raw `Array#inspect` of Symbols into prose (`session/scope.rb:53`,
  `:81-82`). `spec/lain/review/session_spec.rb:605-614` pins the bracketed form **structurally**
  (`error.message[/\[(.*?)\]/, 1]`, `include(":cumulative")`). ActiveSupport's `to_sentence` has
  exactly one precedent in the repo (`cli/resume/selector.rb:170`).
- `Corpus#refuse_oversized!` (`corpus.rb:398-403`) is a **hand-written imitation** of
  `Bounds#guard!`'s shape (`bounds.rb:448-452`) that never calls it and yields no advice. Because it
  raises in the constructor (`corpus.rb:328`) against the same `Bounds` instance the session gets,
  **`Bounds`' file-count advice is structurally unreachable for a corpus** — `cumulative_advice` can
  only ever fire for the line ceiling. `@walk` is in scope at the raise.

**The sidebar's two path bases.** `review_view.rb:516` (`partition_header`) renders the label
verbatim; `review_view.rb:531-533` (`file_row`) applies `.sub(%r{\A(?:\.\./)+}, "")`. The strip was
added to one and never the other. `review_view_spec.rb:184-228` pins the strip **and its known
limitation**; **no example pins a group header built from a climbing label.**

**Test infrastructure.** There is **no Lua test harness**. Every Lua assertion runs through a real
headless nvim from a Ruby `:seam` spec — `spawn("nvim","--headless","--clean","-n","--listen",socket)`
in `layout_spec.rb:21`, `diff_mode_spec.rb:104`, `review_view_spec.rb:877`, `annotate_spec.rb:79-105`,
`thread_view_spec.rb`. That is where T5, T11 and T3's Lua half must be pinned.

## Grounding corrections (orchestrator, 2026-08-25, before wave 1)

Re-verified by four parallel explorations against the tree at `7836c527`, one per wave-1 cluster.
**No card was invalidated.** Every divergence below is absorbable and was passed to the implementing
agent in its brief. Recorded here so the next reader does not re-derive them.

**Two claims were outright FALSE and changed how a card is built:**

- **T3.** The plan says `:LainOpen` resolves a digest at `human_replies.rb:825-828`. It does not.
  `:824-827` is `Gestures#open_set`, which unpacks `line, generation` and forwards them untouched.
  The real `digest_at`-over-`Renderings` resolution is
  **`lib/lain/frontend/neovim/inbox_view/gestures.rb:107`**, reached via `inbox_view.rb:230`, and the
  Lua command (`70_inbox.lua:103-112`) sends `["open", [line, generation]]`. **So `:LainOpen`
  resolves by line + generation, not by digest** — which settles T3's first escalation trigger in
  favour of taking the generation, and means the symmetric `:LainReply` fix follows an existing
  mechanism rather than inventing a digest-on-the-wire shape.
- **T10.** The plan grounds the annotation pane's rationale in `47_diff.lua:184-191` as being about
  `:LainNote` line numbers and LSP attaching. That range is `review_diff.new_side(path)` — the diff
  pane's *new side*, not the annotation pane — and its documented rationale (`:160-183`) is entirely
  about `:w` refusal and `nowrite` vs `nofile`. **There is no mention of `:LainNote` line numbers or
  LSP anywhere in the runtime tree.** The nearest real statement is `51_thread.lua:140-144`, *"the
  new side is a REAL file buffer the human can edit"* — editability, not LSP. A card about docstring
  accuracy must not write a fresh inaccuracy, so T10 grounds the "why" in editability and in
  `projection.rb:62-63`, and claims no LSP behaviour.

**Two findings resolved an escalation trigger before it could fire:**

- **T8, the `lain up` splat.** Tested empirically against the bundled Thor 1.5.0: `check_unknown_options!`
  **does not** break `up <path> -- --provider ollama-cloud`. `thor/parser/options.rb:65-76` sets
  `@stopped_parsing_after_extra_index` when it consumes `--`, and `check_unknown!` (`:168-174`) only
  inspects `@extra` *before* that index, so post-`--` tokens are structurally exempt. **No `except:`
  is needed.** The dogfood session's launch line is safe.
- **T8, and this one changes the implementation.** `thor.rb:363-380` makes `check_unknown_options?`
  return **false for any command name registered in `subcommands`**. `Survey` (`exe/lain:365-386`),
  `Review` (`:333-354`), `Epic` (`:279-321`) and `Bench` (`:394-557`) are nested `< Thor` subclasses,
  so **a single declaration on `LainCLI` would be inert for `lain survey --permissive`, the card's own
  headline scenario.** Each nested class needs its own. "Once for the whole CLI" means five
  declarations, not one — and a card that added only the parent would have shipped nothing.
- **T1, first escalation trigger — resolved, do not stop on it.** It feared `subagent_spec.rb:1249-1290`
  pins the `ask_human` grant as a *universal* invariant. The block actually spans **1242-1292** and
  already pins it as **posture-conditional**: `:1254` grants it "whenever the session posture permits",
  `:1267` withholds it where the posture does not, `:1282` strips the parent's asker from the dispatch
  union when muted. T1 adds one more condition to an existing conditional.

**Line-number drift, absorbed (the claim holds, the cite moved):**

| card | plan says | actually |
|---|---|---|
| T1 | `subagent.rb:610-616` is `ChildBuilder#initialize` | `:609-616` (609 is the `def`) |
| T1 | `subagent.rb:672-697` is the grant doc | `:673-697` (672 is blank) |
| T3 | `70_inbox.lua:7-15` holds the one-question comment | comment is `:1-6`; `:7-15` is the code |
| T3 | `human_replies.rb:375-382` argues the settle | starts at `:374` |
| T3 | `Directory#reply` at `directory.rb:155-159` | that is `Registration#reply`; `Directory#reply` is `:202` |
| T4 | `neovim_runtime_spec.rb:796-798` pins the rails | `:797-799` |
| T4 | `deletability_spec.rb:106` pins rails *and* help tags | `:106` rails, **`:107` help tags** — separate assertions |
| T4 | `Review::Delta#sides` collides | it is `Delta::Git#sides`, and **private** — narrower, but still name it deliberately |
| T4 | `source.rb:79-89` records the `respond_to?` deletion | `:78-87` |
| T5 | `51_thread.lua:452-458` is the `:LainThread` half | that is `review_thread.window`; the command is **`:700-720`** |
| T5 | `thread_view_spec.rb:1337-1346` pins both refusals | `:1338-1347` is the first; the second starts `:1349` |
| T5 | `48_annotate.lua:585-592` binds `<leader>Lt` | `NOTE_KEYS` is `:587-593`, `t` at `:592`; the prefix is `lain_prefix()` (`30_commands.lua:31`), not literal |
| T6 | `Verdict::None#empty?` at `verdict.rb:20-35` / `:34-37` | **`:38`** — both cites miss it |
| T6 | `review_submit.rb` under `lib/lain/review/submit/` | **`lib/lain/cli/command/review_submit.rb`**; that dir holds only `outbox.rb` |
| T6 | guard's-own-words at `survey_spec.rb:783` | `:776` and `:787` |
| T6 | stranding pair at `survey_spec.rb:806-816` | `:790-822` |
| T6 | attr_reader block at `session.rb:186-198` | `:185-193` |
| T7 | known limitation at `review_view_spec.rb:220-227` | `:219-227` |
| T9 | `scope.rb:81` interpolates an Array | it is a bare **`Symbol#inspect`** — same defect, smaller scale, fix it too |
| T8 | `exe/lain:365-386`/`:567-569` are "the" declarations | Survey only; **Review is `:333-354` and `:562-565`** |
| T8 | `--yolo` guard at `cli_spec.rb:312-335` | block starts `:311` |
| T14 | 28 tracked files match `yolo` | **29** — the plan doc itself became the 29th when the pre-step committed it. Still exactly one changes. |

**Confirmed true and load-bearing, so stated once here:** T6's claim that **no spec settles a round
and then tries the other command** — verified unpinned in both directions, so T6's examples are new
coverage rather than a rewrite. T7's claim that **no example pins a group header built from a
climbing label** — also verified. `check_unknown_options!` really is declared nowhere in `exe/lain`.

## Orchestrator contract (plan-specific only)

- **PRE-STEP, before wave 1 (panel, SHOULD-FIX-9).** Three of this chunk's own inputs are UNTRACKED
  and `/execute-plan` runs cards in **isolated git worktrees**, where an untracked file does not
  exist. Commit on `main` first: `planning/qa/scenarios/survey.md`,
  `planning/qa-findings-round11-2026-08-25.md`, this plan, and the modified `planning/qa/README.md`.
  Without it **T10 silently edits nothing** (or creates a second copy) and integration check 7 loses
  the README's uncommitted edits.
- **Shared files (orchestrator-owned, wiring diffs only):** `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`.
- **`exe/lain` is owned exclusively by T8** for this chunk. No other card may edit it; a card that
  believes it needs to must escalate.
- **`lib/lain/review/source/corpus.rb` is touched by T4 and T13.** T13 is sequenced after T4 for
  that reason alone, not for a logical dependency.
- **THIRD contention edge, undeclared until panel review: T12 ↔ T6** on `lib/lain/cli/command/survey.rb`,
  `lib/lain/cli/command/review.rb` and `spec/lain/cli/command/survey_spec.rb`. Wave ordering separates
  them, but state it rather than relying on luck.
- **`plugin/nvim/doc/lain.txt` is owned by T15.** T11 and T3 both falsify statements in it; no other
  card may edit it.
- **Deviation from the default process, declared so lint does not read it as an omission:** **four
  places carry no spec — T10, T14, T15 and T1's `(cont.)` comment AC.** It is a documentation card — it corrects a docstring whose overclaim made a QA
  driver read correct behaviour as a HIGH-severity leak. Asserting docstring prose in RSpec would pin
  wording nobody should be forced to keep. Its ACs are checked by reading the two files, and it names
  the existing spec (`spec/lain/survey/projection_spec.rb:206`) that must keep passing unchanged.
  The same reasoning covers T14 and T15 (prose) and T1's comment-only criterion. Every other AC in
  the plan maps to a spec file.
- The rail set is pinned in three separate lists — `spec/lain/frontend/neovim_runtime_spec.rb:796-798`,
  `spec/lain/review/deletability_spec.rb:106`, `spec/lain/review/surface/neovim_spec.rb:255`.
  **Any card adding a rail or an argument updates all three**, and T4 is the only card that should
  need to.

## Open decisions

- **`fleet N` never decrements.** `StatusFeed#observe` writes `@fleet[event.digest] = true`
  (`status_feed.rb:422-426`) and nothing ever removes it, so the docent arm counts forever. **Deferred
  deliberately:** `status_feed.rb:44-48` records W3 lifecycle state as future work, and giving `@fleet`
  removal means deciding what "done" means for an arm — a design question, not a fix. The human chose
  this scope explicitly. Round 12 QA should expect `fleet 1` to persist after a docent answers.
- **`--permissive` on `lain survey` will say "Unknown switches --permissive", not "a survey has no
  verdict to judge".** After T8 the refusal is honest and correct; a bespoke sentence explaining why
  *this one flag* is absent would be exactly the special-casing CLAUDE.md warns against. Recorded as
  a decision, not an oversight.
- **Three cards are documentation only and construct nothing: T10, T14 and T15.** That is intentional.
  T10 corrects a claim that misled a QA driver into reading correct behaviour as a HIGH-severity leak;
  T14 purges stale `--yolo` prose from live comments; T15 gives `docs/commands.md` the review tier it
  has never had. None is dormant capability — there is no capability, and each has ACs checkable by
  reading the file.
- **A fail-open secret-boundary decision is deferred, and it names this round.**
  `lib/lain/middleware/redact_secret_reads.rb:106-112` records that an unattended run currently
  returns full bytes for a sensitive read, that `--yolo` was the original justification, and that
  *"flipping this to deny is deferred to round 11 with its own measurement, because it changes what
  EVERY unattended run returns."* **This chunk does not take it.** It needs a measurement this round
  did not make and it is a security-posture change, not a surface fix — but it is named here rather
  than left in a comment, because a deferral pointing at "round 11" should not go unanswered by the
  round-11 chunk without a word. `cli/tool_guard_spec.rb` pins both halves together, so the flip
  lands as a red example when someone takes it.
- **`planning/qa/` needs no `--yolo` work.** Verified 2026-08-25: `git grep -i yolo -- planning/qa/`
  returns **nothing**. The QA scenarios and `method.md` are already current; T14's scope is the three
  live files that are not.

## Waves

```
Wave 1: T1, T3, T4, T5, T6, T7, T8, T9, T10, T14
Wave 2: T11 (←T4), T12 (←T4), T13 (←T4)
Wave 3: T15 (←T3, T8, T9, T11, T12, T13)

T2 is WITHDRAWN (see its card) — 14 cards execute.

Critical path: T4 → T11 → T15   (depth 3)

T11 was redesigned after panel review: `SLOTS` stays a constant, only the OPENED subset varies.
Risk-critical:  T4 → T11
```

**Contention edges, all of them** (three sequencing-only, one logical, all declared):
`T13←T4` and `T12↔T6` are file contention; `T11←T4` and `T15←(five cards)` are logical.

The graph is three deep and wide at wave 1 — ten cards can start at once. T15 is last on purpose:
it documents refusals and a layout that T8, T9, T11, T12 and T13 all change, so writing it earlier
would document behaviour that is about to move. **T13 could run beside T4** if the pair did not edit `corpus.rb`; it is sequenced rather than merged
because merging would join unrelated responsibilities.

**T11 is the highest-risk card in the plan.** Start T4 first so it is not waiting.

## Tasks

### T1 — Let a Role declare that it answers unattended, and make the child builder honour it   [wave 1] [risk: medium]  ✅ LANDED 5e40f111

**Depends on:** none
**Files:** modify `lib/lain/role.rb`, `lib/lain/role/catalog.rb`, `lib/lain/tool/spawn_policy.rb`,
`lib/lain/tools/subagent.rb`, `lib/lain/tools/ask_human.rb` (comment only);
modify `spec/lain/role_spec.rb`, `spec/lain/tool/spawn_policy_spec.rb`,
`spec/lain/tools/subagent_spec.rb`, `spec/lain/review/docent_spec.rb`

**Name the property `unattended:`** — decided here rather than left to the executor (panel, NIT-3),
because it is spelled in a `Data` member, a catalog entry, a docstring and three specs.

**`ChildBuilder` never sees a `Role`** (panel, BLOCKER-4). The channel is
`SpawnPolicy = Data.define(:prefix, :posture, :only)` (`tool/spawn_policy.rb:30`), built by
`Role#spawn_policy` (`role.rb:25-27`) and held as `@policy`. Add the member there.
**`SpawnPolicy` is deeply frozen — `Ractor.shareable?` must stay true** (CLAUDE.md), and there is a
spec for that property.
**Reuse:** `Role#spawn_policy` (`lib/lain/role.rb:25-27`); `ChildBuilder#granted`
(`tools/subagent.rb:698-701`); the posture check `@seam.permits.include?(asker.name)`
**Shared-file wiring:** none
**Reachable from:** `Skill::RoleSpawn#call` → `Subagent::ChildBuilder#build` → `#granted` — the real
spawn path every `@role` dispatch and every `Docent#ask` already takes.

A `Role`'s `only:` list says what an arm may TOUCH. The property `diff_docent` actually needs is that
it may not PARK — on the approval gate or on a human — because it answers while a human is standing
mid-review waiting for the line to change. `only:` cannot express that, which is why
`catalog.rb:47-55` argues the invariant in prose and `ChildBuilder#granted` then defeats it by
appending `ask_human` outside the attenuation. Give the role the word.

Name the property for the guarantee, not for the tool: an arm that answers unattended holds no tool
that can block on a human. `ask_human` is the only such tool today; the point of the property is that
a second one cannot quietly reach the docent later.

**Acceptance criteria:**

```gherkin
Scenario: an unattended role's child holds no ask_human, in either set
  Given a session posture that permits ask_human
  And the diff_docent role, which answers unattended
  When a child is built for that role
  Then the allowed set does not include ask_human
  And the rendered dispatch union does not include ask_human either
  And both assertions are made over the BUILT CHILD, not over the role's attenuation

Scenario: the spawn policy stays shareable
  Given a SpawnPolicy carrying the unattended member
  Then Ractor.shareable? answers true for it

Scenario: an ordinary role's child still gets its own ask_human
  Given a session posture that permits ask_human
  And a role that does not answer unattended
  When a child is built for that role
  Then the child's toolset includes its own ask_human
  And it is not the parent's

Scenario: the catalog's stated invariant is pinned where it is claimed
  Given the diff_docent catalog entry
  Then it declares that it answers unattended
  And no role in the catalog declares it while also naming a parking tool in `only:`
```
→ spec files: `spec/lain/tools/subagent_spec.rb`, `spec/lain/tool/spawn_policy_spec.rb`,
`spec/lain/role_spec.rb`, `spec/lain/review/docent_spec.rb`. **The `(cont.)` comment AC above is
documentation-only and has no spec** — same deviation as T10/T14/T15.

**Also correct one stale comment this card makes wrong twice over.** `lib/lain/tools/ask_human.rb:199`
still reads *"`research_subagent` and `role_spawn_seam` are handed the `base` set, which excludes it,
so **no child can ask at all**"* — already false today (`ChildBuilder#granted` gives every child its
own asker) and about to become false in a second, narrower way. `cli/wiring/toolset_build.rb:24-39`
carries the corrected account; make `ask_human.rb` agree with it. Comment only, no behaviour.

**Acceptance criteria (cont.):**

```gherkin
Scenario: the comment describing who may ask is true
  Given lib/lain/tools/ask_human.rb's Outstanding docstring
  Then it does not claim that no child can ask
  And it names the condition under which a child holds its own asker
```

**Escalation triggers:**
- `spec/lain/tools/subagent_spec.rb:42-47`, `:1074-1080` and `:1249-1290` currently pin that **every**
  child gets `ask_human` even when the union has none. This card makes that conditional — if any of
  those examples reads as a universal invariant rather than a default, stop and confirm.
- `docent_spec.rb:1024-1034` asserts over `Role::Catalog.fetch(ROLE).attenuate(union)`. If tightening
  it to the built child requires reaching into `ChildBuilder` internals rather than an existing public
  seam, the seam is wrong — escalate rather than adding a test-only accessor.
- `subagent.rb:672-697`'s doc argues the grant is unconditional **on purpose**. This card narrows it.
  If that doc names a failure mode this card reintroduces, stop.

---

### T2 — WITHDRAWN (no defect behind it)

**Withdrawn during panel review, second pass (BLOCKER-11). Not to be executed. The id is kept rather
than renumbered so cross-references in this plan and in the round-11 findings still resolve.**

The card was written to stop the thread pane claiming to be thinking after an arm failed to answer.
Panel review killed it twice, and the second death is the honest one:

1. **First form** — "the delivery finishes without recording one" — is unreachable. `Delivery#answer`
   (`docent.rb:586-593`) settles on all three exits and `#call` (`:549-556`) adds
   `rescue => refuse` and `ensure => abandon`.
2. **Re-grounded form** — "an abandoned question stops claiming to be thinking" — **already holds on
   `HEAD`.** `#abandon` settles (`docent.rb:622-627`, `settle(SPEAKER_LAIN, ABANDONED, :abandoned)`),
   `Docent#open` renders the in-memory conversation (`:338-342`), the replay path folds it
   (`:720`), and it is pinned: `spec/lain/review/docent_spec.rb:824` — *"closes the record when the
   session ends before the answer does, and stays askable"* — whose own comment describes the
   permanently-thinking replay as a defect **already fixed**.

The one genuinely unfixed sliver is the pane **on screen at the instant of the stop**, and there is no
fiber left to redraw it on — which is exactly the trade-off `docent.rb:620-621` states and accepts.

**F64 is still discharged**: T1 removes the park that was the observed mechanism, and T3 fixes the
`:LainReply` half of the three-surface disagreement. The `fleet` half stays deliberately deferred
(Open decisions).

A card that would go green on an empty diff is worse than no card: it passes review and ships nothing.

---

### T3 — Make an editor-originated reply resolve to its own question   [wave 1] [risk: medium]  ✅ LANDED 5cb5545f

**Depends on:** none
**Files:** modify `lib/lain/frontend/neovim/runtime/70_inbox.lua`, `lib/lain/cli/human_replies.rb`;
modify `spec/lain/frontend/neovim/inbox_view_spec.rb`, `spec/lain/cli/command/inbox_spec.rb`
**Reuse:** `Gestures#open_set` → `InboxView#open` → `digest_at` over `Renderings`
(`human_replies.rb:825-828`) — **`:LainOpen` already does exactly this**; `Directory#reply`
(`tools/ask_human/directory.rb:155-159`)
**Shared-file wiring:** none
**Reachable from:** `runtime/70_inbox.lua`'s `:LainReply` → `rpc_thread` `"reply"` verb →
`human_replies.rb:487` — the path a human at the cockpit takes.

**Two bugs on the reply path — and they are NOT on one seam** (panel, SHOULD-FIX-3; the original
card's "one seam" claim was false). The wire bug is `70_inbox.lua:7-15` + `human_replies.rb:487`.
The settle bug is in `resolve_reply` (`:383-388`), reached from `drain_at_prompt` (`:291-294`) and
from an `AnswerLoop` `resolve:` hook (`:357`) — **a path `:LainReply` never takes.** They are kept in
one card because both are small, both are on the path a human uses to answer, and neither is
trustworthy without the other; the card carries two named spec files for the two behaviours.

`:LainReply` sends only the answer (`70_inbox.lua:7-15`, whose comment still asserts "today one
question is pending at a time"), so the consumer guesses with `@inbox.oldest.digest`. For a question
raised from the editor while the human sits at `you>`, nothing ever `gather`s it into
`HumanReplies::Pending`, so that guess is `nil` and the human is told the inbox line they are looking
at is stale. `:LainOpen` on the very same buffer already resolves a digest correctly.

And on that refusal, `resolve_reply` (`human_replies.rb:383-388`) **settles anyway** —
`@views.answered(nil)`, `@inbox.retire(nil)`. **Only the nil case is wrong**: retiring a named-but-dead
question is deliberate (`human_replies.rb:375-382`), and reversing that reinstates a documented bug.

**Acceptance criteria:**

```gherkin
Scenario: a reply names the question it is answering
  Given a question rendered in lain://inbox
  When the human answers it with :LainReply
  Then the digest sent is the one that row carries
  And it is resolved the same way :LainOpen resolves it

Scenario: a question raised from the editor is answerable
  Given a question announced while the human is at the you> prompt
  And a row for it in lain://inbox
  When the human answers it with :LainReply
  Then the answer reaches the asker
  And the human is not told the row is stale

Scenario: a refusal with no question named retires nothing
  Given a reply that names no question at all, so the digest is nil
  When the refusal is raised
  Then no view is marked answered
  And no inbox entry is retired

Scenario: a refusal that DOES name a dead question still retires it
  Given a reply naming a question that is no longer pending
  When the refusal is raised
  Then that question is still settled and retired, exactly as today
```
→ spec files: `spec/lain/frontend/neovim/inbox_view_spec.rb`, `spec/lain/cli/command/inbox_spec.rb`

**Escalation triggers:**
- `70_inbox.lua`'s comment asserts one-question-at-a-time. If the wire change means a *generation*
  stamp is needed to avoid answering a row that moved under the cursor — as `:LainOpen` already
  carries — take the generation, and escalate if `:LainReply`'s verb cannot accept one without
  changing the answered-verb set pinned at `rpc_thread_spec.rb:549`.
- `inbox_view_spec.rb` pins that a reply `:message` retires nothing and that only a `TurnUsage`
  citing the digest consumes a row. If fixing the nil-digest settle changes which record retires a
  row, stop — that is `InboxView`'s consumption rule and this card does not own it.
- If `@inbox.oldest` turns out to have callers that *depend* on the nil fallback, escalate.
- **`human_replies.rb:375-382` argues the settle is DELIBERATE** — not settling *"left the dead
  question listed, and every later `/inbox` offered it again — a line that lists forever and can only
  ever refuse."* **Only the nil-digest case is the defect.** A change that stops retiring a named-but-
  dead question reinstates that documented bug — stop (panel, BLOCKER-7).

---

### T4 — Let a Review::Source say which sides it presents, and tell the editor   [wave 1] [risk: medium]  ✅ LANDED 40049380

**Depends on:** none
**Files:** modify `lib/lain/review/source.rb`, `lib/lain/review/source/corpus.rb`,
`lib/lain/review/source/local_branch.rb`, `lib/lain/review/source/github_pr.rb`,
**`lib/lain/review/changeset.rb`**, `lib/lain/review/surface/neovim.rb`,
`lib/lain/frontend/neovim/rpc_thread.rb`;
modify `spec/lain/review/changeset_spec.rb`, `spec/lain/review/source/corpus_spec.rb`,
`spec/lain/frontend/neovim/rpc_thread_spec.rb`, `spec/lain/frontend/neovim_runtime_spec.rb`,
`spec/lain/review/deletability_spec.rb`, `spec/lain/review/surface/neovim_spec.rb`

**Two corrections from panel review, both structural:**

1. **`Changeset` must delegate** (BLOCKER-1). `ChangesetDiff#drawn` holds a `Changeset`, not a
   `Source`, and `@source` is private on purpose (`changeset.rb:188`). Follow `#supports?`
   (`changeset.rb:196`) exactly — it is the same shape for the same reason.
2. **The fact rides `set_review`, NOT `open_changeset`** (BLOCKER-2). `review_panes.ensure()` builds
   the windows at **first paint**, from `46_sidebar.lua:88`, before any `<CR>`. A fact delivered on
   `open_changeset` arrives after the wasted window already exists. `set_review(lines, generation)`
   is the rail that precedes the layout, so it carries the sides; the editor stashes it on the
   tabpage (T11) and `open_changeset` reads it from there rather than being sent it twice.

**This is a deliberate protocol change, not a surprise to escalate.** Update all three pinned lists:
`surface/neovim_spec.rb:255` (`%i[set_review open_changeset set_thread review_refused]`),
`neovim_runtime_spec.rb:796-798`, `deletability_spec.rb:106`.
**Reuse:** `Review::SIDES` (`review/vocabulary.rb:31`) — **derive from it, never restate its
members**, which is that file's own stated rule; `Changeset#supports?` (`changeset.rb:196`) as the
delegation precedent; `Partition::ByCommit#supports?` (`partition/by_commit.rb:101`) as the precedent
for a source-shape predicate on the port; the existing `set_review` rail (`rpc_thread.rb:85`).
**Name the message deliberately — `Review::Delta#sides(fields)` already exists
(`review/delta.rb:289`) meaning something else entirely** (panel, NIT-8).
**Shared-file wiring:** none
**Reachable from:** `Review::Surface::Neovim#present` (`review/surface/neovim.rb:303`) →
`RpcThread#post_review_sidebar` → `set_review` — posted on **every** `/survey` and `/review`, before
the layout is built. **The new fact must be on that post, not merely available on the object**; a
card that adds the message and does not send it has shipped nothing.

A corpus has no old side — not "not this time", but structurally, for every file it will ever hold.
A changeset has two sides even when a particular file is an addition. Those are different facts and
the editor currently cannot tell them apart, because neither reaches it.

Add the fact to the source port and put it on the wire. **Send a fact, not a layout instruction** —
`rpc_thread.rb:231-234` states the rule that layout is the editor's own question, and this card is
built to respect it: Ruby says *this round has one side*, T11 decides what to do about it.

**Acceptance criteria:**

```gherkin
Scenario: a corpus presents one side
  Given a corpus source
  Then it answers that it presents only the new side
  And the sides it names are drawn from Review::SIDES rather than restated

Scenario: a changeset source presents two sides
  Given a local-branch source
  Then it answers that it presents both sides
  And a github pull-request source answers the same

Scenario: an added file does not make a changeset one-sided
  Given a local-branch review of a changeset containing an added file
  When that file's row is opened
  Then the round still reports two sides
  And the empty old side is still posted as it is today

Scenario: the editor is told before it builds the layout
  Given a survey is presented
  When set_review is posted
  Then the payload carries the sides the round presents
  And it is posted before any row is opened

Scenario: a changeset review says two sides on the same rail
  Given a local-branch review is presented
  When set_review is posted
  Then the payload names both sides
```
→ spec files: `spec/lain/review/source/corpus_spec.rb`,
`spec/lain/frontend/neovim/changeset_diff_spec.rb`, `spec/lain/frontend/neovim/rpc_thread_spec.rb`

**Escalation triggers:**
- **Changing `set_review`'s arity touches the protocol history.** Updating the three pinned lists is
  EXPECTED work for this card, not a surprise. But if the **protocol VERSION** must be bumped,
  **stop and confirm** — that is not this card's decision.
- If `Changeset` cannot delegate `#sides` without exposing `@source`, stop — `changeset.rb:188`
  argues that privacy explicitly.
- `changeset_diff_spec.rb:323` ("still posts the empty old side a survey has") and `:218` (an added
  file opens with an empty old side) both pin current behaviour. This card must keep **both** posts
  intact and only ADD the fact. If either has to change, the seam is wrong.
- `Source` is a documented port (`review/source.rb:16`, `:79-89`, which records deleting a
  `respond_to?` type test). If adding `#sides` tempts a `respond_to?(:sides)` anywhere, stop — every
  registered source must answer it.

---

### T5 — Tell an unhanded note from no note at all   [wave 1] [risk: low]  ✅ LANDED e72fdea7

**Depends on:** none
**Files:** modify `lib/lain/frontend/neovim/runtime/51_thread.lua`;
modify `spec/lain/frontend/neovim/thread_view_spec.rb`
**Reuse:** the idempotent `nvim_create_namespace("lain_review_notes")` (`48_annotate.lua:79-82`), or
the `review_notes` chunk-local upvalue — `48_annotate.lua` sorts before `51_thread.lua` in one
concatenated chunk (`runtime_loader.rb:6-30`); the existing two-branch refusal in
`define("LainThread")` (`51_thread.lua:700-719`)
**Shared-file wiring:** none
**Reachable from:** `define("LainThread")` — the `<leader>Lt` gesture, bound at
`48_annotate.lua:585-592`.

`:LainThread` says *"no thread on this line"* while a `● note` marker sits visibly on that line. Both
sentences are true and the human can only see one of them. A thread genuinely cannot exist yet — the
anchor id is minted at hand-back (`handover.rb:437-440`) — so **this card does not change the
timing**. The note rail's batch is load-bearing for placement order (`48_annotate.lua:7-15`) and must
not be touched.

Add the third sentence, naming the state and the remedy.

**Acceptance criteria:**

```gherkin
Scenario: a note that has not been handed back says so
  Given a review diff buffer with a note placed on the line under the cursor
  And that note has not been handed back
  When :LainThread is invoked
  Then the refusal says a note is there but has not been handed back
  And it names :LainNoteDone as the remedy

Scenario: a line with no note at all keeps its own sentence
  Given a review diff buffer with no note on the line under the cursor
  When :LainThread is invoked
  Then the refusal is the existing no-thread-on-this-line sentence

Scenario: a buffer that is not a review diff keeps its own sentence
  Given a buffer that is not a review side
  When :LainThread is invoked
  Then the refusal is the existing needs-a-review-diff-buffer sentence

Scenario: no refusal raises
  Given any of the three refusals above
  Then it is delivered as a message, not as an error
  And nvim_get_mode does not block
```
→ spec file: `spec/lain/frontend/neovim/thread_view_spec.rb`

**Escalation triggers:**
- `thread_view_spec.rb:1337-1346` pins the current two-branch behaviour ("says so rather than
  raising"). This card **extends** it; if the existing example must be deleted rather than joined,
  stop.
- `51_thread.lua:119-120` and `41_layout.lua:29-30` both cite the **60-upvalues-per-prototype cap** as
  the reason each module takes exactly one top-level name. If reaching `review_notes` as an upvalue
  pushes the chunk over it, use the namespace-by-name route instead — do not add a second top-level
  local.
- If a note's marker namespace turns out not to be queryable per-row from the `LainThread` handler,
  escalate rather than adding a new RPC.

---

### T6 — Stop a settled round from holding the gesture rails   [wave 1] [risk: medium]  ✅ LANDED 60be33f2

**Depends on:** none
**Files:** modify `lib/lain/review/submit/outbox.rb`, `lib/lain/cli/command/survey.rb`,
`lib/lain/cli/command/review.rb`; modify `spec/lain/review/submit/outbox_spec.rb`,
`spec/lain/cli/command/survey_spec.rb`, `spec/lain/cli/command/review_spec.rb`
**Reuse:** `Held#session` — **already held** (`outbox.rb:91`); `Session#verdict` answering
`Verdict::None` until judged (`session.rb:186-198`); `Verdict::None#empty?` (`verdict.rb:34-37`),
which is the codebase's own no-type-test idiom; `held_source` (`outbox.rb:133`) as the model for a
delegating query
**Shared-file wiring:** none
**Reachable from:** `Command::Survey#refuse_second_surface!` (`survey.rb:337-341`) and
`Command::Review#refuse_over_survey!` (`review.rb:242-246`) — both on the real `/survey` and
`/review` dispatch path.

A chat that has surveyed can never review a branch again, **even after the survey is settled by a
verdict**. The guards ask "what kind of round is held", which was the right question when the only
answer was "a live one". `Session#submit` settles the session and no object on that path holds the
outbox, so nothing downstream ever learns.

The outbox already holds the session, so it can answer whether the round it holds is still awaiting
judgement — a delegated **query**, not a kind test, which is what `held_source`'s own doc
(`outbox.rb:120-131`) is careful to preserve. **`@held` must stay in place**: `/review-submit` reads
`target` *after* sending (`review_submit.rb:107-109`), so clearing it would break submission. The
guard's own rationale — *"a sidebar the survey's marks cannot reach"* — no longer applies once the
marks have been handed back and judged.

**Acceptance criteria:**

```gherkin
Scenario: a settled survey no longer blocks a changeset review
  Given a chat with a survey open
  When the survey is settled with a verdict
  And the human opens a review of a local branch
  Then the review opens
  And no already-open refusal is raised

Scenario: a settled changeset review no longer blocks a survey
  Given a chat with a local-branch review open
  When it is settled with a verdict
  And the human opens a survey
  Then the survey opens

Scenario: a LIVE round still blocks the other kind
  Given a chat with an unsettled survey open
  When the human opens a review of a local branch
  Then it refuses, naming the survey
  And the refusal is unchanged from today

Scenario: the settled round is still submittable until another replaces it
  Given a settled round and no later round opened
  Then the outbox still holds it
  And /review-submit can still name its target
  # NOTE: Outbox#hold replaces @held, so once AC 1's branch review opens, the
  # settled survey is gone and /review-submit names the branch. That is correct.
```
→ spec files: `spec/lain/review/submit/outbox_spec.rb`, `spec/lain/cli/command/survey_spec.rb`,
`spec/lain/cli/command/review_spec.rb`

**Escalation triggers:**
- `survey_spec.rb:737-838` owns both directions of the guard, and `:783` deliberately asserts on the
  guard's **own words** because a mutant passed on a tmpdir match alone. Keep that assertion working.
- `survey_spec.rb:806-816` (the "stranding pair") pins that nothing is held when `Session#present`
  raises. This card must not make a *refused* round look settled.
- `session.rb:522-526` says reopening a settled round is "a larger decision" and that "a human who
  wants one can open a fresh survey today". This card does **not** reopen anything — if the
  implementation drifts toward reopening, stop.
- `outbox.rb:120-131` argues against something NARROWER than "no judgement": it forbids the outbox
  **deciding which source word means what**. The falsifiable criterion (panel, SHOULD-FIX-4): *the
  outbox may forward a question to the session it already holds; it may not interpret a source
  word.* If the implementation interprets, re-cut it.

---

### T7 — Name a surveyed file the same way in every row that shows it   [wave 1] [risk: low]  ✅ LANDED d18b579c

**Depends on:** none
**Files:** modify `lib/lain/frontend/neovim/review_view.rb`;
modify `spec/lain/frontend/neovim/review_view_spec.rb`
**Reuse:** the existing strip at `review_view.rb:531-533` and its reasoning comment (`:525-530`);
`Corpus::Prefix.between` (`review/source/corpus.rb`), which is where the climb originates
**Shared-file wiring:** none — one file, one spec, one commit.

**Corrected after panel review (SHOULD-FIX-6, NIT-4).** The original card asserted that
`review_view.rb` is a subtree index requiring `review_view/`. **It is not:** that directory does not
exist and `review_view.rb` carries zero `require_relative` — it is a leaf, required from
`frontend/neovim.rb:599`. The conclusion (no `lib/lain.rb` edit) happened to be right; every premise
was false.

**And no new file.** The defect is one `sub` on one of two call sites, and the two other surfaces
that render this path correctly are in Lua and in other objects — they cannot share a new collaborator,
so it would buy exactly one caller. **A private method both `partition_header` and `file_row` pass
through** gives the single owner this card argues for, with no subtree question at all.
**Reachable from:** `ReviewView#partition_header` (`review_view.rb:516`) and `#file_row` (`:531`) —
every row drawn into `lain://review`.

One buffer renders the same path two ways. A `by_directory` group header keeps its climb
(`../../../dev/lain/lib/lain/survey`) while the file rows under it have theirs stripped
(`dev/lain/lib/lain/survey/chunker.rb`), which resolves from cwd to a path that does not exist. The
strip was added to `file_row` and never to `partition_header`.

The fix is not to copy the `sub` — it is that **how a surveyed path is shown is a decision no row
should be making for itself.** Give it one owner and let both callers ask.

Note the two other surfaces that render this path correctly today and must keep doing so: the OLD
buffer's name (`lain://review/OLD/../../../…`) and the thread pane header
(`-- thread at ../../../…:12 --`). `file.path` itself must stay untouched — `<CR>` and `47_diff.lua`
resolve through the real name (`review_view.rb:525-530`).

**Acceptance criteria:**

```gherkin
Scenario: a group header and its file rows agree
  Given a by_directory survey of a tree outside the project
  When the sidebar is rendered
  Then the group header and the rows beneath it name the path the same way

Scenario: opening still uses the real path
  Given a row whose displayed name has had its climb dropped
  When the row is opened
  Then the file opened is the one the untouched path names

Scenario: an in-project path is unchanged
  Given a survey of a tree inside the project
  Then every row is drawn exactly as it is today
```
→ spec file: `spec/lain/frontend/neovim/review_view_spec.rb`

**Escalation triggers:**
- `review_view_spec.rb:184-228` pins the strip **and** a known limitation at `:220-227` (a partial
  climb renders indistinguishably from an in-project row). This card does not fix that limitation; if
  the extraction makes it worse, stop.
- `review_view_spec.rb:489-531` pins row widths against `41_layout.lua`'s 40-column sidebar and
  against `plugin/nvim/doc/lain.txt`. A longer header must not break those.
- If unifying the two means the header stops matching what `Partition::ByDirectory` produces as a
  label, escalate — the label is the partition's output, not the view's.

---

### T8 — Refuse unknown switches in exe/lain, on every subcommand   [wave 1] [risk: medium]  ✅ LANDED 380efe62

**Depends on:** none
**Files:** modify `exe/lain`; modify `spec/lain/cli_spec.rb`, `spec/lain/cli/survey_spec.rb`,
`spec/lain/cli/chat_flags_spec.rb`
**Reuse:** Thor's own `check_unknown_options!`; the existing `Boundary#render` mapping
(`exe/lain:48-53`)
**Shared-file wiring:** none — **T8 owns `exe/lain` exclusively for this chunk.**
**Reachable from:** every `lain <subcommand>` invocation. This is the CLI entry point itself.

`check_unknown_options!` is declared nowhere in `exe/lain`, so **every** subcommand mistakes an
unknown switch for a positional argument. On `lain survey PATH --permissive` that produces Thor's
arity error naming `survey open` — a verb the human never typed, introduced by `default_command :open`
(`exe/lain:370`).

Fix the cause, once, for the whole CLI. The human chose repo-wide over a per-command patch.

**The spec that must change, and why it is an improvement.** `spec/lain/cli_spec.rb:312-335` is a
regression guard for the removed `--yolo` flag. Its comment says the arity shape is asserted
*"deliberately, rather than the words 'unknown option'"* precisely **because** `check_unknown_options!`
is absent — and states the property it actually cares about: *"what matters at this seam is that the
removal is LOUD."* Re-point it at that property: refused, nonzero, and the flag named. Do not simply
delete it.

**Acceptance criteria:**

```gherkin
Scenario: an unknown switch is refused as an unknown switch
  Given the command line `lain survey <path> --permissive`
  When it runs
  Then it exits nonzero
  And the message names --permissive
  And the message does not name a subcommand the human did not type

Scenario: a removed flag is still refused loudly
  Given the command line `lain chat --yolo`
  When it runs
  Then it exits nonzero
  And the message names --yolo
  And no session is opened

Scenario: every declared flag still works
  Given each subcommand's declared options
  Then each is still accepted
  And the post-`--` splat on `lain up` still reaches the pane command
```
→ spec files: `spec/lain/cli_spec.rb`, `spec/lain/cli/survey_spec.rb`,
`spec/lain/cli/chat_flags_spec.rb`

**Escalation triggers:**
- **`lain up` passes trailing arguments after `--`, and this is the FIRST thing to check, not a
  surprise to hit later** (panel, NIT-5). `survey-dogfood-2026-08-25.md` §3's own launch line is
  `<shim> up /home/tara/dev/lain -- --provider ollama-cloud`, and this chunk exists to protect that
  session. **Determine up front whether the class-level declaration needs an `except:` for `up`**
  rather than discovering it in a red `cli_spec.rb` "up argv threading through .start" example. If
  `check_unknown_options!` cannot coexist with that splat, **stop immediately** — the cockpit's launch
  path outranks this refusal.
- `spec/lain/cli_spec.rb:316-320` and `spec/lain/cli/chat_flags_spec.rb:14-17` both **document the
  absence** of `check_unknown_options!`. Both comments become false; update them.
- If any subcommand relies on unknown switches reaching a positional argument on purpose (a
  pass-through), stop — that is a real design decision this card would break.

---

### T9 — Name scopes in prose, not in Ruby inspect   [wave 1] [risk: low]  ✅ LANDED e08b6cd2

**Depends on:** none
**Files:** modify `lib/lain/review/session/scope.rb`; modify `spec/lain/review/session_spec.rb`
**Reuse:** ActiveSupport's `to_sentence` — one precedent already in the repo at
`lib/lain/cli/resume/selector.rb:170`, with its `require "active_support/core_ext/array/conversions"`
at `selector.rb:3`. CLAUDE.md: *"ActiveSupport is welcome where it earns its place."* The
`STRATEGIES.each_key.to_a.join("|")` form at `command/survey.rb:174` shows the codebase already
avoids `inspect` where a human reads the result.
**Shared-file wiring:** none
**Reachable from:** `Session::Scope.resolve` (`scope.rb:50-57`) and `#support!` (`:77-83`) — reached
by `/survey --scope`, `/review --scope` and `lain survey --scope`.

Two refusals a human reads interpolate `Array#inspect` of Symbols:
`[:cumulative, :by_directory] do present this one`. The sentences are otherwise well-built and their
CONTENT is correct — the first lists only what this source really presents, the second the whole
registry. Only the rendering is wrong.

**Pick ONE rendering and say which (panel, SHOULD-FIX-7).** This registry is already rendered three
ways — `scope.rb`'s `inspect`, `command/survey.rb:174`'s `join("|")`, and Thor's enum
`"cumulative, commits, by_directory"`. **Use `join(", ")`, matching Thor's**, rather than adding a
fourth shape with `to_sentence`'s trailing "and". That keeps the CLI and the REPL reading alike and
needs no ActiveSupport require at all.

**Acceptance criteria:**

```gherkin
Scenario: an inapplicable scope names the alternatives in prose
  Given a corpus source
  When a scope it cannot answer is requested
  Then the refusal names the scopes this source does present
  And it names them as words, without brackets or leading colons
  And it still names the requested scope and the source

Scenario: an unknown scope names the whole registry in prose
  Given a misspelled scope
  Then the refusal lists every registered scope as words
  And it names what was typed

Scenario: the vocabulary still comes from the registry
  Given a strategy is added to or removed from the registry
  Then both sentences change with it, with no second list to edit
```
→ spec file: `spec/lain/review/session_spec.rb`

**Escalation triggers:**
- `spec/lain/review/session_spec.rb:605-614` pins the bracketed form **structurally** —
  `error.message[/\[(.*?)\]/, 1]` and `include(":cumulative", ":by_directory")`. This card
  necessarily breaks it. Rewrite it to assert the scope NAMES are present and that the source and the
  requested scope are named; **do not** simply loosen it to a substring match on `cumulative`, which
  would pass against the old wording too.
- The looser mirrors at `spec/lain/cli/survey_spec.rb:290` and `spec/lain/cli/command/survey_spec.rb:526`
  should survive untouched. If either breaks, the sentence changed more than intended.
- **`session_spec.rb:612` carries a NEGATIVE (`not_to include(":commits")`) that will pass VACUOUSLY**
  once the brackets are gone — the regex finds nothing, so the negative is trivially true (panel,
  NIT-6). Rewrite it to assert against the rendered sentence, or it stops guarding anything.

---

### T10 — Say what Projection actually guarantees   [wave 1] [risk: low]  ✅ LANDED 0669d378

**Depends on:** none
**Files:** modify `lib/lain/survey/projection.rb` (documentation);
modify `planning/qa/scenarios/survey.md`
**Reuse:** the doc's own existing scoping paragraph at `projection.rb:22-35`, which already ends with
the precise form: *"What the projection guarantees is narrower and true: no region the ledger holds as
unreleased survives into a survey artifact."*
**Shared-file wiring:** none
**Reachable from:** **deferred: documentation only, constructs nothing.** Recorded in Open decisions.

`projection.rb:37-45` claims *"Above the source, the session, **the surfaces**, the journal and the
docent see only released bytes."* A QA driver read "the surfaces" as including the annotation pane,
found the raw key in it, and came within one code-read of filing a HIGH-severity leak against correct
behaviour.

**The behaviour is right and stays.** A survey is a survey of project state; the human opens their own
file, which `projection.rb:62-63` already says. What is wrong is that one sentence enumerates
"the surfaces" without distinguishing **the artifact** — what the session, journal, docent and model
see, all of which really are projected — from **the annotation pane**, which is the human's own file
opened deliberately so `:LainNote` gets real line numbers and LSP attaches (`47_diff.lua:184-191`).

Narrow the claim to what is true and name the exception where the reader will meet it.

**Acceptance criteria:**

```gherkin
Scenario: the docstring distinguishes the artifact from the annotation pane
  Given lib/lain/survey/projection.rb
  Then its guarantee names what is projected: the session, the journal, the docent and the model
  And it states that the annotation pane shows the file on disk, unprojected, deliberately
  And it says why: a survey is of project state, and the note rail needs the real file

Scenario: the QA scenario no longer asks for a masked buffer
  Given planning/qa/scenarios/survey.md section 4
  Then it asserts the projection over the artifact rather than over the opened buffer
  And it records that the opened buffer showing raw bytes is correct
```
→ no new spec; this card changes documentation only. **`spec/lain/survey/projection_spec.rb:206`
("never projects a denied path, so no survey artifact can carry it") must still pass unchanged** —
its wording is the narrow claim and is already correct.

**Escalation triggers:**
- If narrowing the claim reveals that a surface **other** than the annotation pane shows unprojected
  bytes — the journal, the docent brief, a `/critique` prefill — **stop immediately and escalate.**
  That would be a real leak and a different chunk.
- `middleware/redact_secret_reads.rb:12` and `telemetry/secret_boundary.rb:103` carry related wording.
  If they make the same overclaim, note it; do not fix them here without confirming.

---

### T11 — Open only the slots the round has, keeping the vocabulary whole   [wave 2] [risk: high]  ✅ LANDED bde9195c

**Depends on:** T4
**Files:** modify `lib/lain/frontend/neovim/runtime/41_layout.lua`,
`lib/lain/frontend/neovim/runtime/46_sidebar.lua`,
`lib/lain/frontend/neovim/runtime/47_diff.lua`,
**`lib/lain/frontend/neovim/runtime/51_thread.lua`**; modify
`spec/lain/frontend/neovim/layout_spec.rb`, `spec/lain/frontend/neovim/diff_mode_spec.rb`,
**`spec/lain/frontend/neovim/thread_view_spec.rb`**,
`spec/lain/seams/survey_subdirectory_spec.rb`
**Reuse:** `review_panes.ensure` / `open` / `anchor` / `review_place`
(`41_layout.lua:145-199`, `:243-256`); `_G.__lain.open_changeset` (`47_diff.lua:518-540`); the sides
fact T4 puts on the wire
**Shared-file wiring:** none
**Reachable from:** `set_review` (`46_sidebar.lua:88` → `review_place("sidebar", buf)`) →
`review_panes.ensure` — the FIRST paint of every `/survey` and `/review`, before any `<CR>`. The
`<CR>` path (`_G.__lain.open_changeset`, `47_diff.lua:518-540`) then reads the stashed fact rather
than being sent it again.

**This is the card the human asked for by name:** a survey shows the raw file because it is a survey
of project state, and the OLD split wastes a whole window on a buffer that is structurally guaranteed
empty.

**The design, decided here rather than delegated (panel, BLOCKER-3 and SHOULD-FIX-1).**

**`SLOTS` stays a constant** — the full, ordered slot VOCABULARY. What becomes per-round is only
**the subset `review_panes.ensure()` OPENS at first paint.** That single distinction answers four
problems at once:

- `index_of`/`anchor` (`41_layout.lua:56-63`, `:123-138`) keep a stable total order, so left-to-right
  placement stays deterministic.
- `review_place`'s by-name refusal (`:244-247`) still refuses a slot that never existed, and can now
  distinguish it from one **not opened in this round** — which a shrunken `SLOTS` would have made
  impossible.
- `layout_spec.rb:395-413`, which pins the vocabulary by **regexing the Lua source**, stays green
  untouched. It is the only defence a cross-language vocabulary has (`41_layout.lua:47-50`), and a
  behavioural claim cannot replace it.
- **The docent thread pane survives.** This is the one that matters.

**THE TRAP THIS CARD EXISTS TO AVOID.** On a survey the human stands in the `new` side, so
`:LainThread` computes `OPPOSITE["new"] = "old"` (`51_thread.lua:130`) and the **thread pane IS the
`old` slot** (`:452-458` → `review_place`). Removing `old` from the vocabulary would make
`review_place` refuse by name inside a `define`d command — `error()`, `stack traceback:`, a blocking
`Press ENTER` modal: **round 7's F31 shape, resurrected on the very surface F64, F66 and T5 exist
to fix, and the surface `survey-dogfood-2026-08-25.md` Act 5 is scheduled to drive.**

So: a survey opens `sidebar | file`. The `old` slot stays in the vocabulary, unopened, and is
**opened on demand** when the human asks for a thread — the third window appears only when there is
something to put in it.

**AND THE ON-DEMAND OPEN MUST BE BUILT; IT DOES NOT EXIST (panel, BLOCKER-9).** The first draft
asserted `review_thread.window(slot, path, rebuild=true)` opens it. **It does not.** `window`
(`51_thread.lua:452-458`) delegates to `_G.__lain.review_place`, and `review_place`
(`41_layout.lua:243-256`) does not open either — it passes `index_of` (because `old` is still in the
vocabulary), calls `ensure()`, and then does `nvim_win_set_buf(found[slot], buf)` with
**`found["old"]` nil**, raising `Wrong type for argument 1` inside `define("LainThread")` with no
`pcall`. That is the F31 traceback-and-modal shape again, one line further down.

**The only opener is `review_panes.open(tab, found, slot)` (`41_layout.lua:169-174`), called from
exactly one place: the loop inside `ensure` (`:194-199`).** So this card must give `review_place` a
fallback — when `found[slot]` is nil for a slot that IS in the vocabulary, open it — or give `ensure`
a "plus this slot" argument. **Write it; do not discover it.**

Verified as already correct once that exists: `anchor(tab, found, "old")` → `index_of("old") = 2` →
scans left, finds `sidebar` at 1 → returns `(sidebar, "right")`, so the layout becomes
`sidebar | thread | file`, matching slot order. And `ensure` never closes, so the thread pane
survives later renders.

**Where the fact lives, including the bootstrap (panel, SHOULD-FIX-14).** T4 posts sides on
`set_review`, which precedes the layout. But on the **first** `set_review` there is no review
tabpage — `46_sidebar.lua:88` → `review_place("sidebar")` → `ensure()` *creates* it
(`41_layout.lua:182-190`) — so `vim.t[tab]` cannot be read on the very paint that needs it.
The hand-off: **`set_review` sets `review_panes.sides`** (no new top-level local — `review_panes`
already exists, so the 60-upvalue budget is untouched), **`ensure` writes it through to `vim.t[tab]`
the instant it creates the tab**, and everything reads the tabpage thereafter.
`rpc_thread.rb:88-93` says `set_review` *"lands on every redraw"*, so the value is re-posted
idempotently and cannot go stale. **State why this does not violate `41_layout.lua:34-42`'s own
doctrine** (*"there is no registry to leave stale"*): the module-level value is a one-paint carrier,
never a registry — the tabpage variable is the durable home, and it dies with the tabpage. **The layout decision stays in the
editor** (`rpc_thread.rb:231-234`) — Ruby said what the round is, this card decides what to draw.

**Acceptance criteria:**

```gherkin
Scenario: a survey opens two windows
  Given a survey round
  When a row is opened
  Then the review tabpage holds a sidebar and the file, and nothing else
  And the file window holds the real file on disk
  And no old-side buffer is created for it

Scenario: a changeset review is unchanged
  Given a local-branch review
  When a row is opened
  Then the review tabpage holds sidebar, old and new, left to right
  And both diff sides are in diff mode, as today

Scenario: an added file in a changeset still gets its old window
  Given a local-branch review of a changeset containing an added file
  When that row is opened
  Then three windows are still built
  And the old side is empty, as today

Scenario: an unopened slot is opened on demand rather than raising
  Given a survey opened one-sided, so the old slot is in the vocabulary but not open
  When something places a buffer into that slot
  Then the window is created
  And no error is raised

Scenario: the lone survey window is never put in diff mode
  Given a survey opened one-sided
  Then the file window is not in diff mode
  And it is not diffed against anything after a later render

Scenario: a survey reusing a previous review's tabpage sheds the stale window
  Given a changeset review was opened and settled in this chat
  When a survey is then opened, reusing the same review tabpage
  Then the layout is the survey's two windows
  And the previous review's old side is not left showing

Scenario: the docent thread pane still opens on a survey
  Given a survey opened one-sided
  And a note handed back on a line, so a thread exists
  When :LainThread is invoked on that line
  Then the thread pane opens
  And no error is raised, no traceback is shown, and nvim_get_mode does not block

Scenario: the layout repairs to the round's shape
  Given a survey whose sides were carried on set_review
  And its file window closed by the human
  When the next render happens
  Then the layout is rebuilt with two windows, not three
  # The sides are read from the tabpage, so this holds without a prior <CR>.

Scenario: marking still works from the sidebar
  Given a survey opened one-sided
  When the human marks a row reviewed from the sidebar
  Then the mark lands as it does today
```
→ spec files: `spec/lain/frontend/neovim/layout_spec.rb`,
`spec/lain/frontend/neovim/diff_mode_spec.rb`, `spec/lain/seams/survey_subdirectory_spec.rb`

**Escalation triggers:**
- **`spec/lain/frontend/neovim/layout_spec.rb:395-413` must stay GREEN AND UNMODIFIED.** It pins the
  vocabulary by regexing the Lua source for `SLOTS = { ... }`. Under this card's design `SLOTS` is
  still that literal — if the implementation finds itself needing to change that spec, **the design
  drifted to the shrunken-SLOTS version and must stop.**
- **`review_thread.rediff()` (`51_thread.lua:470-478`) is nil-guarded on the WINDOW, not on the
  ROUND, and will fire on EVERY survey render (panel, BLOCKER-10)** — not in an edge case. On a
  one-sided survey `pane("old")` is nil and skipped, but `pane("new")` is the file window, whose
  `vim.wo[win].diff` is false (this card no longer pairs it) and whose `b:lain_review_side` is still
  `"new"` (stamped at `47_diff.lua:531`) — so it runs `diffthis` on a **single window**, and
  `foldmethod=diff` then collapses the whole file. `refresh`'s bail-out (`:495`) does not save it,
  because the file window IS a review side. This has an AC above; it is not merely a trigger.
- **Two more nil paths in `47_diff.lua` (panel, SHOULD-FIX-15):** `review_diff.pair(wins)`
  (`:385-389`) iterates and would diff one window; `review_diff.landing(old_win, new_win)`
  (`:458-465`) falls back to `return old_win` and `nvim_set_current_win(nil)` raises.
- `review_layout()`'s docstring (`41_layout.lua:217`) claims it returns a window *"for every slot"*.
  Under this card it returns fewer — update it (panel, NIT-12).
- `thread_view_spec.rb:1334-1335` asserts the thread lands in `slots["old"]`. It must keep passing
  for a changeset AND start passing for a survey.
- `41_layout.lua:56-63` and `:123-138`: `index_of` drives `anchor`'s left/right split decision. A
  slot list that varies per round must still produce a deterministic left-to-right order.
- `41_layout.lua:244-247`: `review_place` refuses unknown slots **by name**. A slot absent from this
  round must refuse as clearly as one that never existed.
- `41_layout.lua:29-30` cites the **60-upvalues-per-prototype cap**. Do not add a top-level local.
- `diff_mode_spec.rb:570` pins "treats a missing old side as empty rather than as a truthy value" —
  the per-FILE case, which must survive. If this card's change makes a per-file empty old side
  indistinguishable from a one-sided round, **the seam is wrong** — that distinction is the whole
  reason T4 puts the fact on the source rather than inferring it from `old_lines`.
- If the sidebar's 40-column width or `review_view_spec.rb:489-531`'s row widths depend on three
  windows existing, escalate.

---

### T12 — Make the opened banner name the motion the round actually has   [wave 2] [risk: low]  ✅ LANDED b0cac216

**Depends on:** T4
**Files:** modify `lib/lain/review/opened_banner.rb`, `lib/lain/cli/command/review.rb`,
`lib/lain/cli/command/survey.rb`; modify `spec/lain/review/opened_banner_spec.rb`,
`spec/lain/cli/command/survey_spec.rb`

**`OpenedBanner` has NO access to the round today** (panel, SHOULD-FIX-8) — `.call(headline)` takes a
headline String and nothing else (`opened_banner.rb:48`). Giving it the sides changes the signature
and **both** callers: `cli/command/review.rb:319` and `cli/command/survey.rb:409`. **Both are also
edited by T6**, which is why this card is in wave 2. `opened_banner.rb:29-30` states the reason in
prose — *"Two `<C-w>l`, not one: the slots are sidebar, OLD, NEW"* — and must change with `TEMPLATE`.
**Reuse:** the sides fact from T4; the existing banner text
**Shared-file wiring:** none
**Reachable from:** `Review::OpenedBanner`, rendered into the chat on every `/survey` and `/review`.

The banner teaches `<C-w>l<C-w>l reaches the file where :LainNote annotates` — two hops, because
there are three windows. After T11 a survey has two, and the banner would be teaching a motion that
overshoots into nothing.

`planning/survey-dogfood-2026-08-25.md:68` records a human relying on exactly this instruction
(*"slots are sidebar | OLD | NEW"*), so a stale banner is not cosmetic — it is the documented way in.

**Acceptance criteria:**

```gherkin
Scenario: a one-sided round teaches one hop
  Given a survey round
  When its opened banner is rendered
  Then the motion it names reaches the file window in one hop

Scenario: a two-sided round is unchanged
  Given a local-branch review
  Then its banner names the motion it names today

Scenario: the banner still names the sidebar and the verdict gesture
  Given either round
  Then the banner still names lain://review and :LainReviewVerdict
```
→ spec file: `spec/lain/review/opened_banner_spec.rb`

**Escalation triggers:**
- `spec/lain/review/opened_banner_spec.rb:11-15` pins that the banner **deliberately never advertises
  `:LainReviewDone`**. Do not add it.
- **T6 edits both callers of this banner.** Confirm T6 has landed before editing them, and re-read
  them rather than working from this plan's line numbers.
- `opened_banner.rb:29-30`'s prose explains WHY the motion is two hops. Update it with the template —
  a comment left describing the old layout is the defect this chunk keeps filing.

---

### T13 — Let the corpus ceiling refuse through Bounds, with advice   [wave 2] [risk: medium]  ✅ LANDED 338862d3

**Depends on:** T4 (file-contention only — both cards edit `review/source/corpus.rb`)
**Files:** modify `lib/lain/review/source/corpus.rb`, `lib/lain/review/bounds.rb` (if the advice seam
needs opening); modify `spec/lain/review/source/corpus_spec.rb`, `spec/lain/review/bounds_spec.rb`,
`spec/lain/cli/survey_spec.rb`
**Reuse:** `Bounds#guard!` (`bounds.rb:448-452`) — the shape `refuse_oversized!` currently imitates by
hand; `Partition::ByDirectory`'s own static advice constant (`partition/by_directory.rb:21`).
**NOT `cumulative_advice` or `NARROWING_CANDIDATES`** — the static re-cut rules both out, and pointing
at them would send an executor back into the machinery this card exists to avoid.
**Shared-file wiring:** none
**Reachable from:** `Corpus#initialize` (`corpus.rb:328`) — every `/survey` and `lain survey`.

Two objects own the same ceiling and only one of them can advise. `Corpus#refuse_oversized!`
(`corpus.rb:398-403`) raises in the constructor against the **same `Bounds` instance** the session
gets, so `Bounds#check_cumulative!`'s file-count guard can never fire for a corpus — and with it, the
advice machinery `bounds.rb:44-57` was written for. The corpus message is a hand-written imitation of
`guard!`'s sentence that yields no advice at all.

QA confirmed the consequence: over lain's own `lib/` (742 files) the refusal names the measurement and
the ceiling but **no flag and no subdirectory** — *"survey a subdirectory instead, or raise the
ceiling"*, while `--unbounded` is the flag that raises it and the walk in scope knows every
subdirectory that would fit.

The early refusal itself is **correct and must stay** — QA measured it deciding on a file count alone,
~57ms over a no-op baseline against 742 files (round 11 §2). This card keeps the cheap decision and
gives it the advice.

**Re-cut after panel review (BLOCKER-8): the advice is STATIC, not measured.** The original card
asked for "a narrower scope only when one fits", which is **structurally impossible here and would
have destroyed the property above**. `refuse_oversized!` raises inside `Corpus#initialize`
(`corpus.rb:328`), where **no `Changeset` exists yet** — and `cumulative_advice(view)` needs one.
Worse, `fits?` → `view.partitions` → `Corpus#files` → `#lazy` → `reads.fetch` is a **full streamed
read of every file** (`corpus.rb:456-460`), so the two original ACs could not both hold.

So: route the refusal through `Bounds#guard!` (`bounds.rb:448-452`) so it stops being a hand-written
imitation, and **yield `--unbounded` plus the generic subdirectory remedy**. No measurement, no view,
no walk.

> **CORRECTED DURING EXECUTION (2026-08-25, orchestrator).** This paragraph originally said to yield
> `Partition::ByDirectory`'s own static advice string, and AC 2 below originally read *"the refusal
> names the directory scope as an alternative"*. **Both were false and are struck.** `cli/survey.rb:155`
> builds the `Corpus` — where `refuse_oversized!` raises — and `scope` is not applied until `:191`
> (`session.present(scope:)`), so the refusal fires strictly before any scope exists. **`--scope
> by_directory` cannot lift the corpus ceiling**; a refusal naming it would send a human to a path that
> refuses with a byte-identical message, which is the exact defect class this chunk exists to remove.
> The plan conflated *grouping the display by directory* (a partition strategy over the same file set)
> with *surveying a smaller tree* (a different walk root, which really does reduce the count). The
> shipped advice keeps **"survey a subdirectory instead"** — generic, walk-free, and true — and adds
> **`--unbounded`**, the flag QA found missing. Found by T13's implementer, who implemented the card as
> written and escalated rather than silently overriding a reviewed AC.

**Acceptance criteria:**

```gherkin
Scenario: the file-count refusal names the flag that lifts it
  Given a corpus over the file ceiling
  Then the refusal names --unbounded

Scenario: the refusal names the narrower survey that exists
  Given a corpus over the file ceiling
  Then the refusal says a subdirectory may be surveyed instead
  And it names no partition scope, because a scope cannot lift this ceiling
  And it measures nothing

Scenario: the decision is still reached without walking
  Given a corpus over the file ceiling
  When it is refused
  Then no file's content has been read
  And no hunk has been requested

Scenario: the sentence keeps the shape every other ceiling uses
  Given any ceiling refusal in the review tier
  Then it names the measurement, the ceiling and the alternative
```
→ spec files: `spec/lain/review/source/corpus_spec.rb`, `spec/lain/review/bounds_spec.rb`,
`spec/lain/cli/survey_spec.rb`

**Escalation triggers:**
- `spec/lain/cli/survey_spec.rb:174-196` pins `/2 files.*ceiling of 1.*survey a subdirectory/m` and
  `spec/lain/review/source/corpus_spec.rb:665-690` pins `/6 files.*ceiling of 5/m`. Both change.
- `bounds_spec.rb:385-445` pins that advice is composed **by measuring without reading hunks**. This
  card composes NO advice by measuring — if the implementation starts measuring anything in
  `Corpus#initialize`, it has drifted back to the version panel review rejected. **Stop.**
- **If the advice starts naming a specific subdirectory, stop.** That needs a `Changeset` the
  constructor does not have and a walk the card exists to avoid.

### T14 — Purge stale `--yolo` prose from live code comments and design docs   [wave 1] [risk: low]  ✅ LANDED 12de4d37

**Depends on:** none
**Files:** modify `planning/first-class-concepts.md`

**Narrowed after panel review, second pass (BLOCKER-12): the two lib files are NOT stale and must not
be touched.** Both are already correctly past-tense, and both carry a WHY that the rename would
destroy — which is what this card's own third escalation trigger forbids:

- **`lib/lain/middleware/redact_secret_reads.rb:106-112`** reads *"…round 10 deleted the flag and left
  the behaviour. **Flipping this to deny is deferred to round 11 with its own measurement**, because it
  changes what EVERY unattended run returns for a sensitive read."* That is a **live deferral pointer
  aimed at this very round**, and this chunk is deliberately not taking it (see Open decisions).
  Editing it erases a marker the next chunk needs. **T10 also names this file** — neither card edits it.
- **`lib/lain/cli/wiring.rb:125`** — *"so those three cannot come to disagree about it the way `--yolo`
  once did when it was read twice"* — **is** the reason `attended?` is one reading threaded to three
  collaborators. Rename the citation and the reason evaporates.

So the card is one file. `planning/first-class-concepts.md:163` is the only place that names the
deleted flag as a **present capability** (*"`--yolo`: with per-step snapshots, tier-3 `bash` can run
unattended…"*).
**Reuse:** the vocabulary that replaced it — `Mode` postures (`lib/lain/mode/posture.rb:161-162`),
`/mode auto`, and the `auto_approve` layer. `planning/specs/chunk-qa-round10-one-gate-one-record.md:75-77`
states the three-way distinction (**the FLAG, the mode LAYER, the POSTURE are different things**) and
is the authority for which word replaces which reference.
**Shared-file wiring:** none
**Reachable from:** **deferred: documentation and comments only, constructs nothing.** Recorded in
Open decisions alongside T10.

`--yolo` was deleted in round 10 (`chunk-qa-round10-one-gate-one-record.md` T1), but three live files
still justify present behaviour by pointing at it. A comment that explains today's code by reference
to a flag that no longer exists sends a reader looking for something they will not find.

**This card is scoped by a RULE, not by a string match.** Change a reference only where the
surrounding prose describes **current** behaviour. Twenty-five of the twenty-eight tracked files
matching `yolo` must be left exactly as they are:

| leave alone | why |
|---|---|
| `planning/qa-findings-round9-*.md`, `qa-findings-round10-*.md` | **the historical record.** F63 *was* found under `--yolo`. Editing a findings document falsifies what a round observed. |
| `planning/specs/chunk-*.md` (incl. `chunk-qa-round10-*`) | past plans are records. `chunk-qa-round10` is *the plan that deleted the flag*. |
| `ROADMAP.md:148, 324, 1481, 1488` | roadmap history; item 36 records the deletion itself. |
| `spec/lain/cli_spec.rb:311-335` | a deliberate removal guard. **T8 owns this file** — T14 must not touch it. |
| `spec/lain/cli/command/surface_spec.rb:145-161` | pins that a typed `/yolo` still falls through to an unknown-skill report rather than being silently swallowed. |
| `spec/lain/cli/command/env_spec.rb:26`, `spec/lain/cli/wiring_spec.rb:612` | correctly past-tense comments explaining why a seam is shaped as it is. |
| `spec/lain/cli_spec.rb:596` | `expect(source).not_to include("LAIN_YOLO")` — an active guard. |
| `spec/lain/config/gates_spec.rb`, `spec/lain/config/epics_spec.rb` | **unrelated.** `"yolo"` is an arbitrary *invalid gate-policy name* fixture. Nothing to do with the flag. |
| `planning/hn-agent-landscape-2026-07.md:126` | "yoloAI" is a third-party repo's name. |
| `planning/reviews/2026-07-14-joel-code-review.patch` | a patch file — a byte record of a diff. |
| `lib/lain/config/epics.rb:118` | **a LIB file, and still not the flag** — `"yolo"` is an invalid-gate-policy example, exactly as in `gates_spec.rb`. Called out because an executor scanning lib files will meet it (panel, SHOULD-FIX-17). |
| `lib/lain/cli/wiring.rb:125`, `lib/lain/middleware/redact_secret_reads.rb:106-112` | correct past-tense WHY comments; the second carries a live round-11 deferral pointer. See above. |
| `planning/README.md`, `references/*.md` | tracked repo docs that quote past chunk summaries — the record again. **Not** the vendored `references/repos/` trees, which the escalation trigger excludes separately. |

**28 tracked files match; 1 changes.** If the count of files you are about to edit is not exactly
one, re-read the rule.

**Acceptance criteria:**

```gherkin
Scenario: a live comment explains current behaviour in current vocabulary
  Given lib/lain/cli/wiring.rb and lib/lain/middleware/redact_secret_reads.rb
  Then neither justifies present behaviour by naming a flag that no longer exists
  And each names the posture or mode layer that actually provides it

Scenario: an exploratory design doc names something that exists
  Given planning/first-class-concepts.md's approval-economics paragraph
  Then the coupling it describes is named against the approval posture, not the deleted flag
  And the design bet it records is otherwise unchanged

Scenario: the record is not rewritten
  Given every findings document, past chunk spec, and ROADMAP item that names --yolo
  Then each is byte-identical to before this card

Scenario: the removal guards still guard
  Given the specs that pin --yolo and /yolo being refused
  Then they are untouched by this card
  And the suite still fails if either refusal stops happening
```
→ no new spec; this card changes comments and prose only. The guard specs listed above are the
existing coverage and must remain green **and unmodified by this card**.

**Escalation triggers:**
- **`grep` is a FUNCTION in this repo's agent shells and returns 0 hits for `yolo`.**
  `chunk-qa-round10-one-gate-one-record.md:110-111` records exactly this trap. Use `git grep`, which
  also scopes to tracked files — `command grep -rl` over the worktree returns 127 files, 84 of them
  under `.git/`, `tmp/` and `references/repos/` (vendored third-party trees that must never be
  edited). **Verified 2026-08-25: 28 tracked files match.**
- If a reference sits in prose that is *neither* clearly historical *nor* clearly current, **leave it
  and say so** rather than guessing. Over-editing the record is worse than a stale comment.
- If removing a reference would delete the *reason* a piece of code is shaped as it is (rather than
  just renaming the thing that reason cites), stop — that comment is carrying a WHY, which CLAUDE.md
  says is the only thing comments are for.

---

### T15 — Bring the two user-facing docs up to date with the review tier   [wave 3] [risk: low]  ✅ LANDED e5f9cc1f

**Depends on:** T3, T8, T9, T11, T12, T13 — **T3 is what changes `lain.txt:296`'s `:LainReply` line**
**Files:** modify `docs/commands.md`, `plugin/nvim/doc/lain.txt`
**Reuse:** the doc's existing two-surface structure (shell `lain <subcommand>` vs in-session `/<name>`)
and its flag-table format; `exe/lain:365-386` and `:567-569` for the Thor declarations the doc says it
mirrors; `lib/lain/cli/command/survey.rb:88-89` (`USAGE`) for the in-session spelling
**Shared-file wiring:** none
**Reachable from:** **deferred: documentation only, constructs nothing.** Recorded in Open decisions
alongside T10 and T14.

`docs/commands.md` opens by claiming *"Two command surfaces… Every flag listed here is also in
`lain help <subcommand>`, which reads from the same Thor declarations in `exe/lain`."* It then
documents neither `lain survey`, nor `lain review`, nor `/survey`, `/review` or `/review-submit` —
**the entire review tier is absent**, so the doc's own opening claim is false.

`plugin/nvim/doc/lain.txt` has two statements this chunk falsifies (panel, SHOULD-FIX-10):
`:689` documents the three-window layout and `lain://review/OLD/{path}` — T11 changes that for a
survey — and `:296` says *"`:LainReply {answer}` still answers the OLDEST pending question — not the
one under the cursor"*, which T3 changes.

This is the last card in the plan because it documents things five other cards change: the unknown-switch
refusal (T8), the scope refusal wording (T9), the survey's window layout (T11), the banner's motion
(T12) and the corpus ceiling's advice (T13). Written any earlier it would ship stale.

Scope is **additive**. Do not restructure or rewrite the existing sections.

**Acceptance criteria:**

```gherkin
Scenario: the shell surface documents the survey and review subcommands
  Given docs/commands.md
  Then it documents lain survey and lain review, including the [open] disambiguating verb
  And it lists their real flags, matching the Thor declarations in exe/lain
  And it does not list --permissive for lain survey

Scenario: the in-session surface documents the review commands
  Given docs/commands.md
  Then it documents /survey, /review and /review-submit
  And /survey's flags are the three it actually reads: --scope, --unbounded, --permissive
  And the scope values named are read from the strategy registry, not restated as a literal list

Scenario: what the doc says about the cockpit matches what T11 and T12 ship
  Given the survey entry
  Then it describes a survey opening a sidebar and the file
  And it does not describe a survey opening a diff pair

Scenario: the doc's own opening claim becomes true
  Given the doc's statement that every flag listed is also in lain help <subcommand>
  Then every flag it lists for the review tier appears in that command's help output

Scenario: the nvim help stops describing a layout surveys no longer have
  Given plugin/nvim/doc/lain.txt
  Then its account of the review windows distinguishes a survey from a changeset review
  And it no longer states that a survey opens a three-window split

Scenario: the nvim help stops describing the reply behaviour T3 changed
  Given plugin/nvim/doc/lain.txt's :LainReply entry
  Then it no longer says the reply answers the OLDEST pending question
  And it describes answering the question the row under the cursor names
```
→ no new spec; documentation only. **`plugin/nvim/doc/lain.txt` is a spec-pinned surface**, not
optional tidying: `spec/lain/review/deletability_spec.rb:106` pins its help tags and
`spec/lain/frontend/neovim/review_view_spec.rb:489-531` pins row widths against it.
`spec/plugin/nvim_plugin_spec.rb:42, 494-500` pins the doc-prefix boundary. All must stay green.

**Escalation triggers:**
- If writing the survey entry reveals a flag combination that behaves differently from what T8–T13
  landed, **stop and escalate** — the doc is the check that caught it, and a doc bent to match a bug
  is worse than no doc.
- `docs/commands.md`'s opening claim ties it to `lain help`. If a documented flag is absent from help
  output, fix neither in isolation — escalate, because the two have drifted for a reason.
- Do not document `:LainReviewDone`. `spec/lain/review/opened_banner_spec.rb:11-15` pins that it is
  deliberately never advertised, and T12 carries the same trigger.

## Integration checks

Run after the last wave, by the orchestrator:

1. `bundle exec rake pspec` — full suite green. **Check the example COUNT against the pre-chunk
   baseline**, not just the failure count (CLAUDE.md's `parallel_tests` trap).
2. `bundle exec rubocop -a` then a bare `bundle exec rubocop` — clean. Never `-A`; never name a
   `.toml` on the command line.
3. `cargo test && cargo clippy --all-targets -- -D warnings` — unaffected by this chunk, but the gate
   is the gate.
4. `pre-commit run --all-files`.
5. **Re-drive `survey.md` §7 specifically** — the docent thread pane on a one-sided survey. T11's
   whole design exists so `:LainThread` keeps working there; a traceback or a `Press ENTER` modal is
   round 7's F31 returning and is a **stop-the-chunk** result, not a finding to file.
6. **The `:nvim` seam specs must actually run, not be skipped.** T5, T11 and T3's Lua halves are
   pinned only there — a silently skipped `:nvim` tag would make this chunk ship green with its
   riskiest card unverified. Confirm the tagged examples executed.
7. **Manual: re-drive `planning/qa/scenarios/survey.md`** — the regression gate it now belongs to.
   Specifically re-check, by finding id:
   - **F64** — ask a docent two questions on one thread; the pane must never be left thinking, and
     the docent must not park (T1).
   - **F65/layout** — a survey row opens `sidebar | file`; a branch review still opens
     `sidebar | old | new` (T11), and the banner names the right motion (T12).
   - **F66** — `:LainThread` on a placed-but-unhanded note names the hand-back (T5).
   - **F67** — settle a survey, then `/review <branch>`; it must open (T6).
   - **F68** — a `by_directory` survey outside the project; header and rows agree (T7).
   - **F69** — `lain survey <path> --permissive` names the switch, not `survey open` (T8).
   - **F70** — `--scope commmits` and `--scope commits` read as prose (T9).
   - **the corpus ceiling** — `/survey <lain>/lib` names `--unbounded` and, if one fits, a scope
     (T13). **Re-time it against a `lain help` baseline** — the ~57ms-over-no-op property is what
     T13 must not spend.
8. **Update `planning/qa/README.md`'s findings list** with a line pointing at this chunk as what
   discharges round 11, following the `chunk-qa-round7-constructed-and-consistent.md` precedent.
9. **`fleet N` will still not decrement.** That is this chunk's one knowingly-unfixed finding (see
   Open decisions) — do not read it as a regression.

## Close-out (2026-08-25)

**All fourteen cards landed** (T2 withdrawn before execution). Verified by **round 12**, a manual
re-drive of `planning/qa/scenarios/survey.md` on the real cockpit —
[`../qa-findings-round12-2026-08-25.md`](../qa-findings-round12-2026-08-25.md).

**The result this chunk was built for:** `:LainThread` on a one-sided survey opens the `old` slot on
demand at 80 and 100 columns — **no traceback, no modal, no blocking**. Round 7's F31 shape did not
return to the surface T11 reshaped. F64–F70 and the corpus ceiling all verified FIXED against the
real binary, and the ceiling's no-walk property survived at **+83ms over a `lain help` no-op**, with a
scaling control (735 files ≈ same cost, 1762 ≈ 2.1×) proving it enumerates rather than reads.

**Integration checks:** suite **15899 examples, 0 failures, 15 pendings** against a pre-chunk baseline
of **15749/0/15** — the count GREW by 150 and the pendings are unchanged, which is the check that
matters (`parallel_tests` reports only survivors, so a shrinking count is a dead worker wearing a
pass). `rubocop` 1387 files clean with `-a` correcting nothing; `cargo test` + `clippy -D warnings`
green; **509 `:nvim`-tagged examples genuinely executed**, so T3, T5 and T11's Lua halves are really
verified rather than silently skipped. `git worktree list` and `git branch --list` are back to the
pre-chunk baseline exactly.

**One honest loose end.** A single failure appeared in one `pre-commit run --all-files` (15899
examples, 1 failure) and did **not** reproduce across seven subsequent full-suite runs at both 12 and
7 workers. It was never identified by name, so it is deliberately NOT added to the flake list —
CLAUDE.md's rule is that a flake is recorded by NAME, and a stale or guessed entry reads as "not a
known flake" later, which is worse than no entry. Evidence it is not this chunk's: `git diff
b1927ce7..HEAD` over `lib/lain/supervisor*` and `spec/lain/supervisor*` is **empty** — no card touched
any async, supervisor or reactor path. `bundle exec rake spec:flakes` (16 runs in random orders) is
the tool that would settle it.

**Deliberately unfixed, as planned:** `fleet N` still does not decrement. `status_feed.rb:44-48`
records W3 lifecycle as future work, and giving `@fleet` removal means deciding what "done" means for
an arm — a design question, not a fix. Round 12 confirmed it persists; that is expected, not a
regression.

**Follow-up work found in review and by round 12, none blocking:**

| what | found by |
|---|---|
| `Held#source`/`Held#verdict` + `Held::None` — the outbox walks two Demeter trains | T6 panel |
| a judged-but-unposted `github_pr` round is droppable by `/survey` (widened, not new) | T6 panel |
| `HEAD_SIDE_ONLY` belongs in `review/vocabulary.rb`, deleting the banner→source load edge | T12 panel |
| four runtime modules still refuse on raw `vim.notify` and will modal at 80 columns | T5 panel |
| `unattended` may belong to the SPAWN SITE, not the role, for `researcher` | T1 implementer |
| `ChildBuilder` registers an asker before `granted` decides it may not have one | T1 panel |
| `--scope commits` on an oversized tree answers the ceiling, then fails differently | T13 panel |
| F71 — `unknown skill` leaks `Array#inspect` of Symbols, F70's defect one rail over | round 12 |
| F72 — T7 unified the sidebar onto the path spelling that does NOT resolve from cwd | round 12 |
| P18 — orphaned load-probe spinners; `trap ... EXIT INT TERM` folded into `method.md` | round 12 |

**What the panel caught that a green suite could not.** Five assertions in this chunk passed for the
wrong reason and were found by review: a bracket-regex negative that captured nothing (T9); a
"no refusal raises" assertion that held only at 120 columns while the code raised a modal at 80 (T5);
a hop count that `sides.length` satisfied identically (T12); a `landing` fallback so unexercised that
reverting it left all 162 examples green (T11); and a "sheds the stale window" assertion that passed
with the shedding code deleted, because a different mechanism produced the same end state (T11).
Two cards also shipped comments whose stated REASON was false though the decision was right — both
from an orchestrator lesson propagated to a surface whose mechanism did not reach it. **The rule that
earned its keep: when propagating a lesson between cards, propagate the MECHANISM and make the
receiving card verify it reaches its surface before citing it.**

**One card's acceptance criteria were wrong and were corrected mid-flight**: T13's mandated advice
named `--scope by_directory`, which cannot lift the corpus ceiling because the refusal raises in
`Corpus#initialize` before any scope is applied. See the `CORRECTED DURING EXECUTION` block on that
card. The implementer built it as written, proved the falsity with a real filesystem probe, and
escalated rather than silently overriding a reviewed AC — which is what made it visible.
