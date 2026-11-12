# Scenario: herdr, agent state and resume

**What it exercises:** `Herdr::Target::Resolver` (which pane lain may report to), `Herdr::Reporter` (`pane report-agent`,
`pane release-agent`, `pane report-metadata`), `Herdr::Focus`, `Frontend::Focus.for`, `Up#record_herdr_pane` (the tmux
session option `@lain_herdr`), `CLI::HerdrLink` and `plugin/herdr/herdr-plugin.toml`, `CLI::HerdrSurface` and
`CLI::WindowSurface` (windows and popups as herdr tabs), and `CLI::Watch`'s own reporter for a watched child.

**Status:** written 2026-11-11 from the code at HEAD (`5100c953`: `lib/lain/herdr/*.rb`, `cli/herdr_link.rb`,
`cli/herdr_surface.rb`, `cli/window_surface.rb`, `cli/up.rb`, `cli/watch.rb`, `cli/wiring/herdr_binding.rb`,
`frontend/focus.rb`). Nothing here has been driven. Every "Expect" is a prediction read off the code and off the plan's isolated
probes against herdr 0.9.5, so a mismatch is either a defect or a stale line in this file, and the round says which.

**The question it answers:** when lain runs inside herdr, does herdr show the truth about it (state, why it is blocked, how to
resume it), does it keep showing nothing wrong about anything else in herdr, and does lain stay silent and spawn nothing when
herdr is not there? **The rule the plan set, and the thing every section here checks:** lain never changes how herdr treats
Claude Code. It writes herdr's configuration only on `lain herdr link`, reports only for a pane it can prove is its own, and
never overwrites a pane another agent holds.

**Cost:** cheap for §0 to §3, §5, §6, §8 and §9 on the stub (no model beyond 1 or 2 short asks, a local model is enough). §4, §7
and §10 need an isolated real herdr 0.9.5 and are the minutes-long ones.

**Needs:** `../bench.md` up, tmux, nvim for the cockpit. Read `../method.md` first and build the sandbox with
`.claude/skills/manual-qa/scripts/qa-sandbox.sh`. Start each Bash call that touches files with `: "${QA:?}"`.

---

## 0: The instruments, and the isolation rule

**Never point a round at the user's own herdr.** Their `~/.config/herdr/config.toml` carries a `$parked` row for Claude Code, a
Claude integration hook and a live Claude pane. Every section below runs against one of two things, and says which:

1. **The stub** (below): a shell script on a temp path that logs its argv and answers canned JSON. It is the default, it
   touches nothing, and it can be made to say anything, including that a pane belongs to Claude.
2. **An isolated real herdr 0.9.5**: its own `--session` AND its own `XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_DATA_HOME`
   under `$QA`. The session name alone is not isolation, because `plugin link` writes the config directory and a running plugin
   pane writes `$XDG_STATE_HOME/herdr/plugins/<id>/`. lain's calls reach the server named by the `HERDR_SOCKET_PATH` the pane
   hands it, so the socket is what isolates `report-agent`; `lain herdr link|unlink|status` run a bare `herdr` with no socket,
   so for those the `XDG_CONFIG_HOME` is the only wall.

```bash
: "${QA:?}"
mkdir -p $QA/shim $QA/xdg/config $QA/xdg/state $QA/xdg/data
REAL_HERDR="$(command -v herdr)"        # resolved BEFORE the shim goes on PATH
cat > $QA/shim/herdr-iso <<EOF2
#!/bin/sh
# refuses to run unless the XDG dirs are the sandbox's, so a forgotten export cannot reach the user's herdr
case "\$XDG_CONFIG_HOME" in "$QA"/*) ;; *) echo "herdr-iso: XDG_CONFIG_HOME is not under \$QA" >&2; exit 97;; esac
exec "$REAL_HERDR" --session lain-qa "\$@"
EOF2
chmod +x $QA/shim/herdr-iso
stat -c '%n %Y' ~/.config/herdr/config.toml ~/.config/herdr/plugins > $QA/user-herdr.before 2>&1
```

`stat` reads, it never writes. Repeat it at the end into `user-herdr.after` and `diff` the two: a changed mtime on the user's
config or plugin directory means the round touched the user's herdr, and the round stops there and says so. Start the isolated
herdr in a pane of a tmux server of its own (`tmux -L qa-herdr`) with the 3 XDG variables exported and run
`$QA/shim/herdr-iso` there, so its TUI has a terminal. Open 2 panes in it by whatever the 0.9.5 CLI offers (`herdr-iso pane
split`, or the keys); record the ids, called A and B below.

**The stub**, for every section marked "stub":

```bash
cat > $QA/shim/herdr <<'EOF2'
#!/bin/sh
echo "$(date +%s) $* [sock=$HERDR_SOCKET_PATH]" >> "$QA/herdr.calls"
case "$1 $2" in
  "agent get")
    if [ -f "$QA/herdr.holder" ]; then
      printf '{"id":"cli:agent:get","result":{"agent":{"agent":"%s","agent_status":"working","focused":%s,"pane_id":"%s"},"type":"agent_info"}}\n' \
        "$(cat "$QA/herdr.holder")" "$(cat "$QA/herdr.focused" 2>/dev/null || echo false)" "$3"
    else
      echo '{"error":{"code":"agent_not_found","message":"agent target not found"},"id":"cli:agent:get"}' >&2; exit 1
    fi;;
  "plugin list")
    if [ -f "$QA/herdr.linked" ]; then echo '{"result":{"plugins":[{"plugin_id":"lain","enabled":true}]}}'
    else echo '{"result":{"plugins":[]}}'; fi;;
  "plugin pane") echo '{"result":{"plugin_pane":{"pane":{"pane_id":"w1:p5","tab_id":"w1:t5"}}}}';;
  "tab list") echo '{"result":{"tabs":[]}}';;
  *) echo '{}';;
esac
EOF2
chmod +x $QA/shim/herdr
```

`herdr.holder` holds the agent name `agent get` reports for the pane (absent: the pane is free, answered as herdr 0.9.5 does,
`agent_not_found` on stderr with exit 1). `herdr.focused` holds `true` or `false`. `herdr.linked` makes `plugin list --json`
name lain. `herdr.calls` is the record every "stub got" below reads, one line per call with its epoch second. Make the plugin
list, the holder and the focus answers by `touch` and `rm`, so a section can flip them mid-chat.

**A chat the stub believes is in a herdr pane** (a "plain herdr pane", `via :env`) is launched from a tmux pane with the tmux
variables removed, because a tmux pane always has them and a chat with `TMUX` set reads only a cockpit's record:

```bash
env -u TMUX -u TMUX_PANE HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH=$QA/shim/herdr \
  HERDR_SOCKET_PATH=$QA/herdr.sock lain chat --provider ollama --model qwen3-coder:30b
```

A cockpit (`via :cockpit`) is `lain up` launched the same way (`env -u TMUX -u TMUX_PANE HERDR_ENV=1 ... lain up $QA/proj`, from
a pane of an outer tmux, with `-L "$QA_SOCK"` for the cockpit's own server). Say in the round which of the two you drove.

## 1: Outside herdr, lain makes no herdr call and starts no herdr process

**Happy path.** Put `$QA/shim` first on `PATH` and set `HERDR_BIN_PATH=$QA/shim/herdr`, but leave `HERDR_ENV` unset, and run: a
plain `lain chat` in a bare terminal, `lain up` in plain tmux, an ask, `/park note`, `/fork`, a parked approval and a
finished subagent. Expect `$QA/herdr.calls` to stay empty (absent counts as empty) and no process named `herdr` ever started
(`ls /proc/*/comm` is not needed; the empty call log is the evidence, since only the stub can run).

**Unhappy path 1, a scripted chat in herdr.** `HERDR_ENV=1` with all 3 paths set, and `lain chat --non-interactive --prompt hi`.
Expect no call: a scripted run is never a herdr agent of its own, whatever `HERDR_*` says.

**Unhappy path 2, half a herdr.** `HERDR_ENV=1` but `HERDR_SOCKET_PATH` empty, or `HERDR_PANE_ID` empty. Expect no call and no
note.

**Unhappy path 3, a plain tmux pane that inherited herdr's variables.** From a tmux server started inside a herdr pane, run
`lain chat` in a tmux pane that is not a cockpit's chat pane. Expect no call: with `TMUX` set the chat reads only the cockpit
record, and an inherited pane id is the id of whatever started tmux.

**Unhappy path 4, the missing binary.** `HERDR_ENV=1`, the 3 paths set, `HERDR_BIN_PATH` naming a file that does not exist. The
chat starts, asks work, and nothing crashes. The ownership probe cannot run, so expect 1 note on the chat's warning line saying
herdr did not answer and lain will not report to that pane this chat, and no later note.

## 2: State and resume reach herdr, in order

Stub, `via :env` (a plain herdr pane), `herdr.holder` absent. In 1 chat:

1. Start the chat and wait. Expect exactly 1 call: `agent get w1:p1`, the ownership check, once for the whole chat.
2. Ask a short question. Expect `pane report-agent w1:p1 --source lain --agent lain --state working --seq N1`, then when the ask
   settles `... --state idle --seq N2`. herdr 0.9.5 has no `done`, so a finished agent is reported `idle` and herdr shows it as
   done until the pane is focused. `N2 > N1`, and both are nanosecond-epoch numbers, so a restart of lain still beats the last
   one herdr kept.
3. The resume command rides each report, after a bare `--`: `-- lain chat --root <project root> --cwd <cwd> <the flags you typed> --resume <session file name>`. The file is named by its basename, which `--resume` resolves under the pinned root, so the command works from any directory: run the stored words from another directory with the stub's `HERDR_*` unset and expect the same session to resume. A flag you typed (a `--model`, an `--approval ask`) is in the command; `--resume`, `--fork` and `--prompt` from the live run are not.
4. `/mode ask`, ask for a `bash` call, and leave it parked. Expect `--state blocked --message <the wait's summary>`. Approve it:
   a `working` report follows, with no `--message`, and the idle one at the end.
5. Ask the same question again. Expect no report for a change that does not change `(state, message)`: a call count that
   grows without a state change is a defect.
6. `/quit`. Expect exactly 1 `pane release-agent w1:p1 --source lain --agent lain --seq N` and nothing after it.

**The cockpit's resume command is different.** Stub, `via :cockpit` (`lain up` launched with the 3 `HERDR_*`, TMUX empty). In the
cockpit's chat pane expect the report to end `-- lain up <cwd> --session <the tmux session name> [--socket <name>] [--no-nvim or
--nvim-socket=<path>] -- <the chat's own arguments> --resume <session file name>`, so a herdr restart puts the whole cockpit back,
not a bare chat, on the same tmux socket, with the same nvim choice and the same flags. Launch the cockpit with a non-default
`--socket`, `--no-nvim` and `-- --approval ask` to see all three ride along. `lain up` stores those words once, when it creates
the session, in the tmux session option `@lain_up_command` (JSON; read it as in §3), and a reattach with other flags does not
change it. The input pane, the nvim pane, a `/fork` window and a
fleet window of that cockpit make no herdr call (their `TMUX_PANE` is not the chat pane): check by running a `/fork` and
reading the log.

Automated by `spec/lain/seams/herdr_resume_spec.rb`, which feeds the stored words through the resume selector for both a cockpit and a plain chat, and `spec/lain/herdr/reporter_spec.rb` for the refusals.

**Unhappy path 1, a pane another agent holds.** `echo claude > $QA/herdr.holder`, then start the chat. Expect 1 `agent get`, 1
note on the warning line, `herdr: pane w1:p1 belongs to claude; lain will not report there`, and NO `report-agent`,
`release-agent` or `report-metadata` call for the whole chat, including at `/quit`. Then `echo lain-dev-3f2a > $QA/herdr.holder`
and start again: a name starting `lain-` is lain's own, so reporting works. Then a holder `agent get` answers with no name:
the note reads `belongs to an agent herdr does not name`.

**Unhappy path 2, a resume lain will not store.** herdr keeps the command in a file and types it into the restored pane's shell, so a
secret in it would outlive the chat. Each of these sends the state reports with no `-- ...` resume command on any of them, and
1 note on the warning line, `herdr: no resume command is stored for this chat (<reason>); herdr cannot restart it`, however many
reports follow (a refused report would lose the state too, so the state still goes):

- a project root or flag word holding an apostrophe (`mkdir "$QA/it's"`): `a word of its command holds an apostrophe`;
- a flag word carrying URL credentials (`--base-url http://user:pw@127.0.0.1:11434`): `a word of its command carries a URL credential`;
- more than 64 words or 8 KiB of command: `its command is over 64 words` or `over 8192 bytes`;
- a cockpit whose stored command is missing or not JSON (`tmux set-option -t <session> @lain_up_command garbage`): `the cockpit stored no command to restart it with`.

Check the stored command's words for the credential and confirm 0 hits of `pw` in `$QA/herdr.calls`.

**Unhappy path 3, herdr fails.** One at a time: a stub `report-agent` that exits 1; one that sleeps 5; then the chat with the
stub removed mid-chat. Expect the asks to complete at normal speed (the reporter works on its own thread, with a 2 second
timeout), exactly 1 note `herdr: reporting to pane w1:p1 failed; lain retries on the next change` however many reports fail,
and, once a later call succeeds, a second failure notes again. The note appears on the screen's own warning line and never in
the middle of a typed prompt: type half a line, let a report fail, and the half line must survive.

**Unhappy path 4, the secret in a wait.** Park a call whose summary holds a value from `OLLAMA_API_KEY` (as `notifications.md` §6
plants one). The `--message` argument holds the masked form and 0 hits of the value, and no control byte.

**Unhappy path 5, nothing else.** `grep -E 'herdr:|integration|config|server|plugin' $QA/herdr.calls` over a whole chat that
reports, blocks, finishes and quits finds nothing. The only verbs are `agent get`, `pane report-agent`, `pane release-agent`
and, after a `/park`, `pane report-metadata`. A chat that opens a window adds the plugin verbs of §8, and no others.

**Unhappy path 6, a kill.** `kill -9` the chat. No `release-agent` is sent. On the isolated herdr (§4), record what herdr keeps
showing for the pane: lain cannot clean up after a kill, and herdr may drop the agent when the pane's process ends. The record
is the finding.

**On a real herdr (isolated, §0).** Do 1 to 6 once with `HERDR_BIN_PATH` and `HERDR_SOCKET_PATH` as the pane gives them, and read
the result with `herdr-iso agent list` and `herdr-iso agent get <pane>`. Expect the agent named `lain`, `agent_status` moving
`working`, `blocked`, `done` (the shown name for a reported `idle` until focus), and gone after `/quit`. `herdr-iso agent wait
<pane> --until blocked` returns when lain parks (the spike measured 2.6 s). `agent get` showed no `--message` and no stored
resume command in the spike, so do not fail a round for their absence; record what the sidebar shows by eye or screenshot.

## 3: The cockpit records the pane it was attached from

`lain up` launched with the 3 `HERDR_*` and TMUX empty writes the cockpit's herdr pane into the tmux session option
`@lain_herdr`, so the chat pane can report to it. Read it with `tmux -L "$QA_SOCK" show-options -t <session> -v @lain_herdr`:
a JSON object with `bin`, `pane` and `socket`.

- **Happy path.** The option names the pane `lain up` ran in, with the binary and the socket it was given.
- **Reattach from another herdr pane.** Detach, `lain up` again from pane B with its own `HERDR_PANE_ID`: the option now names B, and a
  new state report goes to B, not A.
- **Reattach from a plain terminal.** `lain up` with no `HERDR_ENV`: the option is unset (`show-options -v` prints nothing), and the
  chat stops reporting (`release-agent` for A once, if it still held a report).
- **Unhappy path, a nested `lain up`.** From a shell inside the cockpit (so `TMUX` is set, and a herdr pane's variables are
  inherited from the OUTER client), run `lain up`. The option is neither written nor cleared. A nested launch inherits the
  outer client's `HERDR_*`, and recording them would aim the chat at the wrong pane.
- **Unhappy path, a stale record.** Set the option by hand to a pane that herdr says another agent holds (stub holder `claude`):
  the chat reports nothing and notes it once. The record is a hint, and the ownership probe is the check.
- **Unhappy path, a recorded value that is not JSON.** `tmux set-option -t <session> @lain_herdr garbage`: no report, no crash.
- **The command that rebuilds the cockpit.** The session also holds `@lain_up_command`, a JSON array of the words after `lain` that
  `lain up` was started with (`up <cwd> --session <S>`, then `--socket`, `--no-nvim` or `--nvim-socket=` where given, then `--` and the
  chat's own arguments). Read it with `show-options -v @lain_up_command`. It is written when the session is created and not on a
  reattach.

## 4: A herdr restart brings lain back (isolated real herdr only)

Needs a lain cockpit running in an isolated herdr pane, after one ask so the session file exists, and `resume_agents_on_restore`
on (its default). The plan expects herdr to rerun the resume command it stored from the last report.

- **Happy path.** Stop the isolated herdr server by the stop verb `herdr-iso --help` lists (never any other herdr: kill by the
  server that owns `$QA/xdg/...`'s socket), then start it again with `herdr-iso`. Expect the layout back with fresh shells and
  lain's pane running `lain up <cwd> --session <S> <the socket and nvim flags the cockpit was built with> -- <its chat arguments> --resume <session file name>`. Record the pane's process list, and compare the flags with what you launched (a non-default `--socket` and `--no-nvim` must survive).
- **Which `lain`.** herdr runs the first word through ITS own `PATH`. Record which `lain` that is (`type -a lain` from a shell
  started the way the herdr pane starts), because the cockpit's own panes use the launcher path from `$PROGRAM_NAME` and herdr
  uses the bare name. A different install, or none (`command not found` in the pane), is a finding for the plan's integration
  check 4, not something to work around.
- **The tmux session may have survived.** The cockpit's tmux server is not a child of herdr's server. If session S still
  exists, `lain up ... --session S` reattaches and ignores `--resume`, because the chat is already running. Record which of
  the two happened (survived and reattached, or recreated and resumed), and that the resumed chat's first notice names the
  session.
- **After the restart lain reports again.** A new `working` report with a `--seq` above the old pane's last (nanosecond clock),
  or herdr drops it as stale: the round states which.
- **Unhappy path, a command herdr must not store.** With the project under a root holding an apostrophe, or a flag word carrying URL
  credentials (§2), no resume command was ever sent, so the pane returns as a plain shell. Record it; it is the documented cost of herdr's argv rule.
- **Unhappy path, a closed session.** `/quit` the chat, then restart herdr. The agent was released, so herdr has nothing to
  resume: the pane returns plain, and no `lain` starts by itself.
- **Detached tmux.** Do this once more after `tmux detach-client`: see §10.

## 5: `/park` inside herdr sets lain's own token

`repl-commands.md` §11 owns `/park` itself. The herdr half, on the stub and then the isolated herdr:

- **Happy path.** `/park waiting on CI` in a reporting chat. Expect `pane report-metadata w1:p1 --source lain --agent lain --token
  lain_parked=waiting on CI --seq N` and, from the same command, the feed record `parked: waiting on CI` at once. On the isolated
  herdr, read the pane with `herdr-iso pane get <pane>` (read-only) and look for the token if 0.9.5 shows tokens.
- **No token named `parked`, ever.** The user's Claude setup draws a `$parked` row from a token of that exact name. `grep -c
  'token parked=' $QA/herdr.calls` must read 0 after every variant here. lain's is `lain_parked`.
- **Unhappy path 1, clearing.** `/park` with no text. Expect `report-metadata ... --clear-token lain_parked` and no feed record.
  If the isolated herdr refuses a clear, record what it printed (the plan expects an empty value as the fallback).
- **Unhappy path 2, a pane lain does not hold.** With the holder `claude` (§2 unhappy 1), `/park x` sends the feed record and no
  `report-metadata` call: the token would land on Claude's pane.
- **Unhappy path 3, herdr fails.** The stub exits 1 on `report-metadata`: the reply is still `noted: ...` and the chat goes on.
- **Unhappy path 4, a secret.** The token value and the feed body hold the masked text, never the secret.

## 6: Focus inside herdr needs the right witness

The delayed notices of `notifications.md` §7 skip a window the human is at. Inside herdr that question has 2 witnesses, and which
one counts depends on where the chat runs. Stub, `attention delay: 5`, a settled ask left unattended, and `herdr.focused` set per
row. Watch whether `notify-feed` is called after the delay.

| Where the chat runs | tmux says the chat window is active | herdr says focused | Expect |
|---|---|---|---|
| cockpit inside herdr | yes (client attached) | true | skipped, `done:1` clears |
| cockpit inside herdr | yes | false | sent |
| cockpit inside herdr | no | true | sent |
| plain herdr pane (`TMUX` empty) | not asked | true | skipped |
| plain herdr pane | not asked | false | sent |
| plain tmux, no herdr | yes | not asked | skipped; the stub log has no `agent get` |

**Unhappy path.** The stub's `agent get` exits 1 during the probe: the answer is "not focused" and the notice is sent, because
the safe side of not knowing is ringing. A probe that raises into the chat is a defect.

**What to read.** `herdr.calls` should hold 1 `agent get` for the ownership check at the start and 1 more each time a notice falls
due, and none while nothing is due. Probes at every poll mean the loop asks too early.

## 7: Claude Code beside lain, and lain started from Claude's bash

**This section never runs anything against the user's own Claude pane.** The setup is in the isolated herdr of §0, with a stand-in
for Claude: in pane A, `herdr-iso pane report-agent A --source herdr:claude --agent claude --state working --seq 1`, plus a
`parked` token on A (`herdr-iso pane report-metadata A --token parked=waiting`). If the isolated herdr refuses that source, use
whatever source the 0.9.5 Claude integration documents, and say which. The stand-in's shell is "Claude's bash".

**7a: Claude and lain side by side.** `lain up` in pane B of the same isolated herdr. Drive an ask, a blocked approval, a finish,
a `/park` and a `/quit` in B.

- **Happy path.** `herdr-iso agent list` shows 2 agents, `claude` on A and `lain` on B, each with its own state. `herdr-iso agent
  get A` before and after the whole run is identical in `agent`, `agent_status` and `state_change_seq` (the `revision` may move
  only if Claude's own pane changed). A's `parked` token is still there.
- **Unhappy path 1, lain never touches A.** The calls lain made all name pane B's id. A call naming A is a defect: write down the
  line.
- **Unhappy path 2, claude is working while lain parks.** `herdr-iso agent wait B --until blocked` returns when lain parks and
  does not return because of A.

**7b: lain started from Claude's bash.** In pane A, whose shell inherits `HERDR_ENV=1` and A's `HERDR_PANE_ID`, run:

- `lain chat --non-interactive --prompt hi`. **Happy path:** it answers and exits, and made 0 herdr calls (stub: `herdr.calls`
  empty; real: `agent get A` unchanged). A scripted run is never a herdr agent.
- `lain chat` (interactive) started in A. **Unhappy path, the dangerous one:** the candidate pane is A, `agent get A` names
  `claude`, so lain makes exactly 1 `agent get` and then nothing. Expect the note `herdr: pane <A> belongs to claude; lain will
  not report there`, and after an ask and `/quit`, A's state, its stored resume command and its `parked` token are all as they
  were. A `report-agent` or `release-agent` call naming A is the worst finding this scenario can make: stop the round and report it.
- **The bash child.** In a lain chat anywhere in herdr, ask the model to run `env | grep -c HERDR` (a stub provider may script
  the call). Expect `0`: the 4 `HERDR_*` names are stripped from every bash child, so a model's command cannot report into
  lain's pane or any other.

**7c: the user's own herdr, a manual pass by the user only.** The plan's integration check 4 asks for it. It is read-only unless
the user decides otherwise: with Claude Code running in one real pane and `lain up` in another, run `herdr agent get <Claude
pane>` before and after, and compare. A driver does not type into Claude's pane, does not run `lain chat` from Claude's bash on
the user's behalf, and does not run `report-agent`, `release-agent` or `report-metadata` against any pane of the user's herdr.
Record the comparison the user reports.

## 8: `lain herdr link`, and windows in a plain herdr pane

**8a: link, status, unlink.** The commands run a bare `herdr` from `PATH`, so run them with the XDG variables of §0 exported and
`$QA/shim/herdr-iso` as `herdr` on `PATH` (copy it to `$QA/shim/herdr` for this section only), or on the stub.

- **Happy path.** `lain herdr link` prints `linked <gem root>/plugin/herdr` and the stub got `plugin link <gem root>/plugin/herdr`
  and nothing else. `lain herdr status` prints what `herdr plugin list` prints (the stub: `plugin list`, no flags).
  `lain herdr unlink` prints `unlinked lain`, the stub got `plugin unlink lain`. On the isolated herdr the link record appears
  under `$QA/xdg/config/herdr` and disappears on unlink; `diff` the directory listing before and after to prove it.
- **Unhappy path 1, no herdr.** With no `herdr` on `PATH`, `lain herdr link` exits 1 saying `herdr was not found on PATH` and writes
  nothing (the XDG tree is unchanged).
- **Unhappy path 2, herdr refuses.** A stub that exits 1 with a message on stderr: exit 1, `herdr plugin link ... failed: <stderr>`.
- **Unhappy path 3, lain never links by itself.** Run a whole chat, a `/fork` and `lain up` with the plugin unlinked. The call
  log holds no `plugin link` and no `plugin unlink`: only `lain herdr` writes herdr's configuration.

**8b: `/fork` and `chat --windows` in a plain herdr pane.** Stub or isolated herdr, `via :env`, `TMUX` empty, the plugin linked
(`touch $QA/herdr.linked`, or really linked).

- **Happy path, `/fork`.** After 1 ask, `/fork` replies `forked into <kind> <target>: lain chat --fork <selector>`; record the kind and target a herdr tab shows. The
  log shows `plugin pane open --plugin lain --entrypoint run --placement tab --cwd <project> --env LAIN_RUN_COMMAND=... --env
  LAIN_RUN_STATUS=...` (a fork does not ask to keep a failed pane, so predict no `LAIN_KEEP_FAILED`; record it) and a `tab
  rename w1:t5 fork-xxxxxxxx`. On the isolated herdr a labelled tab appears running the
  forked chat, which opens on the same session.
- **Happy path, `--windows`.** `lain chat --windows` starts in the plain herdr pane without refusing. A subagent task opens a
  tab labelled `<role>-<hex>` that runs `lain watch`, and when the child ends the tab is renamed `<name> done`. A child that
  fails keeps its pane (`LAIN_KEEP_FAILED=1`) and the status file the plugin writes holds the exit status.
- **Happy path, `/btw`.** It asks for `--placement popup` with the sizes. Then edit the stub's `plugin pane` arm to exit 1
  printing `ui_busy` when `--placement popup` is among its arguments: a window opens instead, and the placement is degraded
  with reason `ui_busy`. Any other popup refusal degrades with reason `popup_unavailable`.
- **The plugin list is asked at most once.** `grep -c 'plugin list' $QA/herdr.calls` reads 1 after 2 forks, and 0 in a chat that
  opened no window, at launch and afterward. It is `plugin list --json`, read-only, and is the only plugin verb outside
  `lain herdr`.
- **Unhappy path 1, not linked.** `rm $QA/herdr.linked`, new chat. `/fork` writes 1 note `herdr: lain's plugin is not linked, so
  windows open in tmux only; lain herdr link would open them in herdr`, then says it could not open a window and prints the
  command to run by hand (`not inside tmux or a herdr pane with lain herdr link, so no window can open here; run the fork
  yourself: ...`). A second `/fork` repeats the sentence but not the note. `lain chat --windows` is refused at launch with
  `--windows opens panes in the tmux session this process is already inside, and $TMUX is not set -- start tmux first, run lain in
  a herdr pane with lain herdr link done, or drop --windows`, and no journal is left behind.
- **Unhappy path 2, the cockpit keeps tmux.** In a cockpit inside herdr (`via :cockpit`), `/fork` opens a tmux window in the
  cockpit's own session, whatever the plugin state, so forks stay with their cockpit. `herdr tab list` is unchanged and the log
  holds no `plugin pane open`.
- **Unhappy path 3, a tab that cannot open.** A stub `plugin pane open` that exits 1, or prints something unreadable: `/fork`
  answers with the error and the printed command, and the session is not damaged. The reply names herdr, not a tmux error.
- **Unhappy path 4, outside herdr.** With no target, `/fork` in plain tmux still opens a tmux window and the log is empty.
- **After `lain herdr unlink`** the next chat's `/fork` falls back to the unlinked sentence above.

## 9: A watch tab reports its child under its own name

`FleetWindows` opens `lain watch <selector>` in a herdr tab for each child. In that pane `HERDR_ENV` and `HERDR_PANE_ID` are set
and `TMUX` is empty, so the watch is a chat-like reporter for one agent.

- **Happy path.** Watch a child C (role `dev`, spawn digest starting `3f2a`) in a herdr tab while it works, blocks on `bash` and
  finishes. Expect `--source lain --agent lain-dev-3f2a` with states `working`, `blocked`, `working`, `idle`, no `--`
  resume command, and `pane release-agent` for that tab's pane when the watch ends. The `--message` of the blocked report is the
  wait's masked summary. A role-less spawn is named from its prefix, or `lain-child-<hex>` when it has neither.
- **Two tabs, one role.** 2 children of the same role show under 2 names in `herdr-iso agent list`; the 4 hex characters of the
  digest are what tell them apart.
- **Unhappy path 1, a watch in a tmux window.** In a cockpit's fleet window `TMUX` is set, so no herdr process is spawned: the log
  is empty for the whole watch.
- **Unhappy path 2, nothing matched.** `lain watch` on a file whose spawn never appears reports nothing and releases nothing.
- **Unhappy path 3, a pane held by claude.** A watch started in a pane the stub says claude holds makes 1 `agent get`, notes it,
  and reports nothing.
- **Unhappy path 4, the rollup is not the child's.** The watched file's chat may be blocked for another reason; the watch reports
  only the watched child's own state, never the file's rollup.

## 10: Detaching the cockpit while herdr runs

**Isolated real herdr, a cockpit in pane A, one ask done so lain has reported.**

- **Happy path.** `tmux detach-client`. Record, for each of: the herdr pane A (still there, shell, or closed), `herdr-iso agent
  list` (is `lain` still listed, and in what state), and the chat (still running inside the detached tmux session, answering
  `/status` over `tmux send-keys`). The plan leaves this as "record what herdr shows".
- **Reports to a pane that is gone.** If A closed, ask another question from a second attach of the same session (a plain
  terminal). The chat's report goes to the recorded pane A, which no longer exists. Expect at most 1 note
  `herdr: reporting to pane <A> failed; lain retries on the next change`, no crash and no slowdown.
- **Reattach from another herdr pane B.** `lain up` from B. The option names B (§3), and the next state change reports to B: the
  call log or `agent list` shows `lain` on B. The old pane gets a `release-agent` that may fail quietly.
- **Unhappy path, a plain-terminal reattach** clears the option, and no further herdr call is made.

---

## What this scenario cannot answer

- **Whether herdr's sidebar looks right.** The CLI answers (`agent get`, `agent list`) are checkable; the sidebar's rendering,
  the toast and the sound are not, and a screenshot is the only evidence. A herdr 0.9.5 `agent get` showed neither the message
  nor the stored resume command in the spike, so a restart's resume (§4) is checked by what comes back, not by reading the
  command.
- **The user's real Claude setup.** §7c is a read-only comparison the user makes. No driver does more.
- **herdr versions after 0.9.5.** The plugin manifest asks for 0.9.5 or newer, and every shape here was probed on 0.9.5 only.
- **Windows or macOS.** Linux only, as for every scenario here.
