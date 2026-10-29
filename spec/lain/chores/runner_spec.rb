# frozen_string_literal: true

require "fileutils"
require "rbconfig"
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

  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => @dir, "XDG_STATE_HOME" => File.join(@dir, "state") }) }
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

  before { base }

  def git(dir, *) = SeedRepo.git(dir, *).stdout.strip

  def chores(*lines) = File.write(todos, "# Chores\n#{lines.map { "#{_1}\n" }.join}")

  def line = File.readlines(todos, chomp: true).fetch(1)

  def session_dir(root) = paths.filing_dir(root:)

  # Stands in for `lain chat`: files a session where the chat would, does the chat's work in
  # the spec process, then leaves a real process in its own group to answer for it.
  def chat(exit: 0, commit: false, command: nil, files: true)
    lambda do |*argv, **options|
      root = options.fetch(:chdir)
      spawns << { argv:, options:, line:, todos_in_lease: File.exist?(File.join(root, "TODOS.md")) }
      File.write(File.join(session_dir(root), "2026-10-28T00-00-00-chat.ndjson"), "{}\n") if files
      if commit
        File.write(File.join(root, "foo_spec.rb"), "# spec\n")
        git(root, "add", "foo_spec.rb")
        git(root, "commit", "-q", "-m", "add a spec")
      end
      Process.spawn(*(command || ["sh", "-c", "exit #{exit}"]), pgroup: options.fetch(:pgroup))
    end
  end

  def runner(spawner:, land: lander, backend: self.backend, **)
    factory = lambda do |path|
      landed_from << path
      land
    end
    described_class.new(queue:, backend:, lain: program, land: factory, notices:, paths:, max_cost: 2,
                        spawner:, **)
  end

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

  it "fails a refused or torn run with the session path, enqueues nothing, and lets release judge what to keep" do
    chores("- [ ] add a spec for Foo#bar")

    runner(spawner: chat(exit: 1, commit: true)).to_a

    expect(line).to eq("- [!] add a spec for Foo#bar  <!-- chat exited 1 #{session} -->")
    expect(lander).not_to have_received(:queued)
    expect(releases).to eq([false])
    expect(notes.sole.last).to start_with("failed: ")
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

    it "still stops a chat that never got its own process group" do
      stub_const("#{described_class}::KILL_AFTER", 0.3)
      grouped = tracked(%w[sleep 30], @pids = [])
      ungrouped = ->(*argv, **options) { grouped.call(*argv, **options, pgroup: nil) }

      drained = Thread.new { runner(spawner: ungrouped, chat_timeout: 0.2).to_a }.join(15)

      expect(drained).not_to be_nil
      expect(line).to start_with("- [!] add a spec for Foo#bar  <!-- timed out ")
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

    expect(spawns.sole[:argv].last(2)).to eq(["--prompt", "/research compare x and y"])
    expect(outcome.status).to eq(:researched)
    expect(line).to eq("- [x] [research] compare x and y  <!-- researched #{session} -->")
    expect(landed_from).to be_empty
    expect(releases).to eq([false])
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
