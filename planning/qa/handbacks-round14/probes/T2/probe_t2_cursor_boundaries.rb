# T2 re-review probe: the cursor path. `Rendering#at` resolves a keypress to
# the pending that gets decided; `call_index` is a SECOND 1-based index beside
# it. This walks every boundary of both and, for every answerable line, checks
# that the two agree -- `calls[call_index[line] - 1]` must be the call of the
# very pending `at(line)` hands to `decide`.
require "lain"
Fake = Struct.new(:requester, :tool, :input, :outstanding)
Out = Struct.new(:preamble)
view = Lain::Frontend::Neovim::ApprovalView.new

def check(view, label, parked)
  r = view.send(:rendering_of, parked)
  rows = r.rows
  lines = r.lines.size

  # The two indexes must agree on EVERY answerable line, which is the only
  # property that keeps a `y` from releasing a different command than the one
  # the reader read out of the buffer variable.
  disagree = (1..rows).reject do |line|
    owner = r.at(line)
    slot = r.call_index[line - 1]
    !owner.nil? && slot.is_a?(Integer) && slot >= 1 && r.calls[slot - 1] == "#{owner.tool}(#{owner.input.inspect})"
  end

  boundaries = {
    "line 0" => [r.at(0), r.call_index[0 - 1]],
    "line 1" => [r.at(1), r.call_index[0]],
    "last row (#{rows})" => [r.at(rows), rows.positive? ? r.call_index[rows - 1] : nil],
    "first trailer (#{rows + 1})" => [r.at(rows + 1), r.call_index[rows]],
    "past end (#{lines + 5})" => [r.at(lines + 5), r.call_index[lines + 4]],
    "negative (-1)" => [r.at(-1), r.call_index[-1 - 1]],
    "non-numeric 'y'" => [r.at("y"), nil],
    "nil line" => [r.at(nil), nil],
    "float '2.9'" => [r.at("2.9"), nil],
    "whitespace ' 2 '" => [r.at(" 2 "), nil]
  }
  shown = boundaries.map do |name, (owner, slot)|
    "#{name}=#{owner.nil? ? 'nil' : owner.tool_id}/#{slot.inspect}"
  end
  puts format("%-30s rows=%-4d lines=%-4d calls=%-3d index=%-4d agree=%-5s  %s",
              label, rows, lines, r.calls.size, r.call_index.size, disagree.empty?, shown.join("  "))
  raise "MISMATCH on #{label} lines #{disagree.inspect}" unless disagree.empty?
end

class Fake
  def tool_id = input["command"]
end

check(view, "empty", [])
check(view, "one short", [Fake.new("a", "bash", { "command" => "A" }, Out.new(""))])
check(view, "one wrapped", [Fake.new("a", "bash", { "command" => "B" * 300 }, Out.new(""))])
check(view, "short,wrapped,short",
      [Fake.new("a", "bash", { "command" => "A" }, Out.new("")),
       Fake.new("a", "bash", { "command" => "B" * 300 }, Out.new("")),
       Fake.new("a", "bash", { "command" => "C" }, Out.new(""))])
check(view, "wrapped,short,wrapped",
      [Fake.new("a", "bash", { "command" => "A" * 400 }, Out.new("")),
       Fake.new("a", "bash", { "command" => "B" }, Out.new("")),
       Fake.new("a", "bash", { "command" => "C" * 500 }, Out.new(""))])
check(view, "two identical commands",
      [Fake.new("one", "bash", { "command" => "D" * 200 }, Out.new("")),
       Fake.new("two", "bash", { "command" => "D" * 200 }, Out.new(""))])
check(view, "five wrapped",
      (1..5).map { |i| Fake.new("a", "bash", { "command" => i.to_s * (90 * i) }, Out.new("")) })

puts "all agree"
