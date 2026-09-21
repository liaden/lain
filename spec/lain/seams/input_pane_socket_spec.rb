# frozen_string_literal: true

require "fileutils"
require "json"
require "pty"
require "rbconfig"
require "tmpdir"

# The split cockpit, end to end: a chat process that reads NO stdin and a
# separate `lain input` pane in a real PTY, joined by a real Unix socket. Two
# processes and a file in the filesystem is the whole subject -- a doubled
# socket, or a pane driven in this process, would test neither the pid-free path
# a restarted chat rebinds nor the line editor a human actually types into.
#
# The pane runs THE REPOSITORY'S `exe/lain`, never one the spec runner happens
# to have on PATH: an installed gem's binary is a different program, and a pane
# spec that passed against it would say nothing about this checkout.
module InputPaneSocket
  LIB = File.expand_path("../../../lib", __dir__)
  EXE = File.expand_path("../../../exe/lain", __dir__)

  # The chat: a real Intake, InputSocket, Conductor and TTY, with its stdin
  # closed so nothing on this side can read a line at all. `lines` reads `you>`
  # until the stream ends; `approval` parks one gated call through a real
  # Approval::Queue and answers it through the real terminal surface;
  # `countdown` supervises an ask a Ctrl-C can open a grace window on.
  CHILD = <<~RUBY
    require "lain"
    require "json"

    dir, shape, path = ARGV.values_at(0, 1, 2)
    $stdin.close

    log = File.open(File.join(dir, "heard.ndjson"), "a").tap { |io| io.sync = true }
    out = File.open(File.join(dir, "chat.out"), "w").tap { |io| io.sync = true }
    hud = File.join(dir, "hud")
    tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: out, pastel: Pastel.new(enabled: false),
                                  history_path: File.join(dir, "history"),
                                  state_path: File.join(dir, "state.json"))
    rail = Lain::Frontend::Intake.new(screen: tty)
    # The real composition, not a canned line: the chat's own `hud_line` is
    # `Reading#header` over the published struct, so the file holds the STRUCT
    # and the header is derived here exactly as `CLI::Wiring` derives it.
    header = lambda do
      File.exist?(hud) ? Lain::StatusFeed::Reading.new(JSON.parse(File.read(hud))).header(now: Time.now) : ""
    end
    socket = Lain::CLI::InputSocket.new(rail:, path:, commands: -> { %w[approve inbox] }, header:)
    begin
      socket.bind
    rescue Lain::CLI::InputSocket::InUse => e
      File.write(File.join(dir, "refused"), e.message)
      exit 3
    end
    conductor = Lain::CLI::Conductor.new(tty:, chronicle: Lain::CLI::Chronicle::Null.new,
                                         signals: Lain::CLI::Signals.new, rail:, grace: 30,
                                         countdown: Lain::CLI::Conductor::RailCountdown.new(rail:))

    lines = lambda do |_task|
      Enumerator.produce { conductor.read_prompt("you> ") }.lazy
                .take_while { |line| !line.nil? }.each { |line| log.puts(JSON.generate({ "heard" => line })) }
    end

    approval = lambda do |task|
      queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: out), timeout: 30)
      policy = Lain::Frontend::ApprovalPolicy.new(reader: ->(asked) { conductor.read_reply(asked) },
                                                 output: out, pastel: Pastel.new(enabled: false))
      watching = task.async { policy.watch(queue) }
      call = Lain::Effect::ToolCall.new(tool_use_id: "c1", name: "bash", input: { "command" => "rm -rf build" })
      settled = queue.adjudicate(call, nil)
      log.puts(JSON.generate({ "approved" => settled.approved?, "surface" => settled.surface }))
      watching.stop
    end

    countdown = lambda do |task|
      conductor.read_prompt("you> ")
      done = File.join(dir, "done")
      outcome = conductor.supervise(task, -> { Lain::Timeline.empty }) do
        File.write(File.join(dir, "asking"), "")
        Async::Task.current.sleep(0.05) until File.exist?(done)
        "answered"
      end
      log.puts(JSON.generate({ "response" => outcome.response, "closed" => outcome.closed? }))
    end

    parked = lambda do |task|
      conductor.read_prompt("you> ")
      outcome = conductor.supervise(task, -> { Lain::Timeline.empty }) do
        File.write(File.join(dir, "asking"), "")
        log.puts(JSON.generate({ "reply" => conductor.read_reply("apply this edit? [y/N] ") }))
        "answered"
      end
      log.puts(JSON.generate({ "response" => outcome.response, "closed" => outcome.closed? }))
    end

    File.write(File.join(dir, "bound"), "yes")
    conductor.guard do
      Sync do |task|
        socket.start(task)
        { "lines" => lines, "approval" => approval, "countdown" => countdown,
          "parked" => parked }.fetch(shape).call(task)
      end
    end
    socket.stop
    File.write(File.join(dir, "exited"), "")
  RUBY

  # One cockpit's two processes and the directory they meet in.
  class Cockpit
    attr_reader :dir, :path

    def initialize(dir)
      @dir = dir
      @path = File.join(dir, "input.sock")
      @screen = +""
      @lock = Mutex.new
      @chats = []
    end

    # `$HOME` is deliberately left alone: both children run under this runner's
    # bundle, and a moved home is a bundler that cannot find its own gems. The
    # XDG variables are enough to keep the pane's history and state out of the
    # human's directories.
    def env
      { "XDG_STATE_HOME" => File.join(@dir, "state"), "XDG_RUNTIME_DIR" => File.join(@dir, "run"),
        "XDG_CONFIG_HOME" => File.join(@dir, "config"), "XDG_CACHE_HOME" => File.join(@dir, "cache"),
        "TERM" => "xterm", "INPUTRC" => File.join(@dir, "no-inputrc"), "LAIN_SPEC_GRACE" => "30" }
    end

    # A chat process. Returns its pid; `bound` appears once it owns the socket.
    def chat(shape)
      pid = Process.spawn(env, RbConfig.ruby, "-I", LIB, "-e", CHILD, @dir, shape, @path,
                          out: File.join(@dir, "chat.err"), err: %i[child out])
      @chats << pid
      pid
    end

    # The pane, in a real PTY, running THIS checkout's executable.
    def pane
      @reader, @writer, @pid = PTY.spawn(env, RbConfig.ruby, EXE, "input", "--socket", @path)
      @drain = Thread.new { drain }
      self
    end

    def type(text) = @writer.write(text)

    # What tmux's `resize-pane` does to a pane, as the pane can see it: the
    # master's winsize, which the slave reads back by ioctl.
    def resize(rows, cols = 80) = @reader.winsize = [rows, cols]

    def screen = @lock.synchronize { @screen.dup }

    def heard
      path = File.join(@dir, "heard.ndjson")
      File.exist?(path) ? File.readlines(path).filter_map { |line| parsed(line) } : []
    end

    def close
      @writer&.close
      @drain&.kill
      @chats.each { |pid| reap(pid) }
      reap(@pid)
    end

    # Whatever the block answers once it stops answering nil, or nil at the
    # deadline: two processes and a PTY settle on their own clock.
    def settles(within: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      Enumerator.produce { sleep(0.02) && yield }
                .find { |answer| !answer.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline }
    end

    private

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

    def reap(pid)
      return if pid.nil?

      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end

RSpec.describe "a chat fed by an input pane", :seam do
  subject(:cockpit) { InputPaneSocket::Cockpit.new(dir) }

  let(:dir) { Dir.mktmpdir("lain-input-pane-seam") }

  after do
    cockpit.close
    FileUtils.remove_entry(dir)
  end

  # The chat is up and the pane has drawn its first prompt.
  def cockpit_at(shape, prompt: "you> ")
    cockpit.chat(shape)
    cockpit.settles { File.exist?(File.join(dir, "bound")) || nil }
    cockpit.pane
    cockpit.settles { cockpit.screen.include?(prompt) || nil }
  end

  it "answers a line typed in the pane, with the chat reading no stdin of its own" do
    cockpit_at("lines")

    cockpit.type("hello\r")

    expect(cockpit.settles { cockpit.heard.find { |record| record["heard"] == "hello" } })
      .to eq({ "heard" => "hello" })
  end

  # A published struct, as the chat's own header thunk composes one.
  def publish(**state)
    File.write(File.join(dir, "hud"), JSON.generate({ "fleet" => [], "inbox_count" => 0 }.merge(state)))
  end

  # One `fleet_tree` row, as `StatusFeed::Fleet#tree` publishes one.
  def fleet_row(task: "port the parser", turns: 1)
    { "spawn" => "blake3:dev", "role" => "dev", "task" => task, "worker" => "dev.1",
      "state" => "running", "turns" => turns, "depth" => 0, "started" => Time.now.utc.iso8601 }
  end

  it "shows the chat's header above the prompt, refreshed with no keypress" do
    cockpit_at("lines")

    publish(fleet: %w[a b], inbox_count: 1)

    expect(cockpit.settles { cockpit.screen.include?("fleet:2 inbox:1") || nil }).to be(true)
  end

  # The fleet tree rides the header, so the header is no longer one line. A
  # pane draws it whole above the prompt and republishes on every change, which
  # is what makes a child's turn count live with nothing typed.
  it "draws a multi-line header whole, and redraws it when a row moves" do
    cockpit_at("lines")
    publish(fleet: %w[a], fleet_tree: [fleet_row(turns: 1)])
    first = cockpit.settles { cockpit.screen.include?("dev  running  1t") || nil }
    # The pane reads a prompt whose local read has not reopened yet as one
    # being typed at, so a second header landing in the milliseconds after a
    # redraw waits for the change after it. That window belongs to the
    # round-trip, not to this example, whose subject is the header arriving
    # whole and redrawing with no keypress.
    sleep(0.5)

    publish(fleet: %w[a], fleet_tree: [fleet_row(turns: 2)])

    expect([first, cockpit.settles { cockpit.screen.include?("dev  running  2t") || nil }]).to eq([true, true])
  end

  # The header is the frame, and a pane redraws a changed frame at whatever
  # column the line editor left the cursor on. Measured before the age left
  # the header: seven redraws and seven header prints in eight seconds, and a
  # six-row pane down to one row for its prompt.
  it "redraws nothing while only the clock moves under a running fleet" do
    cockpit_at("lines")
    publish(fleet: %w[a], fleet_tree: [fleet_row])
    cockpit.settles { cockpit.screen.include?("dev  running  1t") || nil }
    # One publish tick past the redraw that carried the row, so the count is
    # taken over a quiet window rather than across the change itself.
    sleep(1)
    settled = cockpit.screen.scan("you> ").size

    sleep(3)

    expect(cockpit.screen.scan("you> ").size).to eq(settled)
  end

  # Squeeze a cockpit window below the pane's row floor and tmux's
  # `window-layout-changed` hook resizes it back -- a bare `resize-pane`, which
  # tells nothing to repaint. Measured in a real cockpit: the HUD header was
  # gone from the restored pane until the next ask completed, while the status
  # feed carried the right string throughout. Nothing on the wire saw it, so
  # the pane's own tty is what has to.
  it "draws the HUD again after its own pane is resized, with no keypress" do
    cockpit_at("lines")
    publish(fleet: %w[a], fleet_tree: [fleet_row])
    cockpit.settles { cockpit.screen.include?("dev  running  1t") || nil }
    # One publish tick past the redraw that carried the row, so the count is
    # taken over a quiet window rather than across the change itself.
    sleep(1)
    shown = cockpit.screen.scan("fleet:1 inbox:0").size

    cockpit.resize(6)

    expect(cockpit.settles { cockpit.screen.scan("fleet:1 inbox:0").size > shown || nil }).to be(true)
  end

  # A repaint is a fresh read and a fresh read starts from nothing, which is why
  # a changed header waits for the next prompt under a half-typed line. A resize
  # is held to the same rule: the human's words outrank the HUD, and the next
  # prompt draws the header anyway.
  it "leaves a half-typed line alone when the pane is resized" do
    cockpit_at("lines")
    publish(fleet: %w[a], fleet_tree: [fleet_row])
    cockpit.settles { cockpit.screen.include?("dev  running  1t") || nil }
    cockpit.type("half a line")
    cockpit.settles { cockpit.screen.include?("half a line") || nil }
    sleep(1)
    shown = cockpit.screen.scan("fleet:1 inbox:0").size

    cockpit.resize(6)
    sleep(2)

    expect(cockpit.screen.scan("fleet:1 inbox:0").size).to eq(shown)
  end

  # And the suppression above is BOUNDED. A human who resizes mid-line and then
  # throws the line away has nothing left to protect, so waiting for an ask to
  # end would cost them the HUD for no one's benefit -- which is the defect this
  # whole path exists to kill, merely postponed. Nothing republishes on a
  # discard: the chat's frame does not carry whether a pane is mid-edit, so its
  # own latch suppresses an identical one either way. Ctrl-U, and no Enter.
  it "draws the HUD again once a half-typed line is discarded, with no submit" do
    cockpit_at("lines")
    publish(fleet: %w[a], fleet_tree: [fleet_row])
    cockpit.settles { cockpit.screen.include?("dev  running  1t") || nil }
    cockpit.type("half a line")
    cockpit.settles { cockpit.screen.include?("half a line") || nil }
    sleep(1)
    shown = cockpit.screen.scan("fleet:1 inbox:0").size
    cockpit.resize(6)
    sleep(1)

    cockpit.type("\x15")

    expect(cockpit.settles { cockpit.screen.scan("fleet:1 inbox:0").size > shown || nil }).to be(true)
  end

  # The pane prints its header raw, so a model-written task line reaches a
  # terminal as bytes: `\e[1A\e[2K` walks the cursor onto the HUD line and
  # erases it. Captured off this very harness before the scrub moved to the
  # row's owner.
  it "draws a task line's terminal escape inert, leaving the HUD line where it was" do
    cockpit_at("lines")

    publish(fleet: %w[a], fleet_tree: [fleet_row(task: "clean\e[1A\e[2KPWNED THE HUD LINE")])

    expect(cockpit.settles { cockpit.screen.include?("cleanPWNED THE HUD LINE") || nil }).to be(true)
    expect(cockpit.screen).to include("fleet:1 inbox:0")
    expect(cockpit.screen).not_to include("\e[2K")
  end

  it "decides a gated call from the pane, and the pane's surface signs the verdict" do
    cockpit_at("approval", prompt: "[y/N]")

    cockpit.type("y\r")

    expect(cockpit.settles { cockpit.heard.find { |record| record.key?("approved") } })
      .to include({ "approved" => true })
  end

  it "draws the countdown in the pane on Ctrl-C, and cancels it from there" do
    cockpit_at("countdown")
    cockpit.type("go\r")
    cockpit.settles { File.exist?(File.join(dir, "asking")) || nil }

    cockpit.type("\x03")
    drawn = cockpit.settles { cockpit.screen.include?("[c] cancel") || nil }
    cockpit.type("c")
    File.write(File.join(dir, "done"), "")

    expect([drawn, cockpit.settles { cockpit.heard.find { |record| record.key?("response") } }])
      .to eq([true, { "response" => "answered", "closed" => false }])
  end

  # The race this pins: a countdown published while the pane's line editor is
  # mid-read, which is what a Ctrl-C at a parked approval is. The editor's own
  # finalize puts the terminal's mode back as that read unwinds, and it unwinds
  # on the pump's fiber -- so a countdown that claimed raw mode the instant its
  # frame arrived had the mode taken back out from under it, and every offered
  # key then waited for an Enter the countdown has no way to ask for.
  it "takes a countdown key pressed at a countdown that opened under an open read" do
    cockpit_at("parked")
    cockpit.type("go\r")
    cockpit.settles { cockpit.screen.include?("[y/N]") || nil }

    cockpit.type("\x03")
    drawn = cockpit.settles { cockpit.screen.include?("[c] cancel") || nil }
    cockpit.type("c")
    cockpit.settles { cockpit.screen.scan("[y/N]").size > 1 || nil }
    cockpit.type("y\r")

    expect([drawn, cockpit.settles { cockpit.heard.find { |record| record.key?("reply") } }])
      .to eq([true, { "reply" => "y" }])
  end

  it "rebinds the path a killed chat left behind, and the pane's next line reaches the new chat" do
    cockpit_at("lines")
    killed = cockpit.instance_variable_get(:@chats).first
    Process.kill("KILL", killed)
    Process.wait(killed)
    FileUtils.rm_f(File.join(dir, "bound"))

    cockpit.chat("lines")
    cockpit.settles { File.exist?(File.join(dir, "bound")) || nil }
    cockpit.settles { cockpit.screen.scan("you> ").size > 1 || nil }
    cockpit.type("after the restart\r")

    expect(cockpit.settles { cockpit.heard.find { |record| record["heard"] == "after the restart" } })
      .to eq({ "heard" => "after the restart" })
  end

  it "refuses a second chat on one path, naming it" do
    cockpit.chat("lines")
    cockpit.settles { File.exist?(File.join(dir, "bound")) || nil }

    second = cockpit.chat("lines")
    Process.wait(second)

    expect(cockpit.settles { File.exist?(File.join(dir, "refused")) || nil }).to be(true)
    expect(File.read(File.join(dir, "refused"))).to include(cockpit.path)
  end
end
