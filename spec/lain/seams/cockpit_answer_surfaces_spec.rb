# frozen_string_literal: true

require "async"
require "stringio"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module CockpitAnswerSurfacesSupport
  # The minimal effect a parked {Lain::Approval::Queue::Pending} reads.
  Effect = Struct.new(:name, :input, :tool_use_id)

  # The editor's command rail, attached: {Lain::Frontend::Neovim::CommandInbox}'s
  # duck. Nothing is pushed onto it here -- what makes a chat a cockpit is that
  # it answers `attached?` true.
  class Rail
    def initialize = @commands = Thread::Queue.new
    def pop(...) = @commands.pop(...)
    def review_refused(_message) = nil
    def attached? = true
  end

  # The nvim end of lain://approval: takes every rendering, and remembers the
  # stamp the last one went out with, which is what a keypress in that buffer
  # carries back.
  class ApprovalRpc
    attr_reader :generation

    def set_approval(_lines, generation, _rows, _calls, _call_index)
      @generation = generation
      nil
    end
  end

  # The one terminal, as the conductor's `read_reply` reaches it. Answers are
  # scripted per KIND of prompt; a prompt with nothing left to answer PARKS, which
  # is the honest shape of a human who is not typing. Every read is counted while
  # it is open, so two readers overlapping on one stdin are caught rather than
  # inferred from what was printed.
  class Terminal
    PARKED = 60

    attr_reader :prompts, :peak, :in_flight

    def initialize(command: [], approval: [])
      @answers = { command: command.dup, approval: approval.dup }
      @prompts = []
      @in_flight = 0
      @peak = 0
    end

    def read_reply(_tty, prompt)
      @prompts << prompt
      @in_flight += 1
      @peak = [@peak, @in_flight].max
      Async::Task.current.sleep(0.02) # the human is typing
      answer(prompt)
    ensure
      @in_flight -= 1
    end

    def approval_prompts = @prompts.grep(%r{\[y/N\]})

    # What the human types from here on at a command prompt.
    def type(*lines) = @answers.fetch(:command).concat(lines)

    private

    def answer(prompt)
      queued = @answers.fetch(prompt.include?("[y/N]") ? :approval : :command)
      queued.empty? ? Async::Task.current.sleep(PARKED) : queued.shift
    end
  end
end

# THE HUMAN'S RULING, nvim-first: with an editor attached the chat pane opens no
# reader whose line can become an answer. A parked call and a parked question are
# each ONE line in the chat, naming where they are answered, and the only thing
# the chat still reads while a line dispatches is a command -- so `/approve` can
# still reach a call the dispatching line itself is parked on, while a line of
# prose typed there waits for `you>` instead of landing as a verdict.
#
# Real {Lain::CLI::HumanReplies}, {Lain::CLI::Repl::ApprovalSurfaces} and
# {Lain::CLI::Repl::LineScope} over a real {Lain::Approval::Queue}, the real
# command registry with the real `/approve` and `/inbox`, and the real
# {Lain::Frontend::Neovim::ApprovalView} deciding the call. The editor's far end
# and the keyboard are the only stand-ins.
RSpec.describe "cockpit answer surfaces", :seam do
  let(:output) { StringIO.new }
  let(:tty) do
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new,
                            history_path: File.join(@dir, "history"))
  end
  let(:journal_io) { StringIO.new }
  let(:queue) { Lain::Approval::Queue.new(journal: Lain::Journal.new(io: journal_io), timeout: 20) }
  let(:rpc) { CockpitAnswerSurfacesSupport::ApprovalRpc.new }
  let(:view) { Lain::Frontend::Neovim::ApprovalView.new(rpc:, poll_interval: 0.01) }
  let(:askers) { Lain::CLI::Wiring::Askers.new(observer: Lain::Event::ChainWriter::Null.new) }
  let(:asker) do
    askers.enrol(Lain::Timeline.empty(store: Lain::Store.new)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])).asker
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def effect(command = "pwd") = CockpitAnswerSurfacesSupport::Effect.new("bash", { "command" => command }, "tu_1")

  def decisions = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a

  def lines_of(text) = output.string.lines.grep(text)

  # The whole chat a line is dispatched in: the reply surfaces, the approval
  # watchers, and the command registry both of them answer through.
  def cockpit(terminal, editor: true)
    replies = Lain::CLI::HumanReplies.new(tty:, conductor: terminal, ask_human: askers.directory,
                                          questions: askers.questions)
    surfaces = Lain::CLI::Repl::ApprovalSurfaces.new(approvals: queue, auto_surface: nil, secret_surface: nil,
                                                     tty:, conductor: terminal)
    attach(replies, surfaces) if editor
    registry = commands_over(replies, terminal)
    replies.bind_commands(registry)
    [Lain::CLI::Repl::LineScope.new(replies:, surfaces:), replies, registry]
  end

  def attach(replies, surfaces)
    replies.bind_editor(CockpitAnswerSurfacesSupport::Rail.new, approvals: view)
    surfaces.bind_editor(view)
  end

  def commands_over(replies, terminal)
    prompt = Lain::Frontend::ApprovalPolicy.new(reader: ->(question) { terminal.read_reply(tty, question) })
    Lain::CLI::Command::Registry.new([Lain::CLI::Command::Approve.new(prompt:), Lain::CLI::Command::Inbox.new])
                                .bind(build_command_env(replies:, approvals: queue))
  end

  # `:LainApprove` on the first row of lain://approval, once the chat has told
  # the human where to look and a rendering of the parked call has reached the
  # editor -- a human who pressed it sooner would be pressing on nothing.
  def approve_in_editor(task)
    pumped_until(task, reason: "the chat announced the parked call") { lines_of(%r{lain://approval}).any? }
    pumped_until(task, reason: "the parked call was drawn in lain://approval") do
      rpc.generation && queue.any? { |pending| !pending.decided? }
    end
    view.decide(1, "approve", generation: rpc.generation)
  end

  def held_note?(text) = output.string.include?("held as your next prompt: #{text}")

  describe "a cockpit chat does not read an approval inline" do
    it "prints one line naming the call and lain://approval, opens no y/N read, and nvim decides it" do
      terminal = CockpitAnswerSurfacesSupport::Terminal.new
      scope, = cockpit(terminal)

      verdict = Sync do |task|
        task.async { approve_in_editor(task) }
        Timeout.timeout(10) { scope.serve { queue.call(effect, nil) } }
      end

      expect(verdict).to be(true)
      expect(lines_of(%r{lain://approval})).to contain_exactly(a_string_including("bash", "pwd", "/approve"))
      expect(terminal.approval_prompts).to be_empty
      expect(decisions.map { |decision| decision.fetch("surface") }).to eq([Lain::Frontend::Neovim::ApprovalView::SURFACE])
    end
  end

  describe "a cockpit chat does not read a question inline" do
    it "prints one line naming the inbox, and holds the next typed line as a prompt rather than answering" do
      terminal = CockpitAnswerSurfacesSupport::Terminal.new(command: ["run the tests"])
      scope, replies = cockpit(terminal)

      Sync do |task|
        Timeout.timeout(10) do
          scope.serve do
            asker.ask("which branch?")
            pumped_until(task, reason: "the typed line was held") { held_note?("run the tests") }
          end
        end
      end

      expect(lines_of(/which branch\?/)).to contain_exactly(a_string_including(Lain::Frontend::TTY::Inbox::POINTER))
      expect(terminal.prompts).not_to include("human> ")
      expect(asker.pending?).to be(true)
      expect(replies.take_held).to eq("run the tests")
    end
  end

  describe "/approve in a cockpit owns the terminal for its line" do
    it "approves an actor's parked call at the tty surface with no other terminal reader open" do
      terminal = CockpitAnswerSurfacesSupport::Terminal.new(approval: ["y"])
      scope, _replies, registry = cockpit(terminal)

      verdict = Sync do |task|
        gated = task.async { queue.call(effect, nil) }
        pumped_until(task, reason: "the actor's call parked") { queue.any? }
        Timeout.timeout(10) do
          scope.serve(owns_terminal: registry.serves_replies?("/approve")) { registry.dispatch("/approve") { nil } }
        end
        gated.wait
      end

      expect(verdict).to be(true)
      expect(decisions.last.fetch("surface")).to eq(Lain::Frontend::ApprovalPolicy::SURFACE)
      expect(terminal.peak).to eq(1)
      expect(terminal.prompts.size).to eq(1)
    end
  end

  describe "/approve reaches the main agent's own parked call" do
    it "approves the call the dispatching line is parked on, and the line continues" do
      terminal = CockpitAnswerSurfacesSupport::Terminal.new(command: ["/approve"], approval: ["y"])
      scope, = cockpit(terminal)

      continued = Sync do
        Timeout.timeout(10) { scope.serve { "continued after #{queue.call(effect, nil)}" } }
      end

      expect(continued).to eq("continued after true")
      expect(output.string).to include("bash: approved")
      expect(decisions.last.fetch("surface")).to eq(Lain::Frontend::ApprovalPolicy::SURFACE)
      expect(terminal.peak).to eq(1)
    end
  end

  describe "a line typed while a turn dispatches is never an answer in a cockpit" do
    it "journals no tty decision, shows the line held, and hands it to you> once the line settles" do
      terminal = CockpitAnswerSurfacesSupport::Terminal.new(command: ["yes please"])
      scope, replies = cockpit(terminal)

      Sync do |task|
        task.async do
          pumped_until(task, reason: "the typed line was held") { held_note?("yes please") }
          approve_in_editor(task)
        end
        Timeout.timeout(10) { scope.serve { queue.call(effect, nil) } }
      end

      expect(decisions.map { |decision| decision.fetch("surface") }).not_to include(Lain::Frontend::ApprovalPolicy::SURFACE)
      expect(held_note?("yes please")).to be(true)
      expect(replies.take_held).to eq("yes please")
    end

    # The held line waits for the dispatching line to settle, so the one way it
    # could be lost is that line being torn down under it -- a Ctrl-C stops the
    # line's fibers. The slot outlives every line.
    it "keeps the held line when the dispatching line is stopped" do
      terminal = CockpitAnswerSurfacesSupport::Terminal.new(command: ["yes please"])
      scope, replies = cockpit(terminal)

      Sync do |task|
        line = task.async { scope.serve { queue.call(effect, nil) } }
        pumped_until(task, reason: "the typed line was held") { held_note?("yes please") }
        line.stop
      end

      expect(replies.take_held).to eq("yes please")
    end
  end

  # The reader is opened by what is OUTSTANDING, not by what arrived this line:
  # a line blocked on a call announced during an earlier one would otherwise
  # have no chat surface at all, which is exactly the state an editor that has
  # died leaves a cockpit in.
  describe "a line blocked on a call announced in an earlier line" do
    it "opens command> in the later line, and /approve decides the call before the window closes" do
      terminal = CockpitAnswerSurfacesSupport::Terminal.new(approval: ["y"])
      scope, = cockpit(terminal)

      verdict, elapsed = Sync do |task|
        actor = task.async { queue.call(effect("whoami"), nil) }
        scope.serve { pumped_until(task, reason: "the call was announced") { lines_of(%r{lain://approval}).any? } }
        terminal.type("/approve")
        started = Async::Clock.now
        [Timeout.timeout(10) { scope.serve { actor.wait } }, Async::Clock.now - started]
      end

      expect(verdict).to be(true)
      expect(decisions.last.fetch("surface")).to eq(Lain::Frontend::ApprovalPolicy::SURFACE)
      expect(elapsed).to be < 5
    end
  end

  # An open `command>` holds the terminal -- the conductor suppresses the
  # interrupt countdown for as long as a read is open -- so it is open only
  # while something is waiting on the human, and a closed one says so rather
  # than leaving a bare prompt on the row the next `you>` lands on.
  describe "command> outliving its reason" do
    it "closes the read once nvim decides the call it was opened for, while the line still dispatches" do
      terminal = CockpitAnswerSurfacesSupport::Terminal.new
      scope, = cockpit(terminal)

      open_after = Sync do |task|
        Timeout.timeout(10) do
          scope.serve do
            gated = task.async { queue.call(effect, nil) }
            pumped_until(task, reason: "command> opened") { terminal.in_flight.positive? }
            approve_in_editor(task)
            gated.wait
            pumped_until(task, reason: "command> closed") { terminal.in_flight.zero? }
            terminal.in_flight
          end
        end
      end

      expect(open_after).to eq(0)
      expect(output.string).to include(Lain::CLI::HumanReplies::CommandLine::CLOSED)
    end

    it "closes the read when the line ends, and says so" do
      terminal = CockpitAnswerSurfacesSupport::Terminal.new
      scope, = cockpit(terminal)

      Sync do |task|
        actor = task.async { queue.call(effect, nil) }
        scope.serve { pumped_until(task, reason: "command> opened") { terminal.in_flight.positive? } }
        actor.stop
      end

      expect(terminal.in_flight).to eq(0)
      expect(output.string.lines.last).to include(Lain::CLI::HumanReplies::CommandLine::CLOSED)
    end
  end

  describe "a plain chat keeps its inline prompts" do
    it "renders the [y/N] prompt for a parked call" do
      terminal = CockpitAnswerSurfacesSupport::Terminal.new(approval: ["n"])
      scope, = cockpit(terminal, editor: false)

      verdict = Sync { Timeout.timeout(10) { scope.serve { queue.call(effect, nil) } } }

      expect(verdict).to be(false)
      expect(terminal.approval_prompts).to contain_exactly(a_string_including("approve bash"))
      expect(decisions.last.fetch("surface")).to eq(Lain::Frontend::ApprovalPolicy::SURFACE)
    end
  end
end
