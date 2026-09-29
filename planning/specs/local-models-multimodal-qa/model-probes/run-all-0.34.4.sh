#!/bin/bash
# Full re-measure on ollama 0.34.4 (2026-09-26). The 0.32.12 rows are archived in raw-0.32.12/, so these
# write the DEFAULT raw/*.jsonl names and analyze.py needs no changes.
# One model resident at a time: on 24 GiB a second 30B model would evict the one under test.
# Keep the GPU otherwise idle -- a game running alongside cut prefill ~60% and nearly caused a wrong
# conclusion about this very upgrade (see ../UPGRADE-ollama-0.34.4.md).
set -u
cd "$(dirname "$0")" || exit
unload() { curl -s localhost:11434/api/generate -d "{\"model\":\"$1\",\"keep_alive\":0}" >/dev/null; }
TEXT=speed,tools,review,plan,qa,ctx32k

python3 run.py qwen3:4b            probes=$TEXT              > logs/v0344_qwen3_4b.log   2>&1
python3 wire.py qwen3:4b a,b                                 > logs/v0344_wire_qwen3.log 2>&1
unload qwen3:4b
python3 run.py lfm2.5              probes=$TEXT              > logs/v0344_lfm2.5.log     2>&1
unload lfm2.5
python3 run.py ornith-1.5:9b       probes=$TEXT,vision       > logs/v0344_ornith.log     2>&1
python3 wire.py ornith-1.5:9b c                              > logs/v0344_wire_ornith.log 2>&1
unload ornith-1.5:9b
python3 run.py gemma4:e4b          probes=speed,vision,ctx32k > logs/v0344_gemma4.log    2>&1
python3 wire.py gemma4:e4b c                                 > logs/v0344_wire_gemma4.log 2>&1
unload gemma4:e4b
python3 run.py qwen3-coder:30b     probes=$TEXT thinks=0     > logs/v0344_qwen3-coder.log 2>&1
unload qwen3-coder:30b
python3 run.py laguna-xs-2.1       probes=$TEXT              > logs/v0344_laguna.log     2>&1
unload laguna-xs-2.1
python3 run.py north-mini-code-1.0 probes=$TEXT              > logs/v0344_north.log      2>&1
unload north-mini-code-1.0
python3 run.py muse-glimmer:30b    probes=speed,vision,ctx32k > logs/v0344_muse.log      2>&1
unload muse-glimmer:30b
python3 run.py qwen3.8:27b         probes=$TEXT,vision runs=3 np=12288 > logs/v0344_qwen3.8.log 2>&1
unload qwen3.8:27b
python3 analyze.py > scored/tables.md
