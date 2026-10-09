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

  # The chat under test: a real Repl, Conductor, TTY, Intake and the StdinPump
  # feeding it, HumanReplies, approval surfaces and Approval::Queue, all open for
  # the conversation. The one fake is the command registry's fallthrough, which
  # claims every line so no model is involved: the first line parks one gated
  # call once the spec says the human has finished typing ahead.
  #
  # `plain` runs with its first line already given; `idle` is the same chat
  # opening at `you>`, and `human`'s first line asks a subagent's question at
  # `human>` instead. `queued` asks that question and parks a call once
  # `human>` is drawn, and `supervised` asks it inside the conductor's
  # supervision, where a Ctrl-C opens the countdown. `actor` opens at `you>`
  # and a fleet actor -- adopted by a real {Lain::Supervisor}, as a subagent is,
  # so the chat's close reaps it -- parks a call once the spec says so, and
  # `actor2` parks two at once. A `/`-line in the plain shapes goes to the real `/approve` and
  # `/inbox`, and to nothing else. `cockpit` binds an
  # attached editor that answers nothing and dispatches one line, so the chat's
  # only read is `command>`, with the real `/approve` registered behind it.
  CHILD = <<~'RUBY'
    require "lain"

    # Booted ahead of the example that takes it, and told which chat to run once
    # an example claims it: see {WarmPool.parked}.
    dir, window_arg, shape, grace = ARGV
    window = Float(window_arg)
    journal_io = File.open(File.join(dir, "journal.ndjson"), "a").tap { |io| io.sync = true }
    queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: journal_io), timeout: window)
    tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, pastel: Pastel.new(enabled: false),
                                  input: Lain::Frontend::StdinPump.keys($stdin),
                                  history_path: File.join(dir, "history"), state_path: File.join(dir, "state.json"))
    rail = Lain::Frontend::Intake.new(screen: tty)
    supervisor = Lain::Supervisor.new
    # A real record only where a shape asserts one, so every other shape keeps
    # the Null it had and writes no file.
    chronicle = if shape == "supervised"
      session_io = File.open(File.join(dir, "session.ndjson"), "a").tap { |io| io.sync = true }
      Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: session_io))
                          .start(context: Lain::Context.new(model: "m", max_tokens: 64),
                                 toolset: Lain::Toolset.new([]))
    else
      Lain::CLI::Chronicle::Null.new
    end
    conductor = Lain::CLI::Conductor.new(tty:, chronicle:, supervisor:,
                                         signals: Lain::CLI::Signals.new, rail:,
                                         grace: Float(grace))
    pump = Lain::Frontend::StdinPump.new(rail:, screen: tty)
    askers = Lain::CLI::Wiring::Askers.new(observer: Lain::Event::ChainWriter::Null.new)
    replies = Lain::CLI::HumanReplies.new(tty:, conductor:, ask_human: askers.directory, questions: askers.questions)
    typed = File.join(dir, "typed")
    waiting = -> { Async::Task.current.sleep(0.02) until File.exist?(typed) }

    approve = Lain::CLI::Command::Approve.new(
      prompt: Lain::Frontend::ApprovalPolicy.new(reader: ->(question) { conductor.read_reply(question) })
    )
    registry = Lain::CLI::Command::Registry.new([approve, Lain::CLI::Command::Inbox.new])
                                           .bind(Struct.new(:approvals, :replies).new(queue, replies))

    commands = Class.new do
      def initialize(queue, dir, askers, conductor, rail, waiting, registry)
        @queue = queue
        @dir = dir
        @askers = askers
        @conductor = conductor
        @rail = rail
        @waiting = waiting
        @registry = registry
        @parked = 0
      end

      def serves_replies?(_text) = false

      def dispatch(text)
        File.write(File.join(@dir, "dispatched"), "#{text}\n", mode: "a")
        return @registry.dispatch(text) { nil } if text.start_with?("/")
        return unless ["run the tests", "ask me", "ask and park", "ask supervised"].include?(text)

        $stdout.write("DISPATCHING\n")
        @waiting.call
        send(text.tr(" ", "_"))
        $stdout.write("SETTLED\n")
        nil
      end

      def park
        @parked += 1
        command = @parked == 1 ? "rm -rf build" : "rm -rf build#{@parked}"
        File.write(File.join(@dir, "parked"), "", mode: "a")
        @queue.call(Lain::Effect::ToolCall.new(tool_use_id: "call_#{@parked}", name: "bash",
                                               input: { "command" => command }), nil)
      end

      def run_the_tests = park
      def ask_me = ask

      def ask_and_park
        parking = Async::Task.current.async do
          Async::Task.current.sleep(0.02) until @rail.published.kind == :human
          park
        end
        ask
        parking.wait
      end

      def ask_supervised
        Sync { |task| @conductor.supervise(task, -> { Lain::Timeline.empty }) { ask } }
      end

      def ask
        chain = Lain::Timeline.empty(store: Lain::Store.new)
                              .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
        result = @askers.enrol(chain).asker.call({ "question" => "which db?" },
                                                 Lain::Tool::Invocation.new(context: Lain::Session::Null.instance))
        File.write(File.join(@dir, "answer"), result.content.to_s)
      end
    end.new(queue, dir, askers, conductor, rail, waiting, registry)

    if shape != "cockpit"
      replies.bind_commands(registry)
      first = { "plain" => "run the tests", "human" => "ask me", "queued" => "ask and park",
                "supervised" => "ask supervised" }[shape]
      repl = Lain::CLI::Repl.new(agent: Struct.new(:timeline).new(nil), tty:, replies:, commands:, supervisor:,
                                 chronicle: Lain::CLI::Chronicle::Null.new, conductor:, approvals: queue, input: pump)
      conductor.guard do
        Sync do |task|
          if shape.start_with?("actor")
            task.async do
              waiting.call
              Async::Task.current.sleep(0.02) until supervisor.running?
              # The park runs under the SUPERVISOR's task, where an adoption puts
              # a subagent's work, so the chat's close reaps it.
              supervisor.adopt(role: "actor") do
                Array.new(shape == "actor2" ? 2 : 1) { Async::Task.current.parent.async { commands.park } }
                Struct.new(:stopped) do
                  def stop = self.stopped = true
                  def stopped? = stopped ? true : false
                  def dead? = false
                  def address = "actor"
                end.new(false)
              end
            end
          end
          repl.run(nvim: nil, store: nil, session: nil, first_prompt: first)
        end
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
      replies.bind_commands(registry)
      conversation = Lain::CLI::Repl::ConversationScope.new(supervisor: Lain::Supervisor::Null, replies:, surfaces:)
      Sync do |task|
        pump.start(task)
        conversation.open(task)
        commands.dispatch("run the tests")
      ensure
        conversation.close
      end
    end
    File.write(File.join(dir, "exited"), "")
  RUBY

  # The far end of the PTY: what the human types, and everything the chat drew.
  # `answers_cursor: false` is a terminal that never replies to Reline's
  # cursor-position query, which Reline waits out for half a second.
  class Terminal
    CURSOR_QUERY = "\e[6n"
    CURSOR_REPORT = "\e[1;1R"

    def initialize(child:, window:, shape:, answers_cursor: true, grace: nil)
      @child = child
      @dir = child.dir
      @output = child.reader
      @input = child.writer
      @screen = +""
      @lock = Mutex.new
      @answers_cursor = answers_cursor
      @during_query = nil
      @pump = Thread.new { pump }
      @output.winsize = [40, 200]
      child.tell(@dir, window, shape, grace || 30)
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
      wait_for(timeout:, what: pattern.inspect) { screen.match?(pattern) }
    end

    # Fails with the screen, which a bare expect on a polled condition would not show.
    def wait_for(timeout: 20, what: "the condition")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep(0.005) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      yield || raise("#{what} never held; the screen was:\n#{screen}")
    end

    # The `[y/N]` drawn again after the last line matching `note`: a line typed
    # before that is held for the next read, not answered.
    def await_asked_again_after(note)
      wait_for(what: "#{note.inspect} then #{PlainChatPromptGuards::APPROVAL.inspect}") do
        drawn = screen
        at = drawn.rindex(note)
        at && drawn[at..].match?(PlainChatPromptGuards::APPROVAL)
      end
    end

    # The echo is the signal that the bytes reached the kernel's buffer.
    def type_echoed(bytes)
      before = screen.bytesize
      type(bytes)
      wait_for(what: "the echo of #{bytes.inspect}") { screen.bytesize >= before + bytes.bytesize }
    end

    # The chat has ended and the terminal has nothing more to say: EOF on the
    # PTY is the whole window for "nothing is drawn after the close".
    def closed?(timeout: 20) = @pump.join(timeout) ? true : false

    def parked? = File.exist?(File.join(@dir, "parked"))

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

    # The session record's entries of one type, for the shapes that keep one.
    def records(type)
      path = File.join(@dir, "session.ndjson")
      return [] unless File.exist?(path)

      Lain::Journal.records(File.readlines(path), type:).to_a
    end

    # Whether the chat ran to its end, rather than still reading.
    def exited? = File.exist?(File.join(@dir, "exited"))

    # The screen with its escape sequences taken out, as a human reads it.
    def text = screen.gsub(/\e\[[\d;?]*[A-Za-z]/, "").gsub(/\e[>=]/, "")

    def close
      @child.reap
      @pump.join(2)
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
    warm_pool(:terminals) do |term|
      WarmCockpit.terminal(prefix: "plain-chat", script: PlainChatPromptGuards::CHILD, term:, flags: [])
    end

    around do |example|
      @terminal = PlainChatPromptGuards::Terminal.new(child: terminals.take(term), window:, shape:,
                                                      answers_cursor:, grace:)
      example.run
    ensure
      @terminal&.close
    end

    let(:window) { 30 }
    let(:grace) { nil }
    let(:shape) { "plain" }
    let(:term) { "xterm" }
    let(:answers_cursor) { true }
    let(:terminal) { @terminal }

    # Typed ahead on a terminal whose prompt the spec cannot wait for by sight.
    def typed_ahead_unseen(bytes)
      terminal.await(/DISPATCHING/)
      terminal.type_echoed(bytes)
      terminal.typed
      terminal.await(/held as your next prompt: #{Regexp.escape(bytes.chomp)}/)
    end

    # The answer that proves nothing earlier was one: it is the only verdict.
    def expect_denied_by_the_next_n
      terminal.await_asked_again_after("held as your next prompt:")
      terminal.type("n\r")
      terminal.await(/SETTLED/)
      expect(terminal.verdicts).to eq([%w[tty deny]])
    end

    # Type ahead while the first line dispatches, then let it park its call.
    def typed_ahead(bytes)
      terminal.await(/DISPATCHING/)
      terminal.type_echoed(bytes) # in the kernel's buffer before the call parks
      terminal.typed
      terminal.await(PlainChatPromptGuards::APPROVAL)
    end

    describe "a line typed during dispatch" do
      it "does not answer the next approval, and is dispatched as the next prompt once the line settles" do
        typed_ahead("yes please\r")
        terminal.await(/held as your next prompt: yes please/)

        expect(terminal.verdicts).to be_empty # the prompt opened empty and waits

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
        terminal.await(/discarded: y/)

        expect(terminal.verdicts).to be_empty
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

        terminal.await_asked_again_after("held as your next prompt:")
        terminal.type("#{verdict}\r")
        terminal.await(/SETTLED/)
        terminal.await(/you> /)
      end

      it "holds the whole line and asks again, when its end is typed after the prompt drew" do
        typed_ahead("Say ")
        terminal.type("yes\r")
        terminal.await(/held as your next prompt: Say yes/)

        split_line_answered_by("n")

        expect(terminal.verdicts).to eq([%w[tty deny]])
        expect(terminal.dispatched).to eq(["run the tests", "Say yes"])
      end

      it "holds the whole line and asks again, when its end is typed at a human's pace, unseen" do
        terminal.await(/DISPATCHING/)
        terminal.type_echoed("Say ")
        terminal.typed
        sleep(0.04) # a human's pace between the halves is the scenario
        terminal.type("yes\r")
        terminal.await(PlainChatPromptGuards::APPROVAL)
        terminal.await(/held as your next prompt: Say yes/)

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
        terminal.await(/held as your next prompt: yes/)

        expect(terminal.verdicts).to be_empty

        expect_denied_by_the_next_n
      end
    end

    # Reline asks the terminal where its cursor is as a read opens, before its
    # prompt draws, and keeps what else it read for that read: a line whose
    # first byte lands in that window was typed before the prompt appeared.
    describe "a line typed while the prompt's read waits on the cursor query" do
      it "does not answer the [y/N]" do
        terminal.await(/DISPATCHING/)
        terminal.type_during_next_query("yes\r")
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)
        terminal.await(/held as your next prompt: yes/)

        expect_denied_by_the_next_n
      end

      context "with a terminal that never answers the query" do
        let(:answers_cursor) { false }

        it "does not answer the [y/N] with a yes typed while the read waited it out" do
          terminal.await(/DISPATCHING/)
          terminal.typed
          terminal.await(/\e\[6n/) # the query is out and nobody replies to it
          terminal.type("yes\r")
          terminal.await(PlainChatPromptGuards::APPROVAL)
          terminal.await(/held as your next prompt: yes/)

          expect_denied_by_the_next_n
        end
      end

      context "when the prompt is a human> question" do
        let(:shape) { "human" }

        it "does not answer the question, which the line typed at human> then does" do
          terminal.await(/DISPATCHING/)
          terminal.type_during_next_query("postgres\r")
          terminal.typed
          terminal.await(/human> /)
          terminal.await(/held as your next prompt: postgres/)

          expect(terminal.answer).to be_nil

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
          terminal.type_during_next_query("yes\r")
          terminal.type("/approve\r")
          terminal.await(/held as your next prompt: yes/)

          expect(terminal.verdicts).to be_empty
          expect_denied_by_the_next_n
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
        expect_denied_by_the_next_n
      end

      it "holds a prompt typed during dispatch, rather than taking it as a denial" do
        typed_ahead_unseen("yes please\r")

        expect(terminal.verdicts).to be_empty
        expect_denied_by_the_next_n
      end
    end

    # A key sequence typed ahead -- an arrow -- is not the start of a line, so
    # the human's first real answer is not joined to it and held.
    describe "an arrow key typed before a prompt" do
      it "is dropped, so the first n typed at the prompt answers it" do
        typed_ahead("\e[A")
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
        terminal.await(/denied after \d+:\d\d with no answer/)
        terminal.await(/you> /)

        terminal.type("y\r")
        terminal.wait_for(what: "the y dispatched as a line") { terminal.dispatched.size == 2 }

        # Found by its words rather than as the row after the prompt: the
        # fixture's SETTLED is a raw write past the writer lock, and when it
        # lands first it ends the prompt's row itself.
        rows = terminal.text.lines
        prompt_row = rows.rindex { |row| row.match?(PlainChatPromptGuards::APPROVAL) }
        verdict_row = rows.index { |row| row.match?(/-- denied after \d+:\d\d with no answer/) }
        expect(verdict_row).to be > prompt_row
        expect(rows[(prompt_row + 1)...verdict_row]).to all(match(/\A\s*\z/))
        expect(rows[verdict_row].lstrip).to match(/\A\d\d:\d\d:\d\d -- denied after/)
        expect(terminal.verdicts).to eq([%w[timeout deny]])
        expect(terminal.dispatched).to eq(["run the tests", "y"])
      end
    end

    # A gated call parks while `human>` is open for a question. The `[y/N]`
    # waits its turn on the rail; its one-line arrival is enqueued at once,
    # printed as soon as `human>` closes (nothing prints above a live prompt),
    # and precedes the `[y/N]`'s draw.
    describe "an approval queued behind a question" do
      let(:shape) { "queued" }

      it "announces the call once human> closes, then draws the [y/N]" do
        terminal.typed
        terminal.await(/human> /)
        terminal.wait_for(what: "the call parked") { terminal.parked? }
        sleep(0.3) # a negative window: an arrival printed over a live human> would land in it
        expect(terminal.screen).not_to include("asks to run bash")

        terminal.type("postgres\r")
        terminal.await(PlainChatPromptGuards::APPROVAL)

        arrival = terminal.screen.index("agent asks to run bash(")
        expect(arrival).not_to be_nil
        expect(arrival).to be < terminal.screen.rindex("approve bash(")
        terminal.type("n\r")
        terminal.await(/SETTLED/)
        expect(terminal.verdicts).to eq([%w[tty deny]])
      end

      context "when its queue timeout expires while human> is still open" do
        let(:window) { 1.0 }

        it "says, once human> closes, that the call was denied by timeout" do
          terminal.typed
          terminal.await(/human> /)
          terminal.wait_for(what: "the window to decide the call") { terminal.verdicts == [%w[timeout deny]] }
          terminal.type("postgres\r")
          terminal.await(/denied after \d+:\d\d with no answer/)

          expect(terminal.verdicts).to eq([%w[timeout deny]])
          expect(terminal.screen.lines.grep(/denied after \d+:\d\d with no answer/).join).to include("rm -rf build")
        end
      end
    end

    # A Ctrl-C at `human>` under a supervised ask opens the shutdown countdown.
    # The `human>` read steps aside for it -- anything half typed there is gone
    # -- so the countdown's line draws rather than being held off by the read.
    describe "Ctrl-C at human>" do
      let(:shape) { "supervised" }

      it "draws the shutdown countdown" do
        terminal.typed
        terminal.await(/human> /)
        terminal.type("\x03")
        terminal.await(/closing in \d+s/)

        expect(terminal.screen[terminal.screen.rindex("human> ")..]).to match(/closing in \d+s -- \[c\] cancel/)
      end

      # The key that ends the ask and nothing else: the window offers it at the
      # chat's own terminal too, and the chat is still there afterwards.
      it "offers stop, and s ends the ask while the session carries on" do
        terminal.typed
        terminal.await(/human> /)
        terminal.type("\x03")
        terminal.await(/closing in \d+s/)
        countdown = terminal.text[terminal.text.rindex("closing in")..]
        terminal.type("s")
        terminal.wait_for(what: "the ask stopped") { terminal.records("run_interrupted").any? }
        terminal.wait_for(what: "you> back") { terminal.text[terminal.text.rindex("closing in")..].include?("you> ") }
        sleep(0.3) # a negative window: a chat that ends on s would write `exited` in it

        expect(countdown).to include("[s] stop this ask")
        expect(terminal.exited?).to be(false)
        expect(terminal.screen).to include("you> ")
        expect(terminal.records("run_interrupted").map { |record| record["reason"] }).to eq(["stopped"])
        expect(terminal.records("session_closed")).to be_empty
      end

      # The stopped ask withdrew its question, so the `human>` read for it has
      # nothing left to answer: a line typed next belongs to `you>`.
      def await_you_after_the_stop
        terminal.wait_for(what: "the ask stopped") { terminal.records("run_interrupted").any? }
        terminal.wait_for(what: "the dispatch to settle") { terminal.text.include?("SETTLED") }
        terminal.wait_for(what: "you> drawn after the stop") do
          terminal.text[terminal.text.rindex("SETTLED")..].include?("you> ")
        end
      end

      {
        "/stop at human>" => ->(terminal) { terminal.type("/stop\r") },
        "Ctrl-C then s" => lambda do |terminal|
          terminal.type("\x03")
          terminal.await(/closing in \d+s/)
          terminal.type("s")
        end
      }.each do |how, stop|
        it "gives you> back after #{how}, and dispatches the next line typed" do
          terminal.typed
          terminal.await(/human> /)
          stop.call(terminal)
          await_you_after_the_stop
          terminal.type("raven\r")
          terminal.wait_for(what: "raven dispatched") { terminal.dispatched.include?("raven") }

          expect(terminal.dispatched).to eq(["ask supervised", "raven"])
          expect(terminal.answer).to be_nil
          expect(terminal.text).not_to include("held as your next prompt: raven")
        end
      end

      it "keeps the human> read for a question still awaited after Ctrl-C then c" do
        terminal.typed
        terminal.await(/human> /)
        terminal.type("\x03")
        terminal.await(/closing in \d+s/)
        terminal.type("c")
        terminal.wait_for(what: "human> put back") do
          terminal.text[terminal.text.rindex("closing in")..].include?("human> ")
        end
        terminal.type("yes\r")
        terminal.await(/SETTLED/)

        expect(terminal.answer).to include("yes")
        expect(terminal.records("run_interrupted")).to be_empty
      end
    end

    # A plain chat at rest sits at `you>`, and a fleet actor's call would
    # otherwise show only when the human next pressed Enter.
    describe "a call parked while the chat sits at an empty you>" do
      let(:shape) { "actor" }

      it "draws its [y/N] at once, and you> again after it is answered" do
        terminal.await(/you> /)
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)

        terminal.type("n\r")
        terminal.wait_for(what: "the denial") { terminal.verdicts == [%w[tty deny]] }
        terminal.wait_for(what: "you> after the answer") { terminal.text.split("approve bash(").last.include?("you> ") }

        expect(terminal.verdicts).to eq([%w[tty deny]])
        expect(terminal.dispatched).to be_empty
      end

      it "waits behind a you> the human has typed at, announced once that line is sent" do
        terminal.await(/you> /)
        terminal.type_echoed("half a thought")
        terminal.typed
        terminal.wait_for(what: "the call parked") { terminal.parked? }
        sleep(0.3) # a negative window: a prompt that preempted the typing would draw in it
        expect(terminal.screen).not_to match(PlainChatPromptGuards::APPROVAL)

        terminal.type("\r")
        terminal.await(PlainChatPromptGuards::APPROVAL)

        expect(terminal.dispatched).to eq(["half a thought"])
        expect(terminal.screen.index("agent asks to run bash(")).to be < terminal.screen.rindex("approve bash(")
      end
    end

    def arrivals = terminal.text.lines.grep(/! agent asks to run bash\(/).grep_v(/decided by/)

    # A watcher asks about one parked call at a time, so the second of two calls
    # parked together is asked the moment the first is answered -- which is the
    # instant `you>` comes back, empty, before its line editor has opened.
    describe "two calls parked together at an empty you>" do
      let(:shape) { "actor2" }

      it "draws the second [y/N] as soon as the first is answered, with nothing typed, then you>" do
        terminal.await(/you> /)
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)
        terminal.type("n\r")
        terminal.await_asked_again_after("rm -rf build2")
        terminal.type("y\r")
        terminal.wait_for(what: "both decided") { terminal.verdicts.size == 2 }
        terminal.wait_for(what: "you> after build2") do
          terminal.text[terminal.text.rindex("rm -rf build2")..].include?("you> ")
        end

        expect(terminal.verdicts).to eq([%w[tty deny], %w[tty approve]])
        expect(terminal.dispatched).to be_empty
      end
    end

    # A line held at a preempting `[y/N]` -- a `/`-line is never its answer --
    # is the next line `you>` reads when it comes back, ahead of anything typed
    # after it.
    describe "a /-line typed at a [y/N] that preempted an empty you>" do
      let(:shape) { "actor" }

      it "is dispatched when you> returns, before the line typed next" do
        terminal.await(/you> /)
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)
        terminal.type("/goal off\r")
        terminal.await(%r{held as your next prompt: /goal off})
        terminal.await_asked_again_after("held as your next prompt: /goal off")
        terminal.type("n\r")
        terminal.wait_for(what: "the held line dispatched") { terminal.dispatched == ["/goal off"] }
        terminal.type("second line\r")
        terminal.wait_for(what: "the second line dispatched") { terminal.dispatched.size == 2 }

        expect(terminal.dispatched).to eq(["/goal off", "second line"])
      end
    end

    # Prose is no verdict either: it is held for `you>` and the `[y/N]` asks again.
    describe "prose typed at a [y/N] that preempted an empty you>" do
      let(:shape) { "actor" }

      it "decides nothing, is held, and is dispatched once the call is answered" do
        terminal.await(/you> /)
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)
        terminal.type("please also fix the tests\r")
        terminal.await(/held as your next prompt: please also fix the tests/)
        terminal.await(/a y or n answers the approval/)
        terminal.await_asked_again_after("a y or n answers the approval")

        expect(terminal.verdicts).to be_empty

        terminal.type("n\r")
        terminal.wait_for(what: "the held line dispatched") { terminal.dispatched == ["please also fix the tests"] }

        expect(terminal.verdicts).to eq([%w[tty deny]])
      end
    end

    # `/approve` typed while the watcher's own `[y/N]` for the same call waits
    # behind it: one question for one call, and the prompt left over is taken
    # down in words once the call is decided rather than asked again.
    describe "/approve typed while the watcher's [y/N] for the same call is queued" do
      let(:shape) { "actor" }

      it "decides the call once, announces it once, and never contradicts the answer" do
        terminal.await(/you> /)
        terminal.type_echoed("/approve")
        terminal.typed
        terminal.wait_for(what: "the call parked") { terminal.parked? }
        sleep(0.3) # a negative window: the watcher's own prompt must not draw over the typing
        terminal.type("\r")
        terminal.await(PlainChatPromptGuards::APPROVAL)
        terminal.type("y\r")
        terminal.await(/bash: approved/)
        terminal.type("n\r")
        terminal.wait_for(what: "the n dispatched as a line") { terminal.dispatched.size == 2 }

        expect(terminal.verdicts).to eq([%w[tty approve]])
        expect(arrivals.size).to eq(1)
        expect(terminal.text).to include("-- decided by tty: approved")
        expect(terminal.text).not_to include("bash: denied")
        expect(terminal.dispatched).to eq(["/approve", "n"])
      end
    end

    # Ctrl-C at a `[y/N]` that took the terminal from an idle `you>` is a
    # Ctrl-C at a question, as at `human>`: the countdown draws, and a cancel
    # puts the question back. It does not end the chat by itself.
    describe "Ctrl-C at a [y/N] that preempted an idle you>" do
      let(:shape) { "actor" }

      it "draws the countdown, and c puts the [y/N] back, answerable" do
        terminal.await(/you> /)
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)
        terminal.type("\x03")
        terminal.await(/closing in \d+s/)
        terminal.type("c")
        terminal.wait_for(what: "the [y/N] put back") do
          terminal.text[terminal.text.rindex("closing in")..].include?("approve bash(")
        end
        after_cancel = terminal.text[terminal.text.rindex("closing in")..]
        terminal.type("n\r")
        terminal.wait_for(what: "the denial") { terminal.verdicts == [%w[tty deny]] }

        expect(after_cancel).to include("approve bash(")
        expect(terminal.verdicts).to eq([%w[tty deny]])
        expect(terminal.exited?).to be(false)
      end

      # Nobody presses anything: the countdown means what it says. The chat
      # closes, the fleet's parked call is reaped with it, and no prompt is put
      # back on a screen the chat has finished with.
      context "when nobody answers it" do
        let(:grace) { 2 }

        it "ends the chat, reaps the parked call, and draws no prompt after the close" do
          terminal.await(/you> /)
          terminal.typed
          terminal.await(PlainChatPromptGuards::APPROVAL)
          terminal.type("\x03")
          terminal.await(/closing in \d+s/)
          drawn = terminal.text.scan("approve bash(").size
          terminal.wait_for(what: "the chat to close") { terminal.closed? }

          expect(terminal.exited?).to be(true)
          expect(terminal.verdicts).to eq([%w[abandoned deny]])
          expect(terminal.text.scan("approve bash(").size).to eq(drawn)
        end

        # "respond then exit" waits for a run to answer, and at `you>` there is
        # none: pressed there it made the next typed line the thing waited for,
        # and that line went with the session.
        it "offers cancel and wait longer, and no respond-then-exit" do
          terminal.await(/you> /)
          terminal.typed
          terminal.await(PlainChatPromptGuards::APPROVAL)
          terminal.type("\x03")
          terminal.await(/closing in \d+s/)

          countdown = terminal.text[terminal.text.rindex("closing in")..]
          expect(countdown).to include("[c] cancel", "[w] wait longer")
          expect(countdown).not_to include("respond then exit")
        end
      end

      # The line editor traps INT for its own read and reaches the chat's handler
      # only from its key loop, so a Ctrl-C arriving as the `[y/N]` takes the
      # terminal used to die with the read it interrupted. The chat holds that
      # trap while a read is under way, and routes the signal against what is
      # drawn when it is handled.
      it "loses no Ctrl-C that lands as the [y/N] takes the terminal" do
        terminal.await(/you> /)
        sleep(0.3) # the chat is not ready for a Ctrl-C in the first ~30ms after you> draws; no signal says when it is
        terminal.typed
        sleep(0.008) # the race under test: the signal lands as the [y/N] takes the terminal
        terminal.type("\x03")
        # Which of the two it is depends on whether `you>` was still the prompt
        # when the signal was handled; that it is one of them is the claim.
        expect(terminal.wait_for(what: "the countdown or the close") do
          terminal.text.match?(/closing in \d+s/) || terminal.exited?
        end).to be_truthy
      end

      it "still ends the chat on a Ctrl-C at the idle you> itself" do
        terminal.await(/you> /)
        terminal.type("\x03")
        expect(terminal.wait_for(what: "the chat to end") { terminal.exited? }).to be(true)
      end
    end

    # A dumb terminal reads cooked, so nothing can say whether the human has
    # begun typing at `you>`: an answer never takes the terminal there, and a
    # line typed across the arrival stays one line.
    context "with a dumb terminal at an idle you>" do
      let(:shape) { "actor" }
      let(:term) { "dumb" }

      it "does not preempt a you> the human is typing at, and never splits the line" do
        terminal.await(/you> /)
        terminal.type_echoed("ye")
        terminal.typed
        terminal.wait_for(what: "the call parked") { terminal.parked? }
        sleep(0.3) # a negative window: a prompt that took the cooked read would split the line in it
        terminal.type("s\r")
        terminal.wait_for(what: "the line dispatched") { terminal.dispatched == ["yes"] }

        expect(terminal.text).not_to include("discarded: ye")
        expect(terminal.dispatched).to eq(["yes"])
        expect(terminal.verdicts).to be_empty
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
        terminal.await(/held as your next prompt: not an answer/)

        expect(terminal.verdicts).to be_empty

        terminal.type("n\r")
        terminal.await(/SETTLED/)

        expect(terminal.verdicts).to eq([%w[tty deny]])
      end
    end
  end

  # A `[y/N]` still waiting its turn on the rail -- a `human>` is published
  # ahead of it -- when the approval window decides its call was never drawn,
  # so it has no row to end: it says how its call was decided in a line of its
  # own, naming the call. That line is held while `human>` is drawn, like any
  # note, and printed once `human>` closes.
  describe "a prompt decided while it still waited behind another read" do
    it "prints a whole line naming the call and saying it was denied by timeout" do
      output = StringIO.new
      tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, history_path: File::NULL,
                                    pastel: Pastel.new(enabled: false))
      rail = Lain::Frontend::Intake.new(screen: tty)
      journal_io = StringIO.new
      queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: journal_io), timeout: 0.3)
      policy = Lain::Frontend::ApprovalPolicy.new(output: StringIO.new,
                                                  reader: ->(prompt) { rail.read(:approval, prompt) })

      Sync do |task|
        human = task.async { rail.read(:human, "human> ") }
        pumped_until(task) { rail.published.kind == :human }
        watcher = task.async { policy.watch(queue) }
        call = Lain::Effect::ToolCall.new(tool_use_id: "call_1", name: "bash", input: { "command" => "rm -rf build" })
        task.async { queue.call(call, nil) }.wait
        settle_for(task, 0.05)
        watcher.stop
        human.stop
      end

      expect(output.string.lines).to include(
        a_string_including("! agent asks to run bash(", "rm -rf build", "its y/N is asked next"),
        a_string_including("! agent asks to run bash(", "rm -rf build", "-- denied after 0:01 with no answer")
      )
      expect(Lain::Journal.records(journal_io.string.lines, type: "approval_decision").map { |r| r["surface"] }.to_a)
        .to eq(["timeout"])
    end
  end
end
