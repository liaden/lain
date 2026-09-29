# Transparent huge pages and CPU offload, measured 2026-09-28

**Question:** are we using THP, and would it help once a bigger context pushes part of the model into system RAM?

**Answer: THP is on, it is mostly unavailable on this box, and it would not rescue offload anyway.**

## 1. THP is enabled, but coverage is ~6%

```
/sys/kernel/mm/transparent_hugepage/enabled = [always] madvise never
/sys/kernel/mm/transparent_hugepage/defrag  = always defer defer+madvise [madvise] never
```

`llama-server` smaps_rollup, qwen3.8:27b:

| state | Anonymous | AnonHugePages | share |
|---|---|---|---|
| fully on GPU | 982 MB | 166 MB | 17% |
| 11 of 66 layers on CPU | 1,958 MB | 94 MB | 5% |
| same, `use_mmap:false` | 1,153 MB | 74 MB | 6% |

## 2. Why: there are no free 2 MB blocks

`/proc/buddyinfo`, zone Normal, orders 9 and 10 (2 MB and 4 MB) are **0**:

```
Node 0, zone   Normal   2582 3235 2081 1306 347 1050 135 3 0 0 0
```

With `defrag=madvise` the kernel will not stall to compact memory for an allocation that did not ask via
`madvise(MADV_HUGEPAGE)`, and llama.cpp does not ask. khugepaged cannot collapse either — it needs a free
huge page to move into, and there are none (its counter sat unchanged across 45 s under load). So on a 15 GB
box with this much allocation churn, THP is enabled in name and largely absent in practice.

File-backed pages get nothing regardless: `FilePmdMapped: 0`. With mmap on (the default) the weights are page
cache, which THP does not cover at all.

## 3. It would not help anyway — offload is not a TLB problem

Measured with a ~2k-token prompt, `num_ctx` 8192, thinking off:

| configuration | prefill | decode |
|---|---|---|
| all 66 layers on GPU | 288 tok/s | **48.6 tok/s** |
| 55 on GPU, 11 on CPU, mmap on | 272 tok/s | **13.6 tok/s** |
| 55 on GPU, 11 on CPU, mmap off | 263 tok/s | **11.3 tok/s** |

**Moving one sixth of the layers to the CPU costs 72% of decode speed.** That is CPU memory bandwidth and
compute, not page-table overhead; THP is worth single-digit percentages against a 3.6x loss. Prefill barely
moves, because it stays GPU-bound.

`use_mmap:false` — the one change that would make the weights anonymous and therefore THP-eligible — was
**slower**, and still only reached 6% huge-page coverage.

## 4. What to do instead

1. **Do not offload.** Keep the model wholly in VRAM: lower `num_ctx`, keep `OLLAMA_KV_CACHE_TYPE=q8_0`
   (already set; ~1.9x more context per GB than f16), and prefer a model that fits.
2. **Prefer MoE when context must grow.** Fewer active parameters per token means a CPU-resident layer costs
   far less. On this box the MoE models also gained 23-38% prefill on 0.34.4 while the dense 27B models lost
   ~4x (see `UPGRADE-ollama-0.34.4.md`).
3. **qwen3.8:27b barely spills anyway** — at `num_ctx` 65536 it still reported `offloaded 66/66 layers`,
   because only 16 of its layers are attention (KV 2,176 MiB); the rest are recurrent. Large context is
   cheaper on it than the parameter count suggests.
4. **If you want to test THP properly**, it needs root and would only settle the small-percentage question:
   `echo 1 | sudo tee /proc/sys/vm/compact_memory` to defragment, optionally
   `echo defer+madvise | sudo tee /sys/kernel/mm/transparent_hugepage/defrag`, then re-run
   `~/tmp/lain/thp-test.py`. Explicit hugetlb pages would be guaranteed rather than best-effort, but
   llama.cpp does not allocate from hugetlbfs, so that is not reachable without patching it.
