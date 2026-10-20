require "lain"
m = Lain::Sensitivity::TextMask.new(secrets: ["hunter2-very-long-secret-value"])
samples = ["API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCD\n",
  "export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789\n",
  "password: hunter2-very-long-secret-value and again hunter2-very-long-secret-value\n",
  "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\nDB_PASSWORD=correcthorsebatterystaple9\n",
  "API_KEY=<redacted:1>\n", "token = \"<redacted:3>\"\n", "SECRET=<redacted:1>\nPASSWORD=<redacted:2>\n"]
samples.each do |t|
  once, c1 = m.call(t)
  twice, c2 = m.call(once)
  puts [t.inspect, once.inspect, c1, (twice == once), c2].inspect
end
# chunk invariance
t = samples[0] + samples[1] + samples[3]
whole, = m.call(t)
bad = 0
200.times do
  cuts = Array.new(rand(1..6)) { rand(0..t.size) }.sort.uniq
  pieces = ([0] + cuts + [t.size]).each_cons(2).map { |a, b| t[a...b] }
  s = m.stream
  out = pieces.map { s << _1 }.join + s.finish
  bad += 1 unless out == whole
end
puts "chunk mismatches: #{bad}/200"
# long line > PARTIAL_CAP with secret straddling
long = ("x " * 2100) + "hunter2-very-long-secret-value tail\n"
w, = m.call(long)
s = m.stream
o = long.chars.each_slice(997).map { s << _1.join }.join + s.finish
puts "long line equal: #{o == w}; leaked: #{o.include?('hunter2')}"
