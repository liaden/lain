# Round 18 research: the secret boundary and the approval ladder

The findings covered are F131, F133, F138, F140, F141, F155, F156 and F166.

- **Tree:** `/home/tara/dev/lain` at `90f081b9`. Everything here comes from reading code, `git log`/`git show` and
  planning docs. Nothing was run.
- **Line numbers** are current HEAD unless marked otherwise.
- **"Card"** means a card of `planning/specs/chunk-qa-round17-the-record-the-human-the-window.md`, which this
  document calls "the chunk".
- **Inference** is labelled wherever a claim is inferred rather than read.

---

## F131: `ComposedTerm` auto-approves `cat` of an ordinary-named key that `read_file` would mask

### 1. Mechanism, re-verified

**Confirmed.**

- `lib/lain/approval/composed_term.rb:361-364` is the conjunction. Predicate 4 is
  `ordinary_words?` at `:375-378`. It asks `@sensitivity.call(cwd).classify(word).ordinary?` for every word.
  Nothing in the rule reads file content.
- `lib/lain/sensitivity.rb:13-19` sets the classifier's contract: "does no IO at all -- no `stat`, no
  `realpath`, no entropy over the bytes". `deploy_key`, `ops_readme.txt`, `.vault-token` and `backup.txt` match no
  entry in `GATED` (`sensitivity.rb:415-462`), so each classifies `:ordinary`.
- `lib/lain/middleware/redact_secret_reads.rb:64-68`:
  `GUARDED_TOOLS = Set["read_file"]`, with the comment "`bash` reading a file with `cat` is deliberately NOT in this
  set -- that is the path boundary's job." A bash result passes through `call` at `:192` untouched.
- The finding says ComposedTerm "never consults the session's own ledger". That is true, and the reason is
  **structural**:
  - The rules rung builds the subject from the effect alone:
    `Escalation::Rules#call(effect, _context)` (`approval/escalation.rb:325-327`) calls
    `subject(effect) = Rule::Call.for(tool:, input:)` (`:343`).
  - The `context`, which is the Session that holds `masked_read?` (`session.rb:180`), is received and discarded
    (`_context`).
  - `Rule::Call = Data.define(:tool, :input)` (`approval/rule.rb:111`) has no member that could carry it.
- **A detail the finding does not give.** `Session#masked_read?` is per agent, while the region ledger
  (`Sensitivity::Ledger`) is per run and keyed by absolute path plus region digest (`sensitivity/ledger.rb:80-115`).
  - A hardlink or copy of a masked file has a different path, so a "ledger has seen this path" predicate still
    misses the fork's hardlink and copy shapes (`fork-shell-report.md` T-H1).
  - It only catches the S1 shape: the same path, masked one turn earlier.

### 2. Most recent relevant changes

| commit | card | what it did here |
|---|---|---|
| `c6f64656` (2026-09-14) | **T8** | Added the root predicate (`composed_term.rb:23-24, 52-76, 388-393`) and the real-path check in `BoardBuild::Classifiers` (`board_build.rb:316-433`). Widened `GATED` with the named credential files (`sensitivity.rb:403-423`). Touched neither content nor `RedactSecretReads`. |
| `2f90da71` (2026-08-26) | shell-term-approval chunk | Created `ComposedTerm` with predicates 1-6, predicate 4 being "ordinary". |
| `a07d8b66` (2026-08-07) | secret boundary | Created `RedactSecretReads` with `GUARDED_TOOLS = Set["read_file"]` and the "path boundary's job" comment (`git log -S'deliberately NOT'`). |

### 3. Why it is this way

**Round 17 already saw the content half and chose paths.**
- F91 in `qa-findings-round17-2026-09-14.md:221-227` had a **"Why no mask"** paragraph: `RedactSecretReads` guards
  `read_file` only, so bytes `Regions.detect` would flag went out raw through `cat`.
- Its fix shape, however, was "words confined to the project root, and a named-credential tier sized for 'nobody is
  asked'".

**The chunk's root-cause framing is about paths.**
- Intent item 5 (`chunk…:33-35`): "Nothing owns what an automatic approval may **read**. `ComposedTerm` has no
  project-root predicate, and the credential table was sized for 'a human is still asked'."
- **The human's ruling (`chunk…:44`): "root predicate + widened GATED for credentials."**
- T8 (`chunk…:1271-1289`) implements exactly that: the root predicate, the widened GATED list, and the per-entry
  exempt cap.
- No T8 acceptance criterion, grounding line (`chunk…:204-209`) or execution-log entry mentions content, `Regions`
  or `GUARDED_TOOLS` (grep of the chunk for `GUARDED|RedactSecret|Regions|mask` finds nothing in T8).

**The code already argues against a names-only boundary.**
- `composed_term.rb:54-56`: "the classifier names credential SHAPES and **no table of shapes is a boundary**".
  That line justifies the root predicate; it is the same argument F131 makes about content.
- The shell-term-approval plan's governing principle (`planning/archive/chunk-shell-term-approval.md:292-302`,
  restated at `composed_term.rb:118-125`): automatic approval must "never be more permissive than a careful human
  reading the same command string", and "every chunk touching this subsystem states its position on each axis …
  and names the next rung".
  - Its axis table (`:304-312`) has "What a command may read" bounded by name predicates.
  - Its "Content the command pulls in" axis is about `web_fetch` destinations, not file content. **File content was
    never an axis.**
- `planning/project-root-and-secret-boundary.md` Q2 describes GATED as "readable, but only through Q3's redaction
  and confirmation". An automatic approval of an ordinary name gets neither.

**Why the content guard stops at `read_file`.** `redact_secret_reads.rb:64-67`: "Exact membership … a tool that
returns file bytes under some other name is unguarded by design **until it earns a place here**."

### 4. Classification

**(b) A gap outside T8's scope.** The round-17 finding text knew it ("Why no mask"). The human's ruling and T8
addressed only the path half, and the chunk never recorded content as deferred. Not a regression: before T8,
`cat deploy_key` was approved the same way (predicate 4 dates from `2f90da71`).

### 5. Constraints and open questions

**Constraints a fix must respect:**
- **Do not only widen `GATED`.** The in-code argument (`composed_term.rb:54-56`) and the round-18 fix shape both
  reject that; a name table alone repeats F91. Narrow name additions for S7/F181 are fine beside a content control,
  not instead of one.
- **The classifier stays syscall-free.**
  - `sensitivity.rb:13-27` states it, and the spec "the classifier makes no filesystem calls at all"
    (`spec/lain/sensitivity_spec.rb`, `describe` at `:658`) pins it.
  - Any content or mode check belongs where T8 put its disk access: on the `BoardBuild::Classifiers` factory as
    another message beside `#confinement` (`board_build.rb:316-327`: "the one place in this boundary that asks the
    filesystem … Resolution can only REMOVE an approval").
  - It must be one more `&&` plus one method (`composed_term.rb:26-35`, "every predicate is total over a term").
- **Adding `"bash"` to `GUARDED_TOOLS` breaks every bash call.**
  - The middleware keys the ledger on `effect.input["path"]` (`redact_secret_reads.rb:76, 261`). A bash input has
    no `path`, so `Session.normalize_path(nil, …)` would raise.
  - `#guarded`'s rescue (`:210-216`) would then turn every bash result into "could not be checked … nothing was
    returned".
  - A bash-result mask needs its own release key, and "Masking always comes with a release path" (`:22-30`) needs
    a release design for results with no path.
- **Threading the Session into `Rule::Call` is a security-relevant interface change.**
  - `Call`'s constructor is locked against forged members.
  - `planning/archive/chunk-shell-term-approval.md:1054-1068`: "Adding a third member silently breaks that", which
    is why `term` is a derived reader.
  - `Remembered::Entry.for_call` compares calls by value (`approval/remembered.rb:85-96`).
- **The detector has residuals, and a content control inherits them.** `survey/projection.rb:21-32` ("masks
  exactly what `Regions` finds, no more"); F174 (the RSA PEM last line is missed).
- **Specs that pin current behaviour:**
  - `spec/lain/approval/composed_term_spec.rb:51` (`cat README.md | head -20` approves) and `:512-517` (`.pub`
    approves);
  - `spec/lain/cli/wiring/board_build_spec.rb`, T8's "the ordinary project read is still approved with nobody
    asked";
  - `spec/lain/middleware/redact_secret_reads_spec.rb:431` ("passes an unguarded tool's result through untouched").
- **Decisions not to relitigate:** the root predicate; the lexical classifier with the real path in the approver
  only (the T8 S3 decision is still owed, see below); "ordinary, not merely un-denied".

**Open questions for the human:**
1. **Which rung owns content under automatic approval?** Three candidates:
   - (i) pre-exec: the approver abstains when the file's bytes carry regions, or when its mode is not group/other
     readable. This has a TOCTOU window and costs a read.
   - (ii) post-exec: mask or refuse the result of an `authority=automatic` bash call.
   - (iii) both.
   The fork evidence covers a 0600 key, a hardlink, a copy and a PKCS#8 key in `notes.txt`. A mode check alone
   misses a 0644 copy; a ledger-path check alone misses the hardlink and the copy.
2. **Does a human-approved `cat` keep today's raw behaviour?** The fork's pin assumes yes.
3. The same content blindness applies under `/mode auto` (round-10 F63, known-open, which reproduces per
   `fork-secret-report.md:200`). Is that in scope or not?

---

## F133: a note on a masked survey line journals raw `anchor_text`

### 1. Mechanism, re-verified

**Confirmed. The finding's line citations are slightly off.**

**Capture.** The raw line is captured in Lua at `runtime/48_annotate.lua:544` (`review_notes.place`:
`anchor_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]`).
- The finding's `:182` is the wire table built later (`review_notes.wired`).
- Two more capture sites read the buffer the same way: `runtime/52_note_compose.lua:231` and
  `runtime/65_review.lua:331`.

**Transport.**
- `frontend/neovim/rpc_thread.rb:717` (`ReviewWrite.normalized`) interns the text and never strips it (`:702-707`).
- `review/handover.rb:271-278` `#wrote_annotation` → `:338-341` `#anchor` → `review/session.rb:372-380`
  `#annotate` builds `AnnotationPlaced` (`review/records.rb:146`) with `anchor_text: anchor.anchor_text` and writes
  it to `@journal`.
- Nothing on that path consults `Survey::Projection` or `Sensitivity::Regions`. `Handover` holds no ledger or
  projection; its constructors are `cli/command/survey.rb:299`, `cli/command/review.rb:270` and
  `tools/request_review.rb:544`.

**Why the buffer is raw.** On a survey the buffer is the diff's `new` slot, a real file buffer read from disk
(`47_diff.lua:184`, `review_diff.new_side`).

**On "likely wider" (changeset reviews).** Only `/survey` projects anything:
- `Survey::Projection` is constructed only at `cli/command/survey.rb:110` and used by `Review::Source::Corpus`.
- A changeset review builds `anchor_text` from the diff line (`review/changeset.rb:252, 269-273`) with no projection
  anywhere in that artifact.
- For changesets the raw `anchor_text` is consistent with the rest of the artifact. That is a separate policy
  question, not the same breach.

### 2. Most recent relevant changes

The chunk touched none of these files.
- `git log` on `review/handover.rb`, `review/session.rb` and `48_annotate.lua` ends at `16a24435` (2026-09-12) and
  `2071f088` (2026-08-26).
- `ba379be5` (2026-08-05) introduced `anchor_text` from the buffer line.
- `a2ed5fc1` (2026-08-04) introduced `AnnotationPlaced` with `anchor_text`.
- `a4c8d44a` (2026-08-09): "survey: a corpus sees only what the read path would show". Its message says "Above the
  source, the session, the surfaces, **the journal** and the docent see released bytes only."
- `dd5cfdec` (2026-08-25): "survey: the projection guarantee covers the artifact, not the file the human opens".
  This added `survey/projection.rb:43-50` and the scenario text in `planning/qa/scenarios/survey.md:198-217`.

### 3. Why it is this way

**The raw buffer is deliberate. `projection.rb:43-50`:**
> "on a SURVEY the window `:LainNote` operates on is the diff's `new` slot, a REAL file buffer the human can edit,
> and it shows the file on disk unprojected, deliberately -- a survey is a survey of project STATE and the note
> rail needs the real file … What WOULD be a leak is unprojected bytes inside the artifact itself: **the journal**,
> the docent brief, a `/critique` prefill."

The scenario adds that this was a round-11 ruling (`survey.md:214`).

**`anchor_text` is raw evidence on purpose.**
- `review/changeset.rb:269-272`: "EVIDENCE, so decoded but never scrubbed: `anchor_text` is compared byte for byte
  against the line the file now holds".
- `review/annotations.rb:14-25` and `48_annotate.lua:184`: drift is measured in the editor, on the raw buffer
  (`drifted = held ~= note.anchor_text`), and arrives on the wire as a boolean.

So the raw capture and the raw drift comparison are both designed. What was never designed is projecting the text
before it is **journaled**, which the projection's own contract says must not carry unprojected bytes.

### 4. Classification

**(c) Pre-existing; the chunk never touched it.** It breaches a contract stated in code since `dd5cfdec`.

### 5. Constraints and open questions

**Constraints:**
- **Do not project the nvim buffer.** The raw `new` slot is a ruling (`projection.rb:43-50`,
  `survey.md:208-217`: "Do not re-file this as a leak").
- **Do not move drift measurement to Ruby.** `annotations.rb:14-25` explains why; `drifted` must stay the editor's
  measurement of raw against raw. A projected `anchor_text` in the journal therefore no longer reproduces that
  measurement.
- **Replay reads `anchor_text` back.** `Review::Session::Replay` reads it (`review/session/replay.rb:172`), and
  `Anchor#drifted?` compares it against document lines (`review/anchor.rb:152-164`).
  - F157 says the replay has no production caller today.
  - A projected or digested `anchor_text` changes what a future replay can measure.
- **Where a projection could sit.** The one run ledger is required, with no default and no Null
  (`projection.rb:52-58`, `LEDGER_CONTRACT`). A projection at `Handover` must take the survey's `@projection`
  (`cli/command/survey.rb:110`), not build a second ledger.
- **Keep the rail's key and blank rules.** `rpc_thread.rb:576-590` `ReviewWrite::KEYS` checks `anchor_text` for
  the key only, never for content: a blank line is anchorable.
- **Specs that touch `anchor_text`:**
  - `spec/lain/review/handover_spec.rb`, `spec/lain/review/session_spec.rb`, `spec/lain/review/records_spec.rb`;
  - `spec/lain/frontend/neovim/rpc_thread_spec.rb`, `spec/lain/frontend/neovim/annotate_spec.rb`;
  - `spec/lain/seams/survey_session_spec.rb`, `spec/lain/survey/projection_spec.rb`,
    `spec/lain/cli/command/survey_spec.rb`.

**Open questions:**
1. Should `anchor_text` be projected through the ledger or journaled as a digest? A digest loses the human-readable
   evidence and breaks `Anchor#drifted?` on replay; a projection keeps the structure.
2. Should changeset reviews project at all? Today nothing in that artifact is projected.
3. Is `AnnotationPlaced.text` (the human's own words) in scope? A human can type a secret; nothing projects that
   either.

---

## F138: a worktree child's `bash` is judged against the parent's tree

### 1. Mechanism, re-verified

**Confirmed, and the discard point is more precise than the finding says.**

**The child's gate is the parent's.**
- `cli/tool_guard.rb:27-29` says children are "guarded and gated over its parent's board".
- `ToolGuard.child_stack` (`:127-130`) gives the child `Asking.new(policy: inputs.policy, requester:)`: the board's
  one policy, with only the requester renamed (`:40-61`).

**The classifier factory is built on the parent's project.** `BoardBuild.classifiers` (`board_build.rb:219-221`)
builds `Classifiers.new(cwd: project.cwd, root: confinement(project:))`. Inside it, `@worker_env` is the **parent's**
cwd (`:392-400`).

**The child's worker env never reaches the rule.**
- The child's `bash` call names no cwd, so `Classifiers#call(nil)` and `#confinement(nil)` resolve through
  `@worker_env.resolve(nil)`, which is the parent's cwd (`worker_env.rb:59-61`, `board_build.rb:406-433`).
- `Confinement#really?` then runs `Landing.of` against the parent's files (`:376-380`).
- Meanwhile `Tools::Bash` runs the command in the child's `WorkerEnv` (the leased worktree).
- The child's Session, which carries its `worker_env`, is the `context` handed to the policy (`RedactSecretReads`
  reads `session.worker_env.cwd` from the same context, `redact_secret_reads.rb:255-261`).
- But `Escalation::Rules#call(effect, _context)` discards the context (`escalation.rb:325`), and `Rule::Call` has
  no member for it (`rule.rb:111`).

**The contrast the fork saw is explained by the code.** The child's `read_file` parked with regions because
`RedactSecretReads` resolves against the child's worker cwd; the shell rule does not.

### 2. Most recent relevant changes

| commit | card | what it did here |
|---|---|---|
| `c6f64656` | **T8** | Added the real-path half. Before T8, `cat keylink` was approved in both parent and child. After T8, the parent abstains but the child is measured against the wrong tree. |
| `3ab0c175` (2026-09-14) | not a chunk card | "build every agent's tool stack in ToolGuard, gate last": one `Inputs` value for parent and child. |
| `3294d9fa` (2026-09-11) | not a chunk card | "one guard for a parent and its children": the child stack over the live board. This commit also made `GuardTestLayout` child-checkout-aware (`tool_guard.rb:117-136`, `roots_for(worker_env)`). |
| `2f90da71` | shell-term-approval chunk | `ComposedTerm` itself. |

### 3. Why it is this way

**Recorded as a known follow-up.** Execution log (`chunk…:388-389`):
> "T8 review S5: subagent children are judged by rules built over the parent's `project.cwd`, while a child's
> `bash` runs in its own worktree. This predates the chunk and is a follow-up card."

The finding says "This is the chunk's T8 review S5 follow-up, confirmed live" (findings `:313`).

**One board for parent and child is a deliberate invariant.**
- `tool_guard.rb:106-110`: "'one ledger per run' is the board's invariant".
- `tool_guard.rb:187-197`: one `Filter.new`, "every reader takes the filter that came with the gate".
- `board_build.rb:76-78`: "The SAME factory reaches both the triage rung and the approving rule, so the two rungs
  cannot disagree about where a relative word … lands."

**`Rules#call` discards the context by design.** It judges calls by shape, with `Remembered` equality by value.

### 4. Classification

**(b) A gap left outside the card's scope, knowingly** (T8 review S5, "follow-up card"). It predates the chunk.

### 5. Constraints and open questions

**Constraints:**
- **Fail closed.** `Classifiers#confinement` must fail closed (`board_build.rb:316-321, 412-433`); any per-child
  confinement keeps that.
- **One `Filter.new` in `lib/`** (CLAUDE.md, and `tool_guard.rb:187-197`). A per-child classifier must not become a
  second listing filter.
- **The two rungs must not disagree.** Triage and ComposedTerm share one factory (`board_build.rb:76-79`), so a
  child-anchored fix must re-anchor both, or the two rungs will disagree about a relative word.
- **`Rule::Call` is locked** (see F131 §5). Carrying the worker env into the rung is a security-relevant interface
  change.
- **A precedent to copy:** `ToolGuard.working`/`GuardTestLayout::Run#roots_for(worker_env)` (`tool_guard.rb:132-136`)
  already derives a child-checkout-aware guard from the `worker_env` the builder is handed.
- **The lease sits outside the root.** It is under `$XDG_STATE_HOME/lain/worktrees/…`, outside `project.root`. If a
  child's cwd is simply made explicit, T8's "a call whose cwd escapes the root is not approved" makes every child
  `bash` abstain (fail closed, one prompt each).
- **Specs:**
  - `spec/lain/cli/tool_guard_spec.rb:221` ("judges both axes over the board's one path policy and asks the board's
    one gate policy"), `:281`, `:305`;
  - `spec/lain/cli/wiring/board_build_spec.rb`;
  - `spec/lain/approval/composed_term_spec.rb:370-497` (the root predicate).

**Open questions:**
1. Should a leased child be confined to its own worktree root, which needs a per-child factory, or should
   ComposedTerm simply abstain for any requester whose worker cwd is not the board's?
2. The same parent-anchoring applies to the triage rung's relative-word classification for children. Is that in
   scope?

---

## F140: basename-only `exempt` lifts every `.env` in the tree

### 1. Mechanism, re-verified

**Confirmed. The finding's framing is slightly wrong in one place.**

**How patterns compile.** `Sensitivity::Rules.located` (`sensitivity.rb:295-301`):
- a `~/` pattern compiles to `Rule.homed`;
- any other `/` refuses with "is a basename glob ("*.secret") or a home-anchored path ("~/.netrc")" (`:298`);
- everything else compiles to `Rule.named`, a basename match anywhere (`:152`).

**How an exemption reaches automatic approval.**
- `exempt` compiles to verdict `%i[ordinary exempt]` (`:234-235`).
- `ComposedTerm` predicate 4 requires only `ordinary?` (`composed_term.rb:375-378`), and `Verdict#ordinary?` is true
  for reason `:exempt` (`sensitivity.rb:86`).

**Why the cap passes it.** T8's per-entry cap `lifted_by` (`:303-310`) probes one sample per built-in GATED entry.
`.env` lifts exactly one entry (`.env`), so it loads.

**Correction to "the only way to exempt a fixture".** The refusal also offers a home-anchored path, and since T8 a
home-anchored exemption lifts exactly the named file:
- the exact form comes before the credentials; the beneath form only lifts personal directories
  (`sensitivity.rb:513-526`);
- `spec/lain/sensitivity_spec.rb:494-500`: `exempt = ["~/src/app/.env"]` lifts `~/src/app/.env` and leaves
  `~/src/other/.env` gated.

The QA sandbox's project was not under its redirected `$HOME`, so that form was unavailable there. It is also
per-user and cannot express a project outside `$HOME` in a committed config. So the finding holds in practice, but
"only" is wrong.

### 2. Most recent relevant changes

- **`c6f64656` T8** added `lifted_by`/`wholesale` (`:250-251, 286-314`, "an exemption that would lift more than one
  built-in entry … refuses") and the home exemption's exact/beneath split.
- **`e3c1237e` (2026-08-07)** established the basename-or-home shape rule and its refusal of path-shaped patterns
  (`git log -S'lands here on purpose'`, `-S'Rule.named(pattern'`).

### 3. Why it is this way

**Path-shaped project patterns are reserved on purpose.**
- `sensitivity.rb:343-346`: "`config/secrets/prod.key` lands here on purpose: a path-shaped pattern with no anchor
  has no defined meaning yet, and refusing it now is what leaves room to define one later."
- `spec/lain/sensitivity_spec.rb:640-646`: "Loud now, widenable later."

**The exempt cap is per entry, and not table-wide, deliberately.** `sensitivity.rb:208-212`:
> "What one exemption may lift is capped at ONE built-in gated entry … It is not a table-wide cap -- `*.key` is one
> entry and still a class of files, and a config listing every gated name on its own line lifts them all,
> deliberately, one line each."

**What exempt means.** `sensitivity.rb:219-222`: "a project whose `.gitconfig` holds no credential has a legitimate
reason to say so". Exempt asserts the name holds no credential, so treating it as ordinary is the key's own
meaning.

**Owed decision.** Execution log `chunk…:390-391` and close-out `:527`: "Open decision (T8 review S4): whether
`exempt` needs a table-wide cap". This is adjacent to F140 but not the same: F140 is one entry lifting one class
across every directory.

**How the scenario got here.** T29's drive recorded "`exempt = ["fixtures/.env"]` … refused at load by T8's exempt
check. Check whether that is a false positive" (`chunk…:481-482`). Round 18 established that it is the
`e3c1237e` shape rule, not T8 (`fork-secret-report.md:204`).

### 4. Classification

**(d) by design for the classifier**, with a design space reserved in code ("widenable later"), **plus (b)** for
the ComposedTerm interplay: T8's cap was scoped to F128's wholesale lift. The table-wide cap ruling is owed; a
ruling on project-anchored exemptions was never raised.

### 5. Constraints and open questions

**Constraints:**
- **"May widen, may never narrow" is expressed as order** (`sensitivity.rb:202-206, 525-526`). A built-in DENIED
  entry must stay unliftable (`sensitivity_spec.rb:443`).
- **Keep the exact/beneath split for home exemptions** (`sensitivity_spec.rb:469-500`). A new project-anchored form
  needs the same rule: an exempted directory must not lift credentials beneath it.
- **The classifier stays lexical and syscall-free**, and root-relative anchoring needs the root injected. Today
  `Sensitivity.new(home:, cwd:, rules:)` takes no root (`sensitivity.rb:520`).
- **Keep the per-entry probe meaningful.** `Rule#sample` builds its probe from `under`/`inside`/`name`
  (`:161-164`), so any new locator needs a sample.
- **Specs:** `spec/lain/sensitivity_spec.rb:450-600` (exempt semantics, wholesale refusal, "accepts an exemption
  that lifts exactly one entry"), `:640-646` (path-shaped refusal), `spec/lain/cli/wiring/board_build_spec.rb:747-756`.

**Open questions:**
1. Should `exempt` accept a project-root-anchored literal path, defining the reserved "later"?
2. Should `ComposedTerm` treat `reason: :exempt` as not ordinary? The rule is "exemption lifts the prompt, not the
   automatic approval". It contradicts exempt's "holds no credential" meaning.
3. Take the owed table-wide-cap ruling at the same time, since both concern what one table can lift.

---

## F141: the `auto_approver` judge can `ask_human`; the question outlives the call

### 1. Mechanism, re-verified

**Confirmed in effect. The cited mechanism needs correcting.**

**What decides the grant.** The fork cites `tools/subagent.rb` around `375-410`. That is `NoAskers`, used only for
spawn seams built outside a chat (`epic_submit.rb:607-612`). The real deciding code is:
- `ChildBuilder#granted`/`#grants_own_asker?` (`tools/subagent.rb:1023-1034`) grants the child its own `AskHuman`
  when `!@policy.unattended && @seam.permits.include?(asker.name)`;
- the grant is "ON TOP of the attenuated set" (`:1001-1022`), so `only:` cannot remove it;
- `Role.new(name: :auto_approver, only: %i[read_file list_files glob grep])` (`role/catalog.rb:34`) and
  `:gate_adjudicator` (`:39`) do **not** declare `unattended: true`, while `merge_resolver`, `diff_docent` and
  `diff_critic` do (`:51, 63, 69`).

**The ask blocks the surface.** `AutoSurface#answer_for` (`approval/auto_surface.rb:83-85`) blocks on the role
spawn, and `QueueSurface#adjudicate` (`queue_surface.rb:131-138`) runs inside the serial sweep. While the child waits
on its question, no verdict comes and the queue's 300 s timeout decides.

**Inference from code, not driven: why `inbox 1`/`fleet 1` persist.**
- `AutoSurface#watch` runs only inside `LineScope#serve` (`cli/repl/line_scope.rb:93-104`, which stops every
  surface task in `ensure`; `approval_surfaces.rb:92-97`).
- When the timed-out line settles, the task stop unwinds the role spawn with `Async::Stop`.
- `Child#answered`'s `ensure` deregisters the child's `AskHuman` registration (`tools/subagent.rb:813-822`), so the
  directory forgets the set. That matches the fork's "no question is awaiting a reply … stale" refusal.
- So "nothing retires a child's questions when the spawn stops" is **incomplete**:
  - the in-memory registration is released;
  - what is missing is a **record**. `StatusFeed::Inbox` retires only on committed-turn edges or a
    `QuestionsConsumed` (`status_feed/inbox.rb:21-51`).
  - `StatusFeed::Fleet` retires only on a terminal completion `:message` (`status_feed/fleet.rb:46-70`), which a
    stopped one-shot never writes. That is F137's shape.

### 2. Most recent relevant changes

| commit | card | what it did here |
|---|---|---|
| `1cfdf970` (2026-09-14) | **T23** | Built `AutoSurface` for every attended session behind a live layer predicate (`auto_surface.rb:7, 38-57, 76-81`; `toolset_build.rb:229`). `/mode +auto_approve` now reaches the judge mid-session, where before only `--auto-approve` did (`29715c30`, 2026-07-23). It did not touch the role catalog or the asker grant. |
| `7016ab7d` | **T17** | A settled `Approval::Gate` writes `QuestionsConsumed(turn: nil)` naming its question (`approval/gate.rb:402-424`). This is the retirement precedent. |
| `b697adf9` (2026-08-25) | not a chunk card | Introduced `Role#unattended`, marking only `merge_resolver` and `diff_docent`. |
| `3ec1dc79` | **T21** | Added `diff_critic` with `unattended: true`. |
| `b3dcd5e8` (2026-07-21) | not a chunk card | Created `AutoSurface`. |

### 3. Why it is this way

**What `unattended` means.** `role.rb:77-83`:
> "An unattended role declares something `only` cannot express: that it may not PARK, on the approval gate or on a
> human, because it answers with nobody minding it … `ask_human` is the only tool that can park a child today … the
> parking capability is granted OUTSIDE the attenuation."

No commit or plan records a decision to leave `auto_approver`/`gate_adjudicator` attended:
- `b697adf9`'s diff names only the resolver and docent reasons;
- a grep of `planning/` finds no ruling.

The `auto-approver.md` persona calls itself "an unattended gate".

**How T23 framed the risk.**
- T23's escalation triggers (`chunk…:2415-2421`) concern thunks, provider spend and the `method.md` ban, not the
  role's asker.
- T23 review SF2 (owed, `chunk…:422-426`) concerns `~`/`$HOME` spellings reaching the judge, a different hole.

**This is the F100 lineage.** T17 fixed round 17's F100 for epic gates ("Reading the answer leaves
`Approval::Gate`", `chunk…:498-502`). The judge path was not in T17's scope.

### 4. Classification

**(c) Pre-existing.** The judge has been able to ask since `b697adf9` left it attended, and could since
`b3dcd5e8`/`29715c30`. T23 (`1cfdf970`) widened the reach. The fleet/inbox residue is F137's missing completion
record plus the absence of a retirement record when a child's registration is dropped.

### 5. Constraints and open questions

**Constraints:**
- **A role claims the guarantee; it never inherits it.** `role.rb:7-9` and `spawn_policy.rb`: `unattended` defaults
  to false. The fix is a catalog claim, and `spec/lain/role_spec.rb:74-94` (the roll call of which roles are
  unattended) pins the current list.
- **Deny when unsure.** `auto_surface.rb:15-17, 87-93`: an ask that fails must settle as defer, never approve.
- **Retirement must reach the live views.** T17's rule (`gate.rb:402-424`): a retirement written where no inbox
  reader folds it "retires the question in the file and leaves it listed on every screen".
- **`StatusFeed` may not ask a live registry** (`status_feed/fleet.rb:23-25`), so fleet retirement must be a
  journaled record.
- **Specs:** `spec/lain/approval/auto_surface_spec.rb`, `spec/lain/tools/subagent_spec.rb` and
  `spec/lain/tools/subagent_gate_spec.rb` (the asker grant), `spec/lain/cli/switchboard_spec.rb` (T23's wiring).

**Open questions:**
1. Mark `auto_approver` and `gate_adjudicator` `unattended: true`?
   - `gate_adjudicator` is already spawned with `NoAskers` from `epic_submit`.
   - Whether any in-chat spawn of it grants an asker was not checked here.
2. **Inference, not driven.** An unattended child can still park on the **approval gate** through a gated
   `read_file`, or on a region release. The judge's own `read_file .env` would park on the queue the blocked
   `AutoSurface` fiber serves, so it would stall to the human or the timeout. Should `unattended` also cover that,
   as `role.rb:77-78` claims it does?
3. Should a spawn stopped mid-question journal a withdrawal/`QuestionsConsumed` for its set (the T17 precedent),
   and is that the same fix as F137's `ensure`-written completion?

---

## F155: `denied = ["vault"]` refuses the directory entry but not its contents

### 1. Mechanism, re-verified

**Confirmed.**
- `Rules.located` compiles a slashless config pattern to `Rule.named` (`sensitivity.rb:300`), matched by
  `named?(File.basename(path))` (`:152, 190-192`). So `vault` matches `…/vault` but not `…/vault/a.txt` (basename
  `a.txt`).
- Built-in directory entries use `Rule.within` (segment anywhere, `:117-119, 188`): `.gnupg`, `.password-store`,
  `keyrings`.
- `vault/**` is refused by the `/` shape rule (`:298`).
- The listing filter and grep classify each hit path with the same classifier, so `vault/a.txt` is ordinary there
  too. The "no approval can lift this" wording is `Middleware::Sensitivity`'s refusal of the one entry.

### 2. Most recent relevant changes

- `e3c1237e` (2026-08-07) created `Rules.located` and `Rule.named` for config entries.
- **T8 (`c6f64656`)** added `Rule.within("keyrings")` to built-in GATED (`sensitivity.rb:426`), a built-in using
  segment matching, and the exempt probe. It did not change how config entries compile.

### 3. Why it is this way

- `Rules` class comment (`sensitivity.rb:199-217`): three keys, "all lists of patterns", with the shapes a basename
  glob or a home-anchored path (`SHAPES`, `:237`).
- A path-shaped project pattern is refused "on purpose … leaves room to define one later" (`:343-346`;
  `sensitivity_spec.rb:640-646`).
- No code comment or plan says a config name should cover a directory's contents. The asymmetry with the built-in
  table's `within` entries is not discussed anywhere found.
- `secret-boundary.md` §2 used `vault/**`, which "is refused as written, and always was"
  (`fork-secret-report.md:283-287`).

### 4. Classification

**(c) Pre-existing**, never touched by the chunk. The scenario's §2 table was wrong, which the fork records as a
scenario correction.

### 5. Constraints and open questions

**Constraints:**
- **Keys must diverge.** Compiling a config entry as `within` would also change **`exempt`**:
  - `exempt = ["Downloads"]` as a segment rule would lift everything beneath any `Downloads`, credentials included;
  - T8's exact/beneath split exists to prevent exactly that (`sensitivity.rb:513-517`; `sensitivity_spec.rb:469-492`,
    "cannot ungate every `.env` and key in every project under it").
  So `denied`/`gated` (which only add) and `exempt` (which subtracts) must compile differently.
- **A widening costs listings.** Denied and gated widen listings too: `WithholdSecretPaths` withholds rows, and a
  denial is unliftable, so a segment rule over a common name (`vault`, `secrets`) makes whole subtrees permanently
  unreadable. See `sensitivity.rb:29-35`: "a false positive there makes a file permanently unreadable".
- **The `lifted_by` probe needs a meaningful sample** for any new locator (`:154-164`).
- **Specs:** `spec/lain/sensitivity_spec.rb:606-655` (the `Rules` shape refusals), `:503-540` (precedence).

**Open questions:**
1. Should `denied`/`gated` config names match a path segment, as the built-ins do, or should a `dir/**` or
   project-anchored form be defined, filling the reserved "later"?
2. Should F155 and F140 share one decision on project-anchored config patterns?

---

## F156: a region release journals no path, count or `tool_use_id`

### 1. Mechanism, re-verified

**Confirmed.**
- `RedactSecretReads#release` (`redact_secret_reads.rb:309-316`) calls `@ledger.release(path, unreleased)` and
  journals nothing. Only `#mask` writes `Telemetry::ReadRedacted` (`:325-335`).
- The decision record `Approval::Queue::Pending#to_journal` (`approval/queue.rb:185-189`) carries requester, tool,
  surface, verdict, `timed_out` and latency: **no `tool_use_id`, no path, no count**.
- `ApprovalPending` carries `tool_use_id` but "does NOT join to `approval_decision`, which carries no id -- pending
  and decision still pair by counting" (`telemetry/approval_pending.rb:28-30`).
- Releases never pass through `Escalation::Surfaces`; `SecretSurface` and the human settle the queue pending
  directly. So no `escalation` record either, which matches the fork.

### 2. Most recent relevant changes

The chunk touched none of these.
- `a07d8b66` (2026-08-07) wrote `#release` and its comment (`git log -S"is what says a secret was sent"`).
- `c49ebd53` (2026-07-17) created `approval_decision`'s shape.
- `75b26bc8`, `9b1494d9` and `28a18506` (2026-09-12/14) touched the file for unrelated reasons.

### 3. Why it is this way

The release comment gives the reason (`redact_secret_reads.rb:309-312`):
> "Nothing was withheld, so nothing is recorded and nothing is journaled: **the approval's own decision record is
> what says a secret was sent**, and a `ReadRedacted` over a read that redacted nothing would be a false finding in
> the experiment record."

`spec/lain/middleware/redact_secret_reads_spec.rb:390-396` pins the same sentence.

**The premise is false, by the code's own statement.** The decision record carries neither the path nor the count,
and cannot be joined to the call (`approval_pending.rb:28-30`).

**Byte discipline.** `outstanding` and `input` are kept off both records deliberately because they hold region
bytes (`approval_pending.rb:40-48`, `queue.rb:178-184`). Paths and counts are not bytes; `ReadRedacted` already
journals both.

### 4. Classification

**(c) Pre-existing**, with an in-code design rationale whose premise does not hold. The chunk never touched it.

### 5. Constraints and open questions

**Constraints:**
- **Do not reuse `read_redacted` for releases.**
  - `SessionRecord::Replay#redactions` folds every `read_redacted` into `Session#record_masked_read`
    (`session_record/replay.rb:80-90, 117-129`).
  - A `read_redacted` written on release would therefore **resume the path as masked** and refuse `edit_file`/
    `write_file` over it (`tools/edit_file.rb:61`, `write_file.rb:53`).
  - A release needs its own record type, or replay must learn to tell the two apart.
- **Never put bytes on the record.** `approval_pending.rb:40-48` and `queue.rb:178-184`: `outstanding` and `input`
  must stay off.
- **Count what this read did.** `ReadRedacted`'s `released` counts what **this** read rendered, by subtraction and
  not by asking the ledger (`redact_secret_reads.rb:167-187`); any release count must follow the same snapshot rule.
- **Keep evidence from costing the turn.** `record` swallows journal failures (`:337-350`).
- **Adding `tool_use_id` to `approval_decision`** changes a record every pending/decision reader pairs by counting.
  Check `Telemetry` readers and friction.
- **Specs:** `spec/lain/middleware/redact_secret_reads_spec.rb:343-428` (what it journals, including `:390-396`),
  `spec/lain/session_record/replay_spec.rb` (redaction replay), `spec/lain/approval/queue_spec.rb`.

**Open questions:**
1. Should a new release record exist, or should `approval_decision` carry `tool_use_id`, or both?
2. Should replay restore ledger releases from such a record? Today a resumed run re-asks.
3. Relation to F195: a child's release is labelled `requester: "agent"`. Fix together?

---

## F166: `improve`/`consolidate` put released secret bytes into a prompt, with Anthropic as the default provider

### 1. Mechanism, re-verified

**Confirmed, with detail.**

**The default provider.**
- `exe/lain` `JournalPassFlags.declare` (`:1130-1141`): `method_option :provider, default: "anthropic"`.
- Unlike `ModelFlags.endpoint` (`:741-743`), it does **not** read `LAIN_PROVIDER`
  (`EnvDefaults.string("LAIN_PROVIDER", "anthropic")`). A project pinning ollama through direnv still sends these
  passes to Anthropic.
- `CLI::Consolidate.from_options` (`cli/consolidate.rb:29-36`) and `CLI::Improve.from_options`
  (`cli/improve.rb:124-128`) build `backend.provider` from those options.

**What reaches the prompt.**
- `Improve::Scaffold#summary` (`improve.rb:85-110`) and `Consolidation::Scaffold#transcript` (`consolidation.rb:158-176`)
  render each turn's **`text`** blocks verbatim, plus "called <tool>". `tool_result` blocks are dropped.
- So what leaves is released bytes that a model or human **echoed into text**, as the fork's child did; not raw
  tool results.
- `Improve` renders the parent's own `turn` texts too (`:81, 86`).

**No re-gate.**
- The passes' `ToolGuard.detached` guard (`tool_guard.rb:174-181`; `improve.rb:21-29`, `consolidation.rb:14-23`)
  guards only what the pass's own child **reads or writes** through tools. It never touches the scaffold prompt.
- Nothing compares the provider with the session header's recorded `provider`.
- The header does record it: `cli/resume/mismatch_notices.rb:52-60` reads `provider` off the `SessionRecord` header.

### 2. Most recent relevant changes

| commit | card | what it did here |
|---|---|---|
| `ad045078` (2026-09-14) | **T22** | "lineages: read subagent work where the session file records it". Before T22 every lineage reader walked `meta.spawned_from`, "a shape production never wrote, so lain consolidate found nothing in any chat and improve and friction could not see child work". |
| `346f84ae` (2026-08-09) | not a chunk card | Factored `JournalPassFlags`: "two copies is how the pair drifts into two providers" (`exe/lain:1120-1129`). |
| `c0511c3f` (2026-07-21) | not a chunk card | Created `lain improve` with the parent-turn summary. |
| `146d9879` (2026-07-21) | not a chunk card | Mounted `consolidate`, with `--provider anthropic` defaults on both. |

What T22 changed:
- **After T22, `Bench::Session::Lineages` yields real child turns.** So consolidate prompts in real chat sessions
  went from empty to populated, and improve gained child transcripts.
- **This is the change that made F166's child-transcript half reachable.** The parent-turn half of `improve` predates
  it.

### 3. Why it is this way

**T22's purpose was to read lineages correctly** (F98). Its intent, design and acceptance criteria
(`chunk…:2303-2340`) are about finding lineages and refusing damage; none mentions what the scaffold may contain or
where it is sent.

**The passes' secret posture has only ever covered tools.** `consolidation.rb:14-23` and `improve.rb:21-29` guard
the child's writes (a credential-shaped memory never indexed) and its reads (masked, no release). Neither considers
the transcript rendered into the prompt.

**Released bytes are meant to be real.**
- A release puts the bytes into the Timeline and session file (`redact_secret_reads.rb:5-12` masks only unreleased
  regions).
- So any reader of the record holds them; the human approved sending them to **that session's** model.

**The closest stated doctrine is the secret oracle's local pin.**
- `oracle/secret_read.rb:15-33`: "The provider is CONSTRUCTED here, and that is the security property … a copy of
  it would let `--summarizer-provider anthropic` ship the candidate secret's PATH to a remote model."
- `planning/project-root-and-secret-boundary.md` Q1: "Pin the tier to a LOCAL provider … a router that escalated
  this question to Claude would defeat the whole control."
- No equivalent rule exists for journal passes.

**Resume's rule is loud-and-continue.** `mismatch_notices.rb:5-7`: "the current flags win … never a silent override
in either direction".

### 4. Classification

**(b) A gap outside T22's scope.** T22 made the consolidate prompt and improve's child transcript reachable in real
sessions, and T22's reading itself is correct.
- **The default provider:** (c) pre-existing since `146d9879`/`c0511c3f`.
- **The parent-turn text half of `improve`:** (c) pre-existing.

It is **not (a)**, because T22's lineage reading is the correct behaviour its acceptance criteria asked for.

### 5. Constraints and open questions

**Constraints:**
- **Do not revert lineage discovery.** T22 (F98) was a correctness fix, and the round-18 re-check confirms it
  (`F98 FIXED, DIFFERENT`).
- **Resume and fork say "the current flags win"** (`mismatch_notices.rb`). A refusal for journal passes would be a
  deliberate divergence from that rule, or would need a named exception.
- **The dry run stays keyless.** `--dry-run` uses `Provider::Unreachable` so no key is fetched
  (`consolidate.rb:20-24`, `improve.rb:116-119`). A provider check must not force a key or a provider construction
  on the dry path.
- **Masking the scaffold** is fail-closed with no surface: `ToolGuard::Unreleased` (`tool_guard.rb:87-102`) is the
  "nobody here to release" precedent. The detector's residuals apply (F174).
- **Keep the two flag bands from drifting.** `JournalPassFlags` exists so the two passes do not drift apart
  (`exe/lain:1120-1129`); a change lands in both.
- **Specs:** `spec/lain/cli/improve_spec.rb` (`:201`, the dry-run scaffold), `spec/lain/consolidation_spec.rb`
  (`:143`), `spec/lain/bench/session/lineages_spec.rb`, `spec/support/recorded_spawn_session.rb`.
  No spec was found pinning the `anthropic` default on these two commands.

**Open questions:**
1. Refuse or require confirmation when the pass's provider differs from the session header's recorded provider?
   Or default the pass to the recorded provider?
2. Mask the scaffold through `Regions` regardless of provider (fail closed)? Or refuse a remote provider over a
   session holding releases, which F156 currently cannot tell?
3. Should `JournalPassFlags` read `LAIN_PROVIDER` as `ModelFlags` does? That is the same "secondary command drops
   the session's env" class as F154.

---

## Cross-finding

### Shared root causes

1. **The approver's subject is too thin: tool and input only.** F131 (the ledger-path variant) and F138 (the
   child's worker env) both need information that reaches the policy as `context` and is discarded at
   `Escalation::Rules#call(effect, _context)` (`escalation.rb:325`).
   - One seam decision covers both: whether and how a `Rule::Call` may carry session facts without becoming
     forgeable.
   - F131's mode or content variant needs a **factory** message instead (the `BoardBuild::Classifiers` precedent).
2. **Names stand in for content and scope.** Three findings arrive through one table of basename shapes:
   - F131: content unseen;
   - F140: basename exempt;
   - F155: basename denied.
   `sensitivity.rb:343-346` reserved a project-anchored or path form "for later". A single ruling on
   project-anchored or segment config patterns, with per-key semantics (add vs. subtract), covers F140 and F155.
   F131 needs a content control regardless.
3. **The artifact contract is stated but not enforced at every writer.** Two findings breach "unreleased bytes
   never above the thing that remembers them" (`redact_secret_reads.rb:8-12`, `projection.rb:36-50`) at a writer
   outside the middleware:
   - F133: annotation `anchor_text`;
   - F166: the journal-pass scaffold.
   Neither can be fixed by the existing middleware; each needs the run ledger or detector at its own writer.
4. **Evidence gaps in the record.** F156 (release unrecorded) and F141's residue (a stopped child's question and
   spawn never retired) are both "the journal cannot say what happened".
   - F141's fleet half is F137's missing `ensure`-written completion.
   - Its inbox half is T17's `QuestionsConsumed` precedent, not yet applied to child askers.
5. **Secondary commands do not inherit the session's backend.** F166 shares this with F132 (`/fork`, `/btw`) and
   F154 (`num_batch`): a command composed over a recorded session defaults to `anthropic` or drops env, instead of
   reading the recorded or pinned backend.

### Which findings one fix would cover

| fix | covers | does not cover |
|---|---|---|
| A ComposedTerm content/mode predicate on the `Classifiers` factory | F131 (0600 key, hardlink to a 0600 file) | a 0644 copy under a mode-only check; F138 |
| A post-exec `Regions` mask on `authority=automatic` bash results | F131 all shapes; F140's `.env` release; F138's key print | the approval decision itself; F63 under `/mode auto` unless extended |
| A per-child (worktree-rooted) factory | F138 | needs Triage re-anchored too |
| Project-anchored or segment config patterns, per key | F140, F155 | F131 |
| `exempt` is not ordinary for ComposedTerm | F140 | F155 |
| `unattended: true` on `auto_approver`/`gate_adjudicator` | F141's stall | F141's stale inbox/fleet (needs retirement records, shared with F137) |
| Project `anchor_text` through the survey's ledger at `Handover` | F133 | changeset reviews (no projection exists there) |
| A release record, plus `tool_use_id` on `approval_decision` | F156; lets F166's "session holds releases" test exist | F195's requester label |
| Backend inheritance for composed/secondary commands | F166's provider half, F132 | F166's local-to-local scaffold content |

### Owed human decisions these findings touch

All are from the chunk's close-out, `chunk…:524-530`.

- **Should the read tools' path check resolve symlinks** (T8 S3)? It touches F131's framing: the approver resolves,
  the classifier does not.
- **The triage rung for `~`/`$HOME` under automatic approval** (T23 SF2). It is adjacent to F141: same judge, and
  that hole is still open structurally per `fork-secret-report.md:202`.
- **An `exempt` table-wide cap** (T8 S4). It is adjacent to F140.
