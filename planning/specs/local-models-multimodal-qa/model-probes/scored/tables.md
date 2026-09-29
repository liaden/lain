## Speed / residency (num_ctx 16384, num_batch 2048)

| model | load_s (first req) | prefill tok/s (cold prefix, ~7.6k tok) | decode tok/s (512-tok gen) | decode tok/s across all probe requests (mean / min) | VRAM @16k | VRAM @32k | contended |
|---|---|---|---|---|---|---|---|
| qwen3:4b | 4.2 | 3956 / 3975 | 150.3 | 135.8 / 97.4 | 3.9/3.9 GiB | 5.1/5.1 GiB | 0/5 |
| lfm2.5 | 3.9 | 7696 / 8057 | 147.1 | 145.4 / 141.3 | 5.2/5.2 GiB | 5.3/5.3 GiB | 0/5 |
| ornith-1.5:9b | 7.2 | 2556 / 2614 | 95.7 | 97.0 / 92.9 | 5.7/5.7 GiB | 6.0/6.0 GiB | 0/5 |
| gemma4:e4b | 6.2 | 2611 / 3274 | 100.0 | 97.7 / 96.5 | 3.5/3.5 GiB | 3.5/3.5 GiB | 0/5 |
| qwen3-coder:30b | 23.2 | 3141 / 3148 | 95.0 | 101.9 / 89.5 | 18.3/18.3 GiB | 19.2/19.2 GiB | 0/5 |
| laguna-xs-2.1 | 19.1 | 3369 / 3436 | 127.6 | 117.1 / 111.9 | 19.3/19.3 GiB | 19.3/19.3 GiB | 0/5 |
| north-mini-code-1.0 | 17.7 | 2915 / 2945 | 124.0 | 103.4 / 59.9 | 18.0/18.0 GiB | 18.1/18.1 GiB | 0/5 |
| muse-glimmer:30b | 24.1 | 158 / 160 | 39.0 | 36.9 / 34.5 | 15.9/15.9 GiB | - | 0/4 |
| qwen3.8:27b | 22.3 | 196 / 193 | 56.3 | 87.1 / 71.3 | 16.5/16.5 GiB | - | 0/4 |

## Tool-call fidelity (8 tasks x n runs)

| model | n | tool called | valid args | right tool | exact path/cmd | edit old_string verbatim (2 tasks) | all-correct rate | worst task (all-correct over its runs) | mean eval tok | mean wall s | max wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 32 | 100% | 100% | 100% | 100% | 8/8 | 100% | read_v2 4/4 | 791 | 6.0 | 24.6 |
| lfm2.5 | 32 | 100% | 100% | 100% | 94% | 7/8 | 91% | read_v3draft 2/4 | 378 | 2.6 | 21.2 |
| ornith-1.5:9b | 32 | 100% | 100% | 81% | 78% | 7/8 | 78% | run_deploy 0/4 | 79 | 0.9 | 1.9 |
| qwen3-coder:30b | 32 | 50% | 50% | 50% | 50% | 8/8 | 50% | read_v2 0/4 | 51 | 0.5 | 1.4 |
| laguna-xs-2.1 | 32 | 100% | 100% | 72% | 72% | 4/8 | 72% | run_deploy 0/4 | 91 | 0.9 | 2.1 |
| north-mini-code-1.0 | 32 | 100% | 100% | 78% | 78% | 3/8 | 72% | edit_typo_tabs 1/4 | 132 | 1.3 | 3.3 |
| qwen3.8:27b | 24 | 100% | 100% | 88% | 88% | 6/6 | 88% | run_deploy 0/3 | 83 | 1.8 | 3.9 |

## Planted-defect code review (4 planted bugs; n runs)

| model | n | parsed | TP mean (worst) /4 | recall | FP mean (worst) | precision | bugs found per run | eval tok mean (max) | think share | wall s mean (max) | truncated |
|---|---|---|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 4 | 0/4 | - | - | - | - | - | 6144 | 100% | 63 | 4 |
| lfm2.5 | 4 | 0/4 | - | - | - | - | - | 5631 | 0% | 39 | 1 |
| ornith-1.5:9b | 4 | 0/4 | - | - | - | - | - | 6144 | 100% | 64 | 4 |
| qwen3-coder:30b | 4 | 4/4 | 2.25 (2) | 56% | 0.75 (1) | 75% | BUG1,BUG3,BUG4; BUG3,BUG4; BUG3,BUG4; BUG3,BUG4 | 214 (229) | 0% | 2 (3) | 0 |
| laguna-xs-2.1 | 4 | 4/4 | 3.25 (3) | 81% | 0.00 (0) | 100% | BUG1,BUG2,BUG3,BUG4; BUG1,BUG3,BUG4; BUG1,BUG3,BUG4; BUG1,BUG3,BUG4 | 1616 (2624) | 89% | 14 (24) | 0 |
| north-mini-code-1.0 | 4 | 1/4 | 3.00 (3) | 75% | 2.00 (2) | 60% | BUG1,BUG3,BUG4 | 5985 (6144) | 99% | 98 (102) | 3 |
| qwen3.8:27b | 3 | 3/3 | 4.00 (4) | 100% | 0.00 (0) | 100% | BUG1,BUG2,BUG3,BUG4; BUG1,BUG2,BUG3,BUG4; BUG1,BUG2,BUG3,BUG4 | 2527 (2771) | 85% | 35 (46) | 0 |

## Plan review (3 planted plan defects; n runs)

| model | n | parsed | found mean (worst) /3 | per-defect hits D1/D2/D3 | false alarms mean (worst) | eval tok mean (max) | think share | wall s mean (max) |
|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 4 | 1/4 | 3.00 (3) | 1/1/1 of 1 | 0.00 (0) | 5913 (6144) | 99% | 56 (59) |
| lfm2.5 | 4 | 0/4 | - | - | - | 3722 | 0% | 25 |
| ornith-1.5:9b | 4 | 0/4 | - | - | - | 6144 | 100% | 64 |
| qwen3-coder:30b | 4 | 4/4 | 2.75 (2) | 4/3/4 of 4 | 0.75 (1) | 200 (237) | 0% | 2 (2) |
| laguna-xs-2.1 | 4 | 4/4 | 3.00 (3) | 4/4/4 of 4 | 0.00 (0) | 2116 (3261) | 92% | 19 (29) |
| north-mini-code-1.0 | 4 | 2/4 | 3.00 (3) | 2/2/2 of 2 | 0.00 (0) | 5044 (6144) | 98% | 80 (103) |
| qwen3.8:27b | 3 | 3/3 | 3.00 (3) | 3/3/3 of 3 | 0.00 (0) | 1672 (1833) | 82% | 22 (23) |

## QA AC verification (8 items: 4 pass, 4 subtle fail; n runs each)

| model | n | accuracy | accuracy greedy (t0) | worst item acc | unsure rate | items unanimous across runs | unanimous-and-wrong items | wrong verdict on a TRUE-FAIL item (missed violation) | eval tok mean | wall s mean (max) |
|---|---|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 32 | 84% | 7/8 | 0% | 6% | 6/8 | - | 0/16 | 2244 | 17.7 (55.7) |
| lfm2.5 | 32 | 0% | 0/8 | 0% | 0% | 8/8 | q1_cart_empty, q2_pw_len, q3_timeout, q4_reqid_log, q5_sort_ok, q6_sort_bad, q7_exit_codes, q8_quiet | 0/16 | 490 | 3.4 (6.0) |
| ornith-1.5:9b | 32 | 100% | 8/8 | 100% | 0% | 8/8 | - | 0/16 | 828 | 8.6 (25.0) |
| qwen3-coder:30b | 32 | 88% | 7/8 | 0% | 0% | 8/8 | q6_sort_bad | 4/16 | 67 | 0.7 (1.0) |
| laguna-xs-2.1 | 32 | 100% | 8/8 | 100% | 0% | 8/8 | - | 0/16 | 579 | 5.0 (14.1) |
| north-mini-code-1.0 | 32 | 100% | 8/8 | 100% | 0% | 8/8 | - | 0/16 | 625 | 6.4 (20.3) |
| qwen3.8:27b | 24 | 100% | 8/8 | 100% | 0% | 8/8 | - | 0/12 | 461 | 5.7 (11.7) |

## Vision / screenshot QA (7 pages: 5 planted defects, 2 clean; n runs each)

| model | n | parsed | defect pages flagged fail | ...and named the right defect | clean pages false alarm | per-page right-defect (v2 overlap/v3 trunc/v4 text/v5 contrast/v7 table) | eval tok mean | prompt tok (image) | wall s mean (max) |
|---|---|---|---|---|---|---|---|---|---|
| ornith-1.5:9b | 28 | 28/28 | 20/20 | 20/20 | 4/8 | 4/4 4/4 4/4 4/4 4/4 | 393 | 1166 | 4.7 (9.0) |
| gemma4:e4b | 28 | 28/28 | 12/20 | 10/20 | 0/8 | 2/4 4/4 4/4 0/4 0/4 | 499 | 632 | 5.5 (7.2) |
| muse-glimmer:30b | 28 | 27/28 | 19/20 | 19/20 | 3/8 | 3/4 4/4 4/4 4/4 4/4 | 445 | 1460 | 14.5 (29.6) |
| qwen3.8:27b | 21 | 21/21 | 15/15 | 15/15 | 0/6 | 3/3 3/3 3/3 3/3 3/3 | 396 | 1166 | 7.0 (19.4) |

## Requests timed while another model was resident
