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

  # The chat under test: a real Repl, Conductor, TTY, InputRail and the StdinPump
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

    dir = ARGV.fetch(0)
    window = Float(ARGV.fetch(1))
    shape = ARGV.fetch(2)
    journal_io = File.open(File.join(dir, "journal.ndjson"), "a").tap { |io| io.sync = true }
    queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: journal_io), timeout: window)
    tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, pastel: Pastel.new(enabled: false),
                                  input: Lain::Frontend::StdinPump.keys($stdin),
                                  history_path: File.join(dir, "history"), state_path: File.join(dir, "state.json"))
    rail = Lain::Frontend::InputRail.new(screen: tty)
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
                                         grace: Float(ENV.fetch("LAIN_SPEC_GRACE", "30")))
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

    def initialize(dir, window:, shape:, term: "xterm", answers_cursor: true, grace: nil)
      @dir = dir
      @screen = +""
      @lock = Mutex.new
      @answers_cursor = answers_cursor
      @during_query = nil
      env = { "TERM" => term, "INPUTRC" => File.join(dir, "no-inputrc") }
      env["LAIN_SPEC_GRACE"] = grace.to_s if grace
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
        @terminal = PlainChatPromptGuards::Terminal.new(dir, window:, shape:, term:, answers_cursor:, grace:)
        example.run
      ensure
        @terminal&.close
      end
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

    # A gated call parks while `human>` is open for a question. The `[y/N]`
    # waits its turn on the rail; its one-line arrival is enqueued at once,
    # printed as soon as `human>` closes (nothing prints above a live prompt),
    # and precedes the `[y/N]`'s draw.
    describe "an approval queued behind a question" do
      let(:shape) { "queued" }

      it "announces the call once human> closes, then draws the [y/N]" do
        terminal.typed
        terminal.await(/human> /)
        sleep(0.8)
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
          sleep(2.0)
          terminal.type("postgres\r")
          terminal.await(/decided by timeout: denied/)

          expect(terminal.verdicts).to eq([%w[timeout deny]])
          expect(terminal.screen.lines.grep(/decided by timeout: denied/).join).to include("rm -rf build")
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
        sleep(0.3)
        terminal.type("\x03")
        terminal.await(/closing in \d+s/)

        expect(terminal.screen[terminal.screen.rindex("human> ")..]).to match(/closing in \d+s -- \[c\] cancel/)
      end

      # The key that ends the ask and nothing else: the window offers it at the
      # chat's own terminal too, and the chat is still there afterwards.
      it "offers stop, and s ends the ask while the session carries on" do
        terminal.typed
        terminal.await(/human> /)
        sleep(0.3)
        terminal.type("\x03")
        terminal.await(/closing in \d+s/)
        countdown = terminal.text[terminal.text.rindex("closing in")..]
        terminal.type("s")
        sleep(2.0)

        expect(countdown).to include("[s] stop this ask")
        expect(terminal.exited?).to be(false)
        expect(terminal.screen).to include("you> ")
        expect(terminal.records("run_interrupted").map { |record| record["reason"] }).to eq(["stopped"])
        expect(terminal.records("session_closed")).to be_empty
      end
    end

    # A plain chat at rest sits at `you>`, and a fleet actor's call would
    # otherwise show only when the human next pressed Enter.
    describe "a call parked while the chat sits at an empty you>" do
      let(:shape) { "actor" }

      it "draws its [y/N] at once, and you> again after it is answered" do
        terminal.await(/you> /)
        sleep(0.3)
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)

        terminal.type("n\r")
        sleep(0.5)
        prompts_after = terminal.screen[terminal.screen.rindex("approve bash(")..]

        expect(terminal.verdicts).to eq([%w[tty deny]])
        expect(prompts_after).to include("you> ")
        expect(terminal.dispatched).to be_empty
      end

      it "waits behind a you> the human has typed at, announced once that line is sent" do
        terminal.await(/you> /)
        sleep(0.3)
        terminal.type("half a thought")
        sleep(0.2)
        terminal.typed
        sleep(1.0)
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
        sleep(0.3)
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)
        sleep(0.3)
        terminal.type("n\r")
        terminal.await(/rm -rf build2/, timeout: 5)
        sleep(0.5)
        terminal.type("y\r")
        sleep(1.0)

        expect(terminal.verdicts).to eq([%w[tty deny], %w[tty approve]])
        expect(terminal.dispatched).to be_empty
        expect(terminal.text[terminal.text.rindex("rm -rf build2")..]).to include("you> ")
      end
    end

    # A line held at a preempting `[y/N]` -- a `/`-line is never its answer --
    # is the next line `you>` reads when it comes back, ahead of anything typed
    # after it.
    describe "a /-line typed at a [y/N] that preempted an empty you>" do
      let(:shape) { "actor" }

      it "is dispatched when you> returns, before the line typed next" do
        terminal.await(/you> /)
        sleep(0.3)
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)
        sleep(0.3)
        terminal.type("/goal off\r")
        terminal.await(%r{held as your next prompt: /goal off})
        sleep(0.3)
        terminal.type("n\r")
        sleep(1.5)
        terminal.type("second line\r")
        sleep(1.5)

        expect(terminal.dispatched).to eq(["/goal off", "second line"])
      end
    end

    # `/approve` typed while the watcher's own `[y/N]` for the same call waits
    # behind it: one question for one call, and the prompt left over is taken
    # down in words once the call is decided rather than asked again.
    describe "/approve typed while the watcher's [y/N] for the same call is queued" do
      let(:shape) { "actor" }

      it "decides the call once, announces it once, and never contradicts the answer" do
        terminal.await(/you> /)
        sleep(0.3)
        terminal.type("/approve")
        sleep(0.2)
        terminal.typed
        sleep(1.0)
        terminal.type("\r")
        terminal.await(PlainChatPromptGuards::APPROVAL)
        sleep(0.5)
        terminal.type("y\r")
        terminal.await(/bash: approved/)
        sleep(0.5)
        terminal.type("n\r")
        sleep(1.0)

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
        sleep(0.3)
        terminal.typed
        terminal.await(PlainChatPromptGuards::APPROVAL)
        sleep(0.3)
        terminal.type("\x03")
        terminal.await(/closing in \d+s/)
        sleep(1.2)
        terminal.type("c")
        sleep(1.5)
        after_cancel = terminal.text[terminal.text.rindex("closing in")..]
        terminal.type("n\r")
        sleep(1.0)

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
          sleep(0.3)
          terminal.typed
          terminal.await(PlainChatPromptGuards::APPROVAL)
          sleep(0.3)
          terminal.type("\x03")
          terminal.await(/closing in \d+s/)
          drawn = terminal.text.scan("approve bash(").size
          sleep(6.0)

          expect(terminal.exited?).to be(true)
          expect(terminal.verdicts).to eq([%w[abandoned deny]])
          expect(terminal.text.scan("approve bash(").size).to eq(drawn)
        end

        # "respond then exit" waits for a run to answer, and at `you>` there is
        # none: pressed there it made the next typed line the thing waited for,
        # and that line went with the session.
        it "offers cancel and wait longer, and no respond-then-exit" do
          terminal.await(/you> /)
          sleep(0.3)
          terminal.typed
          terminal.await(PlainChatPromptGuards::APPROVAL)
          sleep(0.3)
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
        sleep(0.3)
        terminal.typed
        sleep(0.008)
        terminal.type("\x03")
        sleep(2.0)

        # Which of the two it is depends on whether `you>` was still the prompt
        # when the signal was handled; that it is one of them is the claim.
        expect([terminal.text.match?(/closing in \d+s/), terminal.exited?]).to include(true)
      end

      it "still ends the chat on a Ctrl-C at the idle you> itself" do
        terminal.await(/you> /)
        sleep(0.5)
        terminal.type("\x03")
        sleep(1.5)

        expect(terminal.exited?).to be(true)
      end
    end

    # A dumb terminal reads cooked, so nothing can say whether the human has
    # begun typing at `you>`: an answer never takes the terminal there, and a
    # line typed across the arrival stays one line.
    context "with a dumb terminal at an idle you>" do
      let(:shape) { "actor" }
      let(:term) { "dumb" }

      it "does not preempt a you> the human is typing at, and never splits the line" do
        sleep(2.0)
        terminal.type("ye")
        sleep(0.3)
        terminal.typed
        sleep(1.5)
        terminal.type("s\r")
        sleep(1.5)

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
        sleep(0.5)

        expect(terminal.verdicts).to be_empty
        expect(terminal.screen).to include("held as your next prompt: not an answer")

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
      rail = Lain::Frontend::InputRail.new(screen: tty)
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
        a_string_including("! agent asks to run bash(", "rm -rf build", "-- decided by timeout: denied")
      )
      expect(Lain::Journal.records(journal_io.string.lines, type: "approval_decision").map { |r| r["surface"] }.to_a)
        .to eq(["timeout"])
    end
  end
end
