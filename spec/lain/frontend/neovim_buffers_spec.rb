# frozen_string_literal: true

require "async"
require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ApprovalPrimeSupport
  # The gated call the editor is asked about. A Struct rather than a real
  # {Lain::Effect} for {Lain::Approval::Queue::Pending}'s own reason: it reads a
  # name, an input and a tool_use_id, and nothing else. Named apart from
  # neovim_runtime_spec's identical fixture on purpose -- both files load into
  # one process, and a shared top-level constant would make whichever loaded
  # second silently reopen the first.
  Effect = Struct.new(:name, :input, :tool_use_id)
end

# 4-2.2: read-only lain:// state views (lain://timeline, lain://workspace,
# lain://diff), driven through {Lain::Frontend::Neovim}'s public surface exactly
# as production wiring will -- {Buffers} itself never touches nvim. Same real
# headless-nvim harness as spec/lain/frontend/neovim_spec.rb; see its header
# comment for why a SECOND, independent connection ({#inspector}) is the one
# that observes buffer state.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-buffers-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
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

  # How many of the primed lines the editor believes are answerable rows. nil
  # when the buffer exists but nothing ever wrote the variable -- which is the
  # `set_view` mis-prime this asserts against, and why the expectation is `0`
  # rather than a falsy check.
  def buffer_approval_rows(name)
    inspector.exec_lua(<<~LUA, [name])
      local buf = vim.fn.bufnr(...)
      if buf == -1 then return nil end
      return vim.b[buf].lain_approval_rows
    LUA
  end

  def buffer_view_var(name)
    inspector.exec_lua(<<~LUA, [name])
      local buf = vim.fn.bufnr(...)
      if buf == -1 then return nil end
      return vim.b[buf].lain_view
    LUA
  end

  # How much SCREEN a buffer is taking, which is the question the objection to
  # priming lain://approval was really about. -1 distinguishes "no such buffer"
  # from "a buffer nothing is showing", so a prime that never happened cannot
  # pass as a prime that took no window.
  def windows_showing(name)
    inspector.exec_lua(<<~LUA, [name])
      local buf = vim.fn.bufnr(...)
      if buf == -1 then return -1 end
      return #vim.fn.win_findbuf(buf)
    LUA
  end

  # Feeds keys through nvim's OWN mapping resolution (feedkeys, never
  # `:normal!`, which bypasses mappings), so the buffer-local `y` map
  # 62_approval.lua installs is what runs.
  def press(bufname, keys, cursor: [])
    inspector.exec_lua(<<~LUA, [bufname, keys, cursor])
      local bufname, keys, cursor = ...
      vim.cmd("buffer " .. bufname)
      if cursor[1] then
        vim.api.nvim_win_set_cursor(0, cursor)
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
      return true
    LUA
  end

  # A REAL gated call parked in a REAL {Lain::Approval::Queue}, with the REAL
  # consumer bound the way {Lain::CLI::Repl} binds it -- neovim_runtime_spec's
  # harness, trimmed to the one question this file asks: does the buffer the
  # attach primed still take the first real approval and still answer it.
  #
  # It is a THREAD rather than a task on the example's own fiber for the reason
  # that file records at length: a neovim gem call issued from inside an Async
  # task takes the gem's fiber-yielding branch and raises FiberError. The
  # inspector stays on the main thread; everything reactor-shaped stays in here.
  def with_parked_approval(frontend, grace: 8)
    settled = Thread::Queue.new
    worker = Thread.new { serve_approval(frontend, settled, grace) }
    yield
    Timeout.timeout(20) { settled.pop }
  ensure
    raise "the approval consumer thread never stopped" unless worker&.join(20)
  end

  # `:unsettled` is a THIRD answer on purpose: a fail-closed denial answers
  # `false`, which is also what a working deny answers, so a run that hung must
  # be distinguishable from one that decided. The queue's own clock is set far
  # beyond the grace for the same reason.
  def serve_approval(frontend, settled, grace)
    Sync do |task|
      queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: StringIO.new), timeout: 60)
      surfaces = approval_surfaces(task, frontend, queue)
      effect = ApprovalPrimeSupport::Effect.new("bash", { "command" => "pwd" }, "tu_1")
      gated = task.async { queue.call(effect, nil) }
      settled.push(within(task, grace) { gated.finished? } ? gated.wait : :unsettled)
      (surfaces + [gated]).each(&:stop)
    end
  end

  # Whether the condition held before the window ran out. Running out the clock
  # is a legitimate outcome here and it is the one `:unsettled` reports, so this
  # answers rather than raising at its deadline.
  def within(task, grace)
    deadline = Async::Clock.now + grace
    task.sleep(0.02) until yield || Async::Clock.now > deadline
    yield
  end

  # Exactly what `Repl#run` binds and what `Repl#respond` spawns: the editor's
  # gesture consumer over the frontend's rail and views, plus the approval
  # view's own watch fiber over the same queue the gated call parks in.
  def approval_surfaces(task, frontend, queue)
    replies = Lain::CLI::HumanReplies.new(tty: null_tty, conductor: instance_double(Lain::CLI::Conductor),
                                          ask_human: Lain::Tools::AskHuman::Directory.new,
                                          questions: Async::Queue.new)
    replies.bind_editor(frontend.command_inbox, views: frontend.buffers, approvals: frontend.approval_view)
    replies.session_surfaces(task) + [task.async { frontend.approval_view.watch(queue) }]
  end

  def null_tty
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: StringIO.new, input: StringIO.new,
                            history_path: File.join(Dir.tmpdir, "lain-approval-prime-history"))
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

  # Reflection into the backlog behind RpcThread's RenderInlet -- the
  # T6-inherited fix lives there (see lib/lain/frontend/neovim/rpc_thread.rb),
  # and this is the same instance_variable_get idiom the rest of the suite
  # already uses to assert on an internal without widening a class's public API
  # just for a spec. The inlet owns the RenderQueue, which owns the SizedQueue
  # whose bound is the property under test.
  def raw_render_queue(frontend)
    inlet = frontend.instance_variable_get(:@rpc).instance_variable_get(:@inlet)
    inlet.instance_variable_get(:@queue).instance_variable_get(:@queue)
  end

  describe "the views exist from attach" do
    # Before priming, an idle session's :buffers listed no lain:// buffer at
    # all -- which a human reads as "broken", not "waiting" (found in the first
    # manual verification pass). Every view now exists at attach, read-only,
    # each stating what it awaits; workspace renders its real (empty) state.
    it "primes every read-only view with its at-rest projection before any event flows" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        expect(buffer_lines("lain://timeline")).to eq(["(no turns yet)"])
        expect(buffer_lines("lain://diff")).to eq(["(no requests yet)"])
        expect(buffer_lines("lain://workspace")).to eq(["(no reminders)"])
        expect(buffer_modifiable("lain://timeline")).to be(false)
      end
    end

    # UX4, and it is a WIRING claim, which is why it is here and not in
    # surfaces_spec: the cause was that {Lain::Frontend::Neovim::Surfaces} did
    # not hold the {Lain::Frontend::Neovim::ApprovalView} at all -- the view
    # hung off the frontend and rendered only from its own watch fiber, which
    # nothing spawns until a call is gated. A doubled Surfaces handed an
    # approval view primes happily whether or not `#attach` ever wires one, so
    # only the real attach path can witness this.
    it "primes lain://approval too, so the surface a gated agent waits on exists at rest" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do
        wait_until { buffer_lines("lain://approval").any? }
        expect(buffer_lines("lain://approval")).to eq(["(no approvals pending)"])
        # A primed buffer must be a lain VIEW, not an orphan: `named_buf`
        # attaches a filetype from READONLY_FILETYPES, which does not name this
        # buffer, so 62_approval.lua joins the shared "lain" filetype itself and
        # b:lain_view is what says which view it is. It is also what
        # neovim_runtime_spec's "sets b:lain_view on every lain:// buffer" reads.
        expect(buffer_view_var("lain://approval")).to eq("lain://approval")
        # PANEL FIX 2, and it is what separates priming through `set_approval`
        # from priming through `set_view`: only `set_approval` writes
        # b:lain_approval_rows, and 62_approval.lua's `submit_approval` reads it
        # (`line <= (vim.b[buf].lain_approval_rows or 0)`) to decide whether the
        # cursor is on an answerable row at all. A buffer primed through the
        # wrong inlet passes every other assertion in this block -- it has the
        # name, the lines and b:lain_view -- and leaves the variable nil, which
        # is indistinguishable from zero here and is NOT indistinguishable once
        # rows exist. Zero is also exactly why this prime takes no window.
        expect(buffer_approval_rows("lain://approval")).to eq(0)
      end
    end

    # The recorded objection to priming this buffer -- "it would put an empty
    # window on screen at every attach" -- and the runtime's own answer to it:
    # `runtime/62_approval.lua` opens a window only `if rows > 0`, so a prime
    # carrying zero rows creates the buffer and takes no screen.
    it "takes no window for the primed approval list, so an empty surface costs no screen" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do
        wait_until { buffer_lines("lain://approval").any? }
        expect(windows_showing("lain://approval")).to eq(0)
        expect(current_win_buf).not_to eq("lain://approval")
      end
    end

    # The other half of the same claim: priming must not change what the first
    # REAL approval does. A prime that recorded the empty list as "what the
    # screen shows" would make the first sweep skip, and a prime that skipped
    # `set_approval` would leave the buffer without b:lain_approval_rows -- in
    # which case the row renders and `y` on it is inert.
    it "still renders the first real approval into the primed buffer, and still answers it with y" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do |handle|
        wait_until { buffer_lines("lain://approval") == ["(no approvals pending)"] }

        settled = with_parked_approval(handle) do
          wait_until { buffer_lines("lain://approval").join.include?("pwd") }
          press("lain://approval", "y", cursor: [1, 0])
        end

        expect(settled).to be(true)
      end
    end
  end

  describe "lain://timeline reflects a turn commit" do
    it "renders the whole ancestor chain, root first, when a Telemetry::TurnUsage names the head" do
      timeline = Lain::Timeline.empty(store:)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                               .commit(role: :assistant, content: [{ "type" => "text", "text" => "hello there" }])
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do
        channel.push(Lain::Telemetry::TurnUsage.new(digest: timeline.head_digest, model: "m", stop_reason: :end_turn,
                                                    usage: {}))

        wait_until { buffer_lines("lain://timeline").include?("user: hi") }
        expect(buffer_lines("lain://timeline")).to eq(["user: hi", "assistant: hello there"])
      end
    end

    it "does not touch lain://timeline for an event that names no turn" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "hi"))

        wait_until { buffer_lines("lain://journal").grep(/hi/).any? } # something rendered
        expect(buffer_lines("lain://timeline")).to eq(["(no turns yet)"])
      end
    end

    # T12 panel fix (SUBSTANTIVE). A digest the store cannot resolve must not
    # kill the sole drain thread: Neovim#post rescues only ClosedQueueError and
    # FrontendListener#died fires only for RPC-thread death, so an uncaught
    # Store::MissingObject here would silently stop the Channel draining and
    # eventually wedge the agent's producer. The miss renders VISIBLY in the
    # timeline buffer rather than being swallowed, and later events still flow.
    it "survives a TurnUsage whose digest is not in the store, making the miss visible" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

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
      frontend = described_class.new(channel:, socket_path: @socket)

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
      frontend = described_class.new(channel:, socket_path: @socket, session:)

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
      frontend = described_class.new(channel:, socket_path: @socket, session: Lain::Session.new)

      frontend.run do
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "tick"))

        rendered = wait_until { buffer_lines("lain://workspace") if buffer_lines("lain://workspace").any? }
        expect(rendered).to eq(["(no reminders)"])
      end
    end
  end

  describe "lain://diff reflects a request being sent" do
    it "shows the whole first payload as additions, then only what changed on the next send" do
      frontend = described_class.new(channel:, socket_path: @socket)

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
      frontend = described_class.new(channel:, socket_path: @socket, store:, session:)

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

  describe "render backpressure" do
    it "bounds the render queue at the configured capacity instead of Thread::Queue's unbounded default" do
      frontend = described_class.new(channel:, socket_path: @socket, render_capacity: 7)

      frontend.run do
        renders = raw_render_queue(frontend)
        expect(renders).to be_a(Thread::SizedQueue)
        expect(renders.max).to eq(7)
      end
    end

    it "never lets the backlog exceed capacity under a fast producer" do
      frontend = described_class.new(channel:, socket_path: @socket, render_capacity: 4)

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
      frontend = described_class.new(channel:, socket_path: @socket, render_capacity: 4)

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
