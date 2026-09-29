## Speed / residency (num_ctx 16384, num_batch 2048)

| model | load_s (first req) | prefill tok/s (cold prefix, ~7.6k tok) | decode tok/s (512-tok gen) | decode tok/s across all probe requests (mean / min) | VRAM @16k | VRAM @32k | contended |
|---|---|---|---|---|---|---|---|
| qwen3:4b | 7.1 | 3207 / 3213 | 161.4 | 141.5 / 94.2 | 3.9/3.9 GiB | 5.1/5.1 GiB | 4/5 |
| lfm2.5 | 7.6 | 6971 / 7535 | 133.2 | 129.8 / 115.6 | 5.2/5.2 GiB | 5.3/5.3 GiB | 0/5 |
| ornith-1.5:9b | 8.0 | 2682 / 2689 | 101.8 | 100.0 / 96.0 | 5.7/5.7 GiB | 6.0/6.0 GiB | 0/5 |
| gemma4:e4b | 11.4 | 3095 / 3311 | 102.4 | 96.0 / 92.9 | 3.5/3.5 GiB | 3.5/3.5 GiB | 0/5 |
| qwen3-coder:30b | 24.0 | 2302 / 2332 | 107.6 | 109.1 / 98.5 | 18.3/18.3 GiB | 19.2/19.2 GiB | 0/5 |
| laguna-xs-2.1 | 20.4 | 2732 / 2772 | 133.5 | 120.8 / 114.9 | 19.3/19.3 GiB | 19.3/19.3 GiB | 0/5 |
| north-mini-code-1.0 | 19.5 | 2114 / 2152 | 127.1 | 113.3 / 63.1 | 18.0/18.0 GiB | 18.1/18.1 GiB | 0/5 |
| muse-glimmer:30b | 21.5 | 813 / 811 | 39.5 | 37.4 / 37.1 | 15.9/15.9 GiB | 15.9/15.9 GiB | 0/5 |
| qwen3.8:27b | 25.5 | 702 / 717 | 66.1 | 85.9 / 58.6 | 16.5/16.5 GiB | 16.6/16.6 GiB | 0/5 |

## Tool-call fidelity (8 tasks x n runs)

| model | n | tool called | valid args | right tool | exact path/cmd | edit old_string verbatim (2 tasks) | all-correct rate | worst task (all-correct over its runs) | mean eval tok | mean wall s | max wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 32 | 100% | 100% | 100% | 100% | 8/8 | 100% | read_v2 4/4 | 687 | 5.4 | 26.5 |
| lfm2.5 | 32 | 100% | 100% | 100% | 94% | 8/8 | 94% | read_v3draft 2/4 | 319 | 2.9 | 11.0 |
| ornith-1.5:9b | 32 | 100% | 100% | 75% | 69% | 4/8 | 69% | run_deploy 0/4 | 74 | 1.1 | 1.6 |
| qwen3-coder:30b | 32 | 53% | 53% | 53% | 53% | 8/8 | 53% | read_v2 0/4 | 49 | 0.7 | 1.5 |
| laguna-xs-2.1 | 32 | 100% | 100% | 72% | 72% | 3/8 | 72% | run_deploy 0/4 | 84 | 0.9 | 1.8 |
| north-mini-code-1.0 | 32 | 100% | 100% | 75% | 75% | 3/8 | 72% | edit_typo_tabs 1/4 | 134 | 1.6 | 4.2 |
| qwen3.8:27b | 24 | 100% | 100% | 100% | 100% | 6/6 | 100% | read_v2 3/3 | 82 | 1.7 | 2.9 |

## Planted-defect code review (4 planted bugs; n runs)

| model | n | parsed | TP mean (worst) /4 | recall | FP mean (worst) | precision | bugs found per run | eval tok mean (max) | think share | wall s mean (max) | truncated |
|---|---|---|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 4 | 0/4 | - | - | - | - | - | 6144 | 100% | 66 | 4 |
| lfm2.5 | 4 | 4/4 | 1.00 (1) | 25% | 1.50 (2) | 40% | BUG3; BUG3; BUG3; BUG3 | 4915 (5472) | 97% | 42 (48) | 0 |
| ornith-1.5:9b | 4 | 0/4 | - | - | - | - | - | 6144 | 100% | 65 | 4 |
| qwen3-coder:30b | 4 | 4/4 | 1.75 (0) | 44% | 0.75 (1) | 70% | BUG3,BUG4; BUG3,BUG4; BUG1,BUG3,BUG4; - | 174 (227) | 0% | 2 (3) | 0 |
| laguna-xs-2.1 | 4 | 4/4 | 3.25 (3) | 81% | 0.25 (1) | 93% | BUG1,BUG2,BUG3,BUG4; BUG1,BUG2,BUG4; BUG1,BUG3,BUG4; BUG1,BUG3,BUG4 | 1610 (2547) | 88% | 14 (22) | 0 |
| north-mini-code-1.0 | 4 | 0/4 | - | - | - | - | - | 6144 | 100% | 98 | 4 |
| qwen3.8:27b | 3 | 3/3 | 4.00 (4) | 100% | 0.00 (0) | 100% | BUG1,BUG2,BUG3,BUG4; BUG1,BUG2,BUG3,BUG4; BUG1,BUG2,BUG3,BUG4 | 1802 (2193) | 80% | 25 (32) | 0 |

## Plan review (3 planted plan defects; n runs)

| model | n | parsed | found mean (worst) /3 | per-defect hits D1/D2/D3 | false alarms mean (worst) | eval tok mean (max) | think share | wall s mean (max) |
|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 4 | 2/4 | 2.50 (2) | 2/1/2 of 2 | 0.00 (0) | 6038 (6144) | 99% | 53 (55) |
| lfm2.5 | 4 | 4/4 | 1.50 (1) | 2/0/4 of 4 | 0.75 (2) | 3790 (5164) | 96% | 30 (42) |
| ornith-1.5:9b | 4 | 2/4 | 3.00 (3) | 2/2/2 of 2 | 0.00 (0) | 5146 (6144) | 97% | 52 (62) |
| qwen3-coder:30b | 4 | 4/4 | 2.75 (2) | 4/3/4 of 4 | 1.75 (3) | 240 (327) | 0% | 2 (3) |
| laguna-xs-2.1 | 4 | 4/4 | 3.00 (3) | 4/4/4 of 4 | 0.25 (1) | 2196 (3314) | 92% | 19 (28) |
| north-mini-code-1.0 | 4 | 0/4 | - | - | - | 6144 | 99% | 91 |
| qwen3.8:27b | 3 | 3/3 | 3.00 (3) | 3/3/3 of 3 | 0.00 (0) | 1761 (2122) | 81% | 23 (28) |

## QA AC verification (8 items: 4 pass, 4 subtle fail; n runs each)

| model | n | accuracy | accuracy greedy (t0) | worst item acc | unsure rate | items unanimous across runs | unanimous-and-wrong items | wrong verdict on a TRUE-FAIL item (missed violation) | eval tok mean | wall s mean (max) |
|---|---|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 32 | 84% | 7/8 | 0% | 0% | 7/8 | q6_sort_bad | 0/16 | 2177 | 17.8 (54.1) |
| lfm2.5 | 32 | 78% | 7/8 | 0% | 3% | 7/8 | q6_sort_bad | 6/16 | 490 | 4.0 (7.1) |
| ornith-1.5:9b | 32 | 97% | 7/8 | 75% | 0% | 7/8 | - | 0/16 | 846 | 9.0 (63.8) |
| qwen3-coder:30b | 32 | 88% | 7/8 | 0% | 0% | 8/8 | q6_sort_bad | 4/16 | 67 | 0.9 (1.1) |
| laguna-xs-2.1 | 32 | 100% | 8/8 | 100% | 0% | 8/8 | - | 0/16 | 594 | 5.1 (20.3) |
| north-mini-code-1.0 | 32 | 100% | 8/8 | 100% | 0% | 8/8 | - | 0/16 | 610 | 5.6 (14.6) |
| qwen3.8:27b | 24 | 96% | 8/8 | 67% | 0% | 7/8 | - | 0/12 | 438 | 6.9 (30.0) |

## Vision / screenshot QA (7 pages: 5 planted defects, 2 clean; n runs each)

| model | n | parsed | defect pages flagged fail | ...and named the right defect | clean pages false alarm | per-page right-defect (v2 overlap/v3 trunc/v4 text/v5 contrast/v7 table) | eval tok mean | prompt tok (image) | wall s mean (max) |
|---|---|---|---|---|---|---|---|---|---|
| ornith-1.5:9b | 28 | 28/28 | 20/20 | 20/20 | 0/8 | 4/4 4/4 4/4 4/4 4/4 | 324 | 1166 | 4.3 (12.1) |
| gemma4:e4b | 28 | 28/28 | 12/20 | 8/20 | 0/8 | 0/4 4/4 4/4 0/4 0/4 | 508 | 446 | 6.1 (8.0) |
| muse-glimmer:30b | 28 | 27/28 | 19/20 | 19/20 | 3/8 | 3/4 4/4 4/4 4/4 4/4 | 434 | 1460 | 12.8 (22.1) |
| qwen3.8:27b | 21 | 20/21 | 14/15 | 14/15 | 2/6 | 3/3 3/3 2/3 3/3 3/3 | 298 | 1111 | 6.9 (29.8) |

## Requests timed while another model was resident

- qwen3:4b: 1 requests with (another model appeared during the request) also resident
- qwen3:4b: 55 requests with gemma4:e4b also resident
