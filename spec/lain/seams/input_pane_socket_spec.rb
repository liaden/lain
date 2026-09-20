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

  # The chat: a real InputRail, InputSocket, Conductor and TTY, with its stdin
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
    rail = Lain::Frontend::InputRail.new(screen: tty)
    socket = Lain::CLI::InputSocket.new(rail:, path:, commands: -> { %w[approve inbox] },
                                        header: -> { File.exist?(hud) ? File.read(hud).chomp : "" })
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

    File.write(File.join(dir, "bound"), "yes")
    conductor.guard do
      Sync do |task|
        socket.start(task)
        { "lines" => lines, "approval" => approval, "countdown" => countdown }.fetch(shape).call(task)
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

  it "shows the chat's header above the prompt, refreshed with no keypress" do
    cockpit_at("lines")

    File.write(File.join(dir, "hud"), "fleet:2 inbox:1")

    expect(cockpit.settles { cockpit.screen.include?("fleet:2 inbox:1") || nil }).to be(true)
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
