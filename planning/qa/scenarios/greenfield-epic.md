# Scenario: a greenfield epic on the cloud arm

**Round 26 is the re-check** for the round 25 fixes stated in the judge deny and "did not look" notes (k25-1, §6), the stall-timeout check (k25-3, §7) and the launch width notice (retired cloud variable).

**Why this one exists:** on 2026-10-08 the user started `~/dev/frugirl` with `lain up` on
`--provider ollama-cloud --model glm-5.3` and ran `/research-epic` in an empty directory. The run
never reached `research.md`. A `grep` over `~/dev` (171.6 GB) froze the whole process until it was
killed, both researcher subagents died at their iteration ceiling and handed back nothing, the
agent read lain's own source because the skill named Ruby internals it cannot call, and the
cockpit misreported context, hid approvals that then auto-denied, and swallowed Shift+Enter.
Every one of those lived in a seam with specs on both sides. This scenario is the journey in
order, with each trial failure written down as what wrong looks like.

On 2026-10-09 the user reran it. The interview, the researchers and the related-directory config
worked, but `research.md` was never written: 3 runs ended `stalled_stream`, 2 of them exactly where
the model began the `epic_write` call that carries the whole document, because ollama sends a tool
call's arguments whole after a silence that grows with their size. The user also could not tell the
agent anything mid-run, could not see their own prompts or answers in the transcript or what was
written, and was left looking at an answered question buffer. The checks for those fixes are marked
*2026-10-09 trial fixes* below.

**What it exercises:** `lain up <dir> --create`, the cloud arm's window and width, the epic skills
and the `epic_write`, `epic_submit` and `epic_graph` tools, the walk behind `grep`, `glob`,
`list_files` and `ast_search` (ignore files, the entry limit, running off the reactor), the
researcher role and its ceiling, the approval surfaces (deadline, deny reason, held notice), the
HUD's in-flight segment, the stall limit on a long tool call, the transcript's echoes and its
files-written line, notes typed mid-run, `lain://epic` and `lain epic show`, and the cockpit's nvim,
tmux and transcript behavior under a real user config.

**Round 26 re-checks:** k25-1 fixed (a judge deny is stamped `HH:MM:SS the judge denied ...` and the child is told why), k25-3 fixed, k25-4 not fixed in round 26 and fixed since (T11: `x` on a closed fold of `lain://question` refuses instead of deleting the range), B23-1 fixed.

**Cost:** spends real cloud quota. Budget about 150 completions for the whole journey (round 23 counted about 147; round 25 spent about 75 cloud completions, 60 of them §6.3's researcher; round 26 spent about 160, about 102 of them the 2 researchers, so a fork driving it needs the scenario alone and may still need a resume at 200 turns), most of them
the `/research-epic` interview and its two researchers. Sections 1, 2 and 7 cost nothing or one
completion each and can be run alone. Run it on the free plan only if you want to see the width
narrow (§6.6); the default width is 3 and a free plan allows 1.

**Needs:**

- `OLLAMA_API_KEY` exported **in the shell that starts the tmux server**, not only in the shell you
  type in (the trial's `lain` pane died on a stale tmux environment).
- `bin/install-shim` run once, and `lain` resolving from a directory outside the checkout:
  `(cd / && lain help | head -1)`. Without it every step below that says `lain` is a different
  binary from the one under test.
- A tmux with `mouse` and `extended-keys` unset at server start, and an nvim whose user config
  does **not** auto-load lain's plugin. Use your real config; the trial's `:LainStart` failure
  needed a user `init` that resets `runtimepath`.
- A reachable local ollama, for the counter-check in 2.1 (`--provider ollama --model gpt-oss:20b`).
- The sandbox from `method.md` (`qa-sandbox.sh`), so `$QA` is the only place anything is written,
  with `$QA_SOCK` as its tmux socket name.
  §5 and §6 need directories **above** the project, so build them under `$QA`, never outside it.

Fixture, built once under `$QA`:

```bash
mkdir -p "$QA/parent/sibling/src" "$QA/parent/sibling/target"
git -C "$QA/parent/sibling" init -q
printf 'target/\n' > "$QA/parent/sibling/.gitignore"
for i in $(seq 1 60); do printf 'fn f%s() {}\n' "$i" > "$QA/parent/sibling/src/m$i.rs"; done
# a git-ignored build tree: many small files that must never be listed
for d in $(seq 1 300); do mkdir -p "$QA/parent/sibling/target/d$d"
  for f in $(seq 1 100); do printf 'needle %s\n' "$f" > "$QA/parent/sibling/target/d$d/o$f.txt"; done; done
git -C "$QA/parent/sibling" add -A && git -C "$QA/parent/sibling" commit -qm fixture
```

That is 30,000 ignored files carrying the word `needle`, and 60 tracked files that do not.
`$QA/parent/frugirl` does not exist yet; §1 makes it.

**Do not run this to answer "does the cloud work".** Run it to answer: *can a person start in an
empty directory, interview, research, and reach an approved research gate without the process
freezing, the HUD lying, or an approval vanishing unseen?*

---

## 1. Launch from nothing, `--create`

```bash
cd "$QA/parent"
lain up frugirl --create --socket "$QA_SOCK" -- --provider ollama-cloud --model glm-5.3
```

Chat flags go after `--`; before it, `lain up` answers `Unknown switches "--provider", "--model"` and creates nothing.

Checks:

1. **The directory was made**, and the session opens in it. `--create` makes only the missing leaf.
   Re-run with `lain up "$QA/parent/nope/deeper" --create --socket "$QA_SOCK"` and the refusal names the missing
   **parent**. Re-run `lain up frugirl2 --socket "$QA_SOCK"` without the flag and the refusal names `--create`.
   *Wrong looks like:* the trial's refusal that said only that the directory does not exist, or a
   leaf made under a parent that was never there.
2. **The model name is bare** (`glm-5.3`, no `:cloud` suffix); `/model` prints it. No status line or HUD segment names the
   model or the provider, so do not look for one. `/help` lists `research-epic`, `plan-epic`, `iterate-epic` and
   `create-epic-issues`.
3. **A launch notice says the width.** The chat pane prints, before the first prompt:
   `ollama-cloud runs up to 3 cloud requests at once; set LAIN_PROVIDER_CONCURRENCY to change
   it. It narrows on a concurrency refusal from the server.`
   *Wrong looks like:* silence. The trial ran serialized subagents at width 1 with nothing saying
   so.
4. **The key reaches the pane.** In a second tmux server (a different `-L` name) started **without** the key,
   `lain up --socket <that name>` prints a warning that names `OLLAMA_API_KEY` and `tmux set-environment -g`, and never
   prints the value. *Wrong looks like:* a chat pane that dies with status 127 or a bare "key
   missing" and no hint.
5. **The cockpit has what it needs at start.** In the nvim pane `:echo exists(':LainStart')` is
   `2` and the cockpit's windows are `lain://journal`, `timeline`, `inbox` and `request`; `lain-cockpit://start` is loaded but not shown. `tmux -L "$QA_SOCK" show-options -t lain mouse` is `on`, and
   `tmux -L "$QA_SOCK" show-options -s extended-keys` is `on` (or `always`). A fresh server reads
   `extended-keys` off, so the first launch prints a one-time notice that lain turned it on
   server-wide; that notice is expected, not a finding.
   *Wrong looks like:* `E492: Not an editor command: LainStart`, or a wheel that does not scroll.

## 2. The HUD tells the truth about the window

Take one turn (`say hi`), then read the status feed (`HUD state:` line of `lain up`) and the
journal:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "window=#{r["window_tokens"]} used=#{r["used_tokens"].inspect} prov=#{r["provenance"].inspect}" \
    if r["type"]=="compaction_decision"}' "$J"
```

Checks:

1. **`window_tokens` is the published figure for `glm-5.3`** (the cloud book in
   `context_window.rb`; read the row, do not remember it) and `provenance` is `published`. A bare
   cloud model name resolves its window **only on the cloud arm**: repeat with
   `--provider ollama --model gpt-oss:20b` and it must stay `guessed`.
   *Wrong looks like:* `window=8192 prov="guessed"` on the cloud arm. That was the trial: the
   denominator was a guess, so `ctx:~72%` rendered at 0.6% of the real window.
2. **`ctx` in the HUD is `used / published window`.** Compute it from the journal's first turn and
   compare with the `ctx:` segment. No `~` and no `?` mark on a published window.
   *Wrong looks like:* a `~` on `ctx`, or a percentage more than an order of magnitude off.
3. **Idle HUD has no in-flight segment**; during a turn it shows `model:Ns` (seconds climbing in the live reader, the chat's own HUD; the published state file shows a bare `model`), and
   during a tool call `tool:<name>` (`tool:grep`; several names comma-joined). Take a prompt that makes the model run `grep`
   and watch `tmux -L "$QA_SOCK" capture-pane -p` on the HUD row every second. The segment must appear, name the
   tool, and be gone after the result. **Round 23 HUD-1 and HUD-2, fixed:** the names come from the committed turn
   (`in_flight` in `state.json` reads `{"kind":"tool","tools":["grep"]}`, never `"tools":[]`), including a parked call
   (`tool:bash` while the approval waits). And a run that is interrupted clears the slot: after `/stop` mid model call,
   after Ctrl-C then `s`, after `s` at a parked `ask_human`, and after a transport failure (point `--api-base` at a
   closed port, with `--provider ollama`: the cloud arm refuses a non-https base at launch, by name) `state.json`'s `in_flight` is null and the idle `you>` carries neither `model:Ns` nor `tool:`.
   *Wrong looks like:* a HUD that reads the same for a 30 second model call as for idle. A redraw
   faster than once a second is a finding too (a redraw per tool call or token would flood the pane).
4. **Observation, not a check: `fleet:N`.** The trial read `fleet:0` after two subagents ran. Counting
   was checked end to end and the trial's reading could not be reproduced. In §6, record
   what `fleet:` reads while each researcher runs and after, and what the time was. A reading of
   0 while a child is running is a new finding with a timestamp; a reading that matches is
   recorded and closes nothing.

## 3. The cockpit's input and transcript

Checks, in the cockpit from §1:

1. **Shift+Enter inserts a new line** at the `you>` prompt, at `command>` and at the question prompt (**round 23 KEY-1, fixed**: the line editor asks the terminal for the key around each prompt read, so `extended-keys on` is enough), and plain
   Enter submits. A hint row `Shift+Enter or Alt+Enter for a new line` shows once per prompt.
   Drive it with `tmux -L "$QA_SOCK" send-keys -t <input> S-Enter` and also with a real keyboard once. Alt+Enter inserts one as well, in vi command mode too.
   *Wrong looks like:* Shift+Enter submitting a half-typed line.
2. **The chat pane writes to normal scrollback.** In the chat pane `tmux -L "$QA_SOCK" capture-pane -p -S -200`
   returns lines older than the screen, and the mouse wheel scrolls them. The pane does not enter
   the alternate screen (`\e[?1049h` absent from `tmux -L "$QA_SOCK" pipe-pane` output) while an input pane is
   attached.
   *Wrong looks like:* `capture-pane` showing only the current screen, or the wheel doing nothing.
   Note for the record: with mouse on, native selection needs Shift-drag.
3. **Prose wraps at word boundaries.** `tmux -L "$QA_SOCK" resize-pane -t <chat> -x 60`, then take a turn that
   returns a long sentence. No word is split across two rows, a long word is the only thing broken,
   and an indented line keeps its indent on the continuation.
   *Wrong looks like:* `...configur` on one row and `ation` on the next.
4. **Status lines carry a time.** A held line, an approval arrival, a drop and a timeout line each
   start with `HH:MM:SS`. Assistant prose does not.
   *Wrong looks like:* an approval that "appeared" with nothing saying when, so a 5 minute deadline
   cannot be reasoned about.
5. **`/help` is columns.** Names in one aligned column, bold headings, descriptions wrapped under
   their own column. At 60 columns a long name pushes its description to the next row.
6. **The transcript echoes your side (2026-10-09 trial fixes).** Type `say hi` in the input pane. The chat pane shows
   `HH:MM:SS you> say hi` before the reply. A slash command (`/status`) echoes too. A pasted prompt of 3 lines
   shows its first row after `you> ` and the other 2 indented under it, aligned to the text. A prompt a skill
   or `/goal` made is not echoed (nobody typed it at `you>`). A held line is echoed when it dispatches (`8273a631`).
   Repeat on a `--no-nvim` plain chat with no input pane: **no** `you>` line is echoed, since the terminal shows it.
   *Wrong looks like:* a transcript of replies with no sign of what asked for them, or each prompt echoed twice.
7. **A mid-run note reaches the agent (2026-10-09 trial fixes).** Send a prompt that makes the model run at least 3 tool
   rounds (`read 6 files one at a time and summarize`). While a tool round runs, type `also ignore the tests
   directory` in the input pane. The chat pane shows `HH:MM:SS note for the agent: also ignore the tests
   directory` and the run is not stopped. Then read the journal: the next request's last message carries a
   `<mailbox>` text block reading `human | also ignore the tests directory`, beside the tool results, and a
   `message` record from `human` with that `text` is journaled. **The note is in exactly 1 request**: the
   request after it carries the model's reply to the note and no `<mailbox>` block. Rules to try, each
   with what it must do:
   - a `/status` typed mid-run is not a note: it waits and runs as the next prompt;
   - an empty line is not a note;
   - at a parked `[y/N]` or `human>` a typed line is that prompt's, never a note;
   - type a note during the **last** model call of a run (a prompt with no tool use, over quickly: type the line
     right after Enter). It is not in that run. When the run ends the transcript says
     `HH:MM:SS your note joins your next prompt`, and the first request of your **next** prompt carries it.
   - type your next prompt the moment the final reply finishes, before `you>` is back: it is held as your next
     prompt and runs as one, never a note;
   *Wrong looks like:* a note held as `held as your next prompt` and run as its own turn, a note that arrives in
   2 consecutive requests, a note typed in the last call that vanishes, or a prompt typed after the final
   reply echoed as `note for the agent`.
   The system text of every agent says what a `<mailbox>` block is and that `human` is the person at the keyboard, so
   the model treats the note as yours and not as part of its task (`prompt-slots-and-roles.md` §5b).
   Known quirk: `/resend` of a `lain://request` buffer that already holds a pending note claims nothing, so the
   model sees that note twice.

## 4. Approvals: seen, answered, and explained

Write `$QA/parent/frugirl/.lain/config.rb`, run `lain trust` from `frugirl`, restart the chat:

```ruby
approval timeout: 25
```

Launch with `--approval ask`: a launched chat is `auto`, where the judge may answer the call before any
surface sees it. Ask the model to run `echo hello` with the `bash` tool. At `checkout ask` the call parks.
(`ls` no longer parks: it is on the shell rule's allowlist and runs in the project with no human.)

Checks:

1. **The deadline is visible before it fires.** The plain prompt reads
   `agent asks (auto-denies in 0:25): approve bash(...)? [y/N]`; the cockpit chat's arrival note
   ends `; auto-denies in 0:25`; the nvim approval row shows `0:25 left`. All three carry a time.
   The nvim figure is a snapshot, not a ticking clock.
2. **Let it lapse once.** After 25 seconds every surface says `denied after 0:25 with no answer`,
   once. The model's tool result is an error that says the same: `approval denied for tool "bash": denied after 0:25 with
   no answer` (**round 23 B23-2, fixed**; before, it was the bare sentence a human's `n` gives, and the model could not
   tell a lapse from a decision).
   *Wrong looks like:* the trial. The first `bash` call auto-denied after 300 seconds with the
   cockpit never having shown it, and the person learned only from the model's retry.
3. **The timeout is the configured one.** The journal's approval record for the lapse is dated 25
   seconds after the arrival, not 300. Remove the config, restart, and a fresh lapse takes the
   default 300 seconds (record only the displayed `5:00`; do not wait it out).
4. **A reason typed after `n` reaches the model.** Make another `bash` call, answer
   `n stay inside the project`. The tool result the model sees reads
   `approval denied for tool "bash": stay inside the project`, and the journal's approval record
   has `"reason"`. In nvim, `:LainDeny stay inside the project` does the same, and the `n` key
   with no text sends a bare deny with no reason field.
   *Wrong looks like:* a bare `denied` that gives the model nothing, so it retries the same call.
5. **Prose at a `[y/N]` is held, not answered (round 23 B23-11, fixed; plain chat).** Round 22's fix never landed, so check it
   on a `--no-nvim` chat: at a parked `[y/N]` type `please also fix the tests`. The approval stays parked, the line is held as
   the next prompt, and one line says `a y or n answers the approval`. A pasted block of several lines is held whole, even
   when its first line is `y`. The accepted answers are `y`, `yes`, `n`, `no`, `nope`, `nah` in any case, each with trailing
   punctuation (`yes!`), an empty line, and `n <reason>` (check 4). Nothing else decides it. Detail: `cockpit-surfaces.md` §5.
   The cockpit's `[y/N]` is answered in nvim, so it needs this plain-chat leg.
6. **Prose at `command>` is held with a reason.** While an approval is parked, type a free line at
   the `command>` prompt. The held notice says why it was held and where to answer (`/approve`,
   `/inbox` or the nvim buffer). It does not answer the approval, and typed prose never answers a
   question.
7. **Path-shaped text is not a secret.** Ask the model to read a file holding these lines, each
   one a false positive in the trial: `Cargo/Dioxus/clippy/deny/pre-commit`,
   `XDG_CONFIG_HOME/lain/config`, `github.com/lmcnulty/gender-voice-visualization_corpus`, and the
   64 character alphabet `ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/`.
   None parks for a release and none is masked. Then a line `config/prod/q8ZtLm2xR4vN7kPw9sYb`
   (a mixed-case key as the last segment) **still parks**.
   *Wrong looks like:* 5 of 5 flags false positives, as in the trial.
8. **A related directory never prompts for a flagged region.** Add `sensitivity related: %w[<literal value of $QA>/parent/sibling]` to `.lain/config.rb`, `lain trust`, restart. Read a file in
   `sibling/` that holds the real-looking key line from check 6: the read completes with the region
   masked and no release prompt, and the journal's redaction record shows released 0. A `.env`
   under that tree still parks at the read gate. `related: %w[/]` and `related: %w[~]` refuse at
   launch, naming the entry.

## 5. The freeze: a search above the project

Restore the default config (delete `.lain/config.rb`, `lain trust`, restart).

A fixed build finishes a search of the ignore-heavy fixture in well under a second, so on its own
it cannot tell a fixed walk from a frozen one. Build a second, deliberately slow tree that the
walk must read, a plain directory with no git (so no ignore file spares it):

```bash
mkdir -p "$QA/parent/slow"
for d in $(seq 1 400); do mkdir -p "$QA/parent/slow/d$d"
  for f in $(seq 1 500); do printf 'hay %s\n' "$f" > "$QA/parent/slow/d$d/f$f.txt"; done; done
printf 'search max_entries: 500000, max_bytes: 4294967296\n' > "$QA/parent/frugirl/.lain/config.rb"
```

Then `lain trust` from `frugirl` and restart. That is 200,000 files, and raising the limits lets
the walk run for as long as it takes, which is the condition that froze the trial. In the chat:

> Use grep to find the word `needle` in `<$QA/parent>`, and tell me which files hold it.

The word `needle` appears only in the ignored fixture; the slow tree supplies the duration.

Start a stopwatch and watch three things at once: the HUD row, the session journal's size
(`watch -n1 'wc -c "$J"'`), and the tmux status clock.

Checks:

1. **The chat stays alive during the search** (run it over `slow/`, which lasts long enough to watch). The HUD shows `tool:grep` and the chat pane keeps
   repainting; typing at the input pane echoes. The journal keeps growing or at least the
   `ps`-visible process stays responsive: `kill -0` answers inside 2 seconds, and a `/status` typed at the prompt is held at once as the next prompt (it is not answered mid-search).
   *Wrong looks like:* the trial. The whole process stopped answering for 105 seconds on a 40
   GB tree and for more than 2 minutes on the 171 GB one, and ignored SIGTERM.
2. **Ignored files are not walked.** Run this one over `sibling/`. The result lists no path under `sibling/target/`. The 30,000
   files that carry `needle` are all ignored, so the search finds **no match** and says so. A
   run that names `target/d1/o1.txt` is a failure of the walk, not of the model.
   *Wrong looks like:* 30,000 matches, a 200 MB read, or a multi-minute search over build output.
3. **A trailer names the limit when one is hit.** Lower it so it triggers cheaply: put
   `search max_entries: 40` in `frugirl/.lain/config.rb` (replacing the check 1 config) (`lain trust`, restart) and repeat the prompt over
   `sibling/src`. The result ends with a line like `listing stopped at 40 entries; narrow the path
   or the pattern`, and the 60 files are not all reported. Remove the config afterwards.
   *Wrong looks like:* a truncated answer that does not say it is truncated.
4. **Re-including an ignored path works.** Do this in a throwaway project so `frugirl` stays empty
   for §7: `lain up "$QA/parent/scratch" --create --socket "$QA_SOCK"`, then in `scratch` run
   `git init`, put `notes/` in `.gitignore`, and write `notes/a.md` holding `needle`. A grep over
   `scratch` finds nothing. Add `search include: %w[notes/**]` to `scratch/.lain/config.rb`,
   `lain trust`, restart: `notes/a.md` is found. Delete `scratch` and
   `frugirl/.lain/config.rb` before §6.
5. **A search can be stopped.** Start the grep over `$QA/parent/slow` and, while `tool:grep` shows,
   send SIGTERM to the chat process (`kill -TERM <pid>`; this is the primary action). On a warm cache the walk lasts 1 to 12 s, so a SIGTERM inside it needs a larger tree. Watch for the `turn` record carrying the `grep` `tool_use`, not the string `"name":"grep"`, which also matches the tool list in `request_sent`. **One SIGTERM opens the documented 60 second grace**, not an
   instant exit (`closing in 60s`, with `[c] cancel [w] wait longer [r] respond then exit [s] stop this ask` in the input pane); send a second
   SIGTERM, or take `s`, to see the stop. The chat then closes within about 1 second, `pgrep -af 'git .*ls-files'` is empty a few seconds later, and no
   `[git] <defunct>` is left under the chat's pid. Pressing `/stop` mid-search is a second,
   weaker try: the typed line may wait behind the turn, so record what it did rather than failing
   on it.
   *Wrong looks like:* a SIGTERM that is ignored until the walk finishes, or a leaked `git` child.

   **Round 23 j-5, fixed: a pending close survives the end of the ask.** Send one SIGTERM mid-search and then let the search
   finish on its own inside the 60 seconds. The countdown is not withdrawn, so the session closes when the ask ends: the
   journal gets `session_closed` and the process exits, rather than returning to `you>` and staying alive. Controls: a SIGTERM
   at an idle `you>` exits in about 200 ms, and a cancel (`c`) in the countdown keeps the session open.

## 6. A researcher on a sibling repository

In the chat, ask for a researcher on the sibling repo (the plain `/skill` form runs in your chat;
`@researcher/...` hands to a one-shot, which is the path under test):

> Spawn a researcher on `<$QA/parent/sibling>` to find every function in `src/`, read at least 40
> of the files one by one, and report the names.

Keep `--windows` on (`lain up ... --socket "$QA_SOCK" -- --windows`) for this section. It is a chat flag; before `--`, `lain up` answers `Unknown switches`.

Checks:

1. **The child's watch window opens while the child runs**, not when the chat exits.
   `tmux -L "$QA_SOCK" list-windows -t lain` shows the child's window within a few seconds of the spawn.
   *Wrong looks like:* the trial's windows, which appeared only at exit.
2. **A researcher can search.** Its tool list holds `glob` and `grep` as well as `read_file`
   (`/inbox` is not needed; read the spawn record in the journal). Its ceiling is 60 iterations,
   not the default 25.
3. **A ceiling stop hands back what it found.** Reading 40 files one at a time reaches the ceiling.
   When it does, the parent's tool result for the child is an **error that keeps content**: the
   ceiling text, a `read_file` list of the paths the child opened, a list of the searches it ran
   (pattern and path), and the child's last text, clipped as a whole. The parent's next turn uses
   them.
   *Wrong looks like:* `loop ran 60 iterations, ceiling is 60` and nothing else. The trial lost 51
   turns of research that way, twice.
   Ask for all 60 files; 40 finishes at about 42 iterations. Set §4.8's `related` config before this section, or every read of the sibling repo goes to the judge and is denied.
   If the model finishes before the ceiling, tighten the ask (more files, no batching) and repeat
   once; if it still finishes, record the iteration count and mark the check not reached.
4. **The child failed, honestly.** Its lifecycle record says `failed` with the ceiling class, not
   `completed`; the partial report does not change that.
5. **Observation, not a check: fleet count.** Record `fleet:` per §2.4.
6. **Narrowing, if you are on a plan that allows 1.** The first fan-out of 3 researchers may draw a
   concurrency 429. If it does, the journal holds an `admission_narrowed` record
   (`from_width`, `to_width`, `max_concurrent`), requests after it run at the narrowed width, and
   the chat did not fail. Some of the requests already in flight past the limit can fail after
   their retries; record how many. On a plan that allows 3, record that no narrowing happened.
7. **A researcher is warned before its ceiling (2026-10-09 trial fixes).** Both trial researchers spent 60 of 60 iterations
   reading and wrote no findings. Repeat the 40-file ask. When the child has 5 iterations left, its next request
   carries one `<mailbox>` block reading `lain | 5 of 60 iterations remain. A child stopped at its ceiling hands back only
   the files it read and its last text block, so write your findings as text now.` (the child's 56th request). No other
   request of that child carries it, and the warning is journaled as a `message` to the child's spawn. The child's
   role prompt also says it works to an iteration budget. If it then writes a text block and keeps reading, the
   ceiling stop's report (check 3) quotes that text under `Its last text block:`. No extra model request is sent
   after the ceiling. A child whose ceiling is 5 or less gets the warning on its first request.
   *Wrong looks like:* the trial's empty handback, a warning in every request, or one after the ceiling.
8. **A child's writes are reported under its role (2026-10-09 trial fixes).** The chat's `subagent` tool has no role and spawns a researcher; ask it to write 1 line (`write 1
   line to notes.txt in the project`). When its round settles the chat pane shows one stamped line, `HH:MM:SS researcher wrote
   notes.txt`; several files in one round are 1 line, `dev wrote 4 files: a, b, c (+1 more)`. A researcher that only reads
   prints nothing. Known gap: a child in its own worktree reports a path relative to that worktree without naming
   it, so the line reads as if it were your checkout; record it rather than failing.
9. **A related directory is in a child's scope as a tree (2026-10-09 trial fixes).** With `sensitivity related: %w[<$QA>/parent/sibling]` set (§4.8),
   ask a researcher to `list_files` and then `glob` `**/*.rs` on `<$QA>/parent/sibling` itself. Neither parks as
   `outside_project`; the trial's researchers were parked on the related root and could read only single files.
   A path beside it, `<$QA>/parent/slow`, still parks under `ask`. Under `auto` the listing goes to the judge; if the judge denies it, the chat shows a stamped line `the judge denied <tool>(<input>)` and the model is told `the judge refused this call` (round 25, k25-1, fixed), so a refusal is never silent. A judge that times out (30 s, `reason: fault`) parked the call with no note, so the human could not tell a failed judge from no judge (round 26, k26-8); the parked row now carries `the judge could not be asked (it timed out or failed)` (T74). Under `--non-interactive` the model is told no human can approve it instead. State which approval level the step runs at.

10. **Frugirl round 4 checks (default `auto`, relaunched without `--approval`).** Record the judge's latency
    per call and any approve that was wrong, and count the human prompts for the whole journey against
    round 3's 37. Each call the judge approves leaves one stamped transcript line, `the judge approved
    <tool>(<input>)`, and a call it left for you parks with `the judge deferred this` on its prompt, its
    `lain://approval` row and the plain chat's arrival line (b26-6 fixed, T5); a call that names a credential or a path lain cannot name for certain (`cat .env`,
    `ls "$HOME"`) never reaches the judge and parks with a quoted note after the call saying why:
    `the judge did not look: its paths cannot be named`, `the judge did not look: this command is barred from automatic approval`,
    `the judge did not look: it reaches more files than the judge weighs`, or `the judge did not look: <path> is not a path it may weigh`
    (round 25, k25-1, fixed). No researcher reads `/etc/passwd` or lists `/home`: each such call is refused or
    parks once and is then refused for that requester for the session with your reason. A deny you give on a
    `bash` call is remembered by the paths its words name, so a later `read_file` of the same path is refused from
    memory, while a deny of a command that names no path of its own (`rm -rf build`) remembers nothing. Press Shift+Tab
    in the `lain input` pane while a run is in flight: approval flips and the HUD shows it at once
    (a plain chat flips only at its prompts). A researcher's `rustc
    --version` runs with no prompt. Every researcher's first request carries the environment block
    (`prompt-slots-and-roles.md` §5b), names its own lease as its working directory and not `frugirl`, and the lease
    is under the state directory (`subagents-and-backends.md` §2c). Its first message names the lease and the
    project's path, so it reads `frugirl` files by absolute path without parking.

## 7. `/research-epic` to an approved research gate

Restart the chat in `frugirl` (it is still an empty directory; nothing was committed there). Use
the plain `/` form so the skill runs in your chat and can interview you:

```
/research-epic A small CLI that tracks my daily spending in a local file. No server. Rust.
```

Checks:

1. **The skill names only what the agent can reach.** The rendered skill (journal's first user
   turn, or `/skill research-epic` echo) holds the **absolute epic home**
   (`$XDG_STATE_HOME/lain/epics/<hash>`), and names `epic_write` and `epic_submit`. It contains no
   `Epic::Home`, no `Lain::Epic` and no `lain epic submit` as something the agent runs.
   *Wrong looks like:* the trial. The agent read lain's own `lib/` to find the epic home and
   called a `lain epic` command that was not on its PATH. After the run:
   `ruby -rjson -e` over the turn blocks for `read_file` paths, and **count those under the lain
   checkout: it is 0.**
2. **The interview is a question set.** The model calls `ask_human` once with a batch (outcome,
   scope, constraints, done), and it arrives at `lain://inbox`, then `lain://question` in the
   editor. In `lain://question`: `x` ticks an option, indented prose under it says why, `:w`
   submits. A line at column 0 that lain did not render is flagged and a hint row says where
   answers go. Type one anyway. **Round 23 j-8 and j-9, fixed:** a ticked option (`- [x]`) is not flagged as a bad
   indent (before, all of them were), and a `:w` that lain refuses (a stray line, an untouched buffer) is answered on the
   review rail with the sentence on screen and the buffer left modified; it never raises a hit-enter prompt, so nvim stays
   responsive (`nvim --server "$S" --remote-expr 1` answers at once after the refusal). The same holds for a compose write
   that could not reach lain.
   Round 26 (k26-3): the hint row exists as `virt_lines` (`60_question.lua`), so "no hint row" was wrong; what stood was a column-0 answer refused with option-line grammar. Fixed (T12): it now reads `line <n>: "<text>" is not indented -- write your answer on a line indented two spaces below the question`.
   *Wrong looks like:* a refusal that says only "cannot be edited". The refusal now says where
   answers belong.
3. **A typed reply at `/inbox` also answers the set**, as prose, and the model's next turn says it
   received the answer in prose.
4. **Greenfield grounding is honest.** There is no code to read. The model says so and does not
   search above `frugirl`. If it asks to look at `~/dev` or `$QA/parent`, that is a finding about
   the skill's "do not search above the named paths" rule (**round 23 j-10, fixed**: a spawned child's read outside the project parks
   as `outside_project`; the chat's own reads do not); deny it with a reason (§4.4) and watch
   what it does with the reason.
5. **`epic_write` works with no epic.** The model calls `epic_write` with `artifact: research` and
   a lowercase dashed `slug`. The file appears at
   `$XDG_STATE_HOME/lain/epics/<hash>/<slug>/research.md`, nothing is written inside `frugirl/`
   (`git -C frugirl status` is empty or `frugirl` is not yet a repository), and a slug with a
   capital or a slash is refused by name. `write_file` of the same path would have been refused or
   gated; `epic_write` is not.
6. **`epic_submit` reaches the gate in-process.** The model calls `epic_submit` with
   `stage: research`. With the default (interactive) policy a question arrives at `lain://inbox`.
   Approve it (an approval cannot carry a reason: any reply but the bare words is recorded `unrecognised` and denies, and the
   question says so). The tool result reads `research completed, epic_plan started` (re-submitting an approved artifact reads `already approved ... nothing was decided again`), the
   session file holds the stage record, and `lain epic queue` from a spare shell shows nothing
   pending afterwards. The chat was never blocked: the HUD and a sibling prompt kept updating
   while the gate waited.
   *Wrong looks like:* a model that tells you to run `lain epic submit` itself, an
   `epic_submit` that hangs the reactor while it waits, or a gate that is approved in a shell but
   never reaches the model.
   **A human's deny reads as a deny (round 23 g23-1, fixed).** Run it again and answer `n`: the tool result says the gate was
   denied, with no `deferred … parked in … review it: lain epic queue` line, even when an earlier submit of the same
   artifact left a deferral parked. Before, the answer was printed as a deferral, 2 of 2.
7. **An adjudicated stage is relayed, not faked.** Set `epics do gate :research, :adjudicated end`
   (`lain trust`, restart) and repeat the submit. The tool refuses and tells the model to ask
   **you** to run `lain epic submit research <slug>`; the model relays that sentence and stops. It
   does not loop on the tool.
8. **A new epic needs a restart to mount.** After `epic_write` created the epic in this chat, the
   model's final text says to restart the chat. `/implement-epic` answers `this chat is in no epic` until you
   restart (there is no `/epic status`; it answers `unknown skill "epic"`, and `lain epic status` from a shell refuses with `No epic
   artifact at …/epic.md` until the plan stage writes one). After restart, with one epic in the home, it mounts on its own.
9. **`epic_graph` adds an issue in-process.** After the research gate, `/plan-epic` runs the same
   way. Ask it to add one issue (`epic_graph` with `verb: add`) and then split it; the graph's
   issue files appear under the epic home and no `lain epic split` command is suggested.

10. **The cap is roomy, and a cut names the flag (round 23 j-7, fixed).** `--max-tokens` defaulted to 16384 (it was 4096), and since T89 it is unset by default: the output ceiling comes from the model (the window an ollama server says it serves, else 32768), and a typed value overrides it with `max_tokens_source: typed` in the header,
    so glm-5.3's first `/research-epic` turn finishes instead of spending the cap thinking; `lain up -- --max-tokens 16384` is
    no longer needed. To see the cut, relaunch with `-- --max-tokens 256` and send the same prompt: the chat prints `model hit
    max_tokens before finishing` followed by `raise --max-tokens (now 256); a thinking model's reasoning counts against it`.
    The flag changes nothing for a reply under the cap.

11. **A long `epic_write` is not a stall (2026-10-09 trial fixes).** Ollama sends a tool call's arguments whole, after a silence
    that grows with their size (about 20s for 13 KB in a measurement). Ask the model to `epic_write` a `research` of about 300
    lines (30 KB or more). With a typed `--max-tokens 16384`, glm-5.3's 30 KB write plus thinking hits the cap; the per-model default (T89) already allows more, and `-- --max-tokens 32768` forces the same for the unforced leg. The run finishes: no `stalled stream` error, `research.md` exists under the epic home, and
    the turn that carried the call is in the journal. A cloud deployment's stall limit is 115s and a local
    ollama's 295s, 5 under each request timeout. **Force a stall to read the message:** launch with
    `LAIN_STREAM_STALL_TIMEOUT=3` exported in the shell that runs `lain up` and repeat (it reaches the chat pane: `lain up` passes `LAIN_STREAM_STALL_TIMEOUT`, `LAIN_CONNECT_TIMEOUT`, `LAIN_STREAM_DEBUG` and `LAIN_ENV_PASS` on, round 25 k25-3, fixed). The ask ends with `stalled stream: no bytes for N.Ns, past the 3s
    stream_stall_timeout, with the connection still open` and a second line `set LAIN_STREAM_STALL_TIMEOUT to wait longer
    (in seconds; 0 turns the stall check off)`. Unset it again.
    *Wrong looks like:* the trial, 3 of 3 runs ending `stalled_stream` at the document write with nothing on disk, or a
    stall that does not say how to change the limit.
12. **A write is in the transcript (2026-10-09 trial fixes).** After check 11 the chat pane shows 1 stamped line for the round,
    `HH:MM:SS wrote <slug>/research.md` (an epic document is named `<slug>/<path>`). A round that writes several files is
    still 1 line. Reads (`read_file`, `grep`) print no such line.
13. **The document opens itself (2026-10-09 trial fixes).** With the nvim pane, `lain://epic/<slug>/research.md` opens in a split
    below your window when check 11's write lands, holding the file read-only (`:set ma?` is `nomodifiable`, filetype
    `markdown`), and **your cursor stays in the window you were in**. It is not in the 8 primed buffers of
    `cockpit-surfaces.md` §1. Have the model write it again: the buffer refreshes in place. Close its window
    (`:close` in it) and write again: the buffer refreshes **and no window reopens**; `:buffer lain://epic/<slug>/research.md`
    brings it back. From a shell, `lain epic show` prints the same text (it adds no trailing newline of its own since T49, k26-10 fixed: the bytes are the file's), `lain epic show epic` names the missing
    `epic.md` and the home, and `lain epic show notes` lists `research`, `epic`, `issues/ID` and `plans/ID`.
    *Wrong looks like:* a document nobody can read without knowing the XDG path, a window that grabs focus mid-typing, or one
    that reopens at every rewrite.
14. **The answered question buffer is closed, not left open (2026-10-09 trial fixes).** After you answer the interview's last set
    with `:w`, the `lain://question` window closes (unless it was the tabpage's only window), and `:buffer lain://question` shows the document under a first line `answered at HH:MM; your
    answers went to the agent`, read-only. The chat pane shows `HH:MM:SS answered the agent's questions` and one indented line per
    answer, each cut at 120 columns. With 2 sets pending, answering the first opens the second instead and
    the answered banner appears only after the last. An answer given with `/inbox` at the terminal echoes the same
    way.
    *Wrong looks like:* the trial's answered buffer left on screen and still writable, with a second `:w` refused, or an answer the transcript never shows.

## 8. Close-out

Run the sandbox's negative check (`method.md`): nothing outside `$QA` changed, the lain checkout's
`git status --porcelain` is the baseline under the same env, and no `tmux` server of the run is
left. Record per section: checks run, checks not reached and why, and every observation (§2.4,
§6.5, §6.6) with its time.

## What the 2026-10-08 trial found, and where to look

| Trial finding | Section |
|---|---|
| `grep` over `~/dev` froze the process, SIGTERM ignored | 5.1, 5.5 |
| search walked build output and ignored files | 5.2, 5.3 |
| both researchers died at the ceiling with nothing handed back | 6.3 |
| skill sent the agent into lain's source; `lain epic submit` not on PATH | 7.1, 7.6 |
| `ctx:~72%` at 0.6%; window guessed | 2.1, 2.2 |
| subagents serialized at width 1, no notice | 1.3, 6.6 |
| `fleet:0` after two subagents | 2.4, 6.5 (observation) |
| first `bash` call auto-denied unseen after 300 seconds | 4.1, 4.2 |
| a deny gave the model no reason | 4.4 |
| 5 of 5 secret flags false positives | 4.6, 4.7 |
| `:LainStart` missing under a real nvim config | 1.5 |
| Shift+Enter submitted; no scrollback; mid-word wrap; no times | 3.1 to 3.4 |
| windows opened only at exit | 6.1 |
| no in-flight HUD segment | 2.3 |
| `/research-epic` on glm-5.3 spent a 4096-token cap thinking and said only `model hit max_tokens` | 7 (default now 16384; a cut turn names the flag) |
| `lain` not on PATH; stale tmux env; missing directory refused | Needs, 1.1, 1.4 |
| question buffer and `/help` gave no guidance | 7.2, 3.5 |
| `epic_write` of the whole document ended `stalled_stream` 3 of 3 runs | 7.11 |
| prompts and answers never in the transcript; no sign of a write | 3.6, 7.12, 7.14 |
| typed text waited until the run ended | 3.7 |
| `research.md` under XDG state with no viewer | 7.13 |
| answered question buffer left open | 7.14 |
| both researchers spent 60 of 60 iterations and wrote nothing | 6.7 |
| a child's write invisible; the related root itself parked | 6.8, 6.9 |
