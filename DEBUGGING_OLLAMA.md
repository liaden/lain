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


## 2026-08-14 — GPU upgrade (RX 5700 → RX 7900 XTX): full serving-stack characterisation

**Context.** The card changed from Navi 10 (8GiB, ROCm-unsupported, Vulkan-only) to **Navi 31,
24GiB** — reported by Vulkan as `AMD Radeon RX 7900 XTX (RADV NAVI31)`. Server rebuilt on
**v0.32.12**; model store moved to the 4TB NVMe (`OLLAMA_MODELS=/mnt/nvme/ollama/models`), which
also frees the 88%-full root disk. Harness: `bin/bench-ollama-gpu` (see § *Reproducing this*).

Read § *How these were measured* before trusting or extending any number here. The headline
finding is a **measurement artifact that survived three rounds of self-review**, and the same trap
is waiting for the next person.

### The headline: ollama's `num_batch` default costs up to 3x decode and 8x prefill

Ollama passes `-b 512` to llama-server explicitly, **overriding llama.cpp's own default of 2048**.
Raising it is not tuning past upstream; it is undoing an override. On Vulkan it is the single
biggest setting on this box, and it moves *both* phases:

| model | arch | decode @512 | decode @2048 | prefill @512 | prefill @2048 |
|---|---|---|---|---|---|
| `qwen3:4b` | 4B dense | 150.3 | **164.4** | 680 | **2,820** |
| `qwen3-coder:30b` | 30B MoE, 3B active | 118.4 | **128.8** | 340 | **2,222** |
| `qwen3.8:27b` | 27B dense (`qwen35`) | 23.1 | **65.2** | 89 | **577** |
| `muse-glimmer:30b` | 30B dense | 34.7 | **39.0** | 78 | **663** |

Vulkan, `num_ctx=32768`, KV `q8_0`, 7,496-token prompt for prefill, 300-token generations for
decode, medians of 3+ reps. **Pass it per request (`options.num_batch`) — there is no server-side
default for it**, so a caller that forgets gets 512.

`qwen3.8:27b` is the one to notice: **23 → 65 tok/s, a 2.7x swing on decode alone**, verified
interleaved (512: 23.1, 23.4 / 2048: 63.5, 59.6). Batch sensitivity is strongly model-dependent
and not predictable from architecture — the two dense 30B-class models differ by 2.7x and 1.1x
respectively.

**This corrected a conclusion this file previously stated.** Measured at the default batch, the
30B MoE looked **5.4x** faster at decode than the 27B dense, and that was written up as "the
MoE/dense split dominates everything else." At matched, correct batch the gap is **2.0x**
(128.8 vs 65.2). The MoE advantage is real; the number was inflated by ~2.7x by a config artifact
that hit the dense model hardest. Any claim below that compares models is only as good as the
batch setting it was taken at.

The trail: an HN commenter (id=49241679) reported ~700 tok/s prompt for `muse-glimmer:30b` on a
*7900XT* — a weaker card — where this box measured 78. Decode matched theirs closely (34.7 vs ~36),
which is what made the prefill gap worth chasing rather than dismissing: same model, same quant
class, same backend, one number 9x off. At `num_batch=2048` this box reads 663, landing on their
700 and closing the loop.

### Model selection for the local arm

At correct settings, Vulkan, 32k, q8_0, all fully GPU-resident:

| model | VRAM | layers | decode | prefill | verdict |
|---|---|---|---|---|---|
| `qwen3-coder:30b` | 17,524 MiB | 49/49 | **128.8** | 2,222 | **the pick** — MoE, tool-trained, 256k ctx |
| `qwen3:4b` | 2,376 MiB | 37/37 | 164.4 | 2,820 | fastest; the prior default, still fine for cheap work |
| `qwen3.8:27b` | 15,339 MiB | 66/66 | 65.2 | 577 | strongest dense, half the speed |
| `muse-glimmer:30b` | 15,246 MiB | 53/53 | 39.0 | 663 | slowest; per its own thread, aimed at guardrails not coding |

`qwen3:4b` went **85 → 164 tok/s** on the identical model — the clean statement of the GPU upgrade
with the model held fixed, since it is the model the 2026-07 numbers were taken on.

**`nemotron-3.5-lightning:30b` does not fit and fails badly rather than cleanly.** 32.9B params
(`nemotron_h_moe`), Q4_K_M blob **23.68 GiB against ~22.5 GiB usable** — the weights alone exceed
VRAM at any context length. Ollama's automatic sizing nonetheless reports `offloaded 54/54 layers
to GPU` and then wedges: GPU at 14% busy, VRAM pinned, `llama-server` in state `R` spinning on CPU,
**no log output for 40 minutes** mid-generation, and the desktop pushed into swap. Pinning below
the fit line runs (28.75 tok/s at `num_gpu=46, num_ctx=8192`, 150-token generation) but a 300-token
generation wedged again. Unusable here; the failure mode is a hang, not an error.

### KV cache: q8_0 vs f16, and where the context ceiling actually is

Prompted by an HN comment (id=49299605, `Aurornis`) warning that q8_0 KV "comes with notable drops
in performance for longer tasks." The 8GiB card forced q8_0; 24GiB makes it a choice.
`qwen3-coder:30b`, Vulkan, `num_batch=2048`, 200-token generations:

| context | q8_0 KV | q8_0 tok/s | f16 KV | f16 tok/s |
|---|---|---|---|---|
| 32k | 1,632 MiB | 127.3 | 3,072 MiB | **143.5** |
| 48k | — | — | 4,608 MiB | 56.8 |
| 64k | 3,264 MiB | **119.8** | 6,144 MiB | 40.2 |
| 96k | 4,896 MiB | 49.8 | 9,216 MiB | 24.2 |
| 128k | 6,528 MiB | 33.6 | — | — |

**Usable ceiling ~64k on q8_0, ~32k on f16** — the switch halves it. Per 1k tokens the cache costs
**51.0 MiB at q8_0 and 96.0 MiB at f16** (1.88x, not 2x: q8_0 carries per-block scales).

Two things worth keeping. **At 32k, f16 is 13% FASTER than q8_0** (143.5 vs 127.3) — quantized KV
trades decode throughput for capacity, so q8_0 buys 2x context at ~13% speed rather than being a
pure win; if the work fits in 32k, f16 wins on speed *and* on the quality concern above. And
**"it loads" is not "it works"**: f16 at 96k reports `offloaded 49/49 layers to GPU`, allocates a
9,216 MiB cache and generates correct output — at 24 tok/s, a 6x collapse, because the cache no
longer fits and spills. Sizing by what loads without erroring picks a configuration six times too
slow, silently.

Compute buffers also consume VRAM and scale with `num_batch` (464 MiB at 2048, 1,856 MiB at 4096
for this model), so batch size, context length and KV precision compete for one budget.

### ROCm vs Vulkan: split decision, and ROCm is not reliable here yet

`/dev/kfd` is `root:render` with no ACL, so ROCm sees no device until the user is in the `render`
group (`sudo usermod -aG render,video "$USER"`; `sg render` picks it up without a logout). Until
then ollama **silently** falls back to Vulkan — which is also why the 2026-07 entry's
`OLLAMA_VULKAN=1` was doing real work. The ollama ROCm tarball ships `rocm_v7_2` with its own
`libamdhip64`, so AMD's `/opt/rocm` SDK is **not** needed. Force either backend with
`OLLAMA_LLM_LIBRARY=rocm_v7_2` / `=vulkan`; ROCm reports slightly more usable VRAM (23.9 vs 22.6 GiB).

`qwen3-coder:30b`, the one model that ran on both:

| | Vulkan | ROCm |
|---|---|---|
| decode | **119–131** | 92 |
| prefill @ ollama default (512) | 340 | **2,763** |
| prefill @ 2048 | 2,222 | ~2,100–3,000 |

**Vulkan wins decode by ~30%; ROCm wins prefill at defaults by 8x**, because ROCm is insensitive to
the `num_batch` default that cripples Vulkan. Interleaved 5-pass sweep on ROCm:

| num_batch | 256 | 512 | 1024 | **2048** | 4096 | 8192 |
|---|---|---|---|---|---|---|
| median prefill | 1,798 | 1,856 | 2,071 | **2,141** | 2,123 | 2,002 |

2048 is the optimum on both backends (4096 ties, 8192 regresses); on ROCm it is worth +15%, on
Vulkan up to 8x.

**ROCm's reliability is the problem.** `qwen3.8:27b` loads its tensors (66/66 layers, 15,339 MiB)
and then never becomes available — repeated attempts dying on `timed out waiting for llama-server
to start`, including at a 20-minute `OLLAMA_LOAD_TIMEOUT`, GPU at ~29% throughout. Model re-loads
at a new `num_ctx` fail the same way. The same model runs fine on Vulkan. **Vulkan is the default
to recommend**: faster where decode matters, starts promptly, runs every model tried. The ROCm
comparison rests on a single model, so treat "Vulkan decodes faster" as solid and "ROCm prefills
faster at defaults" as one data point.

### Thermals: not the limit, even with no case fans

This box has **no case fans** — the card's own cooler is the entire solution — so this was worth
measuring rather than assuming. 196-second soak, 24,000 tokens, `qwen3-coder:30b`:

| | value |
|---|---|
| peak / final junction | 96C / 96C (plateaued) |
| peak / final VRAM (`mem`) | 92C / 92C (plateaued) |
| peak edge | 77C |
| peak power | 333W |
| peak fan | 1,751 RPM |
| throughput, 12 rounds | 124 124 127 124 124 123 125 125 125 124 126 124 |

Temperatures **plateau rather than climb**, ~14C below the ~110C junction throttle, with clocks
pinned at 1,249 MHz and no throughput decay. Fan peaked at 1,751 RPM, well short of its range, so
there is cooling headroom in reserve. Watch **`mem`**, not edge: it runs ~15C above edge at idle
and is the sensor closest to its limit. Caveat: 196s is long enough for the *card* to plateau, not
the *case* — with no case fans, ambient rises on a much slower time constant, so a multi-hour job
is untested.

### System RAM is not the constraint for a model that fits

Measured across a load of the 18GB `qwen3-coder:30b`: `llama-server` RSS **49.9 MB**, system `used`
unchanged (7,007 → 6,951 MB), `buff/cache` up 746 MB. Weights stream NVMe → page cache → VRAM and
the page cache is reclaimable, so 15.9GB of system RAM is ample. RAM binds only when the model
*doesn't* fit: the nemotron wedge drove zram swap to 82% and left memory pressure at 3.1% against
the 0.35% baseline in CLAUDE.md, long after the process was killed.

### The rest of llama.cpp's knobs are NOT reachable through ollama

The shipped `llama-server` supports the full surface — `-ub/--ubatch-size`, `--spec-type`
(including `ngram-mod`/`ngram-cache`, which need no draft model), `--cache-reuse`,
`--no-context-shift` — each with a `LLAMA_ARG_*` env var, 130+ of them. **They do not pass
through.** Verified: with `LLAMA_ARG_UBATCH=1024` exported into `ollama serve`, the runner still
reports `n_ubatch = 512`. Ollama builds the command line itself. The reachable surface is
`num_ctx`, `num_batch`, `num_gpu`, `num_thread`, `use_mmap`, `use_mlock` via API options, plus
`OLLAMA_FLASH_ATTENTION` / `OLLAMA_KV_CACHE_TYPE` / `OLLAMA_CONTEXT_LENGTH`.

That matters because the biggest untested win is out of reach: **ngram speculative decoding**
self-speculates from repeated context, which is the shape of an agentic loop quoting tool results
back turn after turn. Reported effect elsewhere is large (36 → 60 tok/s via `draft-dflash` on
`muse-glimmer`, id=49241679). Testing it means driving `lib/ollama/llama-server` directly — a bench
arm, not an ollama setting. Two independent reports (id=49299605) say `--spec-draft-n-max` 2–3
beats over-drafting, so do not raise it blindly.

### How these were measured — read this before extending the numbers

Four traps, all of which produced confident wrong answers here first.

1. **The prompt cache fakes prefill.** llama.cpp caches by prompt *prefix*, so a repeated prompt
   reports a rate that is not a measurement: reps 2 and 3 of an identical 7.5k-token prompt read
   **393,042 and 423,914 tok/s**. Only rep 1 was real. Every prefill prompt must carry a unique
   leading nonce, which invalidates the whole cache and forces genuine work.
2. **A blocked sweep lies; interleave it.** Sweeping all reps of one `num_batch` before moving to
   the next gave a **1.7x spread within a single value** (2,154 vs 3,661 at nb=2048) — wider than
   the difference between values — with rep1 systematically below rep2. Cycling the values
   round-robin spreads warm-up and ambient load across all of them instead of concentrating it on
   whichever ran first. This is the same failure CLAUDE.md documents for the spec-worker sweep.
3. **"Loads" is not "works", and neither is "offloaded N/N layers".** Both nemotron (wedged at
   54/54) and f16-at-96k (6x slow at 49/49) reported full offload. The layer count describes intent,
   not residency. Score on the tok/s curve.
4. **One config change can invalidate a cross-model conclusion.** The MoE-vs-dense ratio moved from
   5.4x to 2.0x on a single setting. Before comparing models, verify the setting is optimal *for
   each of them* — batch sensitivity ranged from 1.1x to 2.7x across four models here.

Two smaller ones: `jq` fails on generated text containing raw control characters, so extract timing
fields with `grep -oE '"eval_count":[0-9]+'` rather than parsing the whole response; and ollama
respawns a killed `llama-server` for any queued request, so stop `ollama serve` first when
aborting a run or the runner comes straight back.

**On precision.** Run-to-run spread is roughly ±2% once the config is right: `qwen3-coder:30b`
decode at `num_batch=2048` read **127.1–132.0 across 7 samples in 3 sessions, median 128.8**. So a
difference under ~5% is noise here and should not be reported as a result — which is also why the
`num_batch` effects above (10%, 170%, 650%) are safe to call, and why the ROCm 2048-vs-4096
distinction (2,141 vs 2,123) is not.

### Reproducing this

`bin/bench-ollama-gpu` carries every harness used above as subcommands — `decode`, `prefill`,
`batch-sweep` (interleaved), `kv-ceiling`, `thermals`, `summarize`. Raw NDJSON from this run is not
committed; the tables above are the record. Run `bin/bench-ollama-gpu --help` for usage. The
recommended serving config, with its reasoning, is in `/mnt/nvme/opt/ollama-env.sh`.

## 2026-08-17 — the num_batch prefill gap is unreconciled, and the arm bench methodology changed

Two records for anyone about to trust a number from this file or from a recorded arm sweep.

### The `num_batch` prefill claim: 6.5x above, 1.31x in the POC — both real, not reconciled

The § *headline* table above measured `qwen3-coder:30b` prefill at **340 → 2,222 tok/s (6.5x)**
going from `num_batch=512` to `2048` — Vulkan, `num_ctx=32768`, KV `q8_0`, a fixed 7,496-token
prompt, medians of 3+ interleaved reps (§ *How these were measured*).

The 2026-08-15 manual integration POC measured the same model on the same axis, on the same box
and the same ollama build, and got **1,201/1,194 → 1,578/1,562 tok/s (1.31x)** — two reps with
distinct random-nonce prompts (trap 1 above: a repeated prompt hits the prompt cache and fakes
the rate), both replicating each other.

| source | num_batch=512 | num_batch=2048 | ratio |
|---|---|---|---|
| this file, 2026-08-14 (`bin/bench-ollama-gpu prefill`) | 340 tok/s | 2,222 tok/s | 6.5x |
| 2026-08-15 integration POC (2 reps, distinct prompts) | 1,201 / 1,194 tok/s | 1,578 / 1,562 tok/s | 1.31x |

Same model, same axis, same box, same build — and even the *baselines* disagree by ~3.5x before
either ratio is taken. **This is an open discrepancy, not a correction of either number.** Neither
run is known to be wrong, so neither is overwritten and the two are not averaged. Candidates
nobody has checked yet: prompt length/shape (this file's harness pins a fixed 7,496-token prompt;
the POC's prompts were not built by that harness), a `num_ctx` difference at request time, KV
cache state left over from a prior run on the same server process, or genuine drift in `ollama
serve`'s behavior between the two sessions. Whoever picks this up next should re-run both
harnesses back to back, interleaved, against the same warm server, before trusting either figure
for a decision.

### Arm bench methodology changed: `DualLedger` now settles on its own ledger, not the grader

`Arm::DualLedger` used to run its outer loop until the grader passed, which handed that one arm
an oracle its controls (`SingleThread`, `OrchestratorWorker`) never got — a cross-arm score
comparison then measured protocol rather than strategy, and an ungradeable task burned the whole
step ceiling in model calls (measured pre-change: **18x the controls' tokens** on one ungradeable
task, 2,546 vs 141/162). As of this chunk it settles on its **own ledger's progress reading**
instead — the outer loop stops when the ledger stalls out with its rewrite already spent, or
`max_steps` binds — and the grader is asked **exactly once**, at the end, for the `Run`'s grade,
same as the other two arms. The run's terminal state is now journaled rather than inferred:
`:stalled` (the ledger dried up for good) vs `:done` (the step ceiling bound first — which is NOT
the same claim as "finished healthy").

Three consequences for anyone reading numbers recorded before this date against numbers recorded
after it — **they are not the same measurement:**

- **Grader calls per dual-ledger run:** every outer step under the old protocol (up to
  `DEFAULT_MAX_STEPS`, 6) → exactly 1 now.
- **Token cost per run drops accordingly** — no more oracle-chasing on tasks the grader never
  passes — but the arm still spends more than its controls: `bench/cli.rb`'s live-cost warning
  now says the dual-ledger arm asks the provider roughly `DEFAULT_MAX_STEPS` (6) times on
  essentially every task (its ceiling is the typical case now, not the worst one), so a live
  `bench arms` run should be budgeted at roughly 5x a control arm's cost.
- **The sweep report's disclosure changed.** `Bench::ArmSweep::Report` used to say single-thread
  and dual-ledger produce identical grade *and token* rows under the offline mock replay, with
  the difference visible only in the replans/stalls metric. That is now false: the grade rows
  still tie (an artifact of prompt-keyed replay, not a finding — see the report's own `NOTE:`
  text), but the **token rows separate by about 5x** (`recordings.yml`: single-thread 998 vs
  dual-ledger 4,990). Read the current `NOTE:` block at the top of any `arm sweep` report, or
  `lib/lain/bench/arm_sweep/report.rb`'s `NOTES` constant, for the live wording rather than
  trusting a copy made before this entry.

Any arm-sweep table recorded before 2026-08-17 should be treated as pre-methodology-change and
re-run, not compared directly against new output.
