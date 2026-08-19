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

### Every door, not just `--fork`

**A damaged journal must refuse by name from all four doors, and one of them used to die with a raw
backtrace.** The rebuild has three production constructors — `--fork` and `--resume` share one —
and they used to rescue independently, so which exception a damaged journal produced was an accident
of which record set the damage landed in. Drive the same damaged file through each:

| door | how | expected |
|---|---|---|
| `--fork` | `lain chat --fork SESSION@DIGEST` | `cannot fork <session>: …` |
| `--resume` | `lain chat --resume SESSION` | `cannot resume <session>: …` |
| the bench | `lain bench variance <the damaged file>` | `<path>: <the same refusal>` |
| the supervisor | a supervised restart whose replay reads it | `cannot restart "<role>" from its session record: …` |

All four exit 1 with **no backtrace frames** — `Bench::Session::Corrupt` is a `Lain::Error`, so the
exe maps it onto Thor's contract. **The supervisor door is the one worth the effort**: it had no
rescue at all before this chunk, so a damaged journal took a supervised restart down with a raw
trace. If it is hard to reach in the sandbox, say so in the record rather than marking it passed —
an untested door here is exactly the shape of the defect.

### Damage the flat records too, not only the turns

The probes above all break a `turn`. A `message` or `child_turn` record has its **own** index space
and its own sentence, and the two must not be conflated:

    turn record 26 (user) cites a causal parent this fold never landed: …
    message record 4 (<label>) cites a causal parent this replay never landed: …

Both land as `Bench::Session::Corrupt`, which is the single refusal currency the callers above
depend on. Two shapes are worth breaking separately, because they escaped by different routes and
only one was ever a *dangling* edge:

- **dangling** — a `causal_parents` digest no record in the file carries;
- **malformed** — a `null` inside `causal_parents`, or a real digest beside a `null`. These are not
  the same case: a `null` used to be compacted away and the record then called reachable, so the
  Store refused a put nothing had pre-checked and `Store::MissingObject` escaped as itself. A bare
  `ArgumentError` from sorting a list containing `null` is the other old shape. **Neither is an
  acceptable answer now** — anything but `Corrupt` from any of the four doors is the finding.

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
- **One enormous line is its own case, and worth TWO extra seeds — the probe and its control.** The
  boundary is `WINDOW_BOUND` (1 MiB), not `WHOLE_BOUND`, and getting it wrong in either direction is
  a real defect, so seed both sides:

      ruby -e 'File.write("one.json", "[" + "0,"*600_000 + "0]")'   # 1,200,003 bytes -- OVER 1 MiB
      ruby -e 'File.write("mid.json", "[" + "0,"*150_000 + "0]")'   #   300,003 bytes -- under 1 MiB

  **`one.json` is the probe.** A newline-free file over 1 MiB cannot be narrowed by `offset`/`limit`
  at all, since both count lines, so every window is refused in turn. Its refusal must say so and
  point at a byte range — the distinctive fragment is `one line alone is over the ceiling`, and it
  names a `head -c 100000` sized to sit under `bash`'s own 128 KiB ceiling, so following the advice
  steps the model *down* a ceiling rather than into another refusal.

  **`mid.json` is the control, and it is the guard against over-reach.** It is over `WHOLE_BOUND`
  and newline-free, but *under* `WINDOW_BOUND` — so a window covering it would itself be admitted,
  and the correct advice is still the full-cover one:

      read it with read_file's offset and limit (a window covering the whole file counts as a
      complete read, so edit_file still accepts it)

  If `mid.json` gets the byte-range advice too, the fix over-reached and every newline-free file
  between 256 KiB and 1 MiB has quietly lost its route back to being editable. **Both files offered
  the same advice is the finding, whichever way round** — the same rule as `big.txt`/`mid.rb` above,
  one ceiling up.

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

## 11 — `lain up` refuses before it builds, and reports a corpse it cannot attach to

The 2026-08-06 report was "`lain up` starts and immediately crashes". What actually happened: `chat`
refused a missing API key, printed a clear line, exited 1 — and being the session's only pane, took
the **whole tmux server** down with it, so the operator saw a terminal blink once and return to a
shell. That is now covered on **two** paths, and they are different mechanisms with different
evidence, so drive them separately and do not conflate a pass on one with a pass on the other.

### 11a — the pre-flight refusal: no pane, no session, no tmux at all

`Up#create_session` runs `ChatPreflight` **first**, before `new-session`. It spawns
`<exe> chat <args>` with `LAIN_PREFLIGHT=1`, which constructs everything a chat needs and exits
without reading stdin; a nonzero exit becomes `Up::ChatRefused`, which is a `Lain::Error` and so
reaches Thor's contract — message on stderr, nonzero exit, **no backtrace**. The reasoning is worth
knowing, because it is what the check is really for: a chat this session could not run is a session
that should never have been created, and a refusal raised *after* `new-session` would strand an
empty session for the next `lain up` to reattach to.

```bash
tmux -L lain-qa kill-server 2>/dev/null
lain up "$QA/project" -- --provider anthropic --model claude-opus-5   # no ANTHROPIC_API_KEY in the sandbox
echo "exit=$?"
tmux -L lain-qa has-session -t lain-qa; echo "has-session=$?"
```

Expected: the refusal on the **operator's own terminal**, nonzero exit, and `has-session` failing
because **no session was created**. `list-panes` and `capture-pane` are the wrong assertions here —
there is nothing to capture, and a driver reaching for them will read "no server running" as the
defect rather than as the pass.

The same shape covers the other construction refusals, which is the point of doing it here rather
than only through `lain chat` in `session-and-window.md` §1 — a bad `--num-ctx` or an unknown
`--compact-strategy` now costs no pane either:

```bash
lain up "$QA/project" -- --num-ctx 0
lain up "$QA/project" -- --compact-strategy nonesuch
```

**The caveat that decides whether this section tests anything.** `ChatPreflight#call` rescues
`Errno::ENOENT` and `Mixlib::ShellOut::CommandTimeout` and degrades to a **warning**, opening the
cockpit unchecked:

    could not pre-flight the chat arguments (<reason>) -- opening the cockpit unchecked,
    so a refusal will surface in the chat pane instead

That is correct behaviour — a pre-flight that cannot run must not take `lain up` down — but it
silently restores the pre-chunk world, and the sandbox is exactly where it fires: the pre-flight
spawns `$PROGRAM_NAME`, so a shim that is not on `PATH` under `cwd`, or a cold bootsnap cache
pushing the child past `TIMEOUT` (15s, plus Mixlib's flat ~3.1s escalation), lands here. **Read the
warning lines before believing a §11a result**, and if that sentence appears, this section measured
the corpse path below and not the pre-flight one.

### 11b — the corpse report: a pane that dies faster than anyone can read it

`ChatPreflight` can only cover what `chat` will *refuse*. A pane that fails to exec, whose login
shell exits, or which crashes on the way up is discovered only by running it — so `PaneCorpse`
reads the pane back `GRACE = 0.15`s after it was handed its command and, if it is dead, raises
`Up::ChatDied` instead of attaching. The session **does** survive here, deliberately, and the
message says so:

    the chat pane exited <status> moments after `lain up` started it, so this did not attach.
    Session 'lain-qa' survives with the dead pane in it: another `lain up` attaches to it as it
    stands, `tmux kill-session -t lain-qa` clears it for a fresh start. What <pane> held:

    <the pane's scrollback>

Check three things, and the third is the one that replaced the old residual:

1. **`lain up` did not attach**, and said why on the operator's terminal — nonzero exit, no backtrace.
2. **The session is still there** with the dead pane in it, exactly as the sentence promises. An
   operator told "nothing to attach to" and then dropped into that pane by re-running `lain up` one
   command later has been misled by us, not by tmux.
3. **The refusal's first line survives.** `PaneCorpse#held` reads `capture-pane -p -S -` —
   *scrollback*, not the visible region — precisely because tmux draws its own `Pane is dead
   (status N, ...)` banner into the pane and scrolls the content up by one line. A plain
   `capture-pane -p` comes back without that first line; `-S -` still has it.

**That retires the old "the banner eats the FIRST line, always" table**, which recorded a residual on
a path that no longer reaches the operator. It is recorded here as retired rather than deleted
because the underlying tmux behaviour has not changed — only who reads around it. If a future
`capture-pane` in this section loses the causal first line again, the `-S -` has been dropped.

**The `-- --nosuchflag` probe is retired with it, and for a different reason: it no longer reaches a
pane at all.** Thor's unknown-flag error is a nonzero exit from `lain chat`, so §11a's pre-flight
catches it first and it never becomes a corpse. Multi-line retention is now 11b's business instead,
and it is `PaneCorpse#held` that bounds it: `MAX_LINES = 40` and `MAX_BYTES = 4000`, with runs of
blank rows squeezed to one so that tmux's grid padding does not spend the line budget (measured:
twenty blank rows between the cause and the banner). So drive a pane-only failure and check
the *shape* of what comes back.

**Getting into 11b at all takes care, because 11a now catches almost everything.** Anything `chat`
refuses — a bad `--api-base`, a missing key, an unknown strategy — is a nonzero exit from the
pre-flight child and never becomes a corpse. What reaches 11b is a failure the pre-flight child
does not share, and the bench already has one: launching by a **relative** path. `ChatPreflight`
expands a `$PROGRAM_NAME` containing a separator against the launch cwd, so the check passes, while
`PaneCommand` interpolates it raw and the pane exits **127** the moment its cwd differs. That
asymmetry is deliberate on the pre-flight's side and is exactly the corpse case:

```bash
cd "$QA" && bundle exec ./exe/lain up "$QA/project"    # relative $PROGRAM_NAME; pre-flight passes, pane 127s
```

(`method.md` gives the same mechanism as the reason to launch by absolute path through a shim. Here
it is being used deliberately, as the cheapest way to make a pane die without making `chat` refuse.)

The cause must be present and readable, blank-line padding must not have crowded it out, and a
program's own paragraph break should survive as a single blank line. Losing the whole body — the
report arriving with `(nothing -- it died without writing a line)` against a pane that plainly wrote
one — is the failure; that sentence is reserved for a pane that really said nothing, and
`(nothing -- tmux would not hand back the pane's screen)` for a capture that failed.

A pane that dies *slower* than `GRACE` is simply not converted into a message; `remain-on-exit
failed` still holds the corpse on screen where it can be read, exactly as before. That is a small
bound on purpose, not a compromise — only a healthy launch pays for it, and only for the remainder.

### 11c — `remain-on-exit`, which underpins both

```bash
tmux -L lain-qa show-window-options -t lain-qa:chat remain-on-exit   # -> remain-on-exit failed
```

`failed` — not `on` — is what makes holding a corpse cost nothing in the ordinary case. **A clean
exit must still close the pane.** If a normal `/quit` leaves a dead pane behind, the option has been
widened to `on` and the fix has overshot.

**On an older tmux this whole section degrades rather than fails.** `remain-on-exit failed` needs
tmux ≥ 3.2 and the option is set best-effort on purpose: a diagnostic nicety must not take `lain up`
down. `PaneCorpse` is best-effort on the same rule — a tmux that will not answer means the check
cannot tell, and it stays quiet rather than guessing. Record the tmux version beside the result, or
neither reading can be interpreted.

## 12 — Concurrency against a one-slot server

**Why this section exists: `bench.md` records `n_slots = 1` as a precondition for "the whole class of
contention defects" and until round 6 nothing drove it.** F10 (round 3) and F26 (round 6) are the
same mechanism and were both found by accident, a round apart, because the class had a precondition
and no probe. This is that probe.

**The mechanism to look for.** Lain issues more than one model call per turn — the turn's own
request, and an **oracle** consulted about a tool result — and the second is dispatched within tens
of milliseconds of the first. On a server with one slot they serialize, the loser blocks *at the
server* with **zero bytes**, and if that wait exceeds `stream_stall_timeout` (30s) the turn is torn
down with `stalled stream: no bytes for N.Ns` on a completely healthy endpoint.

**The oracle's call is not journaled**, so this is invisible from the journal alone: you will see one
`request_sent`, then `run_interrupted`, and nothing explaining the gap. **Do not attempt this probe
without a proxy** — without one there is no way to distinguish contention from a slow model, and a
driver will reasonably file the wrong cause.

### The instrument

A **logging pass-through proxy** — forward to the real endpoint, and record start / first-byte / end
per upstream request. `$QA/proxy.rb` ships with the sandbox. Point `--api-base` at it:

```bash
ruby "$QA/proxy.rb" "$QA/records/proxy.log" &     # listens on 127.0.0.1:21434
lain up "$QA/project" -- --provider ollama --model qwen3-coder:30b --api-base http://127.0.0.1:21434
```

Then drive a turn whose tool result is large enough to summon the oracle. A failing compile is
reliable (`cargo build 2>&1 | head -40` against a crate that does not compile); so is any `bash`
call returning tens of KB.

### What to read, and what each reading means

```bash
command grep -E 'START|FIRST-BYTE' "$QA/records/proxy.log"
```

- **Two `START`s within ~50ms** is the dispatch shape. One is journaled, one is not.
- **Count the proxy's `/api/chat` requests against the journal's `request_sent`.** A surplus is the
  unjournaled internal call; round 6 measured **8 against 7**. Equality means either no oracle fired
  this turn or the call is now journaled — check which before recording it as a fix.
- **`FIRST-BYTE` minus `START` for the journaled request is the starvation.** Round 6 measured
  **35.8s** and **64.8s** on a healthy resident model. Anything over `stream_stall_timeout` will have
  torn the turn down; correlate with `run_interrupted` in the journal.

### Two controls, because both innocent explanations are plausible

Neither is optional — a starvation reading without them is a guess, and round 6 nearly filed the
wrong cause twice.

1. **It is not prefill.** Time an *uncached* prompt of comparable size end to end. Generate it
   freshly so no prefix cache can cover it, and **pass no options the resident runner disagrees
   with** (see `method.md` on `num_batch` manufacturing a reload). Round 6: 36,622 bytes, **9.3s**.
2. **It is not the stall clock arming before the first byte.** `FaradayHandlers`' class doc says the
   clock arms on the first tick and not before, so a slow *first* byte must be exempt. Drive it: a
   proxy variant that holds the first response byte for 40s must produce **no stall** and a normal
   answer. Round 6 measured 42.6s wall and a clean reply — the documented split holds, which is what
   proves the tear-down is queued/mid-stream silence rather than a timing bug.

**A clean run here is a real result and worth recording as one** — it means either the concurrency
is gone or the server has more than one slot. Record `-np` from the runner's argv beside the
reading, because this whole section is void on a multi-slot box.
