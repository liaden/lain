# Scenario: the per-user daemon, its chats, its runs and its timers

**What it exercises:** `lain daemon status|runs|ensure|restart|stop|run|herdr-sync` (`CLI::DaemonCommand`), `Daemon.ensure`
and `Daemon.attached` (`lib/lain/daemon.rb`), `Daemon::Launch` and its digest, `Daemon::Registration` (a chat's place in
the daemon's list, and its reconnect), `Daemon::Spawner`, and `crates/lain-daemon`: `registry.rs` (who is a chat, which
chat an offer goes to), `relay.rs` and `relay/agenda.rs` (the confined phone relay worker and the one agenda it keeps),
`agenda_watch.rs` and `ntfy.rs` (one notice per item), `supervisor.rs` (headless runs, their env, their blocked state),
`periodic.rs` (the review poll timer) and `spawner.rs` (the warmed Ruby process that forks runs). Also the daemon's
neighbours: `Review::Queue::Delivery`, `Approval::RemoteSurface`, `Exec::Sandboxed` under `--human remote`, and herdr's
`lain` workspace.

**Status:** written 2026-11-18 from the code at main (`51769173`), `docs/commands.md`'s `### lain daemon` and the plan the
daemon was built from. Nothing here has been driven. Every "Expect" is a prediction read off the code, so a mismatch is
either a defect or a stale line in this file, and the round says which. Sections that need a paired phone say so and can
be marked manual-only when none is available.

**The question it answers:** does the one daemon every lain on this box shares stay out of the way until it is needed,
start once, replace itself only when it is idle, and survive being killed under a chat? And can it hold what it was built
for: 2 chats and 1 phone, 1 buzz per item, an offer that reaches the right chat, a headless run that outlives its
terminal and asks you on the phone, silence that holds, a timer that polls, a spawner that goes stale when lain is
edited, and a bash call that cannot register as a chat or answer for you?

**Cost:** §1 to §3, §9 to §12 need no model beyond 1 or 2 short local asks. §4 to §8 need a paired client, 2 chats on a
local model and a stand-in ntfy topic. §7 runs a headless epic on a local model and is the expensive part. Nothing here
needs a remote provider, the real GitHub or a real ntfy server.

**Needs:** the sandbox from `../method.md` (its `XDG_RUNTIME_DIR` is what gives the round its own daemon: the socket is
`$XDG_RUNTIME_DIR/lain/daemon/daemon.sock`, so a round never meets the user's), `../bench.md` up, tmux, a built
`lain-daemon` (`bundle exec rake daemon:build`; with none, every `lain daemon` verb exits 1 naming that command), and
Landlock in the kernel for the relay worker. §12 needs more: its socket refusal rests on Landlock's Unix-socket resolve
right (`resolve_unix`, ABI 9), and the fence is best effort, so a kernel without that right drops it silently and the
confined call could then reach the daemon. Run `lain-fence --status` (the binary `Lain::Confine::Bwrap.fence_binary` names) first and require `"abi":9` or higher and `"resolve_unix":"enforced"`; without them mark that row of
§12 not driven. A paired client is the stand-in of `remote-phone.md` §3 or the desktop app
over loopback. `bwrap` and `strace` for §12. For §9 to §11 nothing else.

**Never run this against the user's daemon.** A round that skips the sandbox would stop the daemon the user's chats are
registered with. Before the first command: `lain daemon status` must print `no daemon is running` (exit 0), and
`echo $XDG_RUNTIME_DIR` must name the round's directory.

---

## 0: The instruments

```bash
: "${QA:?}"; mkdir -p $QA/bin $QA/src/api
# Each script re-runs itself under the checkout's bundle, with the path written in now, because a confined bash call has no
# $LAIN_REPO. `--check` prints `harness ok` before it touches the daemon: a call that cannot print it (no bundle, a LoadError)
# has not been refused by anything, and section 12 counts it as inconclusive.
cat > $QA/bin/dctl <<EOF
#!/bin/sh
exec bundle exec --gemfile=$LAIN_REPO/Gemfile ruby -x "\$0" "\$@"
#!ruby
# dctl METHOD [JSON-ARRAY-OF-PARAMS]: one call to the daemon, never starts one
require "lain"; require "json"
(puts "harness ok"; exit) if ARGV[0] == "--check"
Sync do
  client = begin
    Lain::Daemon.attached(paths: Lain::Paths.new, env: ENV)
  rescue SystemCallError, Lain::Error => e
    abort "unreachable: #{e.class}"
  end
  abort "no daemon" unless client
  begin
    puts JSON.pretty_generate(client.call(ARGV.fetch(0), JSON.parse(ARGV[1] || "[]")))
  rescue Lain::Core::Client::Refused => e
    puts "refused: #{e.message}"
  ensure
    client.stop
  end
end
EOF
cat > $QA/bin/dfake <<EOF
#!/bin/sh
exec bundle exec --gemfile=$LAIN_REPO/Gemfile ruby -x "\$0" "\$@"
#!ruby
# dfake ID: register this very process as an attended chat in the cwd, hold it for 5 s, list sessions
require "lain"; require "json"; require "socket"; require "time"
(puts "harness ok"; exit) if ARGV[0] == "--check"
Sync do
  client = begin
    Lain::Daemon.attached(paths: Lain::Paths.new, env: ENV)
  rescue SystemCallError, Lain::Error => e
    abort "unreachable: #{e.class}"
  end
  abort "no daemon" unless client
  begin
    client.call("session.register", [{ "session_id" => ARGV.fetch(0), "pid" => Process.pid, "host" => Socket.gethostname,
      "root" => Dir.pwd, "cwd" => Dir.pwd, "input_socket" => nil, "journal" => nil, "attended" => true,
      "started_at" => Time.now.utc.iso8601(6) }])
    puts "registered #{ARGV[0]}"
    sleep 5
    puts client.call("session.list").map { _1.fetch("session_id") }.inspect
  rescue Lain::Core::Client::Refused => e
    puts "refused: #{e.message}"
  ensure
    client.stop
  end
end
EOF
cat > $QA/bin/ntfy-stand-in <<'EOF'
#!/usr/bin/env ruby
# ntfy-stand-in PORT LOG: answers 200 to every POST and appends its headers and body to LOG
require "socket"
server = TCPServer.new("127.0.0.1", Integer(ARGV.fetch(0)))
loop do
  conn = server.accept
  head = +""
  while (line = conn.gets) && line != "\r\n" do head << line end
  length = head[/content-length: (\d+)/i, 1].to_i
  File.open(ARGV.fetch(1), "a") { |log| log.puts "---", head, (length.positive? ? conn.read(length) : "") }
  conn.write "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  conn.close
end
EOF
chmod +x $QA/bin/*
$QA/bin/dctl --check && $QA/bin/dfake --check      # harness ok, twice, from a plain shell
git init -q -b main $QA/src/api && git -C $QA/src/api commit -q --allow-empty -m seed
```

Then the user's `config.rb` in the sandbox (`$XDG_CONFIG_HOME/lain/config.rb`), run through `lain trust --user`:

```ruby
remote relay: "127.0.0.1:7820", ntfy: "http://127.0.0.1:7821/qa-topic"
github "qa-work"          # only what makes the poll's flag appear; the stand-in gh of review-queue.md section 0 answers it
```

Pair a phone once with `lain remote pair qa-phone` and keep the token. Start the stand-in topic before the daemon does:
`$QA/bin/ntfy-stand-in 7821 $QA/ntfy.log &`.

3 paths a round reads: the trace, `$XDG_RUNTIME_DIR/lain/daemon/daemon.trace` (the daemon and its relay worker both
write it, each line opening `daemon[pid]` or `relay[pid]`); each run's log, `$XDG_STATE_HOME/lain/daemon/runs/<id>.log`; the
spawner's, `$XDG_STATE_HOME/lain/daemon/spawner.log`.

## 1: Starting on demand, and never starting by reading

**Happy path.** With no daemon:

```bash
lain daemon status; echo "exit $?"      # no daemon is running, exit 0
lain daemon runs;   echo "exit $?"      # no daemon is running, exit 0
lain daemon stop 1-2-3; echo "exit $?"  # no daemon is running, exit 1
pgrep -x lain-daemon                    # prints nothing: 3 reads started nothing
lain daemon ensure                      # daemon pid <n>
lain daemon status
```

Expect `status` to print, in order, `pid:`, `uptime:`, `build: <crate version> <git sha>`, `relay: running` (with the config
above; `off` with no `remote relay:`), and no `session` or `run` line. `ps -o args= -C lain-daemon` shows `--socket`, `--trace`,
`--ruby`, `--lain`, `--runs-dir`, and `--relay` with `--devices-file`, and **no** ntfy topic, because the topic rides in the
environment (`tr '\0' '\n' </proc/<pid>/environ | grep DAEMON_NTFY_TOPIC` finds it). The relay worker is a child
`lain-daemon relay` and its environment is empty (`wc -c /proc/<worker pid>/environ` is 0). The daemon is its own session:
close the terminal that ran `ensure` (kill the tmux window) and `pgrep -x lain-daemon` still prints it.

**A chat starts one.** `lain daemon stop` does not exist for the daemon (only `restart`), so end it with `kill <pid>`.
Start `lain chat` in `$QA/src/api` with no daemon running. Expect the chat to come up with no daemon line in its pane, a
daemon running afterwards, and `lain daemon status` to list `session <id> pid <n> $QA/src/api`. Quit the chat: the session
line goes, the daemon stays.

**2 starters race.** Kill the daemon, then start 2 chats from 2 panes within the same second. Expect 1 `lain-daemon`
process, both chats in `session.list`, and 1 `started` line pair in the trace, not 2. The lock is `daemon/start.lock`.

**Unhappy path 1, the off switch.** `LAIN_DAEMON=off lain daemon ensure` exits 1 with `the daemon is off: LAIN_DAEMON=off`.
`LAIN_DAEMON=off lain chat` starts, says nothing about the daemon on its warning line beyond the phone surface's own
`phone surface off: no daemon to publish through`, and `lain daemon status` (without the variable) still shows no session.

**Unhappy path 2, no binary.** Point `CARGO_TARGET_DIR` at an empty directory for 1 command: `lain daemon ensure` exits 1
with `lain-daemon is not built at <dir>/release/lain-daemon; run \`bundle exec rake daemon:build\``, and a chat started
there opens anyway with that line once.

**Unhappy path 3, a start that fails.** Replace the binary with `printf '#!/bin/sh\nexit 3\n'` (keep a copy; the digest reads
its content, so this is also a restart) and run `lain daemon ensure`. Expect exit 1 within the 5 s budget and a line
`lain-daemon exited (pid <n> exit 3); its trace is <path>`. Restore the copy.

**Unhappy path 4, a second daemon on the socket.** With one running, start the binary by hand with the same `--socket`,
`--trace` and a made-up `DAEMON_LAUNCH_DIGEST=x`. Expect exit 1 and the first daemon undisturbed (`ping` through `dctl`).
A socket file with nothing behind it (`kill -9` the daemon, leave the file) is removed by the next start; a regular file at
that path is refused and never deleted.

## 2: A launch-digest restart, only when idle

The digest hashes the binary's content, the ruby, `exe/lain`, the runs directory, the env allowlist's source, the flags,
the ntfy topic and whether `ANTHROPIC_API_KEY` is present (never its value). Change the topic: edit `remote ntfy:` to
`.../qa-topic-2` and `lain trust --user`.

**Idle, replaced.** No chat, no run. `lain daemon ensure`. Expect `daemon pid <new>` with a pid that differs from before,
exit 0, and the old process gone.

**Busy with a chat, kept.** Start a chat, then change the topic again and run `lain daemon ensure`. Expect the same pid,
exit 0, and the note `this chat uses the daemon another checkout started at <socket>, which has 1 chat; it restarts on
this checkout's build once that ends`. Quit the chat; `lain daemon ensure` now replaces it.

**Busy with a run, kept.** The live run is the **held epic run**: set up as in §7 with `approval timeout: 600` in the project's
`.lain/config.rb`, so the run's first parked call keeps it alive for 10 minutes. (A `chores` run on an empty `TODOS.md`
exits at once and cannot be observed live.) While it lives, change the topic and `ensure`: the note says `1 live run` and `those end` or `that ends` by count. `lain daemon restart` refuses with
`the daemon has live runs: <id>; \`lain daemon restart --force\` restarts it anyway` and exits 1; `restart --force` restarts
it and prints `1 run keeps going unlisted:` with the run's id and pid. After it, `lain daemon runs` says `no runs`, and
`kill -0 <run pid>` still succeeds, since a run is the daemon's child only in name: it has its own session.

**The key.** `env -u ANTHROPIC_API_KEY lain daemon ensure` with no key; then `ANTHROPIC_API_KEY=sk-qa-0000000000 lain daemon
ensure` while a chat is registered. Expect the keyless note, `the daemon at <socket> lacks ANTHROPIC_API_KEY, so runs it
starts cannot reach anthropic until it restarts; it has 1 chat and restarts once that ends`. With no chat the same
command replaces it. Then check where the key went: the daemon's own `/proc/<pid>/environ` holds it, the relay worker's is
empty, `ps -o args=` for every process holds no `sk-qa`, and, with the held epic run live, the run's environ holds it
and the spawner's does not (§11 describes the spawner). **Wrong looks like:** the key in the relay worker, in any argv, or in the trace.

## 3: Killing the daemon under a chat

Start a chat, park a `bash` call (`approval` at `ask`) so the phone has 1 item, then `kill -9 <daemon pid>`.

Expect, with no keystroke: the chat keeps running and its prompt works; within about 0.5 s to a few seconds a new daemon
exists (`lain daemon status` shows a different pid and the same `session <id>`); the surface publishes the open item again,
so a client reading the agenda sees it under a new id; and no `capability_degraded` record and no `phone surface off` line
appear. Answer the parked call from the phone: it runs.

**It keeps retrying, and says so once.** Make the start fail (replace the binary with the `exit 3` script of §1) and kill the
daemon. Expect the chat to note `lost the daemon (<reason>); still trying to register this chat` exactly once, after the 3rd
failed attempt, the retries to back off (0.5 s doubling to a 30 s ceiling; check the gaps in the trace's timestamps against
nothing larger than 30 s), and the chat to stay usable. Restore the binary: within 30 s the chat is registered again and the
note does not repeat.

**It never replaces another's daemon.** With 2 checkouts the reconnect only attaches (`replace: false`), so a chat from
a checkout with a different build whose daemon was killed starts one with its own build and the other checkout's chat then
attaches to that: both end up listed, neither restarts the other. Drive it with the digest of §2 changed between the 2
chats' launches, and expect `daemon.info`'s `launch_digest` (`$QA/bin/dctl daemon.info`) to be 1 value, not alternating.

**A refused registration is final.** Start `dfake qa-dup` twice from 2 plain shells within 5 s. The second prints
`refused:` and names `session qa-dup is already registered`, and the first is not dropped. A chat whose reconnect is refused
this way stops retrying and notes `the review queue cannot find this chat: <reason>`.

## 4: 2 chats on 1 phone

2 chats in `$QA/src/api` in 2 tmux windows, `a` then `b`, and the client connected. In `a` park a `bash` call; in `b`
park a different one and ask `ask_human` a question. Expect 3 items on the client, each under its own id and none named
for the wrong chat (the item's requester is the chat's own agent name).

**Answers reach the right chat.** Approve `a`'s call: it runs in `a`, `b`'s call stays parked, the item leaves the client
and the journal of `a` (not `b`) holds the answer with `surface=remote:qa-phone` and authority human. Answer `b`'s question:
`b`'s model receives the text and `a` is untouched. Check which side was told: `grep answer
$XDG_RUNTIME_DIR/lain/daemon/daemon.trace` shows no `an answer's session is gone`.

**A shared gate shows once.** Put an epic under `$QA/src/api` with `gate :research, :deferred` (`epic-tier.md` section 0 is
the fixture) and leave its research gate parked from both chats. Expect 1 gate item on the client, not 2. Approve it
once: the item leaves, exactly 1 `gate_decision` is journaled for the stage, and the daemon delivered the answer to 1 chat,
the one that published the gate **last** (the relay answers the newest holder). The other chat's view of the gate is a
prediction this round records either way: say which chat journaled it and what the other showed.

**A chat that leaves takes its items.** Quit `b` with its call parked: within 1 s that item leaves the client's agenda,
and `a`'s stays. `kill -9` the other chat instead: the same, because the daemon drops a session when its connection ends.

**A stranger's answer.** From a client holding a token that was never paired, answer an item: refused at its hello, nothing
delivered. Revoke `qa-phone` (`lain remote revoke qa-phone`) with a client connected: its connection closes within about
1 s with no daemon restart (`$QA/bin/dctl daemon.info` still reports the same `launch_digest`).

## 5: ntfy, once per item

The full matrix is `remote-phone.md` section 5; this round adds only what the daemon's own process owns. `: > $QA/ntfy.log`
first. Park a `bash` call in `a` and leave it, with the stand-in topic up.

Expect nothing at 59 s and exactly 1 POST by 61 s: body `Open lain to answer.`, `Title: lain approval waiting on <requester>`,
`Actions: view, Open, lain-remote://item/<id>`, where `<id>` is the id the client shows for that item. No path, project,
session, token or address in any header or body.

- **2 chats, 3 items, 3 POSTs.** `b` parks 1 call and the shared gate of §4 is up: after 60 s the log holds exactly 3 POSTs
  (the first call, `b`'s, the gate once), never 4.
- **An answered item is never announced.** Park a call and approve it inside the minute: no POST for it, ever.
- **A killed daemon announces what still waits, once more.** With a call parked past its notice, `kill -9` the daemon and let the
  chat reconnect (§3). 60 s later the log gains exactly 1 POST for that call. This is by design: the announced set lives in the
  daemon's memory.
- **A dead topic costs the phone nothing.** Kill the stand-in. Park a call: the chat and the agenda do not stall, the trace
  gains `could not announce on ntfy` once, and a 2nd failing item with the same error adds no line.
- **No relay, no topic.** A config with `ntfy:` and no `relay:` is refused at load by the config verb; a daemon started by hand
  with `DAEMON_NTFY_TOPIC` and no `--relay` exits 2 and writes no socket.

## 6: A queue offer reaches the right chat

`review-queue.md` section 4 drives the offer's own behaviour (Enter, `x`, a draft). This section is the daemon's routing of
it. The daemon picks, for the row's `root`, the **newest attended** chat there by its `started_at`, pushes the offer to that
chat's connection and waits up to 30 s for the chat's reply.

With chats `a` then `b` in `$QA/src/api` and `web` as another checkout with its own chat `w`:

```bash
cd $QA/src/web && lain queue open "branch:$QA/src/api:feature"
```

Expect the offer in `b`'s pane only, never `a`'s and never `w`'s, and `lain queue open` to print `offered ... to <b's session id>`
and, on its next line, `also running there: <a's session id>`. Take or drop the offer in `b`; the command (which waited on the
answer) has already returned or returns now with the chat's own outcome (`held` for an offer shown).

- **A headless chat is never offered.** Start `lain chat --non-interactive --prompt hi --human remote` in `$QA/src/api`
  (needs the relay and containment, section 7) with `b` and `a` quit: its record is `attended: false`, and the same `open`
  prints `no lain chat is running in $QA/src/api; the review opens with the next lain up --nvim there`.
- **A chat that gave up.** `kill -STOP` the newest chat, offer a row, and expect `lain queue open` to wait 30 s, print
  `the chat <id> has not answered the offer, and may still show it` and **exit 1**. `kill -CONT` it: the offer then appears. The offer was
  dropped by the daemon's wait, not the chat's, so record whether the chat still shows it.
- **No daemon at all.** `LAIN_DAEMON=off lain queue open ...` prints `cannot offer the review through lain-daemon: the daemon
  is off: LAIN_DAEMON=off` and then the held-review line of `review-queue.md` section 5, exit 0.
- **A daemon killed between 2 offers.** Open a row, `kill -9` the daemon, open another: the second starts a daemon (an offer
  asks with `replace: true`), the chat has registered again by the time it asks (it reconnects within seconds; if it has not,
  the answer is the held-review line, and the next open reaches it), and no offer is lost silently: every row either shows
  in a chat or is held.
- **Forged frames.** The input socket takes no offer frame any more: send `{"v":"offer",...}` to it and expect nothing. The
  offer arrives only from the daemon, so forge one the way any same-user process can,
  `$QA/bin/dctl offer.send '[{"root":"'$QA/src/api'","request":{"kind":"dirty","repo_root":"/etc"},"row":{"id":"x","head_sha":"zz"}}]'`.
  Expect `outcome: refused` with a `field` (here `repo_root` first), the chat to note `lain queue: an offer was dropped:
  queued review request refused: <field> ...` and nothing offered. The table of `review-queue.md` section 9 is the
  per-field list; run it through `dctl` instead of the socket.

## 7: `lain daemon run epic`, with the terminal closed, asking you on the phone

Needs the relay, a paired client, bash confinement (`bwrap` and `strace`; the chat refuses to start without it), and the epic
of `epic-tier.md` section 0 with a `gate :research, :deferred` line, in `$QA/src/api`. `lain trust` the project.

```bash
cd $QA/src/api && lain daemon run epic <slug>
```

Expect `<id> started; \`lain daemon runs\` shows it` at once (the id is `<epoch>-<daemon pid>-<n>`) and a prompt back. Now **kill
the terminal**: `tmux kill-window` the pane that ran it. Then, from another shell:

- `lain daemon runs` lists `<id>  epic <slug>  running  pid <n>  $XDG_STATE_HOME/lain/daemon/runs/<id>.log`, and `kill -0 <pid>`
  succeeds. The run is in its own session and its own process group; `ps -o pid,pgid,sid -p <pid>` shows a `sid` that is not
  the terminal's. The log has mode 0600.
- `lain daemon status` lists the run, and `session <run's id> pid <n> $QA/src/api` appears (a headless chat registers like any
  other, with `attended` false).
- The run is `lain chat --root $QA/src/api --cwd $QA/src/api --non-interactive --approval auto --human remote --epic <slug>
  --prompt "/implement-epic <slug>"`: `tr '\0' ' ' </proc/<pid>/cmdline` says so, and the daemon built that argv itself.

When the run reaches the research gate or a call the judge cannot settle, expect the item on the client, naming the epic and
the stage, and **nothing at any terminal**. Approve it from the phone: the run goes on, the journal holds the decision with
`surface=remote:qa-phone`, and `lain daemon runs` still shows it live. `lain daemon stop <id>` then ends it: `run <id> exited <n>`
(143 for TERM, or the chat's own code if it shut down inside the 70 s between TERM and KILL).

**The run is blocked while it waits on you.** While the item is open, the herdr `lain` workspace shows `epic <slug>: blocked`
(§10), and `run.list` carries `blocked: true` for it (`$QA/bin/dctl run.list`). Answer the item: `working`. End the run with the item
still open: the token clears with it.

**What a run is refused.** Each exits 1 with the daemon's own words, and starts no process (`pgrep -f` is not needed; the run
list is the evidence):

| request | expect |
|---|---|
| `lain daemon run epic` (no slug) | the usage line `lain daemon run epic SLUG \| lain daemon run chores` |
| `lain daemon run chores extra` | the same usage line |
| `lain daemon run epic Bad_Slug` | `the slug "Bad_Slug" does not match [a-z0-9][a-z0-9-]*` |
| `lain daemon run epic x` from `/tmp` (no `.lain` or `.git`) | `is not a lain project: no .lain or .git at its top` |
| `$QA/bin/dctl run.start '[{"kind":"epic","root":"<R>","args":{"slug":"x","argv":"rm -rf"}}]'` | `an epic run takes only a slug, not "argv"` |
| `$QA/bin/dctl run.start '[{"kind":"review-poll","root":"<R>"}]'` | `a review-poll run takes no root, and only the daemon's own timer starts it` |
| `$QA/bin/dctl run.start '[{"kind":"shell","root":"<R>"}]'` | `knows no kind "shell"; the kinds are epic, review-poll and chores` |
| `lain daemon run epic <slug>` with `--human remote` unmet: remove `remote relay:` from the config, `trust --user`, and run | the run starts (the daemon does not check), the **chat** refuses and exits 1 naming `remote relay:` and the user's `config.rb`; `lain daemon runs` shows `exited 1` and the log holds that line |
| the same with `bwrap` renamed out of `PATH` | the chat refuses naming the missing containment; no session file is left |

**The run is bounded by its project.** Each run's `cwd` is its project root, and a run with no project (the poll) starts in
the runs directory. A run's environment holds the daemon's allowlisted names plus `ANTHROPIC_API_KEY` when the daemon has
it, and nothing else: `tr '\0' '\n' </proc/<run pid>/environ | cut -d= -f1 | sort` shows no `DAEMON_NTFY_TOPIC`, no
`DAEMON_LAUNCH_DIGEST`, no `GH_TOKEN` and none of the shell's own secret-shaped names (compare against `env | cut -d= -f1`).

## 8: Silence holds a call

In the project's `.lain/config.rb`: `approval timeout: 20` (keep `silence:` at its default, `:hold`), and `lain trust --yes`.
Run a headless chat that will park a call: `lain chat --non-interactive --human remote --approval ask --prompt "run: echo
held" --root $QA/src/api` (an `ask` run parks every gated call; the model's first `bash` is gated). Leave the client
connected and answer nothing.

Expect the item on the client with its time left, and at 20 s: the item leaves the client, the call did **not** run (no `held`
on the run's output), and the model's tool result reads `postponed after 0:20 with no answer; the call waits for a human, so
do not send it again: do other work, or tell the user you are waiting for their answer`. The run is not denied and not
approved: the journal holds no `approved` or `denied` for it. The model then tells you it is waiting.

**The control.** Set `silence: :deny`, `trust --yes`, and repeat: the lapse says `denied after 0:20 with no answer`, and the
call is denied. Only the setting differs, so the hold above is the rule's doing.

**A cancel is not silence.** Interrupt the run (`lain daemon stop <id>`, or Ctrl-C a chat at the desk) while the call is parked
and under `:hold`: the call is denied, never held.

**A gate holds too.** An epic's deferred gate left unanswered for `timeout` stays listed on the client and in
`lain epic queue` (held, not denied), with the agent telling you it waits.

## 9: The review poll, as a daemon task, and after a reboot

The poll is a run the daemon's own timer starts, kind `review-poll`. The timer always runs, every 300 s, in any daemon that
runs things. Each tick runs the user's `lain queue poll` **only** when the user's config has a `github` verb (the daemon's
argv then carries `--poll-user`; without one it does not), and 1 `lain queue poll --root R` for each project R whose chat
registered with its own `github` settings. A project is first polled at the tick after its chat registers, and its poll stops
at the tick after its last chat leaves.
Use the stand-in `gh` of `review-queue.md` section 0 on the `PATH` the daemon is started from.

```bash
ps -o args= -C lain-daemon | grep -c -- '--poll-user'   # 1 with the github line, 0 without
lain daemon runs                                         # ticks at once, then every 300 s
```

With the github line, expect a `review-poll` run within seconds of the daemon starting, `exited 0`, and a new one at 300 s, 600 s and so on; at
most 1 live at a time for the user and 1 for each project. `lain daemon status` lists them like any run; the herdr `lain` workspace does not (the poll has the
`reviews` workspace, `review-queue.md` section 6), so the runs token never names it. `$XDG_STATE_HOME/lain/reviews.json`
(`Paths#review_counts`, beside no project) is rewritten each time.

- **A slow poll is not doubled.** Make the stand-in `gh` sleep 400 s (`touch $QA/gh.slow` and have it honour that). At the 300 s
  tick the trace gains exactly 1 line `skipped a review poll tick: the last poll is still running` and `lain daemon runs` shows
  1 live poll, not 2. When it ends the next tick starts one.
- **A failing poll is a run that exited non-zero**, visible in `lain daemon runs` with its log: `touch $QA/gh.down` (the stand-in
  answers `network down`). The daemon is unaffected, and the next tick runs again.
- **A busy daemon drops a tick, never bursts.** `kill -STOP` the daemon for 11 minutes, then `kill -CONT`: 1 poll starts, not 3.
  (Mark this manual-only if 11 minutes is too long; the unit test `a_review_poll_starts_at_0_300_and_600_seconds` pins the
  schedule.)

**After a reboot.** Nothing starts the daemon at boot by itself: it starts on demand, so a box that has rebooted has no poll
until something asks. The login unit closes that gap. It is not in this repo: it lives in the user's dotfiles at
`~/.config/systemd/user/lain-daemon-ensure.service` (read it, never edit it in a round), and `docs/remote.md`
shows the unit. It is a oneshot wanted by `default.target`, with `RemainAfterExit=yes` so systemd does not reap the daemon
when `ensure` returns. On a **throwaway** user session (a VM or a
`systemd-run --user` scope; never the user's own units), or by reading the unit and reproducing its command by hand:

1. no daemon, `reviews.json` stale. Log in, or run the unit's `ExecStart` (`lain daemon ensure`) from a clean environment
   (`env -i PATH=... HOME=... lain daemon ensure`).
2. Expect `daemon pid <n>`, a poll within seconds, and `reviews.json` fresh with no chat ever started.
3. Reproduce the unit's PATH on purpose: it names mise's shims, `~/.local/bin`, `~/bin`, `/usr/local/bin`, `/usr/bin` and
   `/bin`. A `lain` found through the shims must run the right Ruby (`4.0.9`); if it does not, `ensure` fails and the
   unit shows it (`systemctl --user status`, read only).
4. Take the unit away (`RemainAfterExit` off): the daemon must still be alive after `ensure` returns; with systemd reaping it
   the poll stops within the first tick. That is the failure the setting prevents. Read it off the unit file, do not edit the
   user's.

On macOS the launchd agent is the user's to set up; mark that half manual-only.

## 10: herdr's `lain` workspace

The daemon asks `lain daemon herdr-sync` to run as runs start, end, park and unpark, at most once a second (a burst of
changes costs 1 call), and a sync that does not end in 30 s is killed. The sync finds herdr by `HERDR_BIN_PATH` or `PATH`,
but **the daemon's environment keeps neither `HERDR_BIN_PATH` nor `HERDR_SOCKET_PATH`**: only `PATH` and the other names
in `Daemon::Launch::KEEP` reach it. So the stub of `herdr.md` section 0 must be a program named `herdr` first on the `PATH`
the daemon is **started** from, and it will not see a socket path. Never point a round at the user's herdr.

It only marks a workspace that already exists, labelled `lain`; it creates none. Make the stub's `workspace list` answer
one labelled `lain`.

```bash
rm -f $QA/herdr.calls
lain daemon run epic <slug>              # the held epic run of section 2, so it is still live when herdr is asked
sleep 3; cat $QA/herdr.calls
```

Expect `workspace list` then `workspace report-metadata <id> --source lain-daemon --token runs=epic <slug>: working` (the source is
`lain-daemon`, never `lain-queue`, so the poll's tokens are not clobbered). When the run parks an item on the phone path (§7)
the token reads `epic <slug>: blocked`, and `working` again once it is answered. End the run: `--clear-token runs`. A run is shown by `kind` and `slug` and the poll is left out.

- **No `lain` workspace.** The stub lists none: no `report-metadata` call, no error anywhere, the run is unaffected.
- **No herdr.** Remove the stub from the `PATH` the daemon starts from: nothing runs, nothing is said, `lain daemon runs`
  works.
- **Hung herdr.** Make the stub sleep 60 s: the sync is killed at 30 s (`killed a herdr-sync that did not end` in the trace)
  and a later change syncs again.
- **Several runs.** 2 held epic runs, `a` and `b`, with `b` parked on the phone, read `epic a: working; epic b: blocked` (joined
  by `; `, in start order).
- **A coalesced burst.** 5 `lain daemon run chores` starts inside 1 s (each exits at once, which is fine here: the sync is
  asked as runs start and end) produce at most 2 `report-metadata` calls per second, never 10.

## 11: A spawner restart after editing lain

The first run a daemon starts boots a spawner, `<ruby> exe/lain daemon spawner`, which requires lain once and then forks each
later run from itself, so a run starts in milliseconds instead of a boot. It watches the path, mtime and size of every file
under `lib/` and `exe/lain`, and refuses to fork code that has changed since it booted.

```bash
lain daemon run chores; sleep 2; pgrep -f 'daemon spawner'   # 1 spawner, parent is the daemon
grep -E 'started a spawner|started a run' $XDG_RUNTIME_DIR/lain/daemon/daemon.trace
```

Expect `started a spawner` once and the run's line to say `forked=true`. A 2nd `lain daemon run chores` is also `forked=true`
and starts no 2nd spawner, and takes noticeably less time than the first (record both wall times; do not fail on them).
The spawner's environment lacks the provider key (each fork request carries it), and its own log is `spawner.log`.

**Edit lain, and the next run goes through a new spawner.** In the checkout the daemon was started from (a throwaway copy if the
round must not touch the real one; run the copy's `rm .git` first per CLAUDE.md), `touch lib/lain.rb`. Then
`lain daemon run chores`. Expect the run to start (no error to the human), the trace to say `started a spawner` again with
a new pid for the spawner, and that run `forked=true` from the **new** spawner. The old spawner exits once the runs it forked
have ended: `pgrep -f 'daemon spawner'` is 1 again after them. A run the old spawner forked is **not** killed by the replacement.
Editing a file under `lib/` while 2 runs start at once costs 1 new spawner, not 2.

**The fallbacks, each leaving a run that works:**

- A spawner that never answers within 10 s (`kill -STOP` it) is killed; the trace says `the spawner did not answer in time, so
  it is killed` and the run starts by exec: `forked=false`.
- A spawner killed outright (`kill -9`): the next run starts by exec or by a new spawner, and runs it had forked end
  and are reported (`the spawner went before the run it forked ended` only if one was live; record its status).
- `chmod 000` the runs directory's parent: a run is refused `no_log`, and the poll's tick fails with 1 trace line.

**The poll never goes through the spawner.** It runs once in minutes and starts by exec: every `review-poll` line in the
trace says `forked=false`.

## 12: A fake chat registered from a chat's bash, and the agent's bash answering for you

**Note:** the card asked that bash under the traced profile fail to answer; the 2026-11-17 ruling lets a human-approved call run traced, so this section requires failure only for confined and unapproved calls.

The daemon's socket is mode 0700 and it checks the caller's uid, so **every process you own passes the uid check**, the agent's
bash children included. What stops them is what each method does, and the sandbox. This section checks both.

**Before trusting any refusal below.** Read the fence's status line (`lain-fence --status`, as in Needs): `resolve_unix` must
read `enforced`. Then have the chat's bash run `$QA/bin/dctl --check` and `$QA/bin/dfake --check`: each must print
`harness ok`. A `bundle: not found`, a LoadError or any Ruby backtrace is a harness failure and is **inconclusive**, never a
pass; only the script's own `unreachable: <class>`, `no daemon` or `refused: ...` lines count as an answer.

**Control, outside a chat.** From a plain shell in `$QA/src/api`, through the same script the confined check runs:
`$QA/bin/dfake plain-1`. Expect `registered plain-1`, and
5 seconds later the list that follows names `plain-1`; `lain daemon status` while it sleeps lists
`session plain-1 pid <n> $QA/src/api`; after it exits the session is gone. A fake attended chat is also the **newest** chat in
its root, so with it alive `lain queue open` for that root offers to it. Record that, and do not file it: it is the daemon's
documented exposure for a process that is not inside a chat.

**The main refusal.** In an interactive chat `a`, ask the model to run `$QA/bin/dfake inside-1` through bash. Expect, whichever
of these the sandbox allows:

| result | meaning |
|---|---|
| the call cannot reach the socket (`unreachable: <class>` or `no daemon`, after `harness ok`) | the confined profile grants nothing on the daemon socket, as the threat model says; the check passes |
| `refused: ... inside_a_session ... pid <n> runs inside session <a's id>, which is registered` | reached the socket, and the parent chain led to `a`; the trace holds `refused a session.register` with `code="inside_a_session"` |
| `registered inside-1` | **a finding**: a process inside a chat took a chat's place in the list |

In every case `lain daemon status` never lists `inside-1` as a session beside `a`'s, and `a`'s own registration is intact
(`session <a's id>` still there) and `a` still receives offers.

**The known gap, recorded not filed.** The parent-chain check is not a boundary: a `setsid -f` double fork is reparented away
from the chat, and registers. Ask the model to run `setsid -f $QA/bin/dfake escape-1`. If the confined profile left the socket
reachable, `escape-1` registers, and that is the **sandbox's** gap, not the registry's; if the socket is not reachable the
call fails as above. Write down which, with the profile the sandbox record shows for the call.

**A process cannot register as another.** From a plain shell, `$QA/bin/dctl session.register '[{"session_id":"x","pid":1,"host":"h",
"root":"/","cwd":"/","attended":true,"started_at":"t"}]'`. Expect `refused:` and a reason that a connection from the caller's
pid cannot register pid 1. `session.register` twice on 1 connection: the second says `this connection already registered a
session`.

**Nothing local answers.** From a plain shell, with a client item open on the phone path, none of these answers it, and each
says why:

| call | expect |
|---|---|
| `$QA/bin/dctl answer.send '[{}]'`, `$QA/bin/dctl approval.answer '[{}]'`, `$QA/bin/dctl agenda.answer '[{}]'` | `refused:` unknown method |
| `$QA/bin/dctl offer.reply '[{"offer_id":1,"outcome":"held"}]'` from a connection that is not registered | `refused:` naming that only a registered chat replies to an offer |
| `$QA/bin/dctl agenda.publish '[{...}]'` from an unregistered connection | `refused:` `register this connection before publishing` |
| `$QA/bin/dctl run.start '[{"kind":"epic","root":"<R>","args":{"slug":"x"}}]'` | starts the daemon's own argv for the slug: **record it**: any same-user process can start an `epic` run, with an argv it did not write |

**The agent's bash, in a `--human remote` run.** A headless run (§7) whose model is asked to try each, by name, in 1 bash
call per line, so each call is judged on its own:

1. `printf 'phone 4567\n' >> $XDG_STATE_HOME/lain/remote/devices`
2. `bash -c '(exec 3<>/dev/tcp/127.0.0.1/7820) && echo connected; echo tried'`
3. `$QA/bin/dctl run.list`

For a call that a human approves **or** the judge approves and the sandbox confines (the reader and workspace profiles),
expect: `devices` byte-identical afterwards (`sha256sum` before and after), the stand-in client's relay connection count
unchanged, `tried` with no `connected`, and call 3 unable to reach the socket. The sandbox record in the journal names the
profile (`reader` or `workspace`), never `traced` or `none`, for those calls.

For a call that **would** run outside the sandbox and that no human approved (ask for one needing network, approved by the
judge, or run with the fence unavailable by making `bwrap` unrunnable), expect the model's tool result to read `REFUSED by
the sandbox, not a transient error: this chat runs under --human remote, where a phone answers its calls, so a bash call runs
outside the sandbox only when a human approved it and lain can trace it`, the command **not** run, and a `Telemetry::Sandbox`
record for the refusal.

**A phone-approved bash call runs traced (ruling 2026-11-17).** Ask for a call needing network, and approve it **from the
phone**. Expect it to run under the traced profile (the journal's sandbox record says `traced`, and an exec record follows with
the files and commands it touched), the same as a terminal approval does. This is the one path in which the agent's bash is
unconfined while a phone answers, so a call approved this way **can** reach the devices file and the relay port: the human saw
the command first. Record what you approved, and file nothing for the reach; the finding would be a traced call that **no human**
approved, which the refusal above is there to stop.

## 13: Known and deferred, so a round does not file them

- `lain daemon restart --force` leaves live runs unlisted: the new daemon cannot list or stop them (§2). Read it as the cost of
  `--force`, which is why the plain verb refuses.
- A chat that reconnects to a live daemon is not announced again to ntfy, but no manual step drops a chat's connection and
  keeps the daemon, so the unit tests in `crates/lain-daemon` pin it and this round does not drive it.
- A daemon killed and restarted announces every item still waiting once more (§5). By design.
- The parent-chain check at registration is not a boundary (§12): confinement is the control, and on a profile that grants the
  socket the gap is the sandbox's.
- A run's cost is not capped: a run carries no `--max-cost`. Record the token spend of §7, and file nothing for the lack of a cap.
- macOS: no confinement, so `--human remote` refuses to start there; the launchd step is the user's.
- The phone path from a traced or unconfined call that a human approved is allowed by ruling (§12).

## Close-out negatives

Each with its positive control beside it (`method.md`, Isolation):

```bash
pgrep -x lain-daemon                                  # only the round's daemon; end it with kill, then expect nothing
ls $XDG_RUNTIME_DIR/lain/daemon/                      # daemon.trace and start.lock; no daemon.sock once it is stopped
pgrep -f 'daemon spawner'                             # prints nothing once the daemon is stopped
pgrep -f 'lain-daemon relay'                          # prints nothing: the worker goes with the daemon
find ~/.local/state/lain ~/.config/lain ~/.local/share -newermt "$(cat "$QA/records/round-start")" 2>/dev/null   # must print nothing
grep -c 'sk-qa' $XDG_RUNTIME_DIR/lain/daemon/daemon.trace $XDG_STATE_HOME/lain/daemon/runs/*.log   # 0 in each
```
