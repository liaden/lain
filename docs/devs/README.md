# Developer documentation

For people changing lain. [CLAUDE.md](../../CLAUDE.md) holds the rules, and
[ROADMAP.md](../../ROADMAP.md) holds the plan.

## How it works

| Page | Covers |
|---|---|
| [architecture.md](architecture.md) | Each subsystem, with the files that implement it and the process diagrams. |
| [design.md](design.md) | The ideas behind the structure: the turn lifecycle, components, the bench. |
| [glossary.md](glossary.md) | The math and CS vocabulary the other pages use. |
| [agent-state-machine.md](agent-state-machine.md) | The agent loop's states, generated from the code. |
| [compaction.md](compaction.md) | How a compacting turn derives a second timeline. |
| [concurrency.md](concurrency.md) | Why the loop runs on fibers, with the measurements. |
| [review.md](review.md) | The review ports and where their ceilings come from. |
| [stall-clock.md](stall-clock.md) | How a stalled provider stream is detected. |
| [porting-providers.md](porting-providers.md) | Adding a provider. |
| [rust-bindings.md](rust-bindings.md) | The 5 tests a capability passes before it gets a Rust binding. |
| [neovim-protocol-history.md](neovim-protocol-history.md) | The Neovim runtime protocol, version by version. |

## Working on it

| Page | Covers |
|---|---|
| [toolchain-traps.md](toolchain-traps.md) | Failures that are not what they look like. |
| [spec-suite-performance.md](spec-suite-performance.md) | Worker counts, profiling and allocations. |
| [qa-lain.md](qa-lain.md) | `bin/qa-lain`: text-mode review, the bench and the session readers. |
| [dogfood.md](dogfood.md) | Running lain on its own checkout, and draining a chore file overnight. |
| [debugging-nvim.md](debugging-nvim.md) | Dated notes on the Neovim interface. |
| [debugging-ollama.md](debugging-ollama.md) | Dated notes on the local ollama arm. |

Each Rust component has its own README: [ext/lain](../../ext/lain/README.md),
[lain-daemon](../../crates/lain-daemon/README.md), [lain-fence](../../crates/lain-fence/README.md),
[lain-rpc](../../crates/lain-rpc/README.md), [lain-wire](../../crates/lain-wire/README.md) and the
phone app, [lain-remote](../../apps/lain-remote/README.md).
