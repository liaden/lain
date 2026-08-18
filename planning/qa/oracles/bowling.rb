# The DRIVER's grading instrument for the bowling subject. Never the model's own specs --
# grading a model's work with the model's own tests is the vacuity Act 7 exists to prune.
# Run: ruby oracles_spec.rb <path-to-bowling.rb>
require_relative ARGV.fetch(0)

ORACLES = [
  ["all gutters",                        Array.new(20, 0),                                        0],
  ["perfect game",                       Array.new(12, 10),                                     300],
  ["all spares, 5 first ball",           Array.new(21, 5),                                      150],
  ["mixed with open frames",             [1,4, 4,5, 6,4, 5,5, 10, 0,1, 7,3, 6,4, 10, 2,8,6],    133],
  ["nine opens then 10,10,10 in tenth",  Array.new(18, 0) + [10, 10, 10],                        30]
].freeze

failures = ORACLES.reject do |name, rolls, want|
  got = begin
    Bowling.score(rolls)
  rescue StandardError => e
    "raised #{e.class}: #{e.message}"
  end
  ok = got == want
  puts format("%-36s want %3s  got %-28s %s", name, want, got.inspect, ok ? "PASS" : "FAIL")
  ok
end

# The fourth oracle is the one that catches a scorer adding the bonus to EVERY frame;
# the fifth pins the tenth-frame rule. The first three alone are NOT sufficient.
puts "\n#{ORACLES.size - failures.size}/#{ORACLES.size} oracles pass"
exit(failures.empty? ? 0 : 1)
