# QA round 18 — 2026-09-15

**Scope: a FULL round.** No scope was named, so the round covered every scenario in the
`planning/qa/scenarios/` listing, enumerated at Phase 1: **18**, the same set round 17 drove.

- **Main context:** `session-and-window`, `rust-cli`, `bowling-ruby` with `cockpit-surfaces`
  piggybacked, `bench-arms`, `rails-blog` and `ollama-cloud-arm`.
- **Parallel fork contexts, nine of them:** `epic-tier`, `survey`, both shell scenarios together,
  `repl-commands` with `prompt-slots-and-roles`, `changeset-review` (with integration check 8),
  `secret-boundary`, `failure-injection`, `subagents-and-backends` and `memory-and-dogfood`.
- Each fork had its own sandbox (`~/tmp/lain-qa-round18-<fork>`), tmux socket and port range.
- Forks' finding ids (`T`, `S`, `V`, `C`, `E18-`, `R`, `FI`, `SB`, `M`) and full evidence live in
  `~/tmp/lain-qa-round18/records/fork-<name>-report.md`. They are folded in below under F-numbers, with
  the fork id kept beside each.

**Bench:**
- `main` at `90f081b9`: the round-17 discharge closed, and its integration checks 1–3 passed.
- `/mnt/nvme` ollama 0.32.12, `qwen3-coder:30b`, `OLLAMA_NUM_PARALLEL:1`, `OLLAMA_CONTEXT_LENGTH:32768`,
  `KEEP_ALIVE 5m`, `LAIN_NUM_BATCH=2048`.
- NVIM v0.12.4, tmux 3.7b, podman emulating `docker`, Rails 8.1.3.1 installed into the sandbox, cargo
  present.
- Round start `2026-09-15T10:07:13Z`. The machine was 93% idle at start, and `~/.lain` was absent.

**No timing claim in this round rests on a contended window.** All ten contexts shared one GPU slot.
From 11:41Z to 12:47Z, the main context's own `lain bench arms` run also re-keyed that runner roughly
every 30 s (F154; P41). Every latency, reload or window-provenance reading from that interval is
discounted, and where one mattered it was re-taken with a control.

**Before planning fixes, read [`qa-round18-research/README.md`](qa-round18-research/README.md).**
It traces every HIGH, MED-HIGH and MEDIUM finding against the round-17 discharge (what changed last,
and why) and classifies each. It also lists 41 decisions owed to the human, and says which single fixes
cover several findings. Its factual corrections are folded into the findings below and marked
"research pass".

---

## Summary

**The round-17 discharge mostly holds.** Its HIGH items are fixed on the paths round 17 drove:
- **F88/F89:** bash bytes. `✅` commits and Latin-1 refuses by name, on local and both docker arms.
- **F90:** over-window prompts are now refused rather than silently truncated. This was observed
  naturally at the end of a long bowling session.
- **F91:** named credential files park.
- **F92:** `shell_arm`/`isolation_lease` journal.
- **F93:** a torn gate line refuses.

Most MED-HIGH/MEDIUM items are fixed too:
- F94 (the cut holds, observed), F95 on the chat's own summarizer, F96, F97, F98's lineage discovery;
- F99's first wedge, F101, F103, F105, F107, F109, F111–F118 and F119–F125.

**What the round found is mostly one layer past each fix: the same class, arriving by a route the
fix did not cover.**
- F91 was fixed by NAME, and a key under an ordinary name is still released by content (F131).
- F98 now finds lineages, but consolidate persists nothing it writes (F134).
- F95 is fixed for `lain chat`, but every other model-calling command still drops `num_batch` (F154).
- F83's "a finished child leaves the fleet" holds, but a *failed* child never does (F137).
- F100's stale question returns through the auto-approve judge (F141).

The genuinely new HIGHs are about what leaves the box or the record:
- `/fork` and `/btw` start the child on Anthropic (F132);
- a note journals a masked secret raw (F133);
- a crash mid-spawn strands the whole session (F135).

| id | sev | what |
|---|---|---|
| **F131** | **HIGH** | `ComposedTerm` auto-approves `cat` of a private key under an ordinary name (or a hardlink, `.vault-token`, a 0600 `deploy_key`) — raw to the model and journal, nobody asked — while `read_file` of the same bytes masks it (T-H1, S1) |
| **F132** | **HIGH** | `/fork` and `/btw` compose the child `lain chat` with no `--provider`/`--model`: a local ollama session forks onto Anthropic's default model (R1) |
| **F133** | **HIGH** | a note placed on a masked line journals the raw secret as `annotation_placed.anchor_text` (V1) |
| **F134** | **HIGH** | `lain consolidate` writes its memories into an in-memory Recorder and a Null journal: exits 0 claiming memories it never stored (M1) |
| **F135** | **HIGH** | a chat killed while a one-shot child runs can never be resumed or forked: the spawn cites a `tool_use` turn the session file only writes once results arrive (SB1) |
| **F136** | **MED-HIGH** | `WindowBook::Live` stops re-asking after 3 probes; a session whose first iterations miss a resident runner stays `8192/guessed` forever, so approaching-window compaction never fires and occupancy reads 146% |
| **F137** | **MED-HIGH** | a one-shot child that fails (error, iteration ceiling, over-window 400, lease refusal, crash) journals a spawn and no completion: `fleet` and `--windows` never settle (C3, E18-9, SB2) |
| **F138** | **MED-HIGH** | under `--isolation worktree`, a child's `bash` is judged by `ComposedTerm` against the PARENT's tree (T-M1) |
| **F139** | **MED-HIGH** | a timed-out `--exec docker` command leaks its container indefinitely while the result says it timed out (T-M2, SB6) |
| **F140** | **MED-HIGH** | `[sensitivity] exempt` is basename-only, so exempting one fixture `.env` auto-approves `cat` of every `.env` in the tree (S4) |
| **F141** | **MED-HIGH** | the `auto_approver` judge can `ask_human`; the judged call stalls 300 s to a timeout deny and the question never leaves `inbox`/`fleet` (S2) |
| **F142** | **MED-HIGH** | a docent child's gated call parked while the chat idles at `you>` renders on no surface until a line is typed; it times out denied unseen (V2) |
| **F143** | **MED-HIGH** | a `/review` refused at a ceiling still binds the verdict rails: the stale sidebar stays up and `--permissive` approve settles the unshown changeset (C1) |
| **F144** | **MED-HIGH** | a changeset review's NEW side is the working tree, not the reviewed head; notes journal a revision their `anchor_text` does not exist at (C2) |
| **F145** | **MED-HIGH** | `/fork` forks a head whose `tool_use` is a parked APPROVAL; the child is told the call was cancelled while the parent runs it (R2) |
| **F146** | **MED-HIGH** | in a `--no-journal` cockpit `/goal` kills the chat with a `NoMethodError`, and `/mode` reports failure after applying (R3) |
| **F147** | **MED-HIGH** | `lain chat < file` replays stdin after every subprocess: one `y` approved the same `bash` call three times (R4) |
| **F148** | **MED-HIGH** | `/implement-epic` ends the whole run when every launch in one fill refuses; approved issues go unreported (E18-1) |
| **F149** | **MED-HIGH** | the epic landing checkout is per project, not per epic: a second epic cannot run for 7 days (E18-2) |
| **F150** | **MED-HIGH** | retrying an issue past its red step wedges on the stale issue branch (E18-3; F99 DIFFERENT) |
| **F151** | **MED-HIGH** | a parseable but damaged `gate_decision` (misspelt `stage`/`type`) still opens the next stage (E18-4; F93's class) |
| **F152** | **MED-HIGH** | `--summarizer-provider ollama-cloud` never summarizes: the hosted model ignores the JSON schema, `UndecodableAnswer` is swallowed, and nothing is journaled but a paid `request_sent` |
| **F173** | **MED-HIGH** | compaction cannot make room once the `keep_last` tail alone approaches the window: it commits a near-no-op cut every ask, every prompt is refused over-window, and the refusal still names "compaction" as the remedy. Reached under both `eager` and the composed strategy; only `/rewind` recovers |
| **F199** | **MED-HIGH** | a read whose result no model ever saw (refused over-window, or rewound) still counts COMPLETE, so `edit_file` edits lines the model never received (FI-2) |
| **F200** | **MED-HIGH** | `bash` buffers all output before the 128 KiB ceiling refuses it: an auto-approved `cat` of 800 MB held the chat at 1.13 GB RSS, retained (FI-1) |
| F153 | MEDIUM | in a `--no-nvim` chat an approval parked while `human>` holds the terminal is never drawn and times out as a deny (E18-10) |
| F154 | MEDIUM | `LAIN_NUM_BATCH` is read by `lain chat` only: `bench arms`, `epic submit`, `consolidate`, `improve` re-key a shared runner (E18-7; 65 min of alternating reloads measured) |
| F155–F172, F201, F202 | MEDIUM | see the MEDIUM table |
| F174–F198, F203–F205 | LOW | see the LOW table |
| P40–P46 | process | see Process |

**Counts:** 5 HIGH, 20 MED-HIGH, 22 MEDIUM, 28 LOW. That is 75 findings after merging the defects that
two or three contexts found independently (F131, F137, F139, F171, F179, F203), from about 95 raw fork
and main ids.

---

## Round-17 items re-checked

| id | verdict | evidence (context) |
|---|---|---|
| **F88** non-ASCII `bash` output tears the ask | **FIXED** | `printf "done ✅ ok"` commits; `cat latin1.txt` refuses by name and the ask survives, on local and both docker arms; non-ASCII stderr and a timeout message commit (shell). Rust-cli's cargo diagnostics arrived whole, no ANSI (main) |
| **F89** dangling `tool_use` stalls compaction | **FIXED** on the paths driven | no `derivation_refused` naming an unanswered call in any main-context session; a ceiling stop now leaves the head on an answered `tool_result` |
| **F90** silent over-window truncation | **FIXED** | bowling session 1 ended at `ollama refused this prompt at 33718 tokens against the 32768-token context it loaded`, one `window_pressure kind=over_window`, the prompt withdrawn; `/critique` children got 400s rather than truncation (review) |
| **F91** `ComposedTerm` releases named credential files | **FIXED for names; DIFFERENT** | named files abstain (shell, secret). The class returns by content (F131), by exemption (F140) and through a worktree child (F138) |
| **F92** `shell_arm`/`isolation_lease` never journaled | **FIXED** | one `shell_arm` per gated `bash`, attended and `/mode auto` (shell); lease pairs per spawn, Null and Worktree (subag, survey, main) |
| **F93** torn `gate_decision` opens a stage | **FIXED; the class survives** | halved line refuses submit/status/land/finish (epic). Parseable damage still opens it (F151) |
| **F94** plan-step latch and un-compaction | **FIXED (observed)** | rust-cli: `plan_step_completion` compacted once (29 → 21 messages), and later requests grew by 2 per turn from 21 without jumping back; a second cut at `approaching_window` recorded a `parent` |
| **F95** summarizer drops `num_batch` | **FIXED for the chat's own model; UNCHANGED elsewhere** | a local summarizer `request_sent.extra` carries `num_batch: 2048` (main, cloud control); a warm turn plus a summarized 26,890 B read produced **0** `starting llama-server` lines, taken in a quiet window after 12:47Z (fail). `lain epic submit` spikes and `lain bench arms` send none (F154) |
| **F96** `/rewind` with a parked call | **FIXED** | refused naming the call, human> and cockpit `command>` (repl). `/fork` is the door that still disagrees (F145) |
| **F97** twin one-shot spawns share a digest | **FIXED** | two digests, two windows, `fleet 2` (subag). Across a RETRY the digest still repeats (E18-15, LOW) |
| **F98** consolidate finds no chat lineage | **FIXED, DIFFERENT, not better in outcome** | dry run lists 3 lineages; the live pass persists nothing (F134) |
| **F99** failed epic issue cannot be retried | **DIFFERENT** | the retry launches, then wedges on the stale branch (F150) |
| **F100** timed-out gate never withdrawn | **not reached** for the timeout path (answered path holds, epic); the shape returns through the auto-approve judge (F141) |
| **F101** ghost `human>` after an nvim answer | **FIXED** | not reproduced in a cockpit (repl, main) |
| **F102** typeahead signed as a denial | **FIXED** | `--no-nvim`: `yes please` typed during dispatch → `held as your next prompt`, no `approval_decision` until a human typed (main) |
| **F103** one non-UTF-8 name withholds a listing | **FIXED** | `1 path withheld (malformed)` with the rest listed, in a cockpit (main, secret, survey) |
| **F104** mode layers are lighters only | **FIXED for goal/vi/notify** | `notify` rings: one BEL and one `tmux display-message` per cockpit approval arrival (main — the round-17 prediction, now driven); `goal`/`vi` (repl). `+auto_approve` not raised, per method |
| **F105** `/goal off` mid-drive | **FIXED** | held and honoured before the next iteration (repl) |
| **F106** stale live-looking `[y/N]` | **FIXED on `--no-nvim`** | `-- decided by timeout: denied` (main, 300.0 s), `-- decided by secret_oracle: approved/denied` (secret). An arrival is still printed onto a drawn prompt line (F179) |
| **F107** `/undo` under write-set scope | **FIXED** | created and overwritten files restored, mixed postures name only the turn's paths (repl) |
| **F108** critique reads the working tree; chunker unused | **FIXED** | a marker in the uncommitted tree reached 0 of 45 proxied child requests; children read a detached head checkout (review, check 8) |
| **F109** `bench variance` refuses local recordings | **FIXED** | `cost (USD): not priced — …` and the rest renders (main) |
| **F110** `bench arms` refuses non-Anthropic | **FIXED** | `--cheap-model` exists; the refusals for unset and equal are exact (main) |
| F111–F117 (epic E12, E8, E2, E5, E9, E11, E6) | **FIXED** | each re-driven (epic) |
| **F118** `--windows` outside tmux | **FIXED** | refused at launch (subag) |
| **F119** bare-hex `lain watch` | **FIXED** | (subag) |
| F120 kind filter reads as empty store | **FIXED for `--kind`; UNCHANGED for `--project`** | (memory, M6) |
| F121, F122, F123, F124, F125 | **FIXED** | (repl; review; main for F123/F124) |
| F126 retired cloud tags | **FIXED** | 21 rows; all 21 `/api/show` 200, none over-claims (main) |
| F127 `--exec` help about pipelines | **FIXED** | (shell) |
| F128 `exempt = [".*"]` | **FIXED** | refused at load; but see F140 (secret) |
| F129 `grep` silent skip | **FIXED** | `1 file skipped: unreadable name` (secret) |
| F86 `/introspect` window "unreported" | **UNCHANGED** | (repl) |
| round 10 F63 under `/mode auto` | **known-open, reproduces** | (secret) |

---

## HIGH

### F131 — auto-approved `cat` releases a key the content mask catches on `read_file` — HIGH (T-H1, S1)

Found independently by two forks.

**What.** `Approval::ComposedTerm` approves `cat <file>` when every word classifies *ordinary* and
lies under the root. `Sensitivity` classifies by name and never reads content, so a private key under
a name the table does not list reaches the model and the journal verbatim, with no `approval_pending`.
Driven shapes:
- a PKCS#8 key in `ops_readme.txt`;
- a hardlink to `$HOME/.ssh/id_qa`;
- `ssh-keygen -f deploy_key` (mode 0600), catted one turn after `read_file` of it had parked on
  "5 sensitive regions outstanding" and the human refused;
- `.vault-token`.

**Mechanism.**
- `Middleware::RedactSecretReads::GUARDED_TOOLS = Set["read_file"]` (`redact_secret_reads.rb:68`). Its
  comment says `cat` is "the path boundary's job", a premise that holds only while a human reads the
  command.
- `ComposedTerm` predicate 4 (`composed_term.rb:375`, `ordinary_words?`) asks only the name classifier,
  and never consults the session's own ledger of paths it already masked (`record_masked_read`).

**Ruled out.**
- Not the gate being off: `cat .env` parked in the same session.
- Not the root predicate: the files are inside the root, as the rule intends.
- Not model routing: asked plainly for `cat`, with no prior denial.

**Reproduction.** In a git project, `openssl genpkey -algorithm RSA -out notes.txt`, then ask for `bash`
`cat notes.txt`. Expect `rules allow automatic composed_term`, no pending, and the key in the result.
Control: `read_file notes.txt` parks with N regions.

**Fix shape.** Any of three:
- run `Sensitivity::Regions` over any result whose approving authority was `automatic`, and mask;
- have `ComposedTerm` abstain on a path the ledger has masked;
- have it abstain on a file that is not group- or other-readable.

A wider name table alone repeats F91. Pin with a seam spec over an ordinary-named PEM.

### F132 — `/fork` and `/btw` fork a local session onto Anthropic — HIGH (R1)

**What.** `cli/command/fork.rb:128` composes `PaneCommand.call("chat", "--fork", selector)`, and
`btw.rb:53` does the same plus `--prompt`. No backend flags are carried, and `PaneCommand` forwards only
`LAIN_*` env. The child resolves `--provider anthropic`, model `claude-opus-4-8`. `--fork` itself says
`recorded with model qwen3-coder:30b; continuing with claude-opus-4-8 (the current flags win)`.

**Evidence.**
- Without a key, the fork window dies (status 1) after `/fork` said "forked".
- The printed `/btw` command, run under `unshare -rn` with a fake key, dialled `api.anthropic.com:443`.
  `/btw`'s `--prompt` dispatches at once, so with a real key the local transcript leaves on the first
  read.

**Why HIGH.** The local arm exists to keep a transcript on the box. A fork that re-sends content read
under the local secret boundary to a remote provider is the worst case.

**Fix shape.** Carry the parent's resolved backend argv into every composed child (one method shared
with `FleetWindows`), or have `--fork`/`--resume` default to the recorded backend. Pin the composed
command for an ollama session.

### F133 — a note on a masked line journals the raw secret — HIGH (V1)

**What.** `runtime/48_annotate.lua:182` takes `anchor_text` from the NEW buffer line. On a survey that
buffer is the raw file. The line flows `rpc_thread.rb:717` → `Handover#wrote_annotation` → `Session#annotate`
→ `AnnotationPlaced` with no projection.

**Evidence.**
- A `.env` value went from 0 to 1 journal hits after a note on its line.
- A PEM body line did the same.
- In the same session the docent brief and `docent_answered` carry `<redacted:1>`.

**Likely wider.** F144 means a changeset review's NEW side is also a disk buffer.

**Research pass.**
- The raw line is captured at placement: `48_annotate.lua:544`, `52_note_compose.lua:231` and
  `65_review.lua:331`. `:182` only builds the wire table.
- A changeset review projects nothing anywhere, so raw text there is a separate policy question.
- A digest breaks `Anchor#drifted?` on replay.
- Projecting one line through `Projection#project` would forget releases, because the projection is
  whole-file.

**Fix shape.** Project `anchor_text` through the run's ledger at `Handover#wrote_annotation`, or journal a
digest of the line.

### F134 — `lain consolidate` persists nothing — HIGH (M1)

**What.** `CLI::Consolidate.from_options` (`cli/consolidate.rb:31-35`) builds
`Consolidation.new(recorder: Memory::Recorder.new, …)` with no `journal:`, so `Channel::Null` takes it.

**Evidence.**
- A 308 s live pass over 3 lineages exited 0, naming ids such as `ruby_file_count_lib_dir`.
- `grep -r` over the whole sandbox finds none of them.
- A fresh chat has no manifest; a `--resume` shows only the chat's own three items.
- Refused writes vanish on the same Null.

**Fix shape.** Give the pass a durable destination a later session can load, and state which session sees
it. Memory is session-chain scoped today, so nothing moves it between chains. Pin with a CLI spec that
runs `Consolidate.from_options(...).report` against a fixture session with a Mock provider that calls
`memory_write`, then reads the id from a fresh process.

### F135 — a crash mid-spawn strands the session — HIGH (SB1)

**What.** `Tools::Subagent::Lineage#spawn` (`lineage.rb:64-71`) journals the spawn with
`causal_parents: [parent.head_digest]`, the live assistant `tool_use` turn. The session file writes that
turn only when its results commit. After a SIGKILL before the child returns:
- `--resume`, `--fork` at any digest and `bench variance` all refuse:
  `message record 22 … cites a causal parent this replay never landed`.
- Forking long before the spawn refuses identically, which is F23's signature.

**Control.** The same shape closed cleanly resumes with exit 0.

**Why HIGH.** A crash is when resume is needed, and an in-flight spawn is ordinary.

**Fix shape.** Journal the `tool_use` turn at commit, or have the replay treat a spawn whose parent is
missing as a torn tail. Pin with a crash-mid-spawn fixture through all three doors.

---

## MED-HIGH

### F136 — three missed probes pin a session's window at a guess, and compaction stops existing (main)

**What.** `WindowBook::Live#reresolve` (`cli/backend/window_book.rb`) re-asks only while the answer is a
guess and only `REASK_LIMIT = 3` times. After that it keeps the guess for the life of the run. The
comment's premise is that "the first request is what loads [the runner], so an answer that is coming
arrives by the second iteration's refresh", which holds only if nothing else touches that server.

A session whose first three probes land while the runner is absent or reloading therefore resolves
`8192 guessed` permanently, with three consequences:
- `Compaction::Source` never authorises `approaching_window`, because a guess may not rewrite;
- the HUD and status feed divide by 8,192;
- the session walks into `over_window` refusals with nothing ever compacted.

**Evidence, natural.** Two sessions launched during F154's reload thrash:
- `rails-blog` session 2: **25/25** decisions `8192/guessed`, `occupancy 1.4598`, HUD `ctx 100%`,
  `signals []` throughout, zero compactions.
- The third bowling cockpit: 6/6 guessed.
- Sessions launched before the thrash went `probed` on their second decision.

**Evidence, controlled, off contention.**
- `$QA/psfake.rb` answers the first N `GET /api/ps` with `{"models":[]}` and passes everything else.
- **N=4:** seven iterations, all `8192/guessed`. The proxy log shows `/api/ps` asked 4 times and then
  never again, while `/api/ps` direct read `qwen3-coder:30b ctx=32768` the whole time.
- **N=0 control:** `32768/probed` from the first decision.

**Reachable on a single-user box** wherever the chat model is not resident for the first few iterations:
- a `--secret-oracle` or `--summarizer-model` on a different local model evicting it;
- a concurrent `lain` command re-keying it (F154);
- a `KEEP_ALIVE` eviction racing a slow first ask.

**Fix shape.** Count re-asks per resident-runner change rather than per run, or keep asking at a bounded
rate while guessed and a local deployment is in play. Surface `guessed` on the HUD (see F175). Pin with
the psfake shape: a spec where the first N probes answer empty and the (N+1)th resident must re-resolve.

**Research pass.**
- `REASK_LIMIT` is round 3's deliberate bound against ~2 s probes of a black-holed host (`2301a03d`),
  so a fix must keep that bound. The provider answers nil for both "answered, nothing resident" and
  "timed out".
- The same guess also refuses `/critique` (`Critique::Budget.for` → `UNVOUCHED`) for the rest of the
  session.

### F137 — a failed one-shot child never journals its completion (C3, E18-9, SB2)

**What.** `Tools::Subagent#spawn_one_shot` (`subagent.rb:241-246`) runs `lineage.spawn`, then `run_child`,
then `lineage.message`. Any raise out of `run_child` skips the completion. The status feed retires a
spawn only on completion.

**Triggers driven.**
- the 25-iteration ceiling (epic, review);
- an over-window 400 (review, subag);
- a lease refusal: the spawn is journaled BEFORE the lease, so it names a child that never existed
  (subag);
- a crash (F135).

**Evidence.** `/critique` ended at `fleet 3` with nothing running. `--windows` panes never gain `[done]`.
Lineage readers silently skip an open spawn: `Lineages#completions` requires `"final"` (research
pass).

**Fix shape.** An `ensure`-written completion carrying the failure. Take the lease before the spawn record.

### F138 — a worktree child's `bash` judged against the parent's tree (T-M1)

**What.** Children are "gated over its parent's board" (`cli/tool_guard.rb:28`). `BoardBuild::Classifiers`
is built on the parent's `cwd`/`root` (`board_build.rb:388-398`).

**Evidence.**
- Setup: a committed `keylink → $HOME/.ssh/id_qa`, deleted uncommitted in the parent tree.
- `@reviewer_security[/runcat]` ran `cat keylink` in its worktree, auto-approved, and printed the key.
- Control: with `keylink` restored in the parent, the same decision abstains.

**Reach.** Roles holding `bash`, via `@role[/skill]`. The plain `subagent` child has no `bash`.

This is the chunk's T8 review S5 follow-up, confirmed live.

### F139 — a timed-out docker command leaks its container (T-M2, SB6)

**What.** The command runs as PID 1 and ignores the proxied TERM. The client is then KILLed, and KILL is
not proxied, so `--rm` never fires. `exec/docker.rb:111-116`'s docstring claims the ordinary TERM
reaches the command.

**Evidence.**
- Four `tail -f` containers were still `Up` at 25 min.
- A `sleep 600` container was up at 83 s, with `Init=false`.
- The model reported "correctly timed out".
- Outside lain, `--init` makes the same TERM stop it.

**Fix shape.** Add `--init` to `RUN`, and/or `--cidfile` plus `docker rm -f` on timeout.

**Driver note.** Rootless podman keeps a per-`HOME` store, so check containers under the chat's `HOME`.

### F140 — basename-only `exempt` turns one fixture exemption into every `.env` (S4)

**What.**
- `exempt = ["fixtures/.env"]` is refused at load by the shape rule (`sensitivity.rb:298`, since
  `e3c1237e`, not by T8).
- The refusal steers to a basename.
- `exempt = [".env"]` loads and exempts every `.env`, after which `cat .env` at the root auto-approved
  and returned `sk-live-…`.
- **Correction (research pass):** it is not the *only* expressible form. Since T8, a home-anchored
  exact path (`exempt = ["~/src/app/.env"]`) lifts exactly one file, but only for a project under
  `$HOME`, and only per user. The path-shaped refusal is deliberate ("widenable later",
  `sensitivity.rb:343-346`).

**Fix shape.** Accept a project-anchored path in `exempt`, and/or have `ComposedTerm` treat
`reason: :exempt` as not ordinary.

### F141 — the auto-approve judge can park a question that outlives its call (S2)

**What.** Under `/mode +auto_approve` the `auto_approver` role answered `DEFER` AND called `ask_human`.
- The judged call sat 300 s and was timeout-denied.
- The question's arrival was printed onto the live `[y/N]` line.
- `inbox 1` and `fleet 1` never cleared, even after answering was refused as stale.

**Mechanism, corrected by the research pass** (`qa-round18-research/secret.md`):
- `ChildBuilder#grants_own_asker?` (`tools/subagent.rb:1023-1034`) grants every attended child an
  `AskHuman` on top of its `only:` list.
- `auto_approver` and `gate_adjudicator` were never marked `unattended: true` (`role/catalog.rb:34,39`;
  `b697adf9` marked only the resolver and docent). The fork's `NoAskers` citation is the wrong path.
- The in-memory question is released when the child stops. What stays stuck is `inbox`/`fleet`,
  because no *record* retires them. That is F137's missing completion plus T17's `QuestionsConsumed`
  precedent not applied to child askers.

This is round 17's F100 shape arriving through the judge. T23 widened the reach; it did not cause it.

**Fix shape.** Spawn adjudicator roles with the unattended asker, and retire questions on spawn stop.

### F142 — a docent's parked approval is invisible while the chat is idle (V2)

**What.** `Repl::ApprovalSurfaces#watch` (`cli/repl/approval_surfaces.rb`) starts the nvim approval view and
`Arrivals`, and runs only inside `LineScope#serve` (`line_scope.rb:93-100`), which lives for one
dispatched line. A thread-pane question with `:w` runs outside any line, so its child's gated call:
- journals `approval_pending`, and `state.json` reads `approvals_pending: 1`;
- draws nothing in `lain://approval` or the chat;
- is timeout-denied at 300 s.

**Evidence.** Two runs. Typing `/status` is what made both surfaces render. The buffer also kept an
already-denied row.

**Related.** The same per-line watcher shape explains F153 on `--no-nvim`.

**Fix shape.** Keep the editor approval watcher and arrivals alive for the chat's lifetime when an editor
is attached.

### F143 — a ceiling-refused review still takes a verdict (C1)

**What.** `CLI::Command::Review#opened` (`review.rb:190-192`) journals `changeset_opened` and binds the
rails before `drawn` raises `Bounds::TooLarge`. After a refused 301-file `/review --permissive`:
- the old sidebar stayed;
- `:LainReviewVerdict approve` journaled `review_verdict approve` against the unshown changeset's digest.

Under strict, the stale rows answer with raw hunk keys and "f0.txt … and 296 more".

**Fix shape.** Bind rails only after `drawn`, or refuse gestures on an undrawn round, and placeholder the
sidebar.

### F144 — the NEW side of a changeset diff is the working tree (C2)

**What.** `ChangesetDiff#drawn` posts only OLD lines, and `47_diff.lua` `new_side` `bufload`s the disk
file.

**Evidence.**
- A NEW-side blocker journaled `revision: b10d709…` with `anchor_text` holding an uncommitted marker
  line, and `drifted: false`.
- With another branch checked out, NEW opened empty or stale.
- OLD was always correct.

**Fix shape.** Show NEW from `git show <head>:<path>` when the checkout is not at head or is dirty, and
stamp `anchor_text` from the named revision.

### F145 — `/fork` forks through a parked approval (R2)

**What.** `fork.rb:95-98` refuses mid-tool only when `replies.pending?`, which covers questions only. Its
comment's premise (an approval read owns stdin, so nothing runs) is false since T6's `command>` reader.

**Evidence.** In a cockpit with `bash` parked: `/undo` refused, `/rewind` refused, `/fork` forked. The
child's head was repaired as "cancelled" while the parent approved and ran the call.

**Fix shape.** Share the dispatch-lock predicate `/rewind` and `/undo` use.

### F146 — `--no-journal` cockpit: `/goal` crashes the chat (R3)

**What.** `JournalTee` answers `<<` only (`journal_tee.rb:47`).
- `GoalDriver::Run#drive` calls `@journal.record` unrescued (`goal_driver.rb:325`): 12 frames, dead pane.
- `Mode::Switch#switch` assigns `@current` before `record` (`switch.rb:61-64`), so `/mode plan` prints
  "failed" and has applied.

A plain `--no-journal` chat works: the tee exists only on the editor path.

**Worse than filed** (research pass, code read). Under `--no-journal --nvim`, `/mode plan` moves the
posture LABEL while the gate policy and toolset do not. `bash` and the edit tools stay live under a
PLAN lighter, and approval and escalation records are silently dropped.

This is the chunk's own recorded follow-up, now worse.

### F147 — stdin from a regular file replays after every subprocess (R4)

**What.** Every `Mixlib::ShellOut` child does `STDIN.reopen` (`mixlib-shellout unix.rb:237`) on a shared,
read-buffered file description, which seeks the parent back.

**Evidence.**
- `lain chat < p.txt`: three `approval_decision approve` for three `echo one` calls from one `y`, and
  every prompt re-dispatched.
- A lain-free Ruby repro reads `L1 L2 L3 L2 L3`.
- Controls: a pipe or no ShellOut are clean.

**Fix shape.** Spawn with an explicit `in:` (`File::NULL`) via `Process.spawn`, or read non-TTY input
unbuffered.

### F148–F151 — epic driver and sign-off (E18-1 … E18-4)

- **F148 (E18-1).** `Run#drive` (`epic_driver/factory.rb` ~846-856) does `return if @live.empty?` after a
  fill whose every launch refused. At width 1, one broken plan stops the run and 7 approved issues are
  never mentioned; the width-9 control shows every issue refuses correctly on its own. Fix: refill until
  something is live or nothing is startable.
- **F149 (E18-2).** `landing_checkout` is `File.join(worktree_root, LANDING)`, per project. A second epic
  gets `fatal: '…/landing' already exists`; gc keeps it 7 days. Fix: `landing/<slug>`.
- **F150 (E18-3; F99 DIFFERENT).** The retry reuses `lain/issue/<epic>/<id>` at attempt 1's red commit,
  based on the old tip. The existing test file is unchanged, so `TestGeneration::Record#generated?` is
  false and the retry refuses ("left no tests the layout accepts … (… mirrors …)"). Fix: carry the red
  commit forward (accept an existing red commit whose criteria digest matches), or name the branch per
  attempt. **Resetting the branch contradicts a pinned rule** (never force-move an owned branch,
  `issue_actor_spec.rb:297-310`).
- **F151 (E18-4; F93's class).** `SignoffQueue.apply` never validates `stage` against `Epic::STAGES`, and
  a misspelt `type` is simply foreign. `"stage":"reserch"` or `"type":"gate_decisioN"` lets
  `submit epic_plan` return rc=0. `Epic::UnknownStage`'s own comment names the hazard. **Wider, by code
  read (not driven):** a misspelt `policy` and a damaged `epic_slug`/`issue_id` fail open the same way.
  F163's ruling (positive evidence at the boundary) would close most of it, so take that ruling first.

### F152 — the ollama-cloud summarizer silently never summarizes (main)

**What.** With `--summarizer-provider ollama-cloud` (default model `gpt-oss:20b-cloud`), every summary
request is sent and billed and produces nothing:
- no `oracle_answer`, no `provider_wait`, no WAL frame;
- no record of failure;
- compaction reads every result as a miss.

**Mechanism, traced with a `TracePoint` on `:raise` in the live chat.**
- `Oracle::Model::JsonDecoder#call` (`oracle/model.rb:101`) raised `UndecodableAnswer: oracle reply was
  not decodable JSON: invalid number: '-'`.
- `Oracle::Eager#fire` rescues it silently by design (`eager.rb:75-80`: "a failed fire holds nothing").
- `Deployment::CAPABILITIES` declares `structured_output` for the hosted deployment, but the hosted
  model ignores the `format` schema.
- Replaying the journaled request directly with `Provider::Ollama.cloud(...).complete` returned
  `"- The file contains 300 consecutive lines…"`, markdown and not JSON.

**Controls.**
- The identical session with `--summarizer-provider ollama` (local `qwen3-coder`) journaled
  `oracle_answer` and `provider_wait`.
- A logging proxy on the chat's `--api-base` saw no summarizer request, so the bearer went to ollama.com
  as designed (§2 passes).

**Why MED-HIGH.** The operator asked for a summarizer tier, is billed per tool result, and gets nothing,
with no record that says so. A failed fire is indistinguishable from a summary still in flight.

**Fix shape.**
- Journal a failed fire (`oracle_failed` with the error class).
- Treat a declared `structured_output` capability as per-model, or validate it with one probe.
- For JSON-mode models, fall back to a prose decoder or a JSON-in-text extraction.

Pin with a recorded cloud reply that is markdown.

### F173 — compaction cannot make room once the `keep_last` tail approaches the window (main)

**What.** Both strategies collapse only the span *before* the last `keep_last` (20) messages. When
those 20 messages alone carry most of a 32,768-token window, three things follow:
- every compacting decision commits a cut that moves almost nothing, recorded `compacted: true`;
- the derived request is still over the window, and ollama refuses it (T24's refusal, working);
- the next ask repeats both steps.

The refusal's first remedy is "Make room with compaction (that count is now the reading it measures)",
which is exactly what just ran. Only `/rewind` past the large results recovered.

**Corrected by the research pass** (`qa-round18-research/compaction.md`):
- The over-window refusal names compaction only while the last decision had something droppable.
  That held throughout rails, but only on the first refusal in bowling.
- It never names `--compact-keep`. That flag is in the separate stderr stall line
  (`Source::Diagnosis#remedy`).
- "A summarizer call per stuck ask" is not in the rails journal and is unverified.
- **The mechanism the finding missed:** T24's withdrawal takes the cut's commit head off the chain, so
  `HeldCut` retreats and the *same* cut (`fada27bd`) is re-committed on every stuck ask. A retreat and
  re-advance each time, not a fresh 417-byte cut.

**Evidence, two strategies.**

1. **`eager`, the default: bowling session 1, 11:19–11:28Z.**
   - Five compactions in three minutes: `bytes 60910→55730`, `56354→55221`, `58349→54067`, then
     `63697→63553` (0.2%) at `compacted: true`.
   - Then `over_window` at 33,718, and every later prompt refused at 33,771.
   - `/rewind 4` let one ask through, and the model refilled the window within that ask.
2. **`elide-tools+summarize-conversation`: rails session 3, 13:00–13:05Z,** after reading 12 generated
   files of 2–9 KB.
   - One real compaction: `66625→47202`, 58 → 23 messages, a `compaction_cut` naming the composed
     strategy.
   - The derived request (23 messages, 66,769 B) was still refused at 33,105.
   - The next two asks each committed a cut moving 417 bytes and were refused at 33,129 and 33,122.
   - `/rewind 12` refused (it lands on a `tool_use`); `/rewind 13` landed. The next compaction then
     moved `31543→24001`, the ask answered at `input_tokens 11181`, and HUD `ctx 34%`.

The failure-injection fork reached the same wall from the other side: a 772 KB `web_fetch` is never
elided, because "a fresh result sits inside `keep_last`" (FI §10).

**Why MED-HIGH.** The session is stuck until a human finds the right `/rewind` count. The first two
remedies the refusal offers do nothing. Every stuck ask still pays one summarizer call.

**Fix shape.**
- Let the elide half reach tool results inside the tail when the tail alone is over budget (keep the
  newest N messages *or* M bytes, whichever is smaller).
- Refuse to record `compacted: true` for a cut below some fraction of the gap.
- Word the refusal by what compaction just achieved, and name the `/rewind` count that would fit.

Pin with a derivation spec whose last 20 messages exceed the window.

### F199 — a read nobody saw unlocks `edit_file` (FI-2)

**What.** `Session#record_read` marks a path complete when the tool runs (`session_read complete:true`),
before the request carrying the result is sent. Neither the over-window withdrawal (`Agent#withdrawing`,
`agent.rb:338`) nor `/rewind` (`agent.rb:322`) touches `@reads` (`session.rb:54,134`).

**Reproduction.** On a 32,768 window:
1. `read_file mid2.rb offset:1 limit:6000` on a 300 KB, 5,000-line file is refused at 63,708 tokens.
2. `session.read?` reads `[true,false]`.
3. `/rewind 3` leaves it at `[true,false]`.
4. `edit_file` on unique, never-seen line 3,000 → `replaced 1 occurrence`.

**Control.** The same edit on an identical never-read copy refuses `… was never read this session`.

**Why MED-HIGH.** T24 made a full-cover window on a 32k context end in exactly this refusal, so this is
now the ordinary route to `failure-injection` §9 step 5 on this box. The precondition `edit_file` exists
for ("editing it would clobber lines you never saw") is defeated silently.

**Fix shape.** Record the read at commit-and-delivery, or undo the record on withdrawal and on rewind (key
the read set to the producing turn).

### F200 — `bash` output is captured whole before the ceiling (FI-1)

**What.** `Tools::Bash.render_output` compares `OUTPUT_BOUND` with `stdout.bytesize + stderr.bytesize`
after both exec arms have buffered everything (`exec/local.rb:71-82`; `Shell::Pipeline` capture).

**Measured.** Chat RSS, 1 s samples, baseline 92 MB:
- `head -c 300000000 /dev/zero | tr '\0' x`, human-approved: peak 411 MB, retained at 409 MB.
- `cat huge.log` (800 MB, **auto-approved by `composed_term`**): 1.13 GB, retained.

Both were refused correctly afterwards. "The decision precedes the read" (`failure-injection` §8) holds for
`read_file` only. A multi-GB log under the root is one unattended `cat` from OOM-killing the chat.

**Fix shape.** Count past the bound in both arms and stop retaining (or kill the group at bound + 1),
keeping the exit status for the refusal.

---

## MEDIUM

| id | fork | what | mechanism / evidence |
|---|---|---|---|
| F153 | E18-10 | `--no-nvim`: an approval parked while `human>` holds the TTY is never drawn, and times out as a deny | a relayed question drew `human>` at 10:58:57; `dev`'s approval at 10:59:04 was never drawn and was `timeout deny` at 11:04:04; an earlier call waited 290.5 s undrawn. **Research pass:** not F142's per-line watcher. Both readers take one stdin lock (`READS`), and T13 deliberately writes no "decided by" for a prompt that never drew |
| F154 | E18-7 + main | `LAIN_NUM_BATCH` is a `lain chat` Thor default only (`exe/lain:779`); `bench arms`, `bench record`, `epic submit` adjudication, `consolidate` and `improve` send no `num_batch`, so each re-keys a shared runner to `-b 512` | main: from 11:41Z, when `bench arms` started, the ollama log shows qwen3-coder reloading alternately at `-b 512`/`-b 2048` about every 30 s for 65 min, stopping when the run was killed. Epic: two spike submits matched two `-b 512` loads. It caused F136 in two sessions. Fix: read the backend's `sampler_extra` in every model-calling command (T14's rule, generalised) |
| F155 | S3 | `[sensitivity] denied = ["vault"]` refuses `vault` as unliftable but hands back `vault/a.txt` and a `grep` hit ungated; `vault/**` is refused at load | `Rules.located` → `Rule.named` (basename) where built-ins use `Rule.within` |
| F156 | S5 | a region RELEASE (human or oracle) journals no path, count or `tool_use_id` | `RedactSecretReads#release` journals nothing; `approval_decision` has no `tool_use_id` |
| F157 | V3 | a survey's notes, marks and docent threads do not survive `--resume`; a resumed chat approved over the earlier session's blocker | `Review::Session.from_journal` and `Docent#replay` have no production caller |
| F158 | V4 (UX) | a corpus over the LINE ceiling is refused with "nothing to fall back to", yet `--unbounded` opens it; misnames "changeset" | `NO_NARROWER`/`NO_PRESENTABLE_SCOPE` written for `/review` |
| F159 | V5 (gap) | an unsettled survey blocks `/review` for the chat; `approve` is the only verdict, so the only exit is approving something unread | no withdraw verdict or close gesture |
| F160 | C4 + SB2 | a critique chunk's room does not bound the child's reads: 2 of 7 lain chunks died on a 400 over-window, merged as raw provider JSON; no `window_pressure` for children | `RequestBudget` composed only in `Wiring#model_phase`; the chunk's Open decision 2, measured |
| F161 | R5 (UX) | bare `/pin` at a parked question pins the `tool_use` turn; every derivation is then refused while the reply says "compaction keeps this turn" | documented in `derived.rb:36-42`, delivered obtusely |
| F162 | R6 (UX, ruling) | `manual` gates exactly what `accept_edits` gates, lights `MAN`, is listed as more restrictive, and cannot undo a shell's writes | `mode/posture.rb`: both `permits: All, :queue`; only `snapshot_scope` differs |
| F163 | E18-5 (ruling) | the stage boundary admits a stage never submitted: an issue went `in_flight` with no research and no epic_plan gate | `Stage#ensure_open!` asks only `drained?`; the scenario's §6 endorses the letter |
| F164 | E18-6 | a terminal `interactive` gate never times out (670 s against 300 s), journals `latency ≈ 0`, and Ctrl-C prints a raw `Interrupt` backtrace | `Gate#call` calls `asker.ask` before `await` arms clock and timeout |
| F165 | E18-8 | `lain epic merge` drops both issues' description and gherkin criteria, and reopens a `done` side silently | **corrected by research:** the loss is in `CLI::Epic#merge` (from `82bd3784`), which builds the arrival from id and title; `Graph#merge` is not the site |
| F166 | M2 | `lain improve`/`consolidate` put human-released secret bytes from a child transcript into their prompt, and default to `--provider anthropic` | 2/2 values in `improve --dry-run`; library read `key_in_prompt=true`; remote send not tested (no key) |
| F167 | M3 (bench validity) | the `hybrid` sweep arm scores 0 on every paraphrase query `vector` gets right; RRF over an exhaustive vector list doubles bm25 noise | per-query recall@5; hybrid = bm25 at k=1,5 since round 14 |
| F168 | M4 | `memory_write` bounds the body only; a 300 KiB `description`/`id` was accepted and rides every request's manifest (614 KB) | `MemoryWrite::BOUND` measures `body` |
| F169 | SB3 | `lain watch` never concludes on a session with no `session_closed` (any crash): a typo'd selector hangs silently; `--windows` panes tail a dead file forever | `Watch#follow` stops only at `session_closed`; the writer pid is knowable |
| F170 | SB4 (UX) | a wrong keyword or syntax error in `.lain/services.rb` kills every `lain chat` in the project, even `--isolation none`, with a 24-frame backtrace | `Services::Builder.build` `instance_eval`s with no rescue |
| F171 | SB5, FI-6 (UX) | `--no-nvim`: a multi-line `ask_human` is announced as its first line only while `human>` takes the answer; the pointer names a `lain://inbox` that does not exist there | `TTY::Inbox#arrival` prints `one_line(summary)` with a fixed `POINTER` |
| F172 | main (gap) | nothing interrupts a running ask and returns to `you>`: Ctrl-C opens the 60 s CLOSE countdown, `[c] cancel` cancels the close and the runaway ask continues; denying each call or quitting are the only levers | rust-cli: the model looped `cargo test` / `todo_write` to the ceiling three times; `cli/shutdown.rb`'s states are `running → grace → draining → closed` with no "stop this ask" |
| F201 | FI-5 | `lain bench record` never journals `truncated_stream`; an all-zero `turn_usage` enters `bench variance` as a measured 0 (mean 46 from 0 and 92) | **corrected by research:** the provider journals through `Backend#journal` (`cli/backend.rb:274`), which stays Null because `bench record` never calls `pipeline_source`; `provider_wait` is lost too, and `variance` reads no `truncated_stream` anyway. F92's class on the bench path, sibling of T9's `capability_degraded` follow-up |
| F202 | FI-4 | a transport-failed ask (four attempts exhausted) leaves its user turn on the head; the next prompt stacks two user turns and re-sends the abandoned text | only `WindowExceeded` withdraws (`agent.rb:336-340`); predates the chunk |

---

## LOW

| id | fork | what |
|---|---|---|
| F174 | T-L1 | `read_file`'s mask misses an RSA PEM's short last base64 line (7 of 12 keys ≤ 3072 bits), even after a human denial |
| F175 | main | the HUD's `ctx N%` divides by a GUESSED window with no marker: 61% after a cold one-word turn (really 15%), 62% in the bowl3 session, 100% (146%) in rails session 2 |
| F176 | main | `--api-base "http://"` refuses as `has no host; a scheme is required` — it has a scheme (`backend/endpoint.rb:53`) |
| F177 | main | `--cheap-model nonesuch:1b` is accepted and the suite starts spending; the "a model this backend can serve" sentence is advice, not a check |
| F178 | main | Ctrl-C of `lain bench arms` after 65 min and 9 graded runs prints a raw `Interrupt` backtrace and no partial report, although 9 `grade_record`s were journaled; 3 locked leases and 5 `retained/` copies of one path remain. A COMPLETED run also leaves 26 dirty leases retained for 7 days |
| F179 | main + S2 + R14 | an arrival is printed onto a drawn prompt line (`command> ! agent asks to run …`, `…? [y/N] ? auto_approver …`, `human> You like banana…`) |
| F180 | S6 | approving a gated `grep`/`glob` buys a wholly withheld result; the path prompt never says why it is gated |
| F181 | S7 | credential-store names the table misses: `~/.ssh/<non-id_*>`, `.vault-token`, cargo credentials, gcloud ADC, terraform, azure, kube backups |
| F182 | S8 | `--secret-oracle` help still says "ahead of the human" (`exe/lain:969`) |
| F183 | V6 | four path bases around one survey; F68's header/row split is back on the TEXT surface (`surface/text.rb:156`) |
| F184 | V7 | `/survey` splits on whitespace: a directory with a space cannot be surveyed, extra words dropped silently |
| F185 | V8 | the thread pane drops its own note at the first question, and the docent brief never carries it |
| F186 | C5–C8 | `/review` ignores extra positionals and takes the last duplicate flag; `commits` scope refuses a file named `x => y.rb` (no `-z` numstat); `FILE_OVER` remedy "review that file on its own" is circular; `lain review tree` prints `lain_c_l_i` |
| F187 | R7, R8 | `/mode` takes the last of contradictory tokens (`/mode accept_edits auto` → auto); no-op switches journal `mode_switch` + `policy_switch` |
| F188 | R9 | `lain sessions` ignores `rewound`: lists a discarded head and counts discarded turns |
| F189 | R10 | the per-ask ceiling journals `run_interrupted reason: "torn"`, indistinguishable from a tear (main saw the same in every ceiling stop) |
| F190 | R11, R12 | a slot file with the wrong extension is silently ignored; one role has two spellings (`reviewer_code` / `reviewer-code`) |
| F191 | R13, R15 | `/undo skip` wording on the only undoable turn; `/pin`/`/unpin` asymmetry |
| F192 | E18-11 … E18-13 | graph edits orphan parked gates; an id like `a_b` is listed ready and can never be submitted; one abandoned issue makes `finish` impossible |
| F193 | E18-14, E18-15, E18-16 | a child's uncommitted work hands back `nothing_to_do dirty:false`; a retry's spawn repeats attempt 1's digest; `/status inbox 2` vs `/inbox` listing one |
| F194 | E18-17 | epic wording and small refusals (internal names, two-pass typo reports, duplicate `deferred` records, `deny` prints "signed off") |
| F195 | M5 | a child's masked-read release prompt and records say `requester: "agent"` |
| F196 | M6, M7 | `lain improvements --project <no match>` says "no improvements recorded yet"; a torn mid-file line in `improvements.ndjson` is dropped silently |
| F197 | M8, M9 | one improve pass wrote 16 notes that are ~6; missing-embeddings refusal says "no sweep corpus file" and is CLI-unreachable |
| F198 | SB7 | gc keeps a clean crashed lease 7 days though its lock names a dead pid; a lease refusal omits the worker id; a move-aside is unjournaled and restarts retention |
| F203 | FI-3, FI-8 | after `/rewind` past an over-window turn the refused count stays "the reading" and forces a compaction of an ~11k history (reproduced in main's rails session); the refusal says "and it was withdrawn" when a tool round stayed on the head (`request_budget.rb:37-39` picks the wording from `droppable?` alone) |
| F204 | FI-7 | a first Ctrl-C at a parked `human>` draws no countdown; the second closes the session at exit 0 (the journal parses — §6's real check passes) |
| F205 | FI-9 | a transport-failed `bench record` leaves a file with no `session` header, unreadable by `variance` |

---

## Withdrawn near-findings

- **"Typeahead at `you>` shows no `held as your next prompt:`."** That line belongs to a read that opens
  over typeahead (an approval or a question). At `you>` a typed line simply is the next prompt
  (`tty.rb:48`).
- **"An answered parent `ask_human` stays listed in `lain://inbox` and `inbox_count` 1 until the turn
  ends."** A second `:LainReply` refuses in words: `lain://inbox line 1 is answered -- it clears once the
  agent takes it`. By design.
- **"The survey sidebar row `tmp/tally-app/…` is relative to neither cwd nor the root."** It is the
  shared-ancestor strip, documented in `02885580` as known.
- **"Three parallel `bash` calls give three arrival lines and three rows."** `ToolRunner` runs unsafe tools
  in contiguous serial runs (`agent/tool_runner.rb:179-201`), so they park one at a time. The prediction in
  `cockpit-surfaces.md` §5 is wrong, not lain (scenario correction).
- **Ctrl-C "did not stop" rust-cli's ask.** A single Ctrl-C opens the CLOSE grace window by design; see F172
  for the gap it leaves.
- **Model-authored debug scripts "ran unread".** Driver lapse, P43; audited afterwards, nothing outside the
  sandbox.
- Forks' own withdrawals are in their reports (27 across nine forks).

---

## Model behaviour (not lain defects)

- **Literal `<function=…>` on a clean first ask, three times this round:**
  - a rails-blog launch;
  - a cloud-summarizer probe chat;
  - a spike in the epic fork.

  Each is journaled as `malformed_response kind=prose_tool_call`, and a restart fixed each. A
  `malformed_response` record now exists for what used to be read off the pane.
- **Loops to the 25-iteration ceiling.** Rust-cli: `cargo test` ×4 and `todo_write` ×12. Bowling:
  `run_skill execute-plan` used as a shell, re-injecting a 7 KB skill doc per call.
- **Parallel tool calls:** 3–6 in one message (main, secret, epic).
- **`/create-plan` succeeded this round. `/execute-plan` did not:** it spawned read-only `researcher`
  children that asked clarifying questions in a loop.
- **Bowling scored 4/5 oracles.** The spare bonus used `rolls[i+1]`, and the model could not fix it after
  6 debugging scripts. Its own `/critique` blamed the tenth frame.
- After a human denial the model spawned a subagent to run the denied command. That child had no
  `bash` and said so.
- Under `/mode +auto_approve` the judge answered DEFER 6/7 times, and once DEFER plus `ask_human` (F141).
- The `qwen3:4b` secret oracle reasons from the fixture directory's name (`secrets`).

---

## Process

- **P40 — four contexts hit the isolation-grep trap in new spellings (HIGH process).** Main, review,
  repl and secret each wrote a variant of `^(XDG_(CONFIG|STATE|…)|TMPDIR)=…` or a `grep -c` with a
  nested group. Each matched `TMPDIR` alone and read as a leak or a pass. The positive-control rule caught
  it every time, but four re-derivations of one recipe is the recipe's defect.
  **Folded:** `qa-sandbox.sh` now writes `$QA/isolation.sh`, which prints per-pane counts with the one
  correct pattern and exits non-zero under 5. `method.md` points at it.
- **P41 — the driver's own bench run re-keyed the shared runner for 65 minutes.** `lain bench arms` sends
  no `num_batch` (F154). While it ran, every chat at 2048 alternated reloads with it. That voided
  rails-blog session 2's compaction act (F136) and contaminated every fork's timings.
  **Folded:** `method.md` gains a "grep `starting llama-server` for alternating `-b`" check, and a rule not
  to run non-chat model commands beside chats while `LAIN_NUM_BATCH` is exported.
- **P42 — thread pane recurrence (P39.4, fifth time).** Main typed a note into an auto-opened
  `lain://thread/…` via `:2wincmd w`, then emptied it with `:undo 0`. The survey fork did the same.
  `answer.sh`/`reply.sh`, written this round, address windows by `bufwinid(bufnr(...))`.
- **P43 — an allow-list that approves a model-authored script by NAME approves unread code.** The main
  bowling judge allowed `ruby <x>.rb`. Six scripts were audited afterwards, all clean, and the rule was
  tightened to `lib/`/`spec/` only.
- **P44 — rootless podman keeps a per-`HOME` container store** (shell), so a close-out `podman ps` must
  run under the chat's `HOME`.
- **P45 — a journal-quiet window is not completion.** It fails under contention, while a call is parked,
  and during a child's approval wait. Four contexts wrote a "last line is a prompt AND the journal is quiet"
  helper. **Folded:** `waitq.sh`/`answer.sh`/`reply.sh` go into `qa-sandbox.sh`.
- **P46 — a multi-token `/mode` probe raised the approve-all posture by accident** (repl, ~20 s, nothing
  dispatched). **Folded:** `method.md` item 4 gains "never include `auto` in a `/mode` grammar probe".

---

## Scenario corrections owed (not applied — the list is the work item)

Each fork report carries its section-level list. Headlines:

- **`session-and-window`:** nothing wrong. Add a HUD-marker note for a guessed window (F175) and F136's
  give-up.
- **`rust-cli`:** the planted `fn main(x: i32)` is read and fixed from `read_file` before any build, so
  the diagnostic path is never exercised. Plant a type error and say "run `cargo build` first".
- **`bowling-ruby`:** `/execute-plan` spawns read-only researchers that loop on questions; budget a
  hand-over.
- **`cockpit-surfaces`:**
  - §5's three-calls-at-once expectation is wrong: `ToolRunner` serialises unsafe calls, so
    multi-pending rows need two requesters.
  - §5's cockpit approval bell and the `/`-line at `/approve`'s `[y/N]` are now driven, and both pass.
  - §8's two-row fold needs two requesters for the same reason.
- **`bench-arms`:**
  - The full run must not overlap any chat carrying `LAIN_NUM_BATCH` (F154). Record `-b` from the
    ollama log.
  - Alone, the run took **800 s**, where the contended run took 65 min for 9 of 32 grades.
  - `qwen3:4b` and `qwen3-coder:30b` **coexisted**: one load each and no eviction, which contradicts the
    "a second model evicts the first" note (true for bigger pairs, not this one).
  - The run leaves **26 dirty worktree leases** behind (retained 7 days).
  - The header shape prediction is now driven, and holds.
- **`failure-injection`:**
  - §1b: a failed attempt series DOES commit the user turn (F202), and `bench record` cannot produce
    `truncated_stream` (F201).
  - §9 step 4 now marks the read complete anyway (F199).
  - §10's upper-bound decline is unreachable on a fresh result under the default `keep_last` (F173).
  - §12: the oracle and turn no longer overlap at the server; lain waits client-side and journals
    `provider_wait`.
  - §8: add `bash`'s unbounded capture (F200).
  - §6: the first Ctrl-C at `human>` is silent.
- **`rails-blog`:**
  - check window provenance before trusting §1 (F136);
  - `.bundle/config` `path vendor/bundle` plus `--skip-git` needs a `.gitignore` or the vendor tree is
    committed;
  - a model-emitted `<function=` on the first ask happened again.
- **`ollama-cloud-arm`:** §2 is verifiable with a logging proxy on the chat's `--api-base`. §5's WAL read
  gave 2 complete frames, 6,384 and 4,062 bytes, digests joined. Add F152's summarizer check.
- **`secret-boundary`:** §2's table is refused as written by the shape rule; `denied = ["vault"]` does
  not cover contents; do not name the fixture directory `secrets`.
- **`survey`:** re-count `lib` = 788 files / 169,388 lines; the line ceiling cannot be reached on lain's
  own subtrees; F133's note-on-a-masked-line check belongs in §4.
- **`changeset-review`:** sandbox `git init` gives `master`; drive a checkout not at head (F144).
- **`repl-commands`:** the roster lives at `surface_spec.rb:189-191`; `@reviewer[...]` must be
  `@reviewer_code[...]`.
- **`prompt-slots-and-roles`:** §6's paid half probably EXPECTS a cache write, since 20 tool schemas are
  about 4.9k tokens.
- **`shell-terms`/`shell-term-approval`:** drop "void until F92"; add a content control (F131) and a
  docker timeout probe (F139).
- **`subagents-and-backends`:** lease paths are NOT random. Round 17's correction is wrong: they are a
  hash of the per-process worker key, and leftovers are moved aside.
- **`memory-and-dogfood`:** §1's reduction wants `request_sent`; §4's "a prefix" is a filename without
  `.ndjson`; §6 needs a per-query-class reading (F167).
- **`epic-tier`:** E16's refusal lives in `epic land`/the driver, not `status`/`gc`; add the
  parseable-damage rows (F151).

---

## Coverage — the directory listing is the authority: 18 scenarios

| scenario | driven | what, and the reason for anything not driven |
|---|---|---|
| `session-and-window` | **yes, §1–§9b** | all pass; F109 re-check passes; F175/F176 LOW |
| `rust-cli` | **yes** | oracle pass (`the 3`/`cat 1`, 4 tests); cargo E0308 diagnostic arrived whole, exit 101; `lain://journal` populated with no stuck placeholder; two gated calls in a turn answered from nvim and from `/approve`; compaction at `approaching_window` fired. Ctrl-C mid-call: driven (F172) |
| `bowling-ruby` | **yes** | **4/5 oracles** (model's spare bonus); `/create-plan` wrote a plan; `/execute-plan` failed on the model; wedge `@researcher[/critique]` → 44 `message`, 104 `child_turn`, 0 unresolved causal refs; fork at head, fork mid, resume (F124 fixed) and a control all exit 0; ran to a natural `over_window` refusal (F90 fixed; F173) |
| `cockpit-surfaces` | **yes, on the bowling tree** | §1 (8 buffers, approval takes no window), §2, §3, §4 (all refusals, rails, tall and multi-line, `blocking=false`), §4b (5/9/2/3 order, kinds, blocker to the policy and resolved), §5 (arrival, `command>`, `/approve`, `/`-line held at `/approve`'s `[y/N]`, cockpit approval bell and `display-message`, `--no-nvim` guards 1 and 2), §5b (cockpit `/inbox` drain, `/status`, `/nonsense`, prose answer), §6 (multi-line timeline, invalid-UTF-8 name primes all 8), §7 (idle elided at a parent `ask_human`, BELL lighter), §8 (single row). Not driven: §5 three-at-once and §8 two-row (unreachable as written, see corrections); §5 guard 3 (plain-chat question answered elsewhere: no second surface in `--no-nvim`) |
| `bench-arms` | **yes** | All pre-spend refusals exact. Run 1 ran contended and was **stopped at 9 of 32 grades** because it thrashed the shared runner (F154; F178 for its Ctrl-C). **Run 2, alone, completed in 800 s:** the header's four lines match (fixture path, model, `worktree`, no credential or URL); grader means 0.312, 0.646, 0.625 and 0.438, all well above 0.0625; non-zero on six tasks besides `fix-off-by-one-loop`; a non-zero token row for every arm; the cost section `not priced` as one line; no stall; the rest renders. Not driven: the dual-ledger terminal-state distinction (not rendered in the report; budget) and a second warm run (the only outlier, 54.6 s, was not a first-arm load) |
| `failure-injection` | **fork, §1–§12 + check 5** | check 5 PASS; §3's supervisor door has no chat path (one-shot only); §8's byte-identity across the `lain-core` arm is unreachable from a chat by design; §9 step 5 proper needs a `--num-ctx` past ~66k tokens, which re-keys the shared runner for every context, so it was not taken (F199 reached the edit another way) |
| `repl-commands` | **fork, all** | ambiguity refusals unreachable (~300 turns); live-worker `/undo` and `/keep` actors unreachable from chat; kill mid-undo (budget) |
| `prompt-slots-and-roles` | **fork, §1–§4, §6 free half** | §5 left to specs by the scenario; §6 paid half: no `ANTHROPIC_API_KEY` (checked) |
| `epic-tier` | **fork, mostly** | §10d gate deny/timeout, stale attach token, second terminal adjudicated verdict, generated tests already passing, `:no_source` at land, `rebase_retries = 0`: budget (~40 min of GPU per actor); `finish` against GitHub: capability gap (`gh auth status`: not logged in) |
| `survey` | **fork, all** | §7 check 4 (replay) has no production path (F157) |
| `shell-terms` | **fork, all but §9** | §9 paid: no `ANTHROPIC_API_KEY` (checked); the reduction over a local journal was taken as a free substitute (75% term, probe commands only) |
| `shell-term-approval` | **fork, all** | the decision-to-exec TOCTOU is documented and needs a racing writer |
| `secret-boundary` | **fork, §0–§7** | §6 blackhole row (no endpoint seam), unrecognised verdict and below-threshold (no seam), fault-after-oracle-allow (releases bypass the ladder); §5b's thirteen spellings not re-driven one by one |
| `changeset-review` | **fork, §0–§8 + check 8** | none |
| `subagents-and-backends` | **fork, §1–§6** | actor, nested and depth cap: no chat path; daemon stop: podman has no daemon |
| `memory-and-dogfood` | **fork, §1–§7** | T22's adopted-actor follow-up needs an epic session (not in that sandbox) |
| `rails-blog` | **yes, §0–§5; the blog is not finished (the model's, as the scenario allows)** | Rails 8.1.3.1 installed in 10 s and `bundle install` into `vendor/bundle` in 33 s, with no `GEM_HOME` in lain's environment (P9 sidestepped). Session 1 was lost to MODEL-1. Session 2 did 25 turns of scaffolds and migrations with compaction disabled by F136. **Session 3, §1:** composed compaction fired for real at 30,424 tokens (`66625→47202` B, a `compaction_cut` naming the strategy) and then wedged on F173. **§1b:** a `todo_write` completing nothing did not un-compact (25 → 27 messages, same cut); `/rewind 13` retreated the cut; a `--resume` rendered the recorded cut with no summarizer call before its first request (26 of 27 prefix messages byte-identical); the "make room with compaction" refusal variant was driven. **§2:** largest tool result 8,747 B (a generated `public/422.html`). **§3:** 10 gated calls, each read in `lain://approval`; `.lain/config.toml` stayed empty. **§5:** `lain friction` gives the cacheless wording, no dollars, and 0 paths or content. Not driven: `/model` mid-session (budget), `elide+summarizing`'s deliberate `Overlap` (budget). DoD: `bin/rails test` 21 runs, 1 failure, 5 errors; 18 routes resolve |
| `ollama-cloud-arm` | **yes, §1–§5** | 6 completions spent: 2 on §5's turn, 2 in-session summarizer attempts and 2 direct replays (F152). §6 skipped on its own advice |

---

## Negatives

| check | result |
|---|---|
| `find ~/.local/state/lain -newermt '2026-09-15T10:07:13Z'` | **0**; control `-newermt 2026-09-01`: **1264**. Every fork reported the same pair |
| `git status --porcelain` (XDG unset) vs the baseline taken before act 0 | identical except this round's own deliberate edits: `SKILL.md`, `qa-sandbox.sh`, `method.md`, and this file. `Gemfile.lock` untouched (P9 held; Rails ran from `vendor/bundle` with no sandbox `GEM_HOME` in lain's environment) |
| `ls -d $LAIN_REPO/.lain ~/.lain` | **absent** |
| `dunstctl count displayed` / `waiting` | **0 / 0** |
| tmux servers | main and all nine fork sockets killed; none answers `has-session` |
| stray processes / ports | no `exe/lain` and no process naming a round sandbox. Nothing listens on 21400–21499, 22000–22899 or :3000. The round's proxies (`proxy.rb` :21444, `psfake.rb` :21451–21453) were killed by pid, and so was the ollama server this round started (`pid 3103610`, which it had not been running at round start) |
| containers | `podman ps -a` empty in the operator's store and in both redirected-`HOME` stores (shell, secret) |
| `OLLAMA_API_KEY` bytes in any main-sandbox journal, WAL or record | **0** (checked with the value, never printed) |
| secret-boundary §7 grep outside the fixture | not empty, every hit accounted for (secret fork report §7): S1/F131, S3/F155 and S4/F140 reproductions, the symlink `read_file`, and text the driver typed. Generated keys deleted |
| left in place as evidence | all ten sandboxes; retained worktree leases in `project/arms` and `project/arms2` (F178), the epic fork's `tiny`/`plans` checkouts (F149, F150) and the subag fork's `retained/` lease (F135) |
