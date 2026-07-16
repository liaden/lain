# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# These drive a REAL headless nvim over msgpack-RPC -- the mode the RPC-direction
# probe verified can serve inbound rpcrequest (planning/rpc_direction_probe.rb):
# `nvim --headless --clean --listen <socket>`, attached via a unix socket. A
# SECOND, independent connection ({#inspector}) observes nvim's state from the
# outside, exactly like the probe's client2, so every assertion is about what the
# editor actually did, not about the frontend's own bookkeeping.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "--listen", socket, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    @socket = socket
    @nvim_pid = pid
    example.run
  ensure
    @inspector = nil
    if pid
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        # An example that kills nvim itself (the teardown specs) already reaped it.
      end
    end
    FileUtils.rm_f(socket)
  end

  let(:channel) { Lain::Channel.new }

  def inspector
    @inspector ||= Neovim.attach_unix(@socket)
  end

  def journal_lines
    inspector.exec_lua(<<~LUA, [])
      local buf = vim.fn.bufnr("lain://journal")
      if buf == -1 then return {} end
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    LUA
  end

  def messages
    inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
  end

  # Kill the editor out from under the frontend -- the teardown specs' whole
  # premise. Reaps the pid and clears it so the around hook's TERM is a no-op.
  def kill_nvim
    Process.kill("KILL", @nvim_pid)
    Process.wait(@nvim_pid)
    @nvim_pid = nil
  end

  # Poll until the block returns truthy, or fail. Editor effects arrive on the
  # RPC thread, not synchronously with the push that caused them.
  def wait_until(timeout: 8)
    deadline = Time.now + timeout
    result = yield
    until result
      raise "timed out waiting for editor state" if Time.now > deadline

      sleep 0.02
      result = yield
    end
    result
  end

  describe "journal events render into a buffer" do
    it "renders a pushed Telemetry event into the lain:// buffer, agent-free" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hello world"))

        rendered = wait_until { journal_lines.grep(/t1.*hello world/).first }
        expect(rendered).to include("hello world")

        # The frontend subscribes to the Channel; it never hands the agent an nvim
        # handle. The Channel push above is the ONLY thing that drove the render.
        expect(handle).not_to respond_to(:client)
        expect(handle).not_to respond_to(:session)
      end
    end

    # Panel fix #4 (and the leading-blank nit): interior blank lines are real
    # lines and must survive; only the trailing-newline artifact is stripped;
    # and the first render replaces the fresh buffer's single empty line, so
    # the journal never leads with a blank.
    it "preserves interior blank lines and never leads the journal with a blank" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t9", stream: :stdout, bytes: "a\n\n\nc\n"))

        wait_until { journal_lines.any? { |line| line.include?("t9") } }
        expect(journal_lines).to eq(["[t9 stdout] a", "[t9 stdout]", "[t9 stdout]", "[t9 stdout] c"])
      end
    end
  end

  describe "teardown under editor death" do
    # Panel fix #1 (BLOCKER). When nvim dies, the RPC thread exits and nothing
    # drains the wake pipe; if post_render's wake WRITE can block on a full pipe,
    # the drainer wedges and run's `ensure -> drainer.join` hangs forever. The
    # wake pipe must be a signal (coalesced non-blocking write), never a queue.
    # Runs frontend.run on its own thread so a regression is a bounded join
    # timeout, not a hung suite.
    it "returns from run within a bounded time when nvim dies under a flood of renders" do
      frontend = described_class.new(channel:, socket_path: @socket)

      runner = Thread.new do
        frontend.run do
          kill_nvim
          flooder = Thread.new do
            70_000.times { |i| channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "flood", stream: :stdout, bytes: "line #{i}")) }
          rescue ClosedQueueError
            # Fix #2 closes the channel on RPC-thread death; a cut-short flood is fine.
          end
          flooder.join
        end
      rescue IOError, SystemCallError, Lain::Error
        # The editor died on purpose (raw on an attach race, wrapped once T9's
        # SessionFailure records it); teardown promptness is the assertion, not
        # the error. Deliberately NOT a blanket StandardError: an unrelated bug
        # (a NoMethodError in the flooder, say) must still surface.
      end

      expect(runner.join(20)).not_to be_nil
    ensure
      runner&.kill
    end

    # Panel fix #2, extended by T9's AC4 ("editor death ends as a notice, not
    # a crash at exit"). The RPC thread's death must not be swallowed: the
    # channel closes (so producers see the loss as ClosedQueueError) and run
    # re-raises the failure once teardown completes -- wrapped in Lain::Error
    # so a caller's `rescue Lain::Error` (the exe's own convention) presents
    # this as a clean notice, never nvim's raw IOError/SystemCallError with a
    # backtrace. The original still rides `cause`, so nothing about the
    # underlying failure is lost to a curious log. The message NAMES the dead
    # thread (fix round): exe/lain forwards e.message verbatim, so a bare
    # "Broken pipe" with no source would be all the user ever saw.
    it "propagates RPC-thread death loudly, wrapped as a Lain::Error, and closes the channel" do
      frontend = described_class.new(channel:, socket_path: @socket)

      error = begin
        frontend.run do
          kill_nvim
          wait_until { channel.closed? }
        end
        nil
      rescue StandardError => e
        e
      end

      expect(error).to be_a(Lain::Error)
      expect(error.message).to start_with("nvim rpc thread died: ")
      expect(error.cause).to be_a(IOError).or be_a(SystemCallError)
      expect(channel).to be_closed
    end
  end

  describe "drain-thread death discipline (T9)" do
    # AC1: an unexpected drain exception (a malformed event's render raising
    # NoMethodError, say) is recorded and closes the channel like its two
    # siblings (the RPC thread, the resend worker) already do, instead of
    # dying silently and wedging a producer against a Channel nobody drains
    # anymore. `render_lines` is private, but stubbing it is the cleanest way
    # to make ONE specific render raise without a purpose-built event type.
    it "records an unexpected drain exception, closes the channel, and re-raises it after teardown" do
      frontend = described_class.new(channel:, socket_path: @socket)
      allow(frontend).to receive(:render_lines).and_raise(NoMethodError, "boom")

      error = begin
        frontend.run do
          channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi"))
          wait_until { channel.closed? }
        end
        nil
      rescue StandardError => e
        e
      end

      expect(error).to be_a(Lain::Error)
      expect(error.message).to start_with("render drain died: ")
      expect(error.cause).to be_a(NoMethodError)
      expect(channel).to be_closed
    end

    # Fix round: the label per source. The resend worker's death must name
    # itself too -- its native failure (a raising journal write) is otherwise
    # indistinguishable from a drain death in the one message the exe shows.
    it "labels a resend-worker death with its source" do
      frontend = described_class.new(channel:, socket_path: @socket)
      request_buffer = frontend.instance_variable_get(:@request_buffer)
      allow(request_buffer).to receive(:resend).and_raise(RuntimeError, "journal torn")

      error = begin
        frontend.run do
          frontend.send(:post_resend, ["edited line"])
          wait_until { channel.closed? }
        end
        nil
      rescue StandardError => e
        e
      end

      expect(error).to be_a(Lain::Error)
      expect(error.message).to eq("resend worker died: journal torn")
      expect(error.cause).to be_a(RuntimeError)
    end

    # AC2: a drainer that died mid-session must never leak the RPC thread.
    # Before the fix, `teardown`'s bare `drainer&.join` re-raised the dead
    # drainer's exception INSIDE `ensure`, so `@rpc.stop` on the next line
    # never ran. Asserted directly against the RPC thread's own liveness
    # (not `Thread.list`, whose bookkeeping around a just-dead thread is not
    # something worth pinning) so a regression here fails for exactly the
    # reason the card names, not an incidental one.
    it "still stops the RPC thread when the drainer already died" do
      frontend = described_class.new(channel:, socket_path: @socket)
      allow(frontend).to receive(:render_lines).and_raise(NoMethodError, "boom")
      rpc_thread = nil

      begin
        frontend.run do
          rpc_thread = frontend.instance_variable_get(:@rpc).instance_variable_get(:@thread)
          channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi"))
          wait_until { channel.closed? }
        end
      rescue Lain::Error
        nil
      end

      expect(rpc_thread).not_to be_nil
      expect(rpc_thread).not_to be_alive
    end

    # AC3: the run block's OWN exception must never be swapped for a
    # background thread's recorded failure -- the two are independent losses,
    # and the block's is the one the caller is actively unwinding from. The
    # recorded death is asserted through the ivar (like @rpc's thread above):
    # observability here means "not silently dropped", not a public reader.
    it "propagates the block's own exception unswapped, and still records the drainer's death" do
      frontend = described_class.new(channel:, socket_path: @socket)
      allow(frontend).to receive(:render_lines).and_raise(NoMethodError, "drain boom")
      block_error = Class.new(StandardError)

      error = begin
        frontend.run do
          channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi"))
          wait_until { channel.closed? }
          raise block_error, "block boom"
        end
        nil
      rescue StandardError => e
        e
      end

      expect(error).to be_a(block_error)
      expect(error.message).to eq("block boom")
      expect(frontend.instance_variable_get(:@drain_failure)).to be_a(NoMethodError)
    end
  end

  describe "re-attach is idempotent" do
    it "defines namespaced :Lain* commands once and records the gem version" do
      first = described_class.new(channel: Lain::Channel.new, socket_path: @socket)
      second = described_class.new(channel: Lain::Channel.new, socket_path: @socket)

      expect do
        first.run do
          second.run do
            commands = inspector.exec_lua("return vim.tbl_keys(vim.api.nvim_get_commands({}))", [])
            expect(commands).to include("LainResend", "LainSend", "LainContext", "LainVersion")
            expect(inspector.get_var("lain_rpc_version")).to eq(described_class::PROTOCOL)
          end
        end
      end.not_to raise_error
    end

    it "surfaces the gem version through :LainVersion" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        inspector.command("LainVersion")
        surfaced = wait_until { messages.include?(Lain::VERSION) }
        expect(surfaced).to be(true)
      end
    end

    # Panel fix #3. The handshake compares the injection PROTOCOL, not the gem
    # version -- a gem release alone must never warn, or every bump cries wolf.
    it "does not warn on a gem version bump alone" do
      frontend = described_class.new(channel:, socket_path: @socket, version: "9.9.9")

      frontend.run do
        inspector.command("LainVersion")
        wait_until { messages.include?("9.9.9") }
        expect(messages).not_to match(/mismatch/)
      end
    end

    it "warns without crashing on a runtime/gem protocol mismatch" do
      frontend = described_class.new(channel:, socket_path: @socket, protocol: "999")

      frontend.run do
        wait_until { messages.match?(/mismatch/) }
        expect(messages).to match(/mismatch/)
        expect(inspector.evaluate("1 + 1")).to eq(2) # the editor is alive, not crashed
      end
    end
  end

  describe "inbound requests do not deadlock" do
    it "enqueues and acks a :Lain* command without freezing the editor" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        # Give the outbound render path live work so the inbound invoke races an
        # active send rather than a quiescent loop.
        5.times { |i| channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t#{i}", stream: :stdout, bytes: "line #{i}")) }

        # If the command were handled inline (not enqueue-and-acked), this
        # rpcrequest chain would never return and the timeout would fire.
        Timeout.timeout(10) { inspector.command("LainResend") }

        received = Timeout.timeout(5) { handle.command_inbox.pop }
        expect(received).to include("resend")
      end
    end
  end
end
