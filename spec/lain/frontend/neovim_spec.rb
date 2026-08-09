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
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
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

  def bufnr(name) = inspector.exec_lua("return vim.fn.bufnr(...)", [name])

  # The runtime's own whole-buffer-replace entry point, called straight from
  # the inspector connection -- `_G.__lain` is nvim-process-wide Lua state,
  # reachable from any RPC connection. Content is injected here rather than
  # driven through Telemetry so the example pins the BINDING, not {Buffers}'
  # rendering (which the default-suite group at the bottom of this file owns).
  def set_view(name, lines)
    inspector.exec_lua("local name, lines = ...; _G.__lain.set_view(name, lines)", [name, lines])
  end

  # Feeds `keys` through nvim's own mapping resolution (feedkeys, NOT
  # `:normal!`, which bypasses mappings entirely -- this must exercise the
  # actual buffer-local map). Same helper shape as
  # spec/lain/frontend/neovim/buffers_spec.rb's.
  def feed(bufname, keys, cursor:)
    inspector.exec_lua(<<~LUA, [bufname, keys, cursor])
      local bufname, keys, cursor = ...
      vim.cmd("buffer " .. bufname)
      vim.api.nvim_win_set_cursor(0, cursor)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    LUA
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

    # Priming (see Neovim::Surfaces#prime): the journal exists from attach in the
    # exact one-empty-line state a fresh named_buf holds, so :buffers shows it
    # before any event and the render above still replaces rather than appends
    # (the example below pins that the leading blank never survives).
    it "creates an empty lain://journal at attach, before any event" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { journal_lines == [""] }
        expect(journal_lines).to eq([""])
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

  describe "drain-thread death discipline" do
    # The malformed event this whole discipline exists for: `bytes` that is not
    # a String, which {JournalView#attribute_lines}' `chomp` raises
    # NoMethodError on -- ON THE DRAIN THREAD, which is the point. A real event
    # rather than a stubbed collaborator, so these examples assert the rescue
    # without reaching through the frontend for a view to break.
    def malformed_output = Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: 42)

    # AC1: an unexpected drain exception (a malformed event's render raising
    # NoMethodError, say) is recorded and closes the channel like its two
    # siblings (the RPC thread, the resend worker) already do, instead of
    # dying silently and wedging a producer against a Channel nobody drains
    # anymore. The event itself is the malformed one this rescue exists for --
    # see {#malformed_output} -- rather than a stubbed view: it makes the same
    # render raise the same NoMethodError, and it needs no reach-in to do it.
    it "records an unexpected drain exception, closes the channel, and re-raises it after teardown" do
      frontend = described_class.new(channel:, socket_path: @socket)

      error = begin
        frontend.run do
          channel.push(malformed_output)
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
      request_buffer = frontend.instance_variable_get(:@surfaces).request_buffer
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
      rpc_thread = nil

      begin
        frontend.run do
          rpc_thread = frontend.instance_variable_get(:@rpc).instance_variable_get(:@thread)
          channel.push(malformed_output)
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
      block_error = Class.new(StandardError)

      error = begin
        frontend.run do
          channel.push(malformed_output)
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

  # A re-attach is SEQUENTIAL since T35 -- quit lain, start another one in the
  # same nvim -- because two lains attached at once is refused by name (see
  # neovim_runtime_spec's "one lain per editor"). This group was written as one
  # attach NESTED inside another, the shape ticket 31 measured as silent data
  # destruction, so it certified the defect as a feature for as long as it
  # stood. What it pins is unchanged: a lain exiting tears nothing down, so the
  # second injection lands on top of a whole live runtime.
  describe "re-attach is idempotent" do
    it "defines namespaced :Lain* commands once and records the gem version" do
      described_class.new(channel: Lain::Channel.new, socket_path: @socket).run { nil }
      second = described_class.new(channel: Lain::Channel.new, socket_path: @socket)

      expect do
        second.run do
          commands = inspector.exec_lua("return vim.tbl_keys(vim.api.nvim_get_commands({}))", [])
          expect(commands).to include("LainResend", "LainSend", "LainContext", "LainVersion")
          expect(inspector.get_var("lain_rpc_version")).to eq(described_class::PROTOCOL)
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
        expect(messages).not_to include("mismatch")
      end
    end

    it "warns without crashing on a runtime/gem protocol mismatch" do
      frontend = described_class.new(channel:, socket_path: @socket, protocol: "999")

      frontend.run do
        wait_until { messages.include?("mismatch") }
        expect(messages).to include("mismatch")
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

  # B4's editor half. Only the keybinding ROUND TRIP needs a real nvim -- what
  # the pin resolves to, and how it renders, is plain Ruby in {Buffers} and is
  # pinned by the default-suite group at the bottom of this file.
  describe "the pin gesture on lain://timeline" do
    it "enqueues a pin command naming the cursor's line, buffer-locally" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        wait_until { bufnr("lain://timeline") != -1 }
        set_view("lain://timeline", ["user: first", "assistant: second", "user: third"])

        feed("lain://timeline", "p", cursor: [2, 0])

        verb, args = Timeout.timeout(5) { handle.command_inbox.pop }
        expect(verb).to eq("pin")
        expect(args).to eq([2])
      end
    end

    # Fix round. Every :Lain* command is GLOBAL (see runtime.lua's `define`),
    # and :LainPin reads the CURRENT window's cursor -- so hand-typed from
    # lain://journal line 1 it would send ["pin", [1]] and pin TIMELINE turn 1,
    # a turn the human never looked at, silently and (under B2) permanently.
    # Hand-typing is an invited path here precisely because the `p` map invokes
    # the command rather than a private helper, so the command must refuse on
    # its own. Asserted without a sleep: the journal invocation is followed by a
    # real one, and the FIRST thing to reach the inbox must be the real one.
    it "refuses to pin from a buffer that is not the timeline, and says so" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        wait_until { bufnr("lain://timeline") != -1 && bufnr("lain://journal") != -1 }
        set_view("lain://timeline", ["user: first", "assistant: second", "user: third"])

        feed("lain://journal", ":LainPin<CR>", cursor: [1, 0])
        feed("lain://timeline", "p", cursor: [3, 0])

        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["pin", [3]])
        expect(messages).to include("LainPin")
      end
    end
  end

  # B16's editor half: the add-to-survey gesture only EMITS `survey_add`; B12
  # (not yet landed) is what gives the verb a route and a meaning. Real nvim,
  # `pin`'s reason above: only the keybinding round trip needs one.
  describe "the add-to-survey gesture on a real file buffer" do
    def open_real_file(path)
      inspector.exec_lua(<<~LUA, [path])
        local path = ...
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        return vim.api.nvim_get_current_buf()
      LUA
    end

    def stamp_generation(buf, gen)
      inspector.exec_lua("local buf, gen = ...; vim.b[buf].lain_view_generation = gen", [buf, gen])
    end

    # A tmp file rather than a lain:// buffer: the gesture's whole premise is
    # that it fires from a buffer this runtime does not name ahead of time
    # (see 46_sidebar.lua's comment on why the keymap is GLOBAL).
    def real_file(content = "hello\n")
      path = File.join(Dir.mktmpdir, "notes.md")
      File.write(path, content)
      path
    end

    it "emits survey_add carrying the buffer's absolute path and its view generation" do
      frontend = described_class.new(channel:, socket_path: @socket)
      path = real_file

      frontend.run do |handle|
        buf = open_real_file(path)
        stamp_generation(buf, 7)

        feed(path, "\\sa", cursor: [1, 0])

        verb, args = Timeout.timeout(5) { handle.command_inbox.pop }
        expect(verb).to eq("survey_add")
        expect(args).to eq([path, 7])
      end
    end

    # The trigger this card exists to check: Ruby has no route for `survey_add`
    # yet (B12 is unmerged), so `Router#call`'s unrouted-verb path
    # (`rpc_thread.rb:741`) is exercised for real rather than assumed. If the
    # ack had not returned -- a raise reaching `dispatch`, or the connection
    # wedged -- neither the inbox pop nor the round trip below would return
    # inside their timeouts.
    it "acks the gesture and keeps serving requests, with no route wired for it" do
      frontend = described_class.new(channel:, socket_path: @socket)
      path = real_file

      frontend.run do |handle|
        open_real_file(path)

        feed(path, "\\sa", cursor: [1, 0])

        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to include("survey_add")
        expect { Timeout.timeout(5) { inspector.command("echo 'still here'") } }.not_to raise_error
        expect(messages).not_to match(/E5108|Error executing lua/)
      end
    end

    # Fix round (panel finding, Linus): the empty-name guard alone let this
    # fire from any lain:// buffer -- which HAS a name -- and send the view
    # URI as though it were a file path. `:LainPin`'s own wrong-buffer spec
    # above is the shape this follows: asserted without a sleep, because the
    # lain://timeline press is followed by a real one and the FIRST thing to
    # reach the inbox must be the real one, not the URI.
    it "refuses from a lain:// buffer, and says so, rather than sending its URI as a path" do
      frontend = described_class.new(channel:, socket_path: @socket)
      path = real_file

      frontend.run do |handle|
        wait_until { bufnr("lain://timeline") != -1 }
        set_view("lain://timeline", ["user: first", "assistant: second"])

        feed("lain://timeline", "\\sa", cursor: [1, 0])
        open_real_file(path)
        feed(path, "\\sa", cursor: [1, 0])

        verb, args = Timeout.timeout(5) { handle.command_inbox.pop }
        expect(verb).to eq("survey_add")
        expect(args.first).to eq(path)
        expect(messages).to include("LainSurveyAdd")
      end
    end
  end
end

# B4's plain-Ruby half: the line -> digest index, the pin marker, and the pin
# gesture itself. {Buffers} never touches nvim -- it turns events into lines
# and answers "which turn is on line N?" -- so this whole group runs in the
# DEFAULT suite, with no editor and no :nvim tag. The one thing that genuinely
# needs an editor (does `p` reach Ruby at all?) is the :nvim example above.
RSpec.describe Lain::Frontend::Neovim::Buffers do
  let(:store) { Lain::Store.new }
  let(:session) { Lain::Session.new }
  let(:buffers) { described_class.new(store:, session:) }

  # Three turns, alternating roles, root first -- {Timeline#to_a}'s order and
  # therefore the rendered line order.
  def timeline_of(*texts)
    texts.each_with_index.inject(Lain::Timeline.empty(store:)) do |timeline, (text, i)|
      timeline.commit(role: i.even? ? :user : :assistant, content: [{ "type" => "text", "text" => text }])
    end
  end

  def usage(digest)
    Lain::Telemetry::TurnUsage.new(digest:, model: "m", stop_reason: :end_turn, usage: {})
  end

  # One render of lain://timeline, through the same public surface the drain
  # thread uses.
  def render(view, timeline)
    view.updates(usage(timeline.head_digest)).fetch(described_class::TIMELINE)
  end

  describe "pinning from the timeline buffer" do
    it "pins the turn the cursor's line names" do
      timeline = timeline_of("first", "second", "third")
      render(buffers, timeline)

      outcome = buffers.pin(2)

      expect(outcome).to be_pinned
      expect(outcome.digest).to eq(timeline.to_a[1].digest)
      expect(session.pins).to eq([timeline.to_a[1].digest])
    end
  end

  describe "a pinned turn is marked in the rendering" do
    it "marks only the pinned turn's line on the next render" do
      timeline = timeline_of("first", "second", "third")
      render(buffers, timeline)
      buffers.pin(2)

      lines = render(buffers, timeline)

      expect(lines[1]).to end_with(described_class::TimelineView::PIN_MARKER)
      expect(lines.grep(/#{Regexp.escape(described_class::TimelineView::PIN_MARKER)}\z/o).size).to eq(1)
    end
  end

  describe "every rendered turn line maps to its own digest" do
    it "resolves each 1-based line to that turn's digest" do
      timeline = timeline_of("first", "second", "third")

      lines = render(buffers, timeline)

      expect((1..lines.size).map { |line| buffers.digest_at(line) }).to eq(timeline.to_a.map(&:digest))
    end

    # Line 0 is the trap a bare `@line_digests[line - 1]` walks into: -1
    # indexes the LAST turn, so a cursor nvim never reports would pin the head.
    it "resolves nothing for a line outside the rendering" do
      render(buffers, timeline_of("first", "second"))

      expect(buffers.digest_at(0)).to be_nil
      expect(buffers.digest_at(3)).to be_nil
    end
  end

  describe "an unavailable timeline offers nothing to pin" do
    # The Store::MissingObject rescue replaces the WHOLE chain with one notice
    # line, so the index must empty with it -- and the gesture must not reach
    # Session#record_pin, which refuses a blank digest loudly.
    it "pins nothing and reports the failure" do
      timeline = timeline_of("first", "second")
      detached = described_class.new(store: Lain::Store.new, session:)
      allow(session).to receive(:record_pin).and_call_original

      lines = render(detached, timeline)
      outcome = detached.pin(1)

      expect(lines.size).to eq(1)
      expect(lines.first).to include("timeline unavailable")
      expect(outcome).not_to be_pinned
      expect(outcome.report).to include("line 1")
      expect(session.pins).to be_empty
      expect(session).not_to have_received(:record_pin)
    end

    # Fix round. {Buffers#initial} is a RENDER like any other -- it posts the
    # "(no turns yet)" placeholder, which describes no turn -- so it must leave
    # nothing resolvable behind it. Latent rather than live today (priming runs
    # once, first), but it is the same stale-index class this card exists to
    # close, and closing it is one line.
    it "drops the index when the at-rest placeholder is re-posted" do
      render(buffers, timeline_of("first", "second"))

      expect(buffers.initial.fetch(described_class::TIMELINE)).to eq(["(no turns yet)"])
      expect(buffers.digest_at(1)).to be_nil
      expect(buffers.pin(1)).not_to be_pinned
    end

    # The index that a successful render built must not survive a later miss:
    # the lines it described are gone from the buffer.
    it "drops a previously built index when a later chain cannot be resolved" do
      timeline = timeline_of("first", "second")
      render(buffers, timeline)
      orphan = Lain::Timeline.empty(store: Lain::Store.new)
                             .commit(role: :user, content: [{ "type" => "text", "text" => "elsewhere" }])

      buffers.updates(usage(orphan.head_digest))

      expect(buffers.digest_at(1)).to be_nil
      expect(buffers.pin(1)).not_to be_pinned
    end
  end
end

# T34 review fix (substantive #1): FrontendListener's four hand-offs, pinned
# directly and in plain Ruby -- no editor, no :nvim tag, no 300-second
# Compose::GRACE wait. Before this group existed, a `compose_abandoned`
# mutated to a no-op survived the whole default suite and only reddened the
# :nvim end-to-end spec (neovim_runtime_spec.rb's "sends nothing when the
# buffer is unloaded without being written") after paying out the full grace
# period. FrontendListener is `private_constant`, so this reaches the live
# instance through Neovim's own construction rather than describing it by
# name -- the same instance_variable_get idiom the rest of this file already
# uses for @rpc/@render_queue.
#
# Construction alone is enough: {RpcThread#start} is what attaches over the
# socket, and {Neovim#initialize} never calls it, so building a frontend here
# is instant and touches no editor.
RSpec.describe Lain::Frontend::Neovim do
  let(:frontend) { described_class.new(channel: Lain::Channel.new, socket_path: "/nonexistent") }
  let(:listener) { frontend.instance_variable_get(:@rpc).instance_variable_get(:@listener) }

  describe "the listener RpcThread was built with" do
    it "forwards #died by closing the channel" do
      listener.died

      expect(frontend.instance_variable_get(:@channel)).to be_closed
    end

    it "forwards #resend onto the resend inbox (via #post_resend)" do
      listener.resend(["edited line"])

      expect(frontend.instance_variable_get(:@resend_inbox).pop).to eq(["edited line"])
    end

    it "forwards #compose_written to Compose#wrote" do
      allow(frontend.compose).to receive(:wrote)

      listener.compose_written(["draft line"], 5)

      expect(frontend.compose).to have_received(:wrote).with(["draft line"], 5)
    end

    it "forwards #compose_abandoned to Compose#abandoned" do
      allow(frontend.compose).to receive(:abandoned)

      listener.compose_abandoned(9)

      expect(frontend.compose).to have_received(:abandoned).with(9)
    end
  end

  # T31a: the review's OUTBOUND half, which this editor owns for the same reason
  # it owns #buffers -- and which nothing could reach before, so no wiring ever
  # drew a changeset in a real editor.
  describe "the changeset review's surface and view" do
    # A REAL marked changeset over {#round}, not a Struct: what the sidebar
    # reads off one has grown twice since this group was written (a row's
    # `#hunk_keys`, then its `#chunked?`), and a hand-rolled duck goes stale
    # without failing until a view finally asks. It is also the same round the
    # `<CR>` below resolves against, which a separate double was free to
    # contradict.
    def changeset
      over = round
      Lain::Review::Session::MarkedChangeset.of(over, Lain::Review::Marks.new(base_ref: over.base_ref),
                                                strategy: Lain::Review::Partition::STRATEGIES.fetch(:cumulative))
    end

    it "is one pair for the session, so a gesture resolves against what was drawn" do
      frontend.review_surface.present(changeset, scope: :cumulative)

      marked = frontend.review_view.marks(1, generation: 1)

      expect(marked.marked?).to be(true)
    end

    # The pairing said as identity as well as behaviour: a caller building its
    # own surface over this inlet would get a SECOND view, and every gesture
    # stamped by this one would then resolve against a rendering that view never
    # drew -- a wrong row, silently, rather than an error.
    it "answers the same objects every time it is asked" do
      expect(frontend.review_surface).to equal(frontend.review_surface)
      expect(frontend.review_view).to equal(frontend.review_view)
    end

    # The round the gesture below resolves against: a REAL changeset, because
    # what the diff surface reads off one -- the file, its old side, both
    # revisions -- is exactly what a double would be free to invent.
    def round
      text = "diff --git a/lib/a.rb b/lib/a.rb\n--- a/lib/a.rb\n+++ b/lib/a.rb\n@@ -1 +1 @@\n-old\n+new\n"
      stat = Lain::Review::Source::FileStat.new(path: "lib/a.rb", added: 1, deleted: 1)
      commit = Lain::Review::Source::Commit.new(sha: "c1", subject: "s", body: "", numstat: [stat].freeze)
      double = instance_double(Lain::Review::Source::LocalBranch,
                               diff: text.b, commits: [commit].freeze,
                               base_ref: "b" * 40, head_ref: "h" * 40)
      allow(double).to receive(:file_at).and_return("old\n".b)
      Lain::Review::Changeset.new(source: DiffSource.over(double))
    end

    # T32a's acceptance test, from the one place that decides it. The pair is a
    # TRIO now: the view is built with a {Lain::Frontend::Neovim::ChangesetDiff}
    # over this editor's own inlet, so a `<CR>` on a row REACHES something.
    # Before this, `changesets:` was {Lain::Frontend::Neovim::ReviewView::Unwired}
    # in every real process, and that refusal was the whole of what a `<CR>` in
    # the editor's review could do.
    #
    # Asserted through the gesture rather than by naming the collaborator's
    # class: what has to be true is that a wired review cannot produce that
    # sentence, and an implementation wiring the wrong object would name the
    # right class and still refuse.
    it "wires the diff surface a row opens through, so the unwired refusal is unreachable" do
      frontend.review_view.reviewing(round)
      frontend.review_surface.present(changeset, scope: :cumulative)

      opened = frontend.review_view.open(1, generation: 1)

      expect(opened).to have_attributes(opened?: true, path: "lib/a.rb")
      expect(opened.report).not_to include("no diff surface is wired")
    end
  end

  # T28 review fix: the protocol contract, pinned WITHOUT an editor -- which is the
  # point of the group, not an incidental economy. `LAIN_NVIM=0` is a supported mode
  # (spec/support/tags.rb), and in it every other pin on this contract is filtered
  # out: the panel reverted BOTH halves to "8", undoing the bump entirely, and the
  # suite answered 10449 examples, 0 failures. Both properties below are pure reads
  # of source already on disk, so neither needs the editor that was hiding them.
  describe "the protocol contract" do
    let(:runtime) { Lain::Frontend::Neovim::RuntimeLoader.new.source }

    # The lockstep, said in the one place it can be said with no nvim running. It
    # COMPLEMENTS the live attach checks rather than replacing them -- a runtime that
    # fails to LOAD still has the right number in its text, and only an editor catches
    # that. What this catches is the reverse: half a bump.
    it "holds the same protocol in the gem and in the runtime it injects" do
      expect(runtime[/RUNTIME_PROTOCOL = "(\d+)"/, 1]).to eq(described_class::PROTOCOL)
    end

    # "A history that SKIPS a version is worse than none" is the history block's own
    # rule, and d125aba is the proof it is not hypothetical: a bump shipped with no
    # line, and entry "5" is the backfill. Asserting the entry for TODAY's number
    # states a fact about today; this states the RULE, so the next bump cannot go
    # green without its line -- which is what the panel's mutant did, moving both
    # constants to "10", sweeping the doc stamps, and skipping the entry, at 0
    # failures.
    it "keeps an entry for every protocol from 2 up to the constant" do
      expect(protocol_history.keys.map(&:to_i)).to eq((2..described_class::PROTOCOL.to_i).to_a)
    end
  end
end
