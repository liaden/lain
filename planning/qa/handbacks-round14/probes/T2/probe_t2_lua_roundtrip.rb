# T2 review probe, live nvim: how do b:lain_approval_calls and
# b:lain_approval_call_index behave when Ruby hands the lua entry point
# something other than the clean pair, does vim.b round-trip the bytes a real
# command can contain, and does `calls[call_index[N]]` resolve in real lua?
require "lain"
require "neovim"
require "tmpdir"
require "timeout"

SOCK = File.join(Dir.tmpdir, "lain-probe-t2-#{Process.pid}.sock")
PID = spawn("nvim", "--headless", "--clean", "-n", "--listen", SOCK, out: File::NULL, err: File::NULL)
Timeout.timeout(10) { sleep 0.02 until File.exist?(SOCK) }
NVIM = Neovim.attach_unix(SOCK)

# Inject the real runtime chunk exactly as the gem does, so this exercises the
# shipped 62_approval.lua and not a re-creation of it.
loader = Lain::Frontend::Neovim::RuntimeLoader.new
NVIM.exec_lua(loader.source, [0, Lain::Frontend::Neovim::PROTOCOL, Lain::VERSION.to_s])

SET = Lain::Frontend::Neovim::RenderQueue::SET_APPROVAL
BUF = "vim.b[vim.fn.bufnr('lain://approval')]"
READ = "return { #{BUF}.lain_approval_calls, #{BUF}.lain_approval_call_index }"
TYPES = "return { type(#{BUF}.lain_approval_calls), type(#{BUF}.lain_approval_call_index) }"
# What a config author is told to write in :help lain, run as real lua.
RESOLVE = "local n = ...; local c = #{BUF}.lain_approval_calls; " \
          "local i = #{BUF}.lain_approval_call_index; return c[i[n]]"

$gen = 0
def nxt = ($gen += 1)

def try(label, args)
  NVIM.exec_lua(SET, args)
  back = NVIM.exec_lua(READ, [])
  kinds = NVIM.exec_lua(TYPES, [])
  puts format("%-42s OK  types=%-22s read-back=%s", label, kinds.inspect, back.inspect[0, 90])
rescue StandardError => e
  puts format("%-42s RAISED %s: %s", label, e.class, e.message.to_s.lines.first.to_s.strip[0, 130])
end

def resolve(label, n)
  puts format("  resolve calls[call_index[%-3s]] -> %-58s (%s)", n, NVIM.exec_lua(RESOLVE, [n]).inspect[0, 56], label)
rescue StandardError => e
  puts format("  resolve calls[call_index[%-3s]] RAISED %s: %s", n, e.class, e.message.to_s.lines.first.to_s.strip[0, 90])
end

try("3 rows, 2 calls (the normal case)", [%w[a b c], nxt, 3, %w[first second], [1, 1, 2]])
resolve("row 1, first item", 1)
resolve("row 2, first item's continuation", 2)
resolve("row 3, second item", 3)
resolve("the trailer -- past rows", 4)
resolve("far past the end", 99)
resolve("row 0 -- the seam Ruby guards", 0)
resolve("a negative line", -1)

try("call_index EMPTY while rows = 3", [%w[a b c], nxt, 3, %w[one], []])
try("call_index pointing past calls", [%w[a b c], nxt, 3, %w[one], [1, 2, 9]])
resolve("index names a call that is not there", 3)
try("call_index absent (a 4-arg caller)", [%w[a b c], nxt, 3, %w[one]])
try("both absent (a 3-arg caller)", [%w[a b c], nxt, 3])
try("calls a bare String", [%w[a b c], nxt, 3, "not-a-list", [1, 1, 1]])
try("call_index holding a String", [%w[a b c], nxt, 3, %w[one], %w[1 1 1]])
try("64KB single call, 699 rows", [%w[a], nxt, 699, ["x" * 65_536], Array.new(699, 1)])

# Byte-for-byte fidelity on the shapes that could plausibly be mangled.
[
  "café — ✓ ünïcode",
  %(say "hi" 'now'),
  "a\nb",
  "a\\nb\tc",
  " embedded nul",
  "trailing space "
].each do |probe|
  NVIM.exec_lua(SET, [%w[a], nxt, 1, [probe], [1]])
  back = NVIM.exec_lua(RESOLVE, [1])
  puts format("fidelity %-34s %s", probe.inspect[0, 32], back == probe ? "EXACT through calls[call_index[1]]" : "LOST -> #{back.inspect[0, 60]}")
end

NVIM.exec_lua(SET, [%w[a], nxt, 1, ["kept"], [1]])
NVIM.exec_lua(SET, [[""], nxt, 0, [], []])
puts "after an empty re-render: #{NVIM.exec_lua(READ, []).inspect} types #{NVIM.exec_lua(TYPES, []).inspect}"

at_exit do
  Process.kill("TERM", PID)
  Process.wait(PID)
rescue StandardError
  nil
ensure
  File.unlink(SOCK) if File.exist?(SOCK)
end
