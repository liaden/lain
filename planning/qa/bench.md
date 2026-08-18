# The model server

**Shared by every scenario.** Bring this up before act 0 of anything, and record its numbers —
several of them are preconditions that are unrecoverable after the fact.

## There are two ollama installs on this box

The one `DEBUGGING_OLLAMA.md`'s 2026-07 fix block points at (`~/.local/opt/ollama`) uses
`~/.ollama/models`, which holds only `gemma4`, `nomic-embed-text` and `qwen3` — **not** the model
the scenarios name. Use the `/mnt/nvme` install:

```bash
. /mnt/nvme/opt/ollama-env.sh && ollama serve > "$QA/records/ollama-serve.log" 2>&1 &
curl -s localhost:11434/api/tags | command grep -q qwen3-coder:30b || abort
```

That env file sets `OLLAMA_CONTEXT_LENGTH=32768` — the number the occupancy expectations are
written against — and `OLLAMA_KEEP_ALIVE=5m`, which is what makes "cold" the default state after
any five-minute pause.

Also export `LAIN_NUM_BATCH=2048` into the server-starting shell. This box's serving notes say never
to omit it: ollama passes `-b 512`, overriding llama.cpp's 2048, at up to 8× prefill on Vulkan (the
6.5×-vs-1.31× discrepancy is recorded as unreconciled in `DEBUGGING_OLLAMA.md`).

## Record `OLLAMA_NUM_PARALLEL` and `n_slots` at bring-up

Both are **1** on this box, and that is the precondition for the whole class of contention defects
(round 3's F10): lain's own subagents contend for a single slot, so the loser waits SILENTLY and can
cross a stall timeout on a perfectly healthy server. Neither number appears in any pane:

```bash
command grep -oE 'OLLAMA_NUM_PARALLEL:[0-9]+|n_slots = [0-9]+' "$QA/records/ollama-serve.log" | sort -u
```

If a future box reports `n_slots > 1`, say so in the findings — every contention reading in the
scenarios assumes 1 and is void without it.

## Controlling residency

`ollama ps` reports it; `ollama run qwen3-coder:30b ""` makes it resident; `ollama stop
qwen3-coder:30b` evicts it; `OLLAMA_KEEP_ALIVE=5m` self-evicts. **Cold vs warm changes what the
window scenario measures**, so assert it rather than assuming it:

```bash
curl -s localhost:11434/api/ps | ruby -rjson -e 'j=JSON.parse(STDIN.read); puts j["models"].empty? ? "COLD" : j["models"].map{|m| "#{m["name"]} ctx=#{m["context_length"]}"}'
```

## Align the runner's context with every launch, or pay a reload

`lain ... --num-ctx N` forces an ollama runner RELOAD (~27s of silence) whenever N differs from the
resident runner's context, and two reloads inside one request window is what set round 3's F10 up.
Check `/api/ps` before each act and launch with the SAME `--num-ctx`.

## Model choice

**`qwen3-coder:30b`** — the only coding-tuned model present, a 30B MoE with 3B active, so ~2× decode
and ~3.9× prefill against the dense `qwen3.8:27b`.

`nemotron-3.5-lightning:30b` is **ruled out**: 23.68 GiB against ~22.5 usable, reports `offloaded
54/54`, then no log output for 40 minutes.

For a scenario that needs a *second* model (an eviction measurement, a summarizer-tier fall), note
that a second model on one GPU **evicts** the first — that is round 3's T12 measurement, 84.0s
against 7.5s — so it is a cost to schedule deliberately, not an accident to absorb.
