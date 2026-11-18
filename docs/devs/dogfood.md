# Dogfooding lain on lain

`dogfood/lain/config.rb` is the config a checkout of lain uses on itself: it names `bin/verify` as the
isolation verifier and lets the bash tool run exactly that command.

`bin/dogfood-setup` links `.lain` to `dogfood/lain` and prints the `lain trust` command. Read the config,
then run the command: a config does not run until its bytes are trusted.

`.lain/` stays ignored (`/.lain/` in `.gitignore`). It holds per-checkout state, such as the status line
the cockpit republishes each turn, and whether to version it is still open. Until then the committed copy lives in
`dogfood/lain/`, so every clone gets the same bytes. The setup script adds the `.lain` symlink to the
checkout's git exclude file, since the ignore rule matches a directory only.

`bin/verify` rebuilds the toolchain (mise ruby 4.0.9, `LD_LIBRARY_PATH`) because the fence scrubs the
environment, compiles the extension, and runs `rake pspec`. It exits with the suite's status.

## Draining a chore file overnight

`lain todos drain` takes the open lines of the project's chore file (`TODOS.md`, or the file the
[`todos` verb](../users/configuration.md#todos) names) one at a time. Each runs a headless `lain chat` in its own
clone lease and lands what the chat committed through `lain land`. `lain todos status` counts the
lines and names who holds each claim, and `lain todos add 'tidy the README'` appends a line. The
full flags are under [`lain todos`](../users/commands.md#lain-todos).

The chore file stays out of git. The lease is a `git clone --shared` of the checkout, so a file git
does not track never reaches it, and the lease holds no copy of the queue. Add the line to
the checkout's exclude file once:

```bash
echo '/TODOS.md' >> "$(git rev-parse --git-path info/exclude)"
```

The drain lands on the main checkout's branch, so run it from the main checkout, with `.lain` trusted
there (`bin/dogfood-setup`, then `lain trust`). `.lain/` lives in the main checkout only; a lease reads
it from upstream.

### What runs unattended

- The chat runs confined, in a clone lease. Its working copy is a `git clone --shared` cut at the
  branch tip. Its file tools and its `bash` calls are refused when they land outside the lease, and
  the `bash` sandbox cannot write a byte of upstream. It runs `--approval auto --confirm-price-tier
  refuse --max-cost N`, so the judge answers first and parks what it cannot settle, and a
  run that outspends N stops. `--max-cost` defaults to 5 dollars per item.
- `bin/verify` runs the model's commit unconfined. The merge coordinator checks the commit out
  in the verify checkout and runs the suite as a plain subprocess of the drainer: your user, no
  sandbox, the whole network. Whatever the commit puts in the suite runs with your rights. Every
  `lain land` landing does the same, so an overnight drain adds no new exposure beyond having no human
  reading the diff first.
- A landing fast-forwards the branch only when the suite passed. A line ends `[x]` with the sha
  and the session path, or `[!]` with why. A failed landing keeps its lease for a human; a lease
  holding uncommitted work is kept too, and `lain worktrees gc` reaps the rest.

### Scheduling it

A `Persistent=true` timer fires once on the next start when the machine was off at the hour; a crontab line would silently skip it. A user unit inherits almost no environment, so the unit sets
`PATH` and `HOME`. Put the units in `~/.config/systemd/user/`, replace `/path/to/lain`
and `/path/to/checkout` with absolute paths, then `systemctl --user enable --now lain-todos.timer`.

```ini
# lain-todos.service
[Unit]
Description=Drain the lain chore file

[Service]
Type=oneshot
WorkingDirectory=/path/to/checkout
Environment=PATH=/usr/local/bin:/usr/bin:/bin:%h/bin:%h/.local/bin:%h/.cargo/bin
Environment=HOME=%h
ExecStart=/path/to/lain todos drain --max-items 5
StandardOutput=append:%h/.local/state/lain-todos.log
StandardError=append:%h/.local/state/lain-todos.log

# lain-todos.timer
[Unit]
Description=Drain the lain chore file nightly

[Timer]
OnCalendar=*-*-* 02:00
Persistent=true

[Install]
WantedBy=timers.target
```

On macOS, save this as `~/Library/LaunchAgents/dev.lain.todos.plist` and run
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.lain.todos.plist`. launchd starts jobs
with an empty locale, so the plist pins `LANG`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.lain.todos</string>
  <key>ProgramArguments</key>
  <array><string>/path/to/lain</string><string>todos</string><string>drain</string><string>--max-items</string><string>5</string></array>
  <key>WorkingDirectory</key><string>/path/to/checkout</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>/Users/you</string>
    <key>LANG</key><string>en_US.UTF-8</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>2</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>/Users/you/Library/Logs/lain-todos.log</string>
  <key>StandardErrorPath</key><string>/Users/you/Library/Logs/lain-todos.log</string>
</dict>
</plist>
```

A drain that dies leaves its claimed line behind. The next drain takes a line whose claimant is gone
back as abandoned, and `lain todos status` shows a claim whose pid is not live. If one chore line
keeps failing, edit it or delete it: the drain never retries a `[!]` line.
