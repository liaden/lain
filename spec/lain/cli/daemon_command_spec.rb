# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Lain::CLI::DaemonCommand do
  def start(*words)
    printed = +""
    out = StringIO.new(printed)
    saved = $stdout
    $stdout = out
    described_class.start(words, debug: true)
    printed
  ensure
    $stdout = saved
  end

  it "exits 1 on failure" do
    expect(described_class.exit_on_failure?).to be(true)
  end

  describe "with no daemon binary" do
    around do |example|
      Dir.mktmpdir("daemon-command-unbuilt") do |dir|
        with_env("LAIN_DAEMON" => nil, "CARGO_TARGET_DIR" => dir) { example.run }
      end
    end

    [%w[status], %w[runs], %w[ensure], %w[restart], %w[stop run-1], %w[run chores],
     %w[run epic research-x]].each do |argv|
      it "refuses `lain daemon #{argv.join(" ")}`, naming rake daemon:build" do
        expect { start(*argv) }.to raise_error(Thor::Error, /rake daemon:build/)
      end
    end
  end

  describe "herdr-sync" do
    let(:client) { instance_double(Lain::Core::Client, stop: nil) }
    let(:workspaces) { '{"result":{"workspaces":[{"workspace_id":"w1","label":"lain"}]}}' }
    let(:rows) do
      [{ "kind" => "epic", "slug" => "research-x", "status" => nil, "blocked" => true },
       { "kind" => "chores", "slug" => nil, "status" => nil, "blocked" => false },
       { "kind" => "epic", "slug" => "old-one", "status" => 0, "blocked" => false },
       { "kind" => "review-poll", "slug" => nil, "status" => nil, "blocked" => false }]
    end

    around do |example|
      Dir.mktmpdir("daemon-command-herdr") do |dir|
        @log = File.join(dir, "calls")
        @herdr = File.join(dir, "herdr")
        File.write(@herdr, "#!/bin/sh\necho \"$@\" >> #{@log}\n" \
                           "[ \"$1 $2\" = \"workspace list\" ] && echo '#{workspaces}'\nexit 0\n")
        File.chmod(0o755, @herdr)
        with_env("HERDR_BIN_PATH" => @herdr) { example.run }
      end
    end

    before do
      allow(client).to receive(:call).with("run.list").and_return(rows)
      allow(Lain::Daemon).to receive(:attached).and_return(client)
    end

    def reported = File.readlines(@log, chomp: true).grep(/report-metadata/)

    it "puts each live run and whether it waits on you in the runs token of the lain workspace" do
      start("herdr-sync")

      expect(reported).to eq(["workspace report-metadata w1 --source lain-daemon " \
                              "--token runs=epic research-x: blocked; chores: working"])
    end

    it "clears the token when no run is live" do
      allow(client).to receive(:call).with("run.list").and_return([rows[2]])

      start("herdr-sync")

      expect(reported).to eq(["workspace report-metadata w1 --source lain-daemon --clear-token runs"])
    end

    it "prints nothing and does nothing when no daemon is running" do
      allow(Lain::Daemon).to receive(:attached).and_return(nil)

      expect(start("herdr-sync")).to eq("")
      expect(File.exist?(@log)).to be(false)
    end

    context "without a lain workspace" do
      let(:workspaces) { '{"result":{"workspaces":[{"workspace_id":"w2","label":"other"}]}}' }

      it "reports nothing and exits 0" do
        expect(start("herdr-sync")).to eq("")
        expect(reported).to be_empty
      end
    end

    it "does nothing and exits 0 without herdr" do
      with_env("HERDR_BIN_PATH" => nil, "PATH" => "") do
        expect(start("herdr-sync")).to eq("")
      end
    end
  end

  describe "run" do
    let(:client) { instance_double(Lain::Core::Client, stop: nil) }
    let(:project) { Lain::Project.new(root: Dir.pwd, cwd: Dir.pwd, kind: :project, detected_by: :git) }
    let(:unset) { Lain::CLI::EnvDefaults::READ.to_h { [_1, nil] } }

    before do
      allow(Lain::Project::Resolver).to receive(:default_project).and_return(project)
      allow(Lain::Daemon).to receive(:ensure).and_return(client)
      allow(client).to receive(:call).with("run.start", anything).and_return({ "id" => "r1" })
    end

    def requested(fields) = have_received(:call).with("run.start", [a_hash_including(fields)])

    it "hands an epic run the requester's provider profile" do
      with_env(unset.merge("LAIN_PROVIDER" => "ollama", "LAIN_MODEL" => "qwen3-coder:30b",
                           "LAIN_API_BASE" => "http://127.0.0.1:11434", "LAIN_NUM_CTX" => "32768",
                           "LAIN_NUM_BATCH" => "2048")) do
        start("run", "epic", "greet")
      end

      expect(client).to requested(
        "kind" => "epic", "args" => { "slug" => "greet" },
        "profile" => { "provider" => "ollama", "model" => "qwen3-coder:30b",
                       "api_base" => "http://127.0.0.1:11434", "num_ctx" => 32_768, "num_batch" => 2048 }
      )
    end

    it "hands a chores run the same profile" do
      with_env(unset.merge("LAIN_PROVIDER" => "ollama", "LAIN_MODEL" => "qwen3-coder:30b")) { start("run", "chores") }

      expect(client).to requested("kind" => "chores",
                                  "profile" => { "provider" => "ollama", "model" => "qwen3-coder:30b" })
    end

    it "sends no profile when the requester's environment sets none, so a daemon without one still runs it" do
      with_env(unset) { start("run", "chores") }

      expect(client).to have_received(:call).with("run.start", [hash_excluding("profile")])
    end

    %w[LAIN_NUM_CTX LAIN_NUM_BATCH].product(%w[-1 0 8192.5 4294967296]).each do |name, value|
      it "refuses #{name}=#{value}, naming it, and asks the daemon nothing" do
        with_env(unset.merge(name => value)) do
          expect { start("run", "chores") }.to raise_error(Thor::Error, /#{name}=#{Regexp.escape(value.inspect)}/)
        end

        expect(client).not_to have_received(:call)
      end
    end

    it "takes the largest whole number the daemon can hold" do
      with_env(unset.merge("LAIN_NUM_CTX" => "4294967295")) { start("run", "chores") }

      expect(client).to requested("profile" => { "num_ctx" => 4_294_967_295 })
    end

    it "knows the same providers as the daemon that checks them" do
      source = File.read(File.expand_path("../../../crates/lain-daemon/src/supervisor.rs", __dir__))
      listed = source[/const PROVIDERS: \[&str; \d+\] = \[([^\]]*)\]/, 1] or raise "no PROVIDERS in supervisor.rs"

      expect(listed.scan(/"([^"]+)"/).flatten).to eq(Lain::CLI::Backend::PROVIDERS)
    end
  end

  describe "against the real daemon", :daemon do
    around do |example|
      Dir.mktmpdir("daemon-command-state") do |state|
        Dir.mktmpdir("daemon-command-root") do |root|
          @root = File.realpath(root)
          FileUtils.mkdir_p(File.join(@root, ".git"))
          @state = state
          @lain = File.join(state, "fake-lain")
          File.write(@lain, "trap('TERM') { exit }\nsleep\n")
          with_env("XDG_RUNTIME_DIR" => daemon_env.fetch("XDG_RUNTIME_DIR"), "XDG_STATE_HOME" => state) { example.run }
        end
      end
    end

    before do
      project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :git)
      allow(Lain::Project::Resolver).to receive(:default_project).and_return(project)
      allow(Lain::Daemon::Launch).to receive(:current).and_wrap_original do |original, **keywords|
        original.call(**keywords).with(lain: @lain)
      end
    end

    def lines(*words) = start(*words).lines(chomp: true)

    def run_id = lines("run", "epic", "research-x").first[/\A\S+/]

    # The daemon is stopped, and waited for, before the state home goes: it keeps its spawner warm
    # and logs under that home until it exits.
    after { stop_daemon }

    def stop_runs
      Sync do
        client = Lain::Daemon.attached(paths: Lain::Paths.new, env: ENV)
        client&.call("run.list")&.select { _1["status"].nil? }&.each { client.call("run.stop", [{ "id" => _1["id"] }]) }
        client&.stop
      end
    end

    def stop_daemon
      stop_runs
      begin
        Sync { LainDaemon.reap(Lain::Paths.new) }
      ensure
        stragglers.each { |pid| kill(pid) }
      end
      raise LainDaemon::Leaked, "still running when its state home is removed:\n#{state_users.join}" if state_users.any?
    end

    it "names a daemon that ignores the stop, and leaves nothing of it running" do
      stubborn = Process.spawn("sh", "-c", "trap '' TERM; while :; do sleep 1; done", @state)
      Process.detach(stubborn)
      allow(LainDaemon).to receive(:pid_at).and_return(stubborn)
      allow(Lain::Daemon).to receive(:stop)

      expect { stop_daemon }.to raise_error(LainDaemon::Leaked, /pid #{stubborn}\b/)
      expect(state_users).to be_empty
    ensure
      kill(stubborn) if stubborn
    end

    it "leaves its state home quiet once the daemon has been stopped" do
      start("ensure")
      pids = stragglers
      Sync { Lain::Daemon.stop(paths: Lain::Paths.new) }
      pids.each { |pid| LainDaemon.running_after_budget?(pid) }
      settled = state_listing
      sleep 1

      expect(state_users).to be_empty
      expect(state_listing).to eq(settled)
    end

    def kill(pid)
      Process.kill("KILL", pid)
      LainDaemon.running_after_budget?(pid)
    rescue Errno::ESRCH
      nil
    end

    def stragglers
      state_users.map(&:to_i)
    end

    def state_listing
      Dir.glob("**/*", File::FNM_DOTMATCH, base: @state).sort.to_h do |name|
        stat = File.lstat(File.join(@state, name))
        [name, [stat.size, stat.mtime]]
      end
    end

    def state_users = IO.popen(["ps", "-eo", "pid=,args="], &:read).lines.select { _1.include?(@state) }

    it "starts a daemon with ensure, and says its pid" do
      expect(start("ensure")).to match(/daemon pid \d+/)
    end

    it "says no daemon is running for status and runs, and starts none" do
      expect([start("status"), start("runs")]).to eq(["no daemon is running\n"] * 2)
      expect(LainDaemon.pid_at(Lain::Paths.new)).to be_nil
    end

    it "starts no daemon for herdr-sync" do
      expect(start("herdr-sync")).to eq("")
      expect(LainDaemon.pid_at(Lain::Paths.new)).to be_nil
    end

    it "refuses to stop a run when no daemon is running, and starts none" do
      expect { start("stop", "run-1") }.to raise_error(Thor::Error, /no daemon is running/)
      expect(LainDaemon.pid_at(Lain::Paths.new)).to be_nil
    end

    it "shows the pid, uptime, build and relay of the daemon" do
      start("ensure")
      report = start("status")

      expect(report).to match(/^pid: \d+$/)
      expect(report).to match(/^uptime: \S+$/)
      expect(report).to match(/^build: \S+ \S+$/)
      expect(report).to match(/^relay: off$/)
    end

    it "keeps a run going after the command that started it has returned, and lists it" do
      id = run_id

      expect(lines("runs")).to include(a_string_matching(/\A#{id}\s+epic research-x\s+running\b/))
    end

    it "lists each registered session and each run in status" do
      id = run_id
      Sync do
        client = Lain::Daemon.ensure(paths: Lain::Paths.new)
        client.call("session.register", [{ "session_id" => "stem-1", "pid" => Process.pid, "host" => "h",
                                           "root" => @root, "cwd" => @root, "attended" => true,
                                           "started_at" => "2026-11-18T00:00:00Z" }])
        report = start("status")
        client.stop

        expect(report).to match(/^session stem-1 pid #{Process.pid} #{Regexp.escape(@root)}$/)
        expect(report).to match(/^run #{id}\s+epic research-x\s+running\b/)
      end
    end

    it "stops a run by its id" do
      id = run_id

      start("stop", id)

      expect(lines("runs")).to include(a_string_matching(/\A#{id}\s+epic research-x\s+exited\b/))
    end

    it "refuses to restart while a run is live, naming it, and leaves the daemon be" do
      id = run_id
      before = start("status")[/^pid: \d+/]

      expect { start("restart") }.to raise_error(Thor::Error, /#{id}.*--force/m)
      expect(start("status")[/^pid: \d+/]).to eq(before)
    end

    it "restarts with --force even over a live run" do
      run_id
      before = start("status")[/^pid: (\d+)/, 1]

      start("restart", "--force")

      expect(start("status")[/^pid: (\d+)/, 1]).not_to eq(before)
    end

    it "restarts an idle daemon without being asked to force" do
      start("ensure")
      before = start("status")[/^pid: (\d+)/, 1]

      start("restart")

      expect(start("status")[/^pid: (\d+)/, 1]).not_to eq(before)
    end

    it "says plainly there are no runs when the daemon has none" do
      start("ensure")

      expect(start("runs")).to eq("no runs\n")
    end

    it "points at `lain daemon runs` after starting a run" do
      expect(start("run", "chores")).to match(/\A\S+ .*lain daemon runs/)
    end

    it "restarts without --force when the only run has exited" do
      id = run_id
      start("stop", id)
      before = start("status")[/^pid: (\d+)/, 1]

      restarted = start("restart")[/daemon restarted, pid (\d+)/, 1]

      expect(restarted).to eq(start("status")[/^pid: (\d+)/, 1])
      expect(restarted).not_to eq(before)
    end

    it "says which runs keep going unlisted when --force restarts over them" do
      id = run_id
      pid = lines("runs").first[/pid (\d+)/, 1]

      expect(start("restart", "--force")).to match(/1 run keeps going unlisted:\n\s+#{id}\s+pid #{pid}\n/)
    end

    it "shows the daemon's note that a restart waits on a live run" do
      run_id
      @lain = File.join(File.dirname(@lain), "another-lain")
      File.write(@lain, "sleep\n")

      expect(start("ensure")).to include("live run")
    end

    it "starts a chores run for the current project" do
      expect(lines("run", "chores").first).to match(/\A\S+ /)
      expect(lines("runs")).to include(a_string_matching(/chores\s+(?:running|exited)/))
    end

    it "refuses an epic with no slug, and a kind it does not run" do
      expect { start("run", "epic") }.to raise_error(Thor::Error, /SLUG/)
      expect { start("run", "review-poll") }.to raise_error(Thor::Error, /epic|chores/)
    end
  end
end
