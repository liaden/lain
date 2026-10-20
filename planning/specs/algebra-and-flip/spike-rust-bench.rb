require "lain"
def rt = (a = Process.clock_gettime(Process::CLOCK_MONOTONIC); yield; Process.clock_gettime(Process::CLOCK_MONOTONIC) - a)
require "benchmark/ips"
impl = ENV.fetch("IMPL"); n = Integer(ENV.fetch("N")); mode = ENV.fetch("MODE", "mem")
secs = Integer(ENV.fetch("SECS", "3"))
TL, ST = impl == "ruby" ? [Lain::Timeline, Lain::Store] : [Lain::Ext::Timeline, Lain::Ext::Store]
BODY = ("lorem ipsum dolor sit amet " * 14).freeze # ~380 bytes
def text(i) = [{ "type" => "text", "text" => "#{i} #{BODY}" }]
def rss = File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i
def build(n, tl)
  n.times { |i| tl = tl.commit(role: i.even? ? :user : :assistant, content: text(i)) }
  tl
end
def walk(tl) = tl.ancestors.each { |t| t.content.each { |c| c["text"].bytesize } }
def ips(label, secs, &b)
  Benchmark.ips(quiet: true) { |x| x.config(time: secs, warmup: 1); x.report(label, &b) }
    .entries.first.then { |e| puts format("%-28s %-5s %12.1f i/s ±%4.1f%%  (%.4f ms/op)", label, ENV["IMPL"], e.ips, e.ips_sd * 100.0 / e.ips, 1000.0 / e.ips) }
end
if mode == "mem"
  GC.start; r0 = rss; o0 = ObjectSpace.count_objects; g0 = GC.stat
  t = rt { $tl = build(n, TL.empty(store: ST.new)) }
  g1 = GC.stat; GC.start; r1 = rss; o1 = ObjectSpace.count_objects
  puts "#{impl} N=#{n} build=#{(t * 1000).round(1)}ms (#{(t / n * 1e6).round(1)} us/append) RSS_delta=#{r1 - r0}KB " \
       "objs_delta=#{o1[:TOTAL] - o0[:TOTAL]} live(T_OBJECT+STRING+ARRAY+HASH+DATA)=#{%i[T_OBJECT T_STRING T_ARRAY T_HASH T_DATA].sum { |k| o1[k] - o0[k] }} " \
       "gc_count=#{g1[:count] - g0[:count]} alloc_objs=#{g1[:total_allocated_objects] - g0[:total_allocated_objects]}"
else
  base = build(n, TL.empty(store: ST.new)); mid = base.rewind(n / 2)
  puts "#{impl} N=#{n} loadavg=#{File.read('/proc/loadavg').split.first(3).join(' ')}"
  i = 0
  ips("append (onto N chain)", secs) { i += 1; base.commit(role: :user, content: text(i)) }
  ips("fork", secs) { mid.fork }
  l = r = mid.fork
  100.times { |k| l = l.commit(role: :user, content: text("l#{k}")); r = r.commit(role: :user, content: text("r#{k}")) }
  ips("ancestors.each full chain", secs) { base.ancestors.each { |t| t } }
  ips("ancestors.to_a", secs) { base.ancestors.to_a }
  ips("ancestors block form", secs) { base.ancestors { |t| t } } if impl == "ext"
  ips("meet (branches)", secs) { impl == "ruby" ? Lain::Dag::RenderAncestry.meet(l, r) : l.meet(r) }
  ips("diverge_at (branches)", secs) { impl == "ruby" ? Lain::Dag::RenderAncestry.diverge_at(l, r) : l.diverge_at(r) }
  ips("replay-render walk+content", secs) { walk(base) }
end
