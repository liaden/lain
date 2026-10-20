require "lain"
RB = Lain::Tool::RoundBudget
T = Struct.new(:name, :rerunnable) { def rerunnable? = rerunnable }
tools = [T.new("read_file", true), T.new("grep", true), T.new("subagent", false)]
contents = ["a" * 40, "b" * 300, "c" * 900, "ok", "d" * 40, "a" * 40, "b" * 300]
def run(limit, blocks, calls)
  rec = nil
  out = RB::Round.new("static", RB::Limit.new(bytes: limit, scope: "s"), nil).call(blocks, calls) { rec = _1 }
  [out, rec]
end
srand(7)
mono_fail = prefix_fail = 0; witness = nil
3000.times do
  n = rand(1..7)
  ids = Array.new(n) { |i| (rand < 0.5 ? "toolu_#{i}" : "t#{i}" * rand(1..12)) }
  blocks = Array.new(n) { |i| { "type" => "tool_result", "tool_use_id" => ids[i], "content" => contents.sample, **(rand < 0.1 ? { "is_error" => true } : {}) } }
  calls = ids.map { RB::Call.new(id: _1, tool: tools.sample) }
  b1 = rand(0..1500); b2 = b1 + rand(0..1500)
  w = ->(b) { (run(b, blocks, calls)[1]&.withheld || []) }
  unless (w.(b2) - w.(b1)).empty?
    mono_fail += 1; witness ||= [b1, b2, blocks.map { [_1["tool_use_id"], _1["content"].size] }, calls.map { _1.tool.name }]
  end
  k = rand(0..n)
  prefix_fail += 1 unless run(b1, blocks, calls)[0].take(k) == run(b1, blocks.take(k), calls.take(k))[0]
end
puts "monotone(withheld antitone in budget) failures: #{mono_fail}"; p witness
puts "prefix failures: #{prefix_fail}"
# total output bytes vs input: can withholding grow a round?
blocks = [{ "tool_use_id" => "a", "content" => "x" * 100 }, { "tool_use_id" => "b", "content" => "ok" }]
calls = [RB::Call.new(id: "a", tool: tools[0]), RB::Call.new(id: "b", tool: tools[0])]
out, = run(10, blocks, calls)
p out.map { _1["content"].bytesize }
