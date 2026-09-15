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
  def initialize(child, dir)
    @screen = +""
    @output, @input, @pid = PTY.spawn({ "TERM" => "xterm", "INPUTRC" => File.join(dir, "no-inputrc") },
                                      RbConfig.ruby, "-W0", "-I", File.expand_path("../../../lib", __dir__),
                                      "-e", child, dir)
    @output.winsize = [40, 120]
    @reader = Thread.new { pump }
  end

  attr_reader :screen

  def type(bytes) = @input.write(bytes)

  def await(pattern)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    sleep(0.02) until @screen.match?(pattern) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def close
    Process.kill("KILL", @pid)
    Process.wait(@pid)
    @reader.join(2)
  end

  private

  def pump
    loop do
      chunk = @output.readpartial(4096)
      @screen << chunk
      @input.write("\e[1;1R") if chunk.include?("\e[6n")
    end
  rescue IOError, Errno::EIO
    nil
  end
end

RSpec.describe Lain::Frontend::StdinPump do
  let(:output) { StringIO.new }
  let(:history_path) { File.join(@dir, "history") }
  let(:layers) { [] }
  let(:screen) do
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, pastel: Pastel.new(enabled: false), history_path:,
                            layers: -> { Lain::Mode::LayerSet.new(layers) })
  end
  let(:rail) { Lain::Frontend::InputRail.new(screen:) }

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

  def pumped(input)
    pump = described_class.new(rail:, screen:, input:)
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

    it "never writes a history file" do
      pumped(StringIO.new("plain line\n")) { rail.read(:you, "you> ") }

      expect(File.exist?(history_path)).to be(false)
    end

    # A forked child's `STDIN.reopen` puts back whatever its copy of the parent's
    # read buffer held by seeking the descriptor it shares, and a regular file's
    # offset is shared -- so a chat reading stdin buffered re-read its own
    # prompts after every mixlib call. The pump reads a private duplicate and
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
    it "hands the composed prompt to the line editor and answers with what was typed" do
      allow(Reline).to receive(:readmultiline).and_return("hi")

      expect(pumped(terminal) { rail.read(:you, "> ") }).to eq("hi")
      expect(Reline).to have_received(:readmultiline).with("> ", true)
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

    it "writes an accepted line to the history before the next prompt" do
      allow(Reline).to receive(:readmultiline).and_return("remember me")

      pumped(terminal) { rail.read(:you, "> ") }

      expect(File.read(history_path)).to eq("remember me\n")
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
  end

  # What was typed while nothing drew at all -- a standing goal drives turns with
  # no prompt open -- asked for between asks through {InputRail#gather}.
  describe "#sweep" do
    def typed(*sweeps) = allow(Lain::Frontend::LineEditor).to receive(:typed_ahead).and_return(*sweeps)

    it "holds each whole line typed so far, in the order typed, and says so" do
      typed("/goal off\rkeep going\r")

      pumped(terminal) { rail.gather }

      expect([rail.take_held, rail.take_held, rail.take_held]).to eq(["/goal off", "keep going", nil])
      expect(output.string).to include("held as your next prompt: /goal off")
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
        rail << Lain::Frontend::InputRail::Eof.new
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
    let(:child) do
      <<~'RUBY'
        require "lain"

        dir = ARGV.fetch(0)
        tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, history_path: File.join(dir, "history"),
                                      state_path: File.join(dir, "state.json"), pastel: Pastel.new(enabled: false))
        rail = Lain::Frontend::InputRail.new(screen: tty)
        Sync do |task|
          pumping = Lain::Frontend::StdinPump.new(rail:, screen: tty).start(task)
          3.times do
            line = rail.read(:you, "you> ")
            File.write(File.join(dir, "lines"), "#{line.inspect}\n", mode: "a")
            if line == "race"
              approval = task.async { rail.read(:approval, "[y/N] ") }
              task.sleep(0.02) until File.exist?(File.join(dir, "arm"))
              $stdin.wait_readable
              approval.stop
            end
          end
          pumping.stop
        end
      RUBY
    end

    # `n` typed at the drawn `[y/N]`, then Enter just after the child is told to
    # withdraw the prompt the moment Enter reaches its terminal.
    def race(dir)
      terminal = StdinPumpRaceTerminal.new(child, dir)
      terminal.await(/you> /)
      terminal.type("race\r")
      terminal.await(%r{\[y/N\] })
      terminal.type("n")
      sleep(0.3)
      FileUtils.touch(File.join(dir, "arm"))
      sleep(0.2)
      entered_then(terminal, dir)
    ensure
      terminal&.close
    end

    def entered_then(terminal, dir)
      terminal.type("\r")
      sleep(1.0)
      terminal.type("after\r")
      sleep(1.0)
      [File.readlines(File.join(dir, "lines"), chomp: true), terminal.screen]
    end

    it "never sends the line to you> unannounced" do
      3.times do
        Dir.mktmpdir do |dir|
          lines, screen = race(dir)

          expect(lines.first).to eq('"race"')
          expect(screen).to include("held as your next prompt: n") if lines.include?('"n"')
        end
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

  describe ".keys" do
    it "offers the countdown one key at a time from the pump's terminal, and nothing from a stream" do
      keys = described_class.keys(StringIO.new("c"))

      expect([keys.tty?, keys.read_nonblock(1)]).to eq([false, "c"])
    end
  end
end
