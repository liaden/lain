#!/bin/bash
# The remainder of the 0.34.4 re-measure: muse-glimmer + qwen3.8 speed (the first attempt ran under memory
# pressure and is invalid), and qwen3.8's QA + vision (an out-of-memory kill stopped it 5 rows in). The
# partial rows were dropped from raw/ first -- run.py appends. Keep the GPU idle.
set -u
cd "$(dirname "$0")" || exit
unload() { curl -s localhost:11434/api/generate -d "{\"model\":\"$1\",\"keep_alive\":0}" >/dev/null; }
python3 run.py muse-glimmer:30b probes=speed > logs/v0344_muse_speed2.log 2>&1
unload muse-glimmer:30b
python3 run.py qwen3.8:27b probes=speed,qa,vision runs=3 np=12288 > logs/v0344_qwen3.8_rest.log 2>&1
unload qwen3.8:27b
python3 analyze.py > scored/tables.md
