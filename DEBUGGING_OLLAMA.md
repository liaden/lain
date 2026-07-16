# Debugging notes: the local ollama arm

Running log for the `--provider ollama` arm's serving stack. Same shape as
`DEBUGGING_NVIM.md`: symptom → diagnosis → fix, newest at the bottom.

## 2026-07-16 — first full `chat --provider ollama --nvim` e2e: the second turn never returns

**Symptom.** First end-to-end run of the whole stack (`lain chat --provider ollama --nvim
<sock>`, qwen3:4b, prompt: "read README.md and summarize it in a sentence"). Turn 1 behaves:
the model issues the `read_file` tool call, the result journals, `lain://request` renders it
live. Turn 2 — the request carrying the ~22.5KB README as a `tool_result` — never comes back:
20+ minutes, no response event in the journal, llama-server pinned at 100% CPU with 1h43m of
accumulated CPU time before we killed it.

**Diagnosis 1 — the brew ollama is CPU-only.** `ls
/home/linuxbrew/.linuxbrew/Cellar/ollama/*/libexec/lib/ollama/` shows *only*
`libggml-cpu-*.so` variants — no `vulkan/`, no `cuda_*/`, no ROCm. The homebrew formula
simply doesn't build GPU backends, so no environment variable can help; `/api/ps` reporting
`size_vram: 0` was the tell. Everything ran on 8 CPU cores at ~8–20 tok/s.

**Diagnosis 2 — `num_ctx` defaulted to 4096 and truncated silently.** The README alone is
~6–7k tokens; ollama loaded the model with a 4096 context (`ollama ps` CONTEXT column) and
llama-server's `--context-shift` silently evicted prompt tokens to cope. For a correctness
bench, silent truncation is poison — the model answers about a prompt it never fully saw,
and nothing in the journal says so. `Provider::Ollama` already honors `num_ctx` through
`Request#extra` (`Encoding::SAMPLER_KEYS`), but `exe/lain` exposes no flag for it —
follow-up below.

**Diagnosis 3 — the GPU was ready the whole time.** The box has an AMD RX 5700 (Navi 10).
ROCm does not officially support gfx1010, but Mesa's RADV Vulkan driver sees it as a
conformant 1.4 device (`vulkaninfo --summary`), and llama.cpp's Vulkan backend is mature.

**Fix.** Replace the brew server with the official release build, which ships the Vulkan
backend, and quantize the KV cache so 32k of context still fits in 8GiB of VRAM:

```sh
brew services stop ollama          # also deletes the brew systemd user unit
# official v0.32.1 tarball (assets are .tar.zst now; ollama.com/download/*.tgz 404s)
mkdir -p ~/.local/opt/ollama && cd ~/.local/opt/ollama
curl -fLO https://github.com/ollama/ollama/releases/download/v0.32.1/ollama-linux-amd64.tar.zst
tar --zstd -xf ollama-linux-amd64.tar.zst && rm ollama-linux-amd64.tar.zst

OLLAMA_VULKAN=1 OLLAMA_CONTEXT_LENGTH=32768 \
OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 \
  ~/.local/opt/ollama/bin/ollama serve
```

The KV settings are load-bearing, not tuning garnish: at 32k with f16 KV the footprint is
7.6GB against 6.3GB free VRAM, ollama splits 26%/74% CPU/GPU, and decode crawls at ~20
tok/s. With `q8_0` + flash-attn the same 32k fits at 5.2GB, `ollama ps` reports **100%
GPU**, and decode hits **~85 tok/s** (the brew build's own llama-server flags used q8_0
KV too, so this parity is deliberate).

**Result.** The identical e2e turn — tool call, full README as tool_result, final answer —
completes in **56 seconds** wall clock (vs. never, on CPU). Journal shows the whole loop
(2× `request_sent`, per-request `turn_usage`, 4 turns); all four `lain://` buffers render,
`lain://timeline` reading `user → assistant (thinking, tool_use) → user (tool_result) →
assistant`.

**Gotchas found on the way:**

- **Restart race.** A second interrupt makes `ollama serve` terminate *immediately*, but a
  server draining a runaway generation holds :11434 for many seconds after the first
  signal — a new serve started too eagerly dies on bind. Wait for the port to actually
  free (`ss -tln | grep 11434`) before restarting.
- **qwen3:4b thinking spirals.** On trivial prompts the model can burn thousands of
  thinking tokens (2,900 tokens deep on "say hello in three words" before we killed it).
  For raw API pokes, cap with `options.num_predict`; in lain, `--max-tokens` is the
  backstop. Bench arms should treat unbounded thinking as part of the cost distribution,
  not noise.
- **Durability.** `brew services stop` removed the autostart unit; the official build
  currently runs as a manual background process. If it should survive reboots, mirror the
  old unit as `~/.config/systemd/user/ollama.service` with the env vars above in
  `Environment=` lines.

**Follow-ups for lain proper:**

- `exe/lain chat`/`bench record` could take `--num-ctx`, threading `Request#extra["num_ctx"]`
  (the encoding already supports it). Better: `Provider::Ollama` could *refuse or warn*
  when a request it is about to send exceeds the server's context — silent truncation is
  exactly the kind of harness-induced variance the bench exists to catch.
- Ruby 4's `IO::Buffer is experimental` warning (from `journal.rb:139`) leaks onto the chat
  TTY. It is the interpreter talking, not an output-discipline violation, but it smears
  the frontend's screen — suppress with `Warning[:experimental] = false` in `exe/lain`.
