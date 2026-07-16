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
      rescue IOError, SystemCallError
        # The editor died on purpose; teardown promptness is the assertion, not the error.
      end

      expect(runner.join(20)).not_to be_nil
    ensure
      runner&.kill
    end

    # Panel fix #2. The RPC thread's death must not be swallowed: the channel
    # closes (so producers see the loss as ClosedQueueError) and run re-raises
    # the failure once teardown completes.
    it "propagates RPC-thread death loudly and closes the channel" do
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

      expect(error).to be_a(IOError).or be_a(SystemCallError)
      expect(channel).to be_closed
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
