# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "socket"
require "timeout"
require "tmpdir"

RSpec.describe Lain::Daemon::Spawner, :seam do
  # A hang guard, not a timing assertion: a spawner that never answers fails its example
  # instead of wedging the worker.
  let(:patience) { 30 }
  let(:path) { ENV.fetch("PATH") }

  before { skip "this host cannot fork" unless Process.respond_to?(:fork) }

  around do |example|
    Dir.mktmpdir("spawner") do |dir|
      @dir = dir
      @pids = []
      example.run
    ensure
      @pids.each { |pid| stopped(pid) }
    end
  end

  def stopped(pid)
    Process.kill(:KILL, pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # An installed tree of its own, so a spec can change it without touching lain's.
  def install
    File.join(@dir, "install").tap do |root|
      FileUtils.mkdir_p(File.join(root, "lib", "lain"))
      FileUtils.mkdir_p(File.join(root, "exe"))
      File.write(File.join(root, "lib", "lain.rb"), "# lain\n")
      File.write(File.join(root, "lib", "lain", "lain.so"), "built")
      File.write(File.join(root, "exe", "lain"), "#!/usr/bin/env ruby\n")
    end
  end

  # The spawner in a forked process of its own, as `lain daemon spawner` runs it, answering
  # on a socketpair. What it reports once its socket closes is its own state after serving.
  def hosted(starter, root: install, setup: -> {}, via_stdin: false)
    ours, theirs = UNIXSocket.pair
    report, reported = IO.pipe
    @pids << fork do
      built = -> { via_stdin ? on_stdin(starter, theirs) : described_class.new(socket: theirs, starter:, root:) }
      host(built, setup:, reported:, unused: [ours, report])
    end
    [theirs, reported].each(&:close)
    [ours, report]
  end

  # As `lain daemon spawner` gets it: the socket on fd 0.
  def on_stdin(starter, socket)
    $stdin.reopen(socket)
    socket.close
    described_class.on_stdin(starter:)
  end

  def host(built, setup:, reported:, unused:)
    status = 1
    unused.each(&:close)
    begin
      setup.call
      spawner = built.call
      journals = open_journals
      spawner.call
      reported.write(JSON.generate(state(journals)))
      status = 0
    rescue StandardError => e
      reported.write(JSON.generate("raised" => e.class.name))
    ensure
      reported.close
      exit!(status)
    end
  end

  def state(journals)
    { "threads" => Thread.list.size, "scheduler" => !Fiber.scheduler.nil?,
      "journals" => (open_journals - journals).size }
  end

  # By identity, so a Journal an earlier example left open, closed or collected while the
  # spawner served, cannot change the answer.
  def open_journals = ObjectSpace.each_object(Lain::Journal).reject(&:closed?).map(&:object_id)

  def ask(socket, argv: [], env: { "PATH" => path }, cwd: @dir, log: File.join(@dir, "run.log"))
    socket.puts(JSON.generate("argv" => argv, "env" => env, "cwd" => cwd, "log" => log))
  end

  def answer(socket)
    raise "the spawner did not answer" unless socket.wait_readable(patience)

    line = socket.gets
    line && JSON.parse(line)
  end

  def finished(report)
    raise "the spawner did not finish" unless report.wait_readable(patience)

    JSON.parse(report.read)
  end

  describe "a spawn request" do
    let(:probe) do
      lambda do |argv|
        $stdout.puts(JSON.generate("argv" => argv, "sid" => Process.getsid, "pid" => Process.pid,
                                   "cwd" => Dir.pwd, "env" => ENV.to_h, "stdin" => $stdin.read,
                                   "chld" => Signal.trap("CHLD", "DEFAULT")))
        warn "on stderr"
        exit 3
      end
    end

    let(:forgetting) do
      lambda do
        allow(Lain::Config).to receive(:forget!).and_wrap_original do |forget|
          File.write(File.join(@dir, "forgot"), JSON.generate("cwd" => Dir.pwd, "only" => ENV.fetch("ONLY", nil)))
          forget.call
        end
      end
    end

    it "forks a session in its own session, logged, in the asked cwd and env, and reports its exit" do
      socket, = hosted(probe, setup: forgetting, via_stdin: true)
      cwd = File.join(@dir, "work").tap { |dir| Dir.mkdir(dir) }
      ask(socket, argv: %w[chat --non-interactive], env: { "PATH" => path, "ONLY" => "this" }, cwd:)

      pid = answer(socket).fetch("pid")
      expect(answer(socket)).to eq("pid" => pid, "status" => 3)
      said, ran = File.readlines(File.join(@dir, "run.log"), chomp: true).partition { |line| line == "on stderr" }
      expect(said).to eq(["on stderr"])
      expect(JSON.parse(File.read(File.join(@dir, "forgot")))).to eq("cwd" => File.realpath(cwd), "only" => "this")
      expect(JSON.parse(ran.sole)).to eq("argv" => %w[chat --non-interactive], "sid" => pid, "pid" => pid,
                                         "cwd" => File.realpath(cwd), "env" => { "PATH" => path, "ONLY" => "this" },
                                         "stdin" => "", "chld" => "DEFAULT")
      expect(File.stat(File.join(@dir, "run.log")).mode & 0o777).to eq(0o600)
    end

    it "appends to the run's log, keeping what an earlier run wrote" do
      File.write(File.join(@dir, "run.log"), "earlier\n")
      socket, = hosted(->(_argv) { $stdout.puts("later") })
      ask(socket)

      answer(socket)
      answer(socket)
      expect(File.readlines(File.join(@dir, "run.log"), chomp: true)).to eq(%w[earlier later])
    end

    it "refuses a log that is a symlink, writing nothing through it" do
      target = File.join(@dir, "target").tap { |path| File.write(path, "") }
      File.symlink(target, File.join(@dir, "run.log"))
      said = File.join(@dir, "spawner.err")
      socket, = hosted(->(_argv) { $stdout.puts("through") }, setup: -> { $stderr.reopen(said, "w") })
      ask(socket)

      pid = answer(socket).fetch("pid")
      expect(answer(socket)).to eq("pid" => pid, "status" => 1)
      expect(File.read(target)).to be_empty
      expect(File.read(said)).to include("Too many levels of symbolic links")
    end

    it "logs a run that crashed, with status 1" do
      socket, = hosted(->(_argv) { raise ArgumentError, "the run broke" })
      ask(socket)

      pid = answer(socket).fetch("pid")
      expect(answer(socket)).to eq("pid" => pid, "status" => 1)
      expect(File.read(File.join(@dir, "run.log"))).to include("the run broke (ArgumentError)")
    end

    it "logs a run whose cwd is missing, with status 1" do
      socket, = hosted(->(_argv) { $stdout.puts("ran") })
      ask(socket, cwd: File.join(@dir, "missing"))

      pid = answer(socket).fetch("pid")
      expect(answer(socket)).to eq("pid" => pid, "status" => 1)
      expect(File.read(File.join(@dir, "run.log"))).to include("No such file or directory")
      expect(File.readlines(File.join(@dir, "run.log"), chomp: true)).not_to include("ran")
    end

    it "runs none of the spawner's at_exit hooks in a run" do
      marker = File.join(@dir, "at_exit")
      socket, = hosted(->(_argv) {}, setup: -> { at_exit { File.write(marker, "ran") } })
      ask(socket)

      answer(socket)
      expect(answer(socket)).to include("status" => 0)
      expect(File.exist?(marker)).to be(false)
    end

    it "reports a run a signal ended as 128 plus the signal" do
      socket, = hosted(->(_argv) { Process.kill(:TERM, Process.pid) && sleep })
      ask(socket)

      pid = answer(socket).fetch("pid")
      expect(answer(socket)).to eq("pid" => pid, "status" => 128 + Signal.list.fetch("TERM"))
    end

    it "leaves the run no end of its socket, so the spawner's death reads as an end of file" do
      socket, = hosted(->(_argv) { sleep })
      ask(socket)
      @pids << answer(socket).fetch("pid")

      stopped(@pids.first)

      expect(answer(socket)).to be_nil
    end

    it "is a command `lain daemon help` does not list, since only the daemon starts it" do
      expect { Lain::CLI::DaemonCommand.start(["help"], debug: true) }
        .to output(a_string_including(" status ").and(satisfy { |listed| !listed.include?("spawner") })).to_stdout
    end

    def real_spawner(home)
      ours, theirs = UNIXSocket.pair
      exe = File.join(Lain::Paths::Shipped::GEM_ROOT, "exe", "lain")
      @pids << Process.spawn(spawner_env(home), RbConfig.ruby, exe, "daemon", "spawner",
                             in: theirs, out: File::NULL, err: File.join(@dir, "spawner.err"), close_others: true)
      theirs.close
      ours
    end

    def spawner_env(home)
      { "HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config"),
        "XDG_STATE_HOME" => File.join(home, ".state"), "XDG_RUNTIME_DIR" => File.join(home, "run") }
    end

    def ran_help(socket, home)
      ask(socket, argv: ["help"], env: spawner_env(home).merge("PATH" => path))
      pid = answer(socket).fetch("pid")
      expect(answer(socket)).to eq("pid" => pid, "status" => 0)
    end

    it "runs lain itself from `lain daemon spawner`, starting no daemon" do
      home = File.join(@dir, "home")
      ours = real_spawner(home)

      ran_help(ours, home)
      expect(File.read(File.join(@dir, "run.log"))).to include("lain daemon")
      ours.close
      expect(Timeout.timeout(patience) { Process.wait2(@pids.first).last }).to be_success
      expect(Dir.exist?(File.join(home, "run", "lain", "daemon"))).to be(false)
    end

    # Ruby's own eventfd and epoll, the socket, the self-pipe, and stdio: no run's log, no journal.
    it "holds only its own fds after a run" do
      skip "reads /proc, which only Linux has" unless File.directory?("/proc/self/fd")
      home = File.join(@dir, "home")
      ours = real_spawner(home)

      ran_help(ours, home)

      held = Dir.children("/proc/#{@pids.first}/fd").sort_by(&:to_i).map do |fd|
        File.readlink("/proc/#{@pids.first}/fd/#{fd}").sub(/:\[\d+\]\z/, "")
      end
      expect(held.first(3)).to eq([File::NULL, File::NULL, File.join(@dir, "spawner.err")])
      expect(held.drop(3)).to contain_exactly("anon_inode:[eventfd]", "anon_inode:[eventpoll]", "socket", "pipe",
                                              "pipe")
    end
  end

  describe "a request it cannot run" do
    {
      "a line that is not JSON" => "not json\n",
      "a JSON value that is not an object" => "[1]\n",
      "argv that is not a list of strings" => %({"argv":"help","env":{},"cwd":"/","log":"/tmp/x"}\n),
      "env with a value that is not a string" => %({"argv":[],"env":{"A":1},"cwd":"/","log":"/tmp/x"}\n),
      "a missing log" => %({"argv":[],"env":{},"cwd":"/"}\n)
    }.each do |what, line|
      it "answers #{what} with an error and keeps serving" do
        socket, = hosted(->(_argv) {})
        socket.write(line)

        expect(answer(socket).keys).to eq(["error"])
        ask(socket)
        expect(answer(socket)).to include("pid")
      end
    end
  end

  describe "its own state" do
    let(:chat) do
      lambda do |_argv|
        Sync { Lain::Journal.new(io: File.open(File.join(Dir.pwd, "#{Process.pid}.ndjson"), "w"), owns_io: true) }
      end
    end

    it "holds 1 thread, no Journal and no reactor after 10 spawns" do
      socket, report = hosted(chat)
      10.times { ask(socket) }

      answers = Array.new(20) { answer(socket) }
      socket.close

      expect(answers.count { |reply| reply.key?("status") }).to eq(10)
      expect(finished(report)).to eq("threads" => 1, "scheduler" => false, "journals" => 0)
    end

    it "refuses to fork while another thread lives, since its locks could be held at the fork" do
      socket, report = hosted(chat, setup: -> { Thread.new { sleep } })
      ask(socket)

      expect(answer(socket)).to be_nil
      expect(finished(report)).to eq("raised" => "Lain::Daemon::Spawner::Threaded")
    end
  end

  describe "when lain's own code changed" do
    it "still reports a run that was live at the stale answer, then exits" do
      root = install
      go = File.join(@dir, "go")
      socket, report = hosted(->(_argv) { sleep 0.01 until File.exist?(go) }, root:)
      ask(socket)
      pid = answer(socket).fetch("pid")

      File.write(File.join(root, "lib", "lain.rb"), "# changed\n")
      ask(socket)
      expect(answer(socket)).to eq("stale" => true)
      File.write(go, "")

      expect(answer(socket)).to eq("pid" => pid, "status" => 0)
      expect(finished(report)).to include("threads" => 1)
    end

    {
      "a file's mtime" => ->(root) { File.utime(Time.now + 60, Time.now + 60, File.join(root, "lib", "lain.rb")) },
      "a file's size" => ->(root) { File.write(File.join(root, "lib", "lain", "lain.so"), "rebuilt") },
      "a new file" => ->(root) { File.write(File.join(root, "lib", "lain", "new.rb"), "") },
      "exe/lain" => ->(root) { File.write(File.join(root, "exe", "lain"), "#!/bin/sh\n") }
    }.each do |change, changed|
      it "replies stale to the next request and exits, forking nothing, after #{change}" do
        root = install
        socket, report = hosted(->(_argv) {}, root:)
        ask(socket)
        expect(answer(socket)).to include("pid")
        expect(answer(socket)).to include("status" => 0)

        changed.call(root)
        ask(socket, log: File.join(@dir, "stale.log"))

        expect(answer(socket)).to eq("stale" => true)
        expect(finished(report)).to include("threads" => 1)
        expect(File.exist?(File.join(@dir, "stale.log"))).to be(false)
      end
    end
  end
end
