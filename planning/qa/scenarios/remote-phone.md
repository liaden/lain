# Scenario: the phone surface, relay, pairing and ntfy

**What it exercises:** `lain remote pair` and `lain remote revoke` (`CLI::Remote`, `Remote::Devices`), the `remote` config verb
(`relay:` and `ntfy:`), the phone relay the per-user lain-daemon runs as a confined worker (`Daemon::Launch` adds
`--relay` and `--devices-file`), `Approval::RemoteSurface` publishing through the chat's `Daemon::Registration` over
`Remote::Agenda` and its masked `View`, the daemon's ntfy notice (`agenda_watch.rs`, `ntfy.rs`), and the phone app in
`apps/lain-remote` (§6 on the desktop, §7 on an emulated Android device).

**Status:** written 2026-11-04 from the code at HEAD (`5d769e5f`: `cli/remote.rb`, `remote/devices.rb`, `remote/agenda.rb`,
`approval/remote_surface.rb`, `config/builder.rb`, `crates/lain-daemon/src/relay.rs`).
Revised 2026-11-17 when the relay moved into lain-daemon: `lain up` opens no relay window, `lain-core relay` is no
longer the phone path, and the chat publishes through its daemon registration rather than a per-project socket.
The ntfy notice moved the same day: `remote/ntfy.rb` is gone, and `crates/lain-daemon/src/agenda_watch.rs` and
`ntfy.rs` send it (§5).
Nothing here has been driven. §0 to §5 need no phone app: drive the relay's TCP port with a stand-in client, or
with the app. §6 and §7 were added on 2026-11-10, when the app moved into this repo. Every "Expect" is a prediction read off the code, so a mismatch is either a defect or a
stale line in this file, and the round says which.

**The question it answers:** can a human answer what waits on them from a paired phone, with exactly the authority they have at
the desk, while a stranger, a revoked device, a dead relay and a slow topic server each cost nothing but the phone? And does
the phone ever see a byte the desk would have masked?

**Cost:** cheap. 3 short asks on a local model (a parked `bash` call, an `ask_human`, a deferred gate). No spend.

**Needs:** `../bench.md` up, tmux, a built `lain-daemon` (`bundle exec rake daemon:build`), Landlock in the kernel (the relay
worker refuses to run unconfined), and for the real-network half a `tailscale0` interface. Without one, listen on loopback, which the relay allows.
A stand-in ntfy topic: `nc -l` or a one-route HTTP server on loopback. §6 needs `tailscaled` up and logged in, and
WebKitGTK (`cargo build -p lain-remote`); §7 needs what its own Needs line says. Read `../method.md` first, build the sandbox with
`.claude/skills/manual-qa/scripts/qa-sandbox.sh`, and start each Bash call that touches files with `: "${QA:?}"`.

---

## 0: Config refusals *(free — launch only)*

Write each into the user's `config.rb` (`$XDG_CONFIG_HOME/lain/config.rb`), run `lain trust --user`, and start `lain chat`.
Each must refuse at load, naming that file and `:LINE`, exit 1, no backtrace:

```ruby
remote relay: "0.0.0.0:7820"        # listens on every address
remote relay: "my-phone.local:7820" # a name, not an IP
remote relay: "100.64.0.1:70000"    # port out of range
remote ntfy: "ntfy.sh/topic"        # no scheme
remote ntfy: "https://ntfy.sh"      # no topic path
remote nope: 1                      # unknown key
```

Expect: `relay must be an IP address and a port, such as "100.64.0.1:7820"`, `relay listens only on loopback or this host's
tailscale0 address, never on every address`, and `ntfy must be an http or https URL naming a topic`. With no `remote` line the
phone surface is off and the daemon runs no relay.

Then put `remote relay: "100.64.0.1:7820"` in a project's `.lain/config.rb`, run `lain trust --yes`, and start `lain chat`.
Expect a refusal at load, exit 1, no backtrace, saying `remote belongs in the user's config.rb` and naming the user's
`config.rb` path.

## 1: Pairing *(free)*

```bash
lain remote pair qa-phone
lain remote pair qa-phone       # again
lain remote pair                # no name
lain remote forget qa-phone     # unknown verb
lain remote revoke qa-phone
lain remote revoke qa-phone     # again
```

Expect: the first prints `paired qa-phone`, a `token:` line, a `relay:` line (this host's `tailscale0` address on port 7820,
or `none, this host has no tailscale0 address, ...`) and `The token is not shown again`. The devices file is
`$XDG_STATE_HOME/lain/remote/devices`, mode 0600, holding the name and a 64-hex digest and never the token: `grep` it for the token
and expect no match. The repeat pair, the missing name and the unknown verb each refuse by name with exit 1 (the unknown verb
message is `lain remote knows pair and revoke, not "forget"`); the second revoke refuses. **Wrong looks like:** the token in the
file, in the journal, or printed twice.

## 2: The relay worker in the daemon *(free)*

Set `remote relay: "127.0.0.1:7820"` in the user's config.rb and start `lain chat`. Expect the chat's daemon to run with
`--relay 127.0.0.1:7820 --devices-file <state>/lain/remote/devices` on its command line (`ps -o args= -C lain-daemon`), a
child `lain-daemon relay` process listening on the port, and, on a first start, an empty devices file at mode 0600 in a 0700
directory. `lain up` opens no `relay` window. A chat started before the line was added keeps the daemon it has until that
daemon has no chats left; the next chat then restarts it with the relay.

Then the failures. Each leaves the chat running with the phone surface off, a `phone surface off: <reason>` line in the
chat and 1 `capability_degraded` record naming `remote_surface`, never a refused chat:

| setup | expected reason |
|---|---|
| `relay: "100.64.9.9:7820"` on a host with no such address | `the daemon's phone relay is unavailable; <runtime dir>/lain/daemon/daemon.trace says why`, and that trace names the address |
| the devices file replaced by a symlink | the same line, naming the same trace |
| `LAIN_DAEMON=off` | `no daemon to publish through` |

Kill the relay worker (`kill <pid of lain-daemon relay>`): the daemon keeps running and `daemon.info` reports the relay
`unavailable`; the chat's next publish turns the surface off as above. Kill the daemon itself instead: that is not a death.
The chat registers with a new daemon, the surface publishes every open item again, and no `capability_degraded` is written.

## 3: What the phone sees, and what it may not *(cheap)*

In the cockpit, park a `bash` call (`approval` at `ask`), ask the model an `ask_human` question, and leave a `gate :research,
:deferred` gate parked. Connect a paired client to the relay's port. Expect 3 items: an approval, a question with its options, and a gate
question naming its epic and stage, each under an id the client can answer by.

Masking: make the parked call's input carry a known secret value (a key in the command line, a `.env` value). Expect the item's
text to hold `<redacted:N>` where the desk's own prompt does, and a path an error names to read `<a path at the desk>`. The ntfy
notice (§5) carries none of it.

Answers, each with the device named in the journal (`surface=remote:qa-phone`, authority human):

1. approve the parked call: it runs, and the item leaves every surface, the desk's `[y/N]` included;
2. answer the question: the model gets the text, the question leaves `lain://inbox`, and the journal's `question_answered` record names the device (`"answered_by":"remote:qa-phone"`), as a desk answer leaves it nil;
3. answer the gate: the verdict is journaled as a `gate_decision` from the phone, with `answered_by` reading `remote:qa-phone` (it used to read as the desk's human);
4. answer the same item at the desk first, then from the phone: expect a `remote_answer_lost` record with the device, and no
   second decision. Its `id` is the chat's own agenda id (`"1"`, `"2"`, ...), not the id the phone was shown: the relay
   worker mints the phone's ids, and the chat never sees them.

**A refused answer comes back as text.** Answer a question with neither option nor text: the item reappears with
`your last answer was refused: ...` at the head of its text, and the surface lives on. A gate whose journal cannot be read is
shown as `a gate journal cannot be read ... fix it at the desk` and every answer to it is refused with `this item can only be
fixed at the desk`.

**A re-asked gate is a new item.** With 2 chats open over 1 project, the deferred gate shows once on the phone. Re-ask 1 of
its rows under a new artifact revision: expect the phone to show the gate under a new id, and an answer to the old id to be
refused as already settled, with no `gate_decision` for the new revision.

**A stage gate with no issues is 1 item, whichever revision the desk decided.** Park 2 revisions of one stage with no issues (a `plan`
gate re-submitted under a new artifact), so 2 rows are parked at once. Expect the phone to show 1 item for the stage, standing for
the **newer** revision. Press Approve: exactly 1 `gate_decision` is journaled, for the newer revision's digest, and the older row
is superseded by it (the status buffer shows the stage settled), not left parked. Then the other order: with the phone's item
showing, decide the **older** revision at the desk. The item keeps its id and stays listed, and the phone's Approve still lands
on the newer revision (no `remote_answer_lost`). A denial from the phone is journaled for each revision, since a denial supersedes
none. A gate whose rows each name an issue is unchanged: each issue answers by its own key. **Wrong looks like:** 2 decisions for
one tap, an item that vanishes or changes id when the desk settles the older row, or an Approve that errors with `UnknownDigest`.

**A gate offers only Approve and Deny, and a bad answer cannot strand it.** The gate item lists 2 replies; Hold is not among them (a deferred gate already waits, so a hold answered nothing while the phone showed it landed). Check each way an answer can fail to decide a gate, from a client or by hand against the relay:

- a gate answer carrying no verdicts, and an answer that holds the gate (an older app build still offers it): each comes back as text at the head of the item, `a gate answer names no issue; answer <keys>` or `a gate cannot be held: it already waits for an answer, so approve or deny it`, the item is offered again under the same id, and the journal holds no `gate_decision` for it. The old defect was an item the agenda called answered while the journal had no decision, so no surface could answer it. Answer it again and expect the decision to land.
- a gate with no issues (an epic-wide stage such as a research gate) lists the stage's own name as its key. An answer keyed by that name approves or denies it, and an unknown key is refused with `issue "<key>" is not in this gate (<keys>)`.


## 4: Revoke, strangers and a dead relay *(cheap)*

- `lain remote revoke qa-phone` with a client connected: within about a second (the relay rereads the file on a 1 s tick) the
  connection closes, with no relay restart. A client with a token that was never paired is refused at its hello.
- **A relay that fails at launch is said at launch.** Start `lain chat --human remote` with `remote relay:` pointing at an address
  the worker cannot bind (a port already taken: `nc -l 127.0.0.1 <port>` first). Expect the chat's startup lines to include
  `phone surface off: <reason>` before the first prompt, 1 `capability_degraded` record naming the phone surface, and no second
  line however many items are parked later. A relay that dies after the terminal opened is said once the same way (the next bullet).
  **Wrong looks like:** a silent chat that parks calls for a phone that is not there.
- **A signal to a headless chat interrupts at once.** `lain chat --non-interactive --human remote --prompt '<a gated call>'` with the
  call parked on the phone, then `kill -INT <pid>` (and again with `kill -HUP`). Expect the ask to stop with no countdown and no 60 s
  grace line, the parked call to settle as cancelled (which denies; the model's tool result says so), **no** silence `postpone`
  record in the journal, and no provider request started after the signal (the journal's last `turn_usage` precedes it). The
  control is the same signal to a chat at a terminal: the 60 s countdown starts as before and a second signal interrupts.
  **Wrong looks like:** a headless chat that counts down to nobody, or a parked call that ends as a silent postpone after the signal.
- Kill the `lain-daemon relay` worker mid-session: the chat keeps running, one `capability_degraded` record and one
  `phone surface off:` line appear once the chat next publishes, and the desk answers everything as before. **Wrong looks like:** a stalled chat, a second degraded record per sweep, or a stack trace in the pane.
- End the chat: every item it published leaves the relay (retracted within 1 s, and the daemon drops a session's items
  when its registration closes), so no dead question waits on the phone.

## 5: ntfy *(cheap)*

The lain-daemon sends the notice, from its main process: the relay worker has no network. Set
`remote ntfy: "http://127.0.0.1:<port>/qa-topic"` beside `relay:` and run the stand-in topic server before the daemon starts
(a changed topic does not restart a running daemon: it is a setting, and `lain daemon restart` applies it, `daemon.md` §2). Park a call and leave it.

- Before 60 s: nothing is sent. Answer a second parked call within the minute: nothing is ever sent for it.
- At 60 s the server receives exactly 1 POST: body `Open lain to answer.`, a `Title` of `lain approval waiting on <requester>`
  (`gate question` or `question` for those kinds), and an `Actions` header `view, Open, lain-remote://item/<phone id>`. The
  `<phone id>` is the id a client sees in the relay's snapshot for that item (§3), not the chat's own agenda id, and the id is
  percent-encoded. No input text, no token, no path, no project, no session, no relay address anywhere in it. A requester with
  non-ASCII bytes reads `?` in the title.
- **2 chats in 1 project, 1 buzz per item.** Start a second chat in the same project (a shared gate is keyed by its project, so
  chats in different projects each show it), park 1 call in each, and leave a deferred gate parked that both publish. After 60 s the
  server has exactly 3 POSTs, 1 per distinct item (the shared gate once, whichever chat published it first). End the second
  chat: nothing is sent, and its call leaves the phone's agenda. Start another chat there and park a call: 60 s later 1 more POST
  for that call alone. A restarted chat is a new process, so it is a new item to the daemon, and a parked call cannot outlive
  its chat. The gate, still held by the first chat, buzzes nothing. A chat that reconnects to a live daemon is not announced
  again, but no manual step drops a chat's connection and keeps the daemon, so the unit tests in
  `crates/lain-daemon/src/main.rs` and `crates/lain-daemon/src/agenda_watch.rs` pin it and this round does not drive it.
- **More than 30 in a window.** Leave 35 parked calls (or a restart with that many open) past 60 s. The server gets exactly 30 item
  POSTs in that window, and when the window closes (60 s after the first of them) exactly 1 more: `Title` `lain: 5 more items waiting`,
  body `Open lain to answer.`, and no `Actions` header, since no single item is meant. The 5 dropped items are not sent later. No
  window sends more than 30 item POSTs and 1 summary, however many items open.
- **An https topic under a private CA.** Name the CA in `SSL_CERT_FILE` in the environment `lain` starts the daemon from (the
  launch passes `SSL_CERT_FILE` and `SSL_CERT_DIR` on) and point `ntfy:` at an https stand-in signed by it: the POST arrives. Without
  the variable the daemon's trace says `error=io: invalid peer certificate: UnknownIssuer` once. The variable replaces only the
  default file, as with OpenSSL: a public https topic (any real ntfy server) still verifies with it set, which on macOS it does not
  (there a set variable replaces the keychain).
- **Behind a proxy.** With `http_proxy` (or `https_proxy`) set in the environment `lain` starts the daemon from, the POST goes
  through it (an http topic arrives as a `CONNECT`), and a host named in `no_proxy` goes direct. A topic that answers a redirect
  is not followed: the trace says `ntfy answered 302` once.
- It is not sent again while the daemon runs, even if the server answered 500: the refusal is written to the daemon's trace once.
- **A re-buzz after a daemon restart.** Leave a call parked past its notice, then stop the daemon by pid and let the chats
  reconnect (the next chat action starts a new one). The chats publish everything again under new phone ids, and 60 s later each
  item still waiting is announced once more. By design: the announced set lives in the daemon's memory. An item answered in
  between is not announced.
- Point `ntfy:` at a dead port: neither the chat nor the phone's agenda is stalled (the post is bounded at 5 s and runs off the
  relay), no `approval_surface_fault` record is written, and the daemon trace, `$XDG_RUNTIME_DIR/lain/daemon/daemon.trace`
  (`/tmp/lain/daemon/daemon.trace` when `XDG_RUNTIME_DIR` is unset), gains a line `could not announce on ntfy error=<why>`
  (for example `error=ntfy answered 500`) each time the error changes, so a port that keeps refusing costs 1 line, not one per
  item. **Wrong looks like:** a fault record in the chat's journal, or a trace line per item.

## 6: The desktop app, over the tailnet only *(cheap)*

The phone's path, driven from the desk: the relay listens only on this host's tailnet address, so the app cannot take a
loopback shortcut.

```bash
TS=$(tailscale ip -4)
cargo build -p lain-remote
```

Set `remote relay: "$TS:7820"` (the address itself, not `$TS`) in the user's config.rb, run `lain remote pair qa-desktop`, and start `lain chat`. Expect
the `relay:` line of the pair to read `$TS:7820`, and `ss -ltn 'sport = :7820'` to show 1 listener, on `$TS`, and none on
`127.0.0.1` or `0.0.0.0`.

Run the app with a throwaway settings file, so the round never writes the real one:

```bash
LAIN_REMOTE_CONFIG="$QA/remote-settings" target/debug/lain-remote
```

1. **Loopback is refused.** With no settings saved, the app opens on Settings. Enter `127.0.0.1:7820` and the token. Expect the
   status line to read `reconnecting: ` and a connect error, repeated every 3 s, and no agenda. `nc -zv 127.0.0.1 7820` is refused
   too.
2. **The tailnet address works.** Enter `$TS:7820` and leave the token blank. Expect the token field's hint to read
   `a token is saved; leave blank to keep it`, the status line to clear, and `$QA/remote-settings` at mode 0600 holding the
   address. The token must not appear in the window, on the terminal or in the app's stderr.
3. **The 3 items of §3, answered from the app.** The agenda lists them newest first with kind, requester and age. Approve the parked
   call, pick an option on the question, and deny the gate with a note. Expect what §3 expects from each, with `remote:qa-desktop`
   in the journal. The gate's buttons are Approve and Deny only, with no Hold. Then answer an item at the desk while it is open in the app: expect `That item is no longer waiting.`.
4. **A blank text answer is not sent.** Pick Text on a question with nothing typed: expect no answer to leave the app. A Deny
   with an empty note is sent, carrying no note.
5. **Revoke and restart.** `lain remote revoke qa-desktop` while the app is connected: expect `reconnecting: ` within about a
   second, and never the agenda again. Pair again, enter the new token, then kill the lain-daemon: expect
   `reconnecting: `, and the agenda back on its own once the chat has registered with the new daemon.
6. **Wrong looks like:** an agenda while the address is `127.0.0.1`, a listener on loopback, or the token anywhere on screen.

**What this does not prove.** Linux routes a packet for one of the host's own addresses through loopback, so this host reaching
`$TS` never enters WireGuard. Record `ip route get $TS` in the round. The expected output is `local $TS dev lo ...`, and while it
reads that, §6 proves only the bind and the address the phone will use. A real tailnet crossing needs a second node, which is §7 or
a real phone.

## 7: An emulated Android device on the tailnet *(not yet driven; setup first)*

**Needs:** `dx` (the Dioxus 0.7 CLI), the Android SDK and NDK, and 1 of the 2 below. Neither has been set up on this box, and
whether Tailscale's VPN service runs inside Waydroid has not been checked.

- **Waydroid.** It runs Android in a container on this kernel, which already has binder support, and needs no KVM. Its Android
  has its own network, so the Tailscale app inside it is a separate tailnet node. Build for `x86_64-linux-android`.
- **The Android Emulator.** It needs `/dev/kvm`. The `kvm_amd` module ships with the kernel and is not loaded, and if
  `sudo modprobe kvm_amd` fails, SVM is probably off in the BIOS. Use an x86_64 system image with Google Play, so the
  Tailscale app installs from the store.

Then:

1. Install Tailscale inside the device and log it in. Expect `tailscale status` on this host to list it.
2. `dx build --platform android` from `apps/lain-remote`, then `adb install` the APK. Expect the launcher label to read `lain`.
3. Pair a new device, `lain remote pair qa-android`, and enter `$TS:7820` and the token in the app on the device.
4. Expect `tailscale ping <device>` from this host to answer, and the relay's peer in `ss -tn 'sport = :7820'` to be the
   device's tailnet address, not `$TS`. That is the tailnet crossing that §6 cannot show.
5. Repeat §6 steps 3 to 5 from the device. Then repeat §5 with `ntfy:` pointing at a topic the device subscribes to: nothing on
   Android handles the notice's `lain-remote://item/<id>` link yet (known gap), so record what tapping Open does.

## What this scenario does not cover

A real phone, and `tailscale` ACLs. 2 gaps are known and recorded in the plan, and a round that finds them files
them as known: no "already answered" signal reaches a phone that loses a race, only the journal's `remote_answer_lost`, whose `id` is the chat's agenda id, not the phone's; and the
mask's known gaps show through the phone view (a value in base64 or reversed, under 6 bytes, or split across 2 fields).
