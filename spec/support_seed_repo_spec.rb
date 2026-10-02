# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "mixlib/shellout"

# worktree_handback_spec was flaky for weeks because `git commit` and `git merge`
# end by spawning a DETACHED `git maintenance run --auto`, which outlives the
# example and writes under .git/objects while Dir.mktmpdir tears the repo down.
# The failure names whichever example the `around` hook was closing, never the
# cause, so the only durable guard is one that asks git directly whether a
# process was spawned.
RSpec.describe SeedRepo, :seam do
  def commit_trace(repo, *config)
    args = config.flat_map { |pair| ["-c", pair] }
    shell = Mixlib::ShellOut.new("git", "-C", repo, *args, "commit", "--allow-empty", "-q", "-m", "probe",
                                 environment: SeedRepo::SCRUB.merge("GIT_TRACE" => "2"))
    shell.run_command.error!
    shell.stderr
  end

  around do |example|
    Dir.mktmpdir("lain-seed-guard") do |dir|
      @repo = File.join(dir, "repo")
      FileUtils.mkdir_p(@repo)
      FileUtils.cp_r("#{described_class.at({ "README" => "seed\n" })}/.", @repo)
      example.run
    end
  end

  it "commits without spawning a detached maintenance process for teardown to race" do
    expect(commit_trace(@repo)).not_to include("maintenance")
  end

  # Without this the example above could pass because the trace stopped showing
  # maintenance at all, rather than because the pins hold it off.
  it "would spawn one if the pins were lifted, so the trace above can see the difference" do
    trace = commit_trace(@repo, "maintenance.auto=true", "gc.auto=6700")

    expect(trace).to include("maintenance")
  end

  describe ".git" do
    def forks_during
      count = 0
      allow(Process).to receive(:_fork).and_wrap_original do |original|
        count += 1
        original.call
      end
      yield
      count
    end

    it "raises naming the argv, the status and both streams, without forking" do
      Dir.mktmpdir("lain-seed-git") do |dir|
        error = nil
        forks = forks_during do
          described_class.git(dir, "rev-parse", "--verify", "nope")
        rescue SeedRepo::GitFailed => e
          error = e
        end

        expect([forks,
                error.message]).to match([0,
                                          a_string_including("rev-parse --verify nope", "128", "STDERR:", "STDOUT:")])
      end
    end

    it "feeds input on stdin" do
      Dir.mktmpdir("lain-seed-git") do |dir|
        described_class.git(dir, "init", "-q")

        expect(described_class.git(dir, "hash-object", "--stdin", input: "x\n").stdout.strip).to match(/\A\h{40}\z/)
      end
    end
  end

  describe ".derived" do
    around do |example|
      Dir.mktmpdir("lain-seed-into") do |root|
        @root = root
        example.run
      end
    end

    def into(name) = File.join(@root, name)

    it "runs the build block once per key and copies into each caller's directory" do
      builds = 0
      build = lambda do |dir|
        builds += 1
        File.write(File.join(dir, "extra"), "built\n")
      end
      copies = %w[a b].map { |name| described_class.derived("seed-repo-spec-once", into: into(name), &build) }

      expect([builds, copies, copies.map { |d| File.read(File.join(d, "extra")) }])
        .to eq([1, [into("a"), into("b")], ["built\n"] * 2])
    end

    it "keeps a commit, a write and git status in one copy from reaching the next caller" do
      build = lambda do |dir|
        File.write(File.join(dir, "extra"), "x")
        described_class.git(dir, "add", "-A")
        described_class.git(dir, "commit", "-q", "-m", "extra")
      end
      first = described_class.derived("seed-repo-spec-indep", into: into("a"), &build)
      File.write(File.join(first, "extra"), "changed")
      described_class.git(first, "commit", "-q", "-a", "-m", "only here")
      second = described_class.derived("seed-repo-spec-indep", into: into("b")) { raise "built twice" }

      expect([File.read(File.join(second, "extra")), described_class.git(second, "status", "--porcelain").stdout,
              described_class.git(second, "log", "--format=%s").stdout]).to eq(["x", "", "extra\nseed\n"])
    end

    it "registers no exit hook for a copy: the caller's directory is the only owner" do
      described_class.derived("seed-repo-spec-hooks", into: into("warm")) { |d| File.write(File.join(d, "x"), "1") }
      allow(described_class).to receive(:at_exit)
      described_class.derived("seed-repo-spec-hooks", into: into("cold")) { raise "built twice" }

      expect(described_class).not_to have_received(:at_exit)
    end

    it "builds in a cold process where the plain seed was never requested" do
      script = <<~RUBY
        require "lain"
        require "./spec/support/seed_repo"
        Dir.mktmpdir do |d|
          puts File.exist?(File.join(SeedRepo.derived("cold", into: d) { |t| File.write(File.join(t, "x"), "1") }, "x"))
        end
      RUBY
      shell = Lain::Shell::Out.new(RbConfig.ruby, "-Ilib", "-e", script,
                                   environment: { "BUNDLE_GEMFILE" => ENV.fetch("BUNDLE_GEMFILE", nil) }).run_command

      expect([shell.exitstatus, shell.stdout.strip, shell.stderr]).to eq([0, "true", ""])
    end
  end

  describe ".with_layout" do
    it "copies the layout, committed on main, into the caller's directory, untouched by an earlier caller" do
      Dir.mktmpdir("lain-seed-layout-src") do |layout|
        Dir.mktmpdir("lain-seed-into") do |root|
          File.write(File.join(layout, "plan.md"), "plan\n")
          first = described_class.with_layout(layout, into: File.join(root, "a"))
          File.write(File.join(first, "plan.md"), "scribble")
          copy = described_class.with_layout(layout, into: File.join(root, "b"))

          expect([File.read(File.join(copy, "plan.md")),
                  described_class.git(copy, "branch", "--show-current").stdout.strip,
                  described_class.git(copy, "status", "--porcelain").stdout]).to eq(["plan\n", "main", ""])
        end
      end
    end
  end
end
