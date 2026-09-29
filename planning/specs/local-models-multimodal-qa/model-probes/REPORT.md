# Local model probes — status

Two builds have now been measured. **Read the right file:**

| file | what it is |
|---|---|
| `REPORT-0.32.12.md` | the COMPLETE 9-model study, measured on ollama 0.32.12. Still the reference for model selection. |
| `scored/tables.md` | the current tables, measured on **0.34.4** — 8 models complete, `qwen3.8:27b` partial (speed/tools/review/plan done; QA 5 of 24 rows; vision missing). |
| `scored-0.32.12/`, `raw-0.32.12/` | the 0.32.12 rows and tables, archived intact. |
| `../UPGRADE-ollama-0.34.4.md` | the build comparison, the lfm2.5 regression, and the upstream issue map. |

## Before quoting any number from either build

- **Nothing here detects GPU contention from outside ollama.** The `contended` field only sees another
  ollama model. A game running on the card cut prefill ~60% during the first 0.34.4 run and nearly produced
  a false "the upgrade is 2x slower" conclusion — it survived two repeat runs, because the contention did.
  Sample `/sys/class/drm/card1/device/gpu_busy_percent` before scoring anything, and re-measure if it is not
  near idle.
- **`muse-glimmer:30b` and `qwen3.8:27b` prefill dropped ~4x on 0.34.4** and it REPRODUCES on an idle box —
  a real regression in the only two large dense models. Every MoE model gained 23-38%. See the upgrade doc.
- **`lfm2.5` results on 0.34.4 are a parser artefact, not model quality** — its reasoning arrives inside
  `content`, so nothing parses. Its 0.32.12 numbers are the real ones.

## The 0.34.4 run is COMPLETE (2026-09-28)

All nine models, `scored/tables.md`. `./run-all-0.34.4.sh` re-runs the batch, `./finish-0.34.4.sh` the tail.
Keep the GPU idle and watch free RAM: qwen3.8's runner holds ~7.5 GiB of host memory on top of its VRAM,
which is what killed an earlier attempt.

New on this build, beyond the upgrade doc's comparison:
- **`qwen3.8:27b` is the cleanest vision model measured**: 15/15 defect pages flagged AND named, **0/6 false
  alarms on clean pages**, 7.0 s mean. `ornith-1.5:9b` still names 20/20 but now false-alarms on 4/8 clean
  pages (it was 0/8 on 0.32.12), which matters for anything gating on it.
- **`qwen3.8:27b` QA is 100%** (24 rows, 8/8 items unanimous) — it is now the strongest model on every
  quality axis measured, and the slowest to prefill.
