#!/bin/bash
# The three models whose review/plan answers were TRUNCATED at np=6144 (100% think share, no answer
# parsed) get a fair second look at 12288 -- the same cap qwen3.8 ran with. Tagged, so the rows land in
# their own raw/*_np12k.jsonl and cannot be mixed into the 6144 tables.
set -u
cd "$(dirname "$0")" || exit
unload() { curl -s localhost:11434/api/generate -d "{\"model\":\"$1\",\"keep_alive\":0}" >/dev/null; }
for m in qwen3:4b ornith-1.5:9b north-mini-code-1.0; do
  python3 run.py "$m" probes=review,plan np=12288 tag=_np12k > "logs/retest_${m//[:.]/_}.log" 2>&1
  unload "$m"
done
