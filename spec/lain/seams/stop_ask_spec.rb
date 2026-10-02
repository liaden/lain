# frozen_string_literal: true

require "json"

# Stopping an ask without ending the session, end to end: a chat process whose
# ask never returns on its own, and a real `lain input` pane in a PTY joined to
# it over a Unix socket. Two processes and a real session file, because the
# claim is exactly that a human who is NOT at the chat's terminal can reach the
# run, and that what the file holds afterwards is a stopped run rather than a
# closed session.
#
# The pane runs THE REPOSITORY'S `exe/lain`: an installed gem's binary is a
# different program, and a pane spec that passed against it would say nothing
# about this checkout.
module StopAsk
  # The chat: a real Chronicle over a real session file, a real Intake,
  # InputSocket and Conductor, and stdin closed so nothing on this side can
  # answer a prompt.
  #
  # Two runaways, because the human reaches them differently. `parked` asks
  # its approval again the moment it is answered, so there is always a prompt
  # to type `/stop` at; `looping` answers nothing and publishes nothing, which
  # is the automatically approved bash loop, and the only way in is the
  # countdown a Ctrl-C opens.
  CHILD = <<~RUBY
    require "lain"
    require "json"

    dir, shape, path = ARGV.values_at(0, 1, 2)
    $stdin.close

    out = File.open(File.join(dir, "chat.out"), "w").tap { |io| io.sync = true }
    log = File.open(File.join(dir, "heard.ndjson"), "a").tap { |io| io.sync = true }
    session = File.join(dir, "session.ndjson")
    tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: out, pastel: Pastel.new(enabled: false),
                                  history_path: File.join(dir, "history"),
                                  state_path: File.join(dir, "state.json"))
    rail = Lain::Frontend::Intake.new(screen: tty)
    socket = Lain::CLI::InputSocket.new(rail:, path:)
    socket.bind
    chronicle = Lain::CLI::Chronicle.new(
      journal: Lain::Journal.new(io: File.open(session, "ab").tap { |io| io.sync = true }), journal_path: session
    )
    chronicle.start(context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64),
                    toolset: Lain::Toolset.new([]))
    conductor = Lain::CLI::Conductor.new(tty:, chronicle:, signals: Lain::CLI::Signals.new, rail:, grace: 30,
                                         countdown: Lain::CLI::Conductor::RailCountdown.new(rail:))

    runaway = {
      "parked" => -> { Enumerator.produce { conductor.read_reply("[y/N] run bash? ") }.each { |answer| answer } },
      "looping" => -> { Enumerator.produce { Async::Task.current.sleep(0.05) }.each { |tick| tick } },
      "ask_human" => lambda {
        asker = Lain::Tools::AskHuman.new(parent: Lain::Timeline.empty(store: Lain::Store.new),
                                          observer: chronicle.observer, journal: chronicle.record_journal)
        asker.call({ "question" => "which db?" }, Lain::Tool::Invocation.new(context: Lain::Session::Null.instance))
      }
    }.fetch(shape)

    File.write(File.join(dir, "bound"), "yes")
    conductor.guard do
      Sync do |task|
        socket.start(task)
        conductor.read_prompt("you> ")
        outcome = conductor.supervise(task, -> { Lain::Timeline.empty }) do
          File.write(File.join(dir, "asking"), "")
          runaway.call
        end
        log.puts(JSON.generate({ "stopped" => outcome.response.is_a?(Lain::Stopped), "closed" => outcome.closed? }))
        conductor.read_prompt("you> ")
      end
    end
  RUBY

  # One cockpit's two processes and the directory they meet in.
  class Cockpit
    attr_reader :dir

    def initialize(warm)
      @warm = warm
      @dir = warm.dir
      @screen = +""
      @lock = Mutex.new
    end

    # Releases the parked chat with its shape, then types the line that starts the ask.
    def asking(shape)
      @warm.release(shape)
      @reader = @warm.reader
      @writer = @warm.writer
      @drain = Thread.new { drain }
      settles { screen.include?("you> ") || nil }
      type("go\r")
      settles { File.exist?(File.join(@dir, "asking")) || nil }
      self
    end

    def type(text) = @writer.write(text)

    def screen = @lock.synchronize { @screen.dup }

    def heard
      file = File.join(@dir, "heard.ndjson")
      File.exist?(file) ? File.readlines(file).filter_map { |line| parsed(line) } : []
    end

    # The session file's records of one type, as the chat wrote them.
    def records(type)
      file = File.join(@dir, "session.ndjson")
      return [] unless File.exist?(file)

      File.readlines(file).filter_map { |line| parsed(line) }.select { |record| record["type"] == type }
    end

    # The session file folded the way the live views fold it: the HUD's count
    # and lain://inbox each see the Q arrive, then every consumption record.
    def inbox_after_replay
      hud = Lain::StatusFeed::Inbox.new
      view = Lain::Frontend::Neovim::InboxView.new
      asked = records("message").map { |record| telemetry("Message", record) }.select { |m| m.to == "human" }
      drawn = asked.map { |question| arrival(hud, view, question) }
      drawn += records("questions_consumed").map { |record| consumption(hud, view, record) }
      { hud: hud.pending_size, buffer: drawn.compact.last.grep(/which db/).size, asked: asked.size }
    end

    def arrival(hud, view, question)
      hud.arrived(question)
      view.update(question)
    end

    def consumption(hud, view, record)
      hud.retire(record["digests"])
      view.update(telemetry("QuestionsConsumed", record))
    end

    def close
      @drain&.kill
      @warm.reap
    end

    # Whatever the block answers once it stops answering nil, or nil at the
    # deadline: two processes and a PTY settle on their own clock.
    def settles(within: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      Enumerator.produce { sleep(0.02) && yield }
                .find { |answer| !answer.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline }
    end

    private

    def telemetry(name, record)
      Lain::Telemetry.const_get(name).new(**record.except("type", "at", "ts").transform_keys(&:to_sym))
    end

    def parsed(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def drain
      Enumerator.produce { @reader.readpartial(4096) }.each { |bytes| @lock.synchronize { @screen << bytes } }
    rescue Errno::EIO, IOError
      nil
    end
  end
end

RSpec.describe "stopping a running ask from an input pane", :seam do
  warm_pool(:cockpits) do
    WarmCockpit.pair(prefix: "lain-stop-ask-seam", script: StopAsk::CHILD)
  end

  subject(:cockpit) { StopAsk::Cockpit.new(cockpits.take) }

  after { cockpit.close }

  # The ask ended, and it said why: the outcome carries the stop rather than a
  # bare nil, and the file holds one run_interrupted naming it.
  def expect_stop_recorded
    expect(cockpit.settles { cockpit.heard.first }).to eq({ "stopped" => true, "closed" => false })
    expect(cockpit.records("run_interrupted").map { |record| record["reason"] }).to eq(["stopped"])
  end

  # The session did not end with it: nothing closed the record, and the pane is
  # drawing `you>` again.
  def expect_session_open
    expect(cockpit.records("session_closed")).to be_empty
    expect(cockpit.settles { cockpit.screen.scan("you> ").size > 1 || nil }).to be(true)
  end

  it "stops the ask when /stop is typed at the prompt it parked on" do
    cockpit.asking("parked")
    cockpit.settles { cockpit.screen.include?("[y/N] run bash?") || nil }

    cockpit.type("/stop\r")

    expect_stop_recorded
    expect_session_open
  end

  it "offers stop at the countdown a Ctrl-C opens, and s stops the ask there" do
    cockpit.asking("looping")

    cockpit.type("\x03")
    offered = cockpit.settles { cockpit.screen.include?("[s] stop this ask") || nil }
    cockpit.type("s")

    expect(offered).to be(true)
    expect_stop_recorded
    expect_session_open
  end

  it "names the question consumed when the ask parked on ask_human is stopped" do
    cockpit.asking("ask_human")

    cockpit.type("\x03")
    cockpit.settles { cockpit.screen.include?("[s] stop this ask") || nil }
    cockpit.type("s")

    expect_stop_recorded
    consumed = cockpit.settles { cockpit.records("questions_consumed").first }
    expect(consumed["digests"].size).to eq(1)
    expect(consumed["turn"]).to be_nil
    expect(cockpit.inbox_after_replay).to eq(hud: 0, buffer: 0, asked: 1)
  end
end
