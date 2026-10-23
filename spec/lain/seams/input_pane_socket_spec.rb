# frozen_string_literal: true

require "fileutils"
require "json"

# The split cockpit, end to end: a chat process that reads NO stdin and a
# separate `lain input` pane in a real PTY, joined by a real Unix socket. Two
# processes and a file in the filesystem is the whole subject -- a doubled
# socket, or a pane driven in this process, would test neither the pid-free path
# a restarted chat rebinds nor the line editor a human actually types into.
#
# The pane runs THE REPOSITORY'S `exe/lain`, never one the spec runner happens
# to have on PATH: an installed gem's binary is a different program, and a pane
# spec that passed against it would say nothing about this checkout. It comes
# booted from the file's pool, so its load overlaps the example before.
module InputPaneSocket
  # The chat: a real Intake, InputSocket, Conductor and TTY, with its stdin
  # closed so nothing on this side can read a line at all. `lines` reads `you>`
  # until the stream ends; `approval` parks one gated call through a real
  # Approval::Parked::Queue and answers it through the real terminal surface;
  # `countdown` supervises an ask a Ctrl-C can open a grace window on;
  # `running` supervises one until told it is done, then reads `you>` again.
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
    socket = Lain::CLI::InputSocket.new(rail:, path:, commands: -> { %w[approve inbox] }, header:, tick: 0.05)
    begin
      socket.bind
    rescue Lain::CLI::InputSocket::InUse => e
      File.write(File.join(dir, "refused"), e.message)
      exit 3
    end
    conductor = Lain::CLI::Conductor.new(tty:, chronicle: Lain::CLI::Chronicle::Null.new,
                                         signals: Lain::CLI::Signals.new, rail:, grace: 30,
                                         countdown: Lain::CLI::Conductor::RailCountdown.new(rail:), tick: 0.05)

    lines = lambda do |_task|
      Enumerator.produce { conductor.read_prompt("you> ") }.lazy
                .take_while { |line| !line.nil? }.each { |line| log.puts(JSON.generate({ "heard" => line })) }
    end

    approval = lambda do |task|
      queue = Lain::Approval::Parked::Queue.new(journal: Lain::Journal.new(io: out), timeout: 30)
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
      outcome = conductor.supervise(task, -> { Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store) }) do
        File.write(File.join(dir, "asking"), "")
        # The cancel key is still crossing the pane's socket when the spec writes done.
        Async::Task.current.sleep(0.05) until File.exist?(done) && !conductor.counting_down?
        "answered"
      end
      log.puts(JSON.generate({ "response" => outcome.response, "closed" => outcome.closed? }))
    end

    parked = lambda do |task|
      conductor.read_prompt("you> ")
      outcome = conductor.supervise(task, -> { Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store) }) do
        File.write(File.join(dir, "asking"), "")
        log.puts(JSON.generate({ "reply" => conductor.read_reply("apply this edit? [y/N] ") }))
        "answered"
      end
      log.puts(JSON.generate({ "response" => outcome.response, "closed" => outcome.closed? }))
    end

    running = lambda do |task|
      conductor.read_prompt("you> ")
      conductor.supervise(task, -> { Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store) }) do
        File.write(File.join(dir, "asking"), "")
        Async::Task.current.sleep(0.05) until File.exist?(File.join(dir, "done"))
        "answered"
      end
      log.puts(JSON.generate({ "heard" => conductor.read_prompt("you> ") }))
    end

    File.write(File.join(dir, "bound"), "yes")
    conductor.guard do
      Sync do |task|
        socket.start(task)
        { "lines" => lines, "approval" => approval, "countdown" => countdown,
          "parked" => parked, "running" => running }.fetch(shape).call(task)
      end
    end
    socket.stop
    File.write(File.join(dir, "exited"), "")
  RUBY

  # The signalled endings arrive before the script installs any trap, so only
  # what the fork reset decides how they end.
  ENDINGS = {
    "finishes" => ["nil", nil], "exits 3" => ["exit 3", nil],
    "overflows its stack" => ["def deeper = deeper; deeper", nil],
    "runs out of memory" => ["raise NoMemoryError", nil],
    "TERM" => ["File.write(File.join(ARGV[0], ARGV[1]), ''); sleep 10", "TERM"],
    "INT" => ["File.write(File.join(ARGV[0], ARGV[1]), ''); sleep 10", "INT"],
    "raises where its error cannot be written" =>
      ["File.delete(File.join(ARGV[0], 'chat.err')); Dir.mkdir(File.join(ARGV[0], 'chat.err')); raise 'boom'", nil]
  }.freeze

  # Opens pipes on the numbers the worker's dropped IOs held, then collects
  # those IOs: a finalizer that still owned its number would close a pipe.
  PIPES = <<~RUBY
    pipes = Array.new(20) { IO.pipe }
    GC.start
    intact = begin
      pipes.all? { |reader, writer| writer.write("x") && reader.read_nonblock(1) == "x" }
    rescue SystemCallError, IOError
      false
    end
    File.write(File.join(ARGV[0], "pipes"), intact.to_s)
  RUBY

  # One cockpit's two processes and the directory they meet in.
  class Cockpit
    include CursorReport

    attr_reader :dir, :path, :chats

    # @param warm [WarmCockpit::Booted] a pane already spawned on `warm.dir`'s socket
    def initialize(warm)
      @warm = warm
      @dir = warm.dir
      @path = File.join(dir, "input.sock")
      @screen = +""
      @lock = Mutex.new
      @chats = []
      @spent = []
    end

    def env = WarmCockpit.env(@dir, "LAIN_SPEC_GRACE" => "30")

    # A chat process. Returns its pid; `bound` appears once it owns the socket.
    def chat(shape, script: CHILD)
      pid = ForkedChild.start(File.join(@dir, "chat.err")) { run_chat(shape, script) }
      @chats << pid
      pid
    end

    def watch_screen
      @drain ||= Thread.new { drain(@warm.reader) }
      self
    end

    def pane = @warm.pid

    # How a human gets their keyboard back after closing a pane.
    def respawn_pane
      @drain&.kill&.join(1)
      @spent << @warm
      @warm = WarmCockpit::Booted.new(@dir, nil, *WarmCockpit.pane_in(@dir, env))
      @drain = Thread.new { drain(@warm.reader) }
      self
    end

    def type(text) = @warm.writer.write(text)

    # What tmux's `resize-pane` does to a pane, as the pane can see it: the
    # master's winsize, which the slave reads back by ioctl.
    def resize(rows, cols = 80) = @warm.reader.winsize = [rows, cols]

    def screen = @lock.synchronize { @screen.dup }

    def heard
      path = File.join(@dir, "heard.ndjson")
      File.exist?(path) ? File.readlines(path).filter_map { |line| parsed(line) } : []
    end

    def close
      @drain&.kill&.join(1)
      @chats.each { |pid| reap(pid) }
      [*@spent, @warm].each(&:reap)
    end

    # A chat that died first answers false at once, so the example fails with
    # its stderr rather than at the watchdog.
    def bound?(chat)
      settles { File.exist?(File.join(@dir, "bound")) || (Process.waitpid(chat, Process::WNOHANG) && false) }
    end

    def chat_err = File.exist?(File.join(@dir, "chat.err")) ? File.read(File.join(@dir, "chat.err")) : ""

    # Whatever the block answers once it stops answering nil, or nil at the
    # deadline: two processes and a PTY settle on their own clock.
    def settles(within: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
      Enumerator.produce { sleep(0.02) && yield }
                .find { |answer| !answer.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline }
    end

    # What the block reads once it has held still for `ticks` publish ticks: whatever the last change drew has
    # drawn by then. The whole screen is no such measure, since a clock moving under a fleet keeps writing to it.
    # Bounded like {#settles}, so a block that never holds still fails the example rather than hanging it.
    def quiet(ticks: 4, within: 20)
      samples = Enumerator.produce(yield) do
        sleep(0.05 * ticks)
        yield
      end
      samples.each_cons(2).lazy.take((within / (0.05 * ticks)).ceil).find { |was, now| was == now }&.last
    end

    private

    # Forked from the worker, which already holds `lain`: the chat stands in for
    # the far end of the socket and the pane is the subject, so a second boot of
    # the library buys no fidelity.
    def run_chat(shape, script)
      $stdin.reopen(File::NULL)
      $stdout.reopen(File.join(@dir, "chat.err"), "w")
      $stderr.reopen($stdout)
      ForkedChild.close_inherited
      ENV.update(env)
      ARGV.replace([@dir, shape, @path])
      ForkedChild.evaluate(script, "chat_child")
    end

    def parsed(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def drain(reader, writer = @warm.writer)
      Enumerator.produce { reader.readpartial(4096) }.each do |bytes|
        @lock.synchronize { @screen << answered(writer, bytes) }
      end
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
  warm_pool(:panes) { WarmCockpit.pane(prefix: "lain-pane", "LAIN_SPEC_GRACE" => "30") }

  subject(:cockpit) { InputPaneSocket::Cockpit.new(panes.take) }

  let(:dir) { cockpit.dir }

  after { cockpit.close }

  # The chat is up and the pane has drawn its first prompt.
  def cockpit_at(shape, prompt: "you> ")
    cockpit.watch_screen
    expect_bound(cockpit.chat(shape))
    cockpit.settles { cockpit.screen.include?(prompt) || nil }
  end

  def expect_bound(chat)
    expect(cockpit.bound?(chat)).to be(true), -> { "the chat never bound; its stderr:\n#{cockpit.chat_err}" }
  end

  # Anonymous inodes are skipped: the chat keeps the VM's own eventfd and
  # epoll, which IO.for_fd refuses to close, and every anonymous inode reads
  # back as the same link, so it cannot say whose it is.
  def descriptors(pid)
    Dir.children("/proc/#{pid}/fd").map(&:to_i).select { |fd| fd > 2 }.filter_map do |fd|
      target = File.readlink("/proc/#{pid}/fd/#{fd}")
      target unless target.start_with?("anon_inode:")
    rescue Errno::ENOENT
      nil
    end
  end

  it "boots the pane before the chat, and forks the chat holding none of the worker's descriptors" do
    cockpit.watch_screen
    waited = cockpit.settles { cockpit.screen.include?("waiting for a lain chat") || nil }
    File.open(__FILE__) do
      cockpit_at("lines")
      chat = cockpit.chats.first

      forked = File.binread("/proc/#{chat}/cmdline") == File.binread("/proc/self/cmdline")

      expect([waited, forked, descriptors(chat) & descriptors(Process.pid)]).to eq([true, true, []])
    end
  end

  def ended(name, (script, signal))
    chat = cockpit.chat(name, script:)
    if signal
      cockpit.settles(within: 5) { File.exist?(File.join(dir, name)) || nil }
      Process.kill(signal, chat)
    end
    _, status = Process.wait2(chat)
    [status.exitstatus, status.termsig]
  end

  it "ends a forked chat with its own status however it ends, running none of the worker's at_exit hooks" do
    statuses, ran = ForkedChild.in_a_worker_with_hooks(dir) do
      InputPaneSocket::ENDINGS.to_h { |name, ending| [name, ended(name, ending)] }
    end

    expect([statuses, ran]).to eq(
      [{ "finishes" => [0, nil], "exits 3" => [3, nil], "overflows its stack" => [1, nil],
         "runs out of memory" => [1, nil], "TERM" => [nil, 15], "INT" => [nil, 2],
         "raises where its error cannot be written" => [1, nil] }, false]
    )
  end

  it "keeps the chat's own descriptors working across a GC of the worker's dropped IOs" do
    20.times { IO.pipe }

    _, status = Process.wait2(cockpit.chat("pipes", script: InputPaneSocket::PIPES))

    expect([status.exitstatus, File.read(File.join(dir, "pipes"))]).to eq([0, "true"])
  end

  it "answers a line typed in the pane, with the chat reading no stdin of its own" do
    cockpit_at("lines")

    cockpit.type("hello\r")

    expect(cockpit.settles { cockpit.heard.find { |record| record["heard"] == "hello" } })
      .to eq({ "heard" => "hello" })
  end

  # A published struct, as the chat's own header thunk composes one.
  def publish(**state)
    struct = { "fleet" => [], "inbox_count" => 0 }.merge(state.transform_keys(&:to_s))
    File.write(File.join(dir, "hud"), JSON.generate(struct))
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

    # A header landing while the redraw's read has not reopened is dropped, and
    # nothing republishes it, so each attempt publishes a row count of its own
    # until one lands; a fixed pause only holds on a box with CPU to spare.
    redrawn = (2..9).any? do |turns|
      publish(fleet: %w[a], fleet_tree: [fleet_row(turns:)])
      cockpit.settles(within: 3) { cockpit.screen.include?("dev  running  #{turns}t") || nil }
    end

    expect([first, redrawn]).to eq([true, true])
  end

  it "redraws a prompt's header whole when a child spawn adds a row, taking the old one back first" do
    cockpit_at("lines")
    publish(fleet: %w[a], inbox_count: 1)
    cockpit.settles(within: 5) { cockpit.screen.include?("fleet:1 inbox:1") || nil }

    grown = (1..9).any? do |turns|
      publish(fleet: %w[a], inbox_count: 1, fleet_tree: [fleet_row(turns:)])
      cockpit.settles(within: 3) { cockpit.screen.include?("dev  running  #{turns}t") || nil }
    end

    expect([grown, cockpit.screen]).to match([true, /\e\[1A\r\e\[J\r\e\[K.{1,4}fleet:1 inbox:1 \r\n  dev  running/m])
  end

  # The header is the frame, and a pane redraws a changed frame at whatever
  # column the line editor left the cursor on. Measured before the age left
  # the header: seven redraws and seven header prints in eight seconds, and a
  # six-row pane down to one row for its prompt.
  # While an ask runs the pane is idle, and its terminal holds no line the pane cannot see.
  it "redraws the header whole while an ask runs when a spawn adds a row, keeping a draft Enter then sends" do
    cockpit_at("running")
    cockpit.type("go\r")
    cockpit.settles { File.exist?(File.join(dir, "asking")) || nil }
    publish(fleet: %w[a], inbox_count: 1)
    cockpit.settles(within: 5) { cockpit.screen.include?("fleet:1 inbox:1") || nil }
    cockpit.type("abc")
    cockpit.settles { cockpit.screen.end_with?("abc") || nil }

    publish(fleet: %w[a], inbox_count: 1, fleet_tree: [fleet_row])
    redrawn = cockpit.settles { cockpit.screen.include?("dev  running") || nil }
    cockpit.type("\r")
    FileUtils.touch(File.join(dir, "done"))

    expect([redrawn, cockpit.settles { cockpit.heard.find { |record| record.key?("heard") } }, cockpit.screen])
      .to match([true, { "heard" => "abc" },
                 /\e\[1A\r\e\[J\r\e\[K.{1,4}fleet:1 inbox:1 \r\n  dev  running[^\n]*\r\nabc\r\n/m])
  end

  it "redraws nothing while only the clock moves under a running fleet" do
    cockpit_at("lines")
    publish(fleet: %w[a], fleet_tree: [fleet_row])
    cockpit.settles { cockpit.screen.include?("dev  running  1t") || nil }
    # The count is taken over a quiet window rather than across the change itself.
    prompts = -> { cockpit.screen.scan("you> ").size }
    settled = cockpit.quiet(&prompts)

    cockpit.quiet(ticks: 8, &prompts)

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
    # The count is taken over a quiet window rather than across the change itself.
    shown = cockpit.quiet { cockpit.screen.scan("fleet:1 inbox:0").size }

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
    shown = cockpit.quiet { cockpit.screen.scan("fleet:1 inbox:0").size }

    cockpit.resize(6)
    cockpit.quiet(ticks: 8) { cockpit.screen.scan("fleet:1 inbox:0").size }

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
    shown = cockpit.quiet { cockpit.screen.scan("fleet:1 inbox:0").size }
    cockpit.resize(6)
    cockpit.quiet { cockpit.screen.scan("fleet:1 inbox:0").size }

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
    killed = cockpit.chats.first
    Process.kill("KILL", killed)
    Process.wait(killed)
    FileUtils.rm_f(File.join(dir, "bound"))

    expect_bound(cockpit.chat("lines"))
    cockpit.settles { cockpit.screen.scan("you> ").size > 1 || nil }
    cockpit.type("after the restart\r")

    expect(cockpit.settles { cockpit.heard.find { |record| record["heard"] == "after the restart" } })
      .to eq({ "heard" => "after the restart" })
  end

  # HUP is what tmux sends a pane it kills, and the chat is not the pane's to end.
  it "ends only the pane on HUP, and the chat answers a line from a respawned pane" do
    cockpit_at("lines")
    chat = cockpit.chats.first

    Process.kill("HUP", cockpit.pane)
    ended = cockpit.settles(within: 5) { Process.wait2(cockpit.pane, Process::WNOHANG)&.last }
    running = Process.waitpid(chat, Process::WNOHANG).nil?
    drawn = cockpit.screen.scan("you> ").size
    cockpit.respawn_pane.settles(within: 10) { cockpit.screen.scan("you> ").size > drawn || nil }
    cockpit.type("from the new pane\r")
    heard = cockpit.settles(within: 10) { cockpit.heard.find { |record| record["heard"] == "from the new pane" } }

    expect([ended&.exitstatus, running, heard]).to eq([0, true, { "heard" => "from the new pane" }])
  end

  it "refuses a second chat on one path, naming it" do
    expect_bound(cockpit.chat("lines"))

    second = cockpit.chat("lines")
    _, status = Process.wait2(second)

    expect(cockpit.settles { File.exist?(File.join(dir, "refused")) || nil }).to be(true)
    expect(File.read(File.join(dir, "refused"))).to include(cockpit.path)
    expect(status.exitstatus).to eq(3)
  end
end
