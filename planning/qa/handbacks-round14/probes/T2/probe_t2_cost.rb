# T2 review probe: what the per-ROW duplication costs in TIME and on the WIRE,
# and what the one-object-per-call variant would save.
require "lain"
require "msgpack"
def realtime = (t = Process.clock_gettime(Process::CLOCK_MONOTONIC); yield; Process.clock_gettime(Process::CLOCK_MONOTONIC) - t)
Fake = Struct.new(:requester, :tool, :input, :outstanding)
Out = Struct.new(:preamble)
view = Lain::Frontend::Neovim::ApprovalView.new

[4, 32, 64].each do |kb|
  parked = [Fake.new("agent", "bash", { "command" => "cat <<'EOF' > f\n" + ("y" * (kb * 1024)) + "\nEOF" }, Out.new(""))]
  items = parked.map { |p| view.send(:lines_for, p) }
  owners = items.zip(parked).flat_map { |lines, p| Array.new(lines.size, p) }

  as_shipped = nil
  t_shipped = realtime { as_shipped = owners.map { |p| view.send(:call_of, p) } }
  shared = nil
  t_shared = realtime do
    shared = items.zip(parked).flat_map { |lines, p| Array.new(lines.size, view.send(:call_of, p)) }
  end
  lines = items.flatten(1)
  puts format("%3dKB input: rows=%-5d  lines-wire=%-8d calls-wire=%-10d ratio=%6.1fx  " \
              "call_of x%-5d %6.1fms -> shared %5.1fms  heap %8.2fMB -> %6.2fMB",
              kb, owners.size, MessagePack.pack(lines).bytesize, MessagePack.pack(as_shipped).bytesize,
              MessagePack.pack(as_shipped).bytesize.to_f / MessagePack.pack(lines).bytesize,
              owners.size, t_shipped * 1000, t_shared * 1000,
              as_shipped.sum(&:bytesize) / 1024.0 / 1024,
              shared.uniq(&:object_id).sum(&:bytesize) / 1024.0 / 1024)
end
