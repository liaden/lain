# frozen_string_literal: true

require "open3"
require "tmpdir"
require "timeout"

# Every command the tools run is a stub from an environment variable, so no example
# starts a real suite. The tools are scripts, so they are driven as processes.
RSpec.describe "bin/suite-load and bin/suite-redrate" do
  let(:suite_load) { File.expand_path("../../bin/suite-load", __dir__) }
  let(:suite_redrate) { File.expand_path("../../bin/suite-redrate", __dir__) }

  around do |example|
    Dir.mktmpdir("sl") do |dir|
      @dir = dir
      example.run
    end
  end

  def tree(name, body)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "stub.sh"), body)
    path
  end

  def counting_stub(fail_every:, examples: 3)
    <<~SH
      n=$(( $(cat count 2>/dev/null || echo 0) + 1 )); echo $n > count
      echo "Randomized with seed $((1000 + n))"
      if [ $((n % #{fail_every})) -eq 0 ]; then
        echo "rspec ./spec/a_spec.rb:7 # A fails sometimes"
        echo "#{examples} examples, 1 failure"; exit 1
      fi
      echo "#{examples} examples, 0 failures"
    SH
  end

  def guard(name, code)
    path = File.join(@dir, name)
    File.write(path, "#!/bin/sh\n#{code}\n")
    File.chmod(0o755, path)
    path
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def env_for(extra = {})
    { "SUITE_LOAD_GUARD" => guard("guard_ok", "exit 0"), "SUITE_LOAD_WARMUP" => "0",
      "SUITE_LOAD_LOOP" => "sleep 300", "SUITE_LOAD_RUN" => "sh stub.sh",
      "SUITE_REDRATE_GUARD" => guard("guard_ok2", "exit 0"), "SUITE_REDRATE_RUN" => "sh stub.sh" }.merge(extra)
  end

  def load_run(card, base, env = {}, rounds: 2)
    Open3.capture2e(env_for(env), suite_load, "--card", card, "--base", base, "--load", tree("load", ""),
                    "--rounds", rounds.to_s, "spec/a_spec.rb")
  end

  describe "SuiteLoad::Group#stop" do
    before { load suite_load }

    def stop_time(command)
      group = SuiteLoad::Group.spawn({}, "sh", "-c", command)
      sleep 0.2
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      group.stop
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    it "returns as soon as a group that exits on TERM has ended" do
      expect(stop_time("exec sleep 30")).to be < 0.15
    end

    it "still kills a group that ignores TERM after the grace" do
      expect(stop_time("trap '' TERM; while :; do sleep 1; done")).to be_between(0.2, 1.0)
    end
  end

  describe "suite-load" do
    it "counts a card failure with its location and seed, apart from the base" do
      card = tree("card", counting_stub(fail_every: 3))
      base = tree("base", counting_stub(fail_every: 1_000))

      out, status = load_run(card, base, rounds: 6)

      expect(status.exitstatus).to eq(1)
      expect(out).to include("card: 4 passed, 2 failed, 3 examples per run")
      expect(out).to include("base: 6 passed, 0 failed, 3 examples per run")
      expect(out).to include("card failure: ./spec/a_spec.rb:7 seed 1003")
      expect(out).not_to include("base failure")
    end

    it "counts every failed run, even when they share a seed" do
      always = "echo 'Randomized with seed 9'; echo 'rspec ./spec/a_spec.rb:7 # X'; " \
               "echo '3 examples, 1 failure'; exit 1"
      out, = load_run(tree("card", always), tree("base", counting_stub(fail_every: 1_000)), rounds: 3)

      expect(out).to include("card: 0 passed, 3 failed")
    end

    it "fails a run that exits 0 without running any example" do
      out, status = load_run(tree("card", "echo '0 examples, 0 failures'"),
                             tree("base", "echo '0 examples, 0 failures'"))

      expect(status.exitstatus).to eq(1)
      expect(out).to include("card failure: 0 examples ran")
    end

    it "fails a run that exits 0 after printing no summary" do
      out, status = load_run(tree("card", "echo 'Randomized with seed 5'"),
                             tree("base", counting_stub(fail_every: 1_000)))

      expect(status.exitstatus).to eq(1)
      expect(out).to include("card failure: no example summary (exit 0) seed 5")
    end

    it "reports an added example as information, not a failure" do
      out, status = load_run(tree("card", counting_stub(fail_every: 1_000, examples: 4)),
                             tree("base", counting_stub(fail_every: 1_000, examples: 3)))

      expect(status.exitstatus).to eq(0)
      expect(out).to include("example count: card 4, base 3")
    end

    it "fails when one tree's example count varies between rounds" do
      varying = "n=$(( $(cat count 2>/dev/null || echo 0) + 1 )); echo $n > count; " \
                "if [ $((n % 2)) -eq 0 ]; then echo '2 examples, 0 failures'; else echo '3 examples, 0 failures'; fi"
      out, status = load_run(tree("card", varying), tree("base", counting_stub(fail_every: 1_000)), rounds: 4)

      expect(status.exitstatus).to eq(1)
      expect(out).to include("example count varies in card: 2/3")
    end

    it "names the signal that killed a run" do
      out, = load_run(tree("card", "kill -9 $$"), tree("base", counting_stub(fail_every: 1_000)), rounds: 1)

      expect(out).to include("card failure: no example summary (killed by signal 9)")
    end

    it "fails when the load loop dies mid proof" do
      card = tree("card", "sleep 0.3; echo '3 examples, 0 failures'")
      out, status = load_run(card, tree("base", "sleep 0.3; echo '3 examples, 0 failures'"),
                             { "SUITE_LOAD_LOOP" => "exit 1" })

      expect(status.exitstatus).to eq(1)
      expect(out).to include("load group exited")
    end

    it "reports the load runs and their failures" do
      loop_cmd = 'echo "load run exit 1" >> "$SUITE_LOAD_LOG"; echo "load run exit 0" >> "$SUITE_LOAD_LOG"; sleep 300'
      out, = load_run(tree("card", counting_stub(fail_every: 1_000)), tree("base", counting_stub(fail_every: 1_000)),
                      { "SUITE_LOAD_LOOP" => loop_cmd })

      expect(out).to include("load: 2 runs, 1 failed")
    end

    it "gives up on a run held open by a grandchild" do
      held = "sleep 30 & echo '3 examples, 0 failures'"
      out, = Timeout.timeout(20) do
        load_run(tree("card", held), tree("base", held), { "SUITE_LOAD_RUN_TIMEOUT" => "0.3" }, rounds: 1)
      end

      expect(out).to include("card failure: timed out after 0.3s")
    end

    %w[INT TERM].product([false, true]).each do |signal, ignored_at_start|
      it "leaves no loop or run process after #{signal}#{" from a start that ignored it" if ignored_at_start}" do
        pids = File.join(@dir, "pids")
        record = "echo $$ >> #{pids}; sleep 300 & echo $! >> #{pids}; wait"
        card = tree("card", record)
        base = tree("base", record)
        prefix = ignored_at_start ? "trap '' INT TERM;" : ""
        cmd = %(#{prefix} exec "$0" "$@")
        pid = Process.spawn(env_for("SUITE_LOAD_LOOP" => record), "sh", "-c", cmd, suite_load, "--card", card,
                            "--base", base, "--load", tree("load", ""), "--rounds", "1", "spec/a_spec.rb",
                            %i[out err] => File::NULL)

        Timeout.timeout(10) { sleep 0.05 until File.exist?(pids) && File.readlines(pids).size >= 4 }
        Process.kill(signal, pid)
        Timeout.timeout(10) { Process.wait(pid) }

        expect(File.readlines(pids).map(&:to_i).select { |p| alive?(p) }).to be_empty
      end
    end

    it "waits on a busy box, says why, and starts no run" do
      card = tree("card", "touch ran")
      base = tree("base", "touch ran")
      busy = guard("busy", "echo 'not quiet: a mempalace unit is running' >&2; exit 1")

      out, status = load_run(card, base, { "SUITE_LOAD_GUARD" => busy, "SUITE_LOAD_POLL" => "0.05",
                                           "SUITE_LOAD_MAX_WAIT" => "0.3" })

      expect(status).not_to be_success
      expect(out).to include("not quiet: a mempalace unit is running")
      expect([File.exist?(File.join(card, "ran")), File.exist?(File.join(base, "ran"))]).to eq([false, false])
    end
  end

  describe "suite-redrate" do
    def redrate(card, base, rounds: 4)
      Open3.capture2e(env_for, suite_redrate, "--card", card, "--base", base, "--rounds", rounds.to_s)
    end

    it "names failing examples and gives the median wall per tree" do
      out, status = redrate(tree("card", counting_stub(fail_every: 2)), tree("base", counting_stub(fail_every: 1_000)))

      expect(status).to be_success
      expect(out).to match(/card: 4 runs, 2 with a failure, 3 examples per run, median wall \d/)
      expect(out).to include("base: 4 runs, 0 with a failure")
      expect(out).to include("card failed 2x: ./spec/a_spec.rb # A fails sometimes")
    end

    it "counts a run that exits non-zero without naming an example" do
      out, = redrate(tree("card", "echo '3 examples, 0 failures'; exit 1"),
                     tree("base", counting_stub(fail_every: 1_000)), rounds: 2)

      expect(out).to include("card: 2 runs, 2 with a failure")
    end

    it "counts a run that exits 0 after running no example" do
      out, = redrate(tree("card", "echo '0 examples, 0 failures'"), tree("base", counting_stub(fail_every: 1_000)),
                     rounds: 2)

      expect(out).to include("card: 2 runs, 2 with a failure")
    end

    it "reports an added example as information, not a failure" do
      out, status = redrate(tree("card", counting_stub(fail_every: 1_000, examples: 4)),
                            tree("base", counting_stub(fail_every: 1_000, examples: 3)), rounds: 2)

      expect(status.exitstatus).to eq(0)
      expect(out).to include("example count: card 4, base 3")
    end

    it "fails when one tree's example count varies between runs" do
      varying = "n=$(( $(cat count 2>/dev/null || echo 0) + 1 )); echo $n > count; " \
                "if [ $((n % 2)) -eq 0 ]; then echo '2 examples, 0 failures'; else echo '3 examples, 0 failures'; fi"
      out, status = redrate(tree("card", varying), tree("base", counting_stub(fail_every: 1_000)))

      expect(status.exitstatus).to eq(1)
      expect(out).to include("example count varies in card: 2/3")
    end
  end
end
