# Human-in-the-loop review surface

status: in-progress
commit-mode: orchestrator-commits
language: ruby + lua
panel: Ruby (Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson) ·
Neovim/Lua seats proposed for this chunk (TJ DeVries — plugin idiom and API ergonomics;
Justin M. Keyes — nvim core API contracts, what belongs in the editor vs the client;
Folke Lemaitre — buffer/window lifecycle and lazy loading) — **confirm or replace in review**

## Intent

Build the diff-review surface that `RequestReview::Refusals::NO_DOCUMENT` names as missing:
"`implementation` gates a changeset digest rather than a document, so reviewing it would mean
reviewing a diff, a surface lain does not have."

Delivers three usages from one model: reviewing a local branch, reviewing a GitHub PR (with
comments posted back), and the epic implementation gate. Grounded in
`planning/human-in-the-loop-review-research-2026-08.md`, which carries 7 measured spikes, a
6-project survey, and a decision log with superseded options kept.

Built wide on purpose, so different usages can be explored. **Every capability past the core is
behind a Null and owns its own file, so a part that does not work out is deleted by removing one
file and one wiring line.** §"Deletion map" states exactly what each removal costs.

## Grounding

Verified against the working tree on **2026-08-04 at `2b93046`**. Every `runtime.lua:NNN` citation
below and in the cards is against **`2b93046:lib/lain/frontend/neovim/runtime.lua`**, because T6
splits that file and the line numbers do not survive it, by two parallel exploration
passes plus 7 spikes run in the `spike/review-ui` worktree (`eebb24d`, `36fdc99`, `55677b0`,
`9e0f471`, `3484b56`). Where a doc and the code disagreed, the code won.

**Measured, and the cards rest on these:**

- A unified diff maps to `(path, side, file_line)` in one pass, 2 counters. 1501/1501 new-side
  and 179/179 old-side anchors resolve. **No diff gem or crate is needed.** At work scale (800
  files, 80,800 rendered lines) the parse is 0.26s at 39MB.
- `vim.diagnostic` does **not** track edits (a diagnostic on line 3 stays on line 3 after 2 lines
  are inserted above). Extmarks do. So extmarks own position and diagnostics mirror for display.
- Native diff mode gives real buffers (`buftype=""`, filetype detected), `foldmethod=diff`, `]c`,
  and `inline:char`. nvim owns filler and scroll sync via `diff_set_topline`. The old side works
  as a `nofile` scratch buffer: an extmark in it slides on edit (row 14 → 16), so drift detection
  works on both sides. No LSP attaches to the old side.
- `git range-diff` is the re-review primitive, not `git diff`. At 30 commits after a rebase onto a
  moved base plus an amend, it reported 29 identical and 1 changed in 0.22s, despite all 30 SHAs
  differing. `git diff` between heads reports unrelated base movement.
- GitHub's current model is `path` + `line` + `side` (+ `start_line`, `start_side`). Both tuicr and
  octo converged on it; neither uses `position` for PR-level comments.

**Exact seams (from the grounding passes, with line numbers the cards cite):**

- `RenderQueue` lua stubs at `rpc_thread.rb:20-50`; `RenderInlet` blocking (`post_render`,
  `post_view`) vs non-blocking-with-refusal (`open_compose`, `open_question`, `open_review`,
  `review_refused`) at `:210-243`; `Router#acked` `:307`, `#answered` `:316`; `RpcThread#dispatch`
  `:587`, `#acknowledge` `:596` (route runs AFTER ack), `#answer` `:625` (route FIRST, return
  value is the write's verdict).
- `HumanReplies#routes` `human_replies.rb:314-322`; `#serve_editor_command` `:299-306` turns any
  `StandardError` into `@editor.review_refused(e.message)`.
- `runtime.lua` is injected as ONE file read (`RUNTIME = File.expand_path("runtime.lua", __dir__)`,
  `rpc_thread.rb:426`) and `exec_lua`'d with `[version, protocol, chan]` at `:548-553`.
- `PROTOCOL = "8"` (`neovim.rb:63`) and `RUNTIME_PROTOCOL = "8"` (`runtime.lua:15`) are compared for
  **equality**; bump both together. `spec/plugin/nvim_plugin_spec.rb:247-291` pins every
  `(protocol n)` stamp in `plugin/nvim/doc/lain.txt`, and `:293-310` fails unless every
  `define("name")` in runtime.lua is documented there.
- `Surfaces#post` `surfaces.rb:89-99`; a new read-only projection is a `name => lines` pair from
  `Buffers#initial`/`#updates` (`buffers.rb:267-278`), and a *stamped* one also needs
  `#generation_of` (`:259`). `TimelineView` builds its line→digest index in one pass with the lines
  (`timeline` view `render_chain`), and `InboxView::Renderings` is the generation-stamp reconciler.
- Lua is tested by spawning a real headless nvim per example and asserting through a **second**
  `Neovim.attach_unix` connection. There is no shared nvim helper: `spec/lain/frontend/neovim_runtime_spec.rb`
  and `spec/plugin/nvim_plugin_spec.rb` each define their own harness inline. `:nvim` tag at
  `spec/support/tags.rb:77-101` is opt-**out** (`LAIN_NVIM=0`).
- `Forge::Gh` is read-only today. One subprocess site, `#invoke(argv, on_refusal:)` at `gh.rb:280-286`,
  argv array only. Refusals are **values** (`Answer`), not raises: "gh answering 'no' is data, gh not
  existing is a broken machine" (`:16-28`). A new verb must also be taught to `Gh::Recorded`, whose
  verb set is written in 3 places (`recorded.rb:37-40`, `:89-99`, `:65`).
- Thor subcommands live in `exe/lain`; `subcommand "epic", Epic` at `:300` is the mount precedent.
  Lib commands take defaulted keywords and **return Strings**; only the frontend prints.
- Journal records: guard class in `Guards`, `Data.define ... include Telemetry::Journalable`, then a
  **reopened class** carrying `JOURNAL_TYPE` (constants inside a `Data.define` block land on the
  enclosing module). `spec/journalable_surface_spec.rb` sweeps all 62 includers and asserts
  `journal_type` uniqueness across the whole registry.

**Staleness re-check at execution, 2026-08-04, HEAD `5fe99b9`** (11 commits past the grounding
commit `2b93046`, all of them the concurrent chunk's). Every citation above re-verified and holding:
`runtime.lua` still 1359 lines with 9 `define(` sites, `RUNTIME_PROTOCOL = "8"` at `:15`,
`PROTOCOL = "8"` at `neovim.rb:63`, `RUNTIME` read at `rpc_thread.rb:426` and `exec_lua` at `:548`,
`Gh#invoke` at `gh.rb:280`, the `define(` sweep at `nvim_plugin_spec.rb:293`. Two divergences, both
absorbed rather than escalated:

1. **`lib/lain.rb` line numbers moved.** `lain/forge` is at **`:82`** and `lain/friction` at
   **`:83`**, not `:78`/`:79`. The insertion point is unchanged as a *position* — between those two
   requires — and the file is orchestrator-owned, so this costs nothing. Cards state the neighbours,
   not the numbers.
2. **The concurrent chunk `chunk-guardable-petgraph-propcheck.md` is `status: done`.** Its file lock
   is released, so Open decision 1's stated *reason* (two sessions must not both edit `config.rb`)
   no longer applies. **The decision itself stands**: adding a `[review]` config section is scope
   this chunk did not plan, cost or review, and the follow-up chunk is still the right place.
   Integration check 7 is kept as hygiene rather than as a lock check.

Also noted for T14 and T28: `LainReviewDone` **already exists** (`runtime.lua:882`), so the
word-boundaried doc sweep would let it certify a bare `:LainReview`. T14 adds `:LainReviewOpen`,
which is safe; no card may add a bare `:LainReview`.

**Where docs and code disagreed:** `plugin/nvim/doc/lain.txt:364` says the review editor is
"deliberately left unwired". a card in the epic-wiring chunk wired it (`EpicMount`, `--epic SLUG`). The code won; the doc
line is corrected by T21.

**Concurrent chunk.** `planning/specs/chunk-guardable-petgraph-propcheck.md` is in progress in a
separate session (plan committed at `da9eab7`; **C1 and C2 have since landed** at `0ca7523` and `2b93046`, so
`lib/lain/guardable.rb` exists and `config.rb` is already a unit index). It owns
`lib/lain/config.rb`, `lib/lain/config/*`, `lib/lain/guard.rb`, `lib/lain/guardable.rb`,
`ext/lain/src/*`, `Gemfile`, `spec/support/prop_check_setup.rb`, `spec/support/algebra_generators.rb`,
`spec/lain/gherkin_spec.rb`, `spec/lain/canonical_spec.rb`, and
`spec/support/shared_examples/canonical_laws.rb`. **No card here touches any of them.** The cost is
recorded in Open decisions: this chunk ships with no `[review]` config section.

## Orchestrator contract (plan-specific only)

Shared files (orchestrator-owned, wiring diffs only):

- `lib/lain.rb` — the `lain/review` unit inserts **after `lain/forge` (`:78`)**, before
  `lain/friction` (`:79`). It references `Epic::*`, `Forge::*` and `Telemetry::Journalable` at load.
- `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`
- `exe/lain` — the `subcommand "review", Review` mount (T20 hands back the block)
- `plugin/nvim/doc/lain.txt` — **every card that adds a `:Lain*` command hands back its doc stanza**,
  because `spec/plugin/nvim_plugin_spec.rb:293` fails by name otherwise. Cards state the stanza; the
  orchestrator applies it.
Not orchestrator-owned, but **single-owner by design**: `lib/lain/frontend/neovim/rpc_thread.rb` and
`lib/lain/cli/human_replies.rb` belong to T11, which adds every entry point and route this chunk
needs in one pass. No later card edits them, and that is what keeps waves 3–5 conflict-free. T6
touches `rpc_thread.rb` first, in wave 1, for the `RUNTIME` read alone.

The runtime loader is edited by exactly two cards in two different waves: T6 creates it (wave 1) and
T11 changes `RUNTIME_PROTOCOL` in it (wave 2). Nothing after wave 2 touches it, because modules are
discovered from the directory in sorted order, so every later card adds a lua file and edits no
loader.

**Execution note, 2026-08-04 — worktree fork base.** `isolation: "worktree"` cuts from
`refs/remotes/origin/main` (`cc76ea4`), and local `main` is **176 unpushed commits** ahead of it, so
all six wave-1 worktrees started 176 commits stale. Only T6 detected it, because its card cites
measurable file facts (1359 lines, 9 `define(` sites, `RUNTIME_PROTOCOL = "8"`) that the stale tree
contradicted; the five greenfield cards had nothing to trip over and would have shipped work built
against a tree without `Guardable`. Pushing was rejected as outward-facing and the user's call, and
rewriting the remote-tracking ref was rejected because it would make `git status` misreport what is
pushed. Wave 1 was salvaged by fast-forwarding the three surviving worktrees and re-spawning the
three that auto-removed, each with an authorized `git merge --ff-only main` as step 0. **Waves 2
onward create their worktrees from local `main` directly and spawn without `isolation`,** which
removes the failure mode rather than detecting it. Every brief from here carries a measurable
precondition, not just a card.

Two more worktree facts, learned in wave 1 and worth doing up front from wave 2:
`lib/lain/lain.so` is **gitignored**, so a fresh worktree cannot `require "lain"` until
`bundle exec rake compile` — seed it by `cp` from the primary tree instead, since only a card that
changes Rust needs its own build. And a worktree cut before `683974b` lacks the committed plan doc,
so its full-suite count reads exactly **one lower** than the primary tree's
(`gherkin_spec.rb:428` globs `planning/specs/*.md` into one example per doc). Wave-1 hand-back
counts must be read against a 9538 worktree baseline, not the primary tree's 9539.

**STANDING RULE — any timing in a hand-back must state the box was quiet.** Twice in this chunk a
benchmark was taken while a 7-worker `pspec` was running, and both times it was wrong by enough to
reverse the conclusion rather than merely inflate it: T7 reported its parse at 1.03s against the
spike's 0.26s and concluded it was 4× slower, when best-of-3 on a quiet box is **0.16s** — *faster*
than the spike, while doing strictly more work. CLAUDE.md already warns that single runs vary by
±50% and to take a best-of-N; the missing half is that a number measured under the suite is not a
slow number, it is a meaningless one. Quote best-of-3, say the box was quiet, and say what else was
running if it was not.

**STANDING RULE for every remaining card — closed sets live in `vocabulary.rb`, in the String
form.** This trap formed **three separate times** in this chunk before wave 2 was done, so treat it
as the default failure mode rather than a curiosity:

1. **T1 vs T5 (`SIDES`)** — T1 declared `%i[old new]`, T5 `%w[old new]`. The sets were not equal, so
   `Review::SIDES.include?(anchor.side)` answered **false for a perfectly valid anchor**. Both ends
   coerced at their edges, so nothing broke the day it was written.
2. **T9 (`STATE_MARKERS`)** — Symbol keys again, and this one *already* broke: `present` raised
   `KeyError` when handed `"reviewed"`, the spelling every record stores. `:partial` was declared
   nowhere at all. The hand-back claimed the design avoided the trap; it was the trap.
3. **T26 (`Placement::SUPPORTED`)** — Symbols, declared in `placement.rb`. Flagged by its own
   implementer for a ruling rather than discovered, which is the right instinct.

The rule: **any closed set a value is judged against goes in `lib/lain/review/vocabulary.rb`, in
Strings**, because the journal is the durable artifact and Strings are what NDJSON carries. A
collaborator wanting Symbols **derives** them (`SIDES.map(&:to_sym)`) and a spec pins the two
spellings equal. A set that is genuinely never journaled and never compared against a wire value may
live with its owner — but say so explicitly in the hand-back and expect the panel to test the claim,
because "this one is different" is what the first two also looked like.

Deviations from the default process:

- T6 is a **pure refactor with no behavior change**; its AC is that the existing
  `neovim_runtime_spec.rb` passes unmodified. Review it for mechanical fidelity, not design.
- Cards marked `[deletable]` must leave a green suite when their file and wiring line are removed.
  T25 verifies this mechanically; do not skip it.

## Open decisions

1. **No `[review]` config section in this chunk.** `Guardable` has landed, so the blocker is not it:
   the reason is that `lib/lain/config.rb` is owned by the concurrent chunk and two sessions must not
   both edit it.
   Defaults are constants in `Lain::Review`. A follow-up chunk moves them to `.lain/config.toml`.
2. ~~**The Lua panel seats are proposed, not confirmed.**~~ **SETTLED 2026-08-04 by the T6 panel,
   which replaced two of the three on evidence.** T6 was chunk assembly and a namespace contract
   rather than plugin authoring, so **TJ DeVries had nothing to bite on and Folke Lemaitre less**
   (nothing lazy-loads). The confirmed roster:
   - **Justin M. Keyes — KEPT.** The `lib/` vs `plugin/` boundary is the live question here and he
     produced two findings, including that selene only works on the *concatenated* chunk.
   - **Mike Pall replaces TJ DeVries** — LuaJIT chunk semantics, upvalue and local caps. This is
     exactly what the hand-back's headroom claim got wrong (60 names not 56, 199 not 200, and the
     cap that actually binds is 60 upvalues per function).
   - **Lewis Russell replaces Folke Lemaitre** — extmark and buffer-state discipline, which is what
     T15 (diff mode) and T16 (annotate) are actually made of.
3. **The `:nvim` specs stay in the default suite. Considered and declined, 2026-08-04.** Segregating
   them for a lighter inner loop was raised and measured against. `spec/support/tags.rb:82-87`
   records that they were once opt-in and it hid **97 examples from every pre-commit and CI run**;
   the tag was deliberately flipped to opt-out. Re-measured here: the 2 files this chunk touches are
   55 examples in 3.36s, and against `tmp/parallel_runtime_rspec.log` they are 3.6s of 104.9s, well
   under the 14.7s `worktree_handback_spec.rb` floor that sets the wall. The lighter loop already
   exists as `--tag '~seam'` and `LAIN_NVIM=0`. New cards must not add a third mechanism.
4. **ANSWERED 2026-08-04 by the T19 panel: `Review::Surface` survived as a real port**, with one
   nvim-shaped law and a named way to remove it. The plan said to judge the gem question on whether
   the port survives T9 and T19; it did. The evidence the panel gave, in its order:
   - **T19 changed the adapter to fit the check, never the check.** `MESSAGES` and `check!` are
     byte-identical to what T4 shipped — verified by diff, not asserted.
   - **No nvim-shaped argument entered any of the six messages** — no buffer, no window, no
     generation. The nvim-only concerns (`marked`, `marked_at`, the stamps) were deliberately kept
     **off** the port as extra methods on the adapter.
   - **Three adapters with genuinely different mechanics pass the same laws** — Null, Text, and one
     driving a real editor over RPC.
   - **The one pull is Law #5**: "a String means refused" is `RenderInlet`'s own convention promoted
     to a port law, which Null and Text satisfy only *accidentally* (nil, a byte count) and can
     never exercise the refusing half of. Mild and reversible. Its visible cost is the `#verdict`
     exemption, and **re-expressing the return as a `Review::Answer` value type deletes both** —
     filed as a follow-up.

   So the port is not a shape fitted around nvim. Judge the gem extraction on this basis.

4b. **A separate `lain-nvim` gem is deferred, not rejected.** The coupling is the wrong way round for
   extraction today: the `frontend/neovim` tree references only 8 lain constants outbound, but **13
   files outside `frontend/` reach into it** (`epic/review.rb`, `cli/repl.rb`, `cli/wiring.rb`,
   `cli/human_replies.rb`, `tools/ask_human.rb` among them), so the split would be circular and
   would fragment `lib/lain.rb`. `Review::Surface` (T4) is the port-and-adapter inversion that would
   make extraction mechanical; this chunk is where that pattern gets tested on a small surface. Judge
   the gem question on whether the port survives T9 and T19.
5. **Impacted-code discovery (blast radius, omission set) is NOT in this chunk.** §3.6 of the
   research doc found `scip-ruby` unusable here (Sorbet fork) and `ruby-lsp` not installed under the
   prescribed toolchain. Follow-up chunk, after the ruby-lsp install.

## Deletion map

What removing each optional capability costs. **These are not independent**: two of them nest, and
deleting a parent forces deleting its dependent. T25 reads this table, so the nesting is data, not
prose.

| Capability | Files deleted | Also edited | Forces | Delete-and-run |
|---|---|---|---|---|
| Diagnostics (T17) | `runtime/49_diagnostics.lua`, `lib/lain/review/projection/diagnostics.rb`, `spec/lain/review/projection/diagnostics_spec.rb` | `review.rb`'s require; **`frontend/neovim.rb`'s protocol history** | **Prefill (T22)** | **10731** |
| `/critique` prefill (T22) | `lib/lain/review/prefill.rb`, `lib/lain/review/prefill/finding.rb`, `lib/lain/review/prefill/sidecar.rb`, `spec/lain/review/prefill_spec.rb` | `review.rb`'s require | none | **10774** |
| Thread pane (T18) | `runtime/51_thread.lua`, `lib/lain/frontend/neovim/thread_view.rb`, `spec/lain/frontend/neovim/thread_view_spec.rb` | `frontend/neovim.rb`'s require **and its protocol history**; **`review/surface/neovim.rb`'s `#annotate` and `#thread`** and their spec; `neovim_runtime_spec.rb`'s protocol-9 pin; the manual stanza in `plugin/nvim/doc/lain.txt` | **Docent (T24)** | **10673** |
| Docent (T24) | `lib/lain/review/docent.rb`, `lib/lain/prompt/templates/role/diff-docent.md`, `spec/lain/review/docent_spec.rb` | `review.rb`'s require; `role/catalog.rb`; `spec/lain/role_spec.rb`'s roll call; `cli/wiring/toolset_build.rb`; **`spec/lain/cli/wiring/toolset_build_spec.rb`'s two wiring examples** | none | **10803** |
| GitHub submit (T23) | `lib/lain/review/submit.rb`, `spec/lain/review/submit_spec.rb`, `lib/lain/forge/gh/endpoint.rb` | `review.rb`'s require; `forge/gh.rb` (verb + endpoint require), `forge/gh/recorded.rb` ×2, `forge/journaled.rb`, `forge/intent.rb`, `forge/reconcile.rb`; `gh_parity.rb`, `gh_spec.rb`, `recorded_spec.rb`, **`intent_spec.rb`, `reconcile_spec.rb`** | none | **10800** |
| GitHub source (T10) | `lib/lain/review/source/github_pr.rb`, `spec/lain/review/source/github_pr_spec.rb` | `review/source.rb`'s require; **`cli/review.rb`'s whole pull-request leg** and **eight examples in `spec/lain/cli/review_spec.rb`** | **Submit (T23)** | **10704** |
| Epic gate (T21) | *(none — a revert)* | `RequestReview` refuses `implementation` again | none | not measured |

**Re-derived from the tree by T25 on 2026-08-05, and every row above was verified by actually
deleting it and running the suite.** Baseline **10849 examples, 0 failures, 14 pendings** at
`b3fbada`; the last column is what each cut returned, green, with the arithmetic in
`.handback-T25.md`. The bolded entries are what the previous two versions of this table did not say,
and the machine-readable copy now lives in `spec/lain/review/deletability_spec.rb` — that spec fails
if a path here does not exist, if a file it deletes is not mentioned here, or if a file outside a row
starts naming the capability in code.

There is no `require` line to remove for a **lua** module: T6's loader globs the directory, so
deleting the file is the whole edit. Every **Ruby** unit has one, and a dangling `require_relative`
is a LoadError rather than a missing feature — which is why the lines are named above.

**Three things a reference sweep cannot see, and all three were found by deleting.**

1. **The protocol history in `lib/lain/frontend/neovim.rb` is a comment that two specs read.**
   `spec/lain/frontend/neovim_runtime_spec.rb` asserts every `__lain.` entry point and every
   `:Lain*` command the history names against the *live* runtime. Both lua capabilities publish
   entry points the history lists, so deleting either lua module without editing that comment is a
   red suite — and any scan that strips comments (T18's own row does, deliberately, so that prose
   may cite a capability freely) is blind to it.
2. **`Review::Surface::Neovim` renders `#annotate` *and* `#thread` through the thread pane.** Those
   two are the PORT's messages, so they survive the pane and have to become something: deleting the
   pane is a rewrite there, not a removal. The earlier row's "annotations still work" was true of
   the model and not of the editor.
3. **`spec/lain/cli/wiring/toolset_build_spec.rb` holds two docent examples** that T24 added
   precisely so the wiring line could not be removed by accident, and the row that was supposed to
   remove them did not name the file.

**The docent's catalog and roll-call entries are forced, not optional.** `spec/lain/role_spec.rb`
asserts the catalog and the shipped role templates match **in both directions**, so a template with
no catalog entry is a red spec, and adding the catalog entry then trips the `contain_exactly` roll
call. There is no way to ship a role template without both. Accepted as the right answer rather than
a workaround: the card's premise is that the answerer is a **role**, roles live in the catalog, and a
catalogued role is reachable by `@role` spawn lines and by the bench — which is what makes it a
swappable arm rather than a hardcoded collaborator.

**Two things stay behind when submit goes, deliberately:** `ObservationsOnly`, which closes the same
recording fall-through for `pr_create` and `pr_merge`, and — if the stdin seam is kept — the example
guarding the other four verbs against acquiring one.

**The epic gate is the one row that is not a deletion** and is not covered by T25's examples: it owns
no file, and "make `RequestReview` refuse `implementation` again" is a behaviour change across that
tool's implementation leg and `EpicMount`'s wiring. The spec records the exemption by name so the row
cannot quietly acquire files without somebody noticing.

## Follow-up tickets this chunk owes

Raised by panels, deliberately not taken here to keep scope honest. Each names who found it and why
it was deferred.

1. **`Lain::Git::Runner` — extract the scrubbed git invocation.** T3's panel found this is the
   **fifth** copy of "run git in this repo with the context scrubbed" (`Worktree#git`, `Handback`,
   `Promotion#run`, `ShadowGit#run`, `LocalBranch#git`). It also dissolves the load-order question
   T3 raised (`Isolation::Worktree::GIT_CONTEXT_SCRUB` referenced from a method body because
   `lain/review` loads before `lain/isolation`). **The extraction must parameterize the `-c` pins** —
   `LocalBranch` needs `core.quotePath=false`, `--src-prefix`/`--dst-prefix`/`-U3` that the other
   four do not.
2. **`Lain::Wire` — one concept, currently two tiers.** T5's panel: `Review::Wire` owns the String
   coercions while `Epic::WireInteger` owns the Integer one, so `records.rb` reaches sideways into
   `Epic::` for no domain reason.
3. **`spec/journalable_surface_spec.rb`: run the COLLISION example over all includers via
   `allocate`.** T5's panel verified `klass.allocate.journal_type` answers for 66/66 with zero
   collisions and needs no constructor, retiring the 26-record `unreached` blind spot for the one
   property that genuinely needs global scope. **Fix its `.sort_by(&:name)` at the same time** — it
   raises on an anonymous includer, the same latent hazard fixed locally at `28b6fd6`.
4. **selene must lint the loader's OUTPUT, not per-file.** T6's panel measured per-file linting at
   76 errors / 27 warnings, all false `undefined_variable`, because the modules are only meaningful
   concatenated. The `files: \.lua$` hook sketched in `planning/lua-tooling-2026-08.md` would be pure
   false alarm. No selene config exists in the tree yet either.
5. **`Command`-shaped render entry points.** T11's panel (Linus): three entry points cost nine
   hand-written parallel members when `Command` already is `(lua, args)`; the next surface makes it
   twelve. Deferred so a refactor did not ride along with a BLOCKER fix.
6. **Nothing reads `diff_origin` yet.** T10's panel: AC 4 ("the fallback is reported, not silent") is
   true of the object but not yet of any human or journal. Needs a consumer.
7. **`spec/lain/review/source/local_branch_spec.rb` is the suite's NEW WALL FLOOR** — T10's panel
   measured it at **35.3s against `worktree_handback`'s 28.2s**. CLAUDE.md's Toolchain section
   analyses the floor at length and names `worktree_handback` as it; **that analysis is now stale**.
   Owes a split by concern, and a re-measurement of the numbers CLAUDE.md quotes.
8. **`up_spec.rb:175` flake** — see below.
9. **`open_review` and `review_open` are near-anagrams on one rail meaning unrelated things.**
   T14's panel: `open_review` is Ruby→lua and opens the epic's **prose** document review; `review_open`
   is lua→Ruby and is the **changeset** sidebar's open gesture. Different capability, lifetime, buffer
   variable (`b:lain_review_generation` vs `b:lain_view_generation`) and direction — no mechanical
   collision, and leaving both was ruled correct. But `:h lain-review` lands on the document review
   with no "not to be confused with", and the pair is a reading hazard. Rename one and cross-reference;
   `review_open` was named by T11, so this spans cards.
11. **Adopt `Delta::Git` in the two sources.** T12's panel: `Delta::Git` is the missing object,
    correctly extracted — and `Source::LocalBranch` and `Source::GithubPr` were left holding their
    private `#git` copies. Folds into ticket 1 (`Lain::Git::Runner`), and is the same extraction
    seen from the other side.
17. **The shared extmark namespace defeats "visibly a suggestion", and `open_review` clears it
    wholesale.** T22 split the *diagnostic* namespaces (verified against a live foreign LSP) but
    shares the *anchors* namespace, since splitting it would change T17's lua. Its panel measured
    the cost: nvim 0.12.4 defaults to `virtual_text = false, signs = true`, so a BLOCKER finding,
    the human's own `blocker` note and pyright's error all draw the **identical sign** — and the
    human's note carries `virt_text` while a finding carries none, making **the suggestion less
    visible than the thing it must be distinct from**. Worse, `65_review.lua:26`'s `open_review`
    does `nvim_buf_clear_namespace` on the whole shared namespace: place two findings, re-open,
    refresh, and every finding anchor is gone with both diagnostics vanishing silently while Ruby's
    `Prefill` still believes it holds them. Latent — nothing wires findings into a buffer yet. Fix
    belongs on T17's lua, and is small: `vim.diagnostic.config({...}, ns)` is per-namespace.
18. **The sidecar cannot express a range once T23 lands.** T22 chose one line plus prose extent —
    the right call for a surface whose rendering carriers are single `lnum`s — but justified it as
    "every carrier downstream holds exactly one position", which **T23 falsifies in the same wave**
    by shipping `start_line`/`start_side`. The decision stands; the reason is now dated. Revisit
    when a range genuinely crosses the pipeline.
16. **SEQUENCING CONSTRAINT — two silent wedges must close before anything injects a changeset
    source.** T21's panel found both, and both are unreachable today only because `EpicMount` leaves
    `changesets:` nil: (a) a **cancelled park is an unrecoverable, restart-durable claim** —
    `open_generations` keeps the address with no `review_closed`, every later `implementation` call
    refuses `AlreadyOpen`, and `Review.from_journal` rebuilds it across a restart, with no file, no
    `:LainReviewDone` and no CLI to abandon it; (b) **`NoBindings.bind_changeset_review` returns nil
    where its twin `NoChangesets` refuses loudly**, so a source injected against an unbound rail
    parks forever saying nothing. **T20 is the card that injects a source.** Neither may ship live
    until both close.
14. **Guard `Session#present`, not just the CLI.** T20 wired `Review::Bounds` and its panel confirmed
    it is the only caller in `lib/` and fires before anything is journaled. But the hole is not "a
    review opened elsewhere" — it is **inside the command**: the guard runs once on the flag's
    scope, and **`Session#present(scope:)` is re-callable**, so an injected `Surface::Neovim` whose
    sidebar toggles scope reaches it **unguarded on a session the CLI itself opened**. Inert only
    because nothing binds that leg yet. The universal home is `Session#present`.
15. **`Review::Projection` collides with `Event::Projection`.** T17 flagged it and I kept the name:
    it is fixed outside T17's files by the card path, the deletion-map row T25 reads mechanically,
    and T22's card, so renaming is four lines plus three coordinated edits mid-chunk. Distinct
    namespaces, so Ruby resolves it — a readability cost, not a defect.
13. **T14's walk repeats a split commit's numstat N times.** T29's panel: when `Bounds` splits an
    oversized commit for critique, the resulting chunks share one `sha` **and one full,
    unpartitioned `numstat`**. T14 is landed and renders exactly that figure per commit row, so a
    split commit's `+added -deleted` would appear N times, each claiming the whole. Not urgent —
    nothing wires `Bounds` yet (ticket 10's sibling) — but it must not surprise whoever does.
12. **`Source::LocalBranch:87,117` runs git with the exit status unchecked.** Found while reviewing
    T12, which had the identical shape at `Delta#names` — where the panel showed it rendered
    "git could not answer" as "nothing to re-read". T12 fixed its own; the house pattern remains in
    a landed file, and the same class of silent-empty-answer is available there.
10. **The row object's `#numstat` name collision, resolved by ruling rather than by code.**
    `Changeset::CommitScope#numstat` is an `Array<Source::FileStat>`; T14 assumed an aggregate
    answering `#added`/`#deleted`. Ruled: the commit entry answers **`#added`/`#deleted` as scalars**
    and nothing shadows `numstat`. Worth a look later at whether `CommitScope#numstat` should be
    named `file_stats`, since "numstat" reads as an aggregate to everyone who meets it.

19. **`spec/lain/cli/up_spec.rb:175` is a parallel-suite flake, identified 2026-08-05.** T28's panel
    reproduced the "1 failure in 10763" that its implementer had flagged but could not name, and
    tracked it down: tmux's `pane_current_path` is the pane process's **live** cwd, so under a loaded
    parallel run the second pane's short-lived process has already exited (or has not yet chdir'd) and
    tmux falls back to the *client's* cwd — the worktree root. Seen 1 of 5 full runs at load average
    10.3, and **0 of 30 in isolation** even with a concurrent six-worker suite, so it is a
    parallel-suite race rather than a per-example one. The file is byte-identical to the base tree and
    touches nothing T28 changed. It needs a real fix, not a retry: this is precisely the
    "fewer examples, 0 failures"-adjacent shape the suite's own guidance warns about, and a flake that
    presents as exactly one failure is the most expensive kind to leave lying around.

    **It is a class, not a single spec.** T28's fix round hit a second instance in the same session —
    `spec/lain/frontend/neovim/annotate_spec.rb:84`, `ECONNREFUSED` while attaching to a headless
    nvim socket, count correct at 10769, file byte-identical to base, clean on two later runs. Same
    shape: a **spawn race under load**, where a subprocess the spec depends on has not yet reached
    the state the assertion assumes. So the ticket is not "fix `up_spec`" but "make the specs that
    drive real `tmux`/`nvim` wait for the thing they are about to assert on, rather than for the
    spawn to return". Both instances presented as exactly one failure at a correct example count,
    which is the reason to fix the class rather than paper over the two.

20. **A shipped T18 example flakes under heavy load and the mechanism is unknown.**
    `thread_view_spec.rb` → *"does not re-place the diff on every further move once it is back"*
    fails with `calls[:set_buf]` **1** instead of 0: the restore is counted inside the window the
    shim watches, landing one move later than the example assumes. The diff does come back; the
    count is what is wrong. Observed **3 times in ~130 runs, every one at load average ≥ 15** — zero
    in ~110 runs at load ≤ 12, zero in 18 six-way-concurrent runs, and zero in 25 runs with the
    example instrumented (the extra round trips move the timing).

    Two hypotheses were tested and **refuted**, so nobody re-derives them: that `nvim_command`
    returns before its `CursorMoved` autocmd has run (measured with a counting autocmd registered
    after the module's — **0 late out of 800 motions** at load 6.7 and 8.6), and that it is
    example-order dependent (the failing seed 15936 replayed green three times). It is **not**
    ticket 19's tmux flake — different file, different shape.

    Reported rather than hardened around, which was the right call: **hardening an example whose
    mechanism you cannot name risks hiding a real defect rather than a real race.** Every other
    example covering the same property — including the `:bdelete` variant asserting 0 across three
    column moves — was green in every run.

21. **The protocol history should be data, not a comment** (T25). Two specs parse it with regexes over
    prose, and because it is a comment, **every deletability sweep in the repo strips it** — which is
    how both lua rows came to own a file nothing could see they owned. A
    `PROTOCOL_HISTORY = { "9" => { entry_points: [...], commands: [...] } }` hash would let both specs
    read a structure instead of prose, and would put each lua capability's entry-point list somewhere
    a deletion can find it. This is the single change that would have prevented T25's sharpest finding.
22. **Consolidate T18's deletability `describe` into `deletability_spec.rb`** (T25). It is now
    redundant apart from the manual-stanza and `RuntimeLoader` examples, and a second map is a map
    that can drift from the first.
23. **Decide what `Review::Surface::Neovim#annotate` becomes without the pane, and write it into the
    row** (T25). Today the answer exists only in T25's harness, and the row's "left behind" line is
    false of the editor until it is written down.
24. **`RpcThread#set_thread` belongs to the thread row** (T25). The thread cut currently leaves that
    rail posting into a lua entry point that no longer exists — a green suite over an incomplete
    removal, and **the suite cannot tell you that**, because a notify-delivered post to a missing
    function is silent by construction. Same shape as T18's original BLOCKER A.

25. **The two surfaces disagree about an absorbed commit, and the shared contract cannot see it.**
    Found by the manual pass, 2026-08-05, driving `lain review open main --base c003be8 --scope
    commits` against this repository. `Neovim::ReviewView::NO_HUNKS_HERE` renders
    `(no hunks reachable here)` under a commit the range attributes no file to, and its comment says
    why: *"Rendered rather than left blank so the walk accounts for every commit."*
    `Surface::Text#commit_section` (`text.rb:139`) is
    `([legible(commit.subject)] + commit.files.map { … }).join("\n")` — with no files it renders the
    subject and nothing else. So in the real run **seven of fifteen commits looked like they changed
    nothing**, with no explanation, on the surface a human gets when no editor is attached.

    The shared example group `"a review surface"` never tests it: its only nearby example refuses a
    changeset with no files *at all* (`review_surface.rb:341`). **This is the port's own vacuity** —
    the group pins what both adapters happen to do rather than the property one of them reasoned
    about and wrote down. Either the marker belongs in the shared contract, or the Neovim view's
    comment is describing a house rule that only one house keeps.

26. **`spec/lain/review/deletability_spec.rb` costs 6.82s with ZERO git subprocesses.** T30's
    profiling, 2026-08-05: 6.79s of it is *user* CPU, so unlike every other slow file in this chunk
    the lever is not fixture reuse or spawn count — it is the per-row hardlinking and the repeated
    load. The file landed the same day as the measurement, so nobody has looked at it yet. Worth
    someone's attention precisely because it is the one slow file whose cost shape is different from
    all the others, and the obvious fix (reuse fixtures, batch git) does not apply.

27. ~~**`lain up --nvim -- <chat flags>` builds a broken cockpit, and it is the documented form.**~~
    **FIXED** — `b5fb934`. `Cockpit::SwallowedFlag` refuses a socket beginning with `-` and names
    both spellings that work. The same commit keeps the `-c` payload as
    `execute exists(':LainStart') ? 'LainStart' : ''` rather than `silent! LainStart`, because
    `silent!` is what hid ticket 30 below. Live-verified: `lain up --session qa9 --nvim -- --provider
    ollama` now exits 1 with the sentence and creates no tmux session. The original report follows.

    Found by the manual pass, 2026-08-05, by typing the obvious thing:
    `lain up --nvim -- --provider ollama`. The editor comes up as

    ```
    nvim --embed --cmd set rtp+=… --listen --provider -c if exists(':LainStart') | LainStart | endif
    ```

    `--nvim` is declared `[--nvim=[SOCKET]]` — an **optional-value** flag — so when it is the last
    flag before `--`, Thor hands it the first token after the separator. The socket becomes the
    literal string `--provider`, nvim listens on that address, and the shared socket the whole
    `--nvim` cockpit exists to establish is silently not there.

    Isolated by four runs, identical but for flag order:

    | invocation | `--listen` gets |
    |---|---|
    | `up --nvim --session qa1` | `/run/user/1000/lain/nvim-2347294bf5d0.sock` ✓ |
    | `up --nvim --session qa2 -- --provider ollama` | the derived socket ✓ |
    | `up --nvim=/tmp/qa3.sock --session qa3 -- --provider ollama` | `/tmp/qa3.sock` ✓ |
    | **`up --session qa4 --nvim -- --provider ollama`** | **`--provider`** ✗ |

    So **any** flag between `--nvim` and `--` hides it, which is why nothing caught it: `up_spec.rb`
    drives the cockpit with an explicit socket. `lain up --nvim -- --provider ollama` is precisely
    what a human types, and it is the one arrangement that breaks.

    Worth noting where it sits: `up_spec.rb:175` — the ticket-19 flake — is the example asserting
    *"`--nvim` cockpit splits the chat window into an nvim pane and a chat pane sharing one socket"*.
    The socket is the thing this defect destroys, and the example nearest to it is the one that has
    been failing intermittently all day.

28. **The Neovim approval view the architecture was reshaped for does not exist.** Found by the manual
    pass, 2026-08-05, driving a five-command shell task in the cockpit: the agent parked on
    `approve bash({"command" => "pwd"})? [y/N]` **in the chat pane only**, and the human watching the
    editor saw a stalled agent with no visible reason.

    `Frontend::ApprovalPolicy`'s own docstring says why that is notable: *"This class used to BE
    Gate's policy … It became a surface when the queue took over that seam (I4) … this object is just
    one watcher answering pendings — **which is what lets a second surface (a Neovim view) coexist,
    first answer winning.**"* The seam was deliberately built for that consumer, the comment names it,
    and **there is no `lain://approval` buffer, no `ApprovalView`, and nothing approval-shaped in
    `lib/lain/frontend/neovim/` at all.** The wired set is exactly `tty`, `notifier` (dunst), and
    `auto_surface` (opt-in via `--auto-approve`).

    Same family as everything else this pass found: a seam built for a consumer that was never
    written. Distinct from a question — `ask_human` does have a `lain://question` view — so a cockpit
    user gets the editor for questions and the terminal for approvals, with no sign in the editor that
    anything is waiting.

29. **Every `lain review` run leaves a session the session lister calls "unreadable".** Found by the
    manual pass, 2026-08-05. `lain sessions` reports
    `20260805T135507-31557.ndjson  ?  0 turns  unreadable  -` beside the real chat sessions. The file
    is not corrupt — it is 291 bytes of **valid** JSON holding exactly one record, `changeset_opened`.
    What it lacks is the `{"type":"session", …}` header every readable session opens with, so the
    lister cannot classify it and falls through to "unreadable".

    That is the same shape the exe already names for the bench tier — *"a header-less bench journal is
    not a session"* — reappearing on the review rail, and the word is the problem: a journal of a
    different **kind** is being reported as a journal that is **damaged**, which is exactly what a
    human checks after a crash. Either `lain review` should not write into the sessions directory, or
    the lister should recognise a review journal and label it as one.

    **The right words already exist one command away.** `lain bench variance` meets the identical
    condition and refuses precisely: *"no `session` header record to rebuild a context from"* — which
    names the missing thing and implies no damage. `lain sessions` says "unreadable" for the same
    file. Two commands, one condition, and only one of them tells the truth about it.

30. ~~**The cockpit's editor never lays itself out, because the one-shot fires a moment too early.**~~
    **FIXED** — `f576178`, exactly as the last paragraph proposes: the hook arms on `User LainRender`,
    not `LainAttach`. Not `once`, either — the first render is a single view and a layout placing only
    what exists then would open one column and stop — so it stays armed, `vim.schedule`s past the
    current batch of RPC writes, collapses a burst into one attempt via a `pending` flag, and tears
    the augroup down only once `open_layout` reports it placed something. The pre-existing example
    typed `:LainStart` *after* waiting for every buffer, so it could not see this; the new one types
    it first, as the cockpit does, and went red before green. Live-verified by screenshot: `tabs=2
    wins=4` over `journal | timeline | inbox | request` with no manual `:LainStart`. The original
    report follows.

    Found by the manual pass, 2026-08-05, by taking a screenshot instead of reading a buffer over RPC.
    `lain up --nvim` comes up on the user's own dashboard (`snacks_dashboard`, `[No Name]`),
    `tabs=1 wins=1`, with all six `lain://` buffers present and none of them displayed.

    The chain, each step verified in the live editor:

    - `-c "silent! LainStart"` runs at startup, before any attach, so `M.start()` takes its
      not-yet-attached branch and arms a **`once = true`** autocmd on `User LainAttach`.
    - The runtime fires `LainAttach` last, with `data.buffers = BUFFERS` — **names**, because, in its
      own words, *"the buffers themselves are created lazily by the first render, which each announces
      itself via LainRender."*
    - `open_layout` → `existing_columns` requires `vim.fn.bufnr(name) ~= -1`, deliberately: *"a view
      that has not primed yet is skipped, never conjured."*
    - At `LainAttach` **no view has primed**, so every column is empty, `open_layout` warns
      *"no lain:// buffers to lay out yet"* and returns — **and the one-shot is spent.**

    Evidence: the `lain_plugin_start` augroup holds **0** autocmds (consumed) while `tabs=1 wins=1`;
    running `:LainStart` by hand afterwards immediately gives `tabs=2 wins=4` over
    `journal | timeline | inbox | request`. So the layout code is correct and only its trigger is
    wrong.

    The plugin's own help states both halves of the contradiction without noticing:
    *"Only buffers the runtime has actually created are placed"* and *"If lain has not attached yet,
    the layout opens automatically the moment it does."* At the moment it attaches, none have been
    created. **The trigger should be the first `LainRender`, not `LainAttach`** — that is the event the
    runtime already fires for exactly this, and it is the one that means a buffer now exists.

    Everything downstream of the layout is fine and was checked on screen: columns and splits land as
    configured, `lain://timeline` renders the turn with its role markers and dimmed tool-result lines,
    `lain://inbox` shows `(no questions pending)` once answered, and `lain://request` syntax-highlights
    the live JSON payload.

31. **A second frontend attaching to a live nvim socket kills the first one's reply path, silently.**
    Found by the manual pass, 2026-08-05, first by accident (a read-only probe against the cockpit's
    own socket) and then confirmed deliberately. Attach a second `Frontend::Neovim` to a socket a chat
    is already using, let it exit, and three things are true of the chat that is still running:

    - **`:LainReply` is dead.** The runtime captures the RPC channel id as a lua *upvalue* inside
      `submit_reply`, so the second attach's re-injection repoints it at the newcomer's channel. When
      that channel closes, every reply raises `Invalid channel: N`. `_G.__lain.channel` is `nil` — the
      id is not on the table, so nothing can re-read or heal it.
    - **The inbox blanks.** The second attach renders its own empty state over the live question, so a
      human looking at `lain://inbox` sees `(no questions pending)` while the agent is parked waiting
      for an answer to one.
    - **The only evidence is a traceback in `:messages`.** Nothing reaches the chat pane, no
      notification fires, and the inbox row that would have shown the question is the thing that was
      erased.

    The agent is not wedged — answering in the **chat pane** still works, and does resolve the turn.
    So the failure is confined to the editor, which is exactly where it is invisible.

    This is *why* T31b is a repl command rather than `lain review --nvim=<socket>`: a human's only
    socket is the cockpit's, so the standalone form would have done this to their live chat every
    time. Recorded here because T31c still wants a standalone attach, and this is the hazard that
    card has to answer — an attach to an occupied socket should refuse by name, not overwrite.

32. **Three of the five changeset-review verbs have no lua caller at all.** T31b's finding, verified by
    grepping every `.lua` in the tree, 2026-08-05:

    | verb | lua caller |
    |---|---|
    | `review_open` | `46_sidebar.lua` — `<CR>` / `:LainReviewOpen` |
    | `review_ask` | `51_thread.lua:613` |
    | `review_done` | `65_review.lua` — `:LainReviewDone` (the **epic** rail, not the changeset one) |
    | `review_notes` | `48_annotate.lua:404` — `:LainNoteDone`, the settled batch |
    | **`review_mark`** | **none** |
    | **`review_verdict`** | **none** |
    | `review_annotate` | none — but see below |

    **CORRECTED after the orchestrator re-ran the grep, 2026-08-05.** T31b's table omitted
    `review_notes`, and that changes the shape of the fix. `review_annotate` and `review_notes` land on
    the *same* `review_annotated` hand-off — deliberately, `rpc_thread.rb:727-736` says so — and
    `review_notes` **does** have a caller. So annotation is not missing from the editor; only the
    per-note verb is, and `:LainNoteDone` covers the same ground. `:LainNote` needs no rewiring.

    The genuine gaps are **two**, not three: `review_mark` (no keymap) and `review_verdict` (no
    command). Both are independent of everything else — marking a row and giving a verdict happen in
    the sidebar, which already exists and already draws.

    **But the thing that actually makes `/review` read-only is Ruby, not lua.** `<CR>` → `review_open`
    → `ReviewView#open` → `@changesets.open(path, line)`, and `@changesets` is `Unwired`. That
    collaborator is the keystone: it is what posts `open_changeset(path, old_lines, line, revisions)`,
    which is what `47_diff.lua:268` stamps `lain_review_side`/`revision`/`path` from, which is what
    `:LainNote` requires to place a note at all. So the chain
    **open → diff buffers → annotate → settle** is blocked at its first link, by a missing Ruby object.

    `Review::Surface::Neovim`'s own doc (`:149-158`) already names it and says why it cannot be that
    class: `changesets.open` is driven by a gesture arriving arbitrarily later than the `present` that
    drew the row, so it needs a changeset *held* to answer a later message — the one state that surface
    is defined by not keeping. Split into **T32a** (that object) and **T32b** (the two lua gaps and the
    protocol bump) below.

33. **The editor gesture rail is consumed only DURING a model turn, so at `you>` every gesture is
    silent.** Found by the manual pass on T32b, 2026-08-05, immediately after protocol 10 made `x` and
    `u` sendable. This is the most consequential finding of the pass, because a code review is
    precisely a long stretch of reading and marking with **no model turns in it at all**.

    Measured in a live cockpit, agent confirmed idle at `you>` for 20+ seconds:

    | gesture | agent state | answer |
    |---|---|---|
    | `x` on a sidebar row | idle at `you>` | **nothing, 8s** |
    | `x` on a sidebar row | mid-turn | `hunk-content-v1:… is now reviewed`, ~2s |
    | anything queued while idle | next turn starts | **all of it flushes at once** |

    The gestures are **queued, not lost** — the backlog drains the moment a turn begins, which is how
    the first run of this pass produced six mark confirmations in a burst after an unrelated `say ok`.
    But between turns there is no feedback of any kind: the sidebar deliberately does not redraw a
    mark as a glyph (`Surface::Neovim`'s class doc: the row cannot be redrawn without the changeset),
    so the words on the rail are the *only* signal a mark landed, and nothing is delivering them.

    **The mechanism, in code, not inferred.** `cli/repl.rb:257` is the only caller of
    `HumanReplies#surfaces(task)`, it sits inside `Repl#respond` — the model turn — and its `ensure`
    stops every surface it started. `editor_reply_loop` is one of those two surfaces and is the sole
    consumer of every editor verb. So the consumer's lifetime is exactly one `respond` call.
    `#drain_at_prompt` is **not** the counterpart: it is `/inbox`'s question drain, reached only from
    `Command::Inbox`, and it never touches the gesture rail.

    `HumanReplies`' own doc already names half of this for QUESTIONS — *"#answer_loop's fiber only
    lives DURING a respond() call … so a subagent's `announce` can enqueue a question while the human
    sits idle at `you>` with nothing draining it"* — and `drain_at_prompt` is the answer it built for
    that half. The gesture half has the identical lifetime and no such counterpart.

    Note this is not new with T32b: `review_open`'s `<CR>` has always had it. It was invisible while
    the only two sendable verbs were ones nothing was wired to answer.

    **Fix shapes, in the order they seem worth considering** — this wants a card, and probably a design
    ruling first:

    - a gesture drain at the prompt, `drain_at_prompt`'s shape one rail over (cheapest; matches an
      answer this codebase has already made once, but polls rather than reacts);
    - the editor consumer's lifetime moved off `respond` onto the repl's own `Sync`, so it lives for
      the session rather than for one ask (correct-looking, and the reason it is not obviously right is
      that every existing `.stop` in that `ensure` is there deliberately);
    - the ack answered on the RPC thread instead of the rail — **rejected on sight**, this is the
      "serving gestures must never park the RPC thread" stop condition, established twice.

#### T32a — The diff opener: what `<CR>` on a sidebar row has to reach          [risk: medium]

**Depends on:** T31a, T31b. **Unblocks:** annotation, and therefore the whole review gesture chain.

A new object answering `ReviewView`'s `changesets:` duck — `open(path, line)` → nil on success, a
sentence on refusal. It holds the `Review::Changeset` the round was opened on, reads that file's old
side and both revisions off it, and posts `RpcThread#open_changeset(path, old_lines, line, revisions)`.
Wired where `/review` builds the view (`Command::Review#handover`) and wherever the epic path builds
one, so both rails reach the same object.

- **No protocol change.** `_G.__lain.open_changeset` and `47_diff.lua`'s `pair()` already exist and are
  already spec'd; this card supplies the caller they never had.
- **Escalation:** if answering `open` needs the RPC thread to block, stop — established twice.
  If the object needs the *session* rather than the changeset, the lifetime is in the wrong place.
- The refusal wording `ReviewView::Unwired` currently returns is the acceptance test's counter-example:
  after this card that sentence must be unreachable from a wired review and still reachable from an
  unwired one.

#### T32b — `review_mark` and `review_verdict`: the two verbs no key can send          [risk: low]

**Independent of T32a** — the sidebar already draws, so both gestures have a target today.

- **`review_mark`**: sidebar keymaps sending `["review_mark", [line, state, generation]]`. The state
  **rides the wire** and is never toggled lua-side — `human_replies.rb:554-558` is explicit about why:
  a toggle computed from a rendering that has since moved flips the wrong hunk, silently, because both
  values are legal. So two explicit keys, not one toggle.
- **`review_verdict`**: a command sending `["review_verdict", [verdict]]` on the ANSWERED rail
  (`rpc_thread.rb:735`), so its refusal is what the gesture fails with. The vocabulary is
  `Review::VERDICTS`; `Surface::Neovim::ASK_VERDICT` already names it to the human.
- **The protocol bump**, once, for both: `Frontend::Neovim::PROTOCOL` (`"9"`), `RUNTIME_PROTOCOL` in
  `runtime.lua`, and every stamp in `plugin/nvim/doc/lain.txt` — a spec pins each stamp to the
  constant, so a missed one is a red example rather than a silent drift.

### The manual pass on T31b, 2026-08-05 — what a live cockpit confirmed

Run against a real `lain up --nvim` + ollama `qwen3:4b`, screenshots included, after tickets 27 and 30
landed:

- **`/review spike/gems` works.** The chat answers with the headline and range; `lain://review` draws
  all 8 files as unmarked rows; the statusline reads `lain://review [-]`. The review opens its **own
  tabpage** (T26), leaving the plugin's four-window layout tab intact.
- **The acked gesture rail is live and prompt.** `<CR>` on a sidebar row reaches Ruby and the refusal
  comes back into nvim as a `WarningMsg` within ~2s at an *idle* prompt — no turn required. The
  sentence is T31b's documented one: *"no diff surface is wired to this review, so nothing opens from
  it"*, which is ticket 32's gap answering exactly as designed rather than a new fault. (An earlier
  reading of this as "silent" was wrong — the first gesture landed in a non-sidebar window.)
- **The question round trip works both ways.** The inbox `<CR>` opens `lain://question`; `:w` on it
  with a two-space-indented answer reaches the agent (*"The human answered: pong from the compose
  buffer"*). `:LainReply <text>` from anywhere does the same. A malformed write is **refused, not
  reinterpreted**, naming the line and the grammar — including the `expandtab, shiftwidth=2` hint.
- **The layout fix holds under real use.** `lain_plugin_start`'s augroup is torn down after the one
  successful layout, so the review's own tab is not a second layout firing.

Two rough edges, neither a defect: the review's tabpage opens with two empty windows beside the
sidebar (the diff panes ticket 32's `open` would fill), and a free-text answer must be indented two
spaces under a heading that says *"write your answer below"*.

### The manual pass on T32a + T32b, 2026-08-05 — the whole loop, in a real cockpit

Against `lain up --nvim` + ollama `qwen3:4b`, reviewing a real branch. **Every step worked**, which
is the first time in this chunk that sentence has been true of the editor review:

| step | result |
|---|---|
| `/review spike/gems` | sidebar drawn, 8 files, own tabpage |
| `<CR>` on a row | **diff pair opens** — `lain://review/OLD/Gemfile` + the working-tree file, both `diff=true`, both stamped (`side`, `revision`, `path`) with base and head |
| `:LainNote question <text>` | placed; a bad kind refuses by naming `blocker, note, question` |
| `:LainNoteDone` | settled onto the `review_notes` wire, accepted |
| `x` on every row | 8 rows marked, each acked `hunk-content-v1:… is now reviewed` |
| `:LainReviewVerdict approve` **before** marking | **refused**, naming the unreviewed files *and* `Verdict::Policy::Permissive` as the escape hatch |
| `:LainReviewVerdict approve` **after** marking | accepted |

The diff pair is **stable across renders** — watched over 24s of a live turn, both sides stayed
placed and in diff mode.

**The GitHub PR path, separately, against a real public PR** (`rack/rack#2490`, in a throwaway clone):
bare number, full URL and `--scope commits` all resolve to the same changeset; `--scope commits`
carries the commit subjects; an unknown PR and an unknown branch each refuse on **stderr with exit 1**
and an empty stdout, naming the repository and GitHub's own message.

**One transient, recorded rather than filed as its own defect.** On the first `<CR>` the new side was
built and stamped but not *displayed* — the window held the sidebar instead. It happened in exactly
the circumstance ticket 33 creates: a gesture queued at an idle prompt, flushed in a burst at the same
moment renders were arriving. It did not reproduce during normal mid-turn operation, and ticket 33's
fix removes the burst. Worth re-checking once that lands rather than chasing now.

### CORRECTION, AND IT IS WORSE: THE EDITOR REVIEW HAS **ZERO** REACHABLE CONSTRUCTIONS

The section below says waves 3–5 are reachable "only through an epic's implementation stage". **That
is too kind, and the critique panel caught it.** They are reachable from **nowhere**. Verified
independently by the orchestrator, 2026-08-05:

- `cli/epic_mount.rb:196` defaults `changesets: nil, surface: nil, policy: nil`, frozen into
  `@review_seams` at `:207` and splatted into the tool at `:252`.
- The **only** production call site is `cli/wiring.rb:370`:
  `EpicMount.for(chronicle:, options:, notice:, notify: @notifier, bindings: -> { @replies })` —
  it passes **neither** `changesets:` nor `surface:`.
- So `changesets` resolves to `NoChangesets`, whose `source` returns `nil`
  (`request_review.rb:195`), and `Implementation#hold` hits
  `return Refusals.no_changeset if source.nil?` at `:505` on **every call in every production
  wiring**. `surface:` resolves to `Review::Surface::Null` on the same path.

Nothing but specs has ever passed those seams. **Waves 3–5 shipped an adapter that has never been
connected to anything in any real process** — not gated, not hard to reach: never executed outside
the suite. That is why the manual pass found the whole thing dark, and it reframes every "landed"
verdict in this document: the specs were true, the wiring was absent, and no test in 10865 examples
asserts that a production wiring supplies these seams.

**The code names its own fix**, one line from the omission (`epic_mount.rb:229-237`): *"The seam is
threaded rather than absent so that a caller which CAN answer — the review CLI — turns the half on by
INJECTING one, not by editing this file."* And the late-binding machinery is already proven — the
same constructor takes `bindings: -> { @replies }` as a thunk, resolved at call time, for exactly
this reason. `surface:` and `changesets:` belong on that line.

**This is a bug fix, not a card, and it lands before anything else.** Until it does, nobody has run
this chunk's code end to end in a real process.

### THE GAP THAT MATTERS MOST: YOU CANNOT REVIEW A BRANCH OR PR IN THE EDITOR

**Raised by Joel during the manual pass, 2026-08-05, and it is correct: reviewing a PR or a branch
in the editor — the actual job this chunk exists for — has no entry point.**

There is exactly **one** construction of an editor-bound changeset review in the whole tree:
`lib/lain/tools/request_review.rb:540`, `@bindings.bind_changeset_review(ChangesetReview.new(…))`.
Its immediate context is `Epic::Intake::Prose` and `@review.open(…)` — an **epic review token**. And
`Tools::RequestReview` is structurally an epic tool: its class doc is about `Epic::Home`'s three
documents and `Epic::Review`'s ownership baton, and the changeset leg was added onto it by T21 as the
gate on the epic's *implementation* stage.

So the two halves never meet:

| what you can do | what you get |
|---|---|
| `lain review <branch\|PR>` | a **Text** rendering. No editor, no annotations, no marks, no thread pane, no docent, no submit. |
| annotate hunks, thread panes, docent, submit to GitHub | only inside an **epic's implementation stage** |

Everything wave 3–5 built — the diff pair, extmark annotations, diagnostics, the thread pane, the
docent, the GitHub submit — is reachable only by first having an epic. **A developer reviewing a
colleague's PR cannot get to any of it**, which is the use case the chunk's own Intent describes.

Confirmed empirically: in a live cockpit (`lain up --nvim=… -- --provider ollama`, qwen3:4b resident
on the GPU) the agent answers *"I don't have access to the 'request_review' tool"*, and
`lain epic status` reports no epics in this project. **The startup notice the exe promises — "leaves
request_review out with a startup notice" — never appeared in the chat pane**, so the degrade was
silent as well as total.

**Why it is not a one-line fix, stated honestly.** `CLI::Review`'s class doc already reasons about
this and stops one step short: it will not GUESS an editor from `$NVIM`, because the lua half guards
every entry point on `_G.__lain` and only `lain up` injects it — *"drawing into a plain nvim would
report a success that drew nothing"*. That reasoning is right, and it rules out guessing, not
attaching. The shape that respects it:

1. **`lain review --nvim=<socket>`**, exactly parallel to `lain up --nvim=<socket>` and
   `chat --nvim <socket>`. An explicit socket is a caller "handing a surface in", which is the
   command's own stated bar for attachment, and it removes the guessing objection entirely.
2. **The gesture leg back**, which the same doc says is deliberately absent: an adapter answering
   `open(line, generation:)`, `mark(line, state, generation:)` and `ask(anchor_id, question)` — a
   separate object from `Surface::Neovim` because the port already owns `mark` in the other
   direction. Today the only thing that binds one lives in the chat repl.

That is a card, not a patch. But it is the card that makes the rest of this chunk usable by a human
doing code review, and without it wave 3–5's work is reachable only through a tier most reviews will
never enter.

### THE MANUAL PASS FOUND THE CHUNK'S HEADLINE CAPABILITY UNREACHABLE

**`lain review` was never registered in `exe/lain`.** Found in the first five minutes of the manual
pass, 2026-08-05, by running `lain --help` and looking for it. `Could not find command "review"`.

T20's card names the wiring explicitly — *"**Shared-file wiring:** `exe/lain` — a nested
`class Review < Thor` block plus `subcommand "review", Review` beside the epic mount at `:300`. Hand
back as a diff."* It is **orchestrator-owned**, it was never applied, and T20's worktree and
hand-back were lost with the reboot, so whether the implementer handed it back cannot now be
established. Either way the miss is the orchestrator's.

**Nothing in 10865 examples could see it.** `spec/lain/cli/review_spec.rb` has 28 examples and every
one constructs `Lain::CLI::Review` directly — zero touch the exe. `spec/lain/cli_spec.rb` asserts
option defaults on `chat` and never asserts the command *set*. So the class was proved correct and
proved nothing about being reachable.

**This is T18's BLOCKER A one level out**, and worth naming as a pattern rather than an incident:
a capability that works, is fully specced, and is wired to nothing. There it was `Surface::Neovim`
posting into a lua entry point that refused it silently; here it is a Thor command that was never
mounted. Both were invisible for the same reason — **the seam between the tested unit and the thing
a human actually touches is the one place nobody wrote a test.**

Fixed by the orchestrator: the nested `class Review < Thor` with `default_command :open`, since Thor
owns the first word and a branch named `help` needs `lain review open help` — which
`Lain::CLI::Review`'s own docstring already anticipated and told the exe to carry. Verified by hand:
`lain review open main --base c003be8` renders 27 files at cumulative scope, `--scope commits`
renders the walk, and an unresolvable target exits **1** with the message on stderr, stdout empty and
no backtrace, exactly as `Boundary#render` promises.

**A follow-up worth taking: assert the command set.** One example over `LainCLI.commands.keys` would
have caught this and costs nothing.

## Pre-existing defects found while executing this chunk

Neither was caused by a card here; both are recorded so they are not later pinned on whichever card
is in flight when they next appear.

1. **`spec/lain/review/records_spec.rb` seed flake — FIXED at `28b6fd6`.** The discriminator sweep
   used `klass.allocate.journal_type`, and `journal_type` is `self.class.name.split("::")`, so an
   **anonymous** class raises `NoMethodError`. Spec scaffolding leaves anonymous `Journalable`
   includers reachable from `ObjectSpace`, so it failed on **3 of 4 seeds** under
   `rspec spec/lain/review/` and passed under `rake pspec` only because the workers happened to split
   those files apart. Found by T8 while working on an unrelated card, and verified against the bare
   base commit before being reported. **`spec/journalable_surface_spec.rb:14` carries the same latent
   hazard** (`.sort_by(&:name)` on a possible `nil`), currently unreachable because that scan runs at
   load time — folded into the follow-up ticket for that file.
2. **`spec/lain/cli/up_spec.rb:175` flakes ~1 in 14** — the real-tmux cockpit seam. Isolated by T26,
   which ruled its own module out **decisively rather than statistically**: appending a syntax error
   to `41_layout.lua` fails `layout_spec` 19/21 while leaving `up_spec` at 46/0 five times over,
   because `up_spec` asserts tmux `pane_start_command` strings and never injects the runtime chunk at
   all. Pre-existing race; owed a ticket.

Also seen twice, ambient rather than a defect: a `rake pspec` run aborting under load (once at
`load average: 40`), with clean re-runs at the full count. That is the shape CLAUDE.md warns reads as
"fewer examples, 0 failures" — check the count, then re-run before blaming a card.

## Progress

**Wave 1 — 5 of 6 landed on `main`, 2026-08-04.** Suite `9539 → 9672`, 0 failures.

| Card | Commit | Verdict path |
|---|---|---|
| T5 records | `a2ed5fc` | APPROVE-WITH-FIXES → fix round → APPROVE |
| T1 anchor | `43bcdc8` | REQUEST-CHANGES → fix round → APPROVE |
| T2 hunk | `b06d061` | APPROVE-WITH-FIXES → fix round → APPROVE |
| T4 surface | `1d33f26` | APPROVE-WITH-FIXES → fix round → APPROVE |
| T6 runtime split | `62617c5` | APPROVE-WITH-FIXES → fix round → APPROVE |
| T3 source | *in fix round* | REQUEST-CHANGES (merge-numstat blocker) |

**What the panel caught that six green suites did not.** Five of six cards shipped a test that
**could not fail**, and every one of them was green: T4's ordering law ran three orders in one
example against one memoized subject, so the natural order satisfied the other two; T6's sort pin
stubbed `Dir.children`, which the mutation it existed to catch no longer calls; T5 had three mutants
that killed nothing; T2's mutation harness had been silently no-opping since a rename, reporting six
no-ops as survivals; T3 dismissed a surviving mutant as inert when it was **unfixtured**, and the
missing fixture was hiding a real defect. Two reviewers then found their own probes had gone stale
the same way. The working guard is not "the mutant's target exists" — it is asserting the mutation
**changed observable behaviour** before believing any result, and keeping each mutant **minimal**, so
a kill is evidence about the thing you meant to test rather than about something else the mutant
also broke.

Two rulings went against implementers on evidence: T2's span (the "untestable" claim was testable in
66,000 real `git diff` runs, and the full span broke the card's own position-independence AC), and
T3's `--cc` mutant.

**Waves 2–5, landed 2026-08-04/05.** `main` is `c003be8`, suite **10760 examples, 0 failures** with
T18 applied (10720 without it). The last two:

| Card | Commit | Verdict path |
|---|---|---|
| T16 annotations as extmarks | `ba379be` | APPROVE-WITH-FIXES → fix round → APPROVE |
| T23 GitHub submit | `c003be8` | APPROVE-WITH-FIXES → fix round → APPROVE |
| T18 thread pane | `a176599` | **REJECT** (4 seats) → fix round → landed at 10791 |
| T28 protocol 9 | `0c8e01d` | APPROVE-WITH-FIXES ×2 → fix round → landed at 10800 |
| T24 hunk docent | `b3fbada` | APPROVE-WITH-FIXES ×2 → fix round → landed at 10849 |
| T25 deletability | `8c974bf` | landed at 10865; found the map wrong a third time |

### Rulings — T25's two escalation triggers, and the one claim of its own that is wrong

**Trigger 2 fired: delete-and-run is ~4 minutes for six rows against a 44s wall. Ruled: ship the
boot-based proof, and say what it does not prove.** The card's own trigger says *"a check nobody runs
is a fig leaf; stop and find a cheaper honest proof rather than shipping one that gets excluded"* —
which is exactly what T25 did, and the cheaper proof runs **by default** where the real one would have
been tagged out within a week. What ships boots a hardlinked `lib/` with each row removed; it proves
the tree still loads and that the `forces` nesting is real, and it does **not** prove the suite passes.
That gap is named in the spec rather than papered over. The full delete-and-run stays a manual pass,
and its per-row expected counts are in the table above so anyone can check one in isolation.

**Trigger 1 was a judgement call and T25 was right not to stop on it. Ruled: not a re-cut.**
`Review::Surface::Neovim` reaching into `ThreadView` is an **adapter** naming the editor half it
adapts, which is an adapter's whole job — `Review::Surface`, the port, is the core thing here, and the
port is untouched. T18's own row already lists the adapter as a consumer.

But T25's defect #3 is the consequence, and it stands: `Surface::Neovim` renders **both** `#annotate`
and `#thread` through the pane, so *"Left behind: annotations still work"* was true of the model and
false of the editor — with the pane gone a note is visible nowhere. Those are the **port's** messages,
so removing the pane is a *rewrite* there, not a removal, and T25 says plainly that its 10673 means "a
green tree exists", not "this is the removal". That honesty is the finding.

**One claim of T25's is wrong, and the correction matters because the spec asserts it.** Its defect #1
says the map *table* still named `diagnostics.lua`/`thread.lua` unprefixed. It did not — the table was
corrected at `ef76ae6`, before T25's tree was cut, and `git show` confirms it. The unprefixed names
that remain are in the **card bodies** (T17's and T18's `**Files:**` lines), which is a real defect and
worth fixing, but it is not the one reported. The lesson is the chunk's own: **a scan that finds a
string tells you where the string is, not what it means.**

T24's fix round asked for a ruling before moving its four journal records into
`lib/lain/review/records.rb`, which is where `Review`'s records otherwise live. **Ruled: they stay.**

`records.rb` is shared and **not deletable**. Moving a deletable capability's records there would put
capability-owned content in a file that survives the capability — which is exactly the dangling
reference this chunk keeps finding, and it would add a sixth file to a deletion map whose whole
premise is a small, listable footprint.

The card's own `Surface::Message` decision is the discrimination to keep, and it cuts the other way
for a reason worth stating: **a BOUNDARY object belongs at the boundary and outlives both sides; a
CAPABILITY's records belong with the capability and die with it.** `Surface::Message` is deliberately
*not* in the deletion map, and the deletion arithmetic proves the design — removing the docent leaves
**10763**, which is the pre-T24 baseline of 10760 plus exactly the three `message_spec` examples that
correctly survive.

The cost is honest and was reported plainly: `docent.rb` is now 1056 lines (from 723), about 60%
comment, carrying five concerns. That is a real trade, not a free one, and the reasoning now lives in
the class doc rather than in a hand-back nobody will read again.

### The reboot, 2026-08-05, and what it cost

The box rebooted mid-chunk. Git took a **zero-byte object** (`aaa5ac1`) and HEAD would not resolve;
repaired by removing the empty object and writing the last good commit to `.git/refs/heads/main`,
after which `git fsck` was clean. Separately, **six files were truncated to zero bytes — exactly the
six carrying uncommitted modifications**, this plan document and `CLAUDE.md` among them.

All six were recovered in full from `~/.cache/pre-commit/patch1785920562-2971609`, a stash pre-commit
had written at 05:02, one minute before the reboot. **That is the recovery path worth remembering**:
pre-commit stashes unstaged changes on every commit attempt, so `~/.cache/pre-commit/patch*` holds
the working tree as of the last commit that ran the hook, whether it succeeded or not. Restore is
`git checkout HEAD -- <files>` first (the patch's pre-image is HEAD, not the truncated file), then
`git apply` the stash.

The lesson the chunk already half-knew: in `orchestrator-commits` mode the primary tree accumulates
verified-but-uncommitted work, and that is precisely what a crash destroys. Commit each card as it
verifies rather than batching.

### T18's panel, re-run 2026-08-05 — REJECT, and what four seats converged on

T18's original review ran on 2026-08-04 and its findings were destroyed with the orchestrator's
context by the reboot. Rather than land a high-risk lua card on a review that could not be
reproduced, the panel was **re-run from scratch** against a candidate rebuilt on current `main`
(`lain-t18c`, verified 10760 examples / 0 failures). Four seats: TJ DeVries (plugin idiom), Justin M.
Keyes (nvim API contracts), Folke Lemaitre (buffer/window lifecycle), Sandi Metz (object design and
anti-vacuity). Verdicts are in `.review-T18c/`.

**Three APPROVE-WITH-FIXES and one REJECT; the reject stands.** Two findings would each have failed
the card alone:

1. **The capability does not work on its only production path.** `Surface::Neovim` posts
   `set_thread(anchor.id, …)` — a bare String — where the lua refuses a non-table, and delivery is
   `nvim_exec_lua` **notify**, so the refusal reaches nobody. Ruby is answered `nil`, meaning "it
   landed", and nothing landed. **As merged, an annotation never produces a thread pane.** T19 had
   already landed, so this was live rather than prospective. It went unseen because
   `surface/neovim_spec.rb:501-504` excludes `set_thread` from its real-editor seam on a rationale
   that was true when written and stale by the time it mattered — the exclusion names the one test
   that would have caught it.
2. **A mutation-matrix row reported as *killed* is alive.** The `]]` example measures nvim 0.12.4's
   own markdown ftplugin, which binds `]]` to a next-heading motion landing exactly where the example
   asserts. The implementer had found this and believed plain `normal` closed it; it does not —
   `normal` uses a user mapping *when one exists* and falls through to the built-in when none does.
   So a mutant that unbinds `]]` entirely survives at 40/0.

**What the convergence says.** The panel's strongest signal is not any one seat's depth but where
seats that were looking at different things arrived at the same defect:

| Defect | Seats, independently |
|---|---|
| The wipe AC is vacuous — a wiped buffer leaves `nvim_list_bufs()` by definition, so no implementation can fail it | **four** |
| Anchors and extmarks litter the human's real file buffer, surviving `unstamp` | three |
| `:bdelete` (not `:bwipeout`) leaves a valid husk → `E95` forever, plus one orphan buffer per render | two |
| A cursor move rebuilds a whole review tabpage after the human dismissed the review | two |
| The repair path restores a diff buffer that is no longer in diff mode | two |

The `:bwipeout`/`:bdelete` pair is the sharpest of these: the card's own doc stanza *recommends*
`:bwipeout`, and the neighbouring letter is unrecoverable. Every other lain buffer survives it,
because every other one goes through `20_buffers.named_buf` and is found by name; the thread buffer
is the only one keyed on a buffer variable, and buffer variables do not survive unload.

**Two claims the panel confirmed rather than broke**, both worth keeping:

- **Doing nothing about diff mode is right — on the path the card owns.** `'diff'`, `'foldmethod'`,
  `'scrollbind'` and `'wrap'` really are window-local per buffer, and nvim restores them itself; the
  reader's own side is never disturbed, and the human's own `:diffoff` **survives**, which octo's
  `diffoff!` would have destroyed. The claim was over-*scoped*, not wrong: window-local-per-buffer
  memory dies with the window, so it does not hold on the repair path. The fix is a `diffthis` gated
  on `not vim.wo[win].diff`, which leaves the intact path untouched — verified 41/0.
- **The registry really is gone.** Twenty rounds of five threads sent, walked, wiped and re-sent, and
  thirty changeset re-opens: autocmds constant at 2, keymaps constant, buffer count constant, lua
  heap flat. No module table, no per-thread closure, no per-buffer autocmd. What remains is
  buffer-local and inert. The design argument was right; only the evidence cited for it was not.

**And one methodological finding worth more than any of the fixes.** A seat's first attempt to
measure the `CursorMoved` cost per motion used `vim.cmd("normal! j")` in a lua loop, which fires
`CursorMoved` **zero times for 1000 motions** (20/20 when each motion is its own RPC). The seat caught
it and discarded the number. The published justification for the global autocmd is measured backwards
in the same way: the bail-out body costs ~0.16 µs, while dispatch to a global lua callback costs
~2.8 µs — of which ~0.8 µs *is* the pattern match the comment claims to be avoiding. Not a
performance problem, and no seat called it one. It is **a false `why` in a codebase whose comment
standard is that the why must be true.**

### Ruling — T28's escalation trigger 2 fired, and the answer is NO RENAME

`:LainNote` (T16) is a prefix of `:LainNoteDone` (T17). Both were added by this chunk, and it is the
only such pair among the thirteen commands (checked exhaustively; `:LainReviewOpen` and
`:LainReviewDone` are *not* a pair — neither is a prefix of the other). T28 stopped, as its card told
it to, and handed the decision up with measurements rather than a preference.

**Ruled: keep the names.** The trigger's own stated rationale is one specific hazard — "the doc sweep
is word-boundaried precisely because a longer name would otherwise certify a shorter one" — and that
hazard is now **pinned by a mutant rather than guarded by a precaution**. M7 strips all three
`:LainNote` mentions from the doc while leaving `:LainNoteDone` in four places, and
`nvim_plugin_spec.rb:300` goes red by name. The `\b` is doing real work. Renaming a shipped command
would churn T16's and T17's specs, doc and wire verbs to buy nothing that is not already bought.

Two facts worth keeping from the measurement:

- **nvim is not ambiguous here.** `exists(':LainNote')` = **2**, an exact full match, and an exact
  name beats an abbreviation — so `:LainNote` dispatches to `LainNote`.
- **But `exists(':LainReview')` = 3**, "matches several". So a future command actually *named*
  `:LainReview` would be genuinely ambiguous, where `:LainNote` is not. **That is the constraint to
  carry forward**: the rule is not "no name may be a prefix of another", it is "no name may be a
  prefix of *two or more* without being one of them". The comment claiming "no name is a prefix of
  another today" had gone false and T28 corrected it.

### Four operational traps found while landing T16 and T23

1. **`git stash pop` without `--index` silently un-stages everything it restores.** Used mid-landing
   to compare a linter against HEAD, it left only the three newly-*added* files staged and quietly
   dropped eleven *modified* ones — including `lib/lain/review.rb`. The commit then failed with
   `NameError: uninitialized constant Lain::Review::Submit`, which reads as a code defect and is
   not one. Check `git diff --cached --name-only | wc -l` against the expected count before
   committing.
2. **yard-lint's `Tags/OptionTags` fires on the parameter NAME alone** — `options`, `opts` or
   `kwargs` — regardless of whether a docstring exists. The hook lints only *staged* files, so
   `gh/recorded.rb` carried five of these unseen until T23 staged it. `Unrecorded`'s splat is now
   `**given`: those methods take whatever the caller passed and echo it in the refusal, so they are
   not an options hash whose keys anyone could list, and the name was the thing that was wrong.
3. **A fresh `git worktree` has no `lib/lain/lain.so`** (gitignored), so every spec fails at load
   with `cannot load such file -- lain/lain` until `rake compile`. Copying an existing worktree with
   `cp -a` carries both the `.so` and a warm `tmp/cache`, and is much faster — but see CLAUDE.md's
   `rm .git` trap before running anything in such a copy.
4. **A failed run leaves a runtime log that `parallel_tests` then refuses**
   (`RuntimeLogTooSmallError`, "does not contain sufficient data to sort N test files"). Delete
   `tmp/parallel_runtime_rspec.log` and re-run.

## Waves

Cards are listed below in numeric order; T26 to T29 were added after the first draft and their waves
are stated here, not implied by position.

```
Wave 1: T1, T2, T3, T4, T5, T6                              (no unmet deps)
Wave 2: T7 (←T1,T2,T3), T8 (←T2), T9 (←T4), T10 (←T3),
        T11 (←T6), T26 (←T6)
Wave 3: T12 (←T7), T13 (←T5,T7,T8), T14 (←T11,T26), T15 (←T11,T26), T29 (←T7)
Wave 4: T16 (←T15), T17 (←T15), T18 (←T15,T26), T19 (←T4,T14,T15)
Wave 5: T20 (←T10,T13,T19), T21 (←T13,T19), T22 (←T17), T23 (←T10,T13),
        T24 (←T18), T28 (←T14,T15,T18)
Wave 6: T25 (←T17,T18,T22,T23,T24), then T30 LAST (←everything with a spec)
```

Critical path: **T6 → T26 → T15 → T18 → T24 → T25** (6 links). T6 → T26 → T15 → T18 → T28 is the
same length through wave 5. T15 is the highest-contention node in wave 3 (3 wave-4 dependents), so
schedule it first there; T6 is the highest-contention node overall (4 wave-2 dependents) and gates
everything editor-side, so it is the first card to start.

**Same-wave file check.** The four cards that drive a real nvim each own their own spec file with
their own harness (`layout_spec.rb` T26, `diff_mode_spec.rb` T15, `annotate_spec.rb` T16,
`thread_view_spec.rb` T18) rather than appending to `neovim_runtime_spec.rb`, which only T6 (wave 1)
and T28 (wave 5) touch. `runtime.lua` is edited by T6 (wave 1) and T28 (wave 5) only.

---

## THE EXTMARK CONTRACT — binding on T16, T17 and T18

Established by T15's panel, 2026-08-04, by placing a mark on **every row** and re-opening across nine
buffer shapes (identical, pure prepend, pure append, mid-file change, no-shared-prefix,
no-shared-suffix, mid-file deletion, duplicate lines where the prefix and suffix scans overlap, and
shrink-to-one-shared-line).

**Marks inside a rewritten span MOVE rather than invalidate.** `get_extmark_by_id` still answers a
position; it never reports invalid. (The extreme case — every mark landing one row past the last
line — belongs to a *full* rewrite, which T15's refill no longer performs; the span is now bounded
by the shared prefix and suffix. The movement property holds regardless of how narrow the span is,
which is why content comparison is the rule rather than an abundance of caution.)

**So drift is detected by comparing CONTENT, never by asking whether a mark survived.** A card that
tests mark validity will read "still there" for a mark that now names a different line — which is the
silent-wrong-answer shape this chunk keeps finding, in the one place a human would trust it most.

This is inherent to `set_lines` and is now confined to the changed span: marks *outside* it hold
their rows in all nine shapes, on both sides. Two further facts wave 4 depends on:

- **Two identical re-opens bump no `changedtick` at all** — T15's refill writes nothing when the
  content matches, so `on_lines` does not fire. T16's drift detection can rely on that silence.
- The old side is a `nofile` scratch buffer and the new side is the real file, but **both now behave
  the same way under refill**; the asymmetry that made only the old side lose marks is closed.

## Standing obligations on every lua card (T14, T15, T16, T18)

Added during execution from the T11 panel, 2026-08-04. T11 owns the Ruby half of the RPC surface
and **cannot** discharge either of these; they belong to whichever card writes the lua.

1. **"The human's text is untouched" is YOUR obligation, not T11's.** T11's AC says a malformed
   `review_annotate` must fail the write and leave the human's text intact. Ruby only ever responds
   `(id, nil, error)` — whether `:w` actually fails and `'modified'` survives is decided entirely in
   lua: a `pcall` around `vim.rpcrequest`, and **no unconditional `nomodified`**. Without that, the
   AC reads as met over a buffer that clears anyway, which is worse than not claiming it.
2. **The wire shape is `[verb, [one, array, of, args]]` — never flat positionals.**
   `65_review.lua` records that flat positionals silently dropped a payload once, and the T11 panel
   found the Ruby guard raised `NoMethodError` *inside itself* on that shape (now fixed to refuse it
   by name). The panel's judgement: this is "precisely the mistake those cards are most likely to
   make". Send the array.

## Tasks

### T1 — Define the review anchor as a value object          [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/review/anchor.rb` (new), `lib/lain/review.rb` (new, the unit index),
`spec/lain/review/anchor_spec.rb` (new)
**Reuse:** `lib/lain/epic/review/annotations.rb` for the drift rule (`anchor_text` against the line
the number now names); `Lain::Telemetry::Journalable` for the wire shape; `Data.define` + deep-freeze
idiom from `lib/lain/telemetry/*.rb`.
**Shared-file wiring:** `require_relative "lain/review"` in `lib/lain.rb`, after line 78
(`lain/forge`), before line 79 (`lain/friction`).

An anchor names one reviewable position: `(path, side, line, anchor_text, revision, id)`. `side` is
`:old` or `:new`. `id` is a UUID generated when absent and **accepted when supplied**, because replay has to restore
the one the journal recorded (research §5.2). It is deliberately **excluded from equality**: two
anchors at the same position must collapse under `uniq` and match in a `Set`, or reconciliation
cannot recognise the same anchor twice. `revision` names which diff
the anchor was authored against, which §7.4b records as a live bug in tuicr when it is implied
rather than stored.

**Acceptance criteria:**

```gherkin
Scenario: an anchor is deeply frozen
  Given an anchor built with a path, side, line, anchor text and revision
  Then it is deeply frozen

Scenario: two anchors at the same position are equal
  Given two anchors built with identical path, side, line, anchor text and revision
  Then they are equal, hash alike, and collapse under uniq

Scenario: an id is generated when absent and preserved when given
  Given an anchor built without an id
  Then it has one
  Given an anchor built with an id read back from the journal
  Then it reports that id

Scenario: drift is anchor text against the line the number now names
  Given an anchor on line 14 whose anchor text is "  @store.write(input)"
  When the document at line 14 now reads "  @store.write(validated)"
  Then the anchor reports drifted

Scenario: an unknown side is refused loudly
  When an anchor is built with side :both
  Then Lain::Review::Anchor::UnknownSide is raised naming :both
```
→ spec file: `spec/lain/review/anchor_spec.rb`

**Escalation triggers:**
- `spec/lain/epic/review/annotations_spec.rb` pins a drift rule that contradicts this one (e.g. a
  different definition of what counts as drifted for a deleted line) — stop and reconcile before
  writing a second rule.
- Deep-freezing fails because `Symbol#to_s` or string interpolation returned a mutable String, which
  CLAUDE.md records as having broken this once — confirm the fix matches the existing pattern.
  Use the `be_deeply_frozen` matcher, whose own comment says it is "the ONLY spelling" of this check
  and that a companion `Ractor.shareable?` assertion is the same claim written twice.
- Research open question 1 says the drift model "still needs its own spike before the first slice
  fixes a shape — specifically whether `anchor_text` alone is enough, or whether before/after
  context lines are wanted". This card fixes `anchor_text` alone. If a spec needs surrounding
  context to disambiguate, stop: that is the open question arriving, not a detail.

---

### T2 — Give a hunk a content-addressed review key          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/review/hunk.rb` (new), `spec/lain/review/hunk_spec.rb` (new)
**Reuse:** ~~`Lain::Digest`~~ **`Lain::Ext.blake3_hex`** for the hash — corrected during execution:
there is no `Lain::Digest`. `Canonical.digest` (`canonical.rb:60`) is the only other caller and it
wraps the same primitive with a `blake3:` prefix, but this card must not route through `Canonical`
for the reason stated below. tuicr's scheme (research §4.4), reimplemented, not copied.
**Not** `Lain::Canonical`: a hunk body is already a byte string, and `Canonical` canonicalises
JSON-native structures, so routing bytes through it buys nothing and risks normalising away a
difference the key must keep.
**Shared-file wiring:** `require_relative "review/hunk"` in `lib/lain/review.rb` (T1 creates it).

The key hashes the hunk's own text **including `+`/`-`/` ` origin markers and excluding the `@@`
header**, so it is position-independent: an unrelated edit above a hunk must not clear its reviewed
state. Carry a `hunk-content-v1:` prefix so the scheme can change without corrupting old sets. When
a file contains duplicate identical hunks, fall back to a span-qualified key, because a pure
occurrence count moves reviewed state onto the wrong duplicate when one of them changes.

**Acceptance criteria:**

```gherkin
Scenario: the key ignores position
  Given a hunk at old line 10, new line 10
  When 500 unrelated lines are inserted above it and the hunk header changes
  Then its review key is unchanged

Scenario: the key changes when the hunk content changes
  Given a hunk whose body is "+  audit!(input)"
  When the body becomes "+  audit!(validated)"
  Then its review key differs

Scenario: duplicate hunks in one file get distinct keys
  Given a file containing two byte-identical hunks
  Then their review keys differ and both carry the span-qualified prefix

Scenario: the scheme version is part of the key
  Then every key starts with "hunk-content-v1:" or "hunk-span-v1:"
```
→ spec file: `spec/lain/review/hunk_spec.rb`

**Escalation triggers:**
- Two textually different hunks hash equal. The key must distinguish them; if any normalisation has
  crept in between the bytes and the digest, stop and remove it.
- The duplicate-hunk fallback needs the `@@` header to disambiguate, which reintroduces position
  dependence — stop and confirm the tradeoff rather than silently accepting it.

---

### T3 — Introduce the changeset source port with a local-branch implementation   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/review/source.rb` (new), `lib/lain/review/source/local_branch.rb` (new),
`spec/lain/review/source/local_branch_spec.rb` (new),
`spec/support/shared_examples/review_source.rb` (new)
**Reuse:** `Mixlib::ShellOut` behind a `shell_out_factory` keyword, exactly as `Forge::Gh#invoke`
does (`gh.rb:280-286`) — argv array, never `sh -c`; the `spec/lain/isolation/` specs for the
real-git-in-a-tmpdir pattern.
**Shared-file wiring:** `require_relative "review/source"` in `lib/lain/review.rb`.

A source answers `#diff` (raw unified diff bytes), `#commits` (ordered, each with sha, subject,
body, and its own numstat), `#base_ref` and `#head_ref`. `LocalBranch` shells out to
`git diff <base>...HEAD`. The three-dot form compares against the merge base, and the spike found
that getting this wrong shifts every old-side anchor, so the merge base is resolved explicitly and
recorded rather than implied.

The shared example group is the port's contract and every future source must pass it. That is what
makes T10 a small card.

**Acceptance criteria:**

```gherkin
Scenario: the source resolves the merge base rather than the named base
  Given a feature branch and a base branch that has advanced independently
  When the source is asked for its diff
  Then the diff excludes the base branch's independent commits
  And the source reports the merge base sha as its base_ref

Scenario: commits arrive in the order they will be walked
  Given a branch with three commits
  Then #commits returns them oldest-first with subject and per-commit numstat

Scenario: a source refuses loudly when the base ref does not exist
  When the source is built against a ref that does not resolve
  Then Lain::Review::Source::UnknownRef is raised naming the ref

Scenario: any source satisfies the port contract
  Then it behaves like "a review changeset source"
```
→ spec files: `spec/lain/review/source/local_branch_spec.rb`,
`spec/support/shared_examples/review_source.rb`

**Escalation triggers:**
- `git diff A...B` in the repo's git version does not resolve the merge base as the spike measured
  (spike `diff_map.rb` verified 179/179 old-side anchors against it) — stop; every old-side anchor
  depends on this.
- An existing spec already shells out to git with a different factory seam name than
  `shell_out_factory` — stop and use the existing name rather than adding a second convention.

---

### T4 — Introduce the surface port with a Null implementation          [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/review/surface.rb` (new), `lib/lain/review/surface/null.rb` (new),
`spec/support/shared_examples/review_surface.rb` (new), `spec/lain/review/surface/null_spec.rb` (new)
**Reuse:** `Lain::Sink::Null` as the Null Object exemplar (CLAUDE.md names it); `Frontend::Neovim`'s
existing refusal-string convention (`RRenderInlet::REVIEW_DETACHED`) for how a surface declines.
**Shared-file wiring:** `require_relative "review/surface"` in `lib/lain/review.rb`.

The port is the seam that lets the UI be rebuilt without touching the model. Messages:
`#present(changeset, scope:)`, `#annotate(anchor, text, kind:)`, `#mark(hunk_key, state)`,
`#thread(anchor)`, `#verdict`, `#refuse(message)`. `Null` satisfies all of them and does nothing,
so every model spec runs without spawning nvim.

**Acceptance criteria:**

```gherkin
Scenario: the Null surface satisfies the whole port
  Then Lain::Review::Surface::Null behaves like "a review surface"

Scenario: every port message is accepted and discarded
  Given the Null surface
  When each port message is sent with valid arguments
  Then none raises and each returns nil

Scenario: an incomplete surface is refused when checked
  Given an object answering every port message except #verdict
  When Lain::Review::Surface.check!(it) runs
  Then Lain::Review::Surface::Incomplete is raised naming :verdict
```
→ spec files: `spec/lain/review/surface/null_spec.rb`,
`spec/support/shared_examples/review_surface.rb`

**Escalation triggers:**
- The port needs a message that only makes sense for nvim (a buffer number, a window id) — stop; that
  is the seam being wrong, and the shared example group would encode the leak permanently.
- `Surface::Incomplete` duck-checking conflicts with an existing repo convention for verifying
  collaborators (search for how `Effect::Handler` validates its duck) — stop and use the existing one.

---

### T5 — Declare the review journal records          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/review/records.rb` (new), `spec/lain/review/records_spec.rb` (new)
**Reuse:** `lib/lain/epic/records.rb` for the record shape (`Data.define` with
`include Telemetry::Journalable`, then a **reopened class** carrying `JOURNAL_TYPE`), and
`Epic::WireInteger` for integer coercion off the wire. **For validation use `Lain::Guardable`'s
`guard do … end` block on the value class** — it landed at `0ca7523` and is the idiom the repo is
migrating to; do not add a sixth consumer of the old `Guards` class-per-record mechanism.
**Shared-file wiring:** `require_relative "review/records"` in `lib/lain/review.rb`.

Four records: `ChangesetOpened` (source, base_ref, head_ref, digest), `HunkMarked` (hunk_key, state),
`ReviewVerdict` (verdict, changeset digest), `AnnotationPlaced` (anchor id, path, side, line,
anchor_text, text, kind, drifted, revision). The existing `Epic::Annotation` stays as-is; this is the
changeset-shaped sibling, and §7.4b requires `revision` on it.

`journal_type` must be unique across all 62 existing includers, which
`spec/journalable_surface_spec.rb` asserts globally.

**Acceptance criteria:**

```gherkin
Scenario: every record round-trips through a real journal
  Given each of the four review records
  When written to a Lain::Journal and read back
  Then the parsed record equals what was written

Scenario: journal_type is the underscored basename and matches JOURNAL_TYPE
  Then each record's journal_type equals its class's JOURNAL_TYPE constant

Scenario: a malformed record is refused at construction, not at read time
  When an AnnotationPlaced is built with a negative line
  Then a guard error is raised naming the line field

Scenario: the discriminators do not collide with any existing record
  Then spec/journalable_surface_spec.rb passes with the new records loaded
```
→ spec file: `spec/lain/review/records_spec.rb`

**Escalation triggers:**
- `journal_type` for any new record collides with one of the 62 existing includers — stop; the global
  uniqueness assertion in `spec/journalable_surface_spec.rb:26-32` is the arbiter and renaming is a
  design decision, not a mechanical fix.
- A constant defined inside a `Data.define ... do` block is not visible on the value class — this is
  the documented trap; reopen the class instead, do not work around it.
- `Guardable` cannot express a validation these records need, so the old `Guards` shape looks
  necessary. Stop: that is a finding about `Guardable` and belongs to the concurrent chunk's owner,
  not a silent fork of the mechanism.

---

### T6 — Split the injected runtime into modules          [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime.lua` (becomes the loader),
`lib/lain/frontend/neovim/runtime/` (new directory: `folds.lua`, `buffers.lua`, `journal.lua`,
`compose.lua`, `question.lua`, `review.lua`, `inbox.lua`, `timeline.lua`),
`lib/lain/frontend/neovim/rpc_thread.rb` (the `RUNTIME` read only),
`spec/plugin/nvim_plugin_spec.rb` (the `define(` scan, which this card breaks)
**Reuse:** the existing `_G.__lain` table as the shared namespace between modules; `named_buf`,
`editable_buf`, `set_lines`, `claim`, `bind_motions` become the `buffers.lua` exports.
**Shared-file wiring:** none.

`runtime.lua` is 1359 lines and every later card would otherwise collide in it. Splitting first is
what makes waves 3–5 parallel, and it is what makes a capability deletable by removing one file.

The injection is one `exec_lua` of one string (`rpc_thread.rb:426`, `:548-553`), so the loader
concatenates its modules at read time rather than using `require` (there is no `package.path` for an
injected chunk). **Pure refactor: no behavior change.**

Concatenation order matters, and a hardcoded module list would make the loader a file every later
card has to edit, which would serialize waves 3 to 5. So modules carry numeric prefixes
(`00_buffers.lua`, `10_folds.lua`, …) and the loader globs the directory in sorted order. Adding a
module is adding a file. Leave gaps in the numbering for later cards.

**Acceptance criteria:**

```gherkin
Scenario: the existing runtime spec passes unmodified
  Given spec/lain/frontend/neovim_runtime_spec.rb with no edits
  When the suite runs
  Then every example passes

Scenario: every module the loader names is present at injection
  Given the runtime is injected into a headless nvim
  Then _G.__lain exposes render, set_view, set_request, set_compose, set_question,
       open_review and review_refused

Scenario: the protocol handshake is unchanged
  Then vim.g.lain_rpc_version equals Lain::Frontend::Neovim::PROTOCOL

Scenario: the command sweep still finds every command after the split
  Given spec/plugin/nvim_plugin_spec.rb's "documents every command the runtime defines"
  When it scans the runtime for define(...) sites
  Then it finds LainPin, LainOpen and LainSend
  And every command it finds is documented in plugin/nvim/doc/lain.txt

Scenario: modules are discovered from the directory, not a list
  Given a new numbered module file added to runtime/
  When the runtime is injected
  Then its contents are present and the loader was not edited

Scenario: concatenation order is deterministic and by prefix
  Given modules 00_buffers.lua and 10_folds.lua
  Then the injected chunk contains 00_buffers before 10_folds
  And the order does not depend on filesystem readdir order

Scenario: an empty runtime directory fails loudly rather than injecting nothing
  Given runtime/ contains no module files
  When the runtime is injected
  Then the failure names the empty directory
```
→ spec file: `spec/lain/frontend/neovim_runtime_spec.rb` (unmodified),
plus `spec/lain/frontend/neovim/runtime_loader_spec.rb` (new, for the loader itself)

**Escalation triggers:**
- Any existing example in `neovim_runtime_spec.rb` needs editing to pass. **Stop immediately.** This
  card's whole contract is that it changes no behavior; an edit there means the split changed
  semantics.
- Concatenation order matters in a way the current single file hid (a local used before its
  definition) — stop and record the real dependency order rather than reordering by trial.
- `spec/plugin/nvim_plugin_spec.rb:232-242` forbids buffer/RPC tokens in the *plugin* tree; confirm
  the new `runtime/` directory is under `lib/`, not `plugin/`, before writing a line.
- `spec/plugin/nvim_plugin_spec.rb:293-310` does `File.read(".../runtime.lua")` and scans
  `/define\("(\w+)"/`. All nine `define(` sites move into `runtime/*.lua`, so that scan returns `[]`
  and the example fails. Generalising it to read the directory is **in this card's scope**; if
  generalising changes what it asserts rather than where it reads, stop.
- Two modules each declaring `local function named_buf` shadow **silently** — no load error, and a
  "no behavior change" contract cannot detect it. Lua linting was deferred out of this chunk
  (`planning/lua-tooling-2026-08.md`), so this card runs the check **once, by hand**, as evidence
  rather than as tooling: `cargo install selene`, write the 7-line `neovim.toml` std that doc
  records, and confirm 0 errors on the concatenated output. A measured probe found selene reports
  `shadowing` on a duplicated local and `undefined_variable` **as an error** for a reference lost in
  a split — the two failures this refactor can otherwise ship green. Paste the output in the
  hand-back; do not add the tool to `.pre-commit-config.yaml` here.
- A Lua chunk caps at 200 locals and `runtime.lua` already has 56 top-level ones. If the
  concatenated chunk approaches that, stop rather than discovering it at attach time.
- `runtime.lua:8` is `local gem_version, protocol, chan = ...`. Varargs are legal only in the main
  chunk, so no module may be wrapped in a function without threading those three explicitly. State
  which shape was chosen.

---

### T7 — Build the changeset from a source          [wave 2] [risk: medium]

**Depends on:** T1, T2, T3
**Files:** `lib/lain/review/changeset.rb` (new), `spec/lain/review/changeset_spec.rb` (new)
**Reuse:** **promote `spike/review-probe/diff_map.rb` from the `spike/review-ui` worktree** — it is
the verified parser (1501/1501 and 179/179 anchors resolving, 0.26s at 80,800 lines). Do not rewrite
it; port it, keeping the three predicates (`context?`, `addition?`, `deletion?`) that made the
counters correct.
**Shared-file wiring:** `require_relative "review/changeset"` in `lib/lain/review.rb`.

A changeset is files → hunks → anchorable lines, plus per-commit grouping. Include `Enumerable`.
Return an `Enumerator` from the line walk rather than materializing 80,800 rows a caller may not
want.

**Acceptance criteria:**

```gherkin
Scenario: every new-side anchor resolves against the working tree
  Given a changeset over a branch with 3 modified files
  Then each new-side anchor's anchor_text equals that line in the file on disk

Scenario: every old-side anchor resolves against the merge base
  Given the same changeset
  Then each old-side anchor's anchor_text equals that line at the merge base revision

Scenario: the line walk is lazy
  When #each_anchor is called without a block
  Then an Enumerator is returned and no diff parsing has occurred

Scenario: a changeset groups its hunks by commit
  Given a branch with 3 commits touching overlapping files
  Then #by_commit yields 3 groups whose hunks sum to the cumulative hunk count
```
→ spec file: `spec/lain/review/changeset_spec.rb`

**Added during execution (T8 panel, 2026-08-04): THIS CARD OWNS THE FILTERED/UNFILTERED
DISTINCTION, and it must be structural.** T8's card says "reconciliation always runs against the
unfiltered changeset", and T8 implemented everything its own surface allowed — no `scope:`
parameter, no flag reinvented, batch keying, base pinned. The panel then showed that is **a naming
convention, not an enforcement**: a filtered changeset is structurally indistinguishable from a
total one (same class, no `#scope`, no `#filtered?`), and `reconcile(filtered)` silently pruned a
3-mark set to 1 with no error. T8's escalation trigger — "any caller *can* hand the reconciler a
filtered changeset" — is literally satisfied today, and no spec T8 can write would catch a caller
that filters.

So the type this card defines has to make the illegal state unrepresentable. Two shapes the panel
named, either acceptable: filtering yields a **view** that has no `#hunks` at all, or `#hunks` stays
total and a separate `#presented_hunks` carries the filtered set. Pick one and say why in the
hand-back. This is the tuicr `preserve_hunks` bug being closed by data flow rather than by a flag,
which is what T8's card was reaching for — it just could not reach it from where it stood.

**THE RE-REVIEW DELTA CANNOT SEE MERGE-ONLY WORK.** Added for every consumer — T13, T20 and T21 read
this plan, not `delta.rb`'s comments. `git range-diff` **omits merges entirely**, verified twice: a
merge carrying a hand-resolved file reports only the side branch's commit, and that file appears in
**no entry** while `ls-tree` shows it in the branch. It is not a flag away — `range-diff` rejects
`--diff-merges` outright, so the omission is structural. A delta reporting "nothing changed" over a
range whose only change was a merge resolution is therefore correct-by-its-own-lights and wrong for
a human. Anything gating on the delta must say so.

**Added during execution (2026-08-04): MERGE COMMITS ARE THIS CHUNK'S SYSTEMATIC GAP, and two
wave-1 cards hit it independently.** Treat the second escalation trigger below as *expected to fire*,
not as a remote possibility:

- **T3's panel found `git log --numstat` emits no diff for a merge by default**, so a file changed
  only in a merge lands in `#diff` and in no commit's numstat — and the shipped source contract
  failed 1 of 19 on a merge-carrying branch. T3 now passes `--diff-merges=first-parent`, so
  `#commits` accounts for merges. Confirm what that flag hands you before assuming a shape.
- **T2 found a merge combined diff emits `@@@ -1,8 -1,8 +1,8 @@@` — TWO old sides**, which
  `Hunk`'s single `(old_start, old_count)` cannot represent. T2 flagged it rather than widening
  `Hunk` on spec, which was right: the decision belongs here, where the parser meets the diff.

So this card must decide, explicitly and in the hand-back, what a merge commit means to a changeset:
first-parent only, or a real combined-diff representation. **Do not silently skip merge hunks** — the
card's own trigger says losing anchors without saying so is the failure mode. If the honest answer
needs `Hunk` widened, that is the escalation, not a detail.

**Escalation triggers:**
- The old-side counter increments on additions. The spike had exactly this bug and only the old-side
  check caught it — if the old-side scenario fails, the counter is wrong, not the fixture.
- A rename or binary file produces a diff shape the parser's 2 counters cannot represent — stop and
  escalate; silently skipping such a file loses anchors without saying so.

---

### T8 — Derive the tri-state reviewed indicator from hunk marks          [wave 2] [risk: low]

**Depends on:** T2
**Files:** `lib/lain/review/marks.rb` (new), `spec/lain/review/marks_spec.rb` (new)
**Reuse:** `Lain::Review::Hunk` keys from T2; `each_with_object` over the mark set rather than a
hand-mutated accumulator (CLAUDE.md).
**Shared-file wiring:** `require_relative "review/marks"` in `lib/lain/review.rb`.

Marks are recorded at hunk granularity and every coarser indicator is derived, which is what
[tuicr#247] asks for: a file is green at full scope only when all its hunks across all commits are
marked, yellow when some are. Keys absent from the changeset are pruned. **Reconciliation always runs against the unfiltered
changeset**, so a filtered scope cannot reach the pruner at all. tuicr solved this with a
`preserve_hunks` flag and its own comment admits the default path can still reach the bug; a flag on
the wrong side of the call is the special case, and the data flow is the fix.

**Acceptance criteria:**

```gherkin
Scenario: a file is partially reviewed when only some of its hunks are marked
  Given a file with 3 hunks, 2 of them marked
  Then the file's state at full scope is :partial

Scenario: a file is reviewed when every hunk across every commit is marked
  Given a file touched by 2 commits with 4 hunks total, all marked
  Then the file's state at full scope is :reviewed

Scenario: marks for hunks absent from the changeset are pruned
  Given a mark set containing a key for a hunk no longer in the diff
  When the marks are reconciled against the changeset
  Then that key is dropped

Scenario: a filtered scope cannot prune marks for hunks it hides
  Given the presented scope is one commit of three
  When marks are reconciled
  Then keys for hunks in the other two commits survive
  And the reconciler was given the unfiltered changeset
```
→ spec file: `spec/lain/review/marks_spec.rb`

**Added during execution (T2 panel, 2026-08-04): a mark set must be SCOPED TO ITS BASE REVISION.**
The panel established with 66,000 real `git diff` runs that T2's span fallback is distinct within one
diff, and then found a residual hazard that no hunk-key scheme can close: when a **base** edit slides
duplicate #2 onto duplicate #1's former coordinates, *any* positional fallback hands the stale mark
to the wrong hunk, because a base edit shifts the old and new sides by the same amount and the
coordinates stay perfectly correlated. This is not a defect in T2's key — it is the limit of keying
by position at all, so the fix lives here, in the thing that *holds* marks. A mark set carries the
base revision it was recorded against, and marks recorded against a different base are not silently
reused. Pin it with a spec over a real base-side edit that relocates a duplicate.

**Escalation triggers:**
- Any caller can hand the reconciler a filtered changeset. Then the data-flow fix has not been made
  and a flag is being reinvented — stop; the reconciler should not accept one.

---

### T9 — Build the text surface as the second adapter          [wave 2] [risk: low]

**Depends on:** T4
**Files:** `lib/lain/review/surface/text.rb` (new), `spec/lain/review/surface/text_spec.rb` (new)
**Reuse:** `Lain::Sink` for output (never `$stdout` — `spec/output_discipline_spec.rb` parses every
file under `lib/` and fails on it outside `lib/lain/frontend/`); `CLI::EpicQueue`'s row-rendering
shape for the table.
**Shared-file wiring:** `require_relative "review/surface/text"` in `lib/lain/review.rb`.

Two implementations is the only way to know the port is right, and this one is what model specs drive
so they never spawn nvim. It renders the changeset, marks and annotations as plain tables into an
injected `Sink`.

**Acceptance criteria:**

```gherkin
Scenario: the text surface satisfies the whole port
  Then Lain::Review::Surface::Text behaves like "a review surface"

Scenario: it writes to an injected sink, never to stdout
  Given a text surface wired to a recording sink
  When a changeset is presented
  Then the rendering appears in the sink
  And spec/output_discipline_spec.rb passes

Scenario: the tri-state renders distinguishably
  Given a changeset where one file is reviewed, one partial and one untouched
  Then the three rows carry three distinct markers

Scenario: commit scope and cumulative scope render different row sets
  Given a changeset of 2 commits
  When presented with scope: :commits then scope: :cumulative
  Then the first rendering groups rows under commit subjects and the second does not
```
→ spec file: `spec/lain/review/surface/text_spec.rb`

**Added during execution (T4 panel, 2026-08-04): `Surface.check!` REJECTS DELEGATION-BASED
ADAPTERS.** `Forwardable`/`def_delegators` and `SimpleDelegator` both generate `(*args, &block)`,
which the shape check refuses. That forbids a tee or recording decorator wrapped around a real
surface — precisely the bench-shaped thing this repo wants, since comparing two surfaces by
recording one is a study-bench move. **The panel was explicit that loosening the check is the wrong
answer**, because the shape check is what makes an incomplete surface fail before construction
rather than at first use. If this card wants a decorator, give it explicit methods or give the port
an intentional delegation seam — do not widen the shape rule. Also note the group's per-example
freshness is inherited from the *including* spec: a `subject { SOME_CONSTANT }` or a `before(:all)`
instance silently restores the vacuity the ordering law was rewritten to fix.

**Added during execution (T4 panel, 2026-08-04): this card owes the group its FIRST BEHAVIOURAL
LAW.** T4's `"a review surface"` group is a *signature* check plus one ordering law, and the panel
demonstrated that a surface which drops every annotation, ignores `mark`'s `state` and returns a
random verdict passes it green. That is acceptable for a group written with only a Null to check
against, and it is not acceptable once a real adapter exists. T9 is the cheap place to fix it: a
surface told to annotate must be able to say it was, observable through the injected `Sink`. Add one
such law to the shared group, not to this card's own spec, so T19 inherits it.

**Escalation triggers:**
- The port needs a message this surface cannot implement without a no-op. That is a signal the port
  was shaped around nvim; stop and re-cut rather than adding an empty method.

---

### T10 — Add the GitHub PR changeset source          [wave 2] [risk: medium]

**Depends on:** T3
**Files:** `lib/lain/review/source/github_pr.rb` (new),
`spec/lain/review/source/github_pr_spec.rb` (new)
**Reuse:** the shared example group from T3 (`"a review changeset source"`); `Forge::Gh`'s
`shell_out_factory` + argv-array idiom (`gh.rb:280-286`); its refusal-as-value doctrine.
**Shared-file wiring:** `require_relative "review/source/github_pr"` in `lib/lain/review.rb`.

Resolves a PR number or URL, fetches `refs/pull/N/head`, and produces the same shape `LocalBranch`
does. **GitHub stops serving a combined diff past 300 changed files** ([tuicr#475]), and §3.7
measured a real work changeset at 810 files, so the local-object-database fallback is the normal path
here, not an edge case: when the PR's head is already fetched, diff locally rather than asking the
API.

**Acceptance criteria:**

```gherkin
Scenario: a GitHub PR source satisfies the port contract
  Then it behaves like "a review changeset source"

Scenario: a PR URL and a bare number resolve identically
  Given "https://github.com/o/r/pull/42" and "42"
  Then both produce the same base_ref and head_ref

Scenario: the local object database is used when the head is already fetched
  Given the PR head has been fetched into the local repository
  When the source is asked for its diff
  Then no gh subprocess is spawned for the diff

Scenario: a PR too large for the combined diff API falls back rather than failing
  Given gh refuses the combined diff with the 300-file error
  Then the source produces a diff from the local object database
  And the fallback is reported, not silent
```
→ spec file: `spec/lain/review/source/github_pr_spec.rb`

**Escalation triggers:**
- The 300-file refusal string differs from what [tuicr#475] documents — stop and record the actual
  string rather than pattern-matching loosely, because a missed match degrades to a silent truncation
  (which is exactly the defect octo's `--slurp` fix introduced, research §4.5).
- `gh pr diff` output differs in header shape from `git diff` such that T7's parser needs a second
  branch — stop; one parser is the point.

---

### T11 — Extend the RPC protocol surface for review          [wave 2] [risk: high]

**Depends on:** T6
**Files:** `lib/lain/frontend/neovim/rpc_thread.rb`, `lib/lain/cli/human_replies.rb`,
`lib/lain/frontend/neovim.rb` (the `PROTOCOL` constant and its history block),
`lib/lain/frontend/neovim/runtime.lua` (the `RUNTIME_PROTOCOL` twin),
`spec/lain/frontend/neovim/rpc_thread_spec.rb`, `spec/lain/cli/human_replies_spec.rb`
**Reuse:** the existing `RenderQueue` stub shape (`:20-50`); `RenderInlet#refusable` (`:253-257`);
`Router#acked` / `#answered` (`:307`, `:316`); `HumanReplies#routes` (`:314-322`).
**Shared-file wiring:** none. The doc stanzas and the protocol stamps belong to T28.

**This card owns every RPC edit in the chunk.** Later cards use the entry points and do not touch
these files, which is what keeps waves 3–5 conflict-free.

Adds render entry points `set_review` (the sidebar), `open_changeset` (the diff pair),
`set_thread`; inbound verbs `review_open` (acked, carries a cursor line), `review_mark` (acked),
`review_annotate` (**answered** — a malformed annotation must fail the write and leave the human's
text untouched), `review_verdict` (answered), `review_ask` (acked, the docent question).

**This card does NOT bump the protocol.** The Ruby side of an entry point is useless until the lua
`_G.__lain.*` function exists, and those arrive in T14, T15 and T18. Bumping here would advertise a
contract that is three waves from being true, with no lua behind it to exercise. T28
bumps once every half exists. Each lua card owns its own entry-point function; this card owns only
the Ruby stubs that call them.

The recorded rule holds: **the editor sends a LINE or a stamp, never a digest.** Ruby owns the
line→identity map.

**Acceptance criteria:**

```gherkin
Scenario: the protocol is unchanged by this card
  Then Lain::Frontend::Neovim::PROTOCOL still equals "8"
  And spec/plugin/nvim_plugin_spec.rb passes

Scenario: an answered verb's return value is the write's verdict
  Given a review_annotate whose payload names an unknown side
  When the editor writes
  Then the rpc request fails with a message naming the side
  And the annotation is not recorded

Scenario: an acked verb responds before its route runs
  Given a review_mark command
  Then the rpc response is sent and the command appears on the command inbox

Scenario: a raise in any review route becomes an editor refusal
  Given a review route that raises
  When the editor command is served
  Then review_refused is called with the raised message
  And the serving fiber survives
```
→ spec files: `spec/lain/frontend/neovim/rpc_thread_spec.rb`,
`spec/lain/cli/human_replies_spec.rb`

**Escalation triggers:**
- Any Ruby entry point added here cannot be exercised without its lua half. If a spec for this card
  needs `_G.__lain.set_review` to exist, the card is reaching into T14's scope — stop; assert the
  queued lua command instead of its effect.
- `spec/plugin/nvim_plugin_spec.rb:271` reads `PROTOCOL` from the constant, **not** as a literal
  ("Read from the constant, never as a literal"). Do not "fix" it.
- Adding a verb to `Router#answered` changes `dispatch`'s branch for an existing verb — stop; the
  acked/answered split is a wire-semantics decision, not a routing convenience.
- The wire shape is `[verb, [one, array, of, args]]`; `runtime.lua:871-875` records that flat
  positionals silently dropped a payload once. If a new verb needs flat args, stop.

---

### T12 — Compute the re-review delta with range-diff          [wave 3] [risk: medium]

**Depends on:** T7
**Files:** `lib/lain/review/delta.rb` (new), `spec/lain/review/delta_spec.rb` (new)
**Reuse:** **promote `spike/review-probe/redelta.sh`** from the spike worktree — it verified both the
primitive choice and the ref pinning. Same `shell_out_factory` seam as T3.
**Shared-file wiring:** `require_relative "review/delta"` in `lib/lain/review.rb`.

`git range-diff <pinned_base>..<pinned_head> <base>..<head>` reports which commits are identical by
patch content even when every SHA differs. §3.7 measured 29 of 30 identical in 0.22s after a rebase.
The reviewed head is pinned at review time, because once the branch is rewritten nothing else keeps
the baseline reachable and `git gc` can take it. The ref is
`refs/lain/reviewed/<scope-key>/<generation>`, where scope-key is the epic slug for a gated review
and the PR number or branch for a standalone one. A bare generation is not unique: standalone
`lain review` has no epic slug, and two concurrent reviews of different branches would write the
same ref.

**Acceptance criteria:**

```gherkin
Scenario: base movement is excluded from the delta
  Given the base branch gained an unrelated commit since the review
  When the delta is computed
  Then that commit's files do not appear

Scenario: identity survives a rebase that changes every sha
  Given 3 reviewed commits rebased onto a new base with none amended
  Then the delta reports 3 identical entries and 0 changed

Scenario: an amended commit is reported as changed
  Given the tip commit is amended after review
  Then the delta reports it changed and the others identical

Scenario: the reviewed head stays reachable after the branch is rewritten
  Given a review pinned at generation 1
  When the branch is force-updated and git gc --prune=now runs
  Then the pinned ref still resolves
```
→ spec file: `spec/lain/review/delta_spec.rb`

**Escalation triggers:**
- `git range-diff` is unavailable or its output format differs from what the spike parsed (`=`, `!`,
  `<`, `>` markers) — stop; there is no fallback primitive, and `git diff` was measured wrong for
  this job.
- Pinning a ref under `refs/lain/` collides with an existing lain ref convention — search
  `lib/lain/isolation/` before creating the namespace.
- Two reviews open at once resolve to the same ref. The scope-key is what prevents it; if any
  caller can omit it, the key is optional and the collision is back.

---

### T13 — Assemble the review session          [wave 3] [risk: high]

**Depends on:** T5, T7, T8
**Files:** `lib/lain/review/session.rb` (new), `lib/lain/review/verdict/policy.rb` (new),
`spec/lain/review/session_spec.rb` (new), `spec/lain/review/verdict/policy_spec.rb` (new)
**Reuse:** `Lain::Epic::Review`'s `from_journal` fold as the replay shape
(`lib/lain/epic/review.rb`); `Lain::Journal` for writing; `Surface::Null` (T4) so session specs
never spawn nvim.
**Shared-file wiring:** `require_relative "review/session"` in `lib/lain/review.rb`.

The aggregate: a changeset, its marks, its annotations and its verdict, rebuildable from the journal,
so a chat restarted mid-review resumes rather than losing state ([octo#118] and octo#980 are both
this problem unsolved).

Two things deliberately live elsewhere. **The presented scope is view state** and belongs to the
surface; T19's "the surface holds no review state" is right about annotations and marks and wrong
about which scope is on screen. **Verdict admissibility is a policy**, injected as
`Lain::Review::Verdict::Policy`, because its interaction with the `deferred` gate is an open question
and a rule you cannot swap is a rule you cannot experiment with on a bench.

Annotations are **round-scoped**: produced, consumed, then historical. Nothing re-anchors them onto a
later round. That is what lets lain avoid the cross-round re-anchoring that all 3 surveyed projects
punt on (research §4.7).

**Acceptance criteria:**

```gherkin
Scenario: a session rebuilds from its journal
  Given a session with 2 annotations, 3 marks and no verdict
  When rebuilt from the journal alone
  Then it reports the same annotations, marks and absent verdict

Scenario: an annotation records which revision it was authored against
  Given an annotation placed while scope is one commit
  Then its record names that commit's sha as the revision

Scenario: annotations do not carry forward into a new round
  Given a settled session and a new changeset over rewritten commits
  When a new session opens
  Then it holds no annotations
  And the prior round's annotations remain readable from the journal

Scenario: verdict admissibility is delegated, not decided here
  Given a session wired to a policy that admits everything
  When a verdict is submitted over a partially reviewed changeset
  Then it is recorded

Scenario: the default policy refuses an approve over unreviewed hunks
  Given the default policy and a changeset with one partially reviewed file
  When approve is submitted
  Then Lain::Review::Verdict::Policy::Incomplete is raised naming the file
```
→ spec file: `spec/lain/review/session_spec.rb`

**Added during execution (T4 panel, 2026-08-04): this card decides whether a verdict needs a NULL
VALUE.** `Surface::Null#verdict` returns `nil`, per T4's AC. The panel's objection is sound and is
left for this card because this is where a verdict is first consumed: `Sink::Null#write` returns the
byte count *precisely* so that no caller nil-checks it, and `#verdict`/`#thread` are queries rather
than commands, so `nil` from them reintroduces the `if surface` guard the Null Object pattern exists
to delete. If the session ends up nil-checking a verdict, that is the finding — change
`Surface::Null` (one file) rather than spreading guards. There is a comment at `Null#verdict`
pointing here.

**Escalation triggers:**
- The default policy blocks an unattended run under the `deferred` gate. Swapping the policy is the
  designed escape, but if the gate cannot reach the seam to swap it, stop.
- Research open question 3 has not settled the verdict vocabulary ("Reuse the panel's APPROVE /
  APPROVE-WITH-FIXES / REQUEST-CHANGES?"). This card writes `approve`. If a second verdict value is
  needed before the vocabulary is chosen, stop rather than inventing the set.
- Replay produces a different mark set than the live session for the same journal — stop; that is the
  content-addressing not holding, and it invalidates T8.

---

### T14 — Render the review sidebar with a commit walk          [wave 3] [risk: medium]

**Depends on:** T11, T26
**Files:** `lib/lain/frontend/neovim/runtime/sidebar.lua` (new),
`lib/lain/frontend/neovim/review_view.rb` (new),
`spec/lain/frontend/neovim/review_view_spec.rb` (new)
**Reuse:** `InboxView` as the index-buffer exemplar, including `Renderings` for the generation stamp
(`inbox_view/renderings.rb`) — positions move here, so a stamp is required, not optional;
`Buffers#generation_of` (`buffers.rb:259`) for how a stamped view is registered; `named_buf` and
`set_lines` from T6's `buffers.lua`.
**Shared-file wiring:** `plugin/nvim/doc/lain.txt` stanza for `:LainReviewOpen` (hand back).

`lain://review` is the navigator. Two scopes, toggled: a flat cumulative file list, and a commit walk
showing each commit's subject, files and numstat. §3.7 makes the walk a requirement rather than a
convenience: the cumulative view of a real work changeset is 81,810 lines and one commit is 2,727.

Ruby owns the line→identity map, built in the same pass that renders the lines, as
`TimelineView#render_chain` does.

**Acceptance criteria:**

```gherkin
Scenario: the sidebar renders both scopes
  Given a changeset of 2 commits touching 5 files
  When the scope is cumulative
  Then 5 file rows render
  When the scope is commits
  Then 2 commit rows render with their files beneath

Scenario: the tri-state marker renders per row
  Given one reviewed file, one partial and one untouched
  Then the three rows carry three distinct markers

Scenario: a stale generation refuses the open gesture
  Given the sidebar has re-rendered since the human last saw it
  When an open gesture arrives carrying the old stamp
  Then it is refused with a message naming the staleness
  And no file is opened

Scenario: opening a row names the file and its first hunk line
  Given the cursor on a file row
  When the open gesture fires
  Then the resolved target is that file's path and its first hunk's new-side line
```
→ spec file: `spec/lain/frontend/neovim/review_view_spec.rb`

**Added during execution (T7 panel, 2026-08-04): WHAT THE COMMIT WALK MAY AND MAY NOT CLAIM.**
`Changeset#by_commit` attributes at **file** granularity — "last commit in the range to touch this
file" — not per-hunk provenance. Worse, and this is the part that matters here: **when a merge is in
the range, the merge absorbs every file it re-reports and the authoring commits render empty.**
Measured by the panel: 3 commits, 2 of 3 scopes `files: []`, with the side-branch commit that
actually authored `side_only.rb` showing nothing.

So this card may claim *"this commit is the last one in the range to touch these files, and here are
their net hunks"*. It may **not** claim per-hunk provenance, and it may **not** present a commit's
scope as what that commit did. Empty scopes for genuinely empty commits and for add-then-delete
pairs are honest and disclosed; an empty scope for real work absorbed by a merge is not.

Two ways out, pick one and say which: render **`numstat`** (the commit's own figure, which T3's
source answers per commit and which a merge does not distort) as the sidebar's primary signal and
treat `files` as "hunks reachable here", or fetch per-commit diffs. §3.7's numbers make the commit
walk a requirement rather than a convenience — 81,810 cumulative lines against 2,727 for one
commit — so a walk that silently blanks two commits in three defeats the card's own purpose.

**Added during execution (T26 panel, 2026-08-04): THIS CARD IS THE FIRST CALLER OF T26'S LAYOUT, and
until it is, that layout is dead code.** Two review-opening policies coexist on `main` right now: the
shipped `_G.__lain.open_review` still does `belowright split` **in the session tab** — exactly what
T26's card forbids — and it is the one Ruby actually calls, while T26's `review_layout` /
`review_place` have no caller at all. Route the sidebar render through `review_place`, and say in the
hand-back what now calls `open_review`, if anything. If retiring `open_review` turns out to belong to
T19 rather than here, stop and say so rather than leaving two policies live.

**The window-id rule T26's panel established, which this card must obey:** window ids never recycle
and a stale one raises `Invalid window id` rather than silently hitting a different window, so
failure is loud. **`review_place` re-ensures and returns a fresh id and is the safe seam;
`review_layout()`'s return is a snapshot that goes stale on the next human action and must NOT be
cached across renders.**

**Escalation triggers:**
- The line count aliases between two renderings of equal height, which is the exact defect protocol 8
  fixed by replacing the count with a stamp (`neovim.rb` history entry for `"8"`) — if the stamp is
  not threaded, stop.
- `Buffers#generation_of` returns nil for this view because it special-cases `InboxView::NAME`
  (`buffers.rb:259`) — that method needs generalizing, and it is a shared-file edit, so hand it back.

---

### T15 — Open a changed file in native diff mode          [wave 3] [risk: high]

**Depends on:** T11, T26
**Files:** `lib/lain/frontend/neovim/runtime/diff.lua` (new),
`spec/lain/frontend/neovim/diff_mode_spec.rb` (new, its own nvim harness)
**Reuse:** `open_review`'s split-and-stamp shape (`runtime.lua:780-792`) for how a real file is
opened and stamped; `named_buf` from T6's `buffers.lua` for the old-side scratch buffer.
**Shared-file wiring:** `plugin/nvim/doc/lain.txt` stanza for `:LainDiffOpen` (hand back).

The reading surface. New side is the real file (`buftype=""`, so the language server and treesitter
attach). Old side is a `nofile` buffer filled from `git show <base>:<path>`, named
`lain://review/OLD/<path>` so a gesture can recover which side it came from, with filetype set by
hand because there is no path to sniff. Both `diffthis`.

§3.5 measured that an extmark in the old-side scratch buffer slides on edit exactly as in a real
file, so drift detection works on both sides. §3.4 measured `foldmethod=diff` hiding 26 of 40 lines,
which is the expand-context affordance.

Set the buffer **before** showing the window: [diffview#509] is an open bug where the previously
focused buffer flashes in both diff windows.

**Acceptance criteria:**

```gherkin
Scenario: the new side is a real buffer
  Given a changed Ruby file opened for review
  Then its buftype is empty and its filetype is ruby

Scenario: the old side carries its side in its name and is not a real file
  Then the old buffer is named lain://review/OLD/<path> and its buftype is nofile

Scenario: unchanged regions fold away on both sides
  Given a file with one changed line among 40
  Then both windows report foldmethod diff and fold the unchanged regions

Scenario: an extmark in the old-side buffer slides when it is edited
  Given an extmark on old-side line 14
  When 2 lines are inserted above it
  Then the extmark reports row 16

Scenario: opening a second file does not flash the previous buffer
  Given one file already open in diff mode
  When a second file is opened
  Then neither diff window ever displays the previously focused buffer
```
→ spec file: `spec/lain/frontend/neovim/diff_mode_spec.rb`

**Escalation triggers:**
- `diffthis` refuses the `nofile` old-side buffer in this nvim version. §3.5 measured it accepting
  (`old buftype="nofile" diff=true`), so a refusal means the environment differs from the spike —
  stop and report the nvim version.
- Any nvim API call in this module runs inside a libuv callback. [diffview#466] is
  `E5560 nvim_buf_is_valid must not be called in a lua loop callback`; if a call site is reached from
  a callback it needs `vim.schedule`, and getting that wrong crashes the editor rather than failing a
  spec.

---

### T16 — Place and settle annotations on the diff          [wave 4] [risk: medium]

**Depends on:** T15
**Files:** `lib/lain/frontend/neovim/runtime/annotate.lua` (new),
`lib/lain/review/annotations.rb` (new), `spec/lain/review/annotations_spec.rb` (new),
`spec/lain/frontend/neovim/annotate_spec.rb` (new, its own nvim harness)
**Reuse:** `:LainAnnotate`'s extmark + `review_annotations[buf][id]` pattern
(`runtime.lua:853-865`) and its `BufUnload` GC (`:801-804`); `Epic::Review::Annotations.resolve` for
the drift computation; `Anchor` from T1.
**Shared-file wiring:** `plugin/nvim/doc/lain.txt` stanza for `:LainNote` and `:LainNoteDone`.

Annotation content lives in the thread pane (T18); what renders inline is a **marker**, right-aligned
so it never collides with code, as octo does (`file-entry.lua:479-491`). A note carries a kind
(`:note`, `:question`, `:blocker`) and the anchor's side, which the buffer name or `b:lain_review_side`
supplies.

Order is the output: notes are journaled in placement order, and nothing else records which the human
placed first.

**Acceptance criteria:**

```gherkin
Scenario: a note on the new side records the new-side line and revision
  Given the cursor on a changed line in the new-side buffer
  When a note is placed and settled
  Then the recorded anchor names side new, that file line, and the head revision

Scenario: a note on the old side records the old-side line
  Given the cursor in the old-side buffer
  Then the recorded anchor names side old and the merge-base revision

Scenario: a drifted note is kept and marked, not dropped
  Given a note whose anchor text no longer matches its line
  When the review settles
  Then the note is recorded with drifted true and its text intact

Scenario: notes settle in placement order
  Given three notes placed on lines 40, 12 and 25 in that order
  Then the journal records them in that order

Scenario: the inline marker is right-aligned and does not overlay code
  Then the marker extmark uses virt_text_pos right_align
```
→ spec files: `spec/lain/review/annotations_spec.rb`,
`spec/lain/frontend/neovim/annotate_spec.rb`

**Escalation triggers:**
- Buffer numbers are reused and a stale `review_annotations[buf]` entry survives, which the existing
  `BufUnload` GC exists to prevent — if the GC does not fire for diff-mode buffers, stop.
- The old-side buffer's line numbers do not correspond to merge-base line numbers because
  `git show` output was trimmed or reordered — stop; every old-side anchor depends on a 1:1 mapping.

---

### T17 — Project annotations and findings into diagnostics  [wave 4] [risk: low] [deletable]

**Depends on:** T15
**Files:** `lib/lain/frontend/neovim/runtime/49_diagnostics.lua` (new),
`lib/lain/review/projection/diagnostics.rb` (new),
`spec/lain/review/projection/diagnostics_spec.rb` (new)
**Reuse:** **promote `spike/review-probe/diagnostics_probe.lua`** — it measured the whole contract;
the panel's BLOCKER / SHOULD-FIX / NIT vocabulary from `references/review-panel.md`.
**Shared-file wiring:** none.

Diagnostics are a **display layer only**: §3.2 measured that they do not track edits, so extmarks
remain the anchor and this projection re-renders on each change. In exchange nvim gives gutter signs,
virtual text, `]d` and `[d`, `setqflist`, severity filtering, and every picker's diagnostics source —
which is how `:Telescope diagnostics` becomes a comment browser at no cost.

Severity map: BLOCKER → ERROR, SHOULD-FIX → WARN, NIT → HINT.

**Acceptance criteria:**

```gherkin
Scenario: annotations render as diagnostics in their own namespace
  Given 3 annotations of differing kinds on one file
  Then 3 diagnostics exist in the lain review namespace with mapped severities

Scenario: diagnostics coexist with the annotation extmarks
  Given both are placed on the same buffer
  Then querying the annotation namespace still returns the extmarks

Scenario: the projection re-renders after an edit rather than trusting positions
  Given a diagnostic on line 3 and 2 lines inserted above it
  When the projection refreshes from the extmarks
  Then the diagnostic reports line 5

Scenario: severity filtering yields only blockers
  When diagnostics are queried at ERROR severity
  Then only annotations of kind blocker are returned

Scenario: removing this capability leaves a green suite
  Given runtime/49_diagnostics.lua and its projection are deleted
  Then the full suite passes
```
→ spec file: `spec/lain/review/projection/diagnostics_spec.rb`

**Escalation triggers:**
- `vim.diagnostic.set` in this nvim version tracks edits after all, contradicting §3.2's measurement.
  Then extmarks are redundant here and the design should be simplified — stop and say so rather than
  keeping both.

---

### T18 — Show a thread in a persistent pane          [wave 4] [risk: high] [deletable]

**Depends on:** T15, T26
**Files:** `lib/lain/frontend/neovim/runtime/51_thread.lua` (new),
`lib/lain/frontend/neovim/thread_view.rb` (new),
`spec/lain/frontend/neovim/thread_view_spec.rb` (new)
**Reuse:** octo's technique, ported not copied (MIT, attribute in a comment):
`thread-panel.lua:62-88` for the buffer swap, `autocmds.lua:66-74` for the `CursorMoved` trigger with
a buffer-variable bail-out, `layout.lua:246-295` for detecting a user-clobbered window arrangement.
`QuestionView`'s `acwrite` + `BufWriteCmd` shape for submitting text.
**Shared-file wiring:** `plugin/nvim/doc/lain.txt` stanza for `:LainThread`.

The pane is persistent and its **buffer is swapped**; no window is created or destroyed on cursor
movement, which is what causes flicker and layout churn. Content lives here rather than in virtual
text because it can be long, and because a real buffer can be searched, yanked and scrolled.

**Fix two defects octo has** rather than inheriting them: add the idempotency guard on the show path
(octo has one only on hide, so every `CursorMoved` on a commented line re-runs `nvim_win_set_buf`,
`configure()`, keymaps and `diffoff!`), and clean the buffer registry on `BufWipeout` (octo's grows
unboundedly).

**Acceptance criteria:**

```gherkin
Scenario: moving onto an annotated line shows its thread in the other pane
  Given an annotation on line 20 and the cursor on line 1
  When the cursor moves to line 20
  Then the opposite pane displays the thread buffer for that annotation

Scenario: moving within an annotated line does not re-render
  Given the cursor already on line 20 with the thread shown
  When the cursor moves by one column
  Then no buffer is set and no keymap is re-registered

Scenario: moving off an annotated line restores the diff
  When the cursor moves to an unannotated line
  Then the opposite pane displays its diff buffer again

Scenario: a clobbered layout is rebuilt rather than erroring
  Given the human has closed one of the two diff windows
  When the cursor moves onto an annotated line
  Then the layout is restored and the thread shows

Scenario: thread buffers are released when wiped
  Given 5 threads have been shown and their buffers wiped
  Then the registry holds no entries for them

Scenario: removing this capability leaves a green suite
  Given runtime/51_thread.lua and thread_view.rb are deleted and the surface returns Null
  Then the full suite passes
```
→ spec file: `spec/lain/frontend/neovim/thread_view_spec.rb`

**Escalation triggers:**
- The `CursorMoved` handler measurably slows cursor movement in a large buffer. The bail-out must be a
  single buffer-variable read; if anything heavier is needed, stop.
- Swapping the buffer in the opposite pane fights native diff mode (the swapped-in buffer inherits
  `diff`, or `diffoff!` unsets the wrong window) — stop; octo calls `diffoff!` on the thread buffer,
  and whether that interacts safely with our layout is unverified.

---

### T19 — Wire the Neovim surface to the port          [wave 4] [risk: medium]

**Depends on:** T4, T14, T15
**Files:** `lib/lain/review/surface/neovim.rb` (new),
`spec/lain/review/surface/neovim_spec.rb` (new)
**Reuse:** the shared example group from T4 (`"a review surface"`); `Frontend::Neovim`'s
`RenderInlet` refusal strings for how a detached editor declines; `Surfaces#post` for how a
projection is driven.
**Shared-file wiring:** `require_relative "review/surface/neovim"` in `lib/lain/review.rb`.

The adapter. Translates port messages into the T11 entry points and translates gestures back. It holds
no review state; the session (T13) does. That separation is what lets the UI be rebuilt without
touching the model.

**Acceptance criteria:**

```gherkin
Scenario: the Neovim surface satisfies the whole port
  Then Lain::Review::Surface::Neovim behaves like "a review surface"

Scenario: a detached editor refuses rather than raising
  Given no editor is attached
  When present is called
  Then a refusal naming the detached editor is returned and nothing raises

Scenario: the surface holds no review state
  Given a surface that has presented a changeset and recorded 2 annotations
  Then its instance variables contain no annotation and no mark

Scenario: a gesture reaches the session unchanged
  Given the editor sends a mark for a known hunk key
  Then the session records that key and no other
```
→ spec file: `spec/lain/review/surface/neovim_spec.rb`

**Also inherited from the T4 panel: `Surface.check!` rejects `Forwardable`/`SimpleDelegator`
adapters** (they generate `(*args, &block)`). See T9's card for the full note — the ruling is that
the shape check stays strict and a decorator gets explicit methods instead.

**Added during execution (T4 panel, 2026-08-04), two obligations:**

1. **Settle the `#refuse` direction.** It is only half-coherent today: `review_refused(message)` is
   inbound and matches the port, but `RenderInlet#refusable` makes a refusal *an answer the surface
   returns*, and the port currently has nowhere for `REVIEW_DETACHED` to go — every message returns
   nil under Null and the shared group pins no return value. This card is where a real detached
   editor must actually refuse, so decide it here and encode the decision in the shared group.
2. **Add one behavioural law to the shared group**, as T9 also does. The group is a signature check
   plus one ordering law; a surface that drops annotations and ignores `mark`'s `state` passes it.
   T19 is the adapter whose fixtures come from a running nvim, which is why T4's group was changed
   to take **callables** rather than bare values — its `config.fetch` runs at definition time, so a
   `let`-built fixture would be unreachable.

**Escalation triggers:**
- The adapter needs to cache changeset state to answer a port message. That is the session's job;
  stop and move the message rather than duplicating state.

---

### T20 — Add the review CLI          [wave 5] [risk: medium]

**Depends on:** T10, T13, T19
**Files:** `lib/lain/cli/review.rb` (new), `spec/lain/cli/review_spec.rb` (new)
**Reuse:** `CLI::EpicQueue` for the lib-side shape (defaulted keyword collaborators, **returns
Strings**, never prints); `exe/lain:299-300` (`subcommand "epic", Epic`) as the mount precedent;
`Boundary#render` (`exe/lain:27-31`) for turning `Lain::Error` into `Thor::Error`.
**Shared-file wiring:** `exe/lain` — a nested `class Review < Thor` block plus
`subcommand "review", Review` beside the epic mount at `:300`. Hand back as a diff.

`lain review <pr|branch>` resolves a source, opens a session, and presents it through whichever
surface is available (Neovim when attached, Text otherwise). `--scope commits|cumulative` picks the
initial scope. `--base <ref>` overrides the base.

**Acceptance criteria:**

```gherkin
Scenario: a bare number resolves as a PR and a branch name as a branch
  Given "4821" and "feature/foo"
  Then the first builds a GitHub PR source and the second a local branch source

Scenario: the command returns a rendering rather than printing
  When the command runs with the text surface
  Then it returns a String and nothing is written to stdout by lib code

Scenario: an unresolvable target refuses with a named error
  When the target resolves to neither a PR nor a branch
  Then a Thor::Error names the target

Scenario: the scope flag selects the initial presentation
  When run with --scope commits
  Then the presented scope is commits
```
→ spec file: `spec/lain/cli/review_spec.rb`

**Added during execution (T29 panel, 2026-08-04): `Review::Bounds` HAS ZERO CALLERS and this card
is the natural place to wire it.** T29 shipped the guard, its evidence and its refusals, but nothing
invokes it — so an 800-file changeset still presents cumulatively today. A guard nobody calls is the
same shape as a disclosure nobody reads, which this chunk has now produced twice. Wire the cumulative
check where a scope is chosen, and say in the hand-back what calls it and what a human sees when it
fires. If the right caller turns out to be T19 or T13 rather than here, say so rather than leaving it
inert.

**Escalation triggers:**
- A bare number is ambiguous because a branch is literally named `4821` — stop and confirm the
  precedence rule rather than picking one.
- `spec/output_discipline_spec.rb` fails because the command printed. The rule is absolute outside
  `lib/lain/frontend/`; do not add an exclusion.

---

### T21 — Gate the epic implementation stage on a changeset review   [wave 5] [risk: high]

**Depends on:** T13, T19
**Files:** `lib/lain/tools/request_review.rb`, `lib/lain/cli/epic_mount.rb`,
`spec/lain/tools/request_review_spec.rb`
**Reuse:** `Epic::Review`'s baton (`#open`, `#settle`, per-generation promise);
`RequestReview#perform`'s fiber-parking (`:140-153`); `Approval::Queue::Pending#decide`'s
first-answer-wins across surfaces.
**Shared-file wiring:** `plugin/nvim/doc/lain.txt:364` — the line saying the review editor is
"deliberately left unwired" is stale (a card in the epic-wiring chunk wired it) and this card makes
it more so. Hand back the
correction.

Deletes `RequestReview::Refusals::NO_DOCUMENT` and lets `implementation` be reviewable, because the
surface it named as missing now exists. The verdict resolves the stage's `Approval::Gate`.

**Acceptance criteria:**

```gherkin
Scenario: the implementation stage is reviewable
  Given an epic at the implementation stage
  When request_review is called for it
  Then a changeset review opens and the tool parks

Scenario: a verdict resolves the parked call
  Given a parked implementation review
  When the human submits approve
  Then the tool returns a result naming the verdict

Scenario: a second review proceeds alongside the first
  Given an implementation review parked on generation 1
  When a research review opens on generation 2
  Then both are open and settling one does not resolve the other

Scenario: the refusal is gone by name
  Then Lain::Tools::RequestReview::Refusals does not define NO_DOCUMENT
```
→ spec file: `spec/lain/tools/request_review_spec.rb`

**Escalation triggers:**
- An existing example asserts `implementation` is refused. It encodes the old contract and must be
  rewritten, not deleted — if rewriting changes what else it pins, stop.
- Parking on a changeset review under the `deferred` gate policy makes an unattended run block rather
  than queue. `Approval::SignoffQueue` is supposed to absorb this; if it does not, stop.

---

### T22 — Prefill annotations from a critique          [wave 5] [risk: medium] [deletable]

**Depends on:** T17
**Files:** `lib/lain/review/prefill.rb` (new), `spec/lain/review/prefill_spec.rb` (new),
`lib/lain/prompt/templates/skill/critique/sidecar.md` (new)
**Reuse:** the existing critique template
(`lib/lain/prompt/templates/skill/critique/skill.md`), which already ranks BLOCKER / SHOULD-FIX / NIT
and demands an exact file and line; T17's severity map.
**Shared-file wiring:** none.

Findings render as diagnostics in a **separate namespace** from the human's own annotations, so a
suggestion is visibly a suggestion. Promotion is per-finding: editing one makes it yours, ignoring it
drops it. Joel's ruling is that a posted comment is his responsibility and triaging it is his
obligation, so there is no bulk accept.

The sidecar is NDJSON beside the prose, because the prose is for a human and nothing should parse it.

**Acceptance criteria:**

```gherkin
Scenario: findings render in their own namespace
  Given 3 critique findings and 1 human annotation on one file
  Then the finding namespace holds 3 and the annotation namespace holds 1

Scenario: a finding is not submittable until promoted
  Given an unpromoted finding
  When the session is asked for its submittable annotations
  Then the finding is absent

Scenario: editing a finding promotes it
  When a finding's text is edited
  Then it appears among the submittable annotations and carries its origin

Scenario: a malformed sidecar line is reported, not skipped
  Given a sidecar with one unparseable line
  Then loading refuses and names the line number

Scenario: removing this capability leaves a green suite
  Given prefill.rb and the sidecar template are deleted
  Then the full suite passes
```
→ spec file: `spec/lain/review/prefill_spec.rb`

**Escalation triggers:**
- Skipping an unparseable sidecar line looks harmless. It is the defect octo shipped
  (`gh/init.lua:170-182` turned a crash into a quietly truncated list). Refuse loudly.
- The critique skill's output cannot name an exact line for a finding that spans a range — stop and
  decide the range representation before the sidecar format sets.

---

### T23 — Post a review back to GitHub          [wave 5] [risk: high] [deletable]

**Depends on:** T10, T13
**Files:** `lib/lain/review/submit.rb` (new), `lib/lain/forge/gh.rb`,
`lib/lain/forge/gh/recorded.rb`, `spec/lain/review/submit_spec.rb` (new),
`spec/lain/forge/gh_spec.rb`, `spec/support/shared_examples/gh_parity.rb`
**Reuse:** `Gh#invoke`'s argv-array + refusal-as-value idiom (`gh.rb:280-286`); `Forge::Intent` for
replayability (`intent.rb:167`, `:222`); the payload shape §4.6 verified:
`{path, line, side, body}` plus optional `start_line`, `start_side`, with one top-level `commit_id`.
**Shared-file wiring:** none (`gh.rb` and `recorded.rb` are Forge-internal, not orchestrator-owned).

**Validate before submitting**, because §4.6 found tuicr skipping 2 checks GitHub enforces: a range
must sit within one hunk, and the path must be present in the diff. Never model `position`.

An unmappable comment degrades to a bullet under `## Unplaced comments` in the review body rather than
being dropped, which is the best idea in either surveyed project. Each rejection carries **one
unambiguous reason**; tuicr's `MixedSideRange` stands in for 3 different causes and is not the model.

Save session state before the network call, so a lost round trip costs nothing.

**Acceptance criteria:**

```gherkin
Scenario: the payload matches GitHub's line-and-side model
  Given an annotation on the new side at line 42 of app.rb
  Then the submitted comment carries path, line 42, side RIGHT and no position field

Scenario: a range spanning two hunks is refused before the network call
  Given a range annotation whose start and end are in different hunks
  Then submission refuses naming that comment
  And no gh subprocess is spawned

Scenario: an unmappable comment degrades instead of disappearing
  Given an annotation on a path absent from the diff
  When the review is submitted
  Then it appears as a bullet under "## Unplaced comments" in the body
  And its path is named in the bullet

Scenario: local state is durable across a failed submit
  Given gh refuses the request
  Then the session's annotations are unchanged and still on disk

Scenario: the new verb replays through Gh::Recorded
  Then it behaves like "a gh executor"

Scenario: removing this capability leaves a green suite
  Given submit.rb and the Gh verb are deleted
  Then the full suite passes
```
→ spec files: `spec/lain/review/submit_spec.rb`, `spec/lain/forge/gh_spec.rb`

**Escalation triggers:**
- The verb set lives in **3 places** in `recorded.rb` (`:37-40`, `:89-99`, `:65`). Missing one makes
  replay silently fall through to the live inner; if the parity shared example does not catch that,
  stop.
- GitHub rejects a payload the validations accepted. Add the check rather than a retry; a batched
  review POST is not idempotent and neither surveyed project retries.

---

### T24 — Answer a question about a hunk          [wave 5] [risk: medium] [deletable]

**Depends on:** T18
**Files:** `lib/lain/review/docent.rb` (new),
`lib/lain/prompt/templates/role/diff-docent.md` (new),
`spec/lain/review/docent_spec.rb` (new)
**Reuse:** `Tools::Subagent`'s spawn shape for a role-scoped child; `Provider::Mock` for specs;
`Lain::Promise` for the non-blocking answer, exactly as `RequestReview` parks.
**Shared-file wiring:** one line in `lib/lain/cli/wiring/toolset_build.rb` to make the docent
available. Hand back as a diff.

The answerer is a **role**, not a fixed agent, which keeps it a swappable bench arm. Default: a fresh
subagent per thread, given the hunk, both revisions of the enclosing function, the task card, the
handback and the panel's findings. It is unbiased by authorship, and if it cannot answer "why this
way" from the handback, that is a finding about the handback.

The RPC thread must never block: `:w` returns immediately with a pending marker and the answer arrives
through the outbound render path.

**Acceptance criteria:**

```gherkin
Scenario: asking does not block the editor
  Given a docent that takes 2 seconds to answer
  When a question is submitted
  Then the write returns before the answer arrives
  And a pending marker renders in the thread

Scenario: the answer carries the hunk as context
  Given a question on a hunk in app.rb
  Then the spawned role's prompt contains that hunk's lines

Scenario: the exchange is journaled for replay
  Given one question and its answer
  Then both are recorded and a DryReplay reproduces the answer without a provider call

Scenario: a failed docent refuses in the thread rather than killing the fiber
  Given the provider raises
  Then the thread shows a refusal naming the failure
  And the serving fiber survives

Scenario: removing this capability leaves a green suite
  Given docent.rb and the role template are deleted
  Then the full suite passes and asking refuses with a named message
```
→ spec file: `spec/lain/review/docent_spec.rb`

**Escalation triggers:**
- Answering inside the RPC thread. It must not block; if the seam makes that hard, stop rather than
  accepting a multi-second freeze.
- The docent needs the parent's timeline to answer well, which would defeat the fresh-context design
  and break the spawn contract (a child gets a fresh root whose `meta["spawned_from"]` names the
  parent's head) — stop and escalate.

---

### T26 — Give the review its own tabpage          [wave 2] [risk: medium]

**Depends on:** T6
**Files:** `lib/lain/frontend/neovim/runtime/layout.lua` (new),
`lib/lain/review/placement.rb` (new), `spec/lain/review/placement_spec.rb` (new),
`spec/lain/frontend/neovim/layout_spec.rb` (new, its own nvim harness)
**Reuse:** `plugin/nvim/lua/lain/init.lua:179` `open_layout()` for the `tabnew` + `botright vsplit`
idiom already in the repo; `CLI::TmuxSurface#window(command:, name:, target_session:, cwd:)` and its
`Placement = Data.define(:kind, :target, :degraded, :reason)` return for the tmux path, including its
capability probe and degradation; octo's `validate_layout` / `recover_layout` / `ensure_layout`
(`layout.lua:246-295`) for rebuilding a layout the human has clobbered.
**Shared-file wiring:** none.

An epic already in flight has nvim open with the journal, timeline, inbox and request buffers. A
review needs room, so it does not fight that layout. It opens in **its own tabpage**: `tabnew`
inside the existing nvim, sidebar plus the diff pair, session layout untouched, `gt` returns to it.
This is what octo and diffview both do.

**The tmux-window placement is deliberately out of scope**, and the reason is recorded rather than
discovered: it needs a second `Frontend::Neovim` attached to a second socket, and `Cockpit` computes
the socket once from the cwd hash. That is an architecture change, not a card. `Placement` still
exists as a named value so the second placement is additive, but it has one legal value here and
must refuse the rest by name.

The layout is validated before every render and rebuilt if the human closed a window, because they
will. [diffview#457] and [octo#854] are both editor state lost on tab switching, so the tabpage's
buffers must survive `gt` away and back.

**Acceptance criteria:**

```gherkin
Scenario: the review opens in its own tabpage by default
  Given an nvim with the session layout already open
  When a review is presented
  Then a new tabpage holds the sidebar and the diff pair
  And the original tabpage's buffers are unchanged

Scenario: leaving and returning preserves the review layout
  Given a review tabpage with a file open in diff mode
  When the human switches to the session tab and back
  Then the same windows, buffers and folds are present

Scenario: a clobbered layout is rebuilt before the next render
  Given the human has closed the sidebar window
  When the next render arrives
  Then the sidebar window is restored and the render lands in it

Scenario: an unsupported placement is refused by name
  When placement :tmux_window is requested
  Then Lain::Review::Placement::Unsupported is raised naming :tmux_window
  And the message says a second editor attachment is not yet supported
```
→ spec files: `spec/lain/review/placement_spec.rb`,
`spec/lain/frontend/neovim/layout_spec.rb`

**Escalation triggers:**
- Anything in this card starts needing a second editor attachment. That is the tmux placement
  arriving through the back door — stop.
- Creating a tabpage disturbs the existing session layout (window ids change, `Surfaces#post` lands
  in the wrong window) — stop; the guarantee that the session layout is untouched is the point of
  this card.

---

### T28 — Bump the protocol once both halves exist          [wave 5] [risk: low]

**Depends on:** T14, T15, T18
**Files:** `lib/lain/frontend/neovim.rb` (the `PROTOCOL` constant and its history block),
`lib/lain/frontend/neovim/runtime.lua` (the `RUNTIME_PROTOCOL` twin),
`spec/lain/frontend/neovim_runtime_spec.rb` (the protocol-lockstep example)
**Reuse:** the 8-entry history block at `neovim.rb:29-62`, whose own comment says a history that
skips a version is worse than none.

**Added during execution (T15, 2026-08-04): this card owes TWO documentation corrections, not just
a stanza.**

1. **`b:lain_view` now carries a per-file value.** Protocol 3 documents it as naming a *view*, and
   T15's old-side buffers put `lain://review/OLD/lib/foo.rb` in it — a consequence of reusing
   `named_buf`, which was the right call. The widening is real and undocumented; the "9" history
   entry must say so. T15 also sets explicit `b:lain_review_side` and `b:lain_review_path` so a
   gesture reads a variable instead of parsing the URI out of a name.
2. **There is no `:LainDiffOpen`.** The plan assumed one; T15 established that every AC there is
   about the *render entry point*, and the only verb carrying an open gesture is `review_open` —
   the sidebar's `<CR>`, wired as `:LainReviewOpen` by T14. A `:LainDiffOpen` would be a command
   with no gesture behind it. The doc owes a `*lain-review-diff*` paragraph covering the new buffer
   names and stamps instead, which T15 hands back.
**Shared-file wiring:** `plugin/nvim/doc/lain.txt` — a `6.8 READING A CHANGESET (PROTOCOL 9)`
stanza *(title amended 2026-08-05: this card was written before T15 shipped the section, which named
it READING. Keeping T15's title is right — `6.7 REVIEWING A DOCUMENT` sits directly above it with a
near-identical tag, and two adjacent headings both opening "REVIEWING" are hard to tell apart in
`:help`. T28's implementer made this call and its panel agreed.)*, the doc entries for every
`:Lain*` command this chunk added, and updating every existing `(PROTOCOL 8)` heading to 9. Hand
back as one diff.

The protocol is a handshake compared for **equality**, so it advertises a contract. T11 added the
Ruby halves in wave 2 and T14, T15 and T18 added the lua halves in waves 3 and 4. Only now is the
contract true, so only now does the number move.

Research §6.1 records why the counter is kept rather than reset: `runtime.lua:16` is an equality
test, so semver would imply an ordering the code does not implement, and the history exists to date
a change and say whether a running runtime has a feature.

**Acceptance criteria:**

```gherkin
Scenario: both constants move together
  Then Lain::Frontend::Neovim::PROTOCOL equals "9"
  And the runtime's RUNTIME_PROTOCOL equals "9"
  And attaching produces no mismatch warning

Scenario: the history gained an entry saying what changed
  Then the history block contains a "9" entry naming the review entry points and commands

Scenario: every command added by this chunk is documented
  Then spec/plugin/nvim_plugin_spec.rb's command sweep passes

Scenario: every (protocol n) stamp in the doc agrees with the constant
  Then spec/plugin/nvim_plugin_spec.rb's stamp example passes
```
→ spec file: `spec/lain/frontend/neovim_runtime_spec.rb`

**Escalation triggers:**
- Any entry point named in the history entry does not exist. The number would then advertise a
  contract that is false, which is the failure this card was split out to prevent — stop.
- A command name added by this chunk is a prefix of another. The doc sweep is word-boundaried
  precisely because a longer name would otherwise certify a shorter one; if `:LainReview` and
  `:LainReviewDone` both exist, stop and rename.

---

### T29 — Guard against a changeset too large to handle          [wave 3] [risk: medium]

**Depends on:** T7
**Files:** `lib/lain/review/bounds.rb` (new), `spec/lain/review/bounds_spec.rb` (new)
**Reuse:** `Lain::Agent::Budget` for the shape of a bound that refuses rather than truncates;
T7's `Changeset`.
**Shared-file wiring:** none.

Research §5.8 puts this in the first slice rather than deferring it, on §4.2's evidence that large
changesets are where all three surveyed projects break. §3.7 measured where the bound is **not**:
our parse handles 80,800 rendered lines in 0.26s at 39MB, so diff size is not the constraint.

The constraints are elsewhere and this object names them: a per-changeset file count and rendered
line count above which the surface refuses to present cumulatively and offers the commit walk
instead, and a per-`/critique` input bound, since 74k changed lines exceeds any context window and
the commit is the natural chunk.

**Every refusal is loud.** octo's fix for its own large-PR bug turned a crash into a quietly
truncated file list, which is a worse failure than the one it replaced.

**Acceptance criteria:**

```gherkin
Scenario: an oversized cumulative view is refused with a named alternative
  Given a changeset of 800 files
  When it is presented cumulatively
  Then Lain::Review::Bounds::TooLarge is raised naming the file count and the limit
  And the message names the commit walk as the alternative

Scenario: the same changeset presents per commit
  Given the same 800-file changeset across 30 commits
  When it is presented per commit
  Then each commit presents without refusal

Scenario: a critique input above the bound is chunked by commit, not truncated
  Given a changeset of 74000 changed lines
  When it is prepared for critique
  Then it yields one chunk per commit
  And no chunk is silently dropped

Scenario: nothing is ever silently truncated
  Given any changeset above any bound
  Then either the whole thing is handled or a named refusal is raised
```
→ spec file: `spec/lain/review/bounds_spec.rb`

**Escalation triggers:**
- A bound is reached and the honest response is truncation rather than refusal. Stop; the whole card
  exists because a quiet truncation reads as success.
- The critique chunking needs a bound the commit structure cannot supply, because one commit alone
  exceeds the context window. That is research open question 2b arriving unsolved — stop.

---

### T30 — Pay back the suite time this chunk spent          [wave 6, LAST] [risk: low]

**Depends on:** every card that ships a spec (run it after T25)
**Files:** `spec/lain/review/source/local_branch_spec.rb`,
`spec/lain/review/source/github_pr_spec.rb`, `Gemfile`, `spec/spec_helper.rb` (or a
`spec/support/` profiler hook), `CLAUDE.md`
**Shared-file wiring:** `Gemfile` and `CLAUDE.md` are orchestrator-owned — hand back diffs.

**This chunk made the suite slower and made CLAUDE.md wrong about it.** Measured 2026-08-04:

| File | Now | CLAUDE.md says |
|---|---|---|
| `review/source/local_branch_spec.rb` | **18.69s** | not listed |
| `isolation/worktree_handback_spec.rb` | 18.35s | 17.7s |
| `review/source/github_pr_spec.rb` | **14.08s** | not listed |
| `isolation/worker_handoff_spec.rb` | 13.63s | 12.9s |

`parallel_tests` packs whole FILES, so the longest single file is a hard floor: ~18.7s + ~1.1s load
≈ **19.8s**, which is exactly the observed wall. **Four files now sit above 13s where CLAUDE.md
describes two**, and `local_branch_spec.rb` — this chunk's own — is the new floor and appears in that
document nowhere.

Three jobs, in order:

1. **Profile with `test-prof`, do not guess.** Both new files drive real git in a tmpdir, which is
   the subject and cannot be faked (`shell_out_factory` exists for *failure injection*, and CLAUDE.md
   is explicit that a fake would test the fake). So the win is in fixture reuse, not in mocking:
   T10 already took its file 40.7s → 5.4s with a process-wide fixture template and by **copying** a
   seeded repo instead of `init`+`fetch`, with no assertion lost — apply that lesson to
   `local_branch_spec.rb`. `TagProf`/`EventProf` will say where the git spawns are; `before(:all)` +
   copy is the shape that worked.
2. **Then look at allocations and GC**, not just wall time — `test-prof`'s memory profiling, or
   `ObjectSpace.count_objects` around the hot paths. T7 measured 80,190 `SecureRandom.uuid` calls at
   0.13s on one changeset, and its anchors are built per walk; a spec that walks repeatedly pays it
   repeatedly.
3. **Re-measure and correct CLAUDE.md**, whose performance section reasons carefully from numbers
   that are now stale in two ways:
   - The floor is no longer `worktree_handback_spec.rb`, and the ranking it publishes is wrong.
   - **`spec_workers = physical - 1` is no longer optimal on this box.** Since zram swap was added,
     measured best-of-3: **n=7 → 22s, n=8 → 21s, n=9 → 20.7s, n=10 → 19s (19/19/19, imbalance 1.21,
     peak 1628MB), n=11 → 20s, n=12 → 23.3s (worst 29s, imbalance 1.47)**. n=10 is now the optimum
     and it is *past* the physical core count, which that section argues can never help. The memory
     ceiling that made 7 correct has moved; the reasoning must be rewritten around what actually
     binds now, not patched with new digits.

**Acceptance criteria:**

```gherkin
Scenario: the chunk's own specs are no longer the suite floor
  Given test-prof output for both review source specs
  When the fixture strategy is changed as profiling directs
  Then neither file is the longest in tmp/parallel_runtime_rspec.log
  And no assertion was removed to achieve it

Scenario: nothing was traded away for speed
  Given the optimised specs
  Then the example count is unchanged
  And every mutation the pre-optimisation suite killed is still killed

Scenario: CLAUDE.md matches measurement
  Then its named floor file, its ranking, and its worker-count guidance
       each match a best-of-3 measurement taken on a quiet box
```
→ spec files: the two named above; the CLAUDE.md change is prose, verified by re-measurement.

**Escalation triggers:**
- A speed-up needs an assertion dropped, a seam faked, or `:seam` coverage moved out of the default
  run. Stop — CLAUDE.md's testing section says the seam tier is 2.5% of examples for a third of the
  serial time **on purpose**, and the inner loop already exists as `--tag '~seam'`.
- Profiling says the cost is in git itself rather than in fixture setup. **Then the answer is NOT to
  split the file so packing can spread it.** One spec file per code file, at the mirrored path and
  name, is a convention that earns its keep — it is how a reader finds the spec for a subject without
  searching — and carving a unit spec into shards to game the packer trades that away for wall-clock
  the profiler said was not in our control anyway. Take the floor instead, or say plainly that the
  file is as fast as its subject allows.

  **Seam and integration specs are the exception**, because they are not unit specs and the mirror
  convention is not describing them. But CLAUDE.md already draws that line precisely, and it is not a
  licence to split: **a seam with an obvious subject stays at its mirror path and carries the `:seam`
  tag**; `spec/lain/seams/` exists only for seams belonging to **no single subject**. Both files here
  have an obvious subject (`LocalBranch`, `GithubPr`), so they stay where they are. Moving a genuinely
  subject-less seam example out is legitimate; relocating examples that plainly belong to one class
  is not.

---

### T25 — Verify every deletable capability is deletable          [wave 6] [risk: low]

**Depends on:** T17, T18, T22, T23, T24
**Files:** `spec/lain/review/deletability_spec.rb` (new, tagged `:seam`)
**Reuse:** `spec/output_discipline_spec.rb` as the exemplar for a spec that reasons about the tree
rather than an object; the deletion map in this plan as the data.
**Shared-file wiring:** none.

Joel's constraint is that parts which do not work out are easy to delete. A plan that says so and a
suite that proves it are different things.

A reference sweep alone is necessary and **not sufficient**: it proves nothing points at the
capability, not that the tree still builds and passes without it. So this card actually deletes.
For each capability it copies the tree, removes that capability's files **and its dependents from the
deletion map** (diagnostics forces prefill, thread forces docent, GitHub source forces submit), and
runs the suite against the copy. That is slow, so it is tagged `:seam` and excluded from the inner
loop, but it is the only version of this card that means what §Intent claims.

**Acceptance criteria:**

```gherkin
Scenario: deleting a capability leaves a green suite
  Given a copy of the tree with one capability's files removed
  And its dependents from the deletion map removed with it
  When the suite runs against that copy
  Then it is green

Scenario: no file outside a capability references its constants
  Given the deletion map's file list for each capability
  Then no file outside that list and its dependents names its top-level constant

Scenario: the deletion map covers every file a capability owns
  Given the files each capability's constants are defined in
  Then every one appears in that capability's deletion map row
```
→ spec file: `spec/lain/review/deletability_spec.rb`

**Escalation triggers:**
- A capability turns out to be referenced from the core. That is the seam being wrong, not the spec
  being strict — stop and re-cut rather than widening the deletion map.
- The delete-and-run copy takes long enough to be skipped in practice. A check nobody runs is a fig
  leaf; stop and find a cheaper honest proof rather than shipping one that gets excluded.

---

### T31 — Make the review surface reachable          [wave 7] [risk: high]

**Written 2026-08-05, critiqued before implementation, and re-cut into three cards by that critique.**
The first draft proposed `lain review --nvim=<socket>` as a long-running process. Two seats returned
independently and killed it. Both were right, and the record of why is worth more than the draft was.

**What the critique found that the draft had wrong:**

1. **The gap is worse than the draft said.** Not "reachable only through an epic" — reachable
   **nowhere**. `wiring.rb:370` mounts the epic with `notify:` and `bindings:` only, so
   `changesets:`/`surface:` stay nil, `Implementation#hold` returns `Refusals.no_changeset` on every
   production call, and the surface resolves to `Null`. **`Review::Surface::Neovim` has zero
   construction sites in `lib/` or `exe/`.** Verified independently by the orchestrator.
2. **A premise of the draft was simply false.** It claimed only `lain up` injects `_G.__lain`, quoting
   `CLI::Review`'s own doc. **`RpcThread#attach` injects the runtime itself** —
   `@client.exec_lua(RUNTIME.source, [@version, @protocol, @client.channel_id])` (`rpc_thread.rb:1009`).
   The attaching process is what creates `_G.__lain`. The explicit-socket rule survives, **for the
   opposite reason**: attaching does not fail quietly into a plain editor, it **takes the editor
   over** — buffers, tabpage slots, keymaps, autocmds and the command channel. Never do that to an
   editor nobody offered. `CLI::Review`'s doc carries the same false sentence and must be corrected.
3. **The verdict rail is bound by nobody.** `Router` (`rpc_thread.rb:645-670`) splits the five review
   verbs: `review_open`/`review_mark`/`review_ask` are **acked** to the command inbox and consumed by
   `HumanReplies::Gestures`; `review_annotate`/`review_verdict` are **answered** through
   `FrontendListener` to whatever `Frontend::Neovim#bind_changeset_review` holds — **and that method
   has no caller in `lib/` or `exe/`.** Notes and verdicts reach `NoReviewWrites`. The draft's
   scenarios 4 and 5 both rode that unbound rail and neither its Files nor its `Gestures` triple
   mentioned `wrote_annotation` or `wrote_verdict`.
4. **The object the draft wanted already exists.** `Tools::RequestReview::ChangesetReview`
   (`request_review.rb:678`) already answers all five messages and declines four only because it holds
   no view. It is in the wrong namespace and carries one collaborator it should not require — the epic
   baton. A *third* thing named `Gestures`, in a tree where `HumanReplies::Gestures` is a verb router,
   is the drift this codebase spends paragraphs preventing.
5. **Every valid invocation of the draft's command was a double-attach.** The human's only socket is
   the cockpit's, which a chat already owns. A second attach re-injects the runtime with its own
   channel id and reassigns every `_G.__lain.*` function, silently stealing `:LainReply` and every
   review verb from the parked chat; on exit it leaves a dead channel. The draft's ACs tested a bare
   nvim and a lain-attached nvim, and never the only case that can occur in the field.
6. **Four of six ACs passed while broken**, and two of the three messages the card existed to create
   (`open`, `ask`) had no AC at all — while `ReviewView#open`'s only `changesets:` implementation is
   `Unwired` (nothing in the tree answers `#open(path, line)`) and `Review::Docent` is never
   constructed outside `Answerer`.

---

#### T31a — `Review::Handover`: the open review, as the rails see it          [risk: medium]

**Depends on:** T13, T19. **Files:** `lib/lain/review/handover.rb` (new, moved out of
`Tools::RequestReview::ChangesetReview`), its spec, `lib/lain/tools/request_review.rb`,
`lib/lain/cli/wiring.rb`, `lib/lain/cli/epic_mount.rb`.

Move `ChangesetReview` to `Review::Handover`, constructed with `session:`, `view:` and `baton:`. The
epic tool passes its `Epic::Review::Token`; an epic-less caller passes a **null baton whose `settle`
is genuinely a no-op** — honest here, unlike `home`/`review` in `EpicMount`, which have no honest
null. Answer all five messages for real; `Unrendered` and `NO_ANCHOR` go away.

Then **bind it to BOTH rails** — `@bindings.bind_changeset_review` *and*
`Frontend::Neovim#bind_changeset_review` — and thread `surface:`/`changesets:` from `wiring.rb:370`
as thunks on the seam `bindings: -> { @replies }` already proves. `epic_mount.rb:230-253` says in as
many words that the seam is threaded rather than absent precisely so a caller can inject rather than
edit that file.

**This card makes the epic implementation gate work for the first time**, independently of any CLI
change, and it is the prerequisite for both cards below.

- **AC:** a production wiring supplies `changesets:` and `surface:` — assert it at the wiring, since
  no test among 10865 examples does; `Implementation#hold` no longer refuses with `no_changeset`; a
  `review_verdict` on the answered rail reaches the session and settles it; a `review_annotate`
  journals an `AnnotationPlaced` whose `drifted` was **forwarded from the wire, not computed**.
- **Escalation:** if the null baton needs behaviour, the baton belongs to the epic and this is the
  wrong cut.

#### T31b — `/review <target>`: the smallest thing that puts a human in front of a PR          [risk: medium]

**Depends on:** T31a. **Files:** one file under `lib/lain/cli/command/`, one `Command::Env` reader,
one `Wiring` line, one deletion-map row, plus its spec.

A repl command inside the existing cockpit. The frontend is already attached, the process already
stays up, `HumanReplies` already routes the acked gestures — so there is **no second attach, no second
process and no lifetime question**. Resolve through `CLI::Review::Target` (already extracted, already
tested, already handles PR/branch ambiguity and `--base`), build the `Changeset`, open the `Session`
with `Surface::Neovim`, bind the T31a `Handover`.

Human story: `lain up --nvim` then `/review 4821` — one context, on the rail their `ask_human` replies
already ride, with the agent in the room.

- **AC:** drive gestures **through the command inbox**, never by calling the object — that seam is
  where this chunk's defects live. A **stale generation must refuse**, and the refusal must reach
  `review_refused`; without that counter-example a stamp-checking implementation is
  indistinguishable from one ignoring the stamp. Read `lain://review` back out of a **real editor**
  under `LAIN_NVIM=1`.
- **Escalation:** if `open` or `ask` cannot be made to work, scope them out **by name** — `ReviewView#open`'s
  collaborator is `Unwired` and `Docent` is unconstructed, so both would otherwise ship as permanent
  silent refusals.

#### T31c — `lain review attach --nvim=SOCKET TARGET`: the standalone server          [risk: high]

**Depends on:** T31a, T31b. Only if a review genuinely must happen outside a chat — **want evidence
first.**

Keep `CLI::Review#present` byte-identical: one-shot, Text, returns a String. Add a **separate object**
owning attach/serve/teardown, mounted as a second Thor command beside `open`. Precedent: `CLI::Up`
beside `CLI::Chat`. Scenario "without `--nvim` nothing changes" then stops being an assertion and
becomes structural.

Carries the work the draft did not cost: **rail ownership in the runtime** (refuse or take over by
name when a live channel already owns it), the protocol bump that implies, a spec driving **two
attaches at one socket**, and **moving `Bounds#check_presentation!` onto `Session#present`** — the
follow-up `CLI::Review`'s own doc already wrote, and which this card is the one to trigger.

- **Escalation:** if serving gestures needs the RPC thread to block, stop — established twice.
  If the verdict rail and the process exit disagree about when the review is over, the lifetime is in
  the wrong object.

#### Kept verbatim from the draft, because both seats endorsed them

- The gesture leg is a **separate object** from `Surface::Neovim` — the port owns `mark` outbound and
  the name is taken (`surface/neovim.rb:135-145` asks for exactly this object).
- **Serving gestures must never park the RPC thread.**
- Explicit socket, never `$NVIM` — right rule, corrected reason (see 2 above).
- Reuse `CLI::Review::Target` unchanged; that extraction is what makes the split cheap.

#### The free follow-up, in whichever lands first

One example over `LainCLI.commands.keys`. It caught nothing only because nobody wrote it — the same
class of miss that hid `lain review` from the CLI for the whole chunk.

#### MEASURED: two lain processes on one editor is silent data destruction

The third seat did not reason about the collision — it built two `Frontend::Neovim` instances against
one headless nvim and measured. This is why T31c is last and why "one lain per editor" is a rule
rather than a preference.

**Every inbound gesture is stolen, silently.** Re-injection rebinds `chan`, the chunk-level local at
`runtime.lua:27` that every callback closes over, and every `:Lain*` command and augroup is redefined
against the new one (every augroup is `{ clear = true }`). One `:LainSend` at each step:

| | client A's inbox | client B's inbox |
|---|---|---|
| A alone | `[["send"]]` | — |
| after B attaches | `[]` | `[["send"]]` |

A is still running, still attached, still rendering, and receives nothing forever with no error on
either side. That is `:LainReply`, `:LainResend`, `:LainPin`, `:LainOpen`, `:LainNote`, `:LainThread`
and every review verb. **A human's chat replies stop reaching the chat the moment they open a review.**

**The first client's rendered content is destroyed.** `Surfaces#prime` posts every view's at-rest
state on attach, and `post_view` is a whole-buffer replace, so a review process attaching with a
`DetachedStore` primes *empty* projections over the chat's live ones. Measured on `lain://journal`:
`["[tu_0 stdout] client A rendered line 0", …1, …2]` → `[""]`. **This is why T31c cannot simply build
a `Frontend::Neovim`** — it needs the RPC rail without the chat's projections, and
`Neovim#initialize:185` constructs `Surfaces` unconditionally with no injection seam.

**The human's whole review is discarded, and the discard reports success.** Every review lua module
keeps state in a chunk-level local (`review_annotations`, `review_notes.by_buf`, `review_diff`,
`review_thread`, …); re-injection makes them all empty while the **extmarks and `● note` virtual text
persist on screen**. So `:LainReviewDone` harvests extmarks, finds every id missing from
`review_annotations`, and skips them all; `:LainNoteDone` sends `review_notes.settled()` — now empty —
which Ruby **accepts** (`refused_batch([])` is nil, so the batch reads as taken), after which
`review_notes.forget()` runs. The human sees their annotations, submits, and everything is thrown
away with a success report. **That is this chunk's signature failure, reachable by the exact action
the draft proposed.**

**Generation aliasing crosses processes.** `ReviewView` counts per instance from zero, so both mint
generation 1, 2, 3…; the editor stamps `b:lain_view_generation` from whichever wrote last, and
`resolve_marks` finds `held.generation == generation` in the *wrong* process's held renderings. Rows
from a different changeset, marked, reported as landed — most likely on generation 1, the first
rendering each side draws. This is exactly the aliasing protocol 8 replaced the line count to fix,
reintroduced one level up by process multiplicity.

**Nobody owns cleanup.** After the second client exits: `_G.__lain` still present, all six `lain://`
buffers still present, and every gesture raises `Invalid channel: 5` at the keystroke. The editor
advertises a lain runtime it no longer has. T31c must add a detach — clear the ownership marker, fire
`User LainDetach`, leave the buffers (they are the human's record) — called from `RpcThread#stop`
before the socket closes. That is also what makes the takeover check accurate rather than heuristic.

#### AC1 as drafted cannot observe a draw at all

`Surface::Neovim#present` returns `RenderInlet#refusable`'s answer, and the render goes out as a
**notification** — deliberately, so a request cannot nest a read. **A nil answer means "queued",
never "drawn."** So `expect(present).to be_nil` is precisely the vacuous green this chunk keeps
finding. Assert it the way the tree already does: a **second, independent connection** as inspector
(`review_view_spec.rb:563`, `neovim_runtime_spec.rb:47` are the pattern), reading
`nvim_buf_get_lines(bufnr("lain://review"))` back, asserting the lines **contain a file from the
changeset under review** — not that the buffer exists, which proves only that `prime` ran.

Two ACs the draft needed and did not have: **a review attach must not disturb the session views**
(the direct test for the journal-clobber above, which fails against today's `Frontend::Neovim` by
construction), and **a review that ends leaves no editor claiming to be attached**.

#### The answered verbs run ON the RPC thread, inside nvim's `:w`

`review_annotate` and `review_verdict` are **answered**, not acked, so whatever
`bind_changeset_review` holds must answer **synchronously, without I/O, without a lock another thread
can hold, and without raising** — `Neovim::NoReviewWrites` is the shape. A one-shot CLI has no
reactor, so the obvious implementation points `bind_changeset_review` straight at the `Session` — and
`Session#submit` writes the journal. That is I/O on the RPC thread inside the editor's write, which
is how the >20s frozen nvim already documented at `rpc_thread.rb:1070` happens. **If the verdict
handler needs to wait for anything, it must not be the answering verb** — make the verdict acked and
exit on the record, not on the write.
## Integration checks

**Results so far, 2026-08-05, at `1177951` (T18 and T28 landed; T24 in its fix round).**

- **2 — lint.** `bundle exec rubocop` bare: **1147 files, no offenses.**
- **3 — the nvim specs really ran, proved by a control rather than by a count.**
  `LAIN_NVIM=1 rspec spec/lain/frontend/ spec/plugin/` → **1002 examples, 0 failures**;
  `LAIN_NVIM=0` over the same paths → **696**. So **306 examples genuinely drove a real editor**.
  The count alone would not have shown that — which is the whole point of the check, since a
  silently-skipped tag reads as a clean run.
- **4 — Rust untouched, confirmed.** `cargo test` **288 passed, 0 failed**;
  `cargo clippy --all-targets -- -D warnings` clean.
- **5 — deletion.** T18, T23, T24 and T28 each performed their own delete-and-run and each returned
  its stated baseline exactly. T25 automates the sweep; this row is the end-to-end confirmation and
  is still owed.
- **Repository integrity** (added after the reboot): `git fsck --full --strict` exit 0, no zero-byte
  objects, every ref resolves.

Still owed: 1 (final count against a serial run), the rest of 5, and all of 6.

**Manual pass, 2026-08-05 — what it verified against a real machine.** Driven in kitty on Joel's
display: `lain up --nvim=<socket> -- --provider ollama`, qwen3:4b resident at 100% GPU (5.2 GB,
ctx 32768, ~71 tok/s), nvim 0.12.4 with the runtime attached (`exists(':LainSend')` = 2), a real turn
round-tripped through `POST /api/chat`.

| checked | result |
|---|---|
| `lain review` reachable | **was not** — never mounted; fixed at `48161e4` |
| the cockpit starts | **did not** — E488 on every `--nvim`; fixed at `9f6043b` |
| cumulative scope, real branch | 27 files rendered |
| commits scope, real branch | the walk, per commit |
| unresolvable ref | exit **1**, message on stderr, stdout empty, no backtrace |
| **T29 bounds guard** | fires for real: *"the cumulative view is 35775 rendered lines, over the ceiling of 30000 — present it per commit"*, exit 1, nothing drawn |
| the guard's remedy | **works** — the same range at `--scope commits` renders 50 commits in 246 lines |
| **T10 PR path** | reaches GitHub live; a nonexistent PR refuses by name carrying the GraphQL reason |

**Still owed and not doable here:** a real PR at work scale (this repository has no pull requests, so
the 300-file fallback and `gh pr diff`'s header shape remain unobserved — exactly what T10's own
hand-back said it could not check), and the editor review itself, which is blocked until T31a and
T31b land. The manual pass could not reach a single one of waves 3–5's editor capabilities, and that
is the finding, not a gap in the pass.

After the last wave:

1. `bundle exec rake pspec` green. **Check the example count against a serial run** before believing
   it; a dead worker reports as "fewer examples, 0 failures" (CLAUDE.md, and
   `verify-subagent-suite-claims`).
2. `bundle exec rubocop` (bare, never naming a `.toml`) and `pre-commit run --all-files` green.
3. `LAIN_NVIM=1 bundle exec rspec spec/lain/frontend/ spec/plugin/` — the nvim specs are opt-out and
   must actually have run.
4. `cargo test && cargo clippy --all-targets -- -D warnings` unchanged (no card touches Rust; this
   confirms it).
5. Delete each `[deletable]` capability per the deletion map, run the suite, restore. T25 automates
   the reference check; this is the end-to-end confirmation.
6. **Manual pass owed to Joel** (none of these can be automated):
   - Review a real branch with `lain review`, walk the commits, mark hunks, place notes of each kind,
     submit a verdict.
   - Review a real GitHub PR at work scale, confirm the 300-file fallback fires and says so, promote
     2 or 3 critique findings, and post them. **Two things T10 could not observe and explicitly owes
     this pass**: (a) the live 300-file refusal string — it is pinned from primary sources (API
     `HTTP 406` + `{"code":"too_large"}`, gh relaying *"Sorry, the diff exceeded the maximum number
     of files (300)"*) but never seen, though the design inverts the risk so that a wording change
     costs a *label* and never a truncated diff; (b) whether `gh pr diff`'s **header shape** matches
     `git diff`'s, which is an open assumption — the design does not depend on it (deleting one
     method routes everything through the object database), but it has never been checked against
     real gh output.
   - Drive one epic implementation gate end to end and confirm the agent unparks.
   - Ask the docent 3 questions during a review and judge whether the answers are worth the tokens.
   - Confirm `:Telescope diagnostics` browses review annotations.
7. Confirm no file owned by `planning/specs/chunk-guardable-petgraph-propcheck.md` was touched:
   `git diff --name-only main... | grep -E 'lib/lain/config|lib/lain/guard|ext/lain/|Gemfile|spec/support/(prop_check_setup|algebra_generators)'`
   must be empty.

<!-- link reference definitions -->
[tuicr#247]: https://github.com/agavra/tuicr/issues/247
[tuicr#475]: https://github.com/agavra/tuicr/issues/475
[octo#118]: https://github.com/pwntester/octo.nvim/issues/118
[octo#854]: https://github.com/pwntester/octo.nvim/issues/854
[diffview#457]: https://github.com/sindrets/diffview.nvim/issues/457
[diffview#466]: https://github.com/sindrets/diffview.nvim/issues/466
[diffview#509]: https://github.com/sindrets/diffview.nvim/issues/509
