#!/bin/bash
# How does headless chromium report navigation failures?
dir=/home/tara/tmp/lain/claude-1000/-home-tara-dev-lain/c401093e-a43b-407b-8356-177c97f0daa3/scratchpad
prof=$(mktemp -d "$HOME/tmp/lain/chromeprof.XXXX")
for u in http://nonexistent.invalid/ http://127.0.0.1:9/ https://httpbin.org/status/404; do
  rm -f "$dir/fail.png"
  timeout 30 /usr/bin/chromium --headless --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$prof" \
    --screenshot="$dir/fail.png" --window-size=640,400 "$u" >"$dir/fail.out" 2>&1
  echo "$u exit=$? png=$(stat -c %s "$dir/fail.png" 2>/dev/null) last=$(grep -v dbus "$dir/fail.out" | tail -1 | cut -c1-160)"
done
rm -rf "$prof"
