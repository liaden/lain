require "lain"
Sp = Lain::Middleware::RedactSecretReads::Rows::Span
a = Sp.new(start: 5, length: 3); b = Sp.new(start: 2, length: 10)
p [:a_or_b, a | b, :b_or_a, b | a]
text = "0123456789SECRET-tail"
p Lain::Sensitivity::Masking.render(text, [Sp.new(start: 10, length: 6), Sp.new(start: 2, length: 3)])
row = Lain::Middleware::RedactSecretReads::Rows::Row.new(prefix: "", text: "x" * 40, path: nil, regions: [])
cov = ->(spans) { spans.flat_map { (_1.start...(_1.start + _1.length)).to_a }.to_set }
srand(3); bad = 0
2000.times do
  xs = Array.new(rand(0..6)) { Sp.new(start: rand(0..30), length: rand(1..8)) }
  c = row.send(:coalesced, xs)
  ok = cov.(c) == cov.(xs) && row.send(:coalesced, c) == c && row.send(:coalesced, xs.shuffle) == c &&
       c.each_cons(2).all? { |l, r| l.start + l.length < r.start }
  bad += 1 unless ok
end
p [:coalesce_law_failures, bad]
