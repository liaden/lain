# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# 4-2.2: read-only lain:// state views (lain://timeline, lain://workspace,
# lain://diff), driven through {Lain::Frontend::Neovim}'s public surface exactly
# as production wiring will -- {Buffers} itself never touches nvim. Same real
# headless-nvim harness as spec/lain/frontend/neovim_spec.rb; see its header
# comment for why a SECOND, independent connection ({#inspector}) is the one
# that observes buffer state.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-buffers-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "--listen", socket, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    @socket = socket
    @nvim_pid = pid
    example.run
  ensure
    begin
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    FileUtils.rm_f(socket)
  end

  let(:channel) { Lain::Channel.new }
  let(:store) { Lain::Store.new }

  def inspector
    @inspector ||= Neovim.attach_unix(@socket)
  end

  def buffer_lines(name)
    inspector.exec_lua(<<~LUA, [name])
      local name = ...
      local buf = vim.fn.bufnr(name)
      if buf == -1 then return {} end
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    LUA
  end

  def buffer_modifiable(name)
    inspector.exec_lua(<<~LUA, [name])
      local name = ...
      local buf = vim.fn.bufnr(name)
      if buf == -1 then return nil end
      return vim.bo[buf].modifiable
    LUA
  end

  def current_win_buf
    inspector.exec_lua("return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(0))", [])
  end

  # Same poll-until helper as neovim_spec.rb: editor effects arrive on the RPC
  # thread, never synchronously with the push that caused them.
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

  def todo(content, status) = Struct.new(:content, :status).new(content, status)

  # Reflection into RpcThread's private RenderQueue -- the T6-inherited fix
  # lives there (see lib/lain/frontend/neovim/rpc_thread.rb), and this is the
  # same instance_variable_get idiom the rest of the suite already uses to
  # assert on an internal without widening a class's public API just for a spec.
  def raw_render_queue(frontend)
    frontend.instance_variable_get(:@rpc).instance_variable_get(:@render_queue).instance_variable_get(:@queue)
  end

  describe "the views exist from attach" do
    # Before priming, an idle session's :buffers listed no lain:// buffer at
    # all -- which a human reads as "broken", not "waiting" (found in the first
    # manual verification pass). Every view now exists at attach, read-only,
    # each stating what it awaits; workspace renders its real (empty) state.
    it "primes every read-only view with its at-rest projection before any event flows" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, store:)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        expect(buffer_lines("lain://timeline")).to eq(["(no turns yet)"])
        expect(buffer_lines("lain://diff")).to eq(["(no requests yet)"])
        expect(buffer_lines("lain://workspace")).to eq(["(no reminders)"])
        expect(buffer_modifiable("lain://timeline")).to be(false)
      end
    end
  end

  describe "lain://timeline reflects a turn commit" do
    it "renders the whole ancestor chain, root first, when a Telemetry::TurnUsage names the head" do
      timeline = Lain::Timeline.empty(store:)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                               .commit(role: :assistant, content: [{ "type" => "text", "text" => "hello there" }])
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, store:)

      frontend.run do
        channel.push(Lain::Telemetry::TurnUsage.new(digest: timeline.head_digest, model: "m", stop_reason: :end_turn,
                                                    usage: {}))

        wait_until { buffer_lines("lain://timeline").include?("user: hi") }
        expect(buffer_lines("lain://timeline")).to eq(["user: hi", "assistant: hello there"])
      end
    end

    it "does not touch lain://timeline for an event that names no turn" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, store:)

      frontend.run do
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi"))

        wait_until { buffer_lines("lain://journal").grep(/hi/).any? } # something rendered
        expect(buffer_lines("lain://timeline")).to eq(["(no turns yet)"])
      end
    end

    # T12 panel fix (SUBSTANTIVE). A digest the store cannot resolve must not
    # kill the sole drain thread: Neovim#post rescues only ClosedQueueError and
    # on_death fires only for RPC-thread death, so an uncaught
    # Store::MissingObject here would silently stop the Channel draining and
    # eventually wedge the agent's producer. The miss renders VISIBLY in the
    # timeline buffer rather than being swallowed, and later events still flow.
    it "survives a TurnUsage whose digest is not in the store, making the miss visible" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, store:)

      frontend.run do
        channel.push(Lain::Telemetry::TurnUsage.new(digest: "blake3:absent", model: "m", stop_reason: :end_turn,
                                                    usage: {}))

        unavailable = wait_until { buffer_lines("lain://timeline").grep(/timeline unavailable/).first }
        expect(unavailable).to include("blake3:absent")

        # The drain thread survived: a later event still renders.
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "after", stream: :stdout, bytes: "still alive"))
        expect(wait_until { buffer_lines("lain://journal").grep(/still alive/).first }).to include("still alive")
      end
    end

    # The other half of the same fix: the old default (`store: Store.new`) was a
    # real-but-disconnected store, so a naive Neovim.new with no store: crashed
    # on the FIRST TurnUsage. The honest default renders the unavailable state.
    it "renders the unavailable state, not a crash, when no store was injected" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket)

      frontend.run do
        channel.push(Lain::Telemetry::TurnUsage.new(digest: "blake3:whatever", model: "m", stop_reason: :end_turn,
                                                    usage: {}))

        unavailable = wait_until { buffer_lines("lain://timeline").grep(/timeline unavailable/).first }
        expect(unavailable).to include("blake3:whatever")
      end
    end
  end

  describe "lain://workspace reflects a reminders change" do
    it "renders the session's current reminders on the next event after they change" do
      session = Lain::Session.new
      session.write_todos([todo("write the spec", "in_progress")])
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, session:)

      frontend.run do
        # The tick that surfaces the change -- Session has no channel event of
        # its own (T1x2 scope), so whatever next flows through the Channel is
        # what makes the already-mutated Session's state observable.
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "tick"))

        wait_until { buffer_lines("lain://workspace").any? }
        expect(buffer_lines("lain://workspace").join("\n")).to include("write the spec")
      end
    end

    it "renders a placeholder, not an empty buffer, when there are no reminders" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, session: Lain::Session.new)

      frontend.run do
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "tick"))

        rendered = wait_until { buffer_lines("lain://workspace") if buffer_lines("lain://workspace").any? }
        expect(rendered).to eq(["(no reminders)"])
      end
    end
  end

  describe "lain://diff reflects a request being sent" do
    it "shows the whole first payload as additions, then only what changed on the next send" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket)

      frontend.run do
        first = { "messages" => [{ "role" => "user", "content" => "a" }] }
        channel.push(Lain::Telemetry::RequestSent.new(digest: "d1", payload: first, stream: true, extra: {}))
        wait_until { buffer_lines("lain://diff").any? { |line| line.start_with?("+") } }
        expect(buffer_lines("lain://diff")).to all(start_with("+"))

        second = { "messages" => [{ "role" => "user", "content" => "a" },
                                  { "role" => "assistant", "content" => "b" }] }
        channel.push(Lain::Telemetry::RequestSent.new(digest: "d2", payload: second, stream: true, extra: {}))

        # A naive line diff over pretty-printed JSON reports the prior closing
        # brace's trailing comma too (JSON syntax, not a real content change) --
        # so this asserts the ADDITION shows up and the view moved, not that
        # nothing else is reported.
        rendered = wait_until do
          lines = buffer_lines("lain://diff")
          lines if lines.any? { |line| line.include?("assistant") }
        end
        expect(rendered).to include(a_string_matching(/^\+.*assistant/))
      end
    end
  end

  describe "read-only and unobtrusive (4-2.2)" do
    it "keeps every lain:// view buffer nomodifiable at rest and never steals focus" do
      timeline = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
      session = Lain::Session.new
      session.write_todos([todo("a", "pending")])
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, store:, session:)

      frontend.run do
        channel.push(Lain::Telemetry::TurnUsage.new(digest: timeline.head_digest, model: "m", stop_reason: :end_turn,
                                                    usage: {}))
        channel.push(Lain::Telemetry::RequestSent.new(digest: "d1", payload: { "a" => 1 }, stream: true, extra: {}))

        wait_until do
          buffer_lines("lain://timeline").include?("user: hi") &&
            buffer_lines("lain://diff").any? { |line| line.start_with?("+") }
        end

        %w[lain://timeline lain://workspace lain://diff].each do |name|
          expect(buffer_modifiable(name)).to be(false), "#{name} was modifiable"
        end
        # The editor's current window never jumped to a view buffer: nothing
        # here ever calls nvim_set_current_buf/win or types into the editor.
        expect(current_win_buf).not_to match(%r{^lain://})
      end
    end
  end

  describe "render backpressure (T6-inherited fix)" do
    it "bounds the render queue at the configured capacity instead of Thread::Queue's unbounded default" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, render_capacity: 7)

      frontend.run do
        renders = raw_render_queue(frontend)
        expect(renders).to be_a(Thread::SizedQueue)
        expect(renders.max).to eq(7)
      end
    end

    it "never lets the backlog exceed capacity under a fast producer" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, render_capacity: 4)

      frontend.run do
        renders = raw_render_queue(frontend)
        observed_max = 0
        watcher = Thread.new { 300.times { observed_max = [observed_max, renders.size].max } }
        600.times { |i| channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "cap", stream: :stdout, bytes: "l#{i}")) }
        watcher.join

        expect(observed_max).to be <= 4
      end
    end

    # The property the T6 review named: a saturated render path must not starve
    # an inbound editor command. Small capacity + a real flood makes the render
    # path genuinely saturated without needing the original ~800K-entry scale.
    it "still acks an inbound command promptly while the render path is saturated" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, render_capacity: 4)

      frontend.run do |handle|
        flooder = Thread.new do
          5_000.times { |i| channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "flood", stream: :stdout, bytes: "l#{i}")) }
        rescue ClosedQueueError
          nil
        end

        ack = Timeout.timeout(5) do
          inspector.command("LainResend")
          handle.command_inbox.pop
        end
        expect(ack).to include("resend")

        flooder.join
      end
    end
  end
end
