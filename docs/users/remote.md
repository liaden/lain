# Phone approvals

A chat that needs a human parks the call or the question. With the phone path set up, the same item
also shows on your phone, and you answer there. A headless run (`lain chat --non-interactive
--human remote`, or `lain daemon run epic SLUG`) has no terminal at all, so the phone is its only
human.

The pieces, all on 1 machine except the phone:

- `lain-daemon`, 1 per user. Every chat registers with it. It runs the phone relay as a
  confined worker, sends the ntfy notice, supervises headless runs and runs the review poll.
  [docs/devs/architecture.md](../devs/architecture.md#lain-daemon-the-per-user-daemon) has the internals.
- The relay, a TCP listener on this machine's tailscale address. The phone app (`apps/lain-remote`,
  labelled `lain` on the phone) connects to it with a paired token.
- ntfy, a push service. It tells the phone that an item has waited 60 seconds. The notice carries
  a title and a link and nothing of the item.

Linux and macOS both run the daemon. The relay confines itself with Landlock and refuses to start
without it, so the relay is Linux only today.

## Set it up

Each step says what to check before the next.

### 1. Find the tailscale address

```bash
tailscale ip -4        # for example 100.64.0.7
```

The relay listens on this address and on loopback, and refuses every other. `lain remote pair` prints
the same address (the `tailscale0` interface, port 7820) when it has one.

### 2. Run ntfy on the same address

Self-hosting is the recommendation. On Android the notices then never leave your tailnet, and the daemon
posts to a server you own (iOS needs one outside call, see step 5). These are the steps used on the dev box.

1. Download the ntfy release for your platform from the project's GitHub releases page, together
   with its `checksums.txt`, and check the archive before you unpack it:

   ```bash
   sha256sum --check --ignore-missing checksums.txt
   ```

2. Put the `ntfy` binary in `~/.local/bin`.

3. Write `~/.config/ntfy/server.yml`. Both addresses are the tailscale one, so ntfy listens
   nowhere else:

   ```yaml
   base-url: "http://100.64.0.7:2586"
   listen-http: "100.64.0.7:2586"
   cache-file: "/home/YOU/.local/share/ntfy/cache.db"
   cache-duration: "12h"
   ```

   Create the cache directory first. The cache is what lets a phone that was offline see a notice
   it missed.

4. Run it as a user service, `~/.config/systemd/user/ntfy-local.service`:

   ```ini
   [Unit]
   Description=ntfy server for lain notices, on the tailscale address only
   After=network-online.target

   [Service]
   ExecStart=%h/.local/bin/ntfy serve --config %h/.config/ntfy/server.yml
   Restart=on-failure
   RestartSec=10

   [Install]
   WantedBy=default.target
   ```

   `Restart=on-failure` matters. At login `tailscale0` may not have its address yet, and the first
   start then fails. Enable it with `systemctl --user enable --now ntfy-local.service`.

5. In the ntfy app on the phone, add your server's address as a server and subscribe to a topic of
   your choosing.

   - Android: turn on the app's instant delivery option when you subscribe to a topic on another
     server. It keeps a connection to your server open, so notices arrive at once and nothing
     leaves the tailnet.
   - iOS: the app cannot hold that connection, so a self-hosted server needs
     `upstream-base-url: "https://ntfy.sh"` in `server.yml` to wake it. ntfy.sh then receives a poll
     request for each message: no title and no body, but the timing and an id derived from the
     topic. This is the one thing on the iOS path that leaves your tailnet.

   Both are written from memory of the ntfy docs and are not checked against the current ones.

6. Pick a long random topic name. To ntfy a topic is a shared name, and anyone who can reach the
   server and knows the topic can post to it. The name is the only thing between a stranger on your
   tailnet and a fake notice, so treat it like a password. The daemon never puts it on a command
   line: it travels in the daemon's environment.

macOS has no systemd. Run `ntfy serve` from a launchd agent with `KeepAlive` set.

### 3. Name them in your user config

In `~/.config/lain/config.rb` (or `$XDG_CONFIG_HOME/lain/config.rb`):

```ruby
remote relay: "100.64.0.7:7820", ntfy: "http://100.64.0.7:2586/lain-your-long-random-topic"
```

Only the user file may say this, because 1 phone listener serves the whole machine. A project's
`.lain/config.rb` that sets `remote` is refused, and the refusal names the user file. `ntfy:` has no
effect without `relay:`, since only a relay has items to announce. The relay address must be loopback
or this machine's tailscale address: an all-addresses spelling is refused when the config loads.

### 4. Trust the file

```bash
lain trust --user
```

A user config is code, so lain asks before it runs one it has not seen. Shown the file, you answer
`y`. Any later edit to the file asks again.

### 5. Start the daemon

```bash
bundle exec rake daemon:build     # in the lain checkout, once and after the daemon's source changes
lain daemon ensure
lain daemon status
```

`lain` must be on your `PATH`. On the dev box `bin/install-shim` writes `~/.local/bin/lain`, a small script
that runs the checkout's `exe/lain` under the right ruby.

A new daemon build, another lain checkout, another ruby, or `ANTHROPIC_API_KEY` added or removed
replaces an idle daemon. The relay, devices file, ntfy topic, review poll and runs dir never do: a
running daemon keeps the ones it started with, the next chat names the ones it would start
differently, and `lain daemon restart` applies them. An unreadable user config replaces no daemon.

`status` should print `relay: running`. Any chat starts the daemon on demand too, but `ensure` at
login is what keeps the review count fresh and lets a headless run start while no chat is open. On
Linux that is a oneshot user service wanted by `default.target`:

```ini
[Unit]
Description=Start the lain daemon at login
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=%h/.local/share/mise/shims:%h/.local/bin:%h/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=%h
ExecStart=%h/.local/bin/lain daemon ensure

[Install]
WantedBy=default.target
```

`RemainAfterExit=yes` is required. The daemon outlives `lain daemon ensure`, and without it systemd
reaps the daemon when the oneshot ends. Use the `PATH` your `lain` needs (a ruby from mise here). On
macOS use a launchd agent with `RunAtLoad` that runs the same command.

A change to `remote` in the config, a new build of the daemon, a new ruby or an upgrade of lain makes
the running daemon out of date. `lain daemon ensure` replaces it once no chat is registered and no run
is live; until then it says what it is waiting for.

### 6. Pair the phone

```bash
lain remote pair my-phone
```

It prints a token and the relay address, once. Enter both in the phone app's settings. The box keeps
only the token's digest, in a 0600 file under `$XDG_STATE_HOME/lain/remote/`. The relay rereads that
file every second, so neither `pair` nor `lain remote revoke my-phone` restarts anything, and a revoked
phone's connection closes at the next reread.

### 7. Check it end to end

Start a chat, ask for something that needs approval (a `bash` call the judge leaves open is the
usual one) and watch the item appear on the phone. If you leave it unanswered for 60 seconds the
ntfy notice arrives.

For a headless run:

```bash
lain chat --non-interactive --human remote --prompt "..."
lain daemon run epic my-epic        # the same, supervised by the daemon
```

`--human remote` refuses to start, naming the reason, when `remote relay:` is missing from the user
config, when the daemon's relay is not `running`, or when bash would run outside a sandbox that
confines it. It also needs `--non-interactive`. A run the daemon starts outlives the terminal.
It takes the provider, model, api base, context size and batch size from the `LAIN_*` variables
in the shell that started it, passed in its environment and never on its command line.

## Trust boundaries

### What crosses the tailnet

Between the phone and the relay, over plain TCP that tailscale encrypts:

- the device token, in the phone's first message, which the relay checks against its stored digest;
- each waiting item, masked. A parked call shows the tool, its input, the working directory,
  why it was parked and the requester. A question shows its text and options. A gate question shows
  its epic, stage, issues and question. Each item also carries its session id and the project's root
  path. Values the board knows are secrets, and every region the secret detector finds, are replaced
  before an item is published (`Remote::Agenda::View`);
- your answer: approve, deny or text, with the phone's device name.

The relay has no TLS of its own. A tailnet is the encryption and the access list.

### What never crosses

- A call whose yes would release a sensitive region of a file stays at the desk. The phone is not
  shown it, and the release prompt names the file without its bytes.
- The gates waiting in a journal lain cannot read. The phone still gets an item, and an ntfy notice, saying
  to fix the journal at the desk; its question is a fixed sentence, and an answer to it is refused.
- Your provider key, the journals, the unmasked values and every file's contents.
- To ntfy, an item's text, project or session. The notice is a title (`lain approval waiting on
  REQUESTER`, `lain question waiting on REQUESTER` or `lain gate question waiting on REQUESTER`, the
  requester cut to 64 characters, and any character outside printable ASCII shown as `?`), a fixed body, `Open lain to answer.`, and an Open link to
  `lain-remote://item/<id>`. The id means something only to an app holding a paired token.

### Who can do what on the machine

The daemon's local socket (`daemon/daemon.sock` under the runtime directory, mode 0700) checks the
caller's uid on every call, and a chat can register only as its own process. Any process running as
you passes the uid check, so what matters is what the daemon lets a caller do. It lets a caller
register itself, publish items under its own registration's project and pid, and send a review offer
(a chat shows it only after your keypress). No local method answers an approval or a question, and no
local caller can start a run with an argv it wrote: the daemon builds every argv itself, from the
closed kinds `epic`, `chores` and the review poll.

Only the phone can answer, with a paired token, over loopback or the tailscale address. The relay worker
runs with Landlock confinement, an empty environment and no network beyond its listener. It cannot
send ntfy. The main daemon does that.

A confined bash profile gets no daemon socket. A `traced` or `none` profile, and any profile on
macOS, can write the devices file and connect over loopback as a phone. That is why `--human remote`
needs a confining sandbox.

### A phone approval runs traced

A bash call you approve from the phone runs traced, exactly like a call you approve at the
terminal: outside the confining sandbox, under the tracer. This is a ruling (2026-11-17), and it is
the one place a headless run's bash leaves its sandbox. Still refused under `--human remote`: a traced
call no human approved, the `none` profile, and any confined call when the sandbox layer is missing at
call time.

### What the daemon's environment holds

The daemon starts with a short allowlist: `PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `TZ`,
`TMPDIR`, `GEM_HOME`, `GEM_PATH`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, the proxy variables and the 4 XDG
homes. Runs it starts get more: the `LAIN_*` names a launch needs, `SHELL`, `OLLAMA_HOST`, `LC_*`,
and `ANTHROPIC_API_KEY`. That is the only secret-shaped name passed. It goes from the lain that
started the daemon, to the daemon, to its runs, and never to the relay worker, which starts with an
empty environment. A daemon started by a lain with no key has none, and
`lain daemon ensure` from a lain that has one replaces it when no chat or run is live.

## ntfy.sh as the option

If you do not want to host ntfy, `ntfy: "https://ntfy.sh/your-long-random-topic"` works. The daemon
posts over https with the system's TLS roots, and honors the proxy variables. Redirects are refused.

What ntfy.sh then sees, for every notice: the title (which names the requester, such as `main` or an
agent's name), the Open link with the item's id, the exact time, the IP address of the machine that
posted, and the topic name. It sees no tool, input, path or project. Anyone who learns the topic can
read your notices and post to it. Self-hosting on the tailnet removes it on Android; iOS still sends timing to ntfy.sh (see step 5). It costs
the steps above.

## Follow-ups still open

These are known and have no fix yet.

- A tripwire for the relay. Nothing refuses a traced call that writes the devices file under
  `$XDG_STATE_HOME/lain/remote/` or connects to the relay port. Because a phone approval runs traced,
  a prompt-injected run could ask you to approve a call that pairs itself. A rule is planned.
- The `grant` profile can reach ports 80 and 443. A relay configured on a granted port is not
  refused.
- The relay worker is not restarted after it exits. `lain daemon status` then shows
  `relay: unavailable` without the reason, which is in the daemon's trace under
  `$XDG_RUNTIME_DIR/lain/daemon/daemon.trace`. A seccomp deny of unix `socket()` in the worker after
  setup would close the one thing Landlock cannot, a connect to a pathname socket.
- A relay that dies mid-run leaves that run's parked calls waiting with no surface. They stay
  refused until the relay is back.
- Notice links on Android and Linux. The `lain-remote://` scheme is registered on iOS and macOS
  only once the bundle declares it, and not at all on Android or Linux yet. The notice arrives and the
  app opens from it by hand.
- A stale link after a daemon restart. Phone ids are minted per daemon process, and a restart mints
  new ones, so a link in an old notice can open a different item, and an item still waiting after a
  restart is announced again.
- `ask_human` under `--human remote` still starts the terminal answer loop, which prints to a
  headless terminal.
- Ended runs and their logs are not pruned. Each review poll adds 288 a day under
  `$XDG_STATE_HOME/lain/daemon/runs/`.
- `lain daemon restart` checks for live runs, then stops, from the client, so a run that starts
  in between is not seen.
- `herdr`. The daemon passes no `HERDR_SOCKET_PATH` or `HERDR_BIN_PATH` to the sync command, a
  daemon that dies leaves its runs token stale in herdr, and your herdr row template must name
  `$runs`.
- No end-to-end example yet of a phone-approved bash call running traced. It is proven in 2 halves.
- An inherited descriptor. A `lain-daemon` started by anything other than `Daemon.ensure` can pass an
  open descriptor of its own to the spawner and to every run.
- Keyless and keyed callers swap an idle daemon. The build digest includes whether
  `ANTHROPIC_API_KEY` is set, so an idle daemon is replaced each time a lain without the key and a lain
  with it alternate, and each swap restarts the relay.
- The mac. Its launchd steps are by hand, and the relay does not run there.
