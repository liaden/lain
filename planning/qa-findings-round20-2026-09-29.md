# QA round 20 — 2026-09-29

## Summary

A full round over **all eighteen** scenarios in `planning/qa/scenarios/`, driven in ten contexts:
nine parallel forks (`a` to `i`, each with its own sandbox and tmux socket) and this context, which
drove `bench-arms` alone once the forks had finished. **Every scenario was driven; none was dropped
whole.** Sections that were not driven are named in the coverage table with a reason. The spine was
NOT sequenced (`session-and-window`, `rust-cli`, the subject and `cockpit-surfaces` ran concurrently
in forks `a` and `b`); that is a departure from README's ordering, taken for wall-clock.

**Round 19's two persistent HIGH families are still open, one route further on each.** N1 (`read_file`
through an in-root symlink) was found unfixed by two independent forks (`d` and `h`), and fork `d`
found it is **worse for a denied target**: the release prompt is approvable, so an unliftable denial
can be lifted. F133 (a review note journals a masked line's raw text) is also unfixed. And `bench
arms` still cannot report (Fp-3): a task hitting the iteration ceiling aborts the whole run, and this
round reproduced it on a two-task fixture.

**One new HIGH:** each context handoff decays the state document (RB-1). The summarizer is fed the
previous document truncated to ~200 characters, so by generation 3 the Goal reads "Build a Rails blog
application" and Progress reads "No progress made"; generation 1 invented "user authentication".

**What is in good shape.** The round-19 headline (no generation cap on the ollama wire) is FIXED
and was confirmed on the wire by four forks (`num_predict` 4096, `num_batch` 2048, `truncate=false`).
Fp-1 (child prose tool call), Fm-1, F135, F137, F93, F99, F62/F88/F89/F90/F95/F96, Fk-1 and the
unliftable-denial rung under both `checkout ask` and `checkout auto` all hold. `bowling-ruby` scored
**5/5 oracles**. Every refusal's delivery had zero `stack traceback`.

**Two environment findings shape how much to trust the numbers.** (1) Nine forks on a 15 GB box got
the shared `llama-server` **OOM-killed at 10:13:32** with load average 33. (2) Fork `c`'s hand-typed
`curl` probes, which sent no `num_batch`, re-keyed the shared runner to `-b 512` four times. **No
wall-clock figure in this round is a measurement** except `bench-arms`, which had the box to itself
(no `-b` change and no stall error during either run).

| id | sev | what |
|---|---|---|
| **D-1 / H-2** | **HIGH** | N1 not fixed. `read_file` through an ordinary-named in-root symlink to a **denied** key parks an approvable release prompt (an unliftable denial can be approved); to a **gated** file it returns the bytes with nobody asked, unless the bytes hold a detectable region |
| **RB-1** | **HIGH** | each handoff decays the state document: the summarizer sees the previous document cut to ~200 chars; generation 3+ reads "No progress made" |
| **BA-1** | **HIGH** | Fp-3 not fixed: one task hitting the iteration ceiling aborts the whole `bench arms` run; no report, no grade table, no cost column, and 28 locked worktrees left |
| D-2 | MED-HIGH | F133 not fixed: a review note on a masked line journals `anchor_text` raw; the review NEW window shows the line unmasked |
| H-1 | MED-HIGH | `ComposedTerm` auto-approves `cat` of credential files whose names are not in the `Sensitivity` table and whose bytes `Regions` cannot recognise (`_netrc`, `.authinfo`, `.msmtprc`, `.pgpass.bak`, `.htpasswd`, `.vault_pass`, `passwords.txt`, …); live: `cat _netrc` released `password hunter2hunter2` |
| B-1 | MED-HIGH | note markers survive a settled review; the next survey of the file redraws them and `\LN` journals them again (4 notes placed, 7 journaled) |
| A-1 | MED-HIGH | in a cockpit a typed `/goal off` mid-drive only runs after the goal hits its cap; `:LainGoalOff` stops it after 1 iteration |
| E-1 | MED-HIGH | `lain consolidate` wrote items under the human's own ids and replaced their bodies; a fresh chat's `memory_read` returned the clerk's paraphrase |
| RB-2 | MED-HIGH | `--resume` drops `compact_strategy` although the header recorded it; the resumed chat sends 183,169 tokens and is refused |
| E-3 | MEDIUM | SIGHUP mid-spawn: no completion record, no `ending_not_recorded`, lease never released (SIGTERM is correct) |
| RB-3 | MEDIUM | with `--compact-keep 4 --no-nvim` an over-window ask gets no handoff when the only droppable content is one lone turn; 13 asks refused |
| A-2 / I-2 / B-6 | MEDIUM | a prose tool call, or a turn stopped on `max_tokens` before text, is shown as an ordinary answer or as nothing; `Agent#failure_reason` has no reader outside `agent.rb` (round 19's Fp-1, main-chat path) |
| I-1 | MEDIUM | `CLOUD_WINDOWS` holds 5 retired tags that still claim a `published` window (F126 again) |
| H-3 | MEDIUM (design) | an unparseable `.lain/config.toml` no longer refuses the launch; `[shell]` exclusions are dropped, said only in startup notices |
| G-1 | MEDIUM | `lain epic add` accepts ids the tier then refuses (`late_discovery`, `a.b`); the epic is then refused by every command |
| C-1 | MEDIUM (UX) | a stopped ask leaves its `ask_human` row in `lain://inbox` and `inbox:N` in the HUD for good |
| E-2, D-3, B-2 | MEDIUM | memory rows record no provenance; `--secret-oracle` is inert (`defer` at 0.0); approve settles over an un-handed-back blocker |
| G-3 (Fv-3) | LOW-MED | `/stop` says `no ask is running` beside a running docent: NOT FIXED, seen by `b`, `g`, and related to `c`'s C-2 |
| Fr-2 | LOW | a non-zero `bash` exit is `is_error: false`: NOT FIXED (seen by `a` and `c`) |
| the rest | LOW–LOW-MED | itemised under "Per-context findings" |

## Round-19 defects re-checked

| id | verdict | evidence |
|---|---|---|
| Ff-1 / Fv-1 (no generation cap on the ollama wire) | **FIXED** | captured bodies `options={"num_predict"=>4096,"num_batch"=>2048}`, `truncate=false` (forks `a`, `c`, `i`, and `--max-tokens 40` stopped at 40 on ollama.com); `--max-tokens 0` refuses at construction |
| Fs-1 (symlink through `ComposedTerm`) | **FIXED at the rule** | 6 link rows abstain; live `cat readme2.txt` parks (`h`) |
| N1 (`read_file` through the same link) | **NOT FIXED, worse than filed** | D-1 / H-2 |
| Fv-2 (`--root` ignored) | FIXED | `g` |
| Fp-1 (child prose tool call) | FIXED for the child path; **the main-chat path shows it as an answer** | `e`, `b`; A-2 |
| Fm-1, F135, F137 failed-child, F97, F168 | FIXED | `e` |
| Fm-2 / N3 (consolidate clerk, prose tool call) | not driven | `e` did not inject at the clerk |
| Fv-3 / N2 (`/stop` on a running docent) | **NOT FIXED** | `b`, `g`; `e` reached a one-shot child parked on `ask_human` and `/stop` worked there |
| Fp-2 (HUD row after a layout change), Fc-2 (`/review` detached) | FIXED | `b` |
| Fx-1 (`/undo` after a plan-scope write) | not driven | outside every fork's sections |
| Ff-2 (damaged `message` escapes as `KeyError`) | FIXED | `c`; `role: null` still says "has no role key" (nit) |
| Fk-1 (credential in history) | FIXED | `a` |
| Fp-3 (`bench arms` aborts on the ceiling) | **NOT FIXED** | BA-1, reproduced twice |
| Fr-2 (non-zero exit is `is_error: false`) | NOT FIXED | `a`, `c` |
| Fv-4 (two path bases) | NOT FIXED | `b` (B-5), `g` (G-6) |
| Fb-1, Fr-1 | Fb-1 not driven; Fr-1's floor half only | `c`: the >256 KiB half is unreachable live (C-6) |
| F173 handoff | FIXED in the cockpit; same class **NOT FIXED** under `--no-nvim --compact-keep 4` (RB-3) | `f` |
| F136, F82, F88/F89, F90, F94/sticky cut, F95 | hold / not reproduced | `f`, `c` |
| F133 (note journals masked text) | **NOT FIXED** | D-2 |
| F131/F91 named rows | FIXED for named rows; the class is open (H-1) | `h` |
| F92 (`shell_arm` reaches the journal) | FIXED | 5 records for 5 bash calls that ran, under `ask`, `auto` and docker |
| F93, F99, F100, F112, F117 | FIXED | `g` |
| F62, F63, F103, F128 | FIXED | `d` |
| F81 / F64 (relayed child question) | FIXED | `b`: the inbox row clears |
| F23, F29, F17 | FIXED / FIXED / not reproduced | `b` |
| F96, F104, F122, F125, P46 | FIXED / hold | `a` |
| T3 (240.0.0.0/4) | FIXED | `h` |
| F169 | unchanged | `e` |
| F132 (`/fork` starts the child on Anthropic) | not driven | `a` drove `/fork` refusals only |

## The HIGHs

### D-1 / H-2 — `read_file` through an in-root symlink (round 19's N1), unfixed

Two forks, two fixtures. Fork `d`: `notes.txt -> $HOME/.ssh/id_qa` (a **denied** key) parks a release
prompt, so a denial the docs call unliftable is approvable; `readme2.txt -> .env.local` (gated) returns
the bytes with no prompt. Fork `h`: `plain.txt -> .netrc` (denied) and `key2 -> config/master.key`
(gated) returned bytes with no `approval_pending`; the direct spellings are refused
(`read_refused reason=protected`) or parked. `readme2.txt -> .env` parked only because its content held
a detectable region. **Mechanism:** the tool-side path check judges the literal word, while round 19's fix
made only the `ComposedTerm` rule classify where the link lands. **Repro:** `ln -s .netrc plain.txt`,
then ask the model to `read_file plain.txt`. **Evidence:** `~/tmp/lain-qa-2026-09-29-h/records/journal-cockpit2.ndjson`,
`~/tmp/lain-qa-2026-09-29-d/records/journal-cockpit*.ndjson`. **Fix shape:** classify the resolved target
in `read_file`'s gate, not the literal path; pin with a spec that reads a link to each of a denied and
a gated file.

### RB-1 — a handoff decays the state document

In the summarizer's `request_sent` (14:15:17, 1,554 bytes) the previous document is one truncated line
(`## Goal Build a Rails blog applicatio... [980 bytes in full]`) and "conversation since" is one line
per turn cut to ~200 bytes. The first handoff's summarizer input held **0 hits** for "Build a Rails"
although the pre-handoff render carried the directive verbatim (3 hits). Generation 1 invented "user
authentication" and dropped Tags; generation 3 onward reads Progress "No progress made". **Ruled out
the innocent explanation:** the `todo_write` workspace block kept the truth, which is why the model's
next answer was still right; the loss is in the handoff document, not the model. **Repro:** two 45 KB
filler prompts under `--compact-strategy elide-tools+summarize-conversation --num-ctx 32768`
(`~/tmp/lain-qa-2026-09-29-f/records/`). **Fix shape:** stop truncating the previous document in the
summarizer's input (it is the state the next document must carry), and pin it with a spec that a
second handoff's request contains the first document whole.

### BA-1 — `bench arms` cannot report (round 19's Fp-3)

Run 1 (all 8 tasks, 4 arms, `--isolation worktree`): 16 `grade_record`s, then `loop ran 25 iterations,
ceiling is 25`, **exit 1 after 6m58s**, no report. Run 2 (a two-task subset, `records/tasks-subset.yml`):
6 grades (single-thread, orchestrator-worker and dual-ledger complete), then the **adaptive-router** arm
ran 64 s and aborted the same way. So narrowing the fixture does not reach the report, and the header,
grade table, token table and cost column **were not driven**. The grades are recoverable from the
journal, which is a mitigation and not a report. **Leak:** 28 worktrees remained after both runs
(round 19 counted 11); `lain worktrees gc` reaped 0 and kept 28 for "uncommitted changes", so a failed
bench costs a retained checkout per lease for 7 days. **Also:** a refused run (`--cheap-model` missing or
equal to `--model`) leaves a 159-byte journal file holding one `capability_degraded` record
(`records/x1.ndjson`): a refusal that is meant to be pre-spend still writes. **Fix shape:** catch the
iteration-ceiling error per task, journal it as a failed grade, and let the run continue to its report;
pin with a spec that one over-ceiling task yields a report with that task marked failed.

## Per-context findings

Full text and evidence: `~/tmp/lain-qa-2026-09-29/records/fork-reports/` (one file per fork; `a`, `b`, `c`,
`d`, `e`, `f`, `h` are the relayed reports, `g` and `i` are the forks' own findings files, the harness having
refused a fork's write of `findings-<x>.md` for seven of the nine).

| ctx | scenarios | findings |
|---|---|---|
| a | session-and-window, rust-cli, repl-commands | A-1 MED-HIGH, A-2 MEDIUM, A-3 LOW-MED (`cat` of a gated key under `/mode auto` runs; the refusal says a human must approve and never mentions `/mode ask`), A-4, A-5 LOW; one withdrawn |
| b | bowling-ruby, cockpit-surfaces | B-1 MED-HIGH, B-2 MEDIUM, B-3 (`deniedI apologize` has no newline), B-4 (newest ended child hidden under `+1 more`), B-5, B-6, B-7 |
| c | failure-injection | C-1 MEDIUM (UX), C-2 (`/stop` held silently until the ask ends), C-3 (raw `[lain:compaction stderr]` x4), C-4, C-5, C-6 (scenario s8-10 stale: 16 KiB ceiling everywhere), C-7 (Fr-2), C-8 (second `lain up` on one project dies in ~1 s) |
| d | secret-boundary, changeset-review | D-1 HIGH, D-2 MED-HIGH, D-3 MEDIUM, D-4, D-5 (`x` marks a changeset row reviewed unopened, so strict `approve` can be met blind), D-6 |
| e | subagents-and-backends, memory-and-dogfood | E-1 MED-HIGH, E-2, E-3 MEDIUM, E-5 (`improve` does not say whether the store moved), E-6, E-7 (`bench sweep`: `bm25` does not rise from k=1 to k=20), E-8 (a deterministic ollama 500 is retried 4 times) |
| f | rails-blog | RB-1 HIGH, RB-2 MED-HIGH, RB-3, RB-4, RB-5 |
| g | prompt-slots-and-roles, survey, epic-tier | G-1 MEDIUM, G-2 (docent thread on a masked PEM refuses for lines >= 2), G-3, G-4 (status feed frozen during `/implement-epic`), G-5, G-6 |
| h | shell-terms, shell-term-approval | H-1 MED-HIGH, H-2 HIGH, H-3 MEDIUM, H-4 (`ff02::1` not blocked), H-5, H-6 (one `chmod 000` file fails the whole shadow snapshot), H-7 |
| i | ollama-cloud-arm | I-1 MEDIUM, I-2 MEDIUM (UX), I-3 (scenario says 21 rows, table has 24) |
| me | bench-arms | BA-1 HIGH |

**Same class arriving one route past each fix, again.** N1/H-2/D-1 (a symlink), A-2/I-2/B-6 (a
detected-but-invisible failure), Fr-2 (a failure recorded as success) and F133/D-2 (a masked value
re-journaled by a different record) are each an earlier finding whose fix landed on one path.

**Withdrawn on the mechanism:** `a`'s "`lain://journal` misses the failing build" (`nv.sh buf` defaults
to 20 lines and the driver read the top of the buffer); `d`'s silent re-mask after a denied release
(documented in `redact_secret_reads.rb`); `b`'s and `g`'s `settled`/`stopped` lifecycle nit is
deliberate (`lineage.rb`) and is a scenario correction, not a defect.

## Model behaviour (not lain defects)

- `<function=` written as prose in `a`, `b`, `f`, `h` and this context's `bench arms` run (a
  `malformed_response kind=prose_tool_call` journaled); restarting with the same prompt succeeded.
- After answering, the model re-emits `todo_write`/`session_usage` until the 25-call ceiling (3 of ~10
  cockpit asks in `c`; `a` too).
- After a denial it refuses from context (`d`) or calls `ask_human` instead of retrying (`h`, 3 of 3).
- The summarizer model invented "user authentication" and later "no work has been done" (`f`; the input
  truncation is lain's, RB-1).
- The parent pasted the `<workspace>` manifest into a subagent prompt, which is what let the clerk write
  the human's ids (`e`; E-1's trigger, and E-1's defect is lain's).
- On `bench arms` the adaptive-router arm hit the ceiling on both runs; whether that is the model or the
  arm is not settled here.

## Coverage — all eighteen scenarios

| scenario | ctx | driven | not driven, and why |
|---|---|---|---|
| session-and-window | a | §1, 2, 4, 5, 6, 7, 7a, 8, 9, 9b | §3: the runner was already resident (other forks); evicting it would disrupt them; `32768 probed` read on turn 1, so the fallback row is **inconclusive, not a pass**. §2 counted by rendered ordinals only |
| rust-cli | a | happy path, compile error, Ctrl-C, ceiling | two gated `bash` calls in one turn did not occur |
| cockpit-surfaces | b | §0-§7 (both §5 postures, §5b, §4b thread pane) | §0 detach/reattach (needs a real terminal); §1 grandchild row (`researcher` has no spawn tool); §5 guard 3 and second-chat refusal; CJK clamp/ESC scrub inconclusive; §8 driven with one parked row only (steps 3-5 need two) |
| failure-injection | c | §1-§12 | `lain-core` arm (`--exec core` refuses by design); `--fork` on flat damage; §12 control 1 (uncached prefill) not taken, so hidden calls are **inconclusive** (117 first bytes vs 115 journaled) |
| bowling-ruby | b | §1-§3, oracle 5/5 | `/critique` text (transcript poisoned); `/meta summarizer` (budget) |
| bench-arms | me | the five pre-spend refusals; two live runs | header, grade/token/wall/cost tables and the variance path: **unreachable while BA-1 stands**; the `failed.ndjson` set-aside path not driven |
| rails-blog | f | §0, 1, 1b, 2, 3, 4, 5 | §1b `collapse` cut not reached; `/pin` in a held range (stated open decision); §5 `/model` switch (a second model would evict the runner every fork shares) |
| repl-commands | a | §0-§5, 7-9, §6 partly | §2's 4-hex ambiguity and a pin across a real compaction; §3b live-worker refusal; §4 `/keep` with actors; §6 checks 4-5 need a `denied` fixture key |
| epic-tier | g | §0-9, 10a-c, 10e, 13a, 13c, §12 refusals | §10d; parts of §11 and §13b (turn limit); **§12 `finish` forge half dropped by decision**: `gh` here is logged in to a real account and creating a repo is not the driver's to do |
| secret-boundary | d | §0-§4, §5, §6 partly, §7 | §5b spelling table (would read a real key under `auto`); §6 unrecognised/sub-threshold/unreachable oracle rows; §2 rooted pattern with no root |
| changeset-review | d | §0-§5, §7, §8 | §6 chunk sizing vs window, refusals, Ctrl-C; §7 route to github.com not cut; §1 cockpit `master` wording |
| subagents-and-backends | e | §1-§6 | depth cap, actor and nested spawn (no chat path); `--exec local` diff; live-actor tail |
| memory-and-dogfood | e | §1-§6 | resumed-chat-does-not-inherit; `StaleEmbeddings` (unreachable from the CLI); missing corpus |
| ollama-cloud-arm | i | steps 1-5 (5 paid completions) | step 6 saturation/429 (budget: burns quota by design); step 7 is a statement |
| survey | g | §1-§7 | none |
| prompt-slots-and-roles | g | §0-§4b, §6 free half | §6 paid half: `ANTHROPIC_API_KEY` unset (`[ -n "${ANTHROPIC_API_KEY:-}" ]` false) and `.envrc` exports only `OLLAMA_API_KEY` (count 1); §5 spec-covered |
| shell-terms | h | §0-§8 | §9 is not the paid measurement (same missing key); a local reduction over 4 sessions stands in and is **not a distribution** |
| shell-term-approval | h | §0-§3a, 4a, 5, 7, 7a-11 | §4b belongs to secret-boundary |

## Environment and process

**The two environment events.** OOM kill of `llama-server` at 10:13:32 (load 33, nine forks, 15 GB); and
runner re-keys to `-b 512` at 09:27:55, 09:28:21, 09:29:11 and 09:29:35 caused by fork `c`'s hand `curl`
probes, plus `-b 1024`/`2048` pairs at 10:23 and 10:25 that no fork claimed. This round's `bench arms`
runs began at 15:30 UTC with no start after 11:18 local in the serve log.

**Close-out negatives.**
- `find /home/tara/.local/state/lain -newermt 2026-09-29T13:17:29Z` = **0**; positive control (`-newermt 2026-09-01`) = **1315**.
- `git status --porcelain` diffed against the round-start baseline: only `.claude/skills/manual-qa/scripts/qa-sandbox.sh`, which this round edited on purpose (stale ollama client path). `references/repos/smolagents` was already in the baseline. `.local/` and `not/` are older ignored leftovers (nothing under them is newer than the round start).
- `ls -d /home/tara/dev/lain/.lain` and `~/.lain`: neither exists.
- `dunstctl count displayed` / `waiting`: 0 / 0.
- No round tmux server is running (13 stale socket files, all "no server running"), no lain process remains, and `ss -ltnp` shows nothing on the round's ports (3000, 3001, 214xx, 215xx, 234xx).
- The sandbox directories `~/tmp/lain-qa-2026-09-29` and `-a` to `-i` are left in place. Fork `e` left one retained dirty checkout, and this round's `bench arms` left 28 retained worktrees under `~/tmp/lain-qa-2026-09-29/xdg/state/lain/worktrees/`.

**Process lessons, and where they went.** Folded into `planning/qa/method.md` under "Round 20": the
concurrency cap and the hand-`curl` rule, `pipestatus`, the seven stale scenario claims below, and the
helpers worth shipping. Scenario text itself was **not** edited this round.
- `qa-sandbox.sh` shipped a stale ollama client path (0.32.12; the server is 0.34.4): **fixed in this round**.
- `repl-commands.md` says 23 commands; the roster is 25 (`/qa`, `/stop`).
- `session-and-window.md` §6 says `extra={}`; it is `{"num_batch"=>2048}` (commit `e39dda35`).
- `subagents-and-backends.md`'s "random-id leases" claim is false (the same worker key lands at the same path).
- `memory-and-dogfood.md`'s 256 KiB ceiling is 16384 bytes for write and read.
- `shell-terms.md` §4 and `shell-term-approval.md` §4a build `Classifiers` with the old `root:` shape, which abstains every row (negatives pass, positives fail).
- `failure-injection.md` §8-10 name `WHOLE_BOUND`/`WINDOW_BOUND`, which are gone.
- `epic-tier.md` §3, §6 and §0 carry three stale claims (`LAIN_PROVIDER` must be unset; the round-18 approval refusal; `Blocked by:` is not writable).
- `ollama-cloud-arm.md` step 4 says 21 rows; the table has 24.
