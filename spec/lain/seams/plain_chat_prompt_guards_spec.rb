# frozen_string_literal: true

require "fileutils"
require "io/console"
require "pty"
require "rbconfig"

# A plain chat -- no editor -- keeps its inline `human>` and `[y/N]` reads, and
# the only terminal they share is a real one. Between reads it is cooked with
# echo on, so whatever the human typed while a turn dispatched is sitting in the
# kernel when the next raw reader opens, and that reader used to take it as the
# answer: a line typed as a prompt became a human's denial nineteen milliseconds
# after the `[y/N]` appeared, and the prompt itself was lost.
#
# Driven over a PTY in a CHILD process, because Reline picks its terminal gate
# once, at load, from the process's own stdin: a spec process whose stdin is a
# pipe measures a line editor no human ever meets.
module PlainChatPromptGuards
  LIB = File.expand_path("../../../lib", __dir__)
  APPROVAL = %r{\[y/N\] }

  # The chat under test: a real Conductor, TTY, HumanReplies, approval surfaces
  # and Approval::Queue. The one fake is the command registry's fallthrough,
  # which claims every line so no model is involved: the first line parks one
  # gated call once the spec says the human has finished typing ahead.
  #
  # `plain` runs a real Repl with no editor, its first line already given;
  # `idle` is the same chat opening at `you>`, and `human`'s first line asks a
  # subagent's question at `human>` instead. `cockpit` binds an attached editor
  # that answers nothing and runs one dispatched line, so the chat's only read
  # is `command>`, with the real `/approve` registered behind it.
  CHILD = <<~'RUBY'
    require "lain"

    dir = ARGV.fetch(0)
    window = Float(ARGV.fetch(1))
    shape = ARGV.fetch(2)
    journal_io = File.open(File.join(dir, "journal.ndjson"), "a").tap { |io| io.sync = true }
    queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: journal_io), timeout: window)
    tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, pastel: Pastel.new(enabled: false),
                                  history_path: File.join(dir, "history"), state_path: File.join(dir, "state.json"))
    conductor = Lain::CLI::Conductor.new(tty:, chronicle: Lain::CLI::Chronicle::Null.new,
                                         signals: Lain::CLI::Signals.new, grace: 5)
    askers = Lain::CLI::Wiring::Askers.new(observer: Lain::Event::ChainWriter::Null.new)
    replies = Lain::CLI::HumanReplies.new(tty:, conductor:, ask_human: askers.directory, questions: askers.questions)

    commands = Class.new do
      def initialize(queue, dir, askers)
        @queue = queue
        @dir = dir
        @askers = askers
      end

      def serves_replies?(_text) = false

      def dispatch(text)
        File.write(File.join(@dir, "dispatched"), "#{text}\n", mode: "a")
        return unless ["run the tests", "ask me"].include?(text)

        $stdout.write("DISPATCHING\n")
        Async::Task.current.sleep(0.02) until File.exist?(File.join(@dir, "typed"))
        text == "ask me" ? ask : park
        $stdout.write("SETTLED\n")
        nil
      end

      def park
        @queue.call(Lain::Effect::ToolCall.new(tool_use_id: "call_1", name: "bash",
                                               input: { "command" => "rm -rf build" }), nil)
      end

      def ask
        chain = Lain::Timeline.empty(store: Lain::Store.new)
                              .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
        result = @askers.enrol(chain).asker.call({ "question" => "which db?" },
                                                 Lain::Tool::Invocation.new(context: Lain::Session::Null.instance))
        File.write(File.join(@dir, "answer"), result.content.to_s)
      end
    end.new(queue, dir, askers)

    if shape != "cockpit"
      Sync do
        Lain::CLI::Repl.new(agent: Struct.new(:timeline).new(nil), tty:, replies:, commands:,
                            chronicle: Lain::CLI::Chronicle::Null.new, conductor:, approvals: queue)
                       .converse(first_prompt: { "plain" => "run the tests", "human" => "ask me" }[shape])
      end
    else
      editor = Class.new do
        def pop(*) = nil
        def review_refused(_message) = nil
        def attached? = true
        def watch(_queue) = Async::Task.current.sleep
      end.new
      surfaces = Lain::CLI::Repl::ApprovalSurfaces.new(approvals: queue, auto_surface: nil, secret_surface: nil,
                                                       tty:, conductor:)
      surfaces.bind_editor(editor)
      replies.bind_editor(editor)
      approve = Lain::CLI::Command::Approve.new(
        prompt: Lain::Frontend::ApprovalPolicy.new(reader: ->(question) { conductor.read_reply(tty, question) })
      )
      replies.bind_commands(Lain::CLI::Command::Registry.new([approve, Lain::CLI::Command::Inbox.new])
                                                        .bind(Struct.new(:approvals, :replies).new(queue, replies)))
      Sync { Lain::CLI::Repl::LineScope.new(replies:, surfaces:).serve { commands.dispatch("run the tests") } }
    end
  RUBY

  # The far end of the PTY: what the human types, and everything the chat drew.
  # `answers_cursor: false` is a terminal that never replies to Reline's
  # cursor-position query, which Reline waits out for half a second.
  class Terminal
    CURSOR_QUERY = "\e[6n"
    CURSOR_REPORT = "\e[1;1R"

    def initialize(dir, window:, shape:, term: "xterm", answers_cursor: true)
      @dir = dir
      @screen = +""
      @lock = Mutex.new
      @answers_cursor = answers_cursor
      @during_query = nil
      env = { "TERM" => term, "INPUTRC" => File.join(dir, "no-inputrc") }
      @output, @input, @pid = PTY.spawn(env, RbConfig.ruby, "-I", LIB, "-e", CHILD, dir, window.to_s, shape)
      @output.winsize = [40, 200]
      @pump = Thread.new { pump }
    end

    def screen = @lock.synchronize { @screen.dup }

    def type(bytes) = @input.write(bytes)

    # Bytes that reach the chat while the NEXT cursor-position query waits for
    # its reply: typed after the read opened, before its prompt drew.
    def type_during_next_query(bytes) = @lock.synchronize { @during_query = bytes }

    def answer
      path = File.join(@dir, "answer")
      File.exist?(path) ? File.read(path) : nil
    end

    # The human has finished typing ahead; the dispatching line may park its call.
    def typed = FileUtils.touch(File.join(@dir, "typed"))

    def await(pattern, timeout: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep(0.02) until screen.match?(pattern) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      raise "#{pattern.inspect} never drew; the screen was:\n#{screen}" unless screen.match?(pattern)
    end

    def verdicts
      path = File.join(@dir, "journal.ndjson")
      return [] unless File.exist?(path)

      Lain::Journal.records(File.readlines(path), type: "approval_decision").map do |record|
        record.values_at("surface", "verdict")
      end.to_a
    end

    def dispatched
      path = File.join(@dir, "dispatched")
      File.exist?(path) ? File.readlines(path, chomp: true) : []
    end

    def close
      Process.kill("KILL", @pid)
      Process.wait(@pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      @pump.join(2)
      [@input, @output].each { |io| io.close unless io.closed? }
    end

    private

    # A real terminal answers Reline's cursor-position query; left unanswered,
    # every read waits out Reline's half-second timeout first.
    def pump
      loop do
        chunk = @output.readpartial(4096)
        @lock.synchronize { @screen << chunk }
        queried(chunk) if chunk.include?(CURSOR_QUERY)
      end
    rescue IOError, Errno::EIO
      nil
    end

    def queried(_chunk)
      typed = @lock.synchronize { @during_query.tap { @during_query = nil } }
      @input.write(typed) if typed
      @input.write(CURSOR_REPORT) if @answers_cursor
    end
  end
end

RSpec.describe "a plain chat's inline prompts", :seam do
  describe "over a real terminal" do
    around do |example|
      Dir.mktmpdir do |dir|
        @terminal = PlainChatPromptGuards::Terminal.new(dir, window:, shape:, term:, answers_cursor:)
        example.run
      ensure
        @terminal&.close
      end
    end

    let(:window) { 30 }
    let(:shape) { "plain" }
    let(:term) { "xterm" }
    let(:answers_cursor) { true }
    let(:terminal) { @terminal }

    # Typed ahead on a terminal whose prompt the spec cannot wait for by sight.
    def typed_ahead_unseen(bytes)
      terminal.await(/DISPATCHING/)
      terminal.type(bytes)
      sleep(0.2)
      terminal.typed
      sleep(1.5)
    end

    # Type ahead while the first line dispatches, then let it park its call.
    def typed_ahead(bytes)
      terminal.await(/DISPATCHING/)
      terminal.type(bytes)
      sleep(0.2) # the bytes reach the kernel's buffer, echoed, before the call parks
      terminal.typed
      terminal.await(PlainChatPromptGuards::APPROVAL)
    end

    describe "a line typed during dispatch" do
      it "does not answer the next approval, and is dispatched as the next prompt once the line settles" do
        typed_ahead("yes please\r")
        sleep(0.5)

        expect(terminal.verdicts).to be_empty # the prompt opened empty and waits
        expect(terminal.screen).to include("held as your next prompt: yes please")

        terminal.type("n\r")
        terminal.await(/SETTLED/)
        terminal.await(/you> /)

        expect(terminal.verdicts).to eq([%w[tty deny]])
        expect(terminal.dispatched).to eq(["run the tests", "yes please"])
      end
    end

    describe "a partial line typed before a prompt" do
      it "is not an answer, and is said to be discarded" do
        typed_ahead("y")
        sleep(0.5)

        expect(terminal.verdicts).to be_empty
        expect(terminal.screen).to include("discarded: y")
      end
    end

    # A line whose typing SPANS the moment the `[y/N]` opens: its start was
    # typed ahead, its end at the prompt. The end is not an answer either --
    # judged alone, "Say " + "yes" approved `rm -rf build` -- so the line the
    # prompt reads first is joined to the start, held whole, and the prompt
    # opens again empty.
    describe "a line typed across the moment the prompt opens" do
      def split_line_answered_by(verdict)
        expect(terminal.verdicts).to be_empty
        expect(terminal.screen).to include("held as your next prompt: Say yes")

        terminal.type("#{verdict}\r")
        terminal.await(/SETTLED/)
        terminal.await(/you> /)
      end

      it "holds the whole line and asks again, when its end is typed after the prompt drew" do
        typed_ahead("Say ")
        terminal.type("yes\r")
        sleep(0.5)

        split_line_answered_by("n")

        expect(terminal.verdicts).to eq([%w[tty deny]])
        expect(terminal.dispatched).to eq(["run the tests", "Say yes"])
      end

      it "holds the whole line and asks again, when its end is typed at a human's pace, unseen" do
        terminal.await(/DISPATCHING/)
        terminal.type("Say ")
        sleep(0.2)
        terminal.typed
        sleep(0.04)
        terminal.type("yes\r")
        terminal.await(PlainChatPromptGuards::APPROVAL)
        sleep(0.5)

        split_line_answered_by("n")

        expect(terminal.verdicts).to eq([%w[tty deny]])
        expect(terminal.dispatched).to eq(["run the tests", "Say yes"])
      end
    end

    # Lines typed before `you>` even drew. Reline asks the terminal where its
    # cursor is as a read opens, and keeps every other byte it read meanwhile
    # for its next read -- so the second line never reached the kernel's buffer
    # again, and a drain of the kernel alone let it answer the `[y/N]`.
    describe "two lines typed before the prompt that reads the first" do
      let(:shape) { "idle" }

      it "holds the second rather than letting it answer the approval the first one parks" do
        terminal.typed
        terminal.type("run the tests\ryes\r")
        terminal.await(PlainChatPromptGuards::APPROVAL)
        sleep(0.5)

        expect(terminal.verdicts).to be_empty
        expect(terminal.screen).to include("held as your next prompt: yes")

        terminal.type("n\r")
        terminal.await(/SETTLED/)

        expect(terminal.verdicts).to eq([%w[tty deny]])
      end
    end

    # Reline asks the terminal where its cursor is as a read opens, before its
    # prompt draws, and keeps what else it read for that read: a line whose
    # first byte lands in that window was typed before the prompt appeared.
    describe "a line typed while the prompt's read waits on the cursor query" do
      it "does not answer the [y/N]" do
        terminal.await(/DISPATCHING/)
        sleep(0.1)
        terminal.type_during_next_query("yes\r")
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)
        sleep(0.5)

        expect(terminal.verdicts).to be_empty
        expect(terminal.screen).to include("held as your next prompt: yes")
      end

      context "with a terminal that never answers the query" do
        let(:answers_cursor) { false }

        it "does not answer the [y/N] with a yes typed while the read waited it out" do
          terminal.await(/DISPATCHING/)
          sleep(0.1)
          terminal.typed
          sleep(0.1)
          terminal.type("yes\r")
          terminal.await(PlainChatPromptGuards::APPROVAL)
          sleep(1.0)

          expect(terminal.verdicts).to be_empty
        end
      end

      context "when the prompt is a human> question" do
        let(:shape) { "human" }

        it "does not answer the question, which the line typed at human> then does" do
          terminal.await(/DISPATCHING/)
          sleep(0.1)
          terminal.type_during_next_query("postgres\r")
          terminal.typed
          terminal.await(/human> /)
          sleep(0.8)

          expect(terminal.answer).to be_nil
          expect(terminal.screen).to include("held as your next prompt: postgres")

          terminal.type("mysql\r")
          terminal.await(/SETTLED/)

          expect(terminal.answer).to include("mysql")
          expect(terminal.answer).not_to include("postgres")
        end
      end

      context "when the prompt is the [y/N] a cockpit's /approve asks" do
        let(:shape) { "cockpit" }

        it "does not answer it" do
          terminal.await(/DISPATCHING/)
          terminal.typed
          terminal.await(/command> /)
          sleep(0.3)
          terminal.type_during_next_query("yes\r")
          terminal.type("/approve\r")
          sleep(1.5)

          expect(terminal.verdicts).to be_empty
          expect(terminal.screen).to include("held as your next prompt: yes")
        end
      end
    end

    # TERM=dumb gives Reline a gate that reads the terminal cooked and keeps no
    # bytes back, and it still reads the one stdin the chat's typeahead waits on.
    context "with a dumb terminal" do
      let(:term) { "dumb" }

      it "does not let a yes typed during dispatch approve" do
        typed_ahead_unseen("yes\r")

        expect(terminal.verdicts).to be_empty
        expect(terminal.screen).to include("held as your next prompt: yes")
      end

      it "holds a prompt typed during dispatch, rather than taking it as a denial" do
        typed_ahead_unseen("yes please\r")

        expect(terminal.verdicts).to be_empty
        expect(terminal.screen).to include("held as your next prompt: yes please")
      end
    end

    # A key sequence typed ahead -- an arrow -- is not the start of a line, so
    # the human's first real answer is not joined to it and held.
    describe "an arrow key typed before a prompt" do
      it "is dropped, so the first n typed at the prompt answers it" do
        typed_ahead("\e[A")
        sleep(0.3)
        terminal.type("n\r")
        terminal.await(/SETTLED/)

        expect(terminal.verdicts).to eq([%w[tty deny]])
        expect(terminal.screen).not_to include("held as your next prompt")
      end
    end

    describe "a prompt the approval window decides" do
      let(:window) { 1.5 }

      it "ends its line with who decided it and how, and a y typed afterwards decides nothing" do
        typed_ahead("")
        terminal.await(/decided by timeout: denied/)
        terminal.await(/you> /)

        terminal.type("y\r")
        sleep(0.5)

        prompt_line = terminal.screen.lines.grep(PlainChatPromptGuards::APPROVAL).last
        expect(prompt_line).to include("-- decided by timeout: denied")
        expect(terminal.verdicts).to eq([%w[timeout deny]])
        expect(terminal.dispatched).to eq(["run the tests", "y"])
      end
    end

    # `command>` answers nothing, so a command typed a moment before the call
    # parked is read there as typed -- it is what the human reached for -- and
    # the `[y/N]` that command asks drains for itself.
    describe "a cockpit's command> over typeahead" do
      let(:shape) { "cockpit" }

      it "runs a /approve typed just before the call parked, once it has" do
        typed_ahead("/approve\r")
        terminal.type("y\r")
        terminal.await(/SETTLED/)

        expect(terminal.verdicts).to eq([%w[tty approve]])
        expect(terminal.screen).not_to include("held as your next prompt: /approve")
      end

      it "still drains ahead of the [y/N] that /approve asks" do
        typed_ahead("/approve\rnot an answer\r")
        sleep(0.5)

        expect(terminal.verdicts).to be_empty
        expect(terminal.screen).to include("held as your next prompt: not an answer")

        terminal.type("n\r")
        terminal.await(/SETTLED/)

        expect(terminal.verdicts).to eq([%w[tty deny]])
      end
    end
  end

  # A `[y/N]` still waiting on the one read lock -- a `human>` holds it -- when
  # the approval window decides its call never drew a prompt, so there is no
  # line to end: a sentence printed for it would land inside the read that is
  # open, naming no call.
  describe "a prompt decided while it still waited behind another read" do
    it "ends no line, because it drew none" do
      output = StringIO.new
      tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new("never read\n"),
                                    history_path: File::NULL, pastel: Pastel.new(enabled: false))
      journal_io = StringIO.new
      queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: journal_io), timeout: 0.3)
      policy = Lain::Frontend::ApprovalPolicy.new(output: StringIO.new,
                                                  reader: ->(prompt) { tty.prompt_afresh(prompt) })

      Sync do |task|
        human = task.async { Lain::Frontend::LineEditor.exclusively { task.sleep(1.0) } }
        watcher = task.async { policy.watch(queue) }
        call = Lain::Effect::ToolCall.new(tool_use_id: "call_1", name: "bash", input: { "command" => "rm -rf build" })
        task.async { queue.call(call, nil) }.wait
        settle_for(task, 0.05)
        watcher.stop
        human.wait
      end

      expect(output.string).not_to include("decided by")
      expect(Lain::Journal.records(journal_io.string.lines, type: "approval_decision").map { |r| r["surface"] }.to_a)
        .to eq(["timeout"])
    end
  end
end
