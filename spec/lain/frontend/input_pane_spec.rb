# frozen_string_literal: true

require "json"
require "pty"
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

      def looked? = @queue.empty?

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
    raise("pane thread outlived its example") unless @running.nil? || @running.kill.join(5)

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

  # A real signal, but only once the installed handler is the pane's own: a
  # runner's non-Proc handler would otherwise turn the kill into a process exit.
  def deliver(name)
    handler = Signal.trap(name) { nil }
    Signal.trap(name, handler)
    raise "the pane's #{name} handler is #{handler.inspect}, not a Proc" unless handler.is_a?(Proc)

    Process.kill(name, Process.pid)
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

  # The idle reader turns bracketed paste on only once the terminal's mode is its own.
  def uncooked(master)
    paste_on = described_class::Uncooked::PASTE_ON
    Enumerator.produce(+"") { |seen| seen << pty_read(master, 1) }.find { |seen| seen.end_with?(paste_on) }
  end

  it "hands its pump the approval key it was given" do
    made = []
    allow(Lain::Frontend::StdinPump).to(receive(:new).and_wrap_original { |new, **kw| (made << kw) && new.call(**kw) })
    keyed = described_class.new(path:, tty:, input: reader, commands:, layers:, tick: 0.01, geometry:, cycle_key: "C-x")
    @running = Thread.new { keyed.run }
    server.timeout = 5
    server.accept.tap { |chat| chat.timeout = 5 }

    expect(settles { made.first&.fetch(:cycle_key) }).to eq("C-x")
  end

  it "reads the approval key from the user's config when opened" do
    paths = Lain::Paths.new(env: { "HOME" => dir, "XDG_CONFIG_HOME" => File.join(dir, "config") })
    FileUtils.mkdir_p(File.dirname(paths.user_config))
    File.write(paths.user_config, "keys approval_cycle: \"s-tab\"\n")
    Lain::Project::Trust.for_user(paths:).grant!
    made = []
    allow(Lain::Frontend::StdinPump).to(receive(:new).and_wrap_original { |new, **kw| (made << kw) && new.call(**kw) })
    opened = described_class.open(path:, input: reader, output: screen, paths:, history_path: File.join(dir, "h"),
                                  state_path: File.join(dir, "s.json"), pastel: Pastel.new(enabled: false))
    @running = Thread.new { opened.run }
    server.timeout = 5
    server.accept.tap { |chat| chat.timeout = 5 }

    expect(settles { made.first&.fetch(:cycle_key) }).to eq("s-tab")
  end

  it "draws the published prompt with the chat's header above it" do
    chat = open_pane
    publish(chat, { "header" => "🔥 fleet:1 inbox:0" })

    expect(settles { screen.string.include?("you> ") || nil }).to be(true)
    expect(screen.string).to include("🔥 fleet:1 inbox:0")
  end

  it "tells the human at an empty you> prompt how to write more than 1 line" do
    chat = open_pane
    publish(chat, {})

    expect(settles { screen.string.include?("you> ") || nil }).to be(true)
    expect(screen.string).to include("Shift+Enter").and include("Alt+Enter")
  end

  it "keeps the multi-line hint off a prompt that is not you>" do
    chat = open_pane
    publish(chat, { "kind" => "human", "text" => "[y/N] run bash? " })

    expect(settles { screen.string.include?("[y/N]") || nil }).to be(true)
    expect(screen.string).not_to include("Shift+Enter")
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

  it "rewrites a ticking 1-row header in place at an idle prompt, stacking no rows" do
    chat = open_pane
    publish(chat, { "header" => "model:0s" })
    settles { screen.string.include?("model:0s") || nil }
    screen.truncate(0) && screen.rewind

    (1..5).each do |tick|
      publish(chat, { "header" => "model:#{tick}s" })
      settles { screen.string.include?("model:#{tick}s") || nil }
    end

    in_place = (1..5).map { |tick| "\e7\e[1A\r\e[Kmodel:#{tick}s\n\e8" }.join
    expect(screen.string).to eq(in_place)
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

    it "takes the old header back before drawing it again after a resize" do
      chat = open_pane
      showing_hud(chat)
      screen.truncate(0) && screen.rewind

      window.script([6, 80])

      expect(settles { hud_prints.positive? ? screen.string : nil }).to start_with("\e[1A\r\e[J")
    end

    # Regression guard: nothing is drawn at idle (no frame is held), so this holds without the fix.
    it "stacks no 2nd header under the 1st after a resize at true idle" do
      chat = open_pane
      showing_hud(chat)
      say(chat, { "v" => "unpublished", "header" => hud })
      say(chat, { "v" => "context", "commands" => ["idle"] })
      settles { commands == ["idle"] || nil }
      drawn = hud_prints

      window.script([6, 80])
      sleep(0.3)

      expect(hud_prints).to eq(drawn)
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

  # An ask in flight publishes nothing, and a pane that took nothing then had no
  # way to send the human's `/stop` or `/goal off` until the ask was over. The
  # keyboard here is a real terminal's slave side: only a console can be cooked.
  describe "while a prompt is up" do
    let(:pty) { PTY.open }
    let(:reader) { pty.last }
    let(:keyboard) { pty.first }

    after { pty.each { |io| io.close unless io.closed? } }

    it "redraws a header that grew a row over the old one at a prompt with nothing typed" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "fleet:1" })
      settles { screen.string.include?("fleet:1") || nil }
      screen.truncate(0) && screen.rewind

      publish(chat, { "generation" => 3, "header" => "fleet:2\nrow b" })

      expect(settles { screen.string.include?("row b") ? screen.string : nil })
        .to start_with("\e[1A\r\e[J").and include("\r\e[Kfleet:2\nrow b\n")
    end

    it "redraws a header that lost a row over the old rows at a prompt with nothing typed" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "fleet:2\nrow b" })
      settles { screen.string.include?("row b") || nil }
      screen.truncate(0) && screen.rewind

      publish(chat, { "generation" => 3, "header" => "fleet:1" })

      expect(settles { screen.string.include?("fleet:1") ? screen.string : nil })
        .to start_with("\e[2A\r\e[J").and include("\r\e[Kfleet:1\n")
    end

    it "draws a header that arrived right after a prompt drawn with none" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "" })
      publish(chat, { "generation" => 3, "header" => "model:1s" })

      expect(settles { screen.string.include?("model:1s") || nil }).to be(true)
    end

    it "draws only the newer prompt once the draft a header was held over is gone" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      settles { screen.string.include?("model:0s") || nil }
      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(false)
      Enumerator.produce { next_frame(chat, of: "touch") }.find { |touch| !touch["untouched"] }
      publish(chat, { "generation" => 3, "header" => "model:1s" })
      publish(chat, { "generation" => 4, "header" => "model:2s" })
      settles { screen.string.include?("model:2s") || nil }
      screen.truncate(0) && screen.rewind

      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(true)
      Enumerator.produce { next_frame(chat, of: "touch") }.find { |touch| touch["untouched"] }
      sleep(0.1)

      expect(screen.string).to eq("")
    end

    it "repaints the header it held, not the one it replaced, once a resize behind a draft can be drawn" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      settles { screen.string.include?("model:0s") || nil }
      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(false)
      Enumerator.produce { next_frame(chat, of: "touch") }.find { |touch| !touch["untouched"] }
      window.script([6, 80], [6, 80])
      settles { window.looked? || nil }
      publish(chat, { "generation" => 3, "header" => "model:1s" })
      say(chat, { "v" => "context", "commands" => ["after"] })
      settles { commands == ["after"] || nil }
      screen.truncate(0) && screen.rewind

      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(true)

      expect(settles { screen.string.include?("model:") ? screen.string : nil })
        .to eq("\e[1A\r\e[J\r\e[Kmodel:1s\n")
    end

    it "leaves a draft alone when the header changes row count" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "fleet:1" })
      settles { screen.string.include?("fleet:1") || nil }
      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(false)
      Enumerator.produce { next_frame(chat, of: "touch") }.find { |touch| !touch["untouched"] }
      screen.truncate(0) && screen.rewind

      publish(chat, { "generation" => 3, "header" => "fleet:2\nrow b" })
      say(chat, { "v" => "context", "commands" => ["after"] })
      settles { commands == ["after"] || nil }

      expect(screen.string).to eq("")
    end
  end

  describe "a fleet row wider than the pane" do
    let(:pty) { PTY.open }
    let(:reader) { pty.last }
    let(:keyboard) { pty.first }
    let(:row) { "  dev  running  3t  #{"x" * 90}" }

    after { pty.each { |io| io.close unless io.closed? } }

    def drawn_with(columns)
      reader.winsize = [24, columns]
      chat = open_pane
      publish(chat, { "header" => "fleet:1\n#{row}" })
      settles { screen.string.include?("fleet:1") || nil }
      screen.string
    end

    it "draws the whole row in a pane wide enough for it" do
      expect(drawn_with(120)).to include(row)
    end

    it "cuts the row at the pane's width in a narrower one" do
      drawn = drawn_with(60)

      expect(drawn).to include("#{row[0, 59]}\u2026")
      expect(drawn).not_to include(row)
    end

    it "leaves the first line alone however narrow the pane" do
      expect(drawn_with(5)).to include("fleet:1")
    end
  end

  describe "when the chat says nothing is published" do
    let(:pty) { PTY.open }
    let(:reader) { pty.last }
    let(:keyboard) { pty.first }

    after { pty.each { |io| io.close unless io.closed? } }

    # Frames are handled in order on the pane's one reactor, so a frame after
    # "unpublished" that has taken effect proves the withdrawal was handled. It
    # does not prove the idle reader has the terminal: that waits for the
    # withdrawn read to give the pump's lock back, and a key typed before then
    # meets a cooked terminal that echoes it.
    def unpublished(chat)
      publish(chat, { "generation" => 3 })
      say(chat, { "v" => "unpublished" })
      say(chat, { "v" => "context", "commands" => ["idle"] })
      expect(settles { commands == ["idle"] || nil }).to be(true)
      uncooked(keyboard)
    end

    # A "touch" report for the prompt drawn before the withdrawal may already be
    # waiting, so silence is judged on the lines sent, not on the socket.
    def sent_so_far(chat)
      waiting = chat.read_nonblock(65_536, exception: false)
      waiting.is_a?(String) ? waiting.lines.map { |line| JSON.parse(line) } : []
    end

    # The pane echoes what its idle reader took, so the echo is the read.
    def taken(typed)
      settles { screen.string.end_with?(typed) || nil } || raise("the idle reader read nothing")
    end

    it "redraws a changed header over its own rows and returns the cursor, without touching the input row" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "fleet:1\nrow a" })
      settles { screen.string.include?("row a") || nil }
      say(chat, { "v" => "unpublished", "header" => "fleet:1\nrow a" })
      say(chat, { "v" => "context", "commands" => ["idle"] })
      settles { commands == ["idle"] || nil }
      screen.truncate(0) && screen.rewind

      say(chat, { "v" => "unpublished", "header" => "fleet:2\nrow b" })

      expect(settles { screen.string.include?("row b") ? screen.string : nil })
        .to eq("\e7\e[2A\r\e[Kfleet:2\n\r\e[Krow b\n\e8")
    end

    # The pane holds the idle draft itself, so the input row is its own to clear and redraw.
    it "redraws a header that grew a row while a child runs, taking the old row back first" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "fleet:1" })
      settles { screen.string.include?("fleet:1") || nil }
      say(chat, { "v" => "unpublished", "header" => "fleet:1" })
      say(chat, { "v" => "context", "commands" => ["idle"] })
      settles { commands == ["idle"] || nil }
      screen.truncate(0) && screen.rewind

      say(chat, { "v" => "unpublished", "header" => "fleet:2\nrow b" })

      expect(settles { screen.string.include?("row b") ? screen.string : nil })
        .to eq("\e[1A\r\e[J\r\e[Kfleet:2\nrow b\n")
    end

    it "puts a draft typed while a child runs back under a header of another row count, and Enter sends it" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "fleet:1" })
      settles { screen.string.include?("fleet:1") || nil }
      say(chat, { "v" => "unpublished", "header" => "fleet:1" })
      say(chat, { "v" => "context", "commands" => ["idle"] })
      settles { commands == ["idle"] || nil }
      keyboard.write("abc")
      settles { screen.string.end_with?("abc") || nil }
      screen.truncate(0) && screen.rewind

      say(chat, { "v" => "unpublished", "header" => "fleet:2\nrow b" })
      redrawn = settles { screen.string.include?("row b") ? screen.string.dup : nil }
      keyboard.write("\r")

      expect([redrawn, next_frame(chat, of: "line")])
        .to eq(["\e[1A\r\e[J\r\e[Kfleet:2\nrow b\nabc", { "v" => "line", "text" => "abc", "generation" => 0 }])
    end

    it "keeps the HUD live after a sent line, drawing it once and then rewriting it in place" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "fleet:1" })
      settles { screen.string.include?("fleet:1") || nil }
      say(chat, { "v" => "unpublished", "header" => "fleet:1" })
      say(chat, { "v" => "context", "commands" => ["idle"] })
      settles { commands == ["idle"] || nil }
      keyboard.write("/stop\r")
      next_frame(chat, of: "line")
      screen.truncate(0) && screen.rewind

      say(chat, { "v" => "unpublished", "header" => "fleet:2" })
      settles { screen.string.include?("fleet:2") || nil }
      say(chat, { "v" => "unpublished", "header" => "fleet:3" })

      expect(settles { screen.string.include?("fleet:3") ? screen.string : nil })
        .to eq("\r\e[Kfleet:2\n\e7\e[1A\r\e[Kfleet:3\n\e8")
    end

    it "rewrites the header in place below an answered approval's echo, and redraws whole at the next prompt" do
      # A real pty read of the answer timed out here, so the echo itself is not exercised.
      allow(Reline).to receive(:readmultiline).and_return("y", nil)
      chat = open_pane
      publish(chat, { "kind" => "human", "text" => "[y/N] run bash? ", "generation" => 7,
                      "header" => "fleet:1\nrow a" })
      next_frame(chat, of: "line")
      say(chat, { "v" => "unpublished", "header" => "fleet:1\nrow a" })
      settles { screen.string.scan("\r\e[Kfleet:1\nrow a\n").size == 2 || nil }
      screen.truncate(0) && screen.rewind

      say(chat, { "v" => "unpublished", "header" => "fleet:2\nrow b" })
      say(chat, { "v" => "context", "commands" => ["after"] })
      in_place = "\e7\e[2A\r\e[Kfleet:2\n\r\e[Krow b\n\e8"
      expect(settles { screen.string.empty? ? nil : screen.string }).to eq(in_place)
      settles { commands == ["after"] || nil }
      screen.truncate(0) && screen.rewind

      publish(chat, { "generation" => 8, "header" => "fleet:2\nrow b" })
      hint = "\r\e[K#{described_class::MULTILINE_HINT}\n"
      expect(settles { screen.string.include?("row b") ? screen.string : nil })
        .to eq("\e[2A#{hint}\r\e[Kfleet:2\nrow b\n")
    end

    it "keeps the HUD live below an answered line's echo, drawing it once and then rewriting it in place" do
      allow(Reline).to receive(:readmultiline).and_return("list the files", nil)
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      next_frame(chat, of: "line")
      say(chat, { "v" => "unpublished", "header" => "model:1s" })
      expect(settles { screen.string.end_with?("\r\e[Kmodel:1s\n") || nil }).to be(true)

      say(chat, { "v" => "unpublished", "header" => "model:4s" })

      expect(settles { screen.string.end_with?("\e7\e[1A\r\e[Kmodel:4s\n\e8") || nil }).to be(true)
      expect(screen.string.scan("model:1s").size).to eq(1)
    end

    it "writes nothing over any draft in the editor, wrapped or not" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      settles { screen.string.include?("model:0s") || nil }
      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(false)
      Enumerator.produce { next_frame(chat, of: "touch") }.find { |touch| !touch["untouched"] }
      screen.truncate(0) && screen.rewind

      publish(chat, { "generation" => 3, "header" => "model:1s" })
      say(chat, { "v" => "context", "commands" => ["after"] })
      settles { commands == ["after"] || nil }

      expect(screen.string).to eq("")
    end

    it "writes nothing over a 1-character draft either, since the row count cannot be read" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      settles { screen.string.include?("model:0s") || nil }
      keyboard.write("x")
      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(false)
      Enumerator.produce { next_frame(chat, of: "touch") }.find { |touch| !touch["untouched"] }
      screen.truncate(0) && screen.rewind

      publish(chat, { "generation" => 3, "header" => "model:1s" })
      say(chat, { "v" => "context", "commands" => ["after"] })
      settles { commands == ["after"] || nil }

      expect(screen.string).to eq("")
    end

    it "draws a header it declined over a draft in place once the draft is gone" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      settles { screen.string.include?("model:0s") || nil }
      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(false)
      Enumerator.produce { next_frame(chat, of: "touch") }.find { |touch| !touch["untouched"] }
      publish(chat, { "generation" => 3, "header" => "model:1s" })
      say(chat, { "v" => "context", "commands" => ["after"] })
      settles { commands == ["after"] || nil }
      screen.truncate(0) && screen.rewind

      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(true)

      expect(settles { screen.string.empty? ? nil : screen.string }).to eq("\e7\e[1A\r\e[Kmodel:1s\n\e8")
    end

    it "rewrites in place again once a whole redraw followed the resize" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      settles { screen.string.include?("model:0s") || nil }
      window.script([6, 80])
      settles { screen.string.scan("model:0s").size > 1 || nil }
      screen.truncate(0) && screen.rewind

      publish(chat, { "generation" => 3, "header" => "model:1s" })

      expect(settles { screen.string.empty? ? nil : screen.string }).to eq("\e7\e[1A\r\e[Kmodel:1s\n\e8")
    end

    it "holds a same-row header while a resize is pending behind a draft the human just discarded" do
      moves = Queue.new
      armed = false
      stub_const("ScriptedMoves", Module.new)
      ScriptedMoves.define_singleton_method(:moved!) { armed.tap { |moved| moves << moved } }
      ScriptedMoves.define_singleton_method(:painted) { nil }
      slow = described_class.new(path:, tty:, input: reader, commands:, layers:, tick: 0.3, geometry: ScriptedMoves)
      @running = Thread.new { slow.run }
      server.timeout = 5
      chat = server.accept.tap { |client| client.timeout = 5 }
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      settles { screen.string.include?("model:0s") || nil }
      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(false)
      armed = true
      Enumerator.produce { moves.pop(timeout: 5) }.find { |moved| moved || moved.nil? }
      allow(Lain::Frontend::LineEditor).to receive(:untouched?).and_return(true)
      screen.truncate(0) && screen.rewind

      publish(chat, { "generation" => 3, "header" => "model:1s" })
      say(chat, { "v" => "context", "commands" => ["after"] })
      settles { commands == ["after"] || nil }

      expect(screen.string).to eq("")
    end

    it "takes the header it adopted below an echo back before the next prompt draws, so the two do not stack" do
      allow(Reline).to receive(:readmultiline).and_return("list the files", nil)
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      next_frame(chat, of: "line")
      say(chat, { "v" => "unpublished", "header" => "model:1s" })
      settles { screen.string.end_with?("\r\e[Kmodel:1s\n") || nil }
      screen.truncate(0) && screen.rewind

      publish(chat, { "kind" => "human", "text" => "[y/N] ", "generation" => 4, "header" => "model:2s" })

      expect(settles { screen.string.include?("model:2s") ? screen.string : nil }).to eq("\e[1A\r\e[Kmodel:2s\n")
    end

    it "draws a header that first arrived empty once a later idle tick has one" do
      allow(Reline).to receive(:readmultiline).and_return("list the files", nil)
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      next_frame(chat, of: "line")
      say(chat, { "v" => "unpublished", "header" => "" })
      say(chat, { "v" => "context", "commands" => ["idle"] })
      settles { commands == ["idle"] || nil }
      screen.truncate(0) && screen.rewind

      say(chat, { "v" => "unpublished", "header" => "model:1s" })

      expect(settles { screen.string.empty? ? nil : screen.string }).to eq("\r\e[Kmodel:1s\n")
    end

    it "draws nothing in place after the pane was resized, leaving the header to the next prompt" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "fleet:1" })
      settles { screen.string.include?("fleet:1") || nil }
      say(chat, { "v" => "unpublished", "header" => "fleet:1" })
      say(chat, { "v" => "context", "commands" => ["idle"] })
      settles { commands == ["idle"] || nil }
      window.script([6, 80])
      sleep(0.2)
      screen.truncate(0) && screen.rewind

      say(chat, { "v" => "unpublished", "header" => "fleet:2" })
      say(chat, { "v" => "context", "commands" => ["after"] })
      settles { commands == ["after"] || nil }

      expect(screen.string).to eq("")
    end

    it "redraws nothing for an unchanged header" do
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "fleet:1" })
      settles { screen.string.include?("fleet:1") || nil }
      say(chat, { "v" => "unpublished", "header" => "fleet:1" })
      say(chat, { "v" => "context", "commands" => ["idle"] })
      settles { commands == ["idle"] || nil }
      screen.truncate(0) && screen.rewind

      say(chat, { "v" => "unpublished", "header" => "fleet:1" })
      say(chat, { "v" => "context", "commands" => ["after"] })
      settles { commands == ["after"] || nil }

      expect(screen.string).to eq("")
    end

    it "sends a line the human finishes, with no generation, for the chat's rail to judge" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("/stop\r")

      expect(next_frame(chat, of: "line")).to eq({ "v" => "line", "text" => "/stop", "generation" => 0 })
    end

    it "sends each line typed there, one after another" do
      chat = open_pane
      unpublished(chat)
      keyboard.write("first\r")
      next_frame(chat, of: "line")

      keyboard.write("second\r")

      expect(next_frame(chat, of: "line")["text"]).to eq("second")
    end

    it "sends a pasted pair of lines as two lines, in order, once each" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("first\rsecond\r")

      expect([next_frame(chat, of: "line")["text"], next_frame(chat, of: "line")["text"]]).to eq(%w[first second])
    end

    it "sends a bracketed paste of two lines as one line with no markers" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("\e[200~para one\npara two\n\e[201~\r")

      expect(next_frame(chat, of: "line")["text"]).to eq("para one\npara two")
    end

    it "sends a bracketed paste of 6000 bytes whole or cut with a notice, never with a marker" do
      chat = open_pane
      unpublished(chat)
      body = Array.new(40) { "#{"x" * 149}\n" }.join.chomp

      keyboard.write("\e[200~#{body}\n\e[201~\r")

      expect(next_frame(chat, of: "line")["text"]).to eq(body)
    end

    it "sends a pasted segment longer than a cooked terminal's line whole, then the line typed after it" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("\e[200~#{"a" * 4200}\n\e[201~\r")
      keyboard.write("after\r")

      expect([next_frame(chat, of: "line")["text"], next_frame(chat, of: "line")["text"]]).to eq(["a" * 4200, "after"])
    end

    it "drops a Ctrl-D from a draft, which goes on with what is typed after it" do
      chat = open_pane
      unpublished(chat)
      keyboard.write("par\x04")
      taken("par")

      keyboard.write("tial\r")

      expect(next_frame(chat, of: "line")["text"]).to eq("partial")
    end

    it "sends a line of 4095 bytes whole, since the pane holds the line rather than the terminal" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("#{"a" * 4095}\r")

      expect(next_frame(chat, of: "line")["text"]).to eq("a" * 4095)
    end

    it "sends a line of 4094 bytes" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("#{"a" * 4094}\r")

      expect(next_frame(chat, of: "line")["text"]).to eq("a" * 4094)
    end

    it "sends a line of 200 bytes as it always has" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("#{"a" * 200}\r")

      expect(next_frame(chat, of: "line")["text"]).to eq("a" * 200)
    end

    # Reline is stubbed: what is pinned is that the partial line reaches the
    # editor's typeahead when a prompt takes the terminal, not Reline's own keys.
    it "hands a partial line to the prompt the chat then publishes" do
      ungot = []
      allow(Reline::IOGate).to receive(:ungetc) { |byte| ungot.unshift(byte) }
      # A prompt read before the partial line is taken (generation 3, drawn
      # while "unpublished" is still in flight) never answers: it is withdrawn.
      allow(Reline).to receive(:readmultiline) { ungot.empty? ? sleep : "#{ungot.pack("C*")}tial" }
      chat = open_pane
      unpublished(chat)
      keyboard.write("par\x04")
      taken("par")

      publish(chat, { "generation" => 5 })

      expect(next_frame(chat, of: "line")).to eq({ "v" => "line", "text" => "partial", "generation" => 5 })
    end

    it "hands a draft with a line end to the next prompt as a paste, so the line end is not an Enter" do
      ungot = []
      allow(Reline::IOGate).to receive(:ungetc) { |byte| ungot.unshift(byte) }
      allow(Reline).to receive(:readmultiline) { ungot.empty? ? sleep : ungot.pack("C*") }
      chat = open_pane
      unpublished(chat)
      keyboard.write("\e[200~one\ntwo\e[201~")
      taken("two")

      publish(chat, { "generation" => 5 })

      expect(next_frame(chat, of: "line")["text"]).to eq("\e[200~one\ntwo\e[201~")
    end

    it "clears what a withdrawn prompt left on the input row before it echoes a draft" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("abc")

      expect(settles { screen.string.end_with?("abc") || nil } && screen.string).to end_with("\r\e[Kabc")
    end

    it "keeps a Tab in the draft, as a cooked terminal did" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("\tb\r")

      expect(next_frame(chat, of: "line")["text"]).to eq("\tb")
    end

    it "echoes a draft itself, the terminal echoing nothing" do
      chat = open_pane
      unpublished(chat)
      keyboard.write("abc")
      taken("abc")

      expect(keyboard.read_nonblock(65_536, exception: false).to_s).not_to include("abc")
    end

    it "takes a pasted draft's every row back on Ctrl-U, since a backspace cannot climb a line end" do
      chat = open_pane
      unpublished(chat)
      keyboard.write("\e[200~one\ntwo\e[201~")
      taken("two")

      keyboard.write("\x15")

      expect(settles { screen.string.end_with?("\e[1A\r\e[J") || nil }).to be(true)
    end

    it "erases one word on Ctrl-W" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("one two\x17three\r")

      expect(next_frame(chat, of: "line")["text"]).to eq("one three")
    end

    it "kills the draft on Ctrl-U" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("abc\x15xyz\r")

      expect(next_frame(chat, of: "line")["text"]).to eq("xyz")
    end

    it "erases both columns of a wide character on Backspace" do
      chat = open_pane
      unpublished(chat)
      keyboard.write("a\u6f22")
      taken("\u6f22")

      keyboard.write("\x7f")

      expect(settles { screen.string.end_with?("\b\b  \b\b") || nil }).to be(true)
    end

    it "joins a character split across 2 reads" do
      chat = open_pane
      unpublished(chat)
      keyboard.write("a\xE6".b)
      taken("a")

      keyboard.write("\xBC\xA2\r".b)

      expect(next_frame(chat, of: "line")["text"]).to eq("a\u6f22")
    end

    it "takes the approval key split across 2 reads as the key" do
      chat = open_pane
      unpublished(chat)
      keyboard.write("x\e[")
      taken("x")

      keyboard.write("Zy\r")

      expect([next_frame(chat, of: "cycle"), next_frame(chat, of: "line")["text"]]).to eq([{ "v" => "cycle" }, "xy"])
    end

    it "sends no line for a blank Enter" do
      chat = open_pane
      unpublished(chat)

      keyboard.write("   \rreal\r")

      expect(next_frame(chat, of: "line")["text"]).to eq("real")
    end

    it "walks up every row a wrapped draft covers when the header changes row count" do
      reader.winsize = [24, 10]
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "fleet:1" })
      settles { screen.string.include?("fleet:1") || nil }
      say(chat, { "v" => "unpublished", "header" => "fleet:1" })
      keyboard.write("a" * 25)
      taken("a" * 25)
      screen.truncate(0) && screen.rewind

      say(chat, { "v" => "unpublished", "header" => "fleet:2\nrow b" })

      expect(settles { screen.string.include?("row b") ? screen.string : nil }).to start_with("\e[3A\r\e[J")
    end

    it "prints the draft back under a header drawn below an answered echo" do
      allow(Reline).to receive(:readmultiline).and_return("list the files", nil)
      chat = open_pane
      publish(chat, { "generation" => 3, "header" => "model:0s" })
      next_frame(chat, of: "line")
      say(chat, { "v" => "unpublished", "header" => "" })
      keyboard.write("abc")
      taken("abc")
      screen.truncate(0) && screen.rewind

      say(chat, { "v" => "unpublished", "header" => "model:1s" })

      expect(settles { screen.string.empty? ? nil : screen.string }).to eq("\r\e[Kmodel:1s\nabc")
    end
  end

  # A console the pane can wait on, that says how many waits are open on it.
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
    let(:reader) { console }
    let(:keyboard) { pipe.last }

    it "is gone while the chat's prompt is drawn" do
      allow(Reline).to receive(:readmultiline) { sleep(0.4) && "hi" }
      chat = open_pane
      publish(chat, { "generation" => 3 })
      say(chat, { "v" => "unpublished" })
      settles { console.waiting == 1 || nil }
      publish(chat, { "generation" => 4 })

      expect(settles { console.waiting.zero? || nil }).to be(true)
    end
  end

  # The idle wait waits for the pump's terminal lock: a console whose wait
  # never returns while the line editor's read still holds the terminal fails
  # any pane that arms its wait before that read has let go.
  describe "a command> read withdrawn after it was open for a while" do
    let(:console) do
      Class.new do
        attr_accessor :held

        def initialize(io) = (@io = io) && (@held = false)
        def tty? = true
        def echo? = true
        def read_nonblock(*args, **opts) = @io.read_nonblock(*args, **opts)
        def wait_readable = held ? sleep : @io.wait_readable
      end.new(pipe.first)
    end
    let(:reader) { console }

    before do
      allow(Reline).to receive(:readmultiline) do
        console.held = true
        sleep
      ensure
        console.held = false
      end
    end

    it "sends the next line typed to the chat at once, with no generation" do
      chat = open_pane
      publish(chat, { "kind" => "command", "text" => "command> ", "generation" => 3 })
      settles { console.held || nil }
      say(chat, { "v" => "unpublished" })

      keyboard.write("/stop\r")

      expect(next_frame(chat, of: "line")).to eq({ "v" => "line", "text" => "/stop", "generation" => 0 })
    end
  end

  it "gives the pane back to the chat's own prompt when it publishes one after nothing" do
    chat = open_pane
    publish(chat, { "generation" => 3 })
    say(chat, { "v" => "unpublished" })
    publish(chat, { "generation" => 4, "header" => "ctx:1%" })
    settles { screen.string.include?("ctx:1%") || nil }

    keyboard.write("hello\n")

    expect(next_frame(chat, of: "line")).to eq({ "v" => "line", "text" => "hello", "generation" => 4 })
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

      deliver("TERM")

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

    def unpublished_pane
      @pty = PTY.open
      keyed = described_class.new(path:, tty:, input: @pty.last, commands:, layers:, tick: 0.01, geometry:)
      @running = Thread.new { keyed.run }
      server.timeout = 5
      server.accept.tap { |client| client.timeout = 5 }.tap { |chat| withdrawn(chat) }
    end

    # A prompt published and withdrawn, and the idle reader holding the terminal.
    def withdrawn(chat)
      publish(chat, { "generation" => 3 })
      say(chat, { "v" => "unpublished" })
      uncooked(@pty.first)
    end

    # Bytes waiting on the pane's end of the terminal, by FIONREAD: none left
    # means the idle reader has taken them into the draft, since it reads and
    # takes with no other fiber between.
    def waiting
      count = [0].pack("i")
      @pty.last.ioctl(Lain::Shell::Pipeline::FIONREAD, count)
      count.unpack1("i")
    end

    # The frames up to the line sent after the Ctrl-C, so a signal frame sent for it shows.
    def frames_through_line(chat)
      [].tap do |frames|
        Enumerator.produce { JSON.parse(chat.gets.to_s) }.find { |frame| frames << frame and frame["v"] == "line" }
      end
    end

    it "discards the idle draft on Ctrl-C and sends the chat no signal frame" do
      chat = unpublished_pane
      @pty.first.write("qq")
      settles { screen.string.end_with?("qq") || nil }

      deliver("INT")
      settles { screen.string.end_with?("qq") ? nil : true }
      @pty.first.write("d\r")

      expect(frames_through_line(chat).map { |frame| frame["v"] }).not_to include("signal")
    ensure
      @pty&.each(&:close)
    end

    # An open paste echoes nothing, and neither does discarding it, so the
    # 2nd Ctrl-C, over the now empty draft, is the witness that the 1st was
    # handled: signals reach the pane in order, through one pipe.
    it "discards a draft held mid paste on Ctrl-C and sends the chat no signal frame" do
      chat = unpublished_pane
      @pty.first.write("\e[200~qq")
      settles { waiting.zero? || nil }

      deliver("INT")
      deliver("INT")
      next_frame(chat, of: "signal")
      @pty.first.write("d\r")

      expect(frames_through_line(chat).map { |frame| frame["v"] }).not_to include("signal")
    ensure
      @pty&.each(&:close)
    end

    it "interrupts on a Ctrl-C over an empty draft" do
      chat = unpublished_pane

      deliver("INT")

      expect(next_frame(chat, of: "signal")).to eq({ "v" => "signal", "name" => "sigint" })
    ensure
      @pty&.each(&:close)
    end

    context "with a prompt drawn by the line editor" do
      # Reline reads the terminal it was pointed at, so the pane's PTY is made its
      # input and output for the example and the runner's put back after.
      around do |example|
        saved = [Reline.core.io_gate.instance_variable_get(:@input), Reline.core.output]
        example.run
      ensure
        Reline.input, Reline.output = saved
        @pty&.each(&:close)
      end

      def drawn_pane(kind)
        @pty = PTY.open
        Reline.input = Reline.output = @pty.last
        @running = Thread.new { keyed_pane.run }
        server.timeout = 5
        chat = server.accept.tap { |client| client.timeout = 5 }
        publish(chat, { "kind" => kind, "text" => "#{kind}> " })
        chat
      end

      def keyed_pane = described_class.new(path:, tty:, input: @pty.last, commands:, layers:, tick: 0.01, geometry:)

      def echoed_until(seen = +"", &)
        Enumerator.produce { seen << pty_read(@pty.first, 1) }.find(&)
      end

      %w[you command].each do |kind|
        it "clears a line typed at #{kind}> on Ctrl-C, redraws the prompt empty, and sends the chat no signal" do
          chat = drawn_pane(kind)
          echo = echoed_until { |seen| seen.include?("#{kind}> ") }
          @pty.first.write("half a thought")
          echoed_until(echo) { |seen| seen.include?("thought") }

          deliver("INT")
          echoed_until(+"") { |seen| seen.include?("#{kind}> ") }
          @pty.first.write("d\r")
          frames = frames_through_line(chat)

          expect([frames.map { |frame| frame["v"] }.include?("signal"), frames.last["text"]]).to eq([false, "d"])
        end
      end

      it "takes back every row of a 2 row line on Ctrl-C, not only the cursor's" do
        drawn_pane("you")
        echo = echoed_until { |seen| seen.include?("you> ") }
        @pty.first.write("first row\e\rsecond row")
        echoed_until(echo) { |seen| seen.include?("second row") }

        deliver("INT")
        echoed_until(+"") { |seen| seen.include?("you> ") }

        expect(screen.string).to include("\e[1A\r\e[J")
      end

      it "sends a Ctrl-C over an empty line at you> to the chat" do
        chat = drawn_pane("you")
        echoed_until { |seen| seen.include?("you> ") }

        deliver("INT")

        expect(next_frame(chat, of: "signal")).to eq({ "v" => "signal", "name" => "sigint" })
      end

      # TERM=dumb picks Reline's gate once, at require, so the dumb gate is
      # swapped in here rather than by environment.
      it "sends a Ctrl-C at an empty you> to the chat on a dumb terminal, which reads cooked" do
        stub_const("Reline::IOGate", Reline::Dumb.new)
        chat = drawn_pane("you")
        echoed_until { |seen| seen.include?("you> ") }

        deliver("INT")

        expect(next_frame(chat, of: "signal")).to eq({ "v" => "signal", "name" => "sigint" })
      end
    end

    it "goes to the chat rather than interrupting the pane" do
      chat = open_pane
      publish(chat, {})
      settles { screen.string.include?("you> ") || nil }

      deliver("INT")

      expect([next_frame(chat, of: "signal"), @running.join(0.2)]).to eq([{ "v" => "signal", "name" => "sigint" }, nil])
    end
  end

  describe "a signal that closes the pane" do
    around do |example|
      saved = Lain::CLI::Signals::MAP.keys.to_h { |name| [name, Signal.trap(name) { nil }] }
      example.run
    ensure
      saved.each { |name, handler| Signal.trap(name, handler) }
    end

    # What a pane sent before it went, read only once it has gone: a pane still
    # running would hold the read open until the chat's own timeout.
    def sent_before_exit(chat)
      exited = @running.join(2)&.value
      [exited, exited ? chat.read.lines.map { |line| JSON.parse(line)["v"] }.include?("signal") : nil]
    end

    %w[TERM HUP].each do |name|
      it "ends only the pane on #{name}, sending the chat no signal frame" do
        chat = open_pane
        publish(chat, {})
        settles { screen.string.include?("you> ") || nil }

        deliver(name)

        expect(sent_before_exit(chat)).to eq([0, false])
      end
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
