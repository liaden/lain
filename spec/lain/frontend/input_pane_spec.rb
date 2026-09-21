# frozen_string_literal: true

require "json"
require "socket"
require "stringio"
require "tmpdir"

# `lain input`'s object: the pane that draws what a chat publishes and sends
# back what the human typed. Driven against a REAL Unix socket with a scripted
# chat at the far end -- the pane's whole subject is a frame stream, and a
# doubled one would leave the reconnect and the goodbye untested.
#
# Off a terminal the local {Lain::Frontend::StdinPump} takes its streamed path,
# so a line arrives by writing it to `keyboard`. The countdown's key window is a
# terminal's, and belongs to the seam spec.
RSpec.describe Lain::Frontend::InputPane do
  subject(:pane) do
    described_class.new(path:, tty:, input: reader, commands:, layers:, tick: 0.01, geometry:)
  end

  let(:dir) { Dir.mktmpdir("lain-input-pane") }
  let(:path) { File.join(dir, "input.sock") }
  let(:server) { UNIXServer.new(path) }
  let(:screen) { StringIO.new }
  let(:commands) { [] }
  let(:layers) { [] }
  let(:tty) do
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: screen, pastel: Pastel.new(enabled: false),
                            history_path: File.join(dir, "history"), state_path: File.join(dir, "state.json"))
  end

  # The pane measures its geometry by ioctl off its terminal and a pipe has none,
  # so a window an example drives by hand stands in. SCRIPTED rather than simply
  # assignable, because what separates this poller from a naive one is what it
  # does with a RUN of sizes: each look takes the next, the last one stands, and
  # a scripted exception is the terminal going away. A window nobody scripts
  # never moves -- which is what the pane's own default over a pipe already is.
  let(:window) do
    Class.new do
      def initialize
        @current = [24, 80]
        @queue = []
      end

      def script(*sizes) = @queue.concat(sizes)

      def winsize
        @current = @queue.shift unless @queue.empty?
        raise @current if @current.is_a?(Class)

        @current
      end
    end.new
  end
  let(:geometry) { Lain::Frontend::InputPane::Geometry.new(window) }

  # The keyboard, as a pipe: what a spec writes to `keyboard` the pane reads.
  let(:pipe) { IO.pipe }
  let(:reader) { pipe.first }
  let(:keyboard) { pipe.last }

  before { server }

  after do
    @running&.kill
    server.close unless server.closed?
    pipe.each { |io| io.close unless io.closed? }
    FileUtils.remove_entry(dir)
  end

  # The pane in a thread of its own, and the chat's end of its connection. The
  # accept is BOUNDED: a pane that cannot construct dies in its thread and never
  # connects, and an unbounded accept turns that into a spec file that hangs
  # rather than one that fails -- which is neither a red nor a pass.
  def open_pane
    @running = Thread.new { pane.run }
    server.timeout = 5
    server.accept.tap { |chat| chat.timeout = 5 }
  end

  def publish(chat, frame)
    chat.write("#{JSON.generate({ "v" => "prompt", "kind" => "you", "text" => "you> ", "header" => "",
                                  "keys" => {}, "layers" => [], "generation" => 1 }.merge(frame))}\n")
    chat.flush
  end

  def say(chat, frame)
    chat.write("#{JSON.generate(frame)}\n")
    chat.flush
  end

  def next_frame(chat, of:)
    Enumerator.produce { JSON.parse(chat.gets.to_s) }.find { |frame| frame["v"] == of }
  end

  # Whatever the block answers once it stops answering nil, bounded so a pane
  # that never draws ends the example rather than the suite.
  def settles(within: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    Enumerator.produce { sleep(0.005) && yield }
              .find { |answer| !answer.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline }
  end

  it "draws the published prompt with the chat's header above it" do
    chat = open_pane
    publish(chat, { "header" => "🔥 fleet:1 inbox:0" })

    expect(settles { screen.string.include?("you> ") || nil }).to be(true)
    expect(screen.string).to include("🔥 fleet:1 inbox:0")
  end

  it "sends what the human typed as the answer to the prompt it was read at" do
    chat = open_pane
    publish(chat, { "generation" => 7 })
    settles { screen.string.include?("you> ") || nil }

    keyboard.puts("deploy the thing")

    expect(next_frame(chat, of: "line")).to eq({ "v" => "line", "text" => "deploy the thing", "generation" => 7 })
  end

  it "shows a new header at an untouched prompt with no keypress" do
    chat = open_pane
    publish(chat, { "header" => "ctx:10%" })
    settles { screen.string.include?("ctx:10%") || nil }

    publish(chat, { "header" => "ctx:42%" })

    expect(settles { screen.string.include?("ctx:42%") || nil }).to be(true)
  end

  # The fleet tree rides this same header, which is what makes it live: a
  # child's turn count moving republishes the prompt, so a pane sitting at an
  # untouched `you>` shows the new count with nothing typed at it.
  it "shows a fleet row's new turn count at an untouched prompt with no keypress" do
    chat = open_pane
    publish(chat, { "header" => "\u{1F525} fleet:1 inbox:0\n  dev  running  1t  4s  port the parser" })
    settles { screen.string.include?("1t") || nil }

    publish(chat, { "header" => "\u{1F525} fleet:1 inbox:0\n  dev  running  2t  9s  port the parser" })

    expect(settles { screen.string.include?("2t") || nil }).to be(true)
  end

  # Two bytes with no other witness, and that is why they are pinned here.
  # Dropping the ticking age took away the redraw that used to expose the
  # dirty cursor, so a real pane now looks identical with and without them --
  # but the cursor is still wherever the read this frame replaced left it, and
  # every prompt that draws before a header does puts it mid-row. This is the
  # one place that can say the row is taken back first.
  it "takes the row back before it prints the header, so a drawn prompt cannot share it" do
    chat = open_pane
    publish(chat, { "header" => "\u2744 fleet:1 inbox:0" })

    settles { screen.string.include?("fleet:1 inbox:0") || nil }

    expect(screen.string).to include("#{described_class::CLEAR_ROW}\u2744 fleet:1 inbox:0\n")
  end

  # A squeezed cockpit window is put back to the pane's row floor by tmux's own
  # `window-layout-changed` hook, and that hook is a bare `resize-pane`: it
  # tells nothing to draw again. The frame the chat would republish is
  # byte-identical, so the chat's latch drops it and the pane's own dedupe would
  # drop it too -- which leaves the pane's geometry as the only witness that
  # anything happened.
  describe "a pane whose own geometry moved" do
    let(:hud) { "❄ fleet:1 inbox:0" }

    # Counted through the row-clearing bytes, so a repaint that bypassed the one
    # writer would not be counted as a repaint at all.
    def hud_prints = screen.string.scan("#{described_class::CLEAR_ROW}#{hud}\n").size

    def showing_hud(chat)
      publish(chat, { "header" => hud })
      settles { hud_prints.positive? || nil }
    end

    it "draws the HUD again once the geometry settles, with nothing typed" do
      chat = open_pane
      showing_hud(chat)

      window.script([6, 80])

      expect(settles { hud_prints > 1 || nil }).to be(true)
    end

    # THE GESTURE THE WHOLE THING EXISTS FOR, and the one a poller is likeliest
    # to miss: squeeze the cockpit window past the pane's floor and the hook puts
    # it back, so the pane ENDS AT THE SIZE IT STARTED FROM with its header
    # scrolled off. Comparing against the last size repainted at makes that round
    # trip invisible; remembering that something moved does not.
    it "draws the HUD again after a squeeze and restore that ends where it started" do
      chat = open_pane
      showing_hud(chat)

      window.script([6, 80], [24, 80])

      expect(settles { hud_prints > 1 || nil }).to be(true)
    end

    # The settle half of the rule, which nothing else pins: a drag arrives as a
    # RUN of sizes and each repaint costs a six-row pane a row, so the run is
    # worth exactly one repaint, at its end. A poller that acted on the first
    # look that differed would draw four times here.
    it "repaints once at the end of a drag, not once per size it passes through" do
      chat = open_pane
      showing_hud(chat)
      drawn = hud_prints

      window.script([20, 80], [16, 80], [12, 80], [6, 80])
      settles { hud_prints > drawn || nil }
      sleep(0.2)

      expect(hud_prints).to eq(drawn + 1)
    end

    # The clock moving under a running fleet is what this pane spends its life
    # doing, and a poller that repainted on the tick rather than on the edge
    # cost a six-row pane a row per second.
    it "repaints nothing while the geometry holds still" do
      chat = open_pane
      showing_hud(chat)
      drawn = hud_prints

      sleep(0.3)

      expect(hud_prints).to eq(drawn)
    end

    # A look that cannot answer is no information, not a new size. Read as one,
    # a terminal going away is two same-sized looks after a differing one, which
    # is the settle rule's own shape -- so a dying tty earned itself exactly one
    # repaint, into a write on the descriptor that had just gone.
    it "repaints nothing when its terminal goes away under it" do
      chat = open_pane
      showing_hud(chat)
      drawn = hud_prints

      window.script(Errno::ENOTTY)
      sleep(0.3)

      expect(hud_prints).to eq(drawn)
    end
  end

  it "takes commands it completes against from the chat, holding no registry" do
    chat = open_pane
    say(chat, { "v" => "context", "commands" => %w[approve inbox] })

    expect(settles { commands == %w[approve inbox] || nil }).to be(true)
  end

  it "takes the layers its editor works under from the chat" do
    chat = open_pane
    publish(chat, { "layers" => %w[vi] })

    expect(settles { layers == %i[vi] || nil }).to be(true)
  end

  it "ends the chat's read when the human closes the keyboard" do
    chat = open_pane
    publish(chat, {})
    settles { screen.string.include?("you> ") || nil }

    keyboard.close

    expect(next_frame(chat, of: "eof")).to eq({ "v" => "eof" })
  end

  it "reconnects to the same path when the chat restarts" do
    first = open_pane
    publish(first, {})
    settles { screen.string.include?("you> ") || nil }
    first.close

    second = settles { server.accept }
    say(second, { "v" => "context", "commands" => %w[stop] })

    expect(settles { commands == %w[stop] || nil }).to be(true)
  end

  # `/stop` leaves the pane as the LINE the human typed. Nothing behind this
  # rail is running an ask -- the pane holds no agent and no session -- so the
  # chat's own rail is the one that knows whether there is a run to stop, and
  # a pane that decided here would send a stop to a chat with nothing to stop.
  it "sends /stop typed at a parked prompt as a line, leaving the chat's rail to decide" do
    chat = open_pane
    publish(chat, { "kind" => "human", "text" => "[y/N] run bash? ", "generation" => 7 })
    settles { screen.string.include?("[y/N] run bash?") || nil }

    keyboard.write("/stop\n")

    expect(next_frame(chat, of: "line")).to eq({ "v" => "line", "text" => "/stop", "generation" => 7 })
  end

  it "draws the countdown the chat published, keys and all" do
    chat = open_pane
    publish(chat, { "kind" => "countdown", "text" => "closing in 30s -- [c] cancel  [w] wait longer",
                    "keys" => { "c" => "cancel" } })

    expect(settles { screen.string.include?("[c] cancel") || nil }).to be(true)
  end

  # `lain up` starts both panes at once, so waiting for a chat that has not
  # bound yet is ordinary. Being unable to SAY so, or to quit, is not -- and a
  # typo'd --socket and a chat that failed to start look exactly like it.
  describe "a pane with no chat to talk to" do
    around do |example|
      saved = Lain::CLI::Signals::MAP.keys.to_h { |name| [name, Signal.trap(name) { nil }] }
      example.run
    ensure
      saved.each { |name, handler| Signal.trap(name, handler) }
    end

    before do
      server.close
      FileUtils.rm_f(path)
    end

    it "says what it is waiting for without claiming the screen, and leaves when told to" do
      @running = Thread.new { pane.run }
      settles { screen.string.include?("waiting for a lain chat on #{path}") || nil }
      painted = screen.string

      Process.kill("TERM", Process.pid)

      expect([@running.join(5)&.value, painted.include?("\e[?1049h")]).to eq([0, false])
    end
  end

  describe "a signal the human sends the pane" do
    # The pane's own traps are installed for the length of its run; these save
    # and restore the runner's around them, independent of the code under test,
    # so a bug in the pane can never leave the suite without an INT handler.
    around do |example|
      saved = Lain::CLI::Signals::MAP.keys.to_h { |name| [name, Signal.trap(name) { nil }] }
      example.run
    ensure
      saved.each { |name, handler| Signal.trap(name, handler) }
    end

    it "goes to the chat rather than interrupting the pane" do
      chat = open_pane
      publish(chat, {})
      settles { screen.string.include?("you> ") || nil }

      Process.kill("INT", Process.pid)

      expect(next_frame(chat, of: "signal")).to eq({ "v" => "signal", "name" => "sigint" })
    end
  end

  it "exits when the chat closes cleanly" do
    chat = open_pane
    say(chat, { "v" => "closed" })

    expect(settles { @running.join(5) && @running.value }).to eq(0)
  end

  # The whole raw window belongs to the seam spec, which drives a real PTY.
  # What is answerable here is the ordering the seam proved necessary -- the
  # terminal is taken FROM the pump that owns it, so a read still unwinding
  # cannot put its own mode back over the countdown's -- and what happens when
  # the pump will not hand it over.
  describe Lain::Frontend::InputPane::Keys do
    let(:console) do
      Class.new(StringIO) do
        attr_reader :raw_calls

        def initialize = super.tap { @raw_calls = 0 }

        def tty? = true

        def console_mode = :cooked

        def console_mode=(_mode)
          nil
        end

        def raw!(**) = @raw_calls += 1
      end.new
    end

    # Records BOTH doors a degraded window could use, so an example can say
    # which one carried the sentence rather than only that something did.
    let(:screen) do
      Class.new do
        attr_reader :printed, :noted

        def initialize
          @printed = []
          @noted = []
        end

        def print_prompt(text) = @printed << text

        def render_warning(message) = @noted << message
      end.new
    end

    # The window never returns on its own -- it is stopped with the countdown
    # -- so an example runs it under a task it stops itself.
    def offered(terminal)
      Sync do |task|
        window = task.async do
          described_class.new(input: console, tick: 0.01, terminal:).offering(screen, "closing in 3s")
        end
        task.sleep(0.05)
        window.stop
      end
    end

    # A pump that grants the hold, and remembers what the terminal's mode had
    # been switched to by the time it did -- which must be nothing.
    def granting(held)
      Class.new do
        attr_reader :switches_before

        def initialize(console, held) = (@console = console) && (@held = held)

        def exclusively(**)
          @switches_before = @console.raw_calls
          yield(@held)
        end
      end.new(console, held)
    end

    it "switches the terminal's mode only once the pump has handed it over" do
      pump = granting(true)

      offered(pump)

      expect([pump.switches_before, console.raw_calls,
              screen.printed.select { |text| text.include?(described_class::UNHELD) }]).to eq([0, 1, []])
    end

    # A hold the pump never grants would otherwise leave the countdown's words
    # drawn and no key doing anything -- the hang the bounded wait exists to
    # turn back into a window that still reads, and says why it is degraded.
    # PRINTED, not noted, and the difference is the whole point: {TTY::Notes}
    # holds a note while another fiber's prompt is open, which is this path's
    # own premise -- so a noted sentence reaches the human only once the read
    # it was explaining has ended.
    it "prints the degraded warning rather than noting it, so it is not held behind the open read" do
      offered(granting(false))

      expect([console.raw_calls, screen.printed.last, screen.noted]).to eq([1, "#{described_class::UNHELD}\n", []])
    end

    # The degraded window really can lose the key -- it switches raw while the
    # editor is still reading the same descriptor -- so the sentence has to
    # ask for the press again rather than merely explain itself.
    it "tells the human the key may be lost and to press it again" do
      expect(described_class::UNHELD).to include("swallowed").and include("press it again")
    end
  end
end
