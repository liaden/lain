# Scenario: the phone surface, relay, pairing and ntfy

**What it exercises:** `lain remote pair` and `lain remote revoke` (`CLI::Remote`, `Remote::Devices`), the `remote` config verb
(`relay:` and `ntfy:`), the `relay` tmux window `lain up` opens (`CLI::Up::Relay`), `lain-core relay`, `Approval::RemoteSurface`
over `Remote::Agenda` and its masked `View`, and `Remote::Ntfy`.

**Status:** written 2026-11-04 from the code at HEAD (`5d769e5f`: `cli/remote.rb`, `remote/devices.rb`, `remote/agenda.rb`,
`remote/ntfy.rb`, `approval/remote_surface.rb`, `cli/up.rb` `class Relay`, `config/builder.rb`, `crates/lain-core/src/relay.rs`).
Nothing here has been driven, and no phone app is needed: drive the relay's own socket and TCP port with a stand-in client, or
with the lain-remote app if one is paired. Every "Expect" is a prediction read off the code, so a mismatch is either a defect or a
stale line in this file, and the round says which.

**The question it answers:** can a human answer what waits on them from a paired phone, with exactly the authority they have at
the desk, while a stranger, a revoked device, a dead relay and a slow topic server each cost nothing but the phone? And does
the phone ever see a byte the desk would have masked?

**Cost:** cheap. 3 short asks on a local model (a parked `bash` call, an `ask_human`, a deferred gate). No spend.

**Needs:** `../bench.md` up, tmux, a built `lain-core` (`bundle exec rake core:build`), Landlock in the kernel (the relay refuses to
run unconfined), and for the real-network half a `tailscale0` interface. Without one, listen on loopback, which the relay allows.
A stand-in ntfy topic: `nc -l` or a one-route HTTP server on loopback. Read `../method.md` first, build the sandbox with
`.claude/skills/manual-qa/scripts/qa-sandbox.sh`, and start each Bash call that touches files with `: "${QA:?}"`.

---

## 0: Config refusals *(free — launch only)*

Write each into `.lain/config.rb`, run `lain trust --yes`, and start `lain chat`. Each must refuse at load, naming
`.lain/config.rb:LINE`, exit 1, no backtrace:

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
phone surface is off and nothing in `lain up` changes.

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

## 2: The relay window in `lain up` *(free)*

Set `remote relay: "127.0.0.1:7820"` and run `lain up`. Expect a tmux window named `relay` running `lain-core relay`, a note
`the phone relay runs in the 'relay' window; if it dies its log is <path>`, the socket directory at mode 0700 and, on a first start,
an empty devices file. Then the failures, each a warning and a cockpit WITHOUT a relay, never a refused cockpit:

| setup | expected warning |
|---|---|
| `relay: "100.64.9.9:7820"` on a host with no such address | `remote relay 100.64.9.9:7820: the relay listens only on loopback or an address of tailscale0, so the cockpit starts without it (is tailscale up?)` |
| `lain-core` not built | `remote relay is set but lain-core is not built at <path>, ... (run `rake core:build`)` |
| the devices file replaced by a symlink | `remote relay is set but <path> is a symlink or another user's, so the cockpit starts without the relay` |
| a config that will not load | `remote relay skipped: <reason>`, and the chat says the same |

Kill the relay process inside its window: expect the window to stay with the last 20 lines of the relay's trace, not vanish. A
dead relay is not revived by reattaching (known gap). Kill the tmux session: the relay stops with it.

## 3: What the phone sees, and what it may not *(cheap)*

In the cockpit, park a `bash` call (`approval` at `ask`), ask the model an `ask_human` question, and leave a `gate :research,
:deferred` gate parked. Connect a paired client to the relay. Expect 3 items: an approval, a question with its options, and a gate
question naming its epic and stage, each under an id the client can answer by.

Masking: make the parked call's input carry a known secret value (a key in the command line, a `.env` value). Expect the item's
text to hold `<redacted:N>` where the desk's own prompt does, and a path an error names to read `<a path at the desk>`. The ntfy
notice (§5) carries none of it.

Answers, each with the device named in the journal (`surface=remote:qa-phone`, authority human):

1. approve the parked call: it runs, and the item leaves every surface, the desk's `[y/N]` included;
2. answer the question: the model gets the text, and the question leaves `lain://inbox`;
3. answer the gate: the verdict is journaled as a `gate_decision` from the phone;
4. answer the same item at the desk first, then from the phone: expect a `remote_answer_lost` record with the device, and no
   second decision.

**A refused answer comes back as text.** Answer a question with neither option nor text: the item reappears with
`your last answer was refused: ...` at the head of its text, and the surface lives on. A gate whose journal cannot be read is
shown as `a gate journal cannot be read ... fix it at the desk` and every answer to it is refused with `this item can only be
fixed at the desk`.

## 4: Revoke, strangers and a dead relay *(cheap)*

- `lain remote revoke qa-phone` with a client connected: within about a second (the relay rereads the file on a 1 s tick) the
  connection closes, with no relay restart. A client with a token that was never paired is refused at its hello.
- A socket directory open to others (`chmod 755` it), or a socket whose peer is another user's process, makes the chat refuse the
  surface with `must be 0700` or `is another user's`; the chat itself carries on and the journal holds one `capability_degraded`
  record naming the reason.
- Kill `lain-core relay` mid-session: the chat keeps running, one `capability_degraded` record is written, and the desk answers
  everything as before. **Wrong looks like:** a stalled chat, a second degraded record per sweep, or a stack trace in the pane.
- End the chat: every item it published leaves the relay (retracted within 1 s), so no dead question waits on the phone.

## 5: ntfy *(cheap)*

Set `remote ntfy: "http://127.0.0.1:<port>/qa-topic"` beside `relay:` and run the stand-in topic server. Park a call and leave it.

- Before 60 s: nothing is sent. Answer a second parked call within the minute: nothing is ever sent for it.
- At 60 s the server receives exactly 1 POST: body `Open lain-remote to answer.`, a `Title` of `lain approval waiting on <requester>`
  (`gate question` or `question` for those kinds), and an `Actions` header `view, Open, lain-remote://item/<id>`. No input text, no
  token, no path, no relay address anywhere in it. A requester with non-ASCII bytes reads `?` in the title.
- It is not sent again while the same chat runs, even if the server answered 500 (a refusal is recorded once, not retried).
- **A reminder after a restart.** Leave a deferred gate parked, end the chat, start a new one over the same project and wait 60 s
  again: the still-waiting gate is announced again. The announced set lives in the chat, so this is by design, and a gate someone
  answered in between is not announced.
- Point `ntfy:` at a dead port: the chat is not stalled (the post is bounded at 5 s and runs off the sweep), and one fault record
  is written, not one per sweep.

## What this scenario does not cover

The lain-remote app itself, and `tailscale` ACLs. 2 gaps are known and recorded in the plan, and a round that finds them files
them as known: no "already answered" signal reaches a phone that loses a race, only the journal's `remote_answer_lost`; and the
mask's known gaps show through the phone view (a value in base64 or reversed, under 6 bytes, or split across 2 fields).
