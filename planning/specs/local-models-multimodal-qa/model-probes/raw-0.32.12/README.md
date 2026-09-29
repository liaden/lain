Every probe row measured on ollama 0.32.12 (2026-09-22 and 2026-09-25/26), preserved when the box moved to
0.34.4. `../scored-0.32.12/` holds the tables built from these rows and `../REPORT-0.32.12.md` the write-up.
`*_np12k.jsonl` are the budget retest; `*_0344*.jsonl` / `*_03212b.jsonl` are the version A/B speed probes
(see ../UPGRADE-ollama-0.34.4.md), NOT part of the main tables.

CAVEAT on `wire.jsonl`: it holds BOTH builds' rows. The (a) and (b) checks were re-run on 0.34.4 during the
upgrade and appended here before the split, so the later `a_*`/`b_*` rows are 0.34.4's. The 0.34.4 excerpt
lives in `../model-probes/logs/wire_qwen3_4b_0.34.4.log`; the finding either way is in
`../UPGRADE-ollama-0.34.4.md` (format+tools still broken, eval_count now correct).
