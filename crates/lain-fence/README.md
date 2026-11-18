# lain-fence

Runs one command inside a Landlock domain built from its argv, then execs it, so the command and
everything it spawns inherit the restrictions. It is Linux only. Ruby's sandbox calls it from
`lib/lain/confine/sandbox.rb` and `lib/lain/confine/exec_rules.rb`.

```
lain-fence [grants] -- cmd args...
```

`src/main.rs` documents the grants (`--exec-dir`, `--exec-file`, `--read-dir` and the rest).

## Build

It builds one binary, `lain-fence`. `rake compile` builds it with the Ruby extension on Linux and
skips it elsewhere:

```bash
bundle exec rake compile
cargo build -p lain-fence --release     # the binary alone
```

## Tests

```bash
cargo test -p lain-fence
```

The tests in `tests/` (`fence.rs`, `memfd.rs`, `private_net.rs`, `reap.rs`, `sockets.rs`) run the
real binary and need a kernel with Landlock.

## Layout

- `main.rs`: the command line and what each grant means.
- `linux_main.rs`: the Linux entry point. Exit codes 125 (usage), 126 (not enforced) and 127 (exec failed).
- `rules.rs`: the grants turned into a Landlock domain. Every filesystem right is handled, so
  a path that is not granted is refused.
- `seccomp.rs`: a filter for what Landlock cannot name, such as executable memfds and io_uring.
- `netns.rs`: the check behind `--private-net`, read from `/proc/self/net/dev`.
- `reap.rs`: `--reap-only`, a reaper over the command's whole tree with no domain.
- `status.rs`: the one JSON line that reports what the fence enforced.

## Constraints

Landlock is best effort. A kernel older than a right drops it silently, and the status line is
where the drop shows. Read it before trusting a fence.

Related: [architecture](../../docs/devs/architecture.md).
