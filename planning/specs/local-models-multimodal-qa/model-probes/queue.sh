#!/bin/bash
# strictly serial, grouped by model
cd "$(dirname "$0")" || exit
while pgrep -f "run.py qwen3:4b" >/dev/null; do sleep 5; done
python3 wire.py qwen3:4b a,b > logs/wire_qwen3_4b.log 2>&1
python3 run.py lfm2.5 probes=speed,tools,review,plan,qa,ctx32k > logs/lfm2.5.log 2>&1
python3 run.py ornith-1.5:9b probes=speed,tools,review,plan,qa,vision,ctx32k > logs/ornith.log 2>&1
python3 wire.py ornith-1.5:9b c > logs/wire_ornith.log 2>&1
python3 run.py gemma4:e4b probes=speed,vision,ctx32k > logs/gemma4.log 2>&1
python3 wire.py gemma4:e4b c > logs/wire_gemma4.log 2>&1
python3 run.py qwen3-coder:30b probes=speed,tools,review,plan,qa,ctx32k thinks=0 > logs/qwen3-coder.log 2>&1
python3 run.py laguna-xs-2.1 probes=speed,tools,review,plan,qa,ctx32k > logs/laguna.log 2>&1
python3 run.py north-mini-code-1.0 probes=speed,tools,review,plan,qa,ctx32k > logs/north.log 2>&1
python3 run.py muse-glimmer:30b probes=speed,vision,ctx32k > logs/muse.log 2>&1
echo QUEUE_DONE > logs/queue.done
