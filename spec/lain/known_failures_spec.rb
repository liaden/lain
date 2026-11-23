# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

# Fake `bundle` and `cargo` on PATH stand in for the suite: a real one is minutes of work per example.
RSpec.describe "bin/known-failures" do
  let(:repo) { File.expand_path("../..", __dir__) }
  let(:tool) { File.join(repo, "bin/known-failures") }
  let(:recorder) { File.join(repo, "spec/support/known_failure_recorder.rb") }
  let(:ledger_path) { File.join(@root, "spec/vm_known_failures.txt") }
  let(:known) { "./spec/a_spec.rb does a thing" }
  let(:floors) { "floor:daemon\t1\nfloor:ruby\t1\nfloor:rust\t1\n" }

  around do |example|
    Dir.mktmpdir("known-failures-spec") do |dir|
      @root = File.realpath(dir)
      FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", @root)
      FileUtils.mkdir_p([fake_bin, payload, File.join(@root, "spec")])
      fake_commands
      example.run
    end
  end

  def fake_bin = File.join(@root, "fakebin")
  def payload = File.join(@root, "payload")
  def calls = File.read(File.join(@root, "calls")).lines(chomp: true)

  def executable(path, body)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  def fake_commands(suite_status: 0, rubocop_status: 0, cargo_status: 0, compile_status: 0)
    executable(File.join(fake_bin, "bundle"), <<~SH)
      #!/bin/sh
      echo "bundle $*" >> "#{@root}/calls"
      echo "${LAIN_REQUIRE_BINARIES-unset} ${TEST_ENV_NUMBER-unset}" >> "#{@root}/env_seen"
      case "$*" in
        "exec rake compile daemon:build") exit #{compile_status} ;;
        "exec rubocop --parallel") exit #{rubocop_status} ;;
      esac
      if [ -x "#{@root}/real_suite" ]; then exec "#{@root}/real_suite"; fi
      if [ -n "$LAIN_KNOWN_FAILURES_OUT" ]; then cp -R "#{payload}/." "$LAIN_KNOWN_FAILURES_OUT/"; fi
      exit #{suite_status}
    SH
    fake_cargo(cargo_status)
  end

  def fake_cargo(status)
    executable(File.join(fake_bin, "cargo"), <<~SH)
      #!/bin/sh
      echo "cargo $*" >> "#{@root}/calls"
      if [ -f "#{@root}/cargo_output" ]; then command cat "#{@root}/cargo_output"; fi
      exit #{status}
    SH
  end

  def child_env(extra = {})
    SeedRepo::SCRUB.merge("PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}", "LAIN_SPEC_WORKERS" => "2",
                          "LAIN_KNOWN_FAILURES" => nil, "LAIN_KNOWN_FAILURES_OUT" => nil,
                          "TEST_ENV_NUMBER" => nil, "SPEC_OPTS" => nil).merge(extra)
  end

  def run_tool(*args, env: {})
    output, status = Open3.capture2e(child_env(env), RbConfig.ruby, tool, *args, chdir: @root)
    [output, status.exitstatus]
  end

  def stage_ledger(text)
    File.write(ledger_path, text)
    SeedRepo.git(@root, "add", "spec/vm_known_failures.txt")
  end

  def commit_ledger(text)
    stage_ledger(text)
    SeedRepo.git(@root, "commit", "-q", "-m", "ledger")
  end

  def worker(id, failed: [], passed: ["./spec/b_spec.rb passes"], errors: [], expected: nil)
    count = failed.size + passed.size
    File.write(File.join(payload, "worker-#{id}.json"),
               JSON.generate(expected: expected || count, examples: count, seed: 4242,
                             failed:, passed:, errors:))
    File.write(File.join(payload, "worker-#{id}.exit"), "")
  end

  def calls_or_none = File.exist?(File.join(@root, "calls")) ? calls : []

  def real_suite(files, workers: "1", before_recorder: "")
    files.each { |name, body| File.write(File.join(@root, "spec", name), body) }
    File.write(File.join(@root, "before_recorder.rb"), before_recorder)
    executable(File.join(@root, "real_suite"), <<~SH)
      #!/bin/sh
      cd "#{@root}"
      exec "#{RbConfig.ruby}" -rbundler/setup -e 'load Gem.bin_path("rspec-core", "rspec")' -- \
        --require "#{@root}/before_recorder.rb" --require "#{recorder}" --format progress spec
    SH
    { "BUNDLE_GEMFILE" => File.join(repo, "Gemfile"), "LAIN_SPEC_WORKERS" => workers }
  end

  def failing_spec(description) = %(RSpec.describe("thing") { it("#{description}") { raise "no" } }\n)

  describe "the wrapped hooks" do
    originals = {
      "ruby-checks" => ["bundle exec rake compile daemon:build check", "ruby"],
      "daemon-tier" => ["bundle exec rspec --tag core --tag daemon", "daemon"],
      "cargo-test" => ["cargo test", "rust"]
    }.freeze

    def entry_of(id)
      config = YAML.load_file(File.join(repo, ".pre-commit-config.yaml"))
      config.fetch("repos").flat_map { _1.fetch("hooks") }.find { _1["id"] == id }.fetch("entry")
    end

    originals.each do |id, (command, tier)|
      it "runs the original #{id} command and returns its status when the variable is unset" do
        fake_commands(suite_status: 7, cargo_status: 7)

        _out, status = Open3.capture2e(child_env, *Shellwords.split(entry_of(id)), chdir: @root)

        expect(status.exitstatus).to eq(7)
        expect(calls.last.delete_prefix("bundle ").delete_prefix("exec ")).to eq(command.delete_prefix("bundle exec "))
        expect(calls.join("\n")).not_to include("known-failures")
      end

      it "hands #{id} to the #{tier} gate when the variable is set" do
        FileUtils.mkdir_p(File.join(@root, "bin"))
        executable(File.join(@root, "bin/known-failures"), %(#!/bin/sh\necho "gate $*" >> "#{@root}/calls"\nexit 5\n))

        _out, status = Open3.capture2e(child_env("LAIN_KNOWN_FAILURES" => "1"), *Shellwords.split(entry_of(id)),
                                       chdir: @root)

        expect(status.exitstatus).to eq(5)
        expect(calls).to eq(["gate hook #{tier}"])
      end
    end

    describe "the ledger hook" do
      def ledger_hook
        config = YAML.load_file(File.join(repo, ".pre-commit-config.yaml"))
        config.fetch("repos").flat_map { _1.fetch("hooks") }.find { _1["id"] == "known-failures-ledger" }
      end

      it "fires on the ledger alone and takes no filenames" do
        expect(ledger_hook).to include("files" => '^spec/vm_known_failures\.txt$', "pass_filenames" => false,
                                       "language" => "system")
      end

      it "hands the check to the tool when the variable is set" do
        FileUtils.mkdir_p(File.join(@root, "bin"))
        executable(File.join(@root, "bin/known-failures"), %(#!/bin/sh\necho "gate $*" >> "#{@root}/calls"\nexit 5\n))

        _out, status = Open3.capture2e(child_env("LAIN_KNOWN_FAILURES" => "1"),
                                       *Shellwords.split(ledger_hook.fetch("entry")), chdir: @root)

        expect(status.exitstatus).to eq(5)
        expect(calls).to eq(["gate hook ledger"])
      end

      it "runs nothing and passes when the variable is unset" do
        FileUtils.mkdir_p(File.join(@root, "bin"))
        executable(File.join(@root, "bin/known-failures"), %(#!/bin/sh\necho "gate $*" >> "#{@root}/calls"\nexit 5\n))

        _out, status = Open3.capture2e(child_env, *Shellwords.split(ledger_hook.fetch("entry")), chdir: @root)

        expect(status.exitstatus).to eq(0)
        expect(calls_or_none).to be_empty
      end
    end
  end

  describe "hook ruby" do
    before { fake_commands(suite_status: 1) }

    it "blocks a new failure and names it" do
      commit_ledger(floors)
      worker(1, failed: [known])
      worker(2)

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include(known)
    end

    it "passes known failures and prints the remaining count" do
      commit_ledger("#{floors}#{known}\tfailed 3 of 3\n")
      worker(1, failed: [known])
      worker(2)

      output, status = run_tool("hook", "ruby")

      expect(status).to eq(0)
      expect(output).to include("1 known failure")
      expect(calls).to eq(["bundle exec rake compile daemon:build", "bundle exec rake pspec",
                           "bundle exec rubocop --parallel"])
    end

    it "prints an entry that passed and leaves the ledger alone" do
      text = "#{floors}#{known}\tfailed 1 of 3\n"
      commit_ledger(text)
      worker(1, passed: [known])
      worker(2)
      fake_commands

      output, status = run_tool("hook", "ruby")

      expect(status).to eq(0)
      expect(output).to include("passed", known)
      expect(File.read(ledger_path)).to eq(text)
    end

    it "blocks a second failure under a shared description" do
      commit_ledger("#{floors}#{known}\tfailed 3 of 3\n")
      worker(1, failed: [known])
      worker(2, failed: [known])

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include(known)
    end

    it "treats a failure whose address changed as known" do
      commit_ledger("#{floors}./spec/held_spec.rb thing holds 0x0\tfailed 3 of 3\n")
      env = real_suite({ "held_spec.rb" => failing_spec("holds 0x00007f02") })

      output, status = run_tool("hook", "ruby", env:)

      expect(status).to eq(0), output
    end

    it "refuses a staged entry with no reason, once a ledger is committed" do
      commit_ledger(floors)
      stage_ledger("#{floors}#{known}\t\n")

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include(known)
      expect(calls_or_none).to be_empty
    end

    it "names a worker that wrote no summary" do
      commit_ledger(floors)
      worker(1)

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include("worker 2")
    end

    it "does not take a stale file from an earlier run for a live worker" do
      commit_ledger(floors)
      worker(1)
      worker(2)
      fake_commands
      expect(run_tool("hook", "ruby").last).to eq(0)
      FileUtils.rm(File.join(payload, "worker-2.json"))

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include("worker 2")
    end

    it "blocks a worker that stopped before its last example" do
      commit_ledger(floors)
      worker(1, expected: 9)
      worker(2)

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include("worker 1")
    end

    it "names a spec file that raises at load" do
      commit_ledger("#{floors}#{known}\tfailed 3 of 3\n")
      env = real_suite({ "fine_spec.rb" => %(RSpec.describe("fine") { it("works") { expect(1).to eq(1) } }\n),
                         "broken_spec.rb" => "raise 'cannot load'\n" })

      output, status = run_tool("hook", "ruby", env:)

      expect(status).not_to eq(0)
      expect(output).to match(/outside examples.*broken_spec/m)
    end

    it "blocks a count below the floor" do
      commit_ledger("floor:daemon\t1\nfloor:ruby\t100\nfloor:rust\t1\n")
      worker(1)
      worker(2)
      fake_commands

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include("floor")
    end

    it "blocks a failed command that recorded no failures" do
      commit_ledger(floors)
      worker(1)
      worker(2)

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include("0 recorded failures")
    end

    it "blocks a rubocop offense beside known failures" do
      commit_ledger("#{floors}#{known}\tfailed 3 of 3\n")
      worker(1, failed: [known])
      worker(2)
      fake_commands(suite_status: 1, rubocop_status: 1)

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include("rubocop")
    end

    it "blocks a failed compile and starts no suite" do
      commit_ledger(floors)
      worker(1)
      worker(2)
      fake_commands(compile_status: 1)

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include("compile failed")
      expect(calls).to eq(["bundle exec rake compile daemon:build"])
    end

    it "judges the staged ledger, not an unstaged edit to it" do
      commit_ledger(floors)
      File.write(ledger_path, "#{floors}#{known}\tfailed 3 of 3\n")
      worker(1, failed: [known])
      worker(2)

      output, status = run_tool("hook", "ruby")

      expect(status).not_to eq(0)
      expect(output).to include("new failure: #{known}")
    end

    it "does not call an entry passed while it still fails or when it never ran" do
      never_ran = "./spec/c_spec.rb never ran"
      commit_ledger("#{floors}#{known}\tfailed 3 of 3\n#{never_ran}\tfailed 1 of 3\n")
      worker(1, failed: [known], passed: [known])
      worker(2)

      output, status = run_tool("hook", "ruby")

      expect(status).to eq(0), output
      expect(output).not_to include("passed, delete")
    end

    it "blocks a worker that crashes after writing its summary, naming it" do
      commit_ledger("#{floors}./spec/crash_spec.rb thing dies\tfailed 3 of 3\n")
      env = real_suite({ "crash_spec.rb" => "at_exit { exit! 3 }\n#{failing_spec("dies")}" })

      output, status = run_tool("hook", "ruby", env:)

      expect(status).not_to eq(0)
      expect(output).to include("worker 1 wrote a summary but did not exit cleanly")
    end

    it "blocks a worker whose exit handler raises after its summary" do
      commit_ledger("#{floors}./spec/raises_spec.rb thing dies\tfailed 3 of 3\n")
      env = real_suite({ "raises_spec.rb" => %(at_exit { raise "dies in a handler" }\n#{failing_spec("dies")}) })

      output, status = run_tool("hook", "ruby", env:)

      expect(status).not_to eq(0)
      expect(output).to include("worker 1 wrote a summary but did not exit cleanly")
    end

    it "blocks a later exit handler that changes the status to one rspec never uses" do
      commit_ledger("#{floors}./spec/status_spec.rb thing dies\tfailed 3 of 3\n")
      env = real_suite({ "status_spec.rb" => "at_exit { exit 3 }\n#{failing_spec("dies")}" })

      output, status = run_tool("hook", "ruby", env:)

      expect(status).not_to eq(0)
      expect(output).to include("worker 1 wrote a summary but did not exit cleanly")
    end

    it "blocks a crash in an exit handler registered before the recorder" do
      commit_ledger("#{floors}./spec/early_spec.rb thing dies\tfailed 3 of 3\n")
      env = real_suite({ "early_spec.rb" => failing_spec("dies") }, before_recorder: "at_exit { exit! 3 }\n")

      output, status = run_tool("hook", "ruby", env:)

      expect(status).not_to eq(0)
      expect(output).to include("worker 1 wrote a summary but did not exit cleanly")
    end

    it "does not take a forked child's clean exit for its worker's" do
      commit_ledger("#{floors}./spec/fork_spec.rb thing forks\tfailed 3 of 3\n")
      body = <<~RUBY
        parent = Process.pid
        at_exit { exit!(3) if Process.pid == parent }
        RSpec.describe("thing") do
          it("forks") do
            Process.wait(fork { exit 0 })
            raise "no"
          end
        end
      RUBY
      env = real_suite({ "fork_spec.rb" => body })

      output, status = run_tool("hook", "ruby", env:)

      expect(status).not_to eq(0)
      expect(output).to include("worker 1 wrote a summary but did not exit cleanly")
    end

    it "passes a real worker that exits cleanly beside a known failure" do
      commit_ledger("#{floors}./spec/held_spec.rb thing fails\tfailed 3 of 3\n")
      env = real_suite({ "held_spec.rb" => failing_spec("fails") })

      output, status = run_tool("hook", "ruby", env:)

      expect(status).to eq(0), output
    end

    it "catches a real worker that exits inside an example" do
      commit_ledger(floors)
      body = %(RSpec.describe("thing") { it("leaves") { exit 0 }; it("stays") { } }\n)
      env = real_suite({ "leaves_spec.rb" => body })

      output, status = run_tool("hook", "ruby", env:)

      expect(status).not_to eq(0)
      expect(output).to include("worker 1 stopped after 1 of 2 examples")
    end

    it "hides the output directory from anything a spec spawns" do
      commit_ledger(floors)
      body = %(RSpec.describe("thing") { it("looks") { raise "leaked" if ENV.key?("LAIN_KNOWN_FAILURES_OUT") } }\n)
      env = real_suite({ "env_spec.rb" => body })

      output, status = run_tool("hook", "ruby", env:)

      expect(status).to eq(0), output
    end

    it "folds whitespace in a description so the key stays on 1 ledger line" do
      commit_ledger("#{floors}./spec/wide_spec.rb thing spans lines\tfailed 3 of 3\n")
      env = real_suite({ "wide_spec.rb" => failing_spec('spans\n\tlines') })

      output, status = run_tool("hook", "ruby", env:)

      expect(status).to eq(0), output
    end
  end

  describe "hook ledger" do
    it "refuses a staged entry with no reason, names it, and runs no suite" do
      commit_ledger(floors)
      stage_ledger("#{floors}#{known}\t\n")

      output, status = run_tool("hook", "ledger")

      expect(status).not_to eq(0)
      expect(output).to include(known)
      expect(calls_or_none).to be_empty
    end

    it "passes the first ledger commit, when HEAD holds no ledger" do
      stage_ledger("#{floors}#{known}\tfailed 3 of 3\n")

      output, status = run_tool("hook", "ledger")

      expect(status).to eq(0), output
      expect(calls_or_none).to be_empty
    end

    it "refuses a no-reason entry re-added after the ledger was deleted from HEAD" do
      commit_ledger("#{floors}#{known}\tfailed 3 of 3\n")
      SeedRepo.git(@root, "rm", "-q", "spec/vm_known_failures.txt")
      SeedRepo.git(@root, "commit", "-q", "-m", "delete ledger")
      FileUtils.mkdir_p(File.dirname(ledger_path))
      stage_ledger("#{floors}#{known}\t\n")

      output, status = run_tool("hook", "ledger")

      expect(status).not_to eq(0)
      expect(output).to include(known)
    end

    it "passes an added entry that carries a reason" do
      commit_ledger(floors)
      stage_ledger("#{floors}#{known}\tfailed 1 of 3 (seed 1, load 2.0)\n")

      output, status = run_tool("hook", "ledger")

      expect(status).to eq(0), output
    end

    it "does not read git's stderr as ledger lines" do
      commit_ledger(floors)
      stage_ledger("#{floors}#{known}\tfailed 1 of 3\n")
      real_git = Open3.capture2("sh", "-c", "command -v git").first.strip
      executable(File.join(fake_bin, "git"), <<~SH)
        #!/bin/sh
        case "$2" in :spec*) echo "warning: noise from git" >&2 ;; esac
        exec "#{real_git}" "$@"
      SH

      output, status = run_tool("hook", "ledger")

      expect(status).to eq(0), output
    end

    it "prints a lowered floor with its old and new value, and allows it" do
      commit_ledger("floor:daemon\t1\nfloor:ruby\t100\nfloor:rust\t1\n")
      stage_ledger("floor:daemon\t1\nfloor:ruby\t90\nfloor:rust\t1\n")

      output, status = run_tool("hook", "ledger")

      expect(status).to eq(0), output
      expect(output).to include("ruby floor lowered from 100 to 90")
    end
  end

  describe "hook daemon" do
    it "runs the tagged specs as 1 worker with binaries required" do
      commit_ledger(floors)
      worker(1)

      output, status = run_tool("hook", "daemon", env: { "TEST_ENV_NUMBER" => "9" })

      expect(status).to eq(0), output
      expect(calls).to eq(["bundle exec rake compile daemon:build", "bundle exec rspec --tag core --tag daemon"])
      expect(File.readlines(File.join(@root, "env_seen"), chomp: true)).to all(eq("1 unset"))
    end
  end

  describe "hook rust" do
    let(:rust_key) { "sockets/tests/sockets.rs reaches_nothing" }

    def cargo_output(failed: "FAILED", summary: true, reported: "1 passed; 1 failed")
      result = "test result: FAILED. #{reported}; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s\n"
      File.write(File.join(@root, "cargo_output"), <<~OUT)
        Running tests/sockets.rs (target/debug/deps/sockets-0123456789abcdef)

        running 2 tests
        test holds_up ... ok
        test reaches_nothing ... #{failed}

        #{result if summary}
      OUT
    end

    it "keeps going past a failing target and passes a known failure" do
      commit_ledger("#{floors}#{rust_key}\tfailed 3 of 3\n")
      cargo_output
      fake_commands(cargo_status: 101)

      output, status = run_tool("hook", "rust")

      expect(status).to eq(0), output
      expect(calls).to eq(["cargo test --no-fail-fast"])
    end

    it "blocks a new failure and names it" do
      commit_ledger(floors)
      cargo_output
      fake_commands(cargo_status: 101)

      output, status = run_tool("hook", "rust")

      expect(status).not_to eq(0)
      expect(output).to include(rust_key)
    end

    it "names a test binary that died before its summary" do
      commit_ledger("#{floors}#{rust_key}\tfailed 3 of 3\n")
      cargo_output(summary: false)
      fake_commands(cargo_status: 101)

      output, status = run_tool("hook", "rust")

      expect(status).not_to eq(0)
      expect(output).to include("sockets/tests/sockets.rs")
    end

    it "blocks a failed cargo run that recorded no failures" do
      commit_ledger(floors)
      cargo_output(failed: "ok", reported: "2 passed; 0 failed")
      fake_commands(cargo_status: 101)

      output, status = run_tool("hook", "rust")

      expect(status).not_to eq(0)
      expect(output).to include("0 recorded failures")
    end

    it "blocks a target whose reported counts disagree with its test lines" do
      commit_ledger("#{floors}#{rust_key}\tfailed 3 of 3\n")
      cargo_output(reported: "3 passed; 1 failed")
      fake_commands(cargo_status: 101)

      output, status = run_tool("hook", "rust")

      expect(status).not_to eq(0)
      expect(output).to include("sockets/tests/sockets.rs reported 3/1")
    end
  end

  describe "add" do
    before { fake_commands(suite_status: 1) }

    it "records a failure the last hook saw, with its seed and load, in sorted order" do
      commit_ledger(floors)
      worker(1, failed: [known])
      worker(2)
      run_tool("hook", "ruby")

      output, status = run_tool("add", known, "--because", "failed 1 of 3")

      expect(status).to eq(0), output
      lines = File.readlines(ledger_path, chomp: true)
      expect(lines).to eq(lines.sort)
      expect(lines.find { _1.start_with?(known) }).to match(/\tfailed 1 of 3 \(seed 4242, load .+\)\z/)
    end

    it "refuses a key no recorded run failed" do
      commit_ledger(floors)

      output, status = run_tool("add", "./spec/typo_spec.rb nope", "--because", "failed 1 of 3")

      expect(status).not_to eq(0)
      expect(output).to include("typo_spec")
      expect(File.read(ledger_path)).to eq(floors)
    end
  end

  describe "record" do
    it "writes measured reasons, 1 line per failing example, and a floor per tier" do
      commit_ledger(floors)
      worker(1, failed: [known, known])
      worker(2)
      File.write(File.join(@root, "cargo_output"), <<~OUT)
        Running tests/sockets.rs (target/debug/deps/sockets-0123456789abcdef)
        test holds_up ... ok
        test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
      OUT
      fake_commands(suite_status: 1)

      output, status = run_tool("record", env: { "LAIN_SPEC_WORKERS" => "1" })

      expect(status).to eq(0), output
      text = File.read(ledger_path)
      expect(text.lines.count { _1.start_with?("#{known}\tfailed 3 of 3") }).to eq(2)
      expect(text).to include("floor:ruby\t3\n", "floor:daemon\t3\n", "floor:rust\t1\n")
    end

    it "writes nothing when a run cannot be trusted" do
      commit_ledger(floors)

      output, status = run_tool("record")

      expect(status).not_to eq(0), output
      expect(File.read(ledger_path)).to eq(floors)
    end
  end

  describe "the recorder beside the suite's formatters" do
    it "leaves progress output and the runtime log intact under parallel_rspec" do
      %w[one two].each do |name|
        File.write(File.join(@root, "spec/#{name}_spec.rb"), %(RSpec.describe("#{name}") { it("works") { } }\n))
      end
      FileUtils.mkdir_p(File.join(@root, "tmp"))
      out = File.join(@root, "recorded")
      FileUtils.mkdir_p(out)
      env = SeedRepo::SCRUB.merge("BUNDLE_GEMFILE" => File.join(repo, "Gemfile"), "LAIN_KNOWN_FAILURES_OUT" => out,
                                  "TEST_ENV_NUMBER" => nil, "SPEC_OPTS" => nil)
      options = "--require #{recorder} --format progress --format ParallelTests::RSpec::RuntimeLogger " \
                "--out tmp/parallel_runtime_rspec.log"

      output, status = Open3.capture2e(env, RbConfig.ruby, "-rbundler/setup", "-e",
                                       'load Gem.bin_path("parallel_tests", "parallel_rspec")', "--",
                                       "spec", "-n", "2", "--test-options", options, chdir: @root)

      expect(status).to be_success, output
      expect(output).to include("2 examples, 0 failures")
      expect(File.read(File.join(@root, "tmp/parallel_runtime_rspec.log"))).to include("one_spec.rb", "two_spec.rb")
      expect(Dir.children(out)).to contain_exactly("worker-1.json", "worker-1.exit", "worker-2.json", "worker-2.exit")
    end
  end
end
