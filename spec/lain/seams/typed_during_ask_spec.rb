# frozen_string_literal: true

require "fileutils"
require "json"
require "pty"
require "rbconfig"
require "tmpdir"

# A line typed while an ask is in flight, end to end. Nothing is published then,
# so nothing was reading: a `/stop` waited as typeahead until the ask was over.
# Each shape here is a real chat process and a real terminal it is typed at --
# the input pane in a PTY joined by a Unix socket, or the chat's own PTY with
# `--no-nvim`'s stdin pump -- because the claim is about bytes reaching the rail
# while the ask is still running.
#
# The pane runs THE REPOSITORY'S `exe/lain`, as the sibling seams do.
module TypedDuringAsk
  LIB = File.expand_path("../../../lib", __dir__)
  EXE = File.expand_path("../../../exe/lain", __dir__)

  # `looping` never returns on its own, so an ask that ends did so because it
  # was stopped; `held` returns once `done` exists and reports what the chat's
  # rail kept for its next prompt. `pump` is the same chat reading its own
  # terminal instead of a socket.
  CHILD = <<~RUBY
    require "lain"
    require "json"

    dir, shape, path = ARGV.values_at(0, 1, 2)
    out = File.open(File.join(dir, "chat.out"), "w").tap { |io| io.sync = true }
    log = File.open(File.join(dir, "heard.ndjson"), "a").tap { |io| io.sync = true }
    session = File.join(dir, "session.ndjson")
    pump = shape.end_with?("pump")
    tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: pump ? $stdout : out,
                                  pastel: Pastel.new(enabled: false), history_path: File.join(dir, "history"),
                                  state_path: File.join(dir, "state.json"))
    rail = Lain::Frontend::Intake.new(screen: tty)
    producer = pump ? Lain::Frontend::StdinPump.new(rail:, screen: tty) : Lain::CLI::InputSocket.new(rail:, path:)
    producer.bind unless pump
    chronicle = Lain::CLI::Chronicle.new(
      journal: Lain::Journal.new(io: File.open(session, "ab").tap { |io| io.sync = true }), journal_path: session
    )
    chronicle.start(context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64),
                    toolset: Lain::Toolset.new([]))
    conductor = Lain::CLI::Conductor.new(tty:, chronicle:, signals: Lain::CLI::Signals.new, rail:, grace: 30,
                                         countdown: Lain::CLI::Conductor::RailCountdown.new(rail:))

    ask = if shape.start_with?("looping")
            -> { Enumerator.produce { Async::Task.current.sleep(0.05) }.each { |tick| tick } }
          else
            -> { Async::Task.current.sleep(0.05) until File.exist?(File.join(dir, "done")) }
          end

    File.write(File.join(dir, "bound"), "yes")
    conductor.guard do
      Sync do |task|
        producer.start(task)
        conductor.read_prompt("you> ")
        outcome = conductor.supervise(task, -> { Lain::Timeline.empty }) do
          File.write(File.join(dir, "asking"), "")
          ask.call
        end
        log.puts(JSON.generate({ "stopped" => outcome.response.is_a?(Lain::Stopped) }))
        conductor.gather_typed_ahead
        log.puts(JSON.generate({ "held" => Array.new(4) { rail.take_held } }))
      end
    end
  RUBY

  # The chat process and whichever terminal the human types at.
  class Cockpit
    attr_reader :dir

    def initialize(dir)
      @dir = dir
      @path = File.join(dir, "input.sock")
      @screen = +""
      @lock = Mutex.new
      @pids = []
    end

    def env
      { "XDG_STATE_HOME" => File.join(@dir, "state"), "XDG_RUNTIME_DIR" => File.join(@dir, "run"),
        "XDG_CONFIG_HOME" => File.join(@dir, "config"), "XDG_CACHE_HOME" => File.join(@dir, "cache"),
        "TERM" => "xterm", "INPUTRC" => File.join(@dir, "no-inputrc") }
    end

    # A cockpit: the chat reads its socket, the pane is where the human types.
    def cockpit(shape)
      @pids << Process.spawn(env, RbConfig.ruby, "-I", LIB, "-e", CHILD, @dir, shape, @path,
                             out: File.join(@dir, "chat.err"), err: %i[child out])
      settles { File.exist?(File.join(@dir, "bound")) || nil }
      attach(RbConfig.ruby, EXE, "input", "--socket", @path)
      asking
    end

    # `--no-nvim`: the chat's own terminal is the one typed at.
    def plain(shape)
      attach(RbConfig.ruby, "-W0", "-I", LIB, "-e", CHILD, @dir, shape, @path)
      asking
    end

    def type(text) = @writer.write(text)

    def screen = @lock.synchronize { @screen.dup }

    def heard
      file = File.join(@dir, "heard.ndjson")
      File.exist?(file) ? File.readlines(file).filter_map { |line| parsed(line) } : []
    end

    def records(type)
      file = File.join(@dir, "session.ndjson")
      return [] unless File.exist?(file)

      File.readlines(file).filter_map { |line| parsed(line) }.select { |record| record["type"] == type }
    end

    def finish_ask = FileUtils.touch(File.join(@dir, "done"))

    def close
      @writer&.close
      @drain&.kill
      @pids.each { |pid| reap(pid) }
    end

    def settles(within: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      Enumerator.produce { sleep(0.02) && yield }
                .find { |answer| !answer.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline }
    end

    private

    def attach(*command)
      @reader, @writer, pid = PTY.spawn(env, *command)
      @pids << pid
      @drain = Thread.new { drain }
    end

    # Typed while the ask runs, so the ask has to be running: `go` is the line
    # that starts it, and it is typed only once `you>` is drawn.
    def asking
      settles { screen.include?("you> ") || nil }
      type("go\r")
      settles { File.exist?(File.join(@dir, "asking")) || nil }
      sleep(0.3)
      self
    end

    def parsed(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def drain
      Enumerator.produce { @reader.readpartial(4096) }.each do |bytes|
        @lock.synchronize { @screen << bytes }
        @writer.write("\e[1;1R") if bytes.include?("\e[6n")
      end
    rescue Errno::EIO, IOError
      nil
    end

    def reap(pid)
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end

RSpec.describe "a line typed while an ask is in flight", :seam do
  subject(:cockpit) { TypedDuringAsk::Cockpit.new(dir) }

  let(:dir) { Dir.mktmpdir("lain-typed-during-ask") }

  after do
    cockpit.close
    FileUtils.remove_entry(dir)
  end

  def held_after_the_ask
    cockpit.finish_ask
    cockpit.settles { cockpit.heard.find { |record| record.key?("held") } }["held"]
  end

  describe "in the input pane" do
    it "reaches the chat at once: /stop stops an ask that would never have ended" do
      cockpit.cockpit("looping")

      cockpit.type("/stop\r")

      expect(cockpit.settles { cockpit.heard.first }).to eq({ "stopped" => true })
      expect(cockpit.records("run_interrupted").map { |record| record["reason"] }).to eq(["stopped"])
    end

    it "is held for the chat's next prompt, once, in the order typed" do
      cockpit.cockpit("held")

      cockpit.type("/goal off\r")
      sleep(0.5)
      cockpit.type("hello\r")
      sleep(0.5)
      cockpit.type("one\rtwo\r")
      sleep(0.5)

      expect(held_after_the_ask).to eq(["/goal off", "hello", "one", "two"])
    end
  end

  describe "on the chat's own terminal" do
    it "stops the ask when /stop and Enter are typed" do
      cockpit.plain("looping_pump")

      cockpit.type("/stop\r")

      expect(cockpit.settles { cockpit.heard.first }).to eq({ "stopped" => true })
      expect(cockpit.records("run_interrupted").map { |record| record["reason"] }).to eq(["stopped"])
    end

    it "keeps a line typed mid-ask for the next prompt, once" do
      cockpit.plain("held_pump")

      cockpit.type("hello\r")
      sleep(0.5)

      expect(held_after_the_ask).to eq(["hello", nil, nil, nil])
    end
  end
end
