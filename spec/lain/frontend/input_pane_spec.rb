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
    described_class.new(path:, tty:, input: reader, commands:, layers:, tick: 0.01)
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

  # The pane in a thread of its own, and the chat's end of its connection.
  def open_pane
    @running = Thread.new { pane.run }
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

  it "takes the commands it completes against from the chat, holding no registry" do
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
end
