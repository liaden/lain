# Scenario: failure injection and record integrity

**Why this one exists:** these probes are **deterministic and fast** — every expected outcome is a
constant, a refusal string or an arithmetic fact rather than something a model decides — which makes
them the cheapest real signal in the whole QA suite. Round 4 ran the lot in a few minutes and all
of it passed. They are held apart from the subject scenarios so a broken machine cannot contaminate
a main pass — and so they can be run alone, as a regression gate, after any chunk touching the
journal, the store, the transport or the tools.

**Cost:** minutes. **Needs:** a project with at least one recorded multi-turn session.

**Three halves, and it is worth knowing which you are in.**

- **§§1–3 and §11 need nothing running** — a journal on disk, a shell, and `lain` on `PATH`. No
  cockpit, no nvim, no endpoint.
- **§§4–6 drive the transport at a broken endpoint.** Requests are attempted; none of them reaches a
  model, so there is no generation to wait for and nothing the model can decide.
- **§§7–10 need a live session** with a real model behind it: the iteration ceiling, the tool
  bounds, the windowed-read contract and the summarizer's ceilings. The *constants and refusal
  texts* in those sections are still deterministic and readable through `/ruby` with **no model call
  at all** — do those reads first, because if a ceiling is already wrong the turns are wasted.

**Everything deterministic that the 2026-08-18 cost-axis chunk added lands here on purpose.** A check
that only runs inside an expensive scenario mostly does not run, and bounds, refusal wording and
ceilings are exactly the kind of thing that regresses quietly under a green suite.

---

## 1 — Record integrity, at rest

Every journal line parses; no `journal_error`; occupancy reconciles against `input_tokens` and the
served window; compaction decisions carry their denominator.

```bash
ruby -rjson -e 'bad=0; n=0; ARGF.each_line{|l| n+=1; (JSON.parse(l) rescue (bad+=1))}; puts "#{n} lines, #{bad} unparseable"' "$JOURNAL"
```

Remember token counts are nested: `turn_usage.usage.input_tokens`, not top-level.

## 2 — A torn `turn` record

**Tear a `turn` record specifically.** Skipping unparseable lines is `Journal.records`' documented
contract (the fd can be shared with Rust tracing spans), so tearing an arbitrary line proves nothing
— it is invisible by design. Halve an actual `turn` record and the loss becomes legible.

```bash
ruby -rjson -e '
src, dst = ARGV
lines = File.readlines(src)
idx = lines.each_index.find { |i| (JSON.parse(lines[i])["type"] rescue nil) == "turn" && i > 10 }
lines[idx] = lines[idx][0, lines[idx].bytesize / 2] + "\n"
File.write(dst, lines.join)' "$GOOD" "$TORN"
lain sessions
```

Expected: **one fewer turn, under the SAME head digest, plus `1 line unparsed`.** Then fork the
damaged session at that advertised head:

    cannot fork <session>: turn record 3 (user) recorded as blake3:6dbf0c8b… re-commits to
    blake3:6aaa90f1…; its content no longer matches its content address

Exit 1, no backtrace, naming the record index, its role, and **both** digests. Corruption is meant
to be **invisible at rest but unforgeable on use** — check both halves, not just the first.

## 3 — A dangling causal edge

Remove a record that a later record depends on, then try both entry points.

**Which key to break depends on what ran.** A session of plain turns links via `parent`;
`causal_parents` appears only once a spawn or a message has landed. Round 4's journals had **no**
`causal_parents` at all, so a probe written only against that key silently tests nothing — check
first:

```bash
ruby -rjson -e 'k=Hash.new(0); ARGF.each_line{|l| r=JSON.parse(l) rescue next; k["parent"]+=1 if r["parent"]; k["causal_parents"]+=1 if r["causal_parents"]}; p k' "$JOURNAL"
```

Then remove a turn a later turn names, and expect **the same clean refusal from both**:

```
cannot fork <session>: turn record 0 (assistant) recorded as blake3:53f6b032… re-commits to blake3:465e9071…
cannot resume <session>: turn record 0 (assistant) recorded as blake3:53f6b032… re-commits to blake3:465e9071…
```

Both exit 1. An earlier follow-up recorded this as "fixed for `--fork` only"; that is now stale in
the good direction — `--resume` is equally clean and carries its own `cannot resume` prefix.

A bad digest **prefix** must also refuse by name: `no turn matching "<prefix>" recorded in <session>`.

## 4 — A severed transport

**Use a severing proxy, not a killed server.** Put a small TCP forwarder in front of the model
endpoint and have it `SO_LINGER 0`-close (a hard RST) after N bytes of response, then point
`--api-base` at it. Deterministic where killing a service is a timing race, and it leaves the
operator's model server untouched — which matters on a shared machine.

`lain bench record <taskfile> -n 1 --out <dir>` is the non-interactive vehicle. **Always take a
control run against the real endpoint in the same session**, because the whole finding is the gap
between them (this is how a 1.9s control vs >400s hang was found; a bare "kill the server" would
almost certainly not have).

## 5 — An unreachable endpoint

**`--api-base` probes are TURN-level, not launch-level** — judging by launch records is a false
pass. The launch-time window probe falls back cleanly and the chat starts normally at `you>`; the
failure is on the first turn. `--prompt '<text>'` is the cheap vehicle, in a window with
`remain-on-exit on`.

- An unroutable address (`http://10.255.255.1:11434`): expect a **fast, named** failure — ~26s at
  the default 5s connect timeout, ~8s under `LAIN_CONNECT_TIMEOUT=1` — with retries rendered live.
  Not the ~20 minutes of silence this used to cost.
- A scheme-less typo (`localhost:11434`), the mistake a human actually makes: must refuse at
  construction naming `--api-base`, **not** crash with a Faraday backtrace. It is a *valid* URI —
  scheme `localhost`, opaque `11434` — so a `URI::InvalidURIError` guard does not catch it.

Count the real attempts with a counting TCP listener (`method.md`), then check the rendered ordinals
**against** that count: since T18 the give-up line names the attempt that failed rather than the
retry budget, so `1, 2, 3, 3` for four attempts is the regression and `1, 2, 3, 4` is the pass. See
`session-and-window.md` §2 for the expected lines.

## 6 — Ctrl-C during a parked `ask_human`

Known uncovered: signals are routed to a null handler outside an ordinary turn's ask, so either the
process dies outright or the ask stays parked. Both are the documented gap; **the actual check is
that the session journal still parses afterwards.**

## 7 — The iteration ceiling

Drive past the loop ceiling and confirm what happens **after** it:

```bash
ruby -rjson -e 'n=0; ARGF.each_line{|l| r=JSON.parse(l) rescue next; n+=1 if r["type"]=="turn_usage"}; puts n' "$JOURNAL"
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; puts "#{r["ts"]} #{r["type"]}" if r["type"]=="run_interrupted"}' "$JOURNAL"
```

Since T14 the ceiling bounds **one ask**, so this is now three checks and not one, and the third is
the one that was actually fatal:

1. **A long single ask still stops.** 25 model calls inside one prompt raise `Budget::Exceeded`.
2. **The stop is SAID, in one line:** `error: loop ran 25 iterations, ceiling is 25`. Round 4's
   failure rendered *nothing at all* while the HUD kept reading `idle 0s`.
3. **The next prompt is answered normally**, on a fresh count. A per-session counter is the
   regression: it accepted every later prompt, committed it, immediately `run_interrupted` it, and
   answered nothing. `turn_usage` climbing past 25 across several prompts *while answers keep
   arriving* is the pass, not the failure — do not read a high count as a spent session.

**A refusal is not a crash**, and this is measurable rather than aesthetic. `Budget::Exceeded`
escaping its `Async::Task` used to print `Task may have ended with unhandled exception` plus 27
frames *before* the correct one-line message. T16 carries the refusal out as a value instead:
measured **2849 bytes of stderr and one warning, down to 226 bytes and none** — the same output a
clean ask produces. So size the stderr rather than eyeballing it:

```bash
lain chat ... --prompt '<the ask that exhausts the ceiling>' 2>err.txt; wc -c err.txt; command grep -c "in '" err.txt
```

Zero backtrace frames, and a byte count in the low hundreds. A kilobyte of stderr in front of a
correct message is the old shape.

## 8 — Tool bounds, in both shapes

**The house rule is never lose bytes silently, and it has two shapes on a stated boundary.**
Enumerations cap and disclose in band; whole artifacts refuse and name a narrower action. Both are
deterministic — the ceilings are constants, the decision is arithmetic — so the *text* of every
refusal can be checked with **no model call at all** through `/ruby`, and only the delivery needs a
turn.

**A tripped bound writes no journal record** (`method.md`): its only trace is a `tool_result` block
with `"is_error": true`, so use that reduction, not a record-type grep.

The live ceilings, read from the process rather than the source:

```bash
$QA/drive.sh '/ruby [Lain::Tools::ReadFile::WHOLE_BOUND.limit, Lain::Tools::ReadFile::WINDOW_BOUND.limit,
                     Lain::Tools::Bash::OUTPUT_BOUND.limit, Lain::Tools::ListFiles::BOUND.limit]' 6 30 >/dev/null
$QA/peek.sh 6
```

Expected `[262144, 1048576, 131072, 500]` — 256 KiB for a whole read, 1 MiB through a window, 128 KiB
of command output, 500 rows for a listing. `memory_read`/`memory_write` share the 256 KiB artifact
ceiling; `glob` shares 500; `code_outline`, `file_symbols` (definitions) and `test_pattern` cap at
200; `file_symbols` references at 500; `web_search` at 20.

### The refusing shape

Seed the sandbox and drive one turn per probe — `bash` is gated, so these also exercise the gate:

```bash
cd $QA/project
# 60-byte lines, so both files are line-structured (a one-long-line file takes a DIFFERENT
# refusal path -- see below) and their sizes are exactly the ones quoted in the messages.
ruby -e 'File.open("big.txt","w"){ |f| 50_000.times { f.write("x"*59 + "\n") } }'   # 3,000,000 bytes
ruby -e 'File.open("mid.rb","w"){  |f|  5_000.times { f.write("# " + "x"*57 + "\n") } }'   # 300,000 bytes
```

Verified 2026-08-18 against the built library — these are the exact strings, and **the size, the
ceiling and at least one narrower action must all be present**:

```
./big.txt is 3000000 bytes, over the ceiling of 262144 -- instead, read part of it with read_file's offset and limit, or outline it with code_outline, file_symbols or ast_search, or grep it for the lines you actually need

./mid.rb is 300000 bytes, over the ceiling of 262144 -- instead, read it with read_file's offset and limit (a window covering the whole file counts as a complete read, so edit_file still accepts it), or outline it with code_outline, file_symbols or ast_search, or grep it for the lines you actually need

the command's output (exit status: 1) is 200000 bytes, over the ceiling of 131072 -- instead, re-run it with the output narrowed through head, tail or grep, or redirect it to a file and read one window of that with read_file
```

**The difference between those first two is the whole design and is worth reading twice.** The
smaller file is offered a *full-cover window* — advice that leads somewhere — because a window
covering it would itself be admitted. The 3 MB one is not, because that advice would be refused in
turn, and a refusal that names a move which is itself refused is a loop. **Both files offered the
same advice is the finding**, whichever way round.

Five more things to check, because each is a way the shape can be right and the behaviour wrong:

- **No payload bytes in the refusal.** The message carries a size, a ceiling and prose. A preview
  "to be helpful" is truncation wearing a refusal's clothes; a single line of `big.txt` in the
  transcript fails this check.
- **The exit status survives the `bash` refusal.** `exit status: 1` is inside the message above.
  Losing it turns a refusal into a second failure the model cannot diagnose. Ask for a command that
  prints past the ceiling *and* fails — `head -c 200000 /dev/zero | tr '\0' x; exit 1` is enough,
  and being gated it also puts one more approval through the surface.
- **Both `bash` arms refuse byte-identically.** The bound sits in the shared renderer, so the Ruby
  arm and the `lain-core` daemon arm must produce the same string; if the round has a core build
  (`rake core:build`), drive one oversized command through each.
- **The decision precedes the read.** An oversized file must be refused from its size, not read and
  then measured. Watch for a multi-second pause or a memory spike before the refusal — either means
  the file was materialised first, which is the memory half of the claim failing quietly.
- **One enormous line is its own case, and worth one extra seed.** A minified bundle or one-line
  JSON (`ruby -e 'File.write("one.json", "[" + "0,"*600_000 + "0]")'`) cannot be narrowed by
  `offset`/`limit` at all, since both count lines. Its refusal must say so and point at a byte range
  — the distinctive fragment is `one line alone is over the ceiling` — rather than advising a window
  that cannot help. Advice a model cannot act on is the loop this whole shape exists to break.

### The disclosing shape

```bash
mkdir -p "$QA/project/many"
ruby -e 'Dir.chdir(ARGV[0]) { 1_200.times { |i| File.write("f#{i}.txt", "") } }' "$QA/project/many"
```

Ask for a listing of it (`list_files` on `many/`, or `glob 'many/*'`). The result must be 500 rows **plus one trailer naming both numbers**:

    ... capped at 500 of 1200 paths

Checks: the true count is present (`500` alone tells the model nothing about how much it is
missing); the cap is applied **after** the deterministic sort, so two runs return the same 500 rows
in the same order; and a *small* directory gains no trailer at all — a notice on an uncapped result
is as much a defect as a missing one. `grep` and `ast_search` keep their older
`... capped at 200 matches` trailer, deliberately, and must **not** have been unified into this
wording: that string is pinned by the secret-filter specs.

## 9 — The windowed read, and which refusal `edit_file` gives

`read_file` takes `offset` (1-based line) and `limit` (line count), and `edit_file` now distinguishes
three reasons for saying no. **This is the pair that could deadlock**, so drive it as a sequence, in
this order:

1. `read_file` on `mid.rb` with **no** window → refused for size (above).
2. `read_file offset: 1, limit: 50` → returns lines 1–50, and *only* those.
3. `edit_file` on `mid.rb` → **must refuse, naming the window**:

       only a window of path was read this session -- an offset/limit read showed you part of the
       file, so editing it would clobber lines you never saw. Read it again with no offset and no
       limit, or with a window covering the whole file, then edit

4. `read_file offset: 1, limit: <lines beyond the end>` — a window covering the whole file → the
   read is recorded as **complete**.
5. `edit_file` on `mid.rb` again → **must be permitted**.

**Step 5 is the deadlock guard and the reason this sequence exists.** If a full-cover window did not
complete the read set, every file over 256 KiB would be permanently uneditable and the only escape
would be `write_file`, which overwrites whole the very file too large to read. Confirm the read-set
state directly rather than inferring it from the edit:

```bash
$QA/drive.sh '/ruby [session.read?(File.expand_path("mid.rb")), session.partially_read?(File.expand_path("mid.rb"))]' 6 30 >/dev/null
$QA/peek.sh 6
```

`[false, true]` after step 2; `[true, false]` after step 4.

**The message the old behaviour gave is the thing to watch for**: `path was never read this session`
after a windowed read. That is not merely wrong, it is a loop generator — it sends the model back to
read the file, get the same window, and be refused identically. The third refusal (a masked read,
from the secret boundary) is a *different* sentence and says the situation is permanent for the
session; the three must not collapse into one wording.

## 10 — What the summarizer will pay a model to read

Two independent gates, and the point of the check is that they stay independent:

```bash
$QA/drive.sh '/ruby [Lain::Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES,
                     Lain::Oracle::RoutedSummarizer::INPUT_BOUND.limit]' 6 30 >/dev/null
$QA/peek.sh 6
```

Expected `[4096, 262144]` — a **lower** bound (too small to be worth a model call) and an **upper**
one (too large for a model to serve). Collapsing them into one knob is the regression: they answer
different questions, and merging them silently changes which results get a free-tier summary.

Reaching the upper bound needs a tool that legitimately returns megabytes; `web_fetch` is the one
left, capping at 5 MiB, since T5 and T6 bounded the rest of the shipped floor. Drive one large fetch
and check:

- the oversized result is **declined before any tier is asked** — no `oracle_answer` for it, and the
  project's own declared summarizers are not consulted either;
- the decline is counted as a **miss**, not a hit. A refusal string stored as a summary would report
  as a summary that landed, and `summary_hits`/`summary_misses` on `compaction_decision` is the only
  read on whether the fires work at all;
- the result then renders as an **elision line** carrying its type, content address and byte count.
  Silence there — a block that simply vanishes — is the failure.

## 11 — `lain up` when the chat pane dies instantly

The 2026-08-06 report was "`lain up` starts and immediately crashes". What actually happened: `chat`
refused a missing API key, printed a clear line, exited 1 — and being the session's only pane, took
the **whole tmux server** down with it, so the operator saw a terminal blink once and return to a
shell. Drive it deliberately:

```bash
tmux -L lain-qa kill-server 2>/dev/null
lain up "$QA/project" -- --provider anthropic --model claude-opus-5   # no ANTHROPIC_API_KEY in the sandbox
tmux -L lain-qa has-session -t lain-qa; echo "session=$?"
tmux -L lain-qa list-panes -t lain-qa:chat -F '#{pane_dead} #{pane_dead_status}'
tmux -L lain-qa capture-pane -p -t lain-qa:chat | tail -6
```

Expected: **the server is still up**, the chat pane is `pane_dead 1`, and its refusal is still
readable in the pane. `remain-on-exit failed` — not `on` — is what makes this cost nothing in the
ordinary case:

```bash
tmux -L lain-qa show-window-options -t lain-qa:chat remain-on-exit   # -> remain-on-exit failed
```

**A clean exit must still close the pane.** If a normal `/quit` leaves a dead pane behind, the option
has been widened to `on` and the fix has overshot.

**The stated residual, and it may be the original case.** tmux prints its own dead-pane banner at the
top of the held pane, which scrolls the content up by exactly one line — so a refusal that was **a
single line** is still lost, and the pane looks empty. The two-plus-line refusals (a missing key
prints several) survive. So: check retention with a multi-line refusal, and record separately
whether a one-liner is readable. If it is not, that is the known residual and not a new finding —
but if a *multi-line* refusal is also gone, the fix has regressed.

**On an older tmux this whole section is a no-op, not a failure.** `remain-on-exit failed` needs
tmux ≥ 3.2 and the option is set best-effort on purpose: a diagnostic nicety must not take `lain up`
down. Record the tmux version beside the result, or the reading cannot be interpreted.
