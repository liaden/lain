# Chat window UX — research and brainstorm (2026-07-28)

> ⚠️ **LLM-generated synthesis.** Claude-written, from a live smoke test of `lain up --nvim`
> against the ollama arm, a code-grounding pass over the frontend seams, and web research.
> Measured numbers are marked **[measured]** and were run on this machine. External claims
> carry URLs in § References. Readings and recommendations are Claude's, not a source's.
>
> **This is a research artifact, not a plan.** Nothing here is decided. It exists so the
> options — including the rejected ones — can be re-litigated later without redoing the work.

---

## 0. How this started

A live end-to-end test of the distributed stack (`lain up --nvim` → tmux cockpit → nvim
frontend → ollama/qwen3:4b) surfaced four defects. While reviewing them, Joel widened the
question from "fix the bugs" to "make the chat window itself better", then widened it again
to include Rust capabilities in `ext/lain`.

### Joel's questions and thoughts, as asked

> Lets consider making the chat window itself better within the terminal, either through a
> statusline or similar, or improving the prompt point as well. My thinking with some of the
> statusline or prompt line would be to:
> 1. When was the last message from the user sent?
> 2. What is the state of the inbox?
> 3. What is the state of the forked agents for orchestration?
> 4. When is the last time we had input from the user?
> 5. Context usage, modal state, session length, time since last compaction?
>
> Feel free to brainstorm for additional UI/UX features that would help facilitate things here.
>
> Additionally, I do think we would benefit from having colorschemes for the chat window and
> being able to handle some slightly prettier text ornamentation as well.
>
> Lets consider how this fits in for the chat window versus the ruby interactive debug as well?
> We may already have some planning around this that we should consult as well.
>
> I do wonder if we could do a trick like what firenvim does so that we can get all of the
> modal functionality of neovim within the lain chat window for cheap?

> Question: since we also have rust in place, could we leverage starship.rs for our "prompt
> line" to have a slicker experience? Either layering ontop of a user's starship.rs
> configuration OR using a specific toml within lain to render it? Maybe if we built it into
> our binary?

> I am okay with us widening `ext/lain` to include other rust-y related things such as
> starship.rs functionality or `skim` or other powerful things that rust can buy us.

That last line is a **policy change**. `CLAUDE.md` § "Rust, and which data structures earn a
binding" gates every binding on five rules, of which rule 1 is *"It is a data-structure
problem, not IO, async, or confinement."* A prompt renderer and a fuzzy matcher both fail
rule 1 as written. Joel's call supersedes it. The out-of-process rule is **unchanged** —
async/IO/isolation still belongs in `crates/lain-core`. The surviving in-process test is
**pure + synchronous + no terminal ownership**, because the Ruby frontend owns the terminal
and `spec/output_discipline_spec.rb` enforces that mechanically. CLAUDE.md should be amended
when a chunk next touches it.

---

## Part 1 — Findings from the live test

Four defects, with two corrections to the initial read. Both corrections matter: they change
what the fix should be.

### 1.1 `lain://journal` is dead in a live chat

`Frontend::Neovim::JournalView#lines` (`lib/lain/frontend/neovim/journal_view.rb:30-37`) has
exactly one branch, `when Telemetry::ToolOutput`. That branch is **unreachable in a live chat.**

The mechanism: `Wiring#run` mints one channel (`lib/lain/cli/wiring.rb:54`) whose sole consumer
is `Frontend::TTY` (`wiring.rb:58`). `Effect::Handler::Live` gets that same channel
(`wiring.rb:220`), so `Sink::IOAdapter` in `Tools::Bash` (`lib/lain/tools/bash.rb:108`) emits
`ToolOutput` onto it. The nvim `Channel::DropOldest` (`lib/lain/cli/live_views.rb:36`) is a
sink *inside the `JournalTee`*, fed by the chronicle — a different stream entirely. Nothing
bridges them.

So the only text `lain://journal` ever receives is `Resender`'s notices via
`@rpc.post_render` (`lib/lain/frontend/neovim/resender.rb:45,56`), which bypass `JournalView`
altogether. **Confirmed live:** a `bash` call streamed `[call_04tdp2xp stdout] LIVE-TEST-MARKER`
to the TTY while the journal buffer stayed at its one primed empty line.

> **Correction to the initial finding.** I first reported that the session record has no
> record of what tools printed. That was wrong. `Bash.render_output`
> (`lib/lain/tools/bash.rb:44-48`) puts the **complete** stdout and stderr into the
> `tool_result` content, which lands in the `turn` record. The bytes are on disk. What is
> missing from the record is only the *streamed* form: real chronological interleaving,
> per-write chunking, and arrival timing — plus the case of a killed run, where the turn
> record captures nothing but the stream already emitted.
>
> This changes the fix. Journaling `ToolOutput` would **duplicate** bytes already recorded,
> at one fsync'd NDJSON line per write, and every session reader that materializes a file
> (`CLI::Sessions::Row.for`, `Bench::Session::Loader`, `SessionRecord::Salvage`) becomes
> O(bytes-streamed). Fanning it to the *view* channel costs nothing and fixes the dead buffer.

Worth noting: `Telemetry::ToolOutput` already `include Journalable` and already serializes to
`"type" => "tool_output"` — pinned by `spec/lain/journal_spec.rb:25-31`. And no reader would
break on a new record type: every one narrows by `type` first, and `Journal.records`'
skip-unknown behavior is contract, not convenience (`lib/lain/journal.rb:91-97`). So the
journal half is *possible*; it is the volume and duplication that argue against it.

### 1.2 The cockpit's layout guard degrades silently

`Cockpit#nvim_pane_command` (`lib/lain/cli/up/cockpit.rb:36`) launches nvim with
`-c "if exists(':LainStart') | LainStart | endif"`. `:LainStart` is defined **only** by the
in-repo plugin (`plugin/nvim/plugin/lain.lua:12`, and `init.lua:217` via `setup()`), never by
the injected `runtime.lua`. Joel's nvim config carries the *ported* socket autocmd
(`~/.config/nvim/lua/config/autocmds.lua:88`) but not the plugin on runtimepath — so the guard
is false, the layout never opens, and **nothing reports it**.

This is the odd one out. Every other degrade in `Up` warns:

| Degrade | Site | Message |
|---|---|---|
| no `nvim` | `up.rb:177` | `nvim not found on PATH -- --nvim ignored, spawning the plain chat window (install neovim for the editor cockpit)` |
| unsplit reattach | `up.rb:191` | `session '<n>' already exists without the nvim pane -- reattaching as-is (…)` |
| no `jq` | `up/hud.rb:30` | `jq not found on PATH -- status-right falls back to raw state.json (…)` |
| **no `:LainStart`** | — | **silent** |

The plugin itself is fine: adding `plugin/nvim` to runtimepath and running `:LainStart` laid
out `journal | timeline/inbox/request` correctly. `spec/plugin/nvim_plugin_spec.rb:266-275`
already pins the exact condition (`exists(':LainStart') == 0` on a bare nvim) — it just isn't
treated as something to tell the user about.

There is **no** existing mechanism to detect the plugin on runtimepath before or after launch
(`grep -rn "runtimepath\|rtp\b" lib/ exe/` → zero production hits), and `Lain::Paths` has no
notion of the gem's own files. The nearest precedent for reaching a shipped file is
`Core::Child::BINARY = File.expand_path("../../../target/debug/lain-core", __dir__)`.

**Two shapes of fix, and they are different products:** (a) warn, matching the idiom above;
or (b) have `lain up --nvim` inject its own shipped plugin with `--cmd "set rtp+=<gem>/plugin/nvim"`,
making zero-install real and the layout unconditional. (b) is nicer but cuts against the
plugin's stated design — `plugin/nvim/plugin/lain.lua:1-6`: *"installing it must change nothing
about how lain attaches."* Arguably that rule governs the *user's* nvim, not a cockpit lain
spawned itself.

### 1.3 A blocked approval is invisible outside the chat pane

While `bash` sat awaiting approval: `.lain/state.json` showed `inbox_count: 0`, the HUD showed
`inbox:0`, no bell rang.

All three are explained by one root cause. **`Approval::Queue#admit`
(`lib/lain/approval/queue.rb:149-154`) emits nothing.** No journal record, no channel event.
`@parked` is a plain Array; `@arrivals` is an `Async::Queue` read only by surface fibers. The
entire approval lifecycle's only observable emission is the *post-hoc* `approval_decision`
record (`queue.rb:88-92,167`). No renderer has any signal at PENDING time.

The other two are consequences, not separate bugs:
- `inbox_count` counts only `:message` events addressed `to: "human"`
  (`lib/lain/status_feed.rb:164-169`). A `Pending` answers neither `#usage` nor `#kind`, so
  `StatusFeed#<<` skips it entirely. `inbox:0` during an approval is **correct by design**.
- Nothing in the entire tree ever emits a terminal BEL. `lain up` sets `monitor-bell on`
  (`up.rb:214`) on a window whose occupant never rings. The only `\x07` in the repo is
  `Shutdown::BYTES`' internal pipe protocol (`lib/lain/cli/shutdown.rb:46`).

Also uncovered, and worse: **`inbox_count` never decrements in a live chat** — documented at
`status_feed.rb:54-74` as an escalated, unfixed T13 gap. The retiring `:turn` goes straight to
the raw journal, never to the tee. And `spec/lain/status_feed_spec.rb:234` pins the published
key set with `contain_exactly`, so **any new state key breaks that spec** — relevant to every
statusline idea below.

### 1.4 A zero-byte session file poisons `--resume` and hangs `watch`

> **Correction to the initial finding.** I called this cosmetic. It is not.

`Journal.open` creates the file (`lib/lain/journal.rb:55-61`, `File.new(path, "ab")`) but the
header is written much later, in `SessionRecord::Scribe#initialize` (`scribe.rb:58`), reached
via `Chronicle#start` from `Wiring#run` (`wiring.rb:100`). Between them run `LiveViews`
construction, `Notify.for`, `Supervisor.new`, `fleet_isolation`, and the whole
`build_toolset` — a real, multi-hundred-millisecond window. A kill inside it leaves **exactly
a zero-byte `.ndjson`**, and nothing ever deletes it (`Paths::Ephemeral#reap!` requires the
`.btw` mark; there is no GC, no prune, no age sweep).

Three readers, three different behaviors on the same artifact:

| Reader | Behavior |
|---|---|
| `CLI::Sessions` | Degrades honestly — `sessions.rb:58` prints the frozen literal `"#{name}  ?  0 turns  unreadable  -"` |
| `CLI::Resume` | **Raises.** `Selector#newest` (`resume/selector.rb:53-55`) filters by suffix only, picks it, `Loader#header` raises `Corrupt` |
| `CLI::Watch` | **Hangs forever.** `newest_session` (`watch.rb:99-105`) doesn't even exclude `.btw`; `Tail#each` is "infinite by design" and only exits on `session_closed`, which never arrives |

**Bare `lain chat --resume` was dead on this machine from Jul 26 to Jul 28.** Two zero-byte
files are in the sessions dir now (Jul 16 and Jul 26). No spec anywhere exercises a zero-byte
file — `spec/lain/cli/sessions_spec.rb:139-143` uses a *non-empty* headerless file.

---

## Part 2 — What the terminal chat surface actually is today

Grounded 2026-07-28 against the working tree.

**`Frontend::TTY` (`lib/lain/frontend/tty.rb`, 636 lines)** owns the alternate screen
(`\e[?1049h`, `tty.rb:45`), a Pastel palette, and four nested collaborators: `History`,
`Countdown`, `Warmth`, `Inbox`. Its class doc (`tty.rb:14-40`) is a scope contract that any
UX chunk must argue against explicitly:

> *"the TTY is deliberately minimal… The richer interactive interface is not a bigger TTY or
> an embedded Ruby console; it is the Neovim frontend (M4)… So this class stays small on
> purpose; growth goes to Neovim, not here."*

**The prompt is composed at exactly one place** — `tty.rb:223`:

```ruby
line = Reline.readline("#{warmth_prefix}#{@pastel.bold(text)}", true)
```

i.e. `[● or ○ or nothing] + bold("you> ")`. `warmth_prefix` (`tty.rb:233-237`) reads
`.lain/state.json` **from disk** (deliberately — `tty.rb:349-356`: StatusFeed and TTY may be
different processes).

**The whole palette, across the entire frontend**, is nine literal calls: 5× `dim`,
4× `yellow`, 3× `bold`, 2× `yellow.bold`, 1× each `red.bold`, `red`, `green`, `cyan`. There is
**no `Theme`, no `Palette`, no colorscheme, no style-token abstraction anywhere in the repo.**
`Pastel.new(enabled:)` is the only configuration and it is a boolean.

**`Decorators` (`lib/lain/frontend/decorators.rb`, 56 lines)** is a one-member family by
design (`decorators.rb:20-26`: *"a one-member family earns no lookup table"*). `.for(event)`
returns a decorator or nil; `render(pastel)` returns a String. The **injection seam for a
palette object already exists** — `render` takes the palette as a parameter — but what gets
injected is a raw `Pastel` and every call site names a literal color.

**A command's entire return is a String** (`Repl#settle_command`, `lib/lain/cli/repl.rb:132-139`),
which `deliver_text` wraps wholesale in `pastel.cyan` plus a full-width dim rule. So `/status`
and `/help` **cannot render styled output today** in any structured way. Embedding raw ANSI
would nest inside Pastel's cyan wrapper, where an inner reset drops to terminal default rather
than back to cyan.

**Already-present terminal gems** (no new deps needed for a lot of this): `pastel 0.8.0`,
`tty-cursor 0.7.1`, `tty-screen 0.8.2`, `tty-color 0.6.0` (transitive — gives 8/16/256/truecolor
detection free), `unicode-display_width 3.2.0`, `unicode-emoji 4.2.0`, `neovim 0.10.0`,
`reline 0.6.3`. **Not present:** `tty-box`, `tty-prompt`, `tty-table`, `curses`, `rouge`.

**`/ruby` (`lib/lain/cli/command/ruby.rb`)** forces `IRB::StdioInputMethod`
(`ruby.rb:77-83`) precisely because IRB's default is Reline-backed and would fight the chat
prompt over the one global `Reline`/`Reline::HISTORY`. It runs *inside* the alt screen, scrolls
it, writes no terminal byte itself, and — unlike `read_reply` (`conductor.rb:135-141`) — does
**not** suppress the countdown ticker. That is a latent collision.

---

## Part 3 — Constraints prior planning already set

This is the part that most changes the shape of a chat-UX chunk. Three standing rulings.

**(a) The renderer hierarchy was decided, and it demotes the TTY.**
`planning/interface-integration.md:418-436`, decided 2026-07-11:

> *"the tmux status line is the persistent surface … a natural HUD. lualine only renders while
> the nvim pane is focused, so it demotes to optional enrichment … **The TTY prompt is a
> per-prompt snapshot.** Build tmux first; the publisher doesn't care."*

**(b) The Reline limitation was recorded as design-shaping, with an instruction.**
Same file, `:434-436`:

> *"**Reline limitation (design-shaping):** the prompt string is fixed once `readline` /
> `readmultiline` is waiting — no mid-wait refresh. So the TTY prompt shows warmth *as of
> prompt display*; live ticking belongs to tmux. **Don't fight this.**"*

**(c) A TTY bottom line already exists and its ownership is spec-pinned.**
`TTY#render_countdown` owns the bottom line during shutdown
(`chunk-fixes-xdg-resume-signals.md:1136,1155`), and a PTY probe already proved Reline
*"swallows every countdown key and fights over the bottom line"* (`:1170-1178`). Any new
persistent status line must arbitrate with it.

**Also relevant:** output discipline is absolute — ornamentation code must live under
`lib/lain/frontend/` or `spec/output_discipline_spec.rb` fails it. And there is **zero prior
art on colorschemes or ornamentation**: `grep` for "colorscheme"/"ornament" across `planning/`,
`docs/`, ROADMAP, README, ARCHITECTURE, CLAUDE.md returns **nothing**. The only "theme"
doctrine is *don't touch the user's global tmux/editor theme; scope everything to the lain
session* (`interface-integration.md:427`).

**Not a constraint:** nothing says the TTY must stay plain. It already owns Pastel, an alt
screen, a decorator family, a bottom-line countdown, and a warmth glyph. And
`code-review-ollama-test-infra.md:1150-1167` explicitly sanctions the ornamentation seam:
*"the sanctioned shape for your Renderable instinct is decorators living IN the frontend …
colors stay frontend-owned."*

**Net:** the constraint is not "no TTY UX". It is that *live ticking* was awarded to tmux and
the TTY prompt was scoped to a display-time snapshot **because Reline cannot refresh mid-wait**.
A snapshot-shaped prompt honors all three rulings. A ticking status line revisits all three.

---

## Part 4 — The five metrics, against what actually exists

Joel's list, checked against the code. **Zero of the six are published today.**

| Metric | Exists? | Holder | Reachable from the frontend? |
|---|---|---|---|
| Inbox state | Yes, but **broken live** | `StatusFeed#inbox_count` | Yes (file) — never decrements (`status_feed.rb:54-74`) |
| Fleet / forked agents | Yes, **undercounts** | `StatusFeed#fleet` | Yes (file) — identical spawns share a content address, so two live actors collapse to one entry |
| Cache warmth | Yes | `StatusFeed#cache_deadline` | Yes — the one metric that works; absolute deadline so a renderer ticks locally |
| Context usage % | **Both halves exist, never combined** | numerator `Agent::Accounting#last_turn_usage` (private ivar); denominator `ContextWindow#window_tokens` | **No.** The ratio is computed inside `Need::ApproachingWindow#fired?` (`compaction/need.rb:78-80`) and thrown away as a boolean |
| Session length / elapsed | **No.** No session start timestamp is held anywhere live | — | No |
| Time since last compaction | **No.** Only *time since cache touched* exists, in the `private_constant` `Source::IdleGap` | — | No |
| Time since last user input | **No.** Nothing records when a prompt was answered | — | No |
| Turn count | Partially — `Agent#iterations`, session-lifetime model calls, not reset per ask | `Lain::Agent` | Only via `Env#agent` from a **command**, not the render loop |
| Modal state | N/A today (no modal editing) | — | — |

**So the work is mostly plumbing, not rendering.** Four of the six metrics need a publisher
before any renderer can show them, and `StatusFeed` is the obvious home — its `#<<` is already
fanned every journal event, and `#state` is the one derivation both `.lain/state.json` and
`/status` read. But `spec/lain/status_feed_spec.rb:234` pins the key set exactly, and any new
key must land in **three** places in lockstep (`status_feed.rb:196`, `up/hud.rb:24-28`
`JQ_FILTER`, and `plugin/tmux/scripts/lain-status:33-35`, which
`spec/plugin/tmux_plugin_spec.rb:54-57` pins byte-for-byte).

---

## Part 5 — Ideas considered, with tradeoffs

### 5.1 The prompt line

Four options. Research on starship was decisive on two points.

**Option A — shell out to `starship prompt`.**

| | |
|---|---|
| **For** | Zero rendering code. Familiar TOML dialect. Free git/language modules. Honors constraint (b) exactly — starship renders a *static string at display time*, which is precisely what the Reline prompt is scoped to. **[measured]** ~2.7 ms with a lain-controlled minimal config. |
| **Against** | **No config layering, definitively.** `STARSHIP_CONFIG` is all-or-nothing; multi-path merging is [PR #6894](https://github.com/starship/starship/pull/6894), open since Aug 2025, review stalled with the maintainer saying *"I will stop looking at any comments on this PR."* So "user's look + lain's data" requires lain to parse and merge TOML in Ruby and own invalidation. |
| **Against** | **Reline mangles multi-line prompts.** `line_editor.rb:225` is literally `@prompt = prompt.gsub("\n", "\\n")`. Starship's default two-line output renders as a literal `\n`. The host must split the string and print the header lines itself — which then **do not redraw** on resize or history navigation. Real fidelity loss, unfixable in config. |
| **Trap** | `STARSHIP_SHELL` is inherited (it is `zsh` in this environment). A naive `IO.popen` gets `%{…%}` zsh markers, which **[measured]** Reline measures as width **10** instead of 2. The host must clear it. |
| **Trap** | Child is not a tty → starship silently uses `--terminal-width 80`. Must pass `IO.console.winsize` explicitly. |
| **Trap** | stderr must be captured or `[ERROR] - (starship::config)` interleaves into whatever it inherits — a direct threat to NDJSON journal discipline. |
| **Note** | `starship statusline claude-code` is **new in 1.26.0** — a first-class provider for exactly this shape of problem. Worth reading before designing anything. |

**Option B — oh-my-posh instead.** Strictly better on the one axis starship fails: it has an
**`extends`** key giving true config layering (child merges over parent, local path or URL),
accepts TOML, and has an explicit **`uni`versal shell mode** meaning "no shell-specific escape
wrapping" — exactly the raw-ANSI mode lain must reverse-engineer out of starship. MIT, 23.2k★.
**Against:** smaller ecosystem, and it does **not** help with the multi-line/Reline problem at
all, which is the harder of the two.

**Option C — compose it in Ruby with Pastel.** Zero new dependencies of any kind (pastel,
tty-screen, tty-color, unicode-display_width are all already in the bundle). Full control of
width math and the single-line constraint. **Against:** we build the theming system ourselves,
and we get no git/language modules. But — see Part 4 — **the modules are not what we want.**
Every metric Joel listed is lain's own state, already in-process.

**Option D — render it in Rust in `ext/lain`.** Newly viable given the widened charter. Prompt
formatting is *pure, synchronous string work over a config struct* — it fits the surviving
in-process test perfectly, better than most things already bound. Could implement a
starship-compatible `[text](style)` format DSL over a TOML config, giving the familiar dialect
without the fork/exec, the `STARSHIP_SHELL` trap, the width trap, or the layering problem.

> **The observation that matters across A–D:** starship's real value is (a) built-in modules
> and (b) a familiar TOML dialect. lain needs neither module set — every metric in Part 4 is
> **already in the harness**. Shelling out means marshalling lain's own state *out* through
> env vars only to marshal it back *in*. Starship is buying mostly a config parser.
>
> Against that: A is by far the fastest to a working prototype, and "it reads like my shell
> prompt" is a real ergonomic win that C and D have to earn.

### 5.2 Snapshot prompt vs. ticking status line

**Snapshot** (re-rendered at each prompt display, ~once per turn): honors all three standing
rulings, no arbitration with `Countdown`, no Reline fight. Cannot show elapsed time ticking —
but *can* show "12m since last input" computed at display time, which is most of the value.

**Ticking bottom line** (redrawn on a timer): the only way to get live elapsed/cache countdown
in the TTY. Costs: revisits ruling (a); must arbitrate with `Countdown`'s spec-pinned bottom-line
ownership; must survive the alt screen and Reline's redraw, which a PTY probe already found
hostile. Note there **is** an existing periodic pump to host it — `Conductor::CountdownTicker`
(`conductor.rb:261-304`) at `DEFAULT_TICK = 1.0` — and an existing precedent for suppressing it
during a read (`read_reply`, `conductor.rb:135-141`, which exists precisely because a status
line *"would smear against Reline's echo"* and a non-blocking key read *"would steal a keystroke"*).

**Middle path worth considering: DECSTBM scroll regions.** Reserving the bottom line with a
scroll region is how shells and multiplexers do persistent status lines without fighting the
line editor. Not researched in depth here; flagged as the obvious third design point.

**Also worth stealing regardless — powerlevel10k's two ideas:**
- **Transient prompt** — collapse a past prompt to a stub once submitted, so scrollback stays
  clean and copy-pasteable. In a chat REPL the scrollback *is* the conversation record, so this
  is arguably worth more here than in a shell.
- **Instant prompt** — render cheap segments immediately, fill expensive ones in async.

### 5.3 Modal editing — the firenvim question

Research was extensive here; five distinct designs, ranked by cost/benefit.

**How firenvim actually works** (read from source, v0.2.17): it spawns a *private*
`nvim --headless`, stands up a WebSocket server in Lua inside it, attaches as a **full UI
client** (`nvim_ui_attach` with `ext_linegrid`), and implements 24 `redraw` handlers painting
cells onto a canvas (`src/renderer.ts`, 1096 lines). Text sync is a **temp file plus a
`BufWrite` autocmd** → `rpcnotify`, not a live binding.

| Design | Cost | What you get | What you lose | Verdict |
|---|---|---|---|---|
| **1. Full UI-protocol embed** (real firenvim) | ~600–1000 lines of Ruby, a second supervised process, terminal-ownership conflicts with `Conductor`/`PromptBreaker` | Everything, incl. nvim's own painting: syntax highlight in the prompt, live `:` cmdline, completion popup | — | **The opposite of "for cheap."** |
| **2. UI-attach to the user's running nvim** | — | — | — | **Impossible.** `:h nvim_ui_attach`: *"If multiple UI clients are attached, the global screen dimensions degrade to the smallest client."* **[measured]** an 80×4 attach collapsed a 200×50 editor to 80×4 — and `ext_multigrid` does not help. Ruled out. |
| **3. `buftype=prompt` in nvim** | Low — nvim's blessed "chat UI / REPL" primitive; lain already has all the plumbing | `prompt_setcallback` + `prompt_appendbuf` + `rpcnotify` is a complete design | **Relocates the prompt into nvim.** The terminal prompt doesn't gain vim keys; it stops being where you chat | Low cost, high support, **changes the product**. Needs nvim 0.12 to be pleasant. |
| **4. Reline vi mode** | ~free (`set editing-mode vi` in inputrc, or `Reline.core.config` without touching the user's file) | 16 motions, `d`/`c`/`y` + doubled forms, counts on both sides, `/`/`?` search, mode strings | **Everything a vim user's fingers actually do**: no text objects (`ciw`, `di(`), no `.`, no macros, no named registers, no marks, no visual mode, no `:`. Plus a real bug — `dfa`/`dfc`/`dfi`… silently drop the operator | **Worth doing as a floor.** Do not call it "vim mode"; the first `ciw` disappoints. |
| **5. Edit-in-nvim on a keystroke** | **Tens of lines.** No new process | The user's *real* nvim — actual config, plugins, text objects, macros, registers, `.` | Focus doesn't move automatically; user switches panes | **Best cost/benefit by a wide margin.** |
| **6. Headless nvim as a pure editing engine** (the dark horse) | Moderate — a private headless nvim, but **no `ui_attach`, no grid renderer** | **[measured] verified working:** `f(ci(cat<Esc>` ✓ text objects, `..` ✓ repeat, `3@a` ✓ macros, `"ayw$"ap` ✓ registers, `0vey$p` ✓ visual. 0.067 ms/keystroke | nvim's *painting* only: syntax colors, search highlight, live cmdline, popup menu | **This is what actually delivers "all of neovim's modal functionality for cheap."** |

Notes on **5**: `nvim --remote-wait` **does not exist** — `E5600: Wait commands not yet
implemented in Nvim`, confirmed on 0.12.4, so the `EDITOR=` shortcut is out. But lain doesn't
need it: it already holds an RPC channel. The verified recipe is scratch buffer +
`buftype=acwrite` (**not** `nofile` — `:w` fails with `E382`) + `nvim_buf_set_name` (an unnamed
`acwrite` buffer fails with `E32`) + `BufWriteCmd`/`BufUnload` → `rpcnotify` → read back with
`nvim_buf_get_lines`. This is one Lua entry point and one command verb on the existing
`RpcThread`/`runtime.lua` seam. bash/zsh/fish all implement the same gesture
(`C-x C-e` / `edit-command-line` / `edit_command_buffer`); Reline even ships a rough version,
`vi_histedit`, bound to `v` in vi command mode — with three defects worth fixing if reused
(`ENV['EDITOR']` only with no `VISUAL` and no nil guard; string-interpolated `system()`; and it
calls `finish`, submitting immediately with no chance to review).

Notes on **6**: this is what `bfredl/Neovim.jl` did for the Julia REPL (self-described as *"a
terrible hack"*), and what [neovim#1777](https://github.com/neovim/neovim/issues/1777) — open
2015, closed, blessed by core — proposed verbatim. It is also roughly where vscode-neovim
landed from the other direction: it *does* `ui_attach`, but lets the host render the text and
uses nvim as the editing engine plus a source of externalized widgets. **No maintained project
hosts an nvim editing region inside a TUI via the UI protocol.** Eleven years, no takers —
which is either a warning or an opening.

**The Ruby gem is not a blocker for any of these.** `neovim 0.10.0` supports `nvim_ui_attach`
(generated at runtime from `nvim_get_api_info`; also in the YARD docs at `client.rb:274-279`),
receives `redraw` notifications via `Session#run`, and spawns `--embed` via `attach_child`.
lain's `RpcThread` already owns the socket from one thread, which is the gem's one real
constraint. **But** `dispatch` currently only handles `sync?` messages
(`rpc_thread.rb:286-299`) — notifications are dropped today, so a `redraw` branch is new code.

### 5.3a `C-g` → nvim → `:wq` → back to chat (Joel's proposal, worked through)

> *"Could we add keybindings to our chat then such that ctl-g sends the current text to the
> nvim session and then a `:wq` effectively sends it back to our chat window?"*

**Yes.** This is design **5** made concrete, and the two halves have very different costs.

**The nvim half is verified working and cheap.** Recipe, in order (each step's failure mode was
hit for real during research):

```ruby
buf = c.create_buf(false, true)
c.set_option_value("buftype", "acwrite", {"buf" => bid})   # NOT nofile
c.buf_set_name(bid, "lain://compose")                       # required, see below
c.buf_set_lines(bid, 0, -1, true, draft_lines)
c.create_autocmd(["BufWriteCmd"], {"buffer" => bid,
  "command" => %{call rpcnotify(#{ch}, "compose_save", #{bid})}})
c.create_autocmd(["BufUnload"], {"buffer" => bid, "once" => true,
  "command" => %{call rpcnotify(#{ch}, "compose_abort", #{bid})}})
c.open_win(bid, true, {...})       # then read back with buf_get_lines
```

- `nvim_create_buf(false, true)` sets `buftype=nofile`, so `:w` fails with **`E382: Cannot write,
  'buftype' option is set`** and `BufWriteCmd` **never fires**. It must be `acwrite`.
- An **unnamed** `acwrite` buffer fails on write with **`E32: No file name`**. Hence the
  `lain://compose` pseudo-URI — which also gives the autocmd a `pattern` and matches the existing
  `lain://` buffer family.

**`:wq` is exactly the right gesture *because* we key off `BufWriteCmd`.** `:wq` is `:w` (fires
`BufWriteCmd` → text comes back) then `:q` (closes the window). Worth noting this is precisely
where the off-the-shelf tool fails: `nvr --remote-wait` keys off buffer **deletion**, which is why
`:wq` leaves the buffer hidden and hangs the caller, and why its README tells you to type
`:w | bd` instead. Our own autocmd is *better* than `nvr` here, not a poor substitute for it.
(`nvim --remote-wait` itself does not exist — `E5600`, confirmed on 0.12.4.)

`BufUnload` is the cancel path: `:q!` without writing must un-wedge the prompt, not leave it
blocked forever.

**The Reline half is where the cost is.** Verified locally against reline 0.6.3:

- **`C-g` (byte 7) is unbound** — `Reline::KeyActor::EMACS_MAPPING[7] => nil`. No conflict; the
  key is free. (So is `C-x`, if a two-key `C-x C-e` matching bash/zsh is preferred.)
- **But Reline binds keys to *method names on `Reline::LineEditor`*, not to Procs.** Dispatch is
  `return unless respond_to?(method_symbol, true)` then `method(method_symbol)`
  (`line_editor.rb:955-956`). There is no callback registry and no Proc escape hatch.

So "send **the current buffer**" needs one of:

| Approach | Cost | Notes |
|---|---|---|
| **Define one method on `Reline::LineEditor`** from `lib/lain/frontend/` | Small, but it is a monkeypatch of a stdlib class touching private ivars (`@buffer_of_lines`) | The honest cost. Frontend-only, so output discipline holds. Escalation trigger: a Reline minor bump renaming that ivar breaks the prompt silently |
| **Rebind `vi_histedit`** (already exists, already bindable) | Zero new code | Three defects: `ENV['EDITOR']` only with no `VISUAL` and no nil guard; string-interpolated `system()`; and it calls **`finish`** — submitting immediately with no chance to review. Also spawns a *new* process rather than using the RPC channel we already hold |
| **A `/edit` command instead of a keybinding** | Zero Reline coupling | Loses the "send what I've already typed" part — a command runs *after* submit. Cheapest, least satisfying |

**Recommended shape:** bind `C-g` to a lain-defined `LineEditor` method that hands the buffer to
the frontend, blocks on a `Queue` while `RpcThread` runs the round trip, replaces the buffer with
what comes back, and **does not `finish`** — so you land back at `you>` with the edited text and
press Enter yourself. That is strictly better than `vi_histedit`'s immediate submit, and it reuses
the RPC channel instead of spawning a process.

**Open risks to carry:**
- The main thread blocks while `RpcThread` works. `Conductor`'s `PromptBreaker` is armed during a
  prompt (`conductor.rb:191-198`) — Ctrl-C must still break out of the wait, not wedge it.
- **Focus does not move.** The user presses `C-g` in the terminal, then switches to the nvim pane
  themselves. Inside `lain up`'s cockpit that is one tmux key and it is fine; in a bare terminal
  beside a separate nvim, the round trip mostly defeats the point.
- If no editor is attached (`--nvim` absent), `C-g` must degrade honestly — the Null Object idiom,
  not a nil check.

### 5.4 Colorschemes and ornamentation

No prior art anywhere, so this is greenfield. The seam is already half-built: `Decorators#render`
takes the palette as a parameter. The work is (a) replace the raw `Pastel` with a `Theme`/`Palette`
object exposing **named style tokens** (`theme.tool_attribution`, `theme.error`, `theme.response`)
rather than colors, (b) move the nine literal call sites onto tokens, (c) load a theme from
config with a sane default.

Two hard constraints: **`tty-color` (already in the bundle) must gate truecolor** — degrade to
256 and to 16 honestly; and `spec/lain/frontend/decorators_spec.rb:20` pins the literal ANSI
bytes of `red` for stderr, so that spec must move to tokens in the same change.

Bigger structural question: **a command's whole return is a String wrapped wholesale in cyan.**
Ornamented `/status` or `/help` output needs commands to return something richer — a renderable,
or a small markup the frontend interprets. That is a real API change to
`Repl#settle_command` and every command, and it is the single highest-leverage change for
"prettier text", more so than any palette.

### 5.5 Chat window vs. the `/ruby` debug console

Today `/ruby` runs IRB inside the chat's alt screen, scrolling it, with `StdioInputMethod`
forced to avoid fighting over the global `Reline`. It does **not** suppress the countdown
ticker — a latent collision `read_reply` already solved for its own case.

Options: **(a) leave it** — it works, the Reline conflict is already handled deliberately;
**(b) give it its own tmux pane/window** via `CLI::TmuxSurface`, which already does popups and
windows for `/btw` and `/fork` — this is the natural fit and matches TODO.md's own line about
*"segregating the prompting area from the irb/debug/pry console"*; **(c)** an nvim-side console
buffer. **(b)** looks clearly right and is cheap given `TmuxSurface` exists.

### 5.6 Additional UX brainstorm

Beyond what was asked:

- **Fuzzy command/history palette and `@file` autocomplete.** See §5.6a — the matcher is the
  easy part; where the picker *renders* is the real decision.
- **Transient prompt** (5.2) — the conversation record stays clean.
- **Streaming render.** Today `render_response` prints the whole text at once. Token-by-token
  streaming with a spinner is a large perceived-latency win, especially on the local ollama arm
  where **[measured]** a turn takes tens of seconds.
- **A bell, finally.** Nothing emits `\a`. One byte on "approval pending" / "turn complete"
  makes `monitor-bell` (already set by `lain up`) actually work, and costs nothing.
- **`approval_pending` telemetry** — the missing emission from 1.3. It unblocks the HUD, the
  nvim inbox view, and the bell all at once. Probably the highest-leverage single fix in this
  document.
- **Markdown rendering** for agent responses — currently raw text in cyan.
- **Syntax-highlighted code blocks** in responses.
- **Diff rendering** for `write_file`/`edit` tool calls, in the TTY rather than only `lain://diff`.
- **A `/theme` command** to switch palettes live, which also makes the theming testable by hand.

---

### 5.6a `@`-triggered fuzzy autocomplete — and why Reline can't host it

The intended use for a fuzzy matcher is **`@`-triggered path completion in the prompt**, not a
full-screen picker. That distinction matters, and verifying it surfaced a blocker.

**Reline's completion pipeline is prefix-only, hard-coded.** `perform_completion` runs everything
`completion_proc` returns through `filter_normalize_candidates`
(`line_editor.rb`), whose entire filter is:

```ruby
list.select { |item| item.start_with?(target) }   # or item.downcase.start_with?(target)
```

So returning `lib/lain/frontend/tty.rb` for the query `ttyrb` gets **silently dropped**. There is
no hook to override it — `completion_proc` supplies candidates, not ranking. **A fuzzy matcher
cannot be plugged into `Reline.completion_proc`.** This kills the obvious design, and it is the
reason ROADMAP `:641-646`'s "Reline `completion_proc`" line under-describes the work.

Two conveniences that *do* survive: `@` and `/` are **not** in
`Reline.completer_word_break_characters` (default `" \t\n\`><=;|&{("`), so `@lib/la` arrives as a
single target with the sigil attached — easy to detect. And `Reline.autocompletion` exists
(default `false`), which is the show-a-dropdown-as-you-type mode, if prefix completion is enough.

**So the choice is not the matcher — it is where the picker renders.** Three homes:

| Home | Cost | Fuzzy? | Notes |
|---|---|---|---|
| **Reline's own menu** (`completion_proc` + `autocompletion = true`) | Near zero | **No** — prefix only | Perfectly good for `/command` and slot names, where prefix is what you want anyway. No Rust needed at all |
| **tmux popup running `fzf`** | Low — `TmuxSurface#popup` **already exists** (`tmux_surface.rb:97`, `display-popup -EE`), built for `/btw` | Yes, free | **Dodges the terminal fight entirely** — the popup has its own tty, so Reline is never suspended. fzf 0.74.1 is already installed here. Requires tmux; `popup_supported?` (`:151`) and the `-CC` window degrade are already handled |
| **Our own render** (`nucleo-matcher` in `ext/lain`) | Highest — same `Reline::LineEditor` monkeypatch as §5.3a, plus drawing the menu | Yes | Only option that works with **no tmux and no nvim**. Most control, most work |

**On the specific crate question:** `fzf` is Go, so its algorithm is not linkable — `nucleo-matcher`
*is* how you get fzf-quality matching in Rust (it is explicitly modeled on it). As an external
binary, prefer **`fzf` over the `sk` binary**: functionally equivalent, vastly more likely to
already be installed, which matters given lain's degrade-when-missing idiom. And `skim`-as-a-library
remains rejected for the reasons in §6.4.

The honest read: **the popup route is the best value** — it reuses machinery lain already has,
needs no binding, and sidesteps the Reline problem instead of solving it. `nucleo-matcher` earns
its place when the picker must work outside tmux, or when matching moves in-process for the
command palette and history search too.

### 5.7 tmux control mode (`-CC`) — popups, and the HUD problem it exposes

Checked because §5.6a leans on tmux popups. The existing degrade is correct, and the check
surfaced a **larger** problem than the one it was aimed at.

**Popups under `-CC`: confirmed broken, and now permanently so.** Control mode is a text
protocol — pane content ships as `%output <pane-id> <data>` so the client draws it natively, but
anything the tmux *client* draws as an overlay (popups, menus, `choose-tree`, copy-mode UI, the
status line) has no notification to travel on. There is no `%popup`, `%menu`, or `%overlay` in the
notification set. The tmux wiki states it plainly: *"output generated by tmux itself (for example
in copy or choose mode) is not sent to control mode clients."*

What is new: **tmux PR #4361, "Add support for popups to control mode" — authored by gnachman,
iTerm2's own maintainer — was closed unmerged on 2026-06-07**, with nicm's rationale *"I don't
want to add anything further to popups now that floating panes are there."* This is not a gap
waiting to be filled; upstream has ruled.

**The failure shape justifies lain's detect-before-touching design.** Verified live against a
piped `tmux -C` client: `display-popup -E` returns `%begin`/`%end` with **zero output and exit
status 0**, *and the command still executes* — `display-popup -E "echo RAN > /tmp/f"` wrote the
file. So a naive caller gets success, the side effect happens, and the human sees nothing, with no
`%error` to catch. That is precisely why `TmuxSurface#popup` degrades **before** touching the
server (`tmux_surface.rb:17-20`) rather than trying to handle an error afterwards — there is no
error to handle.

**The bigger finding: the tmux status line does not render under `-CC` either.**
`set-option -t <session> status-right` **succeeds and stores the value**, but tmux never draws or
transmits a status line to a control client — verified, nothing arrives on the wire when it
changes. iTerm2 substitutes **native UI gated on a user preference** (*"the status bar will
contain the same content as the tmux status bar… When disabled, the status bar defined in the
profile… will be used"*), with a longstanding open issue
([#10603](https://gitlab.com/gnachman/iterm2/-/work_items/10603)) about it not showing at all.

**So `lain up`'s HUD — the surface the 2026-07-11 ruling designated as *primary* — is silently
invisible under iTerm2 `-CC` unless a preference lain does not control happens to be on.** That
materially weakens "tmux is the persistent surface" on macOS, and it compounds §1.3: on that
platform there is *no* surface reporting a blocked approval.

The robust seam exists and is what iTerm2 itself uses: **`refresh-client -B`** subscriptions push
format changes to a control client at most once per second, independent of any drawn status line.
Verified live: `%subscription-changed sr $0 @0 0 - : HUD-MARKER-CHANGED`. If the HUD must work
under `-CC`, that is the mechanism — not `status-right`.

**Floating panes are the upstream successor** (tmux 3.7, expanded in 3.8; `new-pane -O` for
modal) and are **structurally visible to control mode** — verified: a floating pane is a real pane
with an id, streams `%output`, and appears inside the `<...>` group of `%layout-change`. Whether
iTerm2 parses that layout extension is **UNVERIFIED**; no release note mentions it. Needs a live
check before depending on it, and a 3.7 version guard plus the window fallback regardless.

**Two corrections to carry:** control mode is **no longer iTerm2-only** — WezTerm implemented it
([PR #6602](https://github.com/wezterm/wezterm/pull/6602)) and inherits the same overlay
limitation, since it is a property of the protocol. lain already gets this right by keying on
`#{client_control_mode}` rather than on iTerm2 (`tmux_surface.rb:22-29`). And `display-message`
*was* extended to work for control clients in 3.7, arriving as `%message` — a viable one-line
transient notice under `-CC`, which is a possible home for the missing approval signal.

## Part 6 — Rust crates for `ext/lain`

Surveyed 2026-07-28 against the crates.io API. Throughout, **"pure"** means *verified from the
crate's required-dependency list and feature table* — no async runtime, no I/O, no terminal
ownership — **not** from its docs. Three crates in this survey advertise "returns a String" and
still link terminal drivers; two advertise TUI/animation and are provably clean. The docs lie;
the dependency graph doesn't.

### 6.1 The two headline findings

**`skim` is not usable as a library — but `nucleo-matcher` is, and it's what we actually want.**
`skim` 5.6.1 installs `#[global_allocator] mimalloc` **from the library crate**, hard-depends on
`tokio`, `ratatui`, `crossterm` (with `use-dev-tty`), `portable-pty`, and `nix`, and its `run()`
is `async`. It owns a terminal and an allocator inside our process. `nucleo-matcher` 0.3.1 is
upstream-documented as *"purely functional with no I/O or threading"*, deps are `memchr` +
`unicode-segmentation`, gives fzf query syntax free via `Pattern::parse` (`^prefix`, `suffix$`,
`'substring`, `!negated`) and returns highlight spans. Used by Helix, nushell, mise. **We want
the matcher, not the UI** — Ruby owns the terminal — so this is a strictly better fit than the
thing that was asked for. (`fuzzy-matcher`, skim's own matcher crate, was **archived 2026-01-22**.)

**A starship-compatible renderer is far smaller than expected: the entire DSL is 1,712 bytes.**
This materially upgrades Option D in §5.1. `src/formatter/spec.pest` is ISC-licensed and four
productions deep:

```pest
expression   = _{ SOI ~ value* ~ EOI }
value        = _{ text | variable | textgroup | conditional }
variable     = { "$" ~ (variable_name | variable_scope) }
textgroup    = { "[" ~ format ~ "]" ~ "(" ~ style ~ ")" }
format       = { value* }
style        = { (variable | string)* }
conditional  = { "(" ~ format ~ ")" }
escaped_char = { "[" | "]" | "(" | ")" | "\\" | "$" }
```

`conditional` is the only non-obvious construct: a parenthesized group **elides entirely if
every variable inside it is empty**. That one rule is what makes starship configs read well,
and it is why no generic templating engine substitutes — `tera`, `handlebars`, `liquid`,
`minijinja`, `upon`, `strfmt`, `tinytemplate`, `dynfmt`, and `runtime-fmt` were all checked and
**none expresses span-scoped styling *or* elide-if-empty**.

Implementation is four small objects, **~600–900 lines including specs**: a parser (hand-rolled
recursive descent at zero dependencies is genuinely reasonable at four productions, or `pest`
takes the grammar nearly verbatim); a style parser (`"bold red"`, `"fg:#ff0000"` → `anstyle::Style`,
~100 lines); an evaluator, `(AST, vars, color_mode) -> String`; and a `toml`+`serde` `from_str`
loader, with Ruby reading the file. Every crate needed is already Tier 1.

> **The architectural line that makes it work:** `NO_COLOR`, `FORCE_COLOR`, `isatty`, and
> `TERM=dumb` are properties of the stream **Ruby owns**. Pass a resolved `color:` flag across
> the boundary and render unconditionally. The renderer stays a pure
> `(format, vars, color_mode) → String` — the same purity property `Context#render` relies on,
> and the reason every rejected styling crate below is rejected.

Also sharpened: starship's `pub mod formatter` **is** public, but `StringFormatter::parse`
returns `Vec<Segment>` where `Segment` lives in a **private** `mod segment` — the public API
leaks a private type, so it is unusable downstream regardless. And starship 1.26.0 carries **43
normal dependencies** (`gix`, `rayon`, `clap`, `jiff`, `nix`, `shadow-rs`…). No crate anywhere
implements a starship-compatible format DSL; all 11 `starship`-named crates were enumerated.

### 6.2 Tier 1 — bind first

| Crate | Version (date) | License | Pure | Features | Buys |
|---|---|---|---|---|---|
| `bpe` / `bpe-openai` | 0.2.1 / 0.3.0 (2025-05-07) | MIT | ✅ | default | **Exact context-budget arithmetic over a growing Timeline** |
| `tiktoken-rs` | 0.12.0 (2026-06-02) | MIT | ✅ | default; **never** `async-openai` | Correctness oracle for the above |
| `nucleo-matcher` | 0.3.1 (2024-02-20) | **MPL-2.0** | ✅ | `unicode-segmentation` | fzf-quality fuzzy matching, headless |
| `anstyle` | 1.0.14 (2026-03-13) | MIT/Apache-2.0 | ✅ | default (**zero** runtime deps) | Style value types; substrate for everything |
| `similar` | 3.1.1 (2026-05-23) | Apache-2.0 | ✅ | `text`, `inline`, `unicode` | Diffing, incl. intra-line emphasis |
| `diffy` | 0.5.1 (2026-07-19) | MIT/Apache-2.0 | ✅ | `std`, `color` | Colored unified diff → String |
| `unicode-width` | 0.2.2 (2025-10-06) | MIT/Apache-2.0 | ✅ | default (`no_std`, zero deps) | Correct width math |
| `unicode-segmentation` | 1.13.3 (2026-06-01) | MIT/Apache-2.0 | ✅ | default | Grapheme iteration |
| `unicode-truncate` | 2.0.1 (2026-01-15) | MIT/Apache-2.0 | ✅ | default | **The statusline primitive** — width-aware truncate/pad |
| `strip-ansi-escapes` | 0.2.1 (2025-01-14) | Apache/MIT | ✅ | default (sole dep `vte`) | Measuring already-styled text |
| `rust-stemmers` | 1.2.0 (2019-11-17) | MIT/BSD-3 | ✅ | default | Better `bm25` recall |
| `stop-words` | 0.10.0 (2026-02-21) | MIT/Apache-2.0 | ✅ | default | Ditto |
| `toml` + `serde` | 1.1.3 (2026-07-14) | MIT/Apache-2.0 | ✅ | `parse`, `serde` | Config parsing (`from_str` only) |

**`bpe` is the standout, and it answers Part 4's hardest gap.** Context-usage % was the metric
with no reachable holder. `bpe`'s API is *shaped like lain's problem* rather than merely fast at
it: `count_till_limit(text, limit)` early-exits without tokenizing the remainder;
`appendable_encoder`/`prependable_encoder` count **incrementally as a Timeline grows at either
end**; `interval_encoding` counts arbitrary sub-ranges; and it splits after exactly *n* tokens at
a character boundary — **an exact compaction boundary**. Rule #2 holds on the merits: incremental
prefix counting in Ruby means O(n) re-tokenization per turn. `bpe-openai` embeds
`cl100k_base`/`o200k_base` at build time via `include_bytes!` (verified: no network in `build.rs`).
Keep `tiktoken-rs` as the property-test oracle — the same dual-implementation discipline as the
Ruby/Rust `Timeline` rule. Note the Anthropic count-tokens endpoint stays authoritative for
billing; local counting is for *display* and *budget decisions*.

**Two Tier-1 caveats worth carrying.** `nucleo-matcher` brings **MPL-2.0**, our first
non-permissive dependency — static linking into a `.so` is fine under §3.3, but it deserves a
recorded decision. And its `Matcher` carries ~135 KB of reusable scratch with every method taking
`&mut self`, so the wrapped object is **not `Ractor.shareable?`**. Hold one across calls and
cross the boundary in batches (rule #4).

### 6.3 Tier 2 — plausible, not yet

| Crate | Version | License | Features | Promote when |
|---|---|---|---|---|
| `ratatui-core` + `ratatui-widgets` + `tachyonfx` | 0.1.2 / 0.3.2 / 0.25.1 | MIT | `std`; `default = []` | lain grows a genuine full-screen mode |
| `syntect` (+ `two-face`) | 5.3.0 / 0.5.1 | MIT | `default-features = false` + `default-syntaxes`, `default-themes`, **`regex-fancy`** | Code blocks get styled |
| `pulldown-cmark` | 0.13.4 | MIT | `default-features = false` | Agent markdown gets rendered |
| `tabled` | 0.21.0 | MIT | `default-features = false`, `std`, `ansi` | A concrete table need appears |
| `image` + `icy_sixel` | 0.25.10 / 0.5.0 | MIT/Apache-2.0 | codecs only; **`rayon` off** | Images matter |
| `anstyle-parse`, `textwrap` | 1.0.0 / 0.16.2 | MIT/Apache-2.0 | `default-features = false` | Width/wrap proves hot per-turn |

**The TUI verdict softened on evidence.** ratatui 0.30's workspace split made `ratatui-core`
viable: its complete required-dep list is `bitflags`, `compact_str`, `hashbrown`, `itertools`,
`kasuari`, `lru`, `strum`, `thiserror`, and the unicode trio — **no crossterm, termion, termwiz,
or libc in any feature combination**, `default = []`, `no_std`-capable. `Widget::render(self,
area, &mut Buffer)` never touches a terminal, so you allocate a `Buffer`, render, and serialize,
skipping `Terminal`/`Backend` entirely. `tachyonfx` (official ratatui org, `ratatui`/`crossterm`
as **dev-deps only**) exports `buffer_to_ansi_string(&Buffer, bool) -> String`. Two caveats:
[ratatui#1634](https://github.com/ratatui/ratatui/issues/1634) asked for a blessed
render-to-string API and was **closed without one**, so that function is incidental — hand-rolling
SGR over `Buffer.content` / `Cell` (all public) is ~100 lines and equally supported; and
`TestBackend`'s `Display` is a snapshot format that wraps lines in quotes and **drops all
styling** — never build on it. Still *not yet*: a chat transcript is a linear stream, not a
screen. But the door is open and cheap, which it wasn't before 0.30.

**`termimad` is the trap in the markdown row.** Its pure-string path is genuinely I/O-free, but
**crossterm is a non-optional dep** and it **pins `unicode-width` 0.1.11** — the pre-0.2 model,
reintroducing exactly the emoji bug the unicode trio exists to fix. Take `pulldown-cmark` plus
our own ~200-line renderer instead; owning the renderer also makes the ANSI theme a swappable
strategy, which is the bench's deliverable. And syntect's embedded defaults **lack TOML,
TypeScript, and Dockerfile** — all of which appear in agent chat — so `two-face` (bat's curated
set, fully embedded, no bat process model) follows immediately.

### 6.4 Rejected, with reasons

| Crate | Reason |
|---|---|
| **`skim`** | `#[global_allocator] mimalloc` from the *library* crate; non-optional tokio/ratatui/crossterm/portable-pty/nix; `run()` is async |
| `viuer` | Prints to stdout **and** reads stdin (kitty `\x1b_G…a=q` query, DA1 `\x1b[c`); `ReadKey` is `pub(crate)` so the writer-generic path can't rescue it |
| `indicatif` | Owns output *and timing*; `hidden()` discards rather than captures; the only capture path pulls `vt100`, a whole terminal emulator |
| `termwiz` | `render_to_string` **does not exist**; hard-requires `libc`, `nix`, `termios`, `terminfo`, `signal-hook` |
| `comfy-table` | `custom_styling` (its ANSI-width feature) **transitively re-enables `tty`** → crossterm. Can't have both. `tabled` can |
| `console` / `crossterm` / `colored` / `ansi_term` | Terminal ownership, tty detection, global state; or unmaintained with an advisory |
| `kitty-image` | **LGPL-3.0** — a real problem for a statically linked native gem. Hand-roll `\x1b_G` framing (~30 lines) |
| `tokenizers` (HF) | **`rayon` mandatory** — a global thread pool inside the Ruby process; also `compile_error!` forbids a bare `default-features = false` |
| `simsimd` / `numkong` | Runtime CPU dispatch → float results differ AVX-512 vs NEON. **A determinism hazard for a study bench** |
| `fuzzy-matcher` | Archived 2026-01-22 |
| **umbrella `ratatui`** | `crossterm` is in its **default** feature set. Depend on `-core`/`-widgets` |
| `bat` | `print_with_writer` can capture, but [#1902](https://github.com/sharkdp/bat/issues/1902) documents it locking `io::stdin()` and deadlocking callers |
| `usearch` | Not a purity problem (`save_to_buffer` is in-memory; "requires disk" is **false**) — the C++/`cxx` toolchain is why it stays out-of-process |
| tree-sitter | Pure, but N languages = N C-building crates (~23M lines of C for ~70) plus ABI 14/15 pain. Too heavy for a gem compiled on the user's machine |
| `cursive`, `syntastica`, `md-tui`, `prettytable-rs`, `inkjet`, `mdcat` | Inverted event loop / network at build time / AGPL / abandoned+RUSTSEC / archived |

### 6.5 Traps that belong in `ext/lain/CLAUDE.md`

1. **Never link Oniguruma into MRI.** Ruby exports **Onigmo** symbols (its Oniguruma fork, merged
   in Ruby 2.0). Linking `onig_sys` collides — and the failure mode is not a link error, it is
   **regex captures silently returning wrong results on Linux but not macOS**. This bites
   `syntect` (default `default-onig`) and `comrak` (default `syntect-onig`); both need
   `default-features = false` + a pure-Rust backend. Same shelf as the `Ractor.shareable?` warning.
2. **Prefer `anstyle` over `console` for color, everywhere.** `console::colors_enabled()` inspects
   *the Rust process's* stdout — which the extension does not own. Inside a Ruby harness it can
   silently strip color, and the workaround is process-global mutable state at an FFI boundary.
   **"Is stdout a terminal" is not the same question as "will Ruby print this to a terminal," and
   only Ruby knows the answer.** Two independent research paths converged on this rule.
3. **Purity is decided by the dependency graph, not the docs.** Encode it as a **`cargo deny`
   deny-list** on `crossterm`, `termion`, `termwiz`, `console`, `termcolor`, `terminal_size`,
   `onig_sys` — turning the policy into a build failure instead of a review comment, the same way
   `spec/output_discipline_spec.rb` enforces the Ruby side.
4. **Pin one `unicode-width` major** (`cargo tree -d` clean), and **measure whole graphemes, never
   sum `char` widths** — since 0.2, `str` width is not the sum of its chars (ZWJ sequences → 2,
   Fitzpatrick → 2, `"\r\n"` → 1). Terminal emulators disagree with UAX #11 and with each other,
   so make the width function a **swappable strategy** (bench-shaped) and never let width be
   load-bearing for Journal correctness — display only.
5. **MPL-2.0 enters with `nucleo-matcher`** — record the decision.
6. **Wrapped objects carrying scratch buffers are not `Ractor.shareable?`** (`nucleo`'s `Matcher`,
   `image` decoders). Treat the shareability spec as each binding's acceptance test.
7. **`[profile.dev.package.fancy-regex] opt-level = 3`** — fancy-regex is "absurdly slow in debug
   mode"; add this before anyone concludes syntect is too slow to use.

---

## Part 7 — Open questions for Joel

1. **Snapshot or ticking?** (§5.2) Snapshot honors three standing rulings; ticking revisits all
   three. This is the single biggest fork in the document.
2. **Whose prompt renderer?** (§5.1) Starship shell-out is fastest to a prototype; a Rust
   in-process renderer is architecturally cleaner now that `ext/lain` is widened, and avoids
   every trap in the table. oh-my-posh is the answer if *layering on the user's config* is a
   hard requirement.
3. **Which modal-editing design?** (§5.3) Recommendation: **4 + 5** together — Reline vi as the
   free floor, edit-in-nvim-over-RPC as the escape hatch. **6** is the ambitious answer if
   "modal editing in the chat window" is the actual goal rather than "a way to edit long input".
4. **Does the tool-output fix journal, or only fan to views?** (§1.1) Given the correction, my
   read is views-only.
5. **Does `lain up --nvim` warn, or inject its own plugin onto rtp?** (§1.2)
6. **Does the four-bug fix ship as its own chunk** ahead of the UX work? Three of the four are
   small; 1.4 is a live bug that breaks `--resume`.

---

## References

**Internal — code** (all `/home/joel/dev/lain`, grounded 2026-07-28)
`lib/lain/frontend/tty.rb` · `lib/lain/frontend/decorators.rb` ·
`lib/lain/frontend/neovim.rb`, `neovim/journal_view.rb`, `neovim/resender.rb`,
`neovim/rpc_thread.rb`, `neovim/runtime.lua` · `lib/lain/cli/wiring.rb` ·
`lib/lain/cli/live_views.rb` · `lib/lain/cli/chronicle.rb` · `lib/lain/cli/journal_tee.rb` ·
`lib/lain/cli/repl.rb` · `lib/lain/cli/conductor.rb` · `lib/lain/cli/up.rb`, `up/cockpit.rb`,
`up/hud.rb` · `lib/lain/cli/sessions.rb` · `lib/lain/cli/resume/selector.rb` ·
`lib/lain/cli/watch.rb` · `lib/lain/cli/command/ruby.rb`, `command/status.rb`,
`command/registry.rb` · `lib/lain/status_feed.rb` · `lib/lain/approval/queue.rb` ·
`lib/lain/notify.rb` · `lib/lain/sink.rb` · `lib/lain/journal.rb` · `lib/lain/tools/bash.rb` ·
`lib/lain/agent/accounting.rb` · `lib/lain/context_window.rb` · `lib/lain/compaction/need.rb` ·
`plugin/nvim/lua/lain/init.rb`, `plugin/nvim/plugin/lain.lua` · `plugin/tmux/scripts/lain-status`

**Internal — specs that constrain change**
`spec/lain/status_feed_spec.rb:234` (exact key set) · `spec/lain/frontend/tty_spec.rb:182,191,206,215,224`
(exact `"> "` prompt), `:233` (byte-identical non-tty), `:60-67` (alt-screen start/end) ·
`spec/lain/frontend/decorators_spec.rb:20` (literal ANSI red) ·
`spec/lain/cli/up_spec.rb:270-274,388-389,478` · `spec/plugin/tmux_plugin_spec.rb:54-57`
(JQ_FILTER byte-for-byte) · `spec/plugin/nvim_plugin_spec.rb:266-275` ·
`spec/output_discipline_spec.rb`

**Internal — prior planning**
`planning/interface-integration.md:336-436,484-508` (the three rulings, inputrc/vi mode, the
prompt-buffer idea) · `planning/specs/chunk-ui-ux-tmux-nvim.md` (24 landed cards; §666-667 the
inbox over-count) · `planning/specs/chunk-fixes-xdg-resume-signals.md:1132-1178` (countdown
ownership, the PTY probe) · `planning/specs/chunk-meet-supervision-fanout-interface.md:959-977,1188-1210`
(follow-ups: exe composition smoke, live-HUD inbox over-count, W3 fleet undercount) ·
`references/oss-inspiration.md` · `~/.claude/plans/jiggly-greeting-avalanche.md:126-145,877-893`
(output discipline; Interface section) · `ROADMAP.md:556-717` (§ Interface & UX; the `[exp]`
lines for lualine, approvals list-buffer, Reline autocomplete, the nvim `buftype=prompt` arm) ·
`TODO.md:7-21` · `DEBUGGING_OLLAMA.md`, `DEBUGGING_NVIM.md`

**External — starship**
[docs.rs/starship](https://docs.rs/starship/latest/starship/) ·
[crates.io](https://crates.io/crates/starship) ·
[src/lib.rs](https://github.com/starship/starship/blob/master/src/lib.rs) ·
[src/context.rs](https://github.com/starship/starship/blob/master/src/context.rs) ·
[src/modules/custom.rs](https://github.com/starship/starship/blob/master/src/modules/custom.rs) ·
[config-schema.json](https://github.com/starship/starship/blob/master/.github/config-schema.json) ·
[starship.rs/config](https://starship.rs/config/) ·
[starship.rs/advanced-config](https://starship.rs/advanced-config/) ·
config layering [#6555](https://github.com/starship/starship/issues/6555),
[#565](https://github.com/starship/starship/issues/565),
[#5525](https://github.com/starship/starship/issues/5525),
[PR #6894](https://github.com/starship/starship/pull/6894) ·
performance [#6804](https://github.com/starship/starship/issues/6804),
[#6519](https://github.com/starship/starship/issues/6519),
[#5593](https://github.com/starship/starship/issues/5593)

**External — prompt alternatives**
[oh-my-posh](https://github.com/jandedobbeleer/oh-my-posh) ·
[oh-my-posh `extends`](https://ohmyposh.dev/docs/configuration/general) ·
[powerlevel10k](https://github.com/romkatv/powerlevel10k) ·
[transient prompt #316](https://github.com/romkatv/powerlevel10k/issues/316)

**External — neovim embedding**
[firenvim](https://github.com/glacambre/firenvim) ·
[firenvim SECURITY.md architecture](https://github.com/glacambre/firenvim/blob/master/SECURITY.md) ·
[nvim api-ui-events](https://neovim.io/doc/user/api-ui-events/) ·
[nvim api.txt / nvim_ui_attach](https://neovim.io/doc/user/api.html) ·
[nvim remote.txt / E5600](https://neovim.io/doc/user/remote/) ·
[nvim tui.txt / startup-tui](https://neovim.io/doc/user/tui.html) ·
[nvim channel.txt / prompt-buffer](https://neovim.io/doc/user/channel.html) ·
[neovim#1777 embedding nvim in a REPL](https://github.com/neovim/neovim/issues/1777) ·
[bfredl/Neovim.jl src/repl.jl](https://github.com/bfredl/Neovim.jl/blob/master/src/repl.jl) ·
[vscode-neovim](https://github.com/vscode-neovim/vscode-neovim) ·
[neovide CLI reference](https://neovide.dev/command-line-reference.html) ·
[neovim-remote](https://github.com/mhinz/neovim-remote) ·
[neovim-ruby](https://github.com/neovim/neovim-ruby)

**External — line editing**
[ruby/reline](https://github.com/ruby/reline) (read from installed 0.6.3) ·
[bash Miscellaneous Commands](https://www.gnu.org/software/bash/manual/html_node/Miscellaneous-Commands.html) ·
[bash bashline.c](https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/bashline.c) ·
[zsh edit-command-line](https://github.com/zsh-users/zsh/blob/master/Functions/Zle/edit-command-line) ·
[fish edit_command_buffer.fish](https://github.com/fish-shell/fish-shell/blob/master/share/functions/edit_command_buffer.fish)
