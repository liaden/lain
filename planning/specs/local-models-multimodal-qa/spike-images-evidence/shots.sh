#!/bin/bash
# Spike measurement: PNG sizes of real pages at 1280x800 via headless chromium.
dir=/home/tara/tmp/lain/claude-1000/-home-tara-dev-lain/c401093e-a43b-407b-8356-177c97f0daa3/scratchpad
cd "$dir" || exit 1
for u in https://example.com https://news.ycombinator.com https://www.ruby-lang.org/en/ "https://en.wikipedia.org/wiki/Ruby_(programming_language)" https://github.com/ruby/ruby; do
  n=$(echo "$u" | tr -c '[:lower:]' _ | cut -c1-40)
  start=$(date +%s.%N)
  timeout 30 /usr/bin/chromium --headless --disable-gpu --hide-scrollbars --screenshot="$dir/$n.png" --window-size=1280,800 "$u" >/dev/null 2>&1
  end=$(date +%s.%N)
  echo "$u png=$(stat -c %s "$n.png" 2>/dev/null) b64=$(base64 -w0 "$n.png" | wc -c) secs=$(echo "$end - $start" | bc)"
done
