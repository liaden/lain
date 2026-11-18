# Debugging

What to check when lain misbehaves, for someone using it. Notes for people changing lain are at
the end.

## Where to look

| What | Where |
|---|---|
| This session's state | `/status` at `you>`: cache warmth, fleet size, inbox count. |
| Live objects | `/ruby` opens a console on the running session; `/ruby EXPR` prints one value. |
| The session record | `$XDG_STATE_HOME/lain/sessions/<project-hash>/`, 1 NDJSON file per session. `lain sessions` lists them, newest first. |
| A readable copy | `lain export SESSION` writes the conversation as 1 HTML page. `--jsonl` writes the full local record, which is not for sharing. |
| A subagent | `lain watch SELECTOR` tails 1 actor's lineage, read-only. |
| The HUD's source | `$XDG_STATE_HOME/lain/status/<project-hash>/state.json`. `lain up` prints the resolved path. |
| The daemon | `lain daemon status` shows its pid, build, relay state, sessions and runs. Its trace is `$XDG_RUNTIME_DIR/lain/daemon/daemon.trace` (`/tmp/lain/daemon/daemon.trace` when `XDG_RUNTIME_DIR` is unset). |
| Raw provider frames | `LAIN_STREAM_DEBUG=true` dumps each stream frame as it arrives. |

A launch that refuses names the file and line that stopped it. For an untrusted `.lain/*.rb` it
names [`lain trust`](docs/users/commands.md#lain-trust).

## Symptoms

| Symptom | Cause |
|---|---|
| Cache-hit ratio stays near zero on Claude | Anthropic's minimum cacheable prefix is 4096 tokens. A short system prompt silently will not cache, with no error and nothing on the wire to tell you. Check the prefix length before anything else. |
| Compaction leaves elision lines instead of summaries | With `--summarizer-provider ollama`, the local summarizer had nothing to answer it. `ollama serve` and `ollama pull qwen3:4b`. The fire fails inside its task boundary, so nothing raises. |
| HUD prints `lain: no state yet` | No session has published a state file for this project yet, or the file was written by a `lain` too old to publish the rendered line. `lain up` prints the path it is watching. This is a degraded state by design, never an error. |
| lain refuses to start, `$HOME is "" ... not an absolute path` | `$HOME` is empty or relative. Typical sources are a systemd unit with `Environment=HOME=`, an `env -i` cron job, or a container that sets it to something odd. An unset `$HOME` is fine: lain asks the passwd database. Every XDG fallback is built on `$HOME`, so a relative one would write lain's state into whatever directory you happen to be in. Export an absolute `HOME`. Setting `XDG_STATE_HOME`, `XDG_CONFIG_HOME` or `XDG_CACHE_HOME` fixes the paths but not the refusal: the secret-path classifier anchors on `$HOME` directly, and a relative anchor misclassifies in silence, which is worse than stopping. |
| `--windows` opens no subagent viewers | It needs `$TMUX` and a session journal. It is incompatible with `--no-journal`. |
| HUD freezes, `lain watch` stops updating, tools stop overlapping | Something is blocking the reactor. See [Slow middleware](docs/users/configuration.md#slow-middleware). |
| Ollama output differs run to run at `--temperature 0` | Local Ollama does not always reproduce: the first run after a model load and GPU float rounding both change the output. See [docs/users/providers/ollama.md](docs/users/providers/ollama.md#determinism). On `--provider ollama-cloud` it is expected, and nothing is wrong. |

## Phone approvals

[docs/users/remote.md](docs/users/remote.md) has a check after each setup step. A chat that could not
start the relay prints a `phone surface off:` line with the reason.

## For lain developers

- [docs/devs/toolchain-traps.md](docs/devs/toolchain-traps.md): failures that are not what they look
  like. Read it before believing a red suite.
- [docs/devs/debugging-nvim.md](docs/devs/debugging-nvim.md): dated notes on the Neovim interface.
- [docs/devs/debugging-ollama.md](docs/devs/debugging-ollama.md): dated notes on the local ollama arm.
- [docs/devs/qa-lain.md](docs/devs/qa-lain.md): `qa-lain friction SESSION` reads a finished session
  and reports which settings the run was fighting. It is offline and needs no API key.
