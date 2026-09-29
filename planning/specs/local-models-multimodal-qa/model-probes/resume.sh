#!/bin/bash
# Remaining models, strictly serial and grouped by model. qwen3:4b (all text probes + wire a,b) is done.
# Appends to raw/*.jsonl; re-run `python3 analyze.py > scored/tables.md` afterwards.
set -u
cd "$(dirname "$0")" || exit
python3 run.py lfm2.5 probes=speed,tools,review,plan,qa,ctx32k > logs/lfm2.5.log 2>&1
python3 run.py ornith-1.5:9b probes=speed,tools,review,plan,qa,vision,ctx32k > logs/ornith.log 2>&1
python3 wire.py ornith-1.5:9b c > logs/wire_ornith.log 2>&1
python3 run.py gemma4:e4b probes=speed,vision,ctx32k > logs/gemma4.log 2>&1
python3 wire.py gemma4:e4b c > logs/wire_gemma4.log 2>&1
python3 run.py qwen3-coder:30b probes=speed,tools,review,plan,qa,ctx32k thinks=0 > logs/qwen3-coder.log 2>&1
python3 run.py laguna-xs-2.1 probes=speed,tools,review,plan,qa,ctx32k > logs/laguna.log 2>&1
python3 run.py north-mini-code-1.0 probes=speed,tools,review,plan,qa,ctx32k > logs/north.log 2>&1
python3 run.py muse-glimmer:30b probes=speed,vision,ctx32k > logs/muse.log 2>&1
# qwen3.8 thinks at very high effort by default: n cut to 3 (2 seeded + greedy) and a 12k token cap so
# the budget-exhaustion failure seen on qwen3:4b can be told apart from a wrong answer.
python3 run.py qwen3.8:27b probes=speed,tools,review,plan,qa,vision,ctx32k runs=3 np=12288 > logs/qwen3.8.log 2>&1
python3 analyze.py > scored/tables.md
for m in lfm2.5 ornith-1.5:9b gemma4:e4b qwen3-coder:30b laguna-xs-2.1 north-mini-code-1.0 muse-glimmer:30b qwen3.8:27b; do
  curl -s localhost:11434/api/generate -d "{\"model\":\"$m\",\"keep_alive\":0}" >/dev/null
done
