#!/bin/bash
# Remaining models after the 2026-09-22 out-of-memory kill. qwen3:4b and lfm2.5 are done and are NOT
# repeated -- run.py appends, so a second pass would double-count them. ornith's partial rows were
# dropped from raw/ (backup in raw.bak-partial/), so it starts clean here.
set -u
cd "$(dirname "$0")" || exit
unload() { curl -s localhost:11434/api/generate -d "{\"model\":\"$1\",\"keep_alive\":0}" >/dev/null; }

python3 run.py ornith-1.5:9b probes=speed,tools,review,plan,qa,vision,ctx32k > logs/ornith.log 2>&1
python3 wire.py ornith-1.5:9b c > logs/wire_ornith.log 2>&1
unload ornith-1.5:9b
python3 run.py gemma4:e4b probes=speed,vision,ctx32k > logs/gemma4.log 2>&1
python3 wire.py gemma4:e4b c > logs/wire_gemma4.log 2>&1
unload gemma4:e4b
python3 run.py qwen3-coder:30b probes=speed,tools,review,plan,qa,ctx32k thinks=0 > logs/qwen3-coder.log 2>&1
unload qwen3-coder:30b
python3 run.py laguna-xs-2.1 probes=speed,tools,review,plan,qa,ctx32k > logs/laguna.log 2>&1
unload laguna-xs-2.1
python3 run.py north-mini-code-1.0 probes=speed,tools,review,plan,qa,ctx32k > logs/north.log 2>&1
unload north-mini-code-1.0
python3 run.py muse-glimmer:30b probes=speed,vision,ctx32k > logs/muse.log 2>&1
unload muse-glimmer:30b
# qwen3.8 thinks at very high effort by default: n cut to 3 (2 seeded + greedy) and a 12k token cap so
# budget exhaustion can be told apart from a wrong answer.
python3 run.py qwen3.8:27b probes=speed,tools,review,plan,qa,vision,ctx32k runs=3 np=12288 > logs/qwen3.8.log 2>&1
unload qwen3.8:27b
python3 analyze.py > scored/tables.md
