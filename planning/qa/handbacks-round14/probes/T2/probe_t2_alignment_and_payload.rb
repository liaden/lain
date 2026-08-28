# T2 review probe: (a) does `calls` line up with the ANSWERABLE rows only,
# never with the trailer; (b) what does the per-ROW (rather than per-CALL)
# duplication cost on the wire?
require "lain"
Fake = Struct.new(:requester, :tool, :input, :outstanding)
Out = Struct.new(:preamble)
view = Lain::Frontend::Neovim::ApprovalView.new

def report(view, label, parked)
  r = view.send(:rendering_of, parked)
  trailer = r.lines.size - r.rows
  ok_len = r.calls.size == r.rows
  # every row's call must be the call of the pending that OWNS that row
  ok_map = (1..r.rows).all? { |line| r.calls[line - 1] == "#{r.at(line).tool}(#{r.at(line).input.inspect})" }
  bytes_lines = r.lines.sum(&:bytesize)
  bytes_calls = r.calls.sum(&:bytesize)
  uniq = r.calls.uniq.size
  same_obj = r.calls.map(&:object_id).uniq.size
  puts format("%-34s lines=%-5d rows=%-5d trailer=%-3d calls=%-5d aligned=%-5s owner-match=%-5s " \
              "line-bytes=%-9d call-bytes=%-9d distinct-strings=%-4d distinct-objects=%d",
              label, r.lines.size, r.rows, trailer, r.calls.size, ok_len, ok_map,
              bytes_lines, bytes_calls, uniq, same_obj)
end

report(view, "empty queue", [])
report(view, "one short call", [Fake.new("a", "bash", { "command" => "pwd" }, Out.new(""))])
report(view, "one wrapped call (200b)", [Fake.new("a", "bash", { "command" => "x" * 200 }, Out.new(""))])
report(view, "short + wrapped + short",
       [Fake.new("a", "b", { "c" => "d" }, Out.new("")),
        Fake.new("e", "f", { "g" => "h" * 300 }, Out.new("")),
        Fake.new("i", "j", { "k" => "l" }, Out.new(""))])
[1, 4, 16, 64, 256].each do |kb|
  report(view, "one write_file, #{kb}KB content",
         [Fake.new("agent", "write_file", { "path" => "/tmp/f", "content" => "y" * (kb * 1024) }, Out.new(""))])
end
