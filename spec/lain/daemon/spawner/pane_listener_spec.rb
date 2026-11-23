# frozen_string_literal: true

require "fileutils"
require "json"
require "pty"
require "rbconfig"
require "socket"
require "timeout"
require "tmpdir"

RSpec.describe Lain::Daemon::Spawner::PaneListener, :seam do
  # A hang guard, not a timing assertion: a spawner that never answers fails its example
  # instead of wedging the worker.
  let(:patience) { 30 }
  let(:path) { ENV.fetch("PATH") }
  let(:listening) { File.join(@dir, "run", "spawner.sock") }

  let(:facts) { File.join(@dir, "facts.json") }
  let(:go) { File.join(@dir, "go") }

  # What the program is, from inside it; then, asked to wait, it waits for the file named or `go`.
  let(:program) do
    facts = self.facts
    go = self.go
    listening = self.listening
    pane_conns = method(:pane_conns)
    lambda do |argv|
      fields = File.read("/proc/self/stat").split(") ").last.split
      File.write(facts, JSON.generate("pid" => Process.pid, "sid" => Process.getsid, "tty_nr" => fields[4].to_i,
                                      "stdin" => File.readlink("/proc/self/fd/0"), "cwd" => Dir.pwd,
                                      "env" => ENV.to_h, "pane_conns" => pane_conns.call(listening)))
      sleep 0.01 until argv.first != "wait" || File.exist?(argv.fetch(1, go))
      exit Integer(argv.last) if argv.first == "exit"
    end
  end

  before { skip "needs Linux's ttys and /proc" unless File.directory?("/proc/self/fd") }

  around do |example|
    Dir.mktmpdir("pane") do |dir|
      @dir = dir
      @pids = []
      @strays = []
      @listeners = []
      @terminal = PTY.open
      example.run
    ensure
      @pids.each { |pid| stopped(pid) }
      @strays.each { |pid, at| ended(pid, at) }
      @listeners.each { |listener| listener.close({}) }
      @terminal&.each(&:close)
    end
  end

  def stopped(pid)
    Process.kill(:KILL, pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # A process the example did not fork, killed only while its start time says it is still the same one.
  def ended(pid, at)
    Process.kill(:KILL, pid) if at && started(pid) == at
  rescue Errno::ESRCH
    nil
  end

  # nil once the process is gone: a program that exits at once can be reaped before it is read.
  def stat(pid)
    File.read("/proc/#{pid}/stat").split(") ").last.split
  rescue Errno::ENOENT
    nil
  end

  def started(pid) = stat(pid)&.[](19)

  def stray(pid)
    @strays << [pid, started(pid)]
    pid
  end

  # The program's pid, with the program and its waiter on the cleanup list.
  def forked(conn)
    pid = answer(conn).fetch("pid")
    waiter = waiter_of(pid)
    stray(waiter) if waiter
    stray(pid)
  end

  def waiter_of(pid) = stat(pid)&.[](1)&.to_i

  # A fresh spawner's listener on the same path, closed after the example.
  def rebound = described_class.listen(listening).tap { |listener| @listeners << listener }

  # The program's own fds bound to the pane socket's path: an accepted connection, or the listener.
  def pane_conns(listening)
    Dir.children("/proc/self/fd").count do |fd|
      socket = Socket.for_fd(Integer(fd))
      socket.autoclose = false
      socket.local_address.unix_path == listening
    rescue SystemCallError, SocketError, ArgumentError
      false
    end
  end

  def run_request(argv)
    JSON.generate("argv" => argv, "env" => { "PATH" => path }, "cwd" => @dir, "log" => File.join(@dir, "run.log"))
  end

  def changed(root) = File.write(File.join(root, "lib", "lain.rb"), "# changed\n")

  def leader = @terminal.first
  def follower = @terminal.last

  def install
    File.join(@dir, "install").tap do |root|
      FileUtils.mkdir_p(File.join(root, "lib", "lain"))
      FileUtils.mkdir_p(File.join(root, "exe"))
      File.write(File.join(root, "lib", "lain.rb"), "# lain\n")
      File.write(File.join(root, "exe", "lain"), "#!/usr/bin/env ruby\n")
    end
  end

  # The spawner in a forked process of its own, listening for panes as `lain daemon spawner` does.
  def hosted(starter, root: install, deadline: described_class::DEADLINE, setup: -> {})
    ours, theirs = UNIXSocket.pair
    report, reported = IO.pipe
    @pids << fork do
      ours.close
      report.close
      host(-> { spawner(theirs, starter, root:, deadline:) }, setup:, reported:)
    end
    [theirs, reported].each(&:close)
    Timeout.timeout(patience) { sleep 0.01 until File.socket?(listening) }
    (@ends ||= []).push(ours, report)
    [ours, report]
  end

  def spawner(socket, starter, root:, deadline:)
    Lain::Daemon::Spawner.new(socket:, starter:, root:, pane_listener: described_class.listen(listening, deadline:))
  end

  def host(built, setup:, reported:)
    status = 1
    begin
      setup.call
      built.call.call
      reported.puts(JSON.generate("threads" => Thread.list.size))
      status = 0
    rescue StandardError => e
      reported.puts(JSON.generate("raised" => e.class.name))
    ensure
      reported.close
      exit!(status)
    end
  end

  # As a pane's client asks: a session leader that gives its terminal up, then sends it over.
  # The connection comes back to the example, which reads the answers and can hang up.
  def pane(argv, socket: listening, env: { "PATH" => path }, cwd: @dir)
    ours, theirs = UNIXSocket.pair
    @pids << fork { ask_as_client(socket, theirs, "argv" => argv, "env" => env, "cwd" => cwd) }
    theirs.close
    raise "the client never connected" unless ours.wait_readable(patience)

    ours.recv_io(UNIXSocket).tap { ours.close }
  end

  def ask_as_client(socket, back, fields)
    Process.setsid
    File.open(follower.path, "r+") do |tty|
      Signal.trap("HUP", "IGNORE")
      tty.ioctl(tiocnotty, 0)
      conn = UNIXSocket.new(socket)
      conn.puts(JSON.generate(fields))
      conn.send_io(tty)
      back.send_io(conn)
    end
  ensure
    exit!(0)
  end

  # Linux's own ioctl number: the client gives up the terminal the way a pane's session leader does.
  def tiocnotty = 0x5422

  def answer(socket)
    raise "no answer came" unless socket.wait_readable(patience)

    line = socket.gets
    line && JSON.parse(line)
  end

  # A line, not the whole pipe: a pane's waiter forked from the host holds the pipe's other end.
  def finished(report)
    raise "the spawner did not finish" unless report.wait_readable(patience)

    JSON.parse(report.gets)
  end

  def appeared(file) = Timeout.timeout(patience) { sleep 0.01 until File.exist?(file) }

  # /proc's tty_nr is the kernel's own encoding of the device number.
  def tty_nr(device)
    stat = File.stat(device)
    (stat.rdev_minor & 0xff) | (stat.rdev_major << 8) | ((stat.rdev_minor & ~0xff) << 12)
  end

  describe "a pane request" do
    it "runs the program as a session leader on the passed terminal, holding no pane connection" do
      hosted(program)
      cwd = File.join(@dir, "work").tap { |dir| Dir.mkdir(dir) }

      conn = pane(%w[report], env: { "PATH" => path, "ONLY" => "this" }, cwd:)

      pid = forked(conn)
      expect(answer(conn)).to eq("pid" => pid, "status" => 0)
      expect(JSON.parse(File.read(facts)))
        .to eq("pid" => pid, "sid" => pid, "tty_nr" => tty_nr(follower.path), "stdin" => follower.path,
               "cwd" => File.realpath(cwd), "env" => { "PATH" => path, "ONLY" => "this" }, "pane_conns" => 0)
    end

    it "relays the program's exit status to the client" do
      hosted(program)

      conn = pane(%w[exit 3])

      pid = forked(conn)
      expect(answer(conn)).to eq("pid" => pid, "status" => 3)
    end

    it "keeps the waiter and the program alive through a kill of the spawner's group" do
      hosted(program, setup: -> { Process.setpgid(0, 0) })
      spawner = @pids.first
      conn = pane(%w[wait])
      pid = forked(conn)
      appeared(facts)

      Process.kill(:KILL, -spawner)
      Process.wait(spawner)

      expect(Process.kill(0, pid)).to eq(1)
      File.write(go, "")
      expect(answer(conn)).to eq("pid" => pid, "status" => 0)
    end

    it "hangs the program up when the client's socket closes" do
      hung = File.join(@dir, "hung")
      ready = File.join(@dir, "ready")
      hosted(lambda do |_argv|
        Signal.trap("HUP") { File.write(hung, "HUP") && exit(129) }
        File.write(ready, "")
        sleep
      end)
      conn = pane(%w[sleep])
      forked(conn)
      appeared(ready)

      conn.close

      appeared(hung)
      expect(File.read(hung)).to eq("HUP")
    end

    it "answers a request that is not 1 JSON object with an error, forking nothing" do
      hosted(program)
      conn = UNIXSocket.new(listening)
      conn.puts("[1]")
      conn.send_io(follower)

      expect(answer(conn).keys).to eq(["error"])
      expect(File.exist?(facts)).to be(false)
    end
  end

  describe "a stalled client" do
    it "does not hold the loop that forks the daemon's runs" do
      socket, = hosted(program, deadline: 60)
      stalled = UNIXSocket.new(listening)

      socket.puts(run_request([]))

      expect(answer(socket)).to include("pid")
      expect(stalled.read_nonblock(1, exception: false)).to eq(:wait_readable)
    end

    it "is answered with an error and hung up on at its deadline" do
      hosted(program, deadline: 0.2)
      stalled = UNIXSocket.new(listening)

      expect(answer(stalled).keys).to eq(["error"])
      expect(answer(stalled)).to be_nil
    end
  end

  describe "the socket's path" do
    it "is free for a fresh spawner once a kill of the old one's group leaves its pane running" do
      hosted(program, setup: -> { Process.setpgid(0, 0) })
      spawner = @pids.first
      forked(pane(%w[wait]))
      appeared(facts)

      Process.kill(:KILL, -spawner)
      Process.wait(spawner)

      expect(rebound).to be_a(described_class)
    end

    it "is free for a fresh spawner once the old one dies with a headless run live" do
      socket, = hosted(program)
      socket.puts(run_request(%w[wait]))
      stray(answer(socket).fetch("pid"))
      appeared(facts)

      stopped(@pids.first)

      expect(rebound).to be_a(described_class)
    end

    it "is not listened on away from Linux, so a pane there starts by exec" do
      expect(described_class.listen(listening, host_os: "darwin23.4.0")).to be_a(described_class::Off)
      expect(File.exist?(listening)).to be(false)
    end
  end

  describe "the daemon's stream" do
    it "reports a run's exit and never a pane's" do
      socket, = hosted(program)
      held = File.join(@dir, "held")
      socket.puts(run_request(["wait", held]))
      run = stray(answer(socket).fetch("pid"))
      conn = pane(["wait", go])
      pid = forked(conn)
      waiter = waiter_of(pid)

      File.write(go, "")
      expect(answer(conn)).to eq("pid" => pid, "status" => 0)
      Timeout.timeout(patience) { sleep 0.01 while File.exist?("/proc/#{waiter}") }
      File.write(held, "")

      expect(answer(socket)).to eq("pid" => run, "status" => 0)
    end
  end

  describe "when lain's own code changed" do
    it "frees the path at once, before a live run is reaped" do
      root = install
      socket, = hosted(program, root:)
      socket.puts(run_request(%w[wait]))
      run = stray(answer(socket).fetch("pid"))
      appeared(facts)
      changed(root)

      socket.puts(run_request([]))

      expect(answer(socket)).to eq("stale" => true)
      expect([File.exist?(listening), rebound]).to match([false, an_instance_of(described_class)])
      File.write(go, "")
      expect(answer(socket)).to eq("pid" => run, "status" => 0)
    end

    it "returns while a pane it forked still runs, since only runs are the daemon's to hear of" do
      root = install
      socket, report = hosted(program, root:)
      conn = pane(%w[wait])
      forked(conn)
      changed(root)

      socket.puts(run_request([]))

      expect(answer(socket)).to eq("stale" => true)
      expect(finished(report)).to eq("threads" => 1)
      File.write(go, "")
      expect(answer(conn)).to include("status" => 0)
    end

    it "unlinks the pane socket, says stale once on stdin unasked, and forks nothing" do
      root = install
      socket, report = hosted(program, root:)
      changed(root)

      conn = pane(%w[report])

      expect(answer(conn)).to eq("stale" => true)
      expect([answer(socket), answer(socket)]).to eq([{ "stale" => true }, nil])
      expect(File.exist?(listening)).to be(false)
      expect(File.exist?(facts)).to be(false)
      expect(finished(report)).to eq("threads" => 1)
    end
  end

  describe "`lain daemon spawner`" do
    def spawner_env(home)
      { "HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config"),
        "XDG_STATE_HOME" => File.join(home, ".state"), "XDG_RUNTIME_DIR" => File.join(home, "run") }
    end

    def real_spawner(home)
      ours, theirs = UNIXSocket.pair
      exe = File.join(Lain::Paths::Shipped::GEM_ROOT, "exe", "lain")
      @pids << Process.spawn(spawner_env(home), RbConfig.ruby, exe, "daemon", "spawner",
                             in: theirs, out: File::NULL, err: File.join(@dir, "spawner.err"), close_others: true)
      theirs.close
      ours
    end

    def held(pid)
      Dir.children("/proc/#{pid}/fd").sort_by(&:to_i).map do |fd|
        File.readlink("/proc/#{pid}/fd/#{fd}").sub(/:\[\d+\]\z/, "")
      end
    end

    # Read as it comes, so a full terminal never stalls the program; it ends once no follower is open.
    def drained(io)
      Thread.new do
        shown = +""
        shown << io.readpartial(4096) while io.wait_readable(patience)
        shown
      rescue Errno::EIO, EOFError
        shown
      end
    end

    it "runs lain on the pane's terminal, and keeps no descriptor of the pane's afterwards" do
      home = File.join(@dir, "home")
      daemon_end = real_spawner(home)
      socket = Lain::Paths.new(env: spawner_env(home)).spawner_socket
      Timeout.timeout(patience) { sleep 0.01 until File.socket?(socket) }
      shown = drained(leader)

      conn = pane(%w[help], socket:, env: spawner_env(home).merge("PATH" => path))

      pid = answer(conn).fetch("pid")
      expect(answer(conn)).to eq("pid" => pid, "status" => 0)
      fds = held(@pids.first)
      expect(fds.first(3)).to eq([File::NULL, File::NULL, File.join(@dir, "spawner.err")])
      expect(fds.drop(3)).to contain_exactly("anon_inode:[eventfd]", "anon_inode:[eventpoll]", "socket", "socket",
                                             "pipe", "pipe")
      follower.close
      expect(shown.value).to include("lain daemon")
      daemon_end.close
    end
  end
end
