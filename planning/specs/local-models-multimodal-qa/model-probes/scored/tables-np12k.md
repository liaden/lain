## Budget retest at num_predict=12288 (the three models that answered nothing at 6144)

### code review (was 0/4 answered at 6144)

| model | n | parsed | found mean (worst) | recall | false alarms mean (worst) | eval tok mean (max) | wall s mean (max) | hit the 12288 cap |
|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 4 | 4/4 | 0.25 (0) of 4 | 6% | 1.50 (2) | 7732 (8645) | 87 (103) | 0/4 |
| ornith-1.5:9b | 4 | 1/4 | 2.00 (2) of 4 | 50% | 0.00 (0) | 11405 (12288) | 125 (140) | 3/4 |
| north-mini-code-1.0 | 4 | 0/4 | - | - | - | 9754 (12288) | 194 (294) | 3/4 |

### plan review (was 0/4 answered at 6144)

| model | n | parsed | found mean (worst) | recall | false alarms mean (worst) | eval tok mean (max) | wall s mean (max) | hit the 12288 cap |
|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 4 | 4/4 | 2.25 (2) of 3 | 75% | 0.00 (0) | 7692 (9394) | 79 (102) | 0/4 |
| ornith-1.5:9b | 4 | 1/4 | 3.00 (3) of 3 | 100% | 0.00 (0) | 11020 (12288) | 124 (142) | 3/4 |
| north-mini-code-1.0 | 4 | 1/4 | 3.00 (3) of 3 | 100% | 0.00 (0) | 10393 (12288) | 186 (230) | 3/4 |
