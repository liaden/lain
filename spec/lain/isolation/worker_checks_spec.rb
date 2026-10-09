# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# The worker lain asks to fix its checks: it records every prompt, runs an
# injected action in its checkout as the model would with its shell, and
# answers with `reply`.
class WorkerChecksSpecWorker
  attr_reader :prompts

  def initialize(reply: "fixed", &action)
    @prompts = []
    @reply = reply
    @action = action || ->(_prompt) {}
  end

  def ask(text)
    @prompts << text
    @action.call(text)
    Lain::Response.new(content: [{ "type" => "text", "text" => @reply }], stop_reason: :end_turn)
  end
end

# Runs every command for real, and keeps each argv it was handed.
class WorkerChecksSpecRecorder
  attr_reader :argvs

  def initialize
    @argvs = []
  end

  def call(*argv, **)
    @argvs << argv
    Lain::Shell::Out.new(*argv, **)
  end

  # @param command [Array<String>] the configured argv, which every run of it starts with
  def runs_of(command) = argvs.select { |argv| argv.first(command.size) == command }
end

# Drives real git and real commands in a throwaway repository: a leased
# worktree cut from `feat`, a worker commit in it, and a check that reads the
# spec files it is handed.
RSpec.describe Lain::Isolation::WorkerChecks, :seam do
  subject(:checks) do
    described_class.new(base:, layout:, check:, lint:, lint_files:, retries:, shell_out_factory: recorder)
  end

  around do |example|
    Dir.mktmpdir("lain-checks-repo") do |repo|
      Dir.mktmpdir("lain-checks-worktrees") do |root|
        @repo = File.realpath(repo)
        @root = File.realpath(root)
        SeedRepo.derived("worker_checks", into: @repo) { |template| seed(template) }
        SeedRepo.git(@repo, "switch", "-q", "-c", "feat")
        example.run
      ensure
        @lease&.release
      end
    end
  end

  # `$0` names the command in its own output.
  def runner(name, script) = ["sh", "-c", script, name]

  # A spec file passes when one of its lines starts with "passes".
  let(:rspec) do
    runner("rspec", 'for spec do grep -q "^passes" "$spec" || { echo "$spec: expected passes"; exit 1; }; done')
  end
  let(:rubocop) { runner("rubocop", 'echo "inspected $*"') }

  let(:recorder) { WorkerChecksSpecRecorder.new }
  let(:base) { Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo) }
  let(:backend) { Lain::Isolation::Worktree.new(repo_root: @repo, root: @root, base:) }
  let(:lease) { @lease = backend.acquire("worker-1") }
  let(:tree) { lease.worker_env.cwd }
  let(:layout) { Lain::TestLayout.from({ "preset" => "rspec" }, path: nil) }
  let(:check) { rspec }
  let(:lint) { [] }
  let(:lint_files) { [] }
  let(:retries) { 1 }

  def foo = "class Foo; end\n"

  def seed(template)
    { "lib/foo.rb" => foo, "spec/unit/foo_spec.rb" => "fails\n", "README" => "seed\n" }.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(template, path)))
      File.write(File.join(template, path), body)
    end
    SeedRepo.git(template, "add", "-A")
    SeedRepo.git(template, "commit", "-q", "-m", "a source and its failing spec")
  end

  def commit(file, body)
    FileUtils.mkdir_p(File.dirname(File.join(tree, file)))
    File.write(File.join(tree, file), body)
    SeedRepo.git(tree, "add", file)
    SeedRepo.git(tree, "commit", "-q", "-m", "#{file} changed")
  end

  def break_foo = commit("lib/foo.rb", "class Foo; def bar = 1; end\n")

  def askable(worker) = Lain::Isolation::SelfSync.worker(worker, tools: %w[read_file bash])

  def run_checks(worker = askable(WorkerChecksSpecWorker.new)) = checks.call(lease, worker:, worker_id: "worker-1")

  describe "a failing mirror spec" do
    it "is shown to an askable worker, who fixes and commits, and the checks run again" do
      break_foo
      worker = WorkerChecksSpecWorker.new { commit("spec/unit/foo_spec.rb", "passes\n") }

      result = run_checks(askable(worker))

      expect(worker.prompts.size).to eq(1)
      expect(worker.prompts.first).to include("spec/unit/foo_spec.rb: expected passes")
      expect(recorder.runs_of(rspec).size).to eq(2)
      expect(recorder.runs_of(rspec)).to all(end_with("spec/unit/foo_spec.rb"))
      expect(result.attempts.size).to eq(2)
      expect(result.outcome).to eq(:fixed)
    end
  end

  describe "no tests table" do
    let(:layout) { Lain::TestLayout::None }
    let(:lint) { rubocop }

    before { allow(Lain::TestLayout::Mapping).to receive(:new).and_call_original }

    it "runs only the lint, over the changed files, and never consults the layout's mapping" do
      break_foo

      result = run_checks

      expect(recorder.runs_of(rspec)).to be_empty
      expect(recorder.runs_of(rubocop)).to eq([[*rubocop, "lib/foo.rb"]])
      expect(Lain::TestLayout::Mapping).not_to have_received(:new)
      expect(result.outcome).to eq(:passed)
    end
  end

  describe "a worker without bash" do
    it "is reported failed with the output, and never asked" do
      break_foo
      agent = WorkerChecksSpecWorker.new

      result = run_checks(Lain::Isolation::SelfSync.worker(agent, tools: %w[read_file]))

      expect(result.outcome).to eq(:failed)
      expect(result.detail).to include("spec/unit/foo_spec.rb: expected passes")
      expect(agent.prompts).to be_empty
      expect(recorder.runs_of(rspec).size).to eq(1)
      expect(result.attempts.size).to eq(1)
    end
  end

  describe "nothing configured" do
    let(:check) { [] }

    it "is skipped without spawning a process" do
      break_foo

      result = run_checks

      expect(result.outcome).to eq(:skipped)
      expect(recorder.argvs).to be_empty
    end
  end

  describe "a lease that cut no checkout" do
    it "is skipped, saying so, without spawning a process" do
      no_checkout = Struct.new(:origin).new(Lain::Isolation::Lease::Origin.new(path: nil, base: nil, branch: nil))

      result = checks.call(no_checkout, worker: Lain::Isolation::SelfSync::Unaskable, worker_id: "worker-1")

      expect(result.outcome).to eq(:skipped)
      expect(result.detail).to include("no checkout")
      expect(recorder.argvs).to be_empty
    end
  end

  describe "a negative retries" do
    it "is refused when built" do
      expect { described_class.new(base:, layout:, check:, lint:, lint_files:, retries: -1) }
        .to raise_error(ArgumentError, /retries/)
    end
  end

  describe "uncommitted work in the checkout" do
    it "is reported dirty, and no check runs" do
      break_foo
      File.write(File.join(tree, "notes.txt"), "not committed\n")

      result = run_checks

      expect(result.outcome).to eq(:dirty)
      expect(result.detail).to include(tree)
      expect(recorder.runs_of(rspec)).to be_empty
    end
  end

  describe "retries: 0" do
    let(:retries) { 0 }

    it "fails without asking" do
      break_foo
      worker = WorkerChecksSpecWorker.new

      result = run_checks(askable(worker))

      expect(result.outcome).to eq(:failed)
      expect(worker.prompts).to be_empty
      expect(recorder.runs_of(rspec).size).to eq(1)
    end
  end

  describe "an ask that raises" do
    it "is measured by running the checks again, and named in the detail" do
      break_foo
      worker = WorkerChecksSpecWorker.new { raise Lain::Error, "budget spent" }

      result = run_checks(askable(worker))

      expect(result.outcome).to eq(:failed)
      expect(recorder.runs_of(rspec).size).to eq(2)
      expect(result.detail).to include("the ask raised Lain::Error: budget spent")
    end
  end

  describe "a change with nothing to check" do
    it "is skipped, and no check runs" do
      commit("README", "edited\n")

      result = run_checks

      expect(result.outcome).to eq(:skipped)
      expect(recorder.runs_of(rspec)).to be_empty
    end
  end

  describe "a fix that leaves nothing to check" do
    it "is fixed, not skipped" do
      break_foo
      worker = WorkerChecksSpecWorker.new { commit("lib/foo.rb", foo) }

      result = run_checks(askable(worker))

      expect(worker.prompts.size).to eq(1)
      expect(result.outcome).to eq(:fixed)
    end
  end

  describe "a changed test file with no changed source" do
    it "reaches the test run" do
      commit("spec/unit/bar_spec.rb", "passes\n")

      result = run_checks

      expect(recorder.runs_of(rspec)).to eq([[*rspec, "spec/unit/bar_spec.rb"]])
      expect(result.outcome).to eq(:passed)
    end
  end

  describe "a check's TMPDIR" do
    let(:check) { runner("rspec", 'echo "tmp=$TMPDIR"; test -d "$TMPDIR" && exit 1') }

    it "is a directory in the worktree, removed after the run" do
      break_foo

      result = run_checks(Lain::Isolation::SelfSync::Unaskable)

      expect(result.detail).to include("tmp=#{tree}/lain-checks-")
      expect(Dir.glob(File.join(tree, "lain-checks-*"))).to be_empty
    end
  end

  describe "a long failure" do
    let(:retries) { 0 }

    context "with many lines" do
      let(:check) { runner("rspec", "seq 1 100; exit 1") }

      it "shows only the last 40" do
        break_foo

        lines = run_checks.detail.lines.map(&:chomp)

        expect(lines).to include("61", "100")
        expect(lines).not_to include("60")
      end
    end

    context "with one huge line" do
      let(:check) { runner("rspec", "head -c 300000 /dev/zero | tr '\\0' x; exit 1") }

      it "is capped by bytes too" do
        break_foo

        expect(run_checks.detail.bytesize).to be <= described_class::TAIL_BYTES + 200
      end
    end
  end

  describe "non-ASCII output, paths and replies" do
    let(:check) { [] }
    let(:lint) { runner("rubocop", 'echo "expected café in $*"; exit 1') }

    it "reach the worker and the record intact" do
      commit("lib/naïve.rb", "class Naïve; end\n")
      worker = WorkerChecksSpecWorker.new(reply: "désolé")

      result = run_checks(askable(worker))

      expect(worker.prompts.size).to eq(1)
      expect(worker.prompts.first).to include("lib/naïve.rb", "expected café")
      expect(result.outcome).to eq(:failed)
      expect(result.detail).to include("café", "désolé")
      expect(JSON.parse(JSON.generate(result.to_record))["checks"]["detail"]).to include("désolé")
    end
  end

  describe "output that is not UTF-8" do
    let(:check) { runner("rspec", "printf '\\377\\376 binary\\n'; exit 1") }

    it "still journals" do
      break_foo

      result = run_checks(Lain::Isolation::SelfSync::Unaskable)

      expect(result.detail).to be_valid_encoding
      expect(JSON.generate(result.to_record)).to include("binary")
    end
  end

  describe "lint_files" do
    let(:check) { [] }
    let(:lint) { rubocop }
    let(:lint_files) { ["lib/**/*.rb"] }

    it "hands the lint only the changed files that match" do
      break_foo
      commit("README", "edited\n")

      run_checks

      expect(recorder.runs_of(rubocop)).to eq([[*rubocop, "lib/foo.rb"]])
    end

    context "with a glob from the top" do
      let(:lint_files) { ["**/*.rb"] }

      it "matches a file under a dot directory" do
        commit(".lain/config.rb", "tests preset: \"rspec\"\n")

        run_checks

        expect(recorder.runs_of(rubocop)).to eq([[*rubocop, ".lain/config.rb"]])
      end
    end

    it "runs no lint when no changed file matches" do
      commit("README", "edited\n")

      result = run_checks

      expect(recorder.runs_of(rubocop)).to be_empty
      expect(result.outcome).to eq(:skipped)
    end
  end

  describe "files a check leaves behind" do
    let(:check) { [] }
    let(:lint) { runner("rubocop", "mkdir -p cache && echo x > cache/lint.txt && echo more >> README") }

    it "removes the untracked ones it made and names them, and keeps its edits to tracked files" do
      break_foo

      result = run_checks

      expect(result.outcome).to eq(:passed)
      expect(File.exist?(File.join(tree, "cache/lint.txt"))).to be(false)
      expect(result.detail).to include("cache/lint.txt")
      expect(File.read(File.join(tree, "README"))).to eq("seed\nmore\n")
    end
  end
end
