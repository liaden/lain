require_relative "setup"
R = Lain::Request
def ident(r) = r.to_h.except(:stream, :extra)
def stats(xs)
  s = xs.sort; mean = xs.sum / xs.size
  sd = Math.sqrt(xs.sum { |x| (x - mean)**2 } / xs.size)
  format("min %.3f med %.3f max %.3f sd %.3f", s[0], s[s.size / 2], s[-1], sd)
end
SCHEMES = %i[whole merkle_ruby merkle_rust rolling_ruby rolling_rust]
if ENV["DUMP"]
  r = chat_once; puts %i[merkle_ruby merkle_rust rolling_ruby rolling_rust].map { |s| R.digest_of(ident(r), scheme: s) }
  exit
end
chain = R::PrefixChain.new
req = chat_once
SCHEMES.each { |s| R.digest_of(ident(req), scheme: s) } # warm memos
req.prefix_digests(chain: chain)
puts "load #{File.read('/proc/loadavg').split.first(3).join(' ')}"
puts "cold (memo empty), 5 runs"
SCHEMES.each do |s|
  xs = Array.new(5) { R.memos.clear; i = ident(req); t = CLOCK.(); R.digest_of(i, scheme: s); (CLOCK.() - t) * 1000 }
  puts format("  %-12s %s", s, stats(xs))
end
SCHEMES.each { |s| R.digest_of(ident(req), scheme: s) }
T = Hash.new { |h, k| h[k] = [] }
G = Hash.new { |h, k| h[k] = [] }
A = Hash.new { |h, k| h[k] = [] }
PD = []
30.times do |n|
  r = chat_once
  i = ident(r)
  order = SCHEMES.rotate(n % SCHEMES.size)
  order.each do |s|
    GC.start if ENV["GCSTART"]
    g0 = GC.count; a0 = GC.stat(:total_allocated_objects); t = CLOCK.()
    R.digest_of(i, scheme: s)
    T[s] << (CLOCK.() - t) * 1000; G[s] << GC.count - g0; A[s] << GC.stat(:total_allocated_objects) - a0
  end
  g0 = GC.count; t = CLOCK.(); r.prefix_digests(chain: chain); PD << (CLOCK.() - t) * 1000
end
puts "load #{File.read('/proc/loadavg').split.first(3).join(' ')}"
SCHEMES.each do |s|
  puts format("%-12s digest ms: %s | GC/turn %.2f (max %d) | alloc/turn med %d", s, stats(T[s]), G[s].sum / 30.0, G[s].max, A[s].sort[15])
  both = T[s].zip(PD).map { |a, b| a + b }
  puts format("%-12s digest+prefix_digests ms: %s", "", stats(both))
end
puts "prefix_digests alone ms: #{stats(PD)}"
GC.start
puts "heap_live_slots #{GC.stat(:heap_live_slots)} rss_kb #{File.read('/proc/self/status')[/VmRSS:\s+(\d+)/, 1]} memo sizes #{R.memos.transform_values(&:size)}"
