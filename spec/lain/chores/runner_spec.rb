# frozen_string_literal: true

require "fcntl"
require "fileutils"
require "rbconfig"
require "shellwords"
require "tmpdir"

RSpec.describe Lain::Chores::Runner, :seam do
  include WaitUntil

  around do |example|
    Dir.mktmpdir("lain-chores-runner") do |dir|
      @dir = File.realpath(dir)
      @main = File.join(@dir, "main")
      @lease_path = File.join(@dir, "lease")
      [@main, @lease_path].each { |repo| FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", repo.tap { FileUtils.mkdir_p(_1) }) }
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: SpecHome.env({ "XDG_RUNTIME_DIR" => @dir, "XDG_STATE_HOME" => File.join(@dir, "state") })) }
  let(:todos) { File.join(@main, "TODOS.md") }
  let(:queue) { Lain::Chores::Queue.at(@main, lock: Lain::FileLock.new(File.join(@dir, "queue.lock"))) }
  let(:program) { "/opt/lain/exe/lain" }
  let(:notes) { [] }
  let(:notices) { ->(*note) { notes << note } }
  let(:spawns) { [] }
  let(:acquired) { [] }
  let(:releases) { [] }
  let(:entry) { instance_double(Lain::Isolation::MergeCoordinator::Spool::Entry, id: "entry-1") }
  let(:lander) { instance_double(Lain::CLI::Land, queued: entry, wait: 0) }
  let(:landed_from) { [] }

  let(:base) { git(@lease_path, "rev-parse", "HEAD") }

  let(:backend) do
    leasing = method(:lease_for)
    Object.new.tap { |backend| backend.define_singleton_method(:acquire) { |id| leasing.call(id) } }
  end

  let(:release_action) { ->(discard: false) { releases << discard } }

  def lease_for(id)
    acquired << id
    Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.new(cwd: @lease_path, env: {}),
                               on_release: release_action,
                               origin: Lain::Isolation::Lease::Origin.new(path: @lease_path, base:, branch: "main"))
  end

  before do
    base
    @logs = File.join(@dir, "logs").tap { FileUtils.mkdir_p(_1) }
  end

  def git(dir, *) = SeedRepo.git(dir, *).stdout.strip

  def chores(*lines) = File.write(todos, "# Chores\n#{lines.map { "#{_1}\n" }.join}")

  def line = File.readlines(todos, chomp: true).fetch(1)

  def session_dir(root) = paths.filing_dir(root:)

  # Stands in for `lain chat`: files a session where the chat would, does the chat's work in
  # the spec process, then leaves a real process in its own group to answer for it.
  def chat(exit: 0, commit: false, command: nil, files: true, stderr: nil)
    lambda do |*argv, **options|
      root = options.fetch(:chdir)
      spawns << { argv:, options:, line:, todos_in_lease: File.exist?(File.join(root, "TODOS.md")) }
      File.write(File.join(session_dir(root), "2026-10-28T00-00-00-chat.ndjson"), "{}\n") if files
      if commit
        File.write(File.join(root, "foo_spec.rb"), "# spec\n")
        git(root, "add", "foo_spec.rb")
        git(root, "commit", "-q", "-m", "add a spec")
      end
      command ||= ["sh", "-c", "#{"printf '%s\\n' #{stderr.shellescape} >&2; " if stderr}exit #{exit}"]
      Process.spawn(*command, pgroup: options.fetch(:pgroup), err: options.fetch(:err))
    end
  end

  def reporting(report)
    lambda do |*argv, **options|
      root = options.fetch(:chdir)
      FileUtils.mkdir_p(File.join(root, "planning"))
      File.write(File.join(root, report), "# x and y: research\n")
      git(root, "add", report)
      git(root, "commit", "-q", "-m", "research x and y")
      chat(exit: 0).call(*argv, **options)
    end
  end

  def runner(spawner:, land: lander, backend: self.backend, lain: program, **)
    factory = lambda do |path|
      landed_from << path
      land
    end
    described_class.new(queue:, backend:, lain:, land: factory, notices:, paths:, logs: @logs, max_cost: 2,
                        spawner:, **)
  end

  def live_log = Dir.glob(File.join(@logs, "*.stderr.log")).first

  def session = Dir.glob(File.join(session_dir(@lease_path), "*.ndjson")).sole

  describe "an item that lands" do
    before { chores("- [ ] add a spec for Foo#bar") }

    let!(:outcomes) { runner(spawner: chat(commit: true)).to_a }
    let(:item) { Lain::Chores::Item.parse("- [ ] add a spec for Foo#bar") }
    let(:head) { git(@lease_path, "rev-parse", "HEAD") }

    it "claims the line before the chat runs, and cuts a lease named by the item's id" do
      expect(spawns.sole[:line]).to start_with("- [~] add a spec for Foo#bar  <!-- lain pid=#{Process.pid} ")
      expect(acquired).to eq([item.id])
    end

    it "runs lain chat headless inside the lease with the brief, in its own process group" do
      argv, options = spawns.sole.values_at(:argv, :options)

      expect(argv).to eq([RbConfig.ruby, program, "chat", "--root", @lease_path, "--cwd", @lease_path,
                          "--non-interactive", "--approval", "auto", "--max-cost", "2",
                          "--confirm-price-tier", "refuse", "--prompt", Lain::Chores::Brief.for(item)])
      expect(options).to include(pgroup: true, chdir: @lease_path, in: File::NULL)
    end

    it "enqueues the lease's HEAD from inside the lease under the item's id, and waits on that entry" do
      expect(landed_from).to eq([@lease_path])
      expect(lander).to have_received(:queued).with("HEAD", id: item.id)
      expect(lander).to have_received(:wait).with("entry-1", timeout: 1800)
    end

    it "marks the line done with the landed sha and the session path, and releases the lease" do
      expect(line).to eq("- [x] add a spec for Foo#bar  <!-- landed #{head} #{session} -->")
      expect(releases).to eq([false])
    end

    it "yields the outcome and writes a feed note titled with the item" do
      expect(outcomes).to eq([Lain::Chores::Outcome.new(item: outcomes.sole.item, status: :landed, session:,
                                                        sha: head, note: "landed")])
      expect(notes).to eq([["lain", "add a spec for Foo#bar", "landed #{head} #{session}"]])
    end
  end

  it "fails a chat that made no commit without an enqueue, and releases the clean lease" do
    chores("- [ ] add a spec for Foo#bar")

    outcome = runner(spawner: chat(exit: 0)).to_a.sole

    expect(outcome.status).to eq(:failed)
    expect(line).to eq("- [!] add a spec for Foo#bar  <!-- no commit #{session} -->")
    expect(lander).not_to have_received(:queued)
    expect(releases).to eq([false])
    expect(notes.sole.last).to eq("failed: no commit #{session}")
  end

  it "lands a commit the chat made before it exited nonzero, and says how the chat exited" do
    chores("- [ ] add a spec for Foo#bar")

    outcome = runner(spawner: chat(exit: 1, commit: true)).to_a.sole

    head = git(@lease_path, "rev-parse", "HEAD")
    expect(outcome.status).to eq(:landed)
    expect(lander).to have_received(:queued).with("HEAD", id: outcome.item.id)
    expect(line).to eq("- [x] add a spec for Foo#bar  <!-- landed; chat exited 1 #{head} #{session} -->")
    expect(releases).to eq([false])
  end

  it "fails a chat that exited nonzero with HEAD unmoved, with the chat's failure and no enqueue" do
    chores("- [ ] add a spec for Foo#bar")

    outcome = runner(spawner: chat(exit: 1)).to_a.sole

    expect(outcome.status).to eq(:failed)
    expect(line).to eq("- [!] add a spec for Foo#bar  <!-- chat exited 1 #{session} -->")
    expect(lander).not_to have_received(:queued)
    expect(releases).to eq([false])
    expect(notes.sole.last).to eq("failed: chat exited 1 #{session}")
  end

  describe Lain::Chores::Runner::Tail do
    def tailing(reader, name = "tail.log") = described_class.new(reader, log: File.join(@logs, name), secrets: [])

    # The kernel refuses to grow a pipe once this user's pipes hold fs.pipe-user-pages-soft pages, a budget every
    # process of the user on the box shares, so another suite's pipes can spend it. Past fs.pipe-max-size it refuses
    # with the same EPERM, and on CI a spent budget means this suite leaks pipes, so neither is skipped.
    def grow(pipe)
      pipe.fcntl(Fcntl::F_SETPIPE_SZ, 1 << 20)
    rescue Errno::EPERM
      raise if ENV["CI"] || File.read("/proc/sys/fs/pipe-max-size").to_i < 1 << 20

      skip "no pipe can grow while this user's pipes hold fs.pipe-user-pages-soft"
    end

    it "reads what is left in the pipe once the writer has closed" do
      reader, writer = IO.pipe
      writer.write("last\n")
      writer.close

      tail = tailing(reader).finish

      expect([tail.last_line, File.read(File.join(@logs, "tail.log"))]).to eq(%W[last last\n])
    end

    it "keeps what a read ends inside of as a replacement character when the writer closes" do
      reader, writer = IO.pipe
      writer.write("ok \xC3".b)
      writer.close

      tailing(reader).finish

      expect(File.read(File.join(@logs, "tail.log"))).to eq("ok \uFFFD")
    end

    it "takes several chunks in one drain, so a flood is not read one chunk per wait" do
      skip "no F_SETPIPE_SZ here" unless Fcntl.const_defined?(:F_SETPIPE_SZ)
      reader, writer = IO.pipe
      grow(reader)
      writer.write("a flooded line\n" * 20_000)
      tail = tailing(reader)

      tail.drain(0)

      expect(File.size(File.join(@logs, "tail.log"))).to be > Lain::Chores::Runner::CHUNK
      tail.close
    end

    it "keeps a 4-byte character whole when a read ends 3 bytes into it" do
      reader, writer = IO.pipe
      tail = tailing(reader)
      writer.write(("a" * 5000).b + "x\xF0\x9F\x98".b)
      tail.drain(0.5)
      writer.write("\x80 y\n".b)
      writer.close

      tail.finish

      expect(File.read(File.join(@logs, "tail.log"))).to eq("#{"a" * 5000}x\u{1F600} y\n")
    end

    it "keeps a 3-byte character whole when a read ends after its second byte" do
      reader, writer = IO.pipe
      tail = tailing(reader)
      writer.write(("a" * 5000).b + "x\xE6\x97".b)
      tail.drain(0.5)
      writer.write("\xA5 y\n".b)
      writer.close

      tail.finish

      expect(File.read(File.join(@logs, "tail.log"))).to eq("#{"a" * 5000}x\u65E5 y\n")
    end

    it "keeps a character whole when a read ends inside it" do
      reader, writer = IO.pipe
      text = "#{"a" * 65_535}é tail\n"
      tail = tailing(reader)
      writer.write(text.byteslice(0, 65_536))
      tail.drain(0.5)
      writer.write(text.byteslice(65_536..))
      writer.close

      tail.finish

      expect(File.read(File.join(@logs, "tail.log"))).to eq(text)
    end
  end

  describe "a chat that fails with something on stderr" do
    let(:why) { "ANTHROPIC_API_KEY is not set" }
    let(:log) { Dir.glob(File.join(@logs, "*.stderr.log")).sole }

    before { chores("- [ ] add a spec for Foo#bar") }

    it "keeps the last stderr line in the chore's line and the whole stderr in a per-chore log" do
      outcome = runner(spawner: chat(exit: 1, stderr: "booting\n#{why}")).to_a.sole

      expect(outcome.status).to eq(:failed)
      expect(line).to eq("- [!] add a spec for Foo#bar  <!-- chat exited 1: #{why} #{session} -->")
      expect(File.read(log)).to eq("booting\n#{why}\n")
    end

    it "masks a known secret on stderr in the chore's line and in the log" do
      secret = "hunter2-known-value-9f3a"
      runner(spawner: chat(exit: 1, stderr: "bad token #{secret}"), secrets: [secret]).to_a

      expect(line).not_to include(secret)
      expect(line).to include("bad token ")
      expect(File.read(log)).not_to include(secret)
    end

    it "keeps the log private to its owner, even where an earlier run left it open" do
      item = Lain::Chores::Item.parse("- [ ] add a spec for Foo#bar")
      File.write(File.join(@logs, "#{item.id}.stderr.log"), "old")
      File.chmod(0o644, File.join(@logs, "#{item.id}.stderr.log"))

      runner(spawner: chat(exit: 1, stderr: why)).to_a

      expect(File.stat(log).mode & 0o777).to eq(0o600)
      expect(File.read(log)).to eq("#{why}\n")
    end

    it "never writes a known secret to the log, even while the chat is still running" do
      secret = "hunter2-known-value-9f3a"
      ready = File.join(@dir, "ready")
      command = ["sh", "-c", "printf '%s\\n' 'token #{secret}' >&2; : > #{ready}; sleep 30"]
      thread = Thread.new { runner(spawner: chat(command:), chat_timeout: 60, secrets: [secret]).to_a }

      wait_until(timeout: 10) { File.exist?(ready) && live_log.then { _1 && File.size(_1).positive? } }
      live = File.read(live_log)
      thread.kill.join

      expect(live).to include("token ")
      expect(live).not_to include(secret)
    end

    it "keeps only the tail of a very noisy stderr, and says so" do
      stub_const("#{described_class}::LOG_BYTES", 1000)
      noise = "printf 'line %s xxxxxxxxxxxxxxxxxxxx\\n' $(seq 1 300) >&2"
      runner(spawner: chat(command: ["sh", "-c", "#{noise}; exit 1"])).to_a

      text = File.read(log)
      expect(text).to start_with("[stderr cut: only the last ")
      expect(text).to include("line 300 ")
      expect(text).not_to include("line 1 ")
      expect(text.bytesize).to be < 1300
    end

    it "keeps a log no larger than the cap while the chat is still running" do
      stub_const("#{described_class}::LOG_BYTES", 1000)
      ready = File.join(@dir, "ready")
      noise = "printf 'line %s xxxxxxxxxxxxxxxxxxxx\\n' $(seq 1 300) >&2"
      command = ["sh", "-c", "#{noise}; : > #{ready}; sleep 30"]
      thread = Thread.new { runner(spawner: chat(command:), chat_timeout: 60).to_a }

      wait_until(timeout: 10) { File.exist?(ready) && live_log && File.size(live_log) >= 900 }
      sleep 0.5
      size = File.size(live_log)
      thread.kill.join

      expect(size).to be_between(900, 1000)
    end

    it "finishes a chat that floods stderr, and keeps its real last line" do
      flood = "yes 'a noisy line of stderr output' | head -c 11000000 >&2; " \
              "echo >&2; echo the-real-last-line >&2; exit 1"
      outcome = runner(spawner: chat(command: ["sh", "-c", flood]), chat_timeout: 20).to_a.sole

      expect(outcome.note).to eq("chat exited 1: the-real-last-line")
    end

    it "drains what a chat writes on TERM, so one that fits the grace is not stuck in a write" do
      stub_const("#{described_class}::KILL_AFTER", 4)
      trap_cmd = "head -c 300000 /dev/zero | tr '\\0' x >&2; echo bye >&2; exit 0"
      command = ["sh", "-c", "trap \"#{trap_cmd}\" TERM; while :; do sleep 0.05; done"]

      runner(spawner: chat(command:), chat_timeout: 0.5).to_a

      expect(File.read(log)).to end_with("bye\n")
    end

    it "drains a non-ASCII stderr line into a non-ASCII chore's line" do
      chores("- [ ] résumé chore")

      runner(spawner: chat(exit: 1, stderr: "café failed")).to_a

      expect(line).to eq("- [!] résumé chore  <!-- chat exited 1: café failed #{session} -->")
    end

    it "keeps a last line the chat wrote at once, even with a long wait between drains" do
      stub_const("#{described_class}::POLL", 5)
      runner(spawner: chat(command: ["sh", "-c", "printf 'last words\\n' >&2; exit 1"])).to_a

      expect(line).to include("chat exited 1: last words ")
    end

    it "keeps a last line that ended without a newline" do
      runner(spawner: chat(command: ["sh", "-c", "printf 'no newline at end' >&2; exit 1"])).to_a

      expect(line).to include("chat exited 1: no newline at end ")
    end

    it "shows a long line with no newline while the chat still runs" do
      ready = File.join(@dir, "ready")
      command = ["sh", "-c", "yes word | head -n 3000 | tr '\\n' ' ' >&2; : > #{ready}; sleep 30"]
      thread = Thread.new { runner(spawner: chat(command:), chat_timeout: 60).to_a }

      wait_until(timeout: 10) { File.exist?(ready) && live_log && File.size(live_log).positive? }
      thread.kill.join

      expect(File.read(live_log)).to start_with("word word")
    end

    it "says a chat killed by a signal, naming it" do
      runner(spawner: chat(command: ["sh", "-c", "kill -9 $$"])).to_a

      expect(line).to include("chat killed by signal 9")
    end

    it "cuts a very long last line to the note's limit" do
      runner(spawner: chat(command: ["sh", "-c", "head -c 1000 /dev/zero | tr '\\0' x >&2; exit 1"])).to_a

      expect(line).to include("chat exited 1: #{"x" * 300} ")
    end

    it "shows invalid bytes on stderr as replacement characters, never raising" do
      command = ["sh", "-c", "printf 'bad \\377\\376\\200 bytes' >&2; exit 1"]
      runner(spawner: chat(command:)).to_a

      expect(line).to include("chat exited 1: bad \uFFFD\uFFFD\uFFFD bytes ")
    end

    it "keeps the last carriage-return segment, without control characters" do
      command = ["sh", "-c", "printf 'step 1\\rstep 2\\r\\001done\\r\\n' >&2; exit 1"]
      runner(spawner: chat(command:)).to_a

      expect(line).to include("chat exited 1: done ")
    end

    it "cuts the log and calls the chat timed out when a flooder ignores TERM" do
      stub_const("#{described_class}::KILL_AFTER", 1)
      stub_const("#{described_class}::LOG_BYTES", 5000)
      command = ["sh", "-c", "trap '' TERM; yes 'noise noise noise' >&2"]

      runner(spawner: chat(command:), chat_timeout: 0.5).to_a

      expect(line).to include("<!-- timed out")
      expect(File.read(log)).to start_with("[stderr cut: only the last ")
    end

    it "says only how the chat exited when stderr was empty" do
      runner(spawner: chat(exit: 1)).to_a

      expect(line).to eq("- [!] add a spec for Foo#bar  <!-- chat exited 1 #{session} -->")
    end
  end

  describe "the drain's environment" do
    before { chores("- [ ] add a spec for Foo#bar") }

    it "hands the chat the drain's own LAIN_* values, through the default spawner" do
      seen = File.join(@dir, "seen")
      stub_lain = File.join(@dir, "lain")
      File.write(stub_lain, "File.write(#{seen.dump}, ENV.fetch(\"LAIN_MODEL\", \"unset\"))\n")

      with_env("LAIN_MODEL" => "qwen3-coder:30b") { runner(spawner: Process.method(:spawn), lain: stub_lain).to_a }

      expect(File.read(seen)).to eq("qwen3-coder:30b")
    end
  end

  describe "the wait's answer" do
    before { chores("- [ ] add a spec for Foo#bar") }

    { 1 => "not landed", 2 => "wait timed out", 3 => "no drainer" }.each do |code, said|
      it "reads #{code} as #{said} and keeps the lease for a human" do
        allow(lander).to receive(:wait).and_return(code)

        outcome = runner(spawner: chat(commit: true)).to_a.sole

        expect(outcome.status).to eq(:failed)
        head = git(@lease_path, "rev-parse", "HEAD")
        expect(line).to eq("- [!] add a spec for Foo#bar  <!-- #{said} #{head} #{session} -->")
        expect(releases).to be_empty
        expect(notes.sole.last).to eq("failed: #{said} #{head} #{session}")
      end
    end

    it "adds how the chat exited to a wait's answer on a commit made before a nonzero exit" do
      allow(lander).to receive(:wait).and_return(1)

      runner(spawner: chat(exit: 1, commit: true)).to_a

      head = git(@lease_path, "rev-parse", "HEAD")
      expect(line).to eq("- [!] add a spec for Foo#bar  <!-- not landed; chat exited 1 #{head} #{session} -->")
    end

    it "adds how the chat exited to a refusal of a commit made before a nonzero exit" do
      allow(lander).to receive(:wait).and_raise(Lain::Error, "no landing entry-1 was queued for main")

      runner(spawner: chat(exit: 1, commit: true)).to_a

      head = git(@lease_path, "rev-parse", "HEAD")
      expect(line).to eq("- [!] add a spec for Foo#bar  " \
                         "<!-- no landing entry-1 was queued for main; chat exited 1 #{head} #{session} -->")
    end

    it "reads a refusal as its message and keeps the lease for a human" do
      allow(lander).to receive(:wait).and_raise(Lain::Error, "no landing entry-1 was queued for main")

      runner(spawner: chat(commit: true)).to_a

      head = git(@lease_path, "rev-parse", "HEAD")
      expect(line)
        .to eq("- [!] add a spec for Foo#bar  <!-- no landing entry-1 was queued for main #{head} #{session} -->")
      expect(releases).to be_empty
    end

    it "keeps a landed chore done when its release fails, naming the failure in the line" do
      failing = ->(**) { raise Lain::Error, "cannot remove the checkout" }
      allow(self).to receive(:release_action).and_return(failing)

      outcome = runner(spawner: chat(commit: true)).to_a.sole

      head = git(@lease_path, "rev-parse", "HEAD")
      expect(outcome.status).to eq(:landed)
      expect(line).to eq("- [x] add a spec for Foo#bar  " \
                         "<!-- landed; release failed: cannot remove the checkout #{head} #{session} -->")
    end

    it "stops the drain on 130, leaving the item claimed for the next drain and the lease where it is" do
      chores("- [ ] add a spec for Foo#bar", "- [ ] tidy the README")
      allow(lander).to receive(:wait).and_return(130)

      expect { runner(spawner: chat(commit: true)).to_a }.to raise_error(Interrupt)
      expect(line).to start_with("- [~] add a spec for Foo#bar")
      expect(File.readlines(todos, chomp: true).fetch(2)).to eq("- [ ] tidy the README")
      expect(releases).to be_empty
      expect(notes).to be_empty
    end
  end

  describe "a hung chat" do
    before { chores("- [ ] add a spec for Foo#bar") }

    after { Array(@pids).each { |pid| kill_group(pid) } }

    def kill_group(pid)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end

    def group_gone?(pgid)
      Process.kill(0, -pgid)
      false
    rescue Errno::ESRCH
      true
    end

    it "terminates the chat's process group, reads timed out with the session path, and releases the lease" do
      runner(spawner: chat(command: %w[sleep 30]), chat_timeout: 0.2).to_a

      expect(line).to eq("- [!] add a spec for Foo#bar  <!-- timed out #{session} -->")
      expect(releases).to eq([false])
      expect(spawns.size).to eq(1)
    end

    def tracked(command, pids)
      lambda do |*argv, **options|
        chat(command:).call(*argv, **options).tap { pids << _1 }
      end
    end

    it "lands a commit the chat made before it was stopped for running too long, saying it timed out" do
      stub_const("#{described_class}::KILL_AFTER", 0.3)

      outcome = runner(spawner: chat(command: %w[sleep 30], commit: true), chat_timeout: 0.2).to_a.sole

      head = git(@lease_path, "rev-parse", "HEAD")
      expect(outcome.status).to eq(:landed)
      expect(line).to eq("- [x] add a spec for Foo#bar  <!-- landed; timed out #{head} #{session} -->")
    end

    it "sends the group TERM first, which a chat that traps it can act on" do
      stub_const("#{described_class}::KILL_AFTER", 3)
      marker = File.join(@dir, "termed")
      trap_term = ["sh", "-c", "trap 'echo > #{marker}; exit 0' TERM; while :; do sleep 0.05; done"]

      runner(spawner: tracked(trap_term, @pids = []), chat_timeout: 0.3).to_a

      expect(File).to exist(marker)
      expect(line).to start_with("- [!] add a spec for Foo#bar  <!-- timed out ")
    end

    # The join's bound only turns a runner that never sends KILL into a failure rather than a hang.
    it "kills a group that ignores TERM once the grace runs out" do
      stub_const("#{described_class}::KILL_AFTER", 0.3)
      deaf = ["sh", "-c", "trap '' TERM; sleep 30 & wait"]

      drained = Thread.new { runner(spawner: tracked(deaf, @pids = []), chat_timeout: 0.2).to_a }.join(15)

      expect(drained).not_to be_nil
      expect(line).to start_with("- [!] add a spec for Foo#bar  <!-- timed out ")
      wait_until(reason: "the chat's process group gone") { group_gone?(@pids.sole) }
    end

    it "kills a grandchild that ignores TERM after the leader has exited on it" do
      stub_const("#{described_class}::KILL_AFTER", 0.3)
      orphaning = ["sh", "-c", "(trap '' TERM; sleep 30) & trap 'exit 0' TERM; wait"]

      drained = Thread.new { runner(spawner: tracked(orphaning, @pids = []), chat_timeout: 0.3).to_a }.join(15)

      expect(drained).not_to be_nil
      wait_until(reason: "the chat's process group gone") { group_gone?(@pids.sole) }
    end

    it "reaps the leader of a chat stopped by timeout" do
      stub_const("#{described_class}::KILL_AFTER", 0.3)

      runner(spawner: tracked(%w[sleep 30], @pids = []), chat_timeout: 0.2).to_a

      expect { Process.wait2(@pids.sole) }.to raise_error(Errno::ECHILD)
    end

    it "reaps a leader that traps TERM when stopped directly" do
      stub_const("#{described_class}::KILL_AFTER", 0.3)
      pid = Process.spawn("sh", "-c", "trap '' TERM; while :; do sleep 0.05; done", pgroup: true)
      @pids = [pid]
      sleep 0.2

      runner(spawner: ->(*) {}).send(:stopped, pid, instance_double(described_class::Tail, drain: nil))

      expect { Process.wait2(pid) }.to raise_error(Errno::ECHILD)
    end

    it "stops the chat's group when the runner is interrupted while the chat runs" do
      main = Thread.current
      interrupter = nil
      spawner = lambda do |*argv, **options|
        tracked(%w[sleep 30], @pids = []).call(*argv, **options).tap do
          interrupter = Thread.new { sleep(0.3) && main.raise(Interrupt) }
        end
      end

      expect { runner(spawner:).to_a }.to raise_error(Interrupt)
      wait_until(reason: "the chat's process group gone") { group_gone?(@pids.sole) }
    ensure
      interrupter&.kill&.join
    end
  end

  it "runs the research skill on a research item and finishes it with no land" do
    chores("- [ ] [research] compare x and y")

    outcome = runner(spawner: chat(exit: 0)).to_a.sole

    expect(spawns.sole[:argv].last(2))
      .to eq(["--prompt", Lain::Chores::Brief.for(Lain::Chores::Item.parse("- [ ] [research] compare x and y"))])
    expect(outcome.status).to eq(:researched)
    expect(line).to eq("- [x] [research] compare x and y  <!-- researched #{session} -->")
    expect(landed_from).to be_empty
    expect(releases).to eq([false])
  end

  it "lands the report a research chat committed, from inside the lease under the item's id" do
    chores("- [ ] [research] compare x and y")
    report = "planning/x-and-y-research-2026-11.md"

    outcome = runner(spawner: reporting(report)).to_a.sole

    head = git(@lease_path, "rev-parse", "HEAD")
    expect(git(@lease_path, "show", "#{head}:#{report}")).to eq("# x and y: research")
    expect(landed_from).to eq([@lease_path])
    expect(lander).to have_received(:queued).with("HEAD", id: outcome.item.id)
    expect(outcome).to have_attributes(status: :researched, sha: head)
    expect(line).to eq("- [x] [research] compare x and y  <!-- researched #{head} #{session} -->")
  end

  it "takes the session the chat filed last when the lease's directory already holds one" do
    chores("- [ ] add a spec for Foo#bar")
    older = File.join(session_dir(@lease_path), "2026-10-27T00-00-00-chat.ndjson")
    File.write(older, "{}\n")
    File.utime(Time.now - 3600, Time.now - 3600, older)

    outcome = runner(spawner: chat(exit: 0)).to_a.sole

    expect(outcome.session).to eq(File.join(session_dir(@lease_path), "2026-10-28T00-00-00-chat.ndjson"))
  end

  it "records no session for a retried chat that filed none, rather than the earlier attempt's" do
    chores("- [ ] add a spec for Foo#bar")
    File.write(File.join(session_dir(@lease_path), "2026-10-27T00-00-00-chat.ndjson"), "{}\n")

    outcome = runner(spawner: chat(exit: 1, files: false)).to_a.sole

    expect(outcome.session).to be_nil
    expect(line).to eq("- [!] add a spec for Foo#bar  <!-- chat exited 1 -->")
  end

  it "yields one outcome per item it takes, so a caller can bound the drain" do
    chores("- [ ] first", "- [ ] second")

    taken = runner(spawner: chat(exit: 0)).take(1)

    expect(taken.map { _1.item.text }).to eq(["first"])
    expect(File.readlines(todos, chomp: true).fetch(2)).to eq("- [ ] second")
  end

  it "drains until no item is open" do
    chores("- [ ] first", "- [x] done", "- [ ] second")

    expect(runner(spawner: chat(exit: 0)).map { _1.item.text }).to eq(%w[first second])
  end

  describe "with the real worktree backend" do
    let(:real_backend) { Lain::CLI::IsolationBackend.resolve("worktree", root: @main, paths:) }

    before do
      git(@main, "branch", "-M", "main")
      chores("- [ ] add a spec for Foo#bar")
    end

    it "cuts a lease that holds no chore file, and leaves the main checkout's tracked state alone" do
      status = git(@main, "status", "--porcelain", "--untracked-files=no")

      outcome = runner(spawner: chat(commit: true), backend: real_backend).to_a.sole

      expect(spawns.sole[:todos_in_lease]).to be(false)
      expect(spawns.sole[:options][:chdir]).not_to eq(@main)
      expect(outcome.status).to eq(:landed)
      expect(git(@main, "status", "--porcelain", "--untracked-files=no")).to eq(status)
      expect(File).not_to exist(spawns.sole[:options][:chdir])
    end

    # The plant names a real git dir, a copy of the clone's own, so git outside the guard still reads a HEAD
    # through it: only reading HEAD through the guard fails the item.
    it "fails a clone whose git dir the chat planted a name in, with no enqueue" do
      clone_backend = Lain::CLI::IsolationBackend.resolve("worktree", root: @main)
      planting = lambda do |*argv, **options|
        chat(commit: true).call(*argv, **options).tap do
          clone = options.fetch(:chdir)
          FileUtils.cp_r(File.join(clone, ".git"), File.join(clone, "evil"))
          File.write(File.join(clone, ".git", "commondir"), "../evil\n")
        end
      end

      outcome = runner(spawner: planting, backend: clone_backend).to_a.sole

      expect(outcome.status).to eq(:failed)
      expect(line).to start_with("- [!] add a spec for Foo#bar  <!-- cannot read the lease's HEAD")
      expect(lander).not_to have_received(:queued)
    end

    # The chat is rooted where the runner hands it, so the rule chain a real chat would build is built there.
    it "hands the chat a root its commit rule recognises as the lease, so the chore's commit is approved by rule" do
      clone_backend = Lain::CLI::IsolationBackend.resolve("worktree", root: @main)
      decisions = []
      asking = lambda do |*argv, **options|
        root = argv[argv.index("--root") + 1]
        fresh = Lain::Shell::Executable::Fresh.new(start: Time.now + 3600, written: [],
                                                   stat: Lain::Shell::Executable::Stat.new)
        factory = Lain::CLI::Wiring::BoardBuild::Classifiers.new(
          home: File.join(@dir, "home"), cwd: root, root:, confinement: Lain::Approval::Root.new(root),
          resolver: Lain::Shell::Executable::Resolver.new(root:, fresh:),
          worker_env: Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "/usr/bin", "HOME" => File.join(@dir, "home") })
        )
        call = Lain::Approval::Rule::Call.for(tool: Lain::Tools::Bash.new(verdict: Lain::Shell::Verdict.new),
                                              input: { "command" => 'git commit -m "chore"', "cwd" => root })
        decisions << Lain::Approval::Escalation::Rules.ladder(Lain::CLI::Wiring::BoardBuild.approving([], factory,
                                                                                                      workspace: true))
                                                      .call(call).decision
        chat(commit: true).call(*argv, **options)
      end

      outcome = runner(spawner: asking, backend: clone_backend).to_a.sole

      expect(decisions.sole).to have_attributes(verdict: :allow, rule: "lease_commit")
      expect(outcome.status).to eq(:landed)
    end

    # The drainer runs in this process when the landing asks for one, so the merge onto main is the real one.
    # A clone is recognised only under the process's own state home, so the lease and the landing both use it.
    it "lands a research chat's committed report on main through the real landing" do
      clone_backend = Lain::CLI::IsolationBackend.resolve("worktree", root: @main)
      chores("- [ ] [research] compare x and y")
      File.write(File.join(@main, ".git", "info", "exclude"), ".lain/\n", mode: "a")
      write_config(@main, "isolation verify: #{%w[sh -c true].inspect}\n")
      report = "planning/x-and-y-research-2026-11.md"
      inline = Object.new
      draining = ->(branch, root) { Lain::CLI::Land.new(cwd: root).drain(branch:, project: root) }
      inline.define_singleton_method(:drain) { |branch:, root:, **| draining.call(branch, root) && true }
      land = ->(lease) { Lain::CLI::Land.new(cwd: lease, spawner: inline) }

      outcome = described_class.new(queue:, backend: clone_backend, lain: program, land:, notices:, paths:,
                                    logs: @logs, max_cost: 2, wait_timeout: 60, spawner: reporting(report)).to_a.sole

      expect(outcome.status).to eq(:researched), outcome.summary
      expect(git(@main, "show", "main:#{report}")).to eq("# x and y: research")
    end

    it "adds how the chat exited to a HEAD it cannot read" do
      unreadable = lambda do |*argv, **options|
        chat(exit: 1, commit: true).call(*argv, **options)
                                   .tap { FileUtils.rm_rf(File.join(options.fetch(:chdir), ".git")) }
      end

      runner(spawner: unreadable).to_a

      expect(line)
        .to eq("- [!] add a spec for Foo#bar  <!-- #{described_class::UNREADABLE}; chat exited 1 #{session} -->")
    end

    it "fails a lease whose HEAD git cannot read at all, with no enqueue" do
      unreadable = lambda do |*argv, **options|
        chat(commit: true).call(*argv, **options).tap { FileUtils.rm_rf(File.join(options.fetch(:chdir), ".git")) }
      end

      outcome = runner(spawner: unreadable).to_a.sole

      expect(outcome.status).to eq(:failed)
      expect(line).to start_with("- [!] add a spec for Foo#bar  <!-- cannot read the lease's HEAD")
      expect(lander).not_to have_received(:queued)
    end

    it "keeps a lease whose chat left uncommitted work" do
      dirty = lambda do |*argv, **options|
        File.write(File.join(options.fetch(:chdir), "half_done.rb"), "# wip\n")
        chat(exit: 1).call(*argv, **options)
      end

      runner(spawner: dirty, backend: real_backend).to_a

      expect(File).to exist(File.join(spawns.sole[:options][:chdir], "half_done.rb"))
    end
  end
end
