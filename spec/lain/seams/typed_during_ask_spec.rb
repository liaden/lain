# frozen_string_literal: true

require "fileutils"
require "json"

# A line typed while an ask is in flight, end to end. Nothing is published then,
# so nothing was reading: a `/stop` waited as typeahead until the ask was over.
# Each shape here is a real chat process and the real terminal it is typed at --
# the chat's own PTY with `--no-nvim`'s stdin pump -- because the claim is about
# bytes reaching the rail while the ask is still running.
module TypedDuringAsk
  # `looping` never returns on its own, so an ask that ends did so because it
  # was stopped; `held` returns once `done` exists and reports what the chat's
  # rail kept for its next prompt.
  CHILD = <<~RUBY
    require "lain"
    require "json"

    dir, shape = ARGV.values_at(0, 1)
    log = File.open(File.join(dir, "heard.ndjson"), "a").tap { |io| io.sync = true }
    session = File.join(dir, "session.ndjson")
    tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: $stdout,
                                  pastel: Pastel.new(enabled: false), history_path: File.join(dir, "history"),
                                  state_path: File.join(dir, "state.json"))
    rail = Lain::Frontend::Intake.new(screen: tty)
    producer = Lain::Frontend::StdinPump.new(rail:, screen: tty)
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
        outcome = conductor.supervise(task, -> { Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store) }) do
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

    def initialize(warm)
      @warm = warm
      @dir = warm.dir
      @screen = +""
      @lock = Mutex.new
    end

    # `--no-nvim`: the chat's own terminal is the one typed at.
    def ask(shape)
      @warm.release(shape)
      @reader = @warm.reader
      @writer = @warm.writer
      @drain = Thread.new { drain }
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
      @drain&.kill
      @warm.reap
    end

    def settles(within: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      Enumerator.produce { sleep(0.02) && yield }
                .find { |answer| !answer.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline }
    end

    private

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
  end
end

RSpec.describe "a line typed while an ask is in flight", :seam do
  subject(:cockpit) { TypedDuringAsk::Cockpit.new(warm) }

  after { cockpit.close }

  def held_after_the_ask
    cockpit.finish_ask
    cockpit.settles { cockpit.heard.find { |record| record.key?("held") } }["held"]
  end

  describe "on the chat's own terminal" do
    warm_pool(:terminals) do
      WarmCockpit.terminal(prefix: "lain-typed-during-ask", script: TypedDuringAsk::CHILD)
    end

    let(:warm) { terminals.take }

    it "stops the ask when /stop and Enter are typed" do
      cockpit.ask("looping")

      cockpit.type("/stop\r")

      expect(cockpit.settles { cockpit.heard.first }).to eq({ "stopped" => true })
      expect(cockpit.records("run_interrupted").map { |record| record["reason"] }).to eq(["stopped"])
    end

    it "keeps a line typed mid-ask for the next prompt, once" do
      cockpit.ask("held")

      cockpit.type("hello\r")
      sleep(0.5)

      expect(held_after_the_ask).to eq(["hello", nil, nil, nil])
    end
  end
end
