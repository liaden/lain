# Cost of a cold rolled digest vs today's whole-payload digest, for a JSON-rebuilt request (no identity hits).
require "lain"
require "json"
msgs = Array.new(2000) { |i| { "role" => i.even? ? "user" : "assistant", "content" => [{ "type" => "text", "text" => "turn #{i} " + ("lorem ipsum " * 150) }] } }
json = JSON.dump(msgs)
t = ->(&b) { s = Process.clock_gettime(Process::CLOCK_MONOTONIC); 5.times(&b); (Process.clock_gettime(Process::CLOCK_MONOTONIC) - s) / 5 * 1000 }
whole = t.call { Lain::Request.new(model: "m", max_tokens: 64, messages: JSON.parse(json)) }
rolled = t.call do
  r = Lain::Request.new(model: "m", max_tokens: 64, messages: JSON.parse(json))
  r.messages.inject("seed") { |s, m| Lain::Canonical.digest([s, Lain::Request.strip_cache_markers(m)]) }
end
printf("2000 msgs: today's Request.new %.1f ms; plus a cold roll %.1f ms\n", whole, rolled)
