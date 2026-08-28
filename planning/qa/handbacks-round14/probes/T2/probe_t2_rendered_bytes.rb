# T2 review probe: does ANY rendered byte differ between HEAD's ApprovalView and
# the card's? Renders the same corpus twice in two processes -- the second one
# re-opens the class from HEAD's source -- and compares SHA256 of the lines.
require "lain"
require "digest"
require "json"

Fake = Struct.new(:requester, :tool, :input, :outstanding)
Out = Struct.new(:preamble)

CORPUS = [
  [["a", "bash", { "command" => "pwd" }, ""]],
  [["a", "bash", { "command" => "x" * 200 }, ""]],
  [["fleet-worker-with-a-very-long-name", "write_file",
    { "path" => "/tmp/" + ("deep/" * 30) + "f.rb", "content" => "y" * 300 },
    "4 sensitive regions outstanding; a yes releases them. "]],
  [["a", "bash", { "command" => "echo \"quoted\" and 'single'" }, ""]],
  [["a", "bash", { "command" => "café — ünïcode ✓ " * 20 }, ""]],
  [["a", "bash", { "command" => "line1\nline2\ttab" }, ""]],
  [["a", "bash", { "command" => "z" * 93 }, ""]],
  [["a", "bash", { "command" => "z" * 94 }, ""]],
  [["a", "bash", { "command" => "z" * 95 }, ""]],
  [["a", "b", { "c" => "d" }, ""], ["e", "f", { "g" => "h" * 300 }, ""], ["i", "j", { "k" => "l" }, ""]],
  []
].freeze

if ARGV[0] == "head"
  # Re-open the class over HEAD's bytes. Data.define reassignment warns; silence it.
  old = $VERBOSE
  $VERBOSE = nil
  load File.expand_path("probe_t2_approval_view_AT_HEAD.rb", __dir__)
  $VERBOSE = old
end

view = Lain::Frontend::Neovim::ApprovalView.new
out = CORPUS.map do |group|
  parked = group.map { |r, t, i, p| Fake.new(r, t, i, Out.new(p)) }
  rendering = view.send(:rendering_of, parked)
  { "lines" => rendering.lines, "rows" => rendering.rows,
    "digest" => Digest::SHA256.hexdigest(rendering.lines.inspect) }
end
puts JSON.generate(out)
