# frozen_string_literal: true

# Spike: what an inline image costs the per-request CPU path (normalize+digest).
require "lain"


png = File.binread(File.join(__dir__, "https___en_wikipedia_org_wiki__uby__prog.png"))
block = Lain::Image.block(png)
content = [{ "type" => "tool_result", "tool_use_id" => "t", "is_error" => false, "content" => [block] }]
n = 50
def realtime(count)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  count.times { yield }
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end
normalize = realtime(n) { Lain::Canonical.normalize(content) } / n
digest = realtime(n) { Lain::Canonical.digest(content) } / n
dump = realtime(n) { JSON.generate(content) } / n
puts format("per call on a 292KB base64 block: normalize=%.2fms digest=%.2fms json=%.2fms",
            normalize * 1000, digest * 1000, dump * 1000)
