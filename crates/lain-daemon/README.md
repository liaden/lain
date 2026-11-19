# lain-daemon

The per-user daemon: a msgpack-RPC server on a Unix socket. Every chat registers with it, and it
supervises headless runs, runs the phone relay as a confined worker, and sends the ntfy notice.
Ruby starts and talks to it through `lib/lain/daemon/launch.rb`, `lib/lain/core/client.rb` and
`lib/lain/cli/daemon_command.rb`.

## Build

It builds one binary, `lain-daemon`:

```bash
bundle exec rake daemon:build     # release build, stamps the git sha
```

`Lain::Daemon::Launch` runs `target/release/lain-daemon`, so the plain `cargo build -p lain-daemon`
is only right for a debug binary.

## Tests

```bash
cargo test -p lain-daemon
bundle exec rake daemon:build && bundle exec rspec --tag core   # the Ruby client against the real binary
```

The integration tests are in `tests/` (`lifecycle.rs`, `relay.rs`, `supervisor.rs`).

## Layout

- `main.rs`: the server. Socket and trace path arrive in argv, and the build and settings digests
  in its environment; the binary never computes its own path.
- `registry.rs`: the live chats, each registered over its own connection.
- `supervisor.rs`: headless runs, each started from a closed set of kinds.
- `spawner.rs`: the end of `lain daemon spawner`, a Ruby process that forks each run (JSON lines).
- `periodic.rs`: the daemon's own timers.
- `relay.rs`: the phone relay, which confines itself with Landlock before it serves.
- `relay/agenda.rs`: the open items, recent deltas and answers, numbered by cursor.
- `relay/devices.rs`: the paired phones, as names and token digests.
- `agenda_watch.rs`: which items have waited long enough to buzz a phone.
- `ntfy.rs`: the notice, a title and a link and nothing of the item.

## Constraints

- Diagnostics go to the trace file, never a terminal. `main.rs` denies `clippy::print_stdout` and `print_stderr`.
- The relay worker confines itself with Landlock before it serves, which is why it is a process of
  its own. Only the main daemon calls ntfy.
- Anything async or I/O-bound belongs here and not in `ext/lain`; see [`../../ext/lain/CLAUDE.md`](../../ext/lain/CLAUDE.md).

Related: [`../lain-rpc`](../lain-rpc), [`../lain-wire`](../lain-wire),
[architecture](../../docs/devs/architecture.md), [phone approvals](../../docs/users/remote.md).
