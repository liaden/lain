# QA round 7 — 2026-08-20

## Summary

**Five scenarios driven, two not: `bowling-ruby` was dropped (a named decision, below) and
`rails-blog` is owed as its own round.** `session-and-window` and `bench-arms` completed clean end
to end; `rust-cli` completed including its deliberate unhappy path and recovery;
`failure-injection` covered §1, §2, §3, §8, §9, §11a and §12; `cockpit-surfaces` was piggybacked on
the `rust-cli` subject and covered §1, §3, §7, §8 and parts of §2/§5/§6.

**This round's headline is that the surfaces are quiet and the record integrity is excellent.** Both
halves of §2/§3's "invisible at rest, unforgeable on use" hold, the §9 windowed-read deadlock guard
works end to end, and **the fold surface was verified live for the first time** — `method.md` had
carried it as pending "once T9/T12 land".

**Round 6's UX9, UX5, UX8 and UX4 are all confirmed fixed. F26 — round 6's HIGH — did not reproduce,
but grounding it in the code turned up something worse: the capacity gate built to fix it has
telemetry that is never constructed (F28).** F27 is **withdrawn** on re-test and replaced by the
narrower, real F29. Two new defects, one UX finding, one feature gap re-confirmed, five process
defects in the bench's own method, and five withdrawn suspicions.

| id | sev | what |
|---|---|---|
| **F28** | **HIGH** | `Provider::Admission::Journal` — the decorator that emits `Telemetry::ProviderWait` — is **never constructed in `lib/`**, so the capacity gate built to fix F26 has telemetry that cannot fire in production |
| **F29** | **MEDIUM** | once `/inbox` opens its drain read the prompt still reads `human>` but the command registry is no longer consulted, so a `/command` is silently sent to the model as prose |
| ~~F27~~ | **WITHDRAWN** | session commands **do** run at `human>`; re-tested and disproved — see "Withdrawn" |
| UX10 | LOW | no `Tool::Contracts` precondition can name its subject — `requires` takes a static String, so four `edit_file`/`write_file` refusals say a bare `path` while `Tool::Bounds` interpolates the real one |
| FG1 | gap | *(carried from round 6)* `lain chat --prompt` exits **0** when the turn fails outright — re-confirmed against a blackholed endpoint |
| P1–P3 | process | the close-out negative check can pass **vacuously** on this box; `counter.rb` mis-counts across probes; `pgrep`/`pkill -f` self-match (again) |

**The through-line is that the deterministic half of this bench is now genuinely strong.** Every
launch-level refusal, every damaged-journal door, every tool bound and both read-set transitions
refused by name, at exit 1, with **zero backtrace frames** in all 25 refusals driven this round.

---

Bench: ollama 0.32.12 (`/mnt/nvme/opt/ollama-0.32.12`, verified via `/proc/<pid>/exe` — the server
was a pre-existing 2d02h process this round reused), qwen3-coder:30b, `OLLAMA_CONTEXT_LENGTH=32768`,
`KEEP_ALIVE=5m`, KV `q8_0`, Vulkan, `OLLAMA_FLASH_ATTENTION=1`.
**n_slots = 1 / OLLAMA_NUM_PARALLEL = 1**, read from the runner's own argv (`-np 1`) via
`pgrep -P <serve-pid>`, with `-c 32768 -b 512 -ub 512` in the same argv — so every contention
reading below is in scope rather than void.
ruby 4.0.6, nvim 0.12.4, cargo 1.99.0-nightly, tmux server at 220x50 (verified via
`show-options -g default-size` before every launch).
Machine at round start: load 2.70 (ambient Xorg/firefox/steam only), **no orphan spinners**, no
`parallel_rspec`, no `pre-commit`. One unrelated `tmux -L ctrlc2-…` from another agent's work was
present at round start and left untouched.
Sandbox: `~/tmp/lain-qa-round7-2026-08-20`, XDG redirected, `tmux -L lain-qa-round7-2026-08-20`.
All three panes verified carrying sandbox `XDG_*` and `TMPDIR` before act 1.

**Desktop decision: the notifier was OFF for the entire round — no act ran with it live.**
`LAIN_DESKTOP=0` was exported before `tmux new-session` on every launch, and verified **per pane**
(`/proc/<pid>/environ` → `LAIN_DESKTOP=0` count of 1 in all three panes), not merely exported.

**That claim is backed by a negative, and the negative was nearly mis-read.** Mid-round
`dunstctl count displayed` read **1** during a live gated approval, which looks exactly like a mute
failure. It was not: `dunstctl history` showed the queue was entirely **Claude Code's own**
notifications (`appname="notify-send"` / `"kitty"`, summary `"Claude needs your permission"`) from
the driving harness, not lain's. The controlled test settles it — desktop cleared to
`displayed=0 waiting=0`, then a **real lain approval parked**, and the count was still
**`displayed=0 waiting=0`**. Approvals are raised `-u critical` and never auto-expire, so one that
fired would still have been on screen. Desktop verified `0/0` again at close-out.

**Negative check PASSES and is demonstrably NOT vacuous** — see **P1**, because the documented form
of this check returns a false pass on this box. `~/.local/state/lain` exists and holds **95 files**;
its newest is `2026-08-20 06:54:06` local, **67 seconds before** round start
(`2026-08-20T10:55:13Z` = `06:55:13` local). The same probe finds **286** files newer than
`2026-08-19` and **24** newer than `2026-08-20 06:00`, and **0** newer than round start in *both*
spellings (`'2026-08-20 06:55:13'` local and `'2026-08-20T10:55:13Z'` UTC). `~/.lain` absent
throughout (still parked at `~/.lain.bak`). No `.lain/config.toml` was ever written — no durable
pre-approval, correct, since "always" was never answered.

## Round-6 defects re-checked

| id | verdict | evidence |
|---|---|---|
| **F26** (unjournaled concurrent oracle call starves the turn on a 1-slot server) | **NOT REPRODUCED — but the precondition is intact.** Not "fixed". | Driven deliberately with `$QA/proxy.rb` per `failure-injection.md` §12. The **surplus is real and reproduced**: proxy logged **9** `/api/chat` against the journal's **8** `request_sent` — one internal model call still unjournaled (`oracle_answer` is journaled; its *request* is not). But the **starvation did not occur**: no two `START`s within ~50ms anywhere in a 10-request log; the two requests around the oracle were strictly *sequential* (`req#9 END 563.452` → `req#10 START 564.088`, 0.6s apart). **Zero `stalled stream`, zero `run_interrupted` across the entire round.** Caveat stated plainly: my long inspection pauses let `KEEP_ALIVE=5m` evict the model repeatedly, which serialises the timeline and may mask the race. |
| **F27** (`human>` prompt swallows session commands) | **WITHDRAWN — does not reproduce** | Re-driven against a freshly parked `ask_human` with `lain://approval` verified empty first: `/status` → rendered the status block, `/mode` → `accept_edits: no layers active`, `/ruby 6*7` → `42`. Journal **unchanged at 8 lines** across all three, and the question stayed parked (`inbox 1`). The mechanism is wired: `Wiring#build_repl` calls `@replies.bind_commands(@command_surface.commands)` (`wiring.rb:460`) and `Reply#typed` dispatches through it (`human_replies.rb:1050-1054`). Round 7's original observation was a **driver error** — see F29. |
| UX9 (model-facing refusal carries a Ruby class name) | **FIXED** | Every refusal captured this round is free of the `Lain::Tool::ContractViolation:` prefix. Read from `tool_result` blocks: `precondition failed for write_file: path exists and was never read this session`, `old_string occurs 0 times in …`, `approval denied for tool "bash"`, and the bound refusals. The reduction prints from byte 0, so a prefix would show. |
| UX5 (`compaction.tokens_before/after` are bytes under token names) | **FIXED** | The one `compaction` record this round carries **`bytes_before: 78269` / `bytes_after: 27484`**, with `cost_saved`/`cost_spent` both `"0.0"` beside the local model — the documented honest zero. |
| UX8 (retry backoff at 17 significant figures) | **FIXED** | Four independent renders: `0.11s / 0.25s / 0.43s`, `0.14s / 0.25s / 0.41s`, `0.1s / 0.22s / 0.43s`. No long decimal tails. |
| UX4 (`lain://approval` absent at rest) | **FIXED, and correctly scoped** | At attach, before any approval: all seven primed buffers exist, `lain://approval` holds `(no approvals pending)`, **and takes no window** — tab2 had **4** windows (`journal │ timeline │ inbox │ request`). After approvals had occurred it had 5, i.e. the window opens only when it has rows. The over-correction is absent. |
| F18 (a pending approval the chat pane never drew) | **not reproduced** | Every one of 10 approvals this round rendered in *both* the pane and `lain://approval`, agreeing. |
| FG1 (`--prompt` exits 0 on a failed turn) | **still present** | §2's blackhole probe exhausted four attempts against `10.255.255.1` and still exited **0**. Judged by render and journal, per `method.md`. |

Also re-confirmed working: **T6** (window re-resolves mid-session), **T14** (per-ask iteration
ceiling — it fired, said so in one line, and the session survived), **T18/F16** (retry ordinals),
**T12** (`bench arms` attribution header), **UX6** (`lain up` corpse banner — not re-driven; §11b not
reached).

## Discharged by the round-7 chunk

Written after the fix chunk landed — 22 commits, `dcaae313..b13a246b`, planned in
`planning/specs/chunk-qa-round7-constructed-and-consistent.md`. Every verdict below was
established from the code and the commit messages, **not** from that plan's intent. Two of the
four are not "FIXED", and the next round has to read those two rows before re-driving.

**None of these was established by driving a cockpit.** The chunk's own integration check 5 — a
`/manual-qa` pass over `cockpit-surfaces` §4/§4b and `failure-injection` §12 with the proxy — is
still owed and must not be read as done because this table exists.

| id | verdict | evidence |
|---|---|---|
| **F28** (the capacity gate's telemetry is unreachable from production) | **FIXED for every provider `CLI::Backend` builds — and still HALF-OPEN for the secret-read oracle's WAIT** | `Provider::Admitted#admitted` now builds the decorator on every call — `Admission::Journal.new(admission: Admission.for(endpoint: resolved_endpoint), journal: wait_journal)` (`lib/lain/provider/admitted.rb:65-66`) — so the `lib/` construction site F28 said did not exist now does. It is deliberately **not** in `Admission.build`, which is what F28's Fix shape proposed: `Admission.for` memoises one gate per endpoint for the life of the PROCESS while a journal belongs to one SESSION, so wrapping at the gate would hand the first session's journal every later caller's records (`admitted.rb:26-36`). Both includers answer the new third message (`ollama.rb:356`, `anthropic.rb:136`) and `CLI::Backend` threads the run journal into each (`backend.rb:199`, `:444`). `Provider::Bedrock` gets none, correctly — it does not `include Admitted`, so it has no gate and no wait. F28's "second, narrower half" is unchanged and deliberate: an oracle SKIPPED for capacity still journals no wait, because `try_enter` never queued — though it no longer leaves *no* record at all, since `Provider::Journaled` pushes `request_sent` before dispatch, so a skipped eager summary is now a `request_sent` with no `oracle_answer` beside it. **Still open:** `Oracle::SecretRead.tier` builds `Provider::Ollama.new` with no `journal:` (`oracle/secret_read.rb:142`), so that arm's *wait* still lands in `Channel::Null` while its *requests* are journaled on the same line. Guarded going forward by `spec/provider_construction_discipline_spec.rb` (new), which fails the build on a concrete Provider constructed where nothing can journal it. |
| **F29** (after `/inbox`, a `/command` is silently sent to the model as prose) | **FIXED** | `Reply#typed`'s ladder became `#classify` (`human_replies.rb:1108-1119`) and the drain now reads through that same object: `#drained` hands `method(:replied)` to `drain_inbox` (`:1198-1201`) and `#replied` classifies every line (`:1220-1222`), replacing the bare `->(prompt) { @conductor.read_reply(@tty, prompt) }` the finding named at `:1131-1136`. One classification, so the two prompts cannot drift. Both `case`s over `#classify` close with `else raise`, and the `rescue StandardError` that used to wrap `#typed` was **removed** rather than excepted — it would have caught that raise and turned a swallowed reply into a swallowed-and-retried one, which is worse than the defect. **One asymmetry ships deliberately and a round-8 driver will meet it:** an unregistered `/word` is REFUSED inside the drain and still ANSWERED as prose at the bare prompt (`:1214-1219`), because a mistyped command reaching the model as a considered reply cannot be undone while a refusal costs one retype. `cockpit-surfaces.md` §5b was rewritten in the same chunk to drive the drain and to name that asymmetry, so a driver does not file it. |
| **UX10** (`edit_file`'s windowed refusal names no file) | **FIXED, and the whole class with it** | `Tool::Contracts.requires`/`ensures` take an optional `subject:` supplier, handed the same `(input, invocation)` the predicate is, whose answer fills a `%<subject>s` slot (`lib/lain/tool/contracts.rb:26`, `:48`) — the call-time-subject shape `Tool::Bounds` already used, which is what UX10 asked for instead of a reword. **All five** preconditions on the two tools now name the resolved path: `edit_file.rb:68,91,98` and `write_file.rb:57,64`. (The finding counted four; `edit_file` carries three, not two.) Every way of getting a declaration wrong is now refused at class-definition time — a slot with no supplier, a supplier with no slot, a template `format` cannot render, a non-callable supplier, a supplier of the wrong arity — because each of those would otherwise fail only on the refusal path, in production and never in a green suite. A message declared without a supplier never reaches `format`, which keeps the remaining static declarations byte-identical (one contains a literal `%`). `failure-injection.md` §9's expected string moved in the same commit, so the doc that quoted the old sentence verbatim cannot report the rewording as a regression. |
| **FG1** (`--prompt` exits 0 on a failed turn) | **NOT FIXED — discharged by REDIRECTION.** `--prompt` is untouched and still exits 0. | `lain chat --prompt` still seeds a REPL that reads the terminal, and still exits 0 whatever the conversation reached: `exe/lain:884` gates the exit on `options[:non_interactive]` alone, and `ChatLaunch#exit_status` exists for that one caller (`chat_launch.rb:234-244`). The honest status arrived on a **new** flag, `--non-interactive` (`exe/lain:782`), which refuses without `--prompt` (`chat_launch.rb:292-296`), denies every gated call in a sentence written for a model rather than a human (`switchboard.rb:196`), refuses `ask_human` by name and writes no Q event so nothing is left parked in the record (`tools/ask_human/unattended.rb:25`), and exits non-zero unless the turn SETTLED. That last is an ALLOW-list of two stop reasons — `end_turn`, `stop_sequence` (`Repl::Outcome::SETTLED`, `repl/outcome.rb:47`) — because the wire enum is non-exhaustive and a deny-list is precisely how `max_tokens`, `refusal` and `pause_turn` all came to exit 0. **So round 8 re-files against `--non-interactive` and must not read FG1 as fixed:** the sentence in this document, written about `--prompt`, is still true, and it is a decision rather than an oversight. Note the flag must be run directly — under `lain up` the chat sits in a tmux pane whose exit status nothing reads. |

### What the chunk found that this round did not

Three things worth carrying into round 8; the full list is the chunk spec's **Follow-ups**.

- **Stall protection was silently OFF for any Faraday adapter that resumed `on_data` on another
  fiber.** The clock lived in `Fiber[KEY]`, which made "the adapter dispatches `on_data` on the
  fiber that called it" an assumption only a comment could state. Measured against a real stalling
  socket: a subclass resuming in its own fiber took a **transport timeout after 12.2s** where the
  protection should have fired at **0.36s** — reachable rather than theoretical, since the adapter
  is a supported option. The clock now rides `env.request.context`, beside the retry attempt and the
  WAL frame the transports already thread there (`0ce33f6b`). The general shape is worth keeping:
  *an invariant that can only be written as a comment is an invariant nothing enforces.*
- **`spec/refusal_width_discipline_spec.rb` is structurally blind to Lua.** It walks `lib/` **Ruby**
  through Ripper (`@lib_root.glob("**/*.rb")`), so every refusal and acknowledgement authored in a
  `frontend/neovim/runtime/*.lua` file is unmeasured by it. It was hiding a live exceedance on the
  review rail: `assert_saved`'s sentence measured **135 columns with an empty path and 149 with the
  spec's own fixture**, against a bar of 80, one screen above two sentences that had to be measured
  by hand — and the suite was green throughout. The sentence now ends with the path and fits. A
  discipline spec that cannot see a whole class of its subject passes, and its passing means less
  than a reader assumes.
- **An editor below nvim 0.11 now gets a traceback or SILENCE.** The rail's `exists("&messagesopt")`
  capability probe was deleted and 0.11 stated as the minimum (`README.md:366`), but **no version
  gate replaced it**. Measured on a real editor below 0.11: `:LainNoteDone` yields nvim's own
  `stack traceback:` — the exact shape the refusal rail exists to keep off a screen — and on the
  production notify path the refusal **vanishes entirely**, nothing echoed and `:messages` empty.
  `CLI::Up::Binaries#present?` already spawns `nvim --version` and discards the output, so the one
  object built to answer "can this editor run the cockpit?" already holds the answer. A stated
  README requirement is not a gate.

---

## F28 — the capacity gate's telemetry is unreachable from production *(HIGH, new)*

**What is wrong.** `Provider::Admission::Journal` is the Journal-duck decorator that emits
`Telemetry::ProviderWait` when a caller queues for a busy endpoint. **Nothing in `lib/` ever
constructs it.** The only construction site in the repository is its own spec
(`spec/lain/provider/admission/journal_spec.rb`), so no real run can journal a `provider_wait`
record, and endpoint contention is invisible in the experiment record.

**The mechanism, named.** `Admission.for(endpoint:)` (`lib/lain/provider/admission.rb:221`) is the
single construction point; it memoises `build(key)`, and `build`
(`admission.rb:262-269`) returns either `new(endpoint:, width:)` or `Null.new(endpoint:)` —
**never a `Journal`-wrapped gate**. `Provider::Admitted#admitted` calls `Admission.for` directly,
so every provider in the process gets an unjournaled gate.

**Why this is the expensive kind of gap.** `admission.rb:15` states "F26 is the absent concept this
fills", and `admission.rb:216` says "F26, still live, through the exact construction sites this
card exists to cover" — so the capacity gate was built *for* F26 and knows it. The telemetry that
would prove it works is the half that never got wired. It ships green because
`journal_spec.rb` injects its own decorator, which is precisely the failure mode
`create-plan`'s own guidance warns about: a capability built and never constructed on the real path.

**Evidence that rules out the innocent explanation.** "No contention occurred, so no record was
due" is excluded two ways. Round 7's proxy measured a genuine surplus — **9** `/api/chat` at the
proxy against **8** journaled `request_sent` — so a second model call really was issued. And the
count is zero across *every* journal in the round, including the multi-turn cockpit sessions:

```bash
for f in ~/tmp/lain-qa-round7-2026-08-20/xdg/state/lain/sessions/*/*.ndjson; do
  grep -c provider_wait "$f"; done | sort -u    # -> 0
grep -rn 'Admission::Journal' lib/              # -> only a doc reference in telemetry/provider_wait.rb
```

**A second, narrower half worth its own AC.** `Admission::Journal`'s own docstring records that
`#try_enter` "forwards untouched" and that a busy endpoint there is a **skip, not a wait**, so it is
deliberately not journaled. `Oracle::Eager` is the `try_enter` caller. That means even once the
decorator is wired, an oracle *skipped* for capacity still leaves no record — which is the exact
shape of round 6's F26 (an internal call that contends and says nothing). Whether a skip should
journal is a design decision, not an oversight; it belongs in the fix chunk's open decisions.

**Fix shape.** Wrap in `Admission.build`, which is the one place every gate is minted, so a
journaled gate is the only kind that exists. That needs a journal to be reachable from a class-level
factory — the wiring question the fix chunk has to answer, and the reason this is an architecture
card rather than a one-liner. What would pin it: an AC asserting a `provider_wait` record from a
**production-constructed** gate, never an injected one.

## F29 — after `/inbox`, a `/command` is silently sent to the model as prose *(MEDIUM, new — replaces F27)*

**What is wrong.** At a plain `human>` prompt a session command runs correctly. But `/inbox` *serves
replies*: it opens its own drain read over the pending set. That read does **not** consult the
command registry, so the next line typed — even a registered `/command` — is delivered to the model
as the answer's prose. The prompt still reads `human>` and looks identical either way.

**The mechanism, named.** Two paths decide what a typed line means and only one knows about
commands. `Reply#typed` (`human_replies.rb:1050-1054`) checks `prose?`, then `serves_replies?`,
then dispatches through the bound registry. But `Reply#drained` (`human_replies.rb:1131-1136`)
builds a bare `reader = ->(prompt) { @conductor.read_reply(@tty, prompt) }` and hands it to
`@tty.drain_inbox` — no registry, no `prose?`, no refusal.

**Reproduction** (this is exactly what round 7 mis-read as F27):

```bash
# with an ask_human parked and lain://approval verified empty:
send '/status'   # -> renders the status block, journal UNCHANGED, still parked   (registry consulted)
send '/inbox'    # -> renders the question document, journal UNCHANGED            (opens its drain)
send '/mode'     # -> journal GROWS: the model answers "/mode" as the reply       (registry bypassed)
```

Measured: journal 8 → 8 → 8 → **18**, and the model's reply was an answer to the parked database
question, treating `/mode` as its content.

**Fix shape.** Give the drain the same line classification the outer prompt uses, so "what a typed
line means" is one object rather than two paths — or, if the drain must stay prose-only, refuse a
bare registered `/word` there by name rather than shipping it to the model. What would pin it: an AC
driving `/inbox` then a `/command` and asserting no answer is recorded.

## UX10 — `edit_file`'s windowed refusal names no file *(LOW, new)*

**What is wrong.** The refusal reads:

```
precondition failed for edit_file: only a window of path was read this session -- an offset/limit
read showed you part of the file, so editing it would clobber lines you never saw. …
```

`path` is the literal word, and the file was `mid.rb`. **Corrected characterisation:** this is not a
failed interpolation — `Tool::Contracts.requires(message, &predicate)`
(`lib/lain/tool/contracts.rb:37`) takes a **static String**; the predicate receives
`(input, invocation)` and the message never does, so *no* precondition can name its subject.
All four such messages across `edit_file` and `write_file` use the bare word `path`, which is
the tool's own parameter name. It is a consistent convention, not a typo.

**Why it is still a finding.** Every sibling refusal in the same turn names the file in
full — `/home/tara/tmp/…/project/mid.rb is 300000 bytes, over the ceiling of 262144 …`. So a model
holding several windowed files gets a refusal it cannot attribute, from the one message whose whole
job is to say *which* file to re-read. Note `session-and-window.md`/`failure-injection.md` §9 record
this string verbatim as expected, so the drift is between the message and its siblings, not against
the doc — the doc has the same gap.

**Reproduction:** `failure-injection.md` §9 steps 1–3 (below, fully driven and otherwise passing).

**Fix shape, and it is architectural rather than a reword.** `requires` would have to accept a
callable message (or one handed `(input, invocation)`) before any contract can name its subject —
which fixes the whole class, since `Tool::Bounds` builds its message at call time
(`lib/lain/tool/bounds.rb:191`) and therefore *does* interpolate, leaving a model reading two
different styles of refusal from the same tool. Update §9's expected string in the same card so
the two cannot drift apart again.

---

## What passed, with the evidence worth keeping

### `session-and-window` — complete, all eight sections

- **§1** all nine launch-level refusals: by name, exit 1, **0 backtrace frames**.
  `--num-ctx 262144` (at the trained maximum) accepted. The trained-maximum probe was taken with
  residency verified **COLD** first, so it proves what it claims.
- **§2** blackhole timing **26s** at the default connect timeout, **7s** at
  `LAIN_CONNECT_TIMEOUT=1`. Ordinals `1, 2, 3, 4-giving-up` — the last line names a *higher* ordinal
  than the last retrying line, so F16 is fixed.
  **The attempt count is now backed by path attribution rather than inference.** A counting listener
  gave 6 connections against 4 rendered attempts; rather than file the gap, I built a
  path-logging listener (`$QA/pathcount.rb`, 18 lines) which resolved it exactly:
  `2 × GET /api/ps` + `4 × POST /api/chat`. Four chat POSTs, four rendered ordinals — no hidden retries.
- **§3** cold turn → `window=8192 provenance="guessed" signals=[]`; warm turn →
  `window=32768 provenance="probed" used=4806`. The window re-resolved mid-session (T6).
- **§4 the three readers agree, which is a result worth stating.** `compaction_decision.used_tokens`
  **4806** == `turn_usage.usage.input_tokens` **4806**, exactly. `state.json` `occupancy` 0.1472 and
  the HUD's `ctx 15%` both reflect the latest turn (4823/32768). The decision reading the *previous*
  turn's usage is coherent, not a disagreement — it is made before the request.
- **§5** exactly **one** `capability_degraded` line, correct shape, nothing on screen.
- **§6** with `LAIN_NUM_BATCH=2048` → `extra={"num_batch" => 2048}` on the `session` record and every
  `request_sent`; with `env -u LAIN_NUM_BATCH` → `extra={}`. The asymmetry holds.
- **§7** all four strategy names listed in the refusal; the part-vs-whole wording is correct
  (`elide-tools+` reports part `""` and whole `"elide-tools+"`); `elide+summarizing` **launches**, as
  designed.
- **§8** prices exact against both readers — checkout **and** the live process via `/ruby`
  (opus 5/25/6.25/0.5, sonnet 3/15/3.75/0.3, haiku 1/5/1.25/0.1; `cache_creation` = 1.25× input,
  `cache_read` = 0.1×). `BYTES_PER_TOKEN` **4**. `claude-fable-5`/`claude-mythos-5` raise by name.
  All three freshness-lint branches drive correctly, and **the `gsub` guard fired clean** (the probe
  was not testing its own typo).

### `rust-cli` — complete, including the unhappy path

The model produced a correct `wordfreq`, and the driver's own oracle passes:
`cargo build` clean, `cargo test` **3 passed**, and
`printf 'the cat the dog the\n' | ./target/debug/wordfreq -n 2` → `the 3` / `cat 1`, exactly as specified.

The deliberate breakage (`sed -i 's/fn main()/fn main(x: i32)/'`) produced a real `E0580`, which
**reached the model as a usable multi-line tool result** — spans, notes and `help:` intact, no colour
corruption of the transcript — and the model recovered it to `fn main()` with tests green again.
Streamed output reached `lain://journal` (229 lines) and agreed with the pane. A second gated `bash`
in the same turn still got its own approval prompt.

### The fold surface — first live verification

`method.md` carried this as pending. Driven over RPC against a real approval, both shapes:

| case | `foldclosed` per line | reading |
|---|---|---|
| one-line command (3-line buffer) | `[1,1] [2,2] open` | item folded to its summary, blank its own fold, hint open at rest |
| wrapped command (5-line buffer) | `[1→3] [1→3] [1→3] [4,4] open` | **the fold spans the record**, trailer separate, newest open |

Both match `05_records.lua`'s own documented measurement. **Fold independence holds**: `:1foldopen`
opened lines 1–3 and left row 4's fold closed (`closed=4`) untouched — the property
`method.md` says integration check 7 actually needs. `foldmethod=expr`, boundaries are record
boundaries.

### `bench-arms` — complete and clean

All four header lines correct, including `isolation: unset — Arm::NoIsolation leased nothing` (not
blank, not `none`). **No credential and no base URL anywhere in the report** (checked by eye, as
required). All three conjoined checks pass: means 0.812/0.812/0.938 against a 0.0625 floor, and
**every arm backed by non-zero tokens** (230.0 / 444.4 / 3049.1), so no collapsed arm is faking a
grade. The cost column **refuses** rather than printing zeros —
`not priced — no price for model "qwen3-coder:30b"; configure a fallback to degrade` — while score,
tokens and wall-time all still render. No `StalledStreamError`.

**Round 4's unexplained 20× wall-time outlier did not reproduce**: `single-thread` max **2.45s**
against a **1.45s** median (round 4: 29.6s against 1.39s).

### `failure-injection` — §1, §2, §3, §8, §9, §11a, §12

- **§1** 238 lines, **0 unparseable**, 0 `journal_error`. Causal key census `parent: 50,
  causal_parents: 3` — checked *first*, so the §3 probe tests something.
- **§2 both halves.** At rest the torn session reads **50 turns** (one fewer) under the **same** head
  digest `blake3:d172ca2ee82e`, plus `1 line unparsed`. On use it refuses, naming the record index,
  its role and **both** digests.
- **§3 both shapes, three doors.** Dangling and malformed-`null` both land as `Corrupt` — neither
  `Store::MissingObject` nor a bare `ArgumentError` escapes. `--fork`, `--resume` and
  `lain bench variance` all refuse with the same currency, exit 1, 0 frames. A bad digest prefix
  refuses by name. **The `message record N (<label>)` sentence was reached** — it needed the message
  to be *last* in the fold (otherwise a later turn's citation dangles first and reports
  `turn record 50`), and it correctly uses its own index space and the "replay" wording:
  `message record 0 (message) cites a causal parent this replay never landed: …`.
- **§8** live ceilings `[262144, 1048576, 131072, 500]`, exactly as documented. The over-ceiling
  refusal carries the size, the ceiling and several narrower actions.
- **§9 the deadlock guard works end to end** — the highest-value pass this round.
  Whole read refused for size → windowed read → `[false, true]` → `edit_file` refuses **naming the
  window** (not the loop-generating "never read this session") → full-cover window → `[true, false]`
  → `edit_file` **permitted**, proven by it reaching a *content* refusal
  (`old_string occurs 0 times … File left unchanged`) rather than a precondition one.
  A nice touch: the size refusal now discloses the escape inline — *"(a window covering the whole
  file counts as a complete read, so edit_file still accepts it)"*.
- **§11a** all three pre-flight refusals (missing key, `--num-ctx 0`, unknown `--compact-strategy`):
  message on the operator's terminal, exit 1, 0 frames, and **no session created**.
  **`could not pre-flight` appeared 0 times**, so the section measured the pre-flight path and not
  the corpse path — the caveat that decides whether §11a tests anything.

---

## Withdrawn — nearly filed, disproved by the mechanism

- **F27 itself, filed in this document's first revision and withdrawn on re-test.** Session commands
  DO run at `human>`: `/mode`, `/status` and `/ruby 6*7` all rendered, with the journal unchanged and
  the question still parked. Both innocent explanations for the original observation were excluded at
  the time (a control `/inbox` proved the send worked; `lain://approval` was empty), but the third was
  not considered: the preceding `/inbox` had opened its own drain read, and the drain does not consult
  the registry. The behaviour is real and is filed as **F29**; the diagnosis was wrong.
  **The lesson for the method:** `/inbox` changes what the next line means without changing the
  prompt, so a driver must treat "typed after `/inbox`" as a distinct state.

- **"the approval fold hides nothing."** A one-line command folds to `closed=closedend`, which looks
  like a fold that hides nothing. `05_records.lua` documents exactly this
  (*"the blank its own closed one-line fold, only the hint open"*) and explains why the trailer must
  answer true. Designed, not broken.
- **"`:LainDeny` does not clear the approval buffer."** After denying, an identical `cargo test`
  approval was still parked. The journal settles it: `approval_decision … "verdict" => "deny"`, the
  model received `approval denied for tool "bash"`, and re-requested the same command 1s later. The
  buffer held a **new** pending, not a stale one.
- **"the notifier fired despite `LAIN_DESKTOP=0`."** `displayed=1` mid-round was Claude Code's own
  permission popup. See the desktop paragraph above.
- **"a prompt was accepted and answered with nothing."** `request_sent` journaled, proxy `req#9`
  open with no first byte, HUD `idle 3m`, no stall. It was a **model reload** — the runner was 17s
  old and at 41.8% CPU, `KEEP_ALIVE=5m` having evicted during my inspection pauses. It answered
  147.8s later. `method.md`'s "check three things before calling a session wedged" caught this.

## Model behaviour — not lain defects

- **MODEL-1 recurred, and is not deterministic.** The first `rust-cli` attempt emitted its tool call
  as literal text (`</parameter></function></tool_call>`) committed as an `assistant/text` block
  with no `tool_use` at all, so no file was written and the turn simply ended. Per `method.md` I
  restarted rather than continuing. **The identical prompt then succeeded**, so this is a sampling
  failure, not a property of the prompt — worth knowing, because a round that treats it as
  deterministic will wrongly conclude the scenario is undrivable.
- **The model routes around a refused tool.** After `edit_file` was refused on the windowed-read
  precondition, it achieved the same edit with `bash` `sed -i '1s/^/# EDITED/' mid.rb`. Not a lain
  defect — `bash` is a capability and the gate approved it — but worth recording: a precondition on
  one tool is not a constraint on the *session* while `bash` is available.
- The model twice chose result-shrinking commands (`ls -la /usr/bin | wc -l`, `| head -n 10`) when
  asked for something large, which defeated two attempts to summon the oracle.

## Process defects in the bench's own method

**P1 — the close-out negative check can pass vacuously on this box, in two independent ways.**
This is the check that proves the sandbox held, so a false pass is expensive.
`find` here is **bfs**, not GNU findutils: it **rejects** `-newermt 'yesterday'` (and any non-ISO
8601 timestamp) with an error on *stderr* and matches nothing. The documented recipe pipes stderr to
`/dev/null`, so it prints `0` and reads as a pass. Second, `round-start` is recorded in **UTC with a
`Z`**, while `-newermt '2026-08-20T10:55:13'` without the `Z` is interpreted as **local** — here
UTC−4, i.e. ~4 hours in the future, which also returns 0 unconditionally. Both were live this round.
**Fix:** keep the `Z`, and always run a positive control alongside — this round used
`-newermt '2026-08-19'` → 286 files and `-newermt '2026-08-20 06:00'` → 24, which is what makes the
0 meaningful.

**P2 — `$QA/counter.rb` is cumulative and cannot be reset by the driver.** It writes `"0"` only at
startup and thereafter overwrites the file with its own running in-process total, so a driver
zeroing the file between probes reads garbage. I hit this and got a nonsensical sequence
(10, 11, 12, 18, 24, 30 — construction-only appearing to exceed a full run). **Read deltas, or
restart the listener per probe.** Better: the path-logging variant I built (`$QA/pathcount.rb`)
answers the question the counter was reached for — *which* endpoint each connection hit — and turns
"6 connections vs 4 rendered attempts" from a suspicion into an attribution. **It now ships in
`qa-sandbox.sh` alongside `counter.rb`** — the generated file was verified functionally, not merely
parsed: it logged `1 GET /api/chat` / `2 GET /api/ps` against a live probe.

**P3 — `pgrep`/`pkill -f` self-match, a fourth and fifth time.** `pkill -f 'counter.rb'` matched the
agent shell's own command line and **killed the command issuing it** (exit 144), losing a heredoc
mid-write. CLAUDE.md and `method.md` both record this for `parallel_rspec` and `pre-commit`; it bit
again here. Use `ps -eo pid,args | grep '[c]ounter\.rb' | awk '{print $1}'` and kill by pid.

**P4 — a driver-side near-miss worth recording.** I sent `/mode` by raw `send-keys`, bypassing
`drive.sh`'s approval guard, without checking `lain://approval` first. That first probe was
invalid and I discarded it. Later, `drive.sh` **correctly refused** to send while an approval was
parked (`REFUSING to send: an approval is pending -- answer it first`) — the guard works and is
worth using even for one-off sends. `method.md`'s rule should be read as covering *hand-typed*
sends, not only `drive.sh` ones.

**P5 — a scenario step needs a longer tool timeout than a default agent shell gives.**
`drive.sh` calls that span a model turn routinely exceed 2 minutes; one was killed mid-wait. Not a
lain issue, but a driver running these needs an explicit timeout on the wrapping call.

## What was not reached, and why

- **`rails-blog` is OWED, not dropped.** It is `expensive` and gets its own driver context by
  README's rule; it was never in this round's budget. Run it as `/manual-qa rails-blog`. **This is
  the fourth consecutive round it has not been driven** — rounds 4, 5, 6 and now 7 — which per
  README's own note is itself a finding about the plan, even though the separate-context rule now
  makes it schedulable rather than starved.
- **`bowling-ruby` was DROPPED — a decision, named here.** The `rust-cli` crate served as this
  round's subject and carried the `cockpit-surfaces` piggyback; driving a second authoring subject
  would have bought mostly the same surfaces at 1–3 sessions' cost. **The consequence is real and
  should not be glossed:** the authoring loop (`/create-plan`, `/execute-plan`, `/critique`) and the
  driver-owned oracles in `planning/qa/oracles/bowling.rb` got **no coverage this round**.
- **`failure-injection` §4, §5, §6, §7, §10, §11b, §11c** not driven. §7's ceiling was observed
  *incidentally* and passed (it fired, reported in one line, session survived), but was not driven
  with its own trigger.
- **The supervisor door of §3** (a supervised restart whose replay reads a damaged journal) was not
  reached. Recording it as **not reached**, per the scenario's own instruction — it is the door that
  had no rescue before this chunk, so an untested pass there is exactly the shape of the defect.
- **`cockpit-surfaces` §4 (review flow), §4b (notes on a survey), §5's `--no-nvim` comparison, and
  §6's UTF-8 priming probe** not driven. The `--no-nvim` gap is the one worth scheduling: README
  lists the plain non-cockpit path as a known gap and §5 is the only thing that forces it.
- **F26's concurrency was measured but not stressed.** The clean reading is real, but my inspection
  pauses serialised the workload. A future §12 run should drive several tool-result turns
  back-to-back with no pause, keeping the model resident throughout, before concluding the race is
  gone.

## Folded back into the method

Per the skill's phase 6, the following were written into `planning/qa/method.md` this round:
the **P1** negative-check trap (bfs + the UTC/local spelling, with the positive-control
requirement), the **P2** `counter.rb` cumulative-count trap and the `pathcount.rb` recipe that
supersedes it for attribution questions, the **P3** `pkill -f` self-match recurrence, and **P4**'s
clarification that the "never type while an approval is parked" rule governs hand-typed sends.
**`qa-sandbox.sh` additionally now generates `$QA/pathcount.rb`**, so the attribution instrument is
available to the next round rather than needing to be rebuilt by hand.
