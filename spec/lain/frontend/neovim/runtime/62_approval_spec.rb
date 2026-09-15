# frozen_string_literal: true

require "async"
require "timeout"
require "stringio"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ApprovalSeamSupport
  # The gated call this editor is asked about. A Struct rather than a real
  # {Lain::Effect} for {Lain::Approval::Queue::Pending}'s own reason: it reads a
  # name, an input and a tool_use_id, and nothing else.
  Effect = Struct.new(:name, :input, :tool_use_id)
end

# `runtime/62_approval.lua` -- the gated call put in front of the human, and the
# verdict getting back to the fiber parked on it.
#
# Both halves are here because they are the same claim from two sides. The first
# group binds the view the way {Lain::CLI::Repl} binds it and proves the round
# trip; the second drives the REAL repl and proves that anything in production
# performs that bind at all. Two earlier rounds each found a capability whose
# every collaborator had a green spec and which no code path ever constructed.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-approval-spec") { example.run } }

  # The reason this block exists: the whole approval seam was built for
  # a Neovim surface -- {Lain::Frontend::ApprovalPolicy}'s own class comment
  # names it -- and nothing had ever written one, so a gated call parked the
  # agent with the question visible in the chat pane alone.
  #
  # It drives a REAL {Lain::Approval::Queue} with a REAL fiber parked in it,
  # the REAL consumer ({Lain::CLI::HumanReplies}, bound as `Repl#run` binds
  # it), and a REAL editor, because the verdict reaching the parked call is the
  # only claim worth making: a view that renders rows and wires nothing renders
  # identically.
  describe "answering a parked approval in the editor, end to end" do
    let(:journal_io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io: journal_io) }

    it "approves the parked call when the human presses y on its row" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        settled = with_parked_approval(handle) do
          wait_until_editor { buffer_lines("lain://approval").join.include?("pwd") }
          press("lain://approval", "y", cursor: [1, 0])
        end

        expect(settled).to be(true)
        expect(decisions.last).to include("verdict" => "approve", "tool" => "bash",
                                          "surface" => Lain::Frontend::Neovim::ApprovalView::SURFACE)
      end
    end

    # The counterfactual for the example above: the same path, the other key,
    # and a DIFFERENT verdict reaching the gated fiber. A view that answered
    # `true` whatever was pressed passes the approve example alone.
    it "denies it when the human runs :LainDeny, so the two verdicts are not one gesture" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        settled = with_parked_approval(handle) do
          wait_until_editor { buffer_lines("lain://approval").join.include?("pwd") }
          inspector.command("buffer lain://approval")
          inspector.command("LainDeny")
        end

        expect(settled).to be(false)
        expect(decisions.last).to include("verdict" => "deny")
      end
    end

    # `y` is a GLOBAL command's keymap only inside this buffer, and the command
    # behind it reads the CURRENT window's cursor -- so typed elsewhere it must
    # answer nothing rather than whatever the list holds on that line. The
    # gated call is still parked when the block ends, which is what
    # `:unsettled` means.
    it "answers nothing from a buffer that is not the approval list" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        settled = with_parked_approval(handle, grace: 1.5) do
          wait_until_editor { buffer_lines("lain://approval").join.include?("pwd") }
          press("lain://journal", "y", cursor: [1, 0])
          inspector.command("buffer lain://journal")
          inspector.command("LainApprove")
        end

        expect(settled).to eq(:unsettled)
        # The abandon the harness's own teardown journals is not a decision this
        # surface made, which is the claim: nothing lain://approval owns
        # answered anything.
        expect(decisions.map { |record| record["surface"] })
          .not_to include(Lain::Frontend::Neovim::ApprovalView::SURFACE)
      end
    end

    it "draws the list as a read-only lain view, stamped with the rendering and its row count" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        with_parked_approval(handle, grace: 0.1) do
          wait_until_editor { buffer_lines("lain://approval").join.include?("pwd") }
          state = approval_state
          expect(state).to include("buftype" => "nofile", "modifiable" => false, "filetype" => "lain",
                                   "lain_view" => "lain://approval", "rows" => 1)
          expect(state["generation"]).to be_a(Integer)
          # It took a window, which is the whole point: the defect was an
          # editor that showed nothing while the agent sat parked.
          expect(state["windows"]).to be >= 1
        end
      end
    end

    # The finding this pair answers: `approve_in_editor` (below) reads a call
    # back with `buffer_lines(...).join`, and a wrapped item's continuation
    # lines carry {ApprovalView::INDENT} -- so joining puts two spaces in the
    # middle of what was one contiguous run of bytes in the command, and a
    # substring match on the ORIGINAL command misses. The fix is not to stop
    # wrapping (`approval_view_spec.rb` pins the hard wrap, mid-token, on
    # purpose) -- it is to hand the reader a copy that was never cut.
    #
    # TWO variables, not one: `lain_approval_calls` is one entry per PARKED
    # CALL and `lain_approval_call_index` resolves a cursor line to its member
    # -- {Lain::Frontend::Neovim::ApprovalView::Rendering}'s own comment is
    # where that shape and the reason (a linear wire payload, not one
    # quadratic in a wrapped call's length) are derived. `call_for_row` below
    # is the lua consumer's own resolution, `calls[call_index[row]]`.
    it "carries the wrapped command unwrapped, with the rendered lines unchanged" do
      frontend = described_class.new(channel:, socket_path: @socket)
      long_command = "x" * 200
      full_call = "bash(#{{ "command" => long_command }.inspect})"

      frontend.run do |handle|
        with_parked_approval(handle, input: { "command" => long_command }, grace: 0.1) do
          wait_until_editor { (approval_state["rows"] || 0).positive? }
          lines = buffer_lines("lain://approval")

          # The rendered bytes are exactly what a hard, mid-token wrap always
          # produced here -- this card changes no rendered byte.
          expect(lines.first.length).to eq(Lain::Frontend::Neovim::ApprovalView::WIDTH)
          expect(lines[1]).to start_with(Lain::Frontend::Neovim::ApprovalView::INDENT)
          expect(lines.join).not_to include(long_command)

          # ONE parked call, so `calls` holds exactly one entry -- not one per
          # row it wraps into -- and every row's index resolves back to it.
          expect(approval_calls).to eq([full_call])
          expect(approval_call_index.uniq).to eq([1])
          expect(approval_call_index.size).to eq(approval_state["rows"])
          expect(call_for_row(1)).to eq(full_call)
          expect(call_for_row(approval_state["rows"])).to eq(full_call)
        end
      end
    end

    it "resolves one unwrapped call per answerable row, in queue order, for two parked approvals" do
      frontend = described_class.new(channel:, socket_path: @socket)
      settled = Thread::Queue.new
      pwd_call = "bash(#{{ "command" => "pwd" }.inspect})"
      whoami_call = "bash(#{{ "command" => "whoami" }.inspect})"

      frontend.run do |handle|
        worker = Thread.new { two_parked_approvals(handle, settled) }
        wait_until_editor { (approval_calls || []).size >= 2 }

        expect(approval_calls).to eq([pwd_call, whoami_call])
        expect(approval_call_index.size).to eq(approval_state["rows"])
        expect(call_for_row(1)).to eq(pwd_call)
        expect(call_for_row(2)).to eq(whoami_call)

        Timeout.timeout(20) { settled.pop }
        raise "the approval consumer thread never stopped" unless worker.join(20)
      end
    end
  end

  # THE REACHABILITY HALF, and the one this chunk keeps failing: every example
  # above binds the approval view the way {Lain::CLI::Repl} binds it, which
  # proves the round trip and NOT that anything in production performs that
  # bind. Two earlier rounds both found capabilities whose every collaborator
  # had a green spec and which no code path ever constructed.
  #
  # So this one drives the REAL {Lain::CLI::Repl} -- it builds the frontend, it
  # binds the view to both halves, and its own #respond spawns the watch fiber
  # -- against a REAL editor, and gates a REAL call inside the ask. Nothing
  # here reaches into the repl to wire anything.
  describe "the repl's own wiring puts a parked approval in front of the human" do
    let(:journal_io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io: journal_io) }
    let(:conductor) { instance_double(Lain::CLI::Conductor, closed?: false, counting_down?: false, take_held: nil) }
    let(:agent) { instance_double(Lain::Agent, timeline: nil) }
    # `dispatch` YIELDS: a registry that swallowed the line would skip the model
    # turn. `serves_replies?` is the second half of the command surface's duck:
    # the Repl asks whether the LINE is itself a reply surface before it
    # brackets it in the human's answer and approval surfaces.
    let(:commands) do
      Struct.new(:none) do
        def dispatch(_text) = yield
        def serves_replies?(_text) = false
      end.new(nil)
    end

    # The chat's command> reads, and nobody types there either.
    before { allow(conductor).to receive(:read_command) { Async::Task.current.sleep(60) } }

    it "renders it in lain://approval and answers it with y, with nobody having wired the view by hand" do
      queue = Lain::Approval::Queue.new(journal:, timeout: 60)
      settled = Thread::Queue.new
      allow(agent).to receive(:ask) do
        settled.push(queue.call(ApprovalSeamSupport::Effect.new("bash", { "command" => "pwd" }, "tu_1"), nil))
        nil
      end
      allow(conductor).to receive(:supervise) { |_task, _head, &turn| Struct.new(:response).new(turn.call) }
      allow(conductor).to receive(:read_prompt).and_return("go", "quit")
      # The human is not at the terminal, which is the whole situation the card
      # describes: whatever the chat reads, nobody types, so the ONLY thing that
      # can settle this call is the editor.
      allow(conductor).to receive(:read_reply) { Async::Task.current.sleep(60) }
      presser = Thread.new do
        wait_until_editor(timeout: 20) { buffer_lines("lain://approval").join.include?("pwd") }
        press("lain://approval", "y", cursor: [1, 0])
      end

      Timeout.timeout(30) { repl_over(queue).run(**repl_session) }

      expect(presser.join(5)).to be_truthy
      expect(Timeout.timeout(10) { settled.pop }).to be(true)
      expect(decisions.last).to include("surface" => Lain::Frontend::Neovim::ApprovalView::SURFACE,
                                        "verdict" => "approve")
    end

    # QA round 8's finding, and the REACHABILITY half of it. The terminal was
    # the casualty then: having taken the first arrival it stayed inside a read
    # no human would answer, so the second gated call of the turn was never put
    # in front of the human at all.
    #
    # In a cockpit the terminal asks NOTHING -- lain://approval is where the
    # human answers, and a `[y/N]` in the chat beside it is a reader for
    # typeahead to land in. What survives of the finding is its reachability
    # claim, through the real {Lain::CLI::Repl}: the chat still TELLS the human
    # about the second call once the editor has answered the first, and opens a
    # y/N read for neither. The reader records before it parks, so a y/N read
    # that opened is seen even though nobody answers it.
    it "announces the second gated call too, once the editor answered the first, and asks y/N about neither" do
      queue = Lain::Approval::Queue.new(journal:, timeout: 60)
      settled = Thread::Queue.new
      prompts = []
      chat = StringIO.new
      allow(agent).to receive(:ask) do
        %w[pwd whoami].each_with_index do |command, index|
          settled.push(queue.call(ApprovalSeamSupport::Effect.new("bash", { "command" => command },
                                                                  "tu_#{index + 1}"), nil))
        end
        nil
      end
      allow(conductor).to receive(:supervise) { |_task, _head, &turn| Struct.new(:response).new(turn.call) }
      allow(conductor).to receive(:read_prompt).and_return("go", "quit")
      allow(conductor).to receive(:read_reply) do |_tty, prompt|
        prompts << prompt
        Async::Task.current.sleep(60)
      end
      presser = Thread.new do
        approve_in_editor("pwd")
        approve_in_editor("whoami", after: "pwd")
      end

      Dir.mktmpdir do |dir|
        Timeout.timeout(45) { repl_over(queue, tty: chat_tty(chat, dir)).run(**repl_session) }
      end

      expect(presser.join(5)).to be_truthy
      expect(Timeout.timeout(10) { [settled.pop, settled.pop] }).to eq([true, true])
      expect(prompts.grep(%r{\[y/N\]})).to be_empty
      expect(chat.string.lines.grep(%r{lain://approval}).join).to include("pwd").and include("whoami")
    end

    def chat_tty(output, dir)
      Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new,
                              history_path: File.join(dir, "history"))
    end

    # Wait for the row to be the one on screen, then press y on it. `after:` is
    # the row the PREVIOUS press retired: pressing before it leaves the buffer
    # would land the keystroke on the call that was already approved, and the
    # example would hang rather than fail.
    def approve_in_editor(command, after: nil)
      wait_until_editor(timeout: 20) do
        text = buffer_lines("lain://approval").join
        text.include?(command) && !(after && text.include?(after))
      end
      press("lain://approval", "y", cursor: [1, 0])
    end

    # The REAL HumanReplies, undelegated: repl_spec wraps it in a double that
    # no-ops `bind_editor` precisely so its own examples keep the rail they set,
    # and that is the wiring under test here.
    def repl_over(approvals, tty: null_tty)
      replies = Lain::CLI::HumanReplies.new(tty:, conductor:, questions: Async::Queue.new,
                                            ask_human: Lain::Tools::AskHuman::Directory.new)
      Lain::CLI::Repl.new(agent:, tty:, replies:, commands:, approvals:, conductor:,
                          chronicle: Lain::CLI::Chronicle::Null.new)
    end

    def repl_session
      { nvim: { channel:, socket_path: @socket }, store: Lain::Store.new,
        session: Lain::Session::Null.instance }
    end
  end

  def decisions = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a

  def approval_state
    inspector.exec_lua(<<~LUA, %w[buftype filetype modifiable])
      local buf, out = vim.fn.bufnr("lain://approval"), {}
      if buf == -1 then return nil end
      for _, option in ipairs({ ... }) do out[option] = vim.bo[buf][option] end
      out.lain_view = vim.b[buf].lain_view
      out.generation = vim.b[buf].lain_view_generation
      out.rows = vim.b[buf].lain_approval_rows
      out.windows = #vim.fn.win_findbuf(buf)
      return out
    LUA
  end

  # The unwrapped call per PARKED CALL, beside {#approval_state}'s row count
  # for the same reason 62_approval.lua's own comment gives: joining rendered
  # lines embeds INDENT mid-token, so a reader wanting the command back reads
  # this variable rather than the buffer's own text. One entry per call, not
  # per row -- {#approval_call_index} is what resolves a row to its member.
  def approval_calls
    inspector.exec_lua("return vim.b[vim.fn.bufnr('lain://approval')].lain_approval_calls", [])
  end

  def approval_call_index
    inspector.exec_lua("return vim.b[vim.fn.bufnr('lain://approval')].lain_approval_call_index", [])
  end

  # The lua consumer's OWN resolution, `calls[call_index[row]]`, both
  # 1-based as nvim stores them -- read this way rather than indexed by hand
  # on the Ruby side, so the example proves what a real reader does, not an
  # arithmetic restatement of it.
  def call_for_row(row)
    inspector.exec_lua(<<~LUA, [row])
      local buf = vim.fn.bufnr("lain://approval")
      local index = vim.b[buf].lain_approval_call_index[...]
      return vim.b[buf].lain_approval_calls[index]
    LUA
  end

  # The approval round trip's own consumer thread, and it is a THREAD for the
  # reason `with_consumer` records at length: a gem call issued from inside an
  # Async task takes the neovim gem's fiber-yielding branch and raises
  # FiberError, which is swallowed and retried forever. The inspector stays on
  # the main thread; everything reactor-shaped stays here.
  #
  # Bounded on BOTH ends and by a stop channel rather than by the queue's
  # clock: a fail-closed denial would answer `false`, which is also what a
  # working deny answers, so a hung run must be distinguishable from a decided
  # one. `:unsettled` is that third answer.
  def with_parked_approval(frontend, input: { "command" => "pwd" }, grace: 8)
    settled = Thread::Queue.new
    worker = Thread.new { serve_approval(frontend, ApprovalSeamSupport::Effect.new("bash", input, "tu_1"), settled, grace) }
    yield
    Timeout.timeout(20) { settled.pop }
  ensure
    raise "the approval consumer thread never stopped" unless worker&.join(20)
  end

  # `grace` is how long the gated fiber is given to settle before this answers
  # `:unsettled`, and the two directions want different numbers: a real gesture
  # crosses this in about fifty milliseconds, so 8s is slack against a loaded
  # box, while an example asserting that NOTHING answers would otherwise pay
  # that slack in full. The queue's own clock is set far beyond both, so a
  # fail-closed denial can never stand in for a deny the human pressed.
  def serve_approval(frontend, effect, settled, grace)
    Sync do |task|
      queue = Lain::Approval::Queue.new(journal:, timeout: 60)
      surfaces = approval_surfaces(task, frontend, queue)
      gated = task.async { queue.call(effect, nil) }
      settled.push(within(task, grace) { gated.finished? } ? gated.wait : :unsettled)
      (surfaces + [gated]).each(&:stop)
    end
  end

  # {#serve_approval}'s shape, widened to the pair {#parked_pair} admits.
  def two_parked_approvals(frontend, settled)
    Sync do |task|
      queue = Lain::Approval::Queue.new(journal:, timeout: 60)
      surfaces = approval_surfaces(task, frontend, queue)
      gated = parked_pair(task, queue)
      settled.push(within(task, 0.1) { gated.all?(&:finished?) } ? gated.map(&:wait) : :unsettled)
      (surfaces + gated).each(&:stop)
    end
  end

  # Two independent gated fibers admitted to the SAME queue without either
  # awaiting the other -- what "two parked approvals" needs, and what the
  # sequential loop in the repl seam above deliberately does not give (only
  # one pending is ever parked there at a time).
  def parked_pair(task, queue)
    %w[pwd whoami].each_with_index.map do |command, index|
      effect = ApprovalSeamSupport::Effect.new("bash", { "command" => command }, "tu_#{index + 1}")
      task.async { queue.call(effect, nil) }
    end
  end

  # Whether the condition held before the window ran out. Deliberately NOT
  # `pumped_until`, which raises at its deadline: running out the clock is a
  # legitimate outcome here and it is the one `:unsettled` reports.
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
end
