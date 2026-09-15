# Round 18 findings against the round-17 discharge: what changed, and why

**Purpose.** Before a fix plan is written for round 18's HIGH, MED-HIGH and MEDIUM findings
(`../qa-findings-round18-2026-09-15.md`), establish for each one:
- what most recently changed in that code;
- **why** it changed that way;
- whether the finding is a regression, a gap, old behaviour, or a design someone ruled on.

The aim is that the plan does not undo a deliberate decision or repeat a rejected approach.

**Method.**
- Seven read-only research passes, one per subsystem, at `main` `90f081b9`.
- Each re-verified the finding's mechanism against current code with file:line citations.
- Each traced it through the discharge chunk (`../specs/chunk-qa-round17-the-record-the-human-the-window.md`:
  its cards, Landed SHAs, Execution-log rulings and follow-ups), older plans, `git log -S`/`-L` and
  in-code design comments.
- Nothing was run, and no code was changed.
- Anything inferred rather than read is marked so in the detail files.

| detail file | findings |
|---|---|
| [`secret.md`](secret.md) | F131, F133, F138, F140, F141, F155, F156, F166 |
| [`compaction.md`](compaction.md) | F136, F152, F154, F160, F161, F173, F199, F201, F203 |
| [`repl.md`](repl.md) | F132, F142, F145, F146, F147, F153, F162, F171, F172, F179 |
| [`review.md`](review.md) | F133, F143, F144, F157, F158, F159, F160, F183–F185 |
| [`epic.md`](epic.md) | F148–F151, F154 (epic), F163–F165, F192–F194 |
| [`subagents.md`](subagents.md) | F134, F135, F137, F166, F167–F170, F177, F178, F195–F198 |
| [`exec.md`](exec.md) | F139, F147 (exec), F189, F200, F202, F205 |

Classification key:
- **(a)** a regression introduced by the latest fix;
- **(b)** a gap left outside a card's scope, whether the card knew or not;
- **(c)** pre-existing behaviour the chunk never touched;
- **(d)** by design, with a ruling owed or taken;
- **(e)** the finding or its scenario is wrong.

---

## 1. The headline

**The round-17 discharge introduced no regression among the 47 HIGH, MED-HIGH and MEDIUM findings.**
Every one is classified (b), (c) or (d); none is (a). Two LOW-level exceptions:
- **F183(a):** `lain survey`'s text group header, exposed by T26's row-base change `c3ccaa39`.
- **F160's raw JSON:** a regression *by interaction*. T24's `truncate:false` turned a child's silent
  truncation into a raise whose message is JSON, on a path T21's generic rescue prints verbatim.

**What the chunk did do, repeatedly, is make an old gap reachable, visible or ordinary:**

| chunk change | what it exposed | finding |
|---|---|---|
| T8 `c6f64656` added a real-path check to automatic approval | the child is now measured against the *wrong* tree, where before both parent and child were approved | F138 |
| T8, the human's ruling "root predicate + widened GATED" | content was never an axis; round 17's own F91 text had a "Why no mask" paragraph the ruling did not take up | F131 |
| T22 `ad045078` made lineages readable | `consolidate` now reaches a pass that has persisted nothing since July; child transcripts now reach remote-default prompts | F134, F166 |
| T23 `1cfdf970` made `+auto_approve` a live mid-session switch | a judge role that was never marked `unattended` can now park a human question | F141 |
| T24 `4cf30b98` refused over-window prompts instead of truncating | a tail that fills the window is now a visible wedge; a child's overflow is a 400; a full-cover read that no 32k request can carry is now the ordinary route to editing unseen lines | F173, F160, F199 |
| T7 × T24 | a withdrawal takes a cut's commit head off the chain, so the same cut is re-committed on every stuck ask | F173 |
| T6 `command>` reader | `/fork`'s documented premise ("nothing else can run while an approval is read") stopped holding | F145 |
| T10 `4b0778f8` gc guard | a checkout at its cut point is retained 7 days instead of reaped, which lengthens F149 and F198 | F149, F198 |
| T14 `bfe984e9` scoped to the chat's three tiers | every non-chat model-calling command was never in scope | F154 |

**The recurring structural cause is the round-17 pattern one level out: a fix lands at the site that
was driven, not at the owner.** The research groups name it independently:
- the model-phase wiring exists only on the main chat stack (F154, F160, F201);
- watcher lifetimes are bound to a dispatched line (F142);
- the approval rule's subject is `(tool, input)` only, so session facts are discarded at
  `Escalation::Rules#call(effect, _context)` (F131, F138);
- secondary commands do not inherit the session's backend (F132, F154, F166);
- run state is not scoped to the chain it measured (F136, F199, F203);
- bookkeeping is written on success paths only (F137, F148, E18-14).

---

## 2. Classification, all 47

| id | sev | class | the change that matters, and why it is this way |
|---|---|---|---|
| F131 | HIGH | (b) | T8 `c6f64656`. The human ruled "root predicate + widened GATED". File content was never an axis of the shell-approval plan; `RedactSecretReads` guards `read_file` only "until [a tool] earns a place" (`a07d8b66`) |
| F132 | HIGH | (c) | `/fork` and `/btw` since 2026-07-23. "The current flags win" is a recorded ruling (`f9ca95fa`) made for a human who types flags, not for a composed command with none. The session header records no `provider` |
| F133 | HIGH | (b)/(c) | The raw NEW buffer is a round-11 ruling. `dd5cfdec`'s written contract says the *journal* must never carry unprojected bytes, and nobody traced `anchor_text` from the buffer into it. The chunk never touched it |
| F134 | HIGH | (b) on (c) | In-memory Recorder and Null journal since `ef4cfb9f`, with M5's durability follow-up owed since July. T22 made the pass reachable. The scenario's "fresh session sees it" is **(e)**: memory is session-chain scoped by design |
| F135 | HIGH | (b) | `JournalTurns` writes a `tool_use` turn only after its tools finish, while a spawn cites it at start. Round 14's `b679ed46` fixed this for children only; T22 tolerated it in one reader (`Lineages::InFlight`) and filed nothing |
| F136 | MED-HIGH | (c) | `REASK_LIMIT` is round-3 T6's deliberate bound (`2301a03d`) against ~2 s probes of a black-holed host. Its premise, that the chat's own first request is all that touches the server, was falsified this round. Also disables `/critique` (`UNVOUCHED`) |
| F137 | MED-HIGH | (c) | `spawn_one_shot` has no failure arm, and the lease-after-spawn order dates from `994f894d`. The lifecycle vocabulary is round 15's closed, ruled set |
| F138 | MED-HIGH | (b), known | T8 review S5, filed as a follow-up that predates the chunk. T8's real-path check is what made the wrong tree matter |
| F139 | MED-HIGH | (c) | Round-8 T2 `6ab98dd2`, "deliberately bare". The leak was accepted in the docstring on the false premise that ignoring TERM is unusual; every PID 1 without a handler does |
| F140 | MED-HIGH | (d)+(b) | `e3c1237e` refused path-shaped patterns "on purpose… widenable later"; the per-entry exempt cap is deliberately not table-wide. The table-wide-cap ruling is owed (T8 S4). "The only way" is wrong: a home-anchored exact path works when the project is under `$HOME` |
| F141 | MED-HIGH | (c), widened by T23 | `auto_approver`/`gate_adjudicator` were never marked `unattended` (`b697adf9` marked only the resolver and docent). The fork's cited mechanism (`NoAskers`) is wrong. The stuck inbox/fleet is a missing *record*, the F137 and T17 precedents |
| F142 | MED-HIGH | (b) | Every approval watcher lives for one dispatched line (since `71e7d13f`, chosen for *terminal* readers); the non-terminal watchers inherited that without the reason. The docent runs outside any line. By code reading, the auto-approver and secret oracle likewise do not run between lines |
| F143 | MED-HIGH | (b)/(d) | Bind-before-draw is deliberate (`5607b2db`, `7b6fa060`, "the honest state"). A verdict landing on an undrawn round, and the stale sidebar, were never ruled on. `/survey` has the same rails issue |
| F144 | MED-HIGH | (c) | The review design silently assumed the checkout is at head. It also applies to PR reviews, where the checkout almost never is |
| F145 | MED-HIGH | (b) | T6's `command>` falsified `fork.rb:82-88`. T3 unified `/rewind` and `/undo` onto one in-flight predicate; `/fork` kept a question-only test, and `/btw` has no door at all (unfiled) |
| F146 | MED-HIGH | (c) | Since `3e8502e0`, recorded as a T4 follow-up and not carded. Worse than filed: under `--no-journal --nvim`, `/mode plan` moves the LABEL while the gate policy and toolset stay put, and approval and escalation records are dropped (code read) |
| F147 | MED-HIGH | (c) | Mixlib's `STDIN.reopen` on a shared buffered description, found by T29 and never carded. About ten mixlib callers; which one fired in the repro is unproven |
| F148 | MED-HIGH | (c) | Since `e92c4483`, whose own message says a refusal "stops its own issue and never the run" |
| F149 | MED-HIGH | (b) | The per-project path is from `e92c4483`, kept by T19 when it added the lock. T10's correct guard retains it `retain_days` |
| F150 | MED-HIGH | (b) | Two pinned rules collide: "reuse an owned branch where it stands, never force-move" and "generation must change the target". The finding's "reset per attempt" contradicts the first |
| F151 | MED-HIGH | (b) | Outside T5's scope (torn lines, `approved`). **Wider than filed:** a misspelt `policy`, and damaged `epic_slug`/`issue_id`, also fail open (code read). The read-side stage fold already validates stages; the sign-off fold does not |
| F152 | MED-HIGH | (c)/(d) | `fb0c74f9` ruled "the answer's absence is the signal". `a0655c6e` chose structured output to fix exactly this failure locally, never verified hosted. Identical capabilities on both deployments are a deliberate experimental control (`deployment.rb:93-99`) |
| F173 | MED-HIGH | (b), known | Round 15's retained-tail deferral, Open decision 2 and T7 S4 (owed). T7 × T24 re-commits the same cut per stuck ask. **The finding is partly wrong:** the refusal never names `--compact-keep` (that is the stderr stall line), and "a summarizer call per stuck ask" is not in the rails journal |
| F199 | MED-HIGH | (c) | `ReadSet` is add-only by design (`08b9ab01`, and the monotonicity argument at `session.rb:574-597`). T24 made the route ordinary. It also survives `--resume` |
| F200 | MED-HIGH | (c) | `036e6ec0` placed the one bound in `render_output` so every arm refuses byte-identically; memory was never weighed. T1 changed encoding only. A timeout message also copies the whole capture |
| F153 | MEDIUM | (c)/(b) | **Not the watcher lifetime the finding blames.** Both readers take one stdin lock, and T13 deliberately writes no "decided by" line for a prompt that never drew |
| F154 | MEDIUM | (b) | Outside T14's scope, whose "Reachable from" names the chat's three tiers. `bench record` is affected too. The env read lives in the exe's Thor `default:` on purpose |
| F155 | MEDIUM | (c) | Config names compile `Rule.named` (basename) where built-ins use `Rule.within`. Switching `exempt` to segment matching would undo T8's exact/beneath split |
| F156 | MEDIUM | (c) | `a07d8b66`'s reason ("the approval's own decision record is what says a secret was sent") is false: that record carries no path, count or id |
| F157 | MEDIUM | (b)+(d)+(e) | The replay was built and never wired. Whether a resumed reopen is "the same round" is unruled against round-scoped notes. The survey scenario's §7 check 4 is **(e)** |
| F158 | MEDIUM | (b) | Round-11 T13 fixed the file-count refusal only; the line refusal reuses `/review`'s sentences |
| F159 | MEDIUM | (d) | Verdict vocabulary is research open question 3. Round 11 recorded the missing close gesture; T6 chose not to build it |
| F160 | MEDIUM | (b), known | T21: "T24 does not cover child requests". T24's own escalation trigger named children and was never escalated. Raw JSON is (a)-by-interaction |
| F161 | MEDIUM | (c)+(d) | Derived-context follow-up 14 (pin semantics: drag the counterpart or refuse a lone pin) owed; T7 S5 beside it |
| F162 | MEDIUM | (d) | Follows from the modes chunk's "no `mutates?` axis" ruling. No stated reason was found for `manual` existing as it does |
| F163 | MEDIUM | (d) | "Drained" is the recorded interview ruling, endorsed by `epic-tier` §6. **Take this ruling before F151's fix** |
| F164 | MEDIUM | (d)+(c) | No timeout: deliberate since `7dfdd9dd`, kept by T17. Latency ≈ 0 contradicts `GateDecision`'s own "a measurement nobody made" rule. The Ctrl-C backtrace: `render` rescues only `Lain::Error` |
| F165 | MEDIUM | (b) | The loss is in `CLI::Epic#merge` (from `82bd3784`), not `Graph#merge`; T18 edited that method for provenance only |
| F166 | MEDIUM | (b) | T22 put child transcripts into both scaffolds. The `anthropic` default (which ignores `LAIN_PROVIDER`) and improve's parent-turn text are (c) |
| F167 | MEDIUM | (c)/(d) | Known since 2026-07-15. The M6 panel rejected a hybrid≥ unit assertion and corpus-fit `RRF_K`. `hybrid_spec.rb:54-66` pins the property that causes it |
| F168 | MEDIUM | (c) | The body bound exists to mirror `memory_read`; the manifest was never considered. T24 turned the consequence into a hard refusal |
| F169 | MEDIUM | (c) | `79face26` answered a crashed session with a clean Ctrl-C exit, not a conclusion. The two liveness idioms disagree on EPERM |
| F170 | MEDIUM | (c) | The exe maps only `Lain::Error`. Very likely the same for `.lain/summarizers.rb`, which shares the loader (not driven) |
| F171 | MEDIUM | (b)/(d)+(c) | The one-line arrival and "name both surfaces" (`40160943`) are deliberate; T13 made the pointer typeable in a chat with no buffer. Not drawing the document before a live `human>` was owned by no card |
| F172 | MEDIUM | (d)/(c) | Ctrl-C is a shutdown request by design (xdg-resume decision 6); "stop this ask" was never designed |
| F201 | MEDIUM | (c) | **The finding's citation is wrong.** The provider journals through `Backend#journal`, which stays Null because bench never calls `pipeline_source`. `provider_wait` is lost too. `variance` ignores `truncated_stream` anyway. T9's `capability_degraded` follow-up is the same class |
| F202 | MEDIUM | (b)+(e) | T24 withdraws only on over-window, and `agent_spec.rb:1029` pins "leaves any other failure's prompt committed". After a wire attempt the harness cannot prove no model saw it (`resend_bridge.rb:29-36`). `failure-injection` §1b's "no turn committed" is **(e)** |

---

## 3. Corrections to the findings file

**Applied to `../qa-findings-round18-2026-09-15.md` alongside this document:**

- **F141:** the cause is the judge roles' missing `unattended: true`, not `NoAskers`; the stale
  inbox/fleet is a missing retirement record.
- **F140:** "the only way" is wrong. A home-anchored exact exemption lifts one file when the project
  is under `$HOME`.
- **F153:** not the per-line watcher. It is one stdin lock plus T13's undrawn-prompt exclusion.
- **F173:**
  - the over-window refusal does not name `--compact-keep`;
  - it names compaction only while something is droppable;
  - the per-ask summarizer cost is unverified;
  - add the T7 × T24 re-commit mechanism.
- **F201:** the journal is `Backend#journal` (Null on the bench path), not the provider constructor
  default; `provider_wait` is lost too.
- **F151:** wider. Policy, slug and issue damage also fail open (code read).
- **F154:** add `bench record`.
- **F133:** capture sites are `48_annotate.lua:544`, `52_note_compose.lua:231` and `65_review.lua:331`.
- **F165:** the loss is in `CLI::Epic#merge`.
- **F136:** it also disables `/critique` for the session.
- **F146:** worse. The posture label moves while the policy does not.
- **F137:** lineage readers silently skip open spawns rather than seeing them.
- **F150:** the proposed "reset the branch per attempt" contradicts a pinned rule.

---

## 4. Checks to take before a card is scoped

These rest on code reading and change a card's size if true:

1. **F135's reach.** Does a SIGKILL during *any* tool call (not only a spawn) strand `--resume`
   through `memory_root` (`memory_replay.rb:112-116`) or a main-agent `ask_human`
   (`ask_human.rb:369-371`)? If so, the scope is "any crash mid-tool".
2. **F142's reach.** Do `+auto_approve`'s judge and `--secret-oracle` also fail to run for a call that
   parks between lines?
3. **F141's second half.** Can an `unattended` child still park on the *approval gate* through a gated
   `read_file` or a region release, contrary to `role.rb:77-78`'s claim?
4. **F147.** Which mixlib caller rewound stdin in R4? The shadow-git snapshot or bash's string arm.
5. **F170.** Does `.lain/summarizers.rb` die the same way through the shared loader?
6. **F151.** Drive the `policy`/`epic_slug`/`issue_id` damage rows. The widening is code-read only.
7. **F173.** Re-read a stuck session's journal for `oracle_answer` per stuck ask, before costing it.

---

## 5. Decisions owed to the human, before planning

Grouped by what they unblock. Items marked **owed since the chunk** are already on the chunk's
close-out list; the rest are raised by this research.

### The secret boundary

1. **Which rung owns file CONTENT under automatic approval (F131)?**
   - (i) Pre-exec: the approver abstains on region-bearing bytes or a non-world-readable mode. This
     has a TOCTOU window and costs a read.
   - (ii) Post-exec: mask or refuse the result of an `authority=automatic` `bash` call.
   - (iii) Both.

   A mode check alone misses a 0644 copy; a ledger-path check misses hardlinks and copies. Adding
   `bash` to `GUARDED_TOOLS` is not an option: the mask keys on a `path` bash lacks.

   Related: is round-10 F63 under `/mode auto` in scope?
2. **May a `Rule::Call` carry session facts (the ledger, the worker env)?** It is a locked,
   compare-by-value, forgery-guarded interface, and it decides whether F131 and F138 are fixed at the
   rules rung or via the `Classifiers` factory.
3. **Should a leased child be confined to its own worktree (F138)?** That needs a per-child factory,
   with triage re-anchored too. The alternative is that ComposedTerm abstains for any requester whose
   cwd is not the board's.
4. **Project-anchored config patterns (F140, F155), one ruling.**
   - Define the reserved "later" (a root-anchored literal, or `dir/**`) with per-key semantics:
     `denied`/`gated` add, `exempt` subtracts and must keep the exact/beneath split.
   - Does `reason: :exempt` count as ordinary for automatic approval?
   - **Owed since the chunk:** the table-wide exempt cap (T8 S4).
5. **F133:** project `anchor_text` through the survey's ledger (keeps replay drift comparable) or
   journal a digest (breaks `Anchor#drifted?` on replay)? Should changeset reviews project at all? Is
   `annotation_placed.text` in scope?
6. **F156:** a new `read_released` record, or `tool_use_id` on `approval_decision`, or both? Do not
   reuse `read_redacted`: replay would resume the file as masked.
7. **F166:** default journal passes to the session's recorded provider, refuse a remote provider over
   a session holding releases, or mask the scaffold regardless?
8. **Owed since the chunk:**
   - should the read tools' path check resolve symlinks (T8 S3)?
   - the triage rung for `~`/`$HOME` spellings under automatic approval (T23 SF2).

### The loop, the window and the record

9. **F135: fix at the writer or tolerate at the reader?** Writer options:
   - promote the `tool_use` turn before anything cites it (the `b679ed46` precedent);
   - journal at commit.

   Reader tolerance conflicts with Open decision 3, "the human's call".
10. **The one-shot failure arm (F137).**
    - Extend `SpawnLifecycle::MARKS` (round 15's closed vocabulary)?
    - Are failed lineages lineages for consolidate, improve and friction?
    - Does Open decision 5's twin digest stand for failures?
11. **Consolidated memory scope (F134).** Which session is meant to see it:
    - (i) a session file the pass writes, which `--resume` chains to;
    - (ii) the source chain, appended to;
    - (iii) a new project-level store loaded by fresh chats?
12. **Window-relative size (F173, F160, the route into F199).** Take Open decision 2 now, and
    generalise it from per-tool to per-tail? Rule on T7 S4 (re-collapse held replacements)? Should a
    pure withdrawal keep a cut rather than retreat it? An elidable tail reopens T7's dropped "cut wins
    over keep_last".
13. **Chain-scoped run state (F199, F203).** Does a read count only while its result is on the current
    chain, or only once a model answered a request carrying it? Clear the believed reading on
    `/rewind`, or tag it with the head it measured? Note `ReadSet` monotonicity is load-bearing for
    parallel reads.
14. **F136:** budget probe *wall time spent on timeouts* rather than attempts? Should a T24 400 (which
    carries `n_ctx`) vouch for the window? Fold in the chunk's stale-smaller-runner follow-up?
15. **F152:** amend "the absence is the signal" with an `oracle_failed` record, or keep it and ask for
    JSON in the summarizer template (the secret-read precedent)? Per-model capabilities are a new axis
    against a stated experimental control.
16. **F154:** declare the throughput flags on every model-calling command, or one shared band? For a
    standalone command there is no in-process chat to apply T14's same-model rule against.
17. **F202 and F189: why an ask stopped.** Withdraw a transport-failed prompt only when provably
    pre-wire? Add `:ceiling` (and `:over_window`, `:transport`) to the closed `RunInterrupted` enum?
18. **F161:** follow-up 14. A pin drags its tool counterpart, or a lone `tool_use`/`tool_result` pin is
    refused. Rule T7 S5 with it.

### Surfaces and commands

19. **F132:** should composed children inherit the parent's resolved backend argv, or should the header
    gain `provider`/`api_base` so `--fork` defaults to the recording? And which flags count as "backend"?
20. **F142:** move non-terminal watchers (the editor view, and possibly the auto and secret surfaces)
    to conversation scope? Or refuse an unattended role's gated call at an unattended rung instead of
    parking it?
21. **F145:** give `/fork` and `/btw` the shared dispatch-lock predicate? This drops the question-only
    test.
22. **F143:** on a ceiling refusal, restore the previous review's rails and sidebar, or clear to a
    placeholder with nothing bound?
23. **F144:** show NEW from git objects when the checkout is not at head or is dirty (losing LSP), or
    refuse or flag the open? What is NEW for a PR review?
24. **F157, F159 and F185, taken together.**
    - Is a resumed reopen the same round?
    - Is there a non-approving terminal verdict or a close gesture (research open question 3)?
    - Should the docent see the reviewer's note?
25. **F162:** is `manual` meant to ask about edits? It has to be expressible without a `mutates?` axis;
    otherwise rename, reorder or remove it.
26. **F172:** which gesture stops one ask and keeps the session: a fourth countdown key, a command, or
    another signal?
27. **F153 and F171, plain chat:** a one-line approval arrival as the cockpit draws? That also settles
    the chunk's owed plain-chat bell. Print the question document above `human>`? A print-above-prompt
    TTY seam covers F179 too.
28. **F147:** fix at the parent's reader (one place, covers every mixlib caller) or at every call site?
29. **F139:** may the bare docker backend own a container's end (`--name` plus a bounded kill), or only
    `--init`, with the TERM-trapping residual named?
30. **F200:** is a daemon-arm capture bound in scope? That needs a Rust change. The Ruby arms can
    "stop retaining, keep draining" without breaking the exit-status pin.

### Epic

31. **F163 first:** does an earlier stage need a terminal approval (positive evidence), or only no
    parked sign-off? Positive evidence also blunts most of F151.
32. **F151:** what counts as a "gate-shaped record of unknown type", and does it refuse or warn? Does
    an address naming no real epic or issue refuse?
33. **F150:** keep "reuse where it stands" and accept an existing red commit whose criteria digest
    matches, or name the branch per attempt?
34. **F149:** should two epics in one project run concurrently (which needs a per-epic path), or only in
    turn?
35. **F164:** should a terminal gate the human just invoked time out at all (the `7dfdd9dd` choice)? If
    not, should latency be measured from the question's write?
36. **F165:** concatenate criteria or refuse; refuse to merge a `done` side or announce it?
37. **F148:** should a non-issue-specific launch refusal (an unreadable journal) abort the run?

### Bench and memory

38. **F167:** fusion rework or corpus change? Either moves the ranking rounds 14–18 recorded as stable.
39. **F168:** a per-line or a per-manifest bound, kept at the tool, not `Item`, so old sessions still
    resume?
40. **F169:** conclude a watch on a dead writer only, or also at the lineage's terminal record, and with
    which exit status? Pick one liveness idiom (the two disagree on EPERM).
41. **F201/F205:** exclude or flag a zero-usage run in `bench variance`? Delete, rename aside or
    header-mark a failed recording?

---

## 6. Fixes that cover several findings

| one fix | covers | must respect |
|---|---|---|
| **Wire the model phase at the owner:** one helper for every model-calling command (throughput flags plus a per-run provider journal) | F154, F201, T9's `capability_degraded` follow-up | a flagless run sends no `options`; ollama-only keys never reach Anthropic; the env read stays in the exe |
| **Composed and secondary commands inherit the session's backend** | F132, F166 (provider half), part of F154 | "current flags win" for a human-typed `--fork`/`--resume`; no secret on a pane command line |
| **Settle a `tool_use` turn before anything cites it** | F135, F137's crash row, likely any crash mid-tool, and F169's trigger | `Scribe`'s append-only prefix invariant; T3's load-side cancellation repair |
| **An `ensure`-written one-shot completion, lease before spawn** | F137, E18-14 (stranded child work), F141's fleet residue | the closed lifecycle vocabulary (ruling); `Async::Stop` ensure semantics |
| **A retirement record when a child's question is dropped** (the T17 precedent) | F141's inbox residue | `StatusFeed` may not ask a live registry |
| **Content control on automatic approval** | F131, and F140's `.env` release and F138's key print if post-exec | ruling 1; the classifier stays syscall-free |
| **One "undrawn round" state on `Handover`/`Session`** | F143 for `/review` and `/survey` | one `check_presentation!` enforcer; gesture rails never raise |
| **Note evidence from objects or the projection, not the buffer** | F133, and the record half of F144 | drift stays measured raw in the editor; one run ledger |
| **A shared in-flight predicate for `/fork`, `/btw`, `/rewind`, `/undo`** | F145 and the unfiled `/btw` hole | a stranded head at rest still forks and is repaired |
| **A print-above-prompt TTY seam** | F179, the delivery half of F153, F142's chat note | one lock over the stream; notes stay one line |
| **Positive-evidence stage boundary** (after ruling 31) | F163, most of F151 | partitions stay scoped per epic; ~21 `epic_submit_spec` fixtures change |
| **A typed "why the ask stopped"** | F189, F202's withdraw decision | closed, loud enums; classify by type, never by message |
| **A bounded capture object filled by every Ruby exec arm** | F200 (and bash's own share of F147 if its string arm leaves mixlib) | byte-identical refusals across arms; the exit status survives; keep draining the pipe |
| **Window-relative tail or result budget** (Open decision 2) | F173, F160, the route into F199 and F203 | ruling 12; no pre-send token estimate (T24 redesign) |
| **Translate DSL load errors and `Interrupt` at the exe** | F170, F178, F164's Ctrl-C | `summarizer/builder_spec.rb:229-232`'s bare-`ArgumentError` pin |

---

## 7. Decisions NOT to relitigate without the human

These came from the research passes, each ruled or pinned with a stated reason:

- **Secret boundary:** the root predicate; the lexical, syscall-free classifier (the approver resolves
  the real path; T8 S3 is still owed); "ordinary, not merely un-denied"; one `Filter.new` and one
  ledger per run; "a container is not a sandbox"; the survey's raw NEW buffer (round 11).
- **Loop and record:**
  - T24's "withdraw only the asked text, only while it is the head";
  - "no pre-send estimate", the redesign after measured 3.3x token/byte variance;
  - T3's "answer a stranded `tool_use` before the next ask";
  - T1's refuse-by-name and its size-then-text order;
  - the Timeline stays lossless;
  - the derivation stays non-recursive;
  - "the cut wins over keep_last" was dropped by T7;
  - `ReadSet` monotonicity;
  - Open decision 3 (heal at the reader is the human's call);
  - Open decision 5 (identical twins share one spawn digest);
  - the closed, loud reason enums.
- **Surfaces:** nvim-first (T6); a `/`-line at `[y/N]` is never a decision (T27); conversation-scoped
  *terminal* readers (`71e7d13f`); "current flags win" on a human-typed `--fork`; exactly one approval
  queue consumer.
- **Epic:** never force-move a working branch; refuse a branch lain did not create; one boundary call
  site; T10's "a checkout at its cut point has not landed"; T16's no per-provider cheap-model table.
- **Bench and memory:** the M6 panel amendment (no hybrid≥ unit assertion, no corpus-fit `RRF_K`);
  "FRESH-ROOT IS NOT NEGOTIABLE" for the consolidation clerk.
- **Modes:** no `mutates?` axis; tools are capabilities, not permissions.

**A document note.** T24's card body in the chunk is stale; its redesign (`truncate:false`, no estimate)
exists only in the Execution log. A plan should cite the log, not the card.
