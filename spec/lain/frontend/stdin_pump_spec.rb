# frozen_string_literal: true

require "async"
require "fileutils"
require "io/console"
require "pty"
require "rbconfig"
require "stringio"
require "tmpdir"

# The far end of a PTY a pump child reads: what the human types, and everything drawn.
class StdinPumpRaceTerminal
  include CursorReport

  # @param warm [WarmCockpit::Booted] a pump child already booted and parked in
  #   its own directory
  def initialize(warm)
    @warm = warm
    @screen = +""
    @output = warm.reader
    @input = warm.writer
    @output.winsize = [40, 120]
    @reader = Thread.new { pump }
    warm.tell(warm.dir)
  end

  def dir = @warm.dir

  attr_reader :screen

  def type(bytes) = @input.write(bytes)

  def await(pattern) = wait_for("screen to match #{pattern.inspect}") { @screen.match?(pattern) }

  def type_and_await_echo(bytes)
    seen = @screen.size
    type(bytes)
    wait_for("the echo of #{bytes.inspect}") { @screen.size > seen }
  end

  def await_file(path) = wait_for("#{File.basename(path)} written") { File.exist?(path) }

  def await_lines(pattern)
    wait_for("lines to match #{pattern.inspect}") { lines.match?(pattern) }
  end

  def lines = File.exist?(File.join(dir, "lines")) ? File.read(File.join(dir, "lines")) : ""

  def close
    @warm.reap
    @reader.join(2)
  end

  private

  def wait_for(reason, limit: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
    sleep(0.005) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "#{reason} never held within #{limit}s" unless yield
  end

  def pump
    loop do
      chunk = @output.readpartial(4096)
      @screen << chunk
      answered(@input, chunk)
    end
  rescue IOError, Errno::EIO
    nil
  end
end

RSpec.describe Lain::Frontend::StdinPump do
  # History is the Intake's to keep, not the pump's: the rail here keeps it
  # through the same discretion a chat's does, into the real file.
  let(:rail) { Lain::Frontend::Intake.new(screen:, history: Lain::Frontend::Intake::Discretion.new(writer: screen)) }
  let(:screen) do
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, pastel: Pastel.new(enabled: false), history_path:,
                            layers: -> { Lain::Mode::LayerSet.new(layers) })
  end
  let(:layers) { [] }
  let(:history_path) { File.join(@dir, "history") }
  let(:output) { StringIO.new }

  # Reline's history and config are process-global; see tty_spec for why every
  # example that reaches the line editor puts them back.
  around do |example|
    original = Reline::HISTORY.to_a
    original_inputrc = ENV.fetch("INPUTRC", nil)
    ENV["INPUTRC"] = File.join(Dir.tmpdir, "lain-spec-no-such-inputrc")
    Reline.core.config.reset_variables
    Reline::HISTORY.clear
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  ensure
    Reline::HISTORY.clear
    Reline::HISTORY.concat(original)
    ENV["INPUTRC"] = original_inputrc
    Reline.core.config.reset_variables
  end

  # A double standing in for a real terminal: the pump runs the line editor
  # only when its input answers `tty?`, which a StringIO never does.
  def terminal = instance_double(IO, tty?: true)

  def pumped(input, **seams)
    pump = described_class.new(rail:, screen:, input:, **seams)
    Sync do |task|
      pumping = pump.start(task)
      yield pump
    ensure
      pumping&.stop
    end
  end

  describe "over a stream that is not a terminal" do
    it "writes the published prompt and answers it with the stream's next line" do
      answers = pumped(StringIO.new("hello there\nsecond\n")) { [rail.read(:you, "you> "), rail.read(:you, "you> ")] }

      expect(answers).to eq(["hello there", "second"])
      expect(output.string).to eq("you> you> ")
    end

    it "reads nothing until a prompt is published" do
      input = StringIO.new("not yet\n")

      pumped(input) { |_| Async::Task.current.sleep(0.1) }

      expect(input.pos).to eq(0)
    end

    it "answers every prompt after the stream ends with its end" do
      answers = pumped(StringIO.new("only\n")) { Array.new(3) { rail.read(:human, "human> ") } }

      expect(answers).to eq(["only", nil, nil])
    end

    # A forked child's `STDIN.reopen` puts back whatever its copy of the parent's
    # read buffer held by seeking the descriptor it shares, and a regular file's
    # offset is shared -- so a chat reading stdin buffered re-read its own
    # prompts after every forking runner call. The pump reads a private duplicate and
    # leaves the descriptor children inherit on the null device.
    it "reads a private copy of a real descriptor and seats the original on the null device" do
      path = File.join(@dir, "prompts.txt")
      File.write(path, "first\nsecond\n")
      File.open(path) do |stdin|
        answers = pumped(stdin) { [rail.read(:you, "you> "), stdin.read, rail.read(:you, "you> ")] }

        expect(answers).to eq(["first", "", "second"])
        expect(File.identical?(stdin.path || "/proc/self/fd/#{stdin.fileno}", File::NULL)).to be(true)
      end
    end
  end

  describe "over a terminal" do
    it "binds the approval key it was given when it starts, and not Shift+Tab" do
      allow(Reline).to receive(:readmultiline).and_return("hi")
      Lain::Frontend::LineEditor.unbind_all

      bound = pumped(terminal, cycle_key: "C-x") do
        rail.read(:you, "> ")
        [Lain::Frontend::LineEditor.bound?("C-x"), Lain::Frontend::LineEditor.bound?("S-Tab")]
      ensure
        Lain::Frontend::LineEditor.unbind_all
      end

      expect(bound).to eq([true, false])
    end

    it "hands the composed prompt to the line editor and answers with what was typed" do
      allow(Reline).to receive(:readmultiline).and_return("hi")

      expect(pumped(terminal) { rail.read(:you, "> ") }).to eq("hi")
      expect(Reline).to have_received(:readmultiline).with("> ", true)
    end

    it "draws an answer's prompt once and a you> prompt on every row" do
      drawn = []
      allow(Reline).to receive(:readmultiline) do
        drawn << Reline.prompt_proc&.call(%w[a b])
        "n"
      end

      pumped(terminal) { [rail.read(:you, "you> "), rail.read(:human, "human> ")] }

      expect(drawn).to eq([nil, ["human> ", ""]])
    end

    it "delivers a backslash-continued message as one line" do
      allow(Reline).to receive(:readmultiline).and_return("first \\\nsecond")

      expect(pumped(terminal) { rail.read(:you, "> ") }).to eq("first \nsecond")
    end

    it "asks the line editor for vi mode only while the vi layer is up" do
      allow(Reline).to receive(:readmultiline).and_return("hi")
      layers << :vi

      pumped(terminal) { rail.read(:you, "> ") }

      expect(Reline.core.config.editing_mode_is?(:vi_insert)).to be(true)
    end

    # With a `[y/N]` able to take the terminal from an idle `you>`, a `y` or an
    # `n` would otherwise be the first thing Up recalls there.
    it "keeps an answer to a [y/N] out of the history" do
      allow(Lain::Frontend::LineEditor).to receive(:typed_ahead).and_return("")
      allow(Reline).to receive(:readmultiline).and_return("n")

      pumped(terminal) { rail.read(:approval, "[y/N] ") }

      expect(File.exist?(history_path)).to be(false)
    end

    it "writes an accepted line to the history before the next prompt" do
      allow(Reline).to receive(:readmultiline).and_return("remember me")

      pumped(terminal) { rail.read(:you, "> ") }

      expect(File.read(history_path)).to eq("remember me\n")
    end

    it "keeps a credential typed at you> out of the history, and still answers with it" do
      credential = "use sk-#{"a" * 24} for the staging deploy"
      allow(Reline).to receive(:readmultiline).and_return(credential)

      expect(pumped(terminal) { rail.read(:you, "you> ") }).to eq(credential)
      expect(File.exist?(history_path)).to be(false)
    end

    # The fragment typed ahead of a `[y/N]` and the rest typed at it are one
    # line to the human, and the history is where they would look for it.
    it "keeps a line begun before an answer's prompt whole, once it reaches you>" do
      allow(Lain::Frontend::LineEditor).to receive(:typed_ahead).and_return("Say ", "", "", "")
      allow(Reline).to receive(:readmultiline).and_return("yes", "n")

      pumped(terminal) { [rail.read(:approval, "[y/N] "), rail.read(:you, "you> ")] }

      expect(File.read(history_path)).to eq("Say yes\n")
    end

    it "answers the end of the terminal's stream with nil, and still reads the next prompt" do
      allow(Reline).to receive(:readmultiline).and_return(nil, "again")

      expect(pumped(terminal) { [rail.read(:human, "human> "), rail.read(:you, "you> ")] }).to eq([nil, "again"])
    end

    it "answers a terminal that died under the read with nil" do
      allow(Reline).to receive(:readmultiline).and_raise(Errno::EIO)

      expect(pumped(terminal) { rail.read(:human, "human> ") }).to be_nil
    end
  end

  # What was typed before an ANSWER's prompt drew, swept off the terminal by
  # {Lain::Frontend::LineEditor.typed_ahead} -- stubbed here with what it would
  # have taken; the seam over a real terminal is plain_chat_prompt_guards_spec.
  describe "typeahead at an answer's prompt" do
    def typed(*sweeps) = allow(Lain::Frontend::LineEditor).to receive(:typed_ahead).and_return(*sweeps)

    it "holds each whole line typed ahead, and answers with the line typed at the prompt" do
      typed("yes please\r", "")
      allow(Reline).to receive(:readmultiline).and_return("n")

      expect(pumped(terminal) { rail.read(:approval, "[y/N] ") }).to eq("n")
      expect(rail.take_held).to eq("yes please")
      expect(output.string).to include("held as your next prompt: yes please")
    end

    it "joins a line begun before the prompt to its end, and holds it whole rather than answering" do
      typed("Say ", "", "", "")
      allow(Reline).to receive(:readmultiline).and_return("yes", "n")

      expect(pumped(terminal) { rail.read(:approval, "[y/N] ") }).to eq("n")
      expect(rail.take_held).to eq("Say yes")
      expect(output.string).to include("discarded: Say")
    end

    it "sweeps nothing ahead of a prompt that answers nothing, which reads typeahead as the line it is" do
      typed("/approve\r")
      allow(Reline).to receive(:readmultiline).and_return("/approve")

      expect(pumped(terminal) { rail.read(:command, "command> ") }).to eq("/approve")
      expect(Lain::Frontend::LineEditor).not_to have_received(:typed_ahead)
    end

    it "asks the terminal for Shift+Enter around a command> read as around any other" do
      master, slave = PTY.open
      allow(Reline.core).to receive(:output).and_return(slave)
      during = nil
      allow(Reline).to receive(:readmultiline) do
        during = pty_read(master, "\e[>4;1m".bytesize)
        "/approve"
      end

      pumped(terminal) { rail.read(:command, "command> ") }
      slave.close

      expect([during, pty_drained(master)]).to eq(["\e[>4;1m", "\e[>4;0m"])
    ensure
      slave&.close
      master&.close
    end
  end

  # What was typed while nothing drew at all -- a standing goal drives turns with
  # no prompt open -- asked for between asks through {Intake#gather}.
  describe "#sweep" do
    def typed(*sweeps) = allow(Lain::Frontend::LineEditor).to receive(:typed_ahead).and_return(*sweeps)

    it "holds each whole line typed so far, in the order typed, and says so" do
      typed("/goal off\rkeep going\r")

      pumped(terminal) { rail.gather }

      expect([rail.take_held, rail.take_held, rail.take_held]).to eq(["/goal off", "keep going", nil])
      expect(output.string).to include("held as your next prompt: /goal off")
    end

    # The sweep switches the terminal raw, which beside an open read would take
    # the bytes that read is waiting on -- and with every answer surface live for
    # the conversation, a `[y/N]` can be open while a goal's sweep runs.
    it "waits for a read that is already open" do
      order = []
      allow(Lain::Frontend::LineEditor).to receive(:typed_ahead) { (order << :swept) && "" }
      allow(Reline).to receive(:readmultiline) do
        order << :read_opened
        Async::Task.current.sleep(0.05)
        (order << :read_closed) && "hi"
      end

      pumped(terminal) do
        reading = Async::Task.current.async { rail.read(:you, "you> ") }
        pumped_until(Async::Task.current, reason: "the read opened") { order.include?(:read_opened) }
        rail.gather
        reading.wait
      end

      expect(order).to eq(%i[read_opened read_closed swept])
    end

    it "reads nothing from a stream that is not a terminal, so its next line is read at the prompt" do
      answer = pumped(StringIO.new("a prompt\n")) do
        rail.gather
        rail.read(:you, "you> ")
      end

      expect([rail.take_held, answer]).to eq([nil, "a prompt"])
    end

    it "keeps a line still being typed, and holds it whole once a later sweep finds its end" do
      typed("/goal o", "ff\r")

      held = pumped(terminal) do
        rail.gather
        early = rail.take_held
        rail.gather
        [early, rail.take_held]
      end

      expect(held).to eq([nil, "/goal off"])
      expect(output.string).not_to include("discarded")
    end

    it "types a kept line back into the next prompt's read, once, where the human finishes it" do
      typed("hel")
      pushed = []
      allow(Reline::IOGate).to receive(:ungetc) { |byte| pushed << byte }
      allow(Reline).to receive(:readmultiline).and_return("hello", "next")

      pumped(terminal) do
        rail.gather
        2.times { rail.read(:you, "you> ") }
      end

      expect(pushed.size).to eq(3)
    end

    it "joins a kept line to the rest at an answer's prompt rather than taking it as the answer" do
      typed("/goal o", "", "", "", "")
      allow(Reline).to receive(:readmultiline).and_return("ff", "n")

      answer = pumped(terminal) do
        rail.gather
        rail.read(:approval, "[y/N] ")
      end

      expect([answer, rail.take_held]).to eq(["n", "/goal off"])
    end
  end

  describe "a prompt withdrawn while it is drawn" do
    it "stops the read, draws nothing again, and answers nothing" do
      reads = 0
      allow(Reline).to receive(:readmultiline) do
        reads += 1
        Async::Task.current.sleep(30)
      end

      pumped(terminal) do
        reading = Async::Task.current.async { rail.read(:approval, "[y/N] ") }
        pumped_until(Async::Task.current, reason: "the read drawn") { reads == 1 }
        reading.stop
        Async::Task.current.sleep(0.1)
        rail << Lain::Frontend::Intake::Eof.new
      end

      expect(reads).to eq(1)
      expect(rail.published.generation).to eq(0)
    end
  end

  # A line the human finished at a `[y/N]` in the instant another surface
  # decided its call: the prompt is gone, so the line is not an answer to
  # anything, and it is held and said to be rather than reaching `you>` unseen.
  describe "a line finished at a prompt withdrawn under it" do
    # The withdrawal is made to land between the editor returning the line and
    # the pump delivering it, which is the window a real terminal hits at
    # random, by the rail answering that the prompt is gone once the line is in.
    it "is held, and said to be, rather than put on the rail" do
      entered = false
      allow(rail).to receive(:open?).and_wrap_original do |open, prompt|
        !entered && open.call(prompt)
      end
      allow(Reline).to receive(:readmultiline) do
        entered = true
        "n"
      end

      pumped(terminal) do
        approval = Async::Task.current.async { rail.read(:approval, "[y/N] ") }
        pumped_until(Async::Task.current, reason: "the line held") { output.string.include?("held as your next") }
        approval.stop
      end

      expect(output.string).to include("held as your next prompt: n")
      expect(rail.take_held).to eq("n")
    end
  end

  # The same window over a real terminal: Enter pressed at a `[y/N]` in the
  # instant another surface decides its call. Either the pump had the line --
  # then it is held and said to be -- or the stop reached the editor first and
  # the line died with the read, as it always did. Never an `n` reaching `you>`
  # with nobody told.
  describe "a line entered at a [y/N] as it is withdrawn, over a real terminal", :seam do
    child = <<~'RUBY'
      require "lain"

      dir = ARGV.fetch(0)
      tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, history_path: File.join(dir, "history"),
                                    state_path: File.join(dir, "state.json"), pastel: Pastel.new(enabled: false))
      rail = Lain::Frontend::Intake.new(screen: tty)
      Sync do |task|
        pumping = Lain::Frontend::StdinPump.new(rail:, screen: tty).start(task)
        3.times do
          line = rail.read(:you, "you> ")
          File.write(File.join(dir, "lines"), "#{line.inspect}\n", mode: "a")
          if line == "race"
            approval = task.async { rail.read(:approval, "[y/N] ") }
            task.sleep(0.02) until File.exist?(File.join(dir, "arm"))
            File.write(File.join(dir, "armed"), "")
            $stdin.wait_readable
            approval.stop
          end
        end
        pumping.stop
      end
    RUBY

    warm_pool(:terminals, expected: 3) { WarmCockpit.terminal(prefix: "stdin-pump-race", script: child) }

    # `n` typed at the drawn `[y/N]`, then Enter just after the child is told to
    # withdraw the prompt the moment Enter reaches its terminal.
    def race(terminal)
      dir = terminal.dir
      terminal.await(/you> /)
      terminal.type("race\r")
      terminal.await(%r{\[y/N\] })
      terminal.type("n")
      terminal.await(%r{\[y/N\] (?:\e\[[0-9;?]*[A-Za-z])*n})
      FileUtils.touch(File.join(dir, "arm"))
      terminal.await_file(File.join(dir, "armed"))
      entered_then(terminal)
    ensure
      terminal&.close
    end

    def entered_then(terminal)
      terminal.type_and_await_echo("\r")
      terminal.type("after\r")
      terminal.await_lines(/"after"/)
      terminal.await(/after/)
      [terminal.lines.lines(chomp: true), terminal.screen]
    end

    it "never sends the line to you> unannounced" do
      3.times do
        lines, screen = race(StdinPumpRaceTerminal.new(terminals.take))

        expect(lines.first).to eq('"race"')
        expect(lines.last).to eq('"after"')
        expect(screen).to include("held as your next prompt: n") if lines.include?('"n"')
      end
    end
  end

  describe "waiting for a prompt" do
    it "is told when one is published, rather than asking the rail on a clock" do
      asked = 0
      allow(rail).to receive(:published).and_wrap_original do |original|
        asked += 1
        original.call
      end
      idle_asks = nil

      answer = pumped(StringIO.new("hello\n")) do
        Async::Task.current.sleep(0.3)
        idle_asks = asked
        rail.read(:you, "you> ")
      end

      expect([idle_asks, answer]).to eq([1, "hello"])
    end
  end

  # The rail asks before an answer takes the terminal from `you>`: a prompt the
  # human has begun typing at is theirs, and only the editor holding it knows.
  describe "#untouched?" do
    # A line editor that has opened its read -- Reline calls the pre-input hook
    # once its buffer is fresh -- and then waits for keys, holding `buffer`.
    def editing(buffer)
      allow(Lain::Frontend::LineEditor).to receive(:untouched?) { buffer.empty? }
      allow(Reline).to receive(:readmultiline) do
        Reline.pre_input_hook&.call
        Async::Task.current.sleep(30)
      end
    end

    def untouched_at_you(input)
      pumped(input) do |pump|
        task = Async::Task.current
        reading = task.async { rail.read(:you, "you> ") }
        pumped_until(task, reason: "you> published") { rail.published.kind == :you }
        settle_for(task, 0.05)
        [pump.untouched?(rail.published), pump.untouched?(rail.published.with(generation: 99))]
          .tap { reading.stop }
      end
    end

    it "is true of the you> it draws while nothing is typed there, and false of any other prompt" do
      editing(+"")

      expect(untouched_at_you(terminal)).to eq([true, false])
    end

    it "is false once something is typed at it" do
      editing(+"half a sent")

      expect(untouched_at_you(terminal).first).to be(false)
    end

    # A stream's next line is the next line, whatever prompt it lands at, so a
    # file of prompts is never reordered by an answer arriving.
    it "is false over a stream that is not a terminal" do
      reader, writer = IO.pipe

      expect(untouched_at_you(reader).first).to be(false)
    ensure
      [reader, writer].each { |io| io&.close }
    end
  end

  # The countdown in {Lain::Frontend::InputPane} borrows the terminal through
  # this rather than switching it raw beside an open read -- the read unwinds
  # on this pump's own fiber and puts the mode it found back on the way out.
  #
  # DRIVEN WITH FIBERS, and that is the example rather than incidental to it:
  # the defect is two fibers of one reactor, so a two-thread version would
  # prove only that a Mutex is a Mutex. The seam spec carries the rest of the
  # weight, against a real PTY.
  describe "#typed?" do
    def editing(buffer)
      allow(Lain::Frontend::LineEditor).to receive(:typed?) { !buffer.empty? }
      allow(Reline).to receive(:readmultiline) do
        Reline.pre_input_hook&.call
        Async::Task.current.sleep(30)
      end
    end

    def typed_at_you(input)
      pumped(input) do |pump|
        task = Async::Task.current
        reading = task.async { rail.read(:you, "you> ") }
        pumped_until(task, reason: "you> published") { rail.published.kind == :you }
        settle_for(task, 0.05)
        [pump.typed?(rail.published), pump.typed?(rail.published.with(generation: 99))]
          .tap { reading.stop }
      end
    end

    it "is true of the you> it draws once something is typed there, and false of any other prompt" do
      editing(+"half a sent")

      expect(typed_at_you(terminal)).to eq([true, false])
    end

    it "is false while nothing is typed" do
      editing(+"")

      expect(typed_at_you(terminal).first).to be(false)
    end

    it "is false of the pump that reads no line" do
      expect(described_class::Idle.typed?(rail.published)).to be(false)
    end
  end

  describe "#exclusively" do
    let(:pump) do
      described_class.new(rail: Lain::Frontend::Intake.new(screen: Lain::Sink::Null.new),
                          screen: Lain::Sink::Null.new, input: StringIO.new)
    end

    it "holds the terminal for the length of the block, against another fiber of the same reactor" do
      order = []

      Sync do |task|
        holder = task.async do
          pump.exclusively { order.push(:entered) and sleep(0.05) and order.push(:left) }
        end
        task.sleep(0.01)
        pump.exclusively { order.push(:after) }
        holder.wait
      end

      expect(order).to eq(%i[entered left after])
    end

    it "tells the block it got the terminal" do
      expect(Sync { pump.exclusively { |held| held } }).to be(true)
    end

    # A withdrawal that never arrives must not park the borrower with the
    # countdown's words already drawn and no key doing anything: that is the
    # hang the bound turns back into a degradable refusal. The block still
    # runs -- it is told it is running unheld.
    it "gives up after its bound and tells the block it did not get the terminal" do
      answered = Sync do |task|
        holder = task.async { pump.exclusively { sleep(5) } }
        task.sleep(0.02)
        pump.exclusively(within: 0.05) { |held| held }.tap { holder.stop }
      end

      expect(answered).to be(false)
    end

    it "lets go again once the bound has passed, so a later borrower is not poisoned" do
      Sync do |task|
        holder = task.async { pump.exclusively { sleep(5) } }
        task.sleep(0.02)
        pump.exclusively(within: 0.05) { nil }
        holder.stop
        holder.wait
      rescue Async::Stop
        nil
      end

      expect(Sync { pump.exclusively { |held| held } }).to be(true)
    end
  end

  # Typed while nothing is published, where no read is open to take it. A
  # terminal cooks a line until Enter, so the pump waits on the descriptor and
  # takes only a whole line -- and never while the terminal is raw, which is the
  # countdown's window and its keys are not lines. Only a stop is acted on; the
  # rest waits where it always did, for the prompt that reads or sweeps it.
  describe "a line typed while nothing is published, over a real terminal", :seam do
    child = <<~'RUBY'
      require "lain"

      dir = ARGV.fetch(0)
      log = ->(text) { File.write(File.join(dir, "log"), "#{text}\n", mode: "a") }
      sink = Class.new do
        def initialize(log, dir) = (@log = log) && (@dir = dir)
        def signal(name) = @log.call("signal:#{name}")
        def ask_in_flight? = !File.exist?(File.join(@dir, "noask"))
      end.new(log, dir)
      tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, history_path: File.join(dir, "history"),
                                    state_path: File.join(dir, "state.json"), pastel: Pastel.new(enabled: false))
      rail = Lain::Frontend::Intake.new(screen: tty).route(sink)
      Sync do |task|
        pumping = Lain::Frontend::StdinPump.new(rail:, screen: tty).start(task)
        task.sleep(0.2)
        log.call("ready")
        task.sleep(0.02) until %w[raw quit].any? { |name| File.exist?(File.join(dir, name)) }
        if File.exist?(File.join(dir, "raw"))
          $stdin.raw!(intr: true)
          task.sleep(0.4)
          log.call("key:#{$stdin.read_nonblock(1, exception: false).inspect}")
          $stdin.cooked!
        end
        task.sleep(0.02) until File.exist?(File.join(dir, "quit"))
        if File.exist?(File.join(dir, "reads"))
          3.times { log.call("read:#{rail.read(:you, "you> ").inspect}") }
        else
          rail.gather
          log.call("held:#{[rail.take_held, rail.take_held].inspect}")
        end
        pumping.stop
      end
    RUBY

    warm_pool(:terminals) { WarmCockpit.terminal(prefix: "stdin-pump-typed", script: child) }

    let(:warm) { terminals.take }
    let(:dir) { warm.dir }

    def logged(dir) = File.exist?(File.join(dir, "log")) ? File.read(File.join(dir, "log")) : ""

    def await_log(dir, pattern)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
      sleep(0.02) until logged(dir).match?(pattern) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end

    it "delivers /stop as the signal it is and keeps every other line as typeahead, with no prompt open" do
      terminal = StdinPumpRaceTerminal.new(warm)
      await_log(dir, /ready/)
      terminal.type("hello\r")
      terminal.type("/stop\r")
      await_log(dir, /signal:stop/)
      FileUtils.touch(File.join(dir, "quit"))
      await_log(dir, /held:/)

      expect(logged(dir)).to include("signal:stop").and include('held:["hello", nil]')
    ensure
      terminal&.close
    end

    it "leaves a /stop the chat would not treat as one in the order it was typed" do
      FileUtils.touch(File.join(dir, "noask"))
      terminal = StdinPumpRaceTerminal.new(warm)
      await_log(dir, /ready/)
      terminal.type("hello\r")
      terminal.type("/stop\r")
      sleep(0.5)
      FileUtils.touch(File.join(dir, "quit"))
      await_log(dir, /held:/)

      expect(logged(dir)).to include('held:["hello", "/stop"]')
      expect(logged(dir)).not_to include("signal:stop")
    ensure
      terminal&.close
    end

    it "reads lines typed one at a time and a pasted pair at the next prompts, in order, once each" do
      FileUtils.touch(File.join(dir, "reads"))
      terminal = StdinPumpRaceTerminal.new(warm)
      await_log(dir, /ready/)
      terminal.type("one\r")
      sleep(0.3)
      terminal.type("two\rthree\r")
      sleep(0.5)
      FileUtils.touch(File.join(dir, "quit"))
      await_log(dir, /(?:read:.*\n){3}/)

      expect(logged(dir).scan(/read:("[^"]*"|nil)/).flatten).to eq(["\"one\"", "\"two\"", "\"three\""])
    ensure
      terminal&.close
    end

    it "leaves a key typed under a raw window to the window, and takes it as no line" do
      terminal = StdinPumpRaceTerminal.new(warm)
      await_log(dir, /ready/)
      FileUtils.touch(File.join(dir, "raw"))
      sleep(0.2)
      terminal.type("c")
      await_log(dir, /key:/)
      FileUtils.touch(File.join(dir, "quit"))
      await_log(dir, /held:/)

      expect(logged(dir)).to include('key:"c"').and include("held:[nil, nil]")
    ensure
      terminal&.close
    end
  end

  # A console the pump can wait on, that says how many waits are open on it.
  describe "the reader it runs while nothing is published" do
    let(:console) do
      Class.new do
        attr_reader :waiting

        def initialize(io) = (@io = io) && (@waiting = 0)
        def tty? = true
        def echo? = true
        def read_nonblock(*args, **opts) = @io.read_nonblock(*args, **opts)

        def wait_readable
          @waiting += 1
          @io.wait_readable
        ensure
          @waiting -= 1
        end
      end.new(pipe.first)
    end
    let(:pipe) { IO.pipe }

    after { pipe.each(&:close) }

    it "is gone once a prompt is published, and back when it is withdrawn" do
      allow(Reline).to receive(:readmultiline) do
        Async::Task.current.sleep(0.05)
        "hi"
      end
      seen = []
      pumped(console) do
        Async::Task.current.sleep(0.05)
        seen << console.waiting
        reading = Async::Task.current.async { rail.read(:you, "you> ") }
        Async::Task.current.sleep(0.02)
        seen << console.waiting
        reading.wait
        Async::Task.current.sleep(0.05)
        seen << console.waiting
      end

      expect(seen).to eq([1, 0, 1])
    end
  end

  describe "a line typed mid-ask that the terminal's line buffer may have cut" do
    let(:pipe) { IO.pipe }
    let(:console) do
      Class.new do
        def initialize(io) = @io = io
        def tty? = true
        def echo? = true
        def read_nonblock(*args, **opts) = @io.read_nonblock(*args, **opts)
        def wait_readable = @io.wait_readable
      end.new(pipe.first)
    end

    after { pipe.each(&:close) }

    def typed_mid_ask(text)
      pumped(console) do |pump|
        pipe.last.write("#{text}\r")
        Async::Task.current.sleep(0.2)
        pump.sweep
      end
    end

    it "does not hold a line of 4095 bytes, and says the terminal cut it and to paste it at the idle prompt" do
      typed_mid_ask("a" * 4095)

      expect(rail.take_held).to be_nil
      expect(output.string).to include("cut by the terminal").and include("idle prompt")
    end

    it "holds a line of 4094 bytes, one under the cut" do
      typed_mid_ask("a" * 4094)

      expect(rail.take_held).to eq("a" * 4094)
      expect(output.string).not_to include("cut by the terminal")
    end

    it "holds a line of 200 bytes as typeahead and says nothing" do
      typed_mid_ask("a" * 200)

      expect(rail.take_held).to eq("a" * 200)
      expect(output.string).not_to include("cut by the terminal")
    end
  end

  describe "prose typed mid-run while an ask is in flight, with notes to the agent" do
    let(:pipe) { IO.pipe }
    let(:console) do
      Class.new do
        def initialize(io) = @io = io
        def tty? = true
        def echo? = true
        def read_nonblock(*args, **opts) = @io.read_nonblock(*args, **opts)
        def wait_readable = @io.wait_readable
      end.new(pipe.first)
    end
    let(:store) { Lain::Dag::Factory.store }
    let(:mailbox) do
      Lain::Context::Mailbox::Live.new(recipient: Lain::EventLog::ChainWriter.method(:correlation_of),
                                       observer: lambda { |_|
                                       })
    end
    let(:notes) { Lain::CLI::HumanNotes.new(mailbox:, in_flight: -> { true }) }
    let(:timeline) do
      Lain::Dag::Factory.timeline(store:).commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
    end

    after { pipe.each(&:close) }

    def typed_mid_run(text, settled: -> { output.string.include?("note for the agent") })
      pump = described_class.new(rail:, screen:, input: console, notes:)
      Sync do |task|
        pumping = pump.start(task)
        pipe.last.write(text)
        pumped_until(task, reason: "the line taken off the terminal", &settled)
        pump.sweep
      ensure
        pumping&.stop
      end
    end

    def noted = mailbox.capture(timeline).pending.map { |note| note.body.fetch("text") }

    it "posts the line as a note, says so, and does not put it back as typeahead" do
      typed_mid_run("prefer Syncthing\r")

      expect([rail.take_held, noted]).to eq([nil, ["prefer Syncthing"]])
      expect(output.string).to include("note for the agent: prefer Syncthing")
    end

    # The reader also runs between a prompt's read ending and its withdrawal, and
    # a line it finishes then is the published prompt's, never a note.
    it "keeps a line as typeahead, posting no note, while a human> prompt is published" do
      allow(rail).to receive(:published)
        .and_return(Lain::Frontend::Intake::Prompt.new(kind: :human, text: "human> ", generation: 0))
      typed = [false]
      allow(rail).to receive(:lifts?).and_wrap_original do |original, value|
        original.call(value).tap { typed[0] = true }
      end

      typed_mid_run("prefer Syncthing\r", settled: -> { typed.first })

      expect([rail.take_held, noted]).to eq(["prefer Syncthing", []])
      expect(output.string).not_to include("note for the agent")
    end

    it "still keeps a slash command as typeahead for the next prompt" do
      typed_mid_run("prefer Syncthing\r/model\r")

      expect([rail.take_held, rail.take_held, noted]).to eq(["/model", nil, ["prefer Syncthing"]])
    end
  end

  describe "#keep" do
    it "hands a partial line to the next sweep, which joins it to the rest" do
      allow(Lain::Frontend::LineEditor).to receive(:typed_ahead).and_return("ial\r")

      pumped(terminal) do |pump|
        pump.keep("part")
        rail.gather
      end

      expect(rail.take_held).to eq("partial")
    end
  end

  describe Lain::Frontend::StdinPump::Typeahead::Typed, ".from" do
    it "takes a paste after a command as one line with no markers" do
      typed = described_class.from("/research-epic \e[200~para one\npara two\n\e[201~\r")

      expect([typed.lines, typed.partial]).to eq([["/research-epic para one\npara two"], ""])
    end

    it "keeps a paste still arriving in the partial, markers and all" do
      typed = described_class.from("\e[200~a\nb")

      expect([typed.lines, typed.partial]).to eq([[], "\e[200~a\nb"])
    end

    it "leaves a typed U+10FFFF alone as text" do
      typed = described_class.from("a\u{10FFFF}b\r")

      expect(typed.lines).to eq(["a\u{10FFFF}b"])
    end

    it "keeps the lines typed before and after a paste" do
      typed = described_class.from("one\r\e[200~x\ny\e[201~\rtwo\r")

      expect(typed.lines).to eq(%W[one x\ny two])
    end
  end

  describe Lain::Frontend::StdinPump::Typeahead::Typed, "counting the terminal's cut" do
    it "refuses a whole paste when one of its raw lines reaches the cut, and reads the next line normally" do
      typed = described_class.from("\e[200~short\n#{"a" * 4095}\rnext\r")

      expect([typed.lines, typed.cut]).to eq([["next"], 1])
    end

    it "counts the marker bytes toward the cut" do
      typed = described_class.from("\e[200~#{"a" * 4089}\n\e[201~\r")

      expect([typed.lines, typed.cut]).to eq([[], 1])
    end

    it "refuses the line a cut paste began, typed prefix and all" do
      typed = described_class.from("/x \e[200~#{"a" * 4095}\rnext\r")

      expect([typed.lines, typed.cut]).to eq([["next"], 1])
    end

    it "keeps a paste whose raw lines are each under the cut though the whole is over it" do
      typed = described_class.from("\e[200~#{"a" * 4000}\n#{"a" * 4000}\n#{"a" * 4000}\e[201~\r")

      expect([typed.lines.map(&:bytesize), typed.cut]).to eq([[12_002], 0])
    end

    it "keeps a typed line between two cut pastes" do
      typed = described_class.from("pre\r\e[200~x\r#{"a" * 4095}\rkeep\r\e[200~y\r#{"b" * 4095}\r")

      expect([typed.lines, typed.cut]).to eq([%w[pre keep], 2])
    end

    it "closes a paste at its end marker, so a later cut line takes nothing before it" do
      typed = described_class.from("\e[200~a\rb\e[201~\r#{"c" * 4100}\rd\r")

      expect([typed.lines, typed.cut]).to eq([%W[a\nb d], 1])
    end

    it "keeps a line of 4094 bytes, one under the cut" do
      typed = described_class.from("#{"a" * 4094}\r")

      expect([typed.lines.map(&:bytesize), typed.cut]).to eq([[4094], 0])
    end
  end

  describe ".uncut" do
    let(:screen) { instance_double(Lain::Frontend::TTY, render_warning: nil) }

    it "says once that the terminal cut what it dropped, and returns the lines kept" do
      typed = Lain::Frontend::StdinPump::Typeahead::Typed.new(lines: ["kept"].freeze, partial: "", cut: 2)

      expect(described_class.uncut(typed, screen)).to eq(["kept"])
      expect(screen).to have_received(:render_warning).with(described_class::CUT_NOTICE).once
    end

    it "says nothing when nothing was cut" do
      typed = Lain::Frontend::StdinPump::Typeahead::Typed.new(lines: ["kept"].freeze, partial: "", cut: 0)

      expect(described_class.uncut(typed, screen)).to eq(["kept"])
      expect(screen).not_to have_received(:render_warning)
    end
  end

  describe ".keys" do
    it "offers the countdown one key at a time from the pump's terminal, and nothing from a stream" do
      keys = described_class.keys(StringIO.new("c"))

      expect([keys.tty?, keys.read_nonblock(1)]).to eq([false, "c"])
    end
  end

  describe ".bind_cycle" do
    let(:rail) { instance_double(Lain::Frontend::Intake, cycle: nil) }
    let(:screen) { instance_double(Lain::Frontend::TTY, render_warning: nil) }

    # Reline's config is process-wide and reads the developer's inputrc, so a key an
    # earlier example bound, or an inputrc owns, would make the bind refuse.
    around do |example|
      with_env("INPUTRC" => File.join(Dir.tmpdir, "lain-spec-no-such-inputrc")) do
        Reline.core.config.reset_variables
        Lain::Frontend::LineEditor.unbind_all
        example.run
      end
    end

    after do
      Reline.core.config.reset_variables
      Lain::Frontend::LineEditor.unbind_all
    end

    it "binds Shift+Tab by default" do
      described_class.bind_cycle(rail, screen)

      expect(Lain::Frontend::LineEditor).to be_bound("S-Tab")
    end

    it "binds the key it is given and leaves Shift+Tab unbound" do
      described_class.bind_cycle(rail, screen, "C-x")

      expect([Lain::Frontend::LineEditor.bound?("C-x"), Lain::Frontend::LineEditor.bound?("S-Tab")])
        .to eq([true, false])
    end
  end
end
