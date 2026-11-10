# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "../../../tools/test_map/git"
require_relative "../../../tools/test_map/bisect"

RSpec.describe TestMap::Bisect do
  def git(*args, input: nil)
    out, err, status = Open3.capture3(SeedRepo::SCRUB, "git", "-C", @repo, "-c", "user.name=t", "-c", "user.email=t@t",
                                      *args, stdin_data: input.to_s)
    raise err unless status.success?

    out
  end

  def commit(files, message)
    files.each { |name, text| File.write(File.join(@repo, name), text) }
    git("add", "-A")
    git("commit", "-q", "-m", message)
    git("rev-parse", "HEAD").strip
  end

  def staged_tree(files)
    index = File.join(@scratch, "staged-index")
    Open3.capture2(SeedRepo::SCRUB.merge("GIT_INDEX_FILE" => index), "git", "-C", @repo, "read-tree", "HEAD")
    files.each do |name, text|
      blob = git("hash-object", "-w", "--stdin", input: text).strip
      Open3.capture2(SeedRepo::SCRUB.merge("GIT_INDEX_FILE" => index), "git", "-C", @repo, "update-index", "--add",
                     "--cacheinfo", "100644,#{blob},#{name}")
    end
    Open3.capture2(SeedRepo::SCRUB.merge("GIT_INDEX_FILE" => index), "git", "-C", @repo, "write-tree").first.strip
  end

  def verdict_log
    File.read(Dir.glob(File.join(@repo, ".git", "lain", "test-map", "bisect-*.log")).first)
  end

  def step_runs = File.readlines(@runs_log, chomp: true)

  def bisect(good:, staged:, specs: ["state.txt"], notify: ->(_) {})
    head = git("rev-parse", "HEAD").strip
    described_class.new(repo: @repo, good:, head:, staged:, specs:, step: [@step], notify:)
  end

  around do |example|
    Dir.mktmpdir("bisect-spec") do |dir|
      @scratch = dir
      @repo = File.join(dir, "repo")
      FileUtils.mkdir_p(@repo)
      @runs_log = File.join(dir, "runs.log")
      @env_log = File.join(dir, "env.log")
      @step = File.join(dir, "step.sh")
      File.write(@step, <<~SH)
        #!/bin/sh
        echo "$(git rev-parse HEAD)" >> #{@runs_log}
        echo "$CARGO_TARGET_DIR|$BUNDLE_GEMFILE|$RUBYOPT|$RUBYLIB|$GIT_INDEX_FILE" >> #{@env_log}
        for f in "$@"; do
          [ -e "$f" ] || exit 3
          grep -q EXPLODE "$f" && exit 200
          grep -q SKIPME "$f" && exit 125
          grep -q FAIL "$f" && exit 1
        done
        exit 0
      SH
      File.chmod(0o755, @step)
      git("init", "-q", "-b", "main")
      example.run
    end
  end

  describe "#call" do
    it "names the first bad commit and removes the scratch worktree" do
      good = commit({ "state.txt" => "ok 0" }, "f")
      commits = [commit({ "state.txt" => "ok 1" }, "c1"), commit({ "state.txt" => "ok 2" }, "c2"),
                 commit({ "state.txt" => "FAIL 3" }, "c3"), commit({ "state.txt" => "FAIL 4" }, "c4"),
                 commit({ "state.txt" => "FAIL 5" }, "c5")]

      status = bisect(good:, staged: staged_tree("state.txt" => "FAIL 6")).call

      expect([status, verdict_log]).to match([0, include(commits[2])])
      expect(git("worktree", "list", "--porcelain")).not_to include("tmp/worktrees/bisect-")
    end

    it "blames the staged change when HEAD passes" do
      good = commit({ "state.txt" => "ok 0" }, "f")
      3.times { |i| commit({ "state.txt" => "ok #{i + 1}" }, "c#{i}") }

      bisect(good:, staged: staged_tree("state.txt" => "FAIL")).call

      expect([verdict_log, step_runs.size]).to match([a_string_matching(/staged change/), 2])
    end

    it "reports a flake when the staged tree passes" do
      good = commit({ "state.txt" => "ok 0" }, "f")
      commit({ "state.txt" => "FAIL 1" }, "c1")

      bisect(good:, staged: staged_tree("state.txt" => "ok 2")).call

      expect([verdict_log, step_runs.size]).to match([a_string_matching(/flake/), 1])
    end

    it "counts a failed spec file that does not exist yet as good" do
      good = commit({ "keep.txt" => "ok" }, "f")
      commits = [commit({ "keep.txt" => "1" }, "c1"), commit({ "keep.txt" => "2" }, "c2"),
                 commit({ "keep.txt" => "3" }, "c3"), commit({ "late.txt" => "FAIL" }, "c4"),
                 commit({ "keep.txt" => "5" }, "c5")]

      bisect(good:, staged: staged_tree("keep.txt" => "6"), specs: ["late.txt"]).call

      expect(verdict_log).to include(commits[3])
    end

    it "does nothing when a bisect for the same HEAD holds its lock" do
      good = commit({ "state.txt" => "ok 0" }, "f")
      commit({ "state.txt" => "FAIL 1" }, "c1")
      staged = staged_tree("state.txt" => "FAIL 2")
      first = bisect(good:, staged:)
      worktree = File.join(@repo, "tmp", "worktrees", "bisect-#{git("rev-parse", "--short", "HEAD").strip}")
      FileUtils.mkdir_p(worktree)
      File.write(File.join(worktree, "marker"), "first")

      FileUtils.mkdir_p(File.dirname(first.lock_path))
      status = Lain::FileLock.new(first.lock_path).hold { bisect(good:, staged:).call }

      expect([status, File.read(File.join(worktree, "marker")), File.exist?(@runs_log)]).to eq([0, "first", false])
    end

    it "says no bisect is possible without a good commit" do
      commit({ "state.txt" => "FAIL" }, "f")

      bisect(good: nil, staged: staged_tree("state.txt" => "FAIL 2")).call

      expect([verdict_log, File.exist?(@runs_log)]).to match([a_string_matching(/no bisect is possible/), false])
    end

    it "gives the step the shared cargo target directory" do
      good = commit({ "state.txt" => "ok 0" }, "f")
      commit({ "state.txt" => "FAIL 1" }, "c1")

      bisect(good:, staged: staged_tree("state.txt" => "FAIL 2")).call

      expect(File.readlines(@env_log).map { |line| line.split("|").first }.uniq)
        .to eq([File.join(@repo, "tmp", "test-map-bisect-target")])
    end

    it "keeps the caller's git, bundler and ruby context away from the step" do
      good = commit({ "state.txt" => "ok 0" }, "f")
      commit({ "state.txt" => "FAIL 1" }, "c1")
      leaks = { "GIT_INDEX_FILE" => "/nonexistent/index", "RUBYOPT" => "-W0", "RUBYLIB" => "/nonexistent",
                "BUNDLE_GEMFILE" => "/nonexistent/Gemfile" }
      saved = leaks.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      subject = bisect(good:, staged: staged_tree("state.txt" => "FAIL 2"))
      ENV.update(leaks)
      begin
        subject.call
      ensure
        ENV.update(saved)
      end

      seen = File.readlines(@env_log, chomp: true).map { |line| line.split("|", -1) }
      expect(seen.map { |_, gemfile, opt, lib, index| [gemfile.end_with?("/Gemfile"), opt, lib, index] }.uniq)
        .to eq([[true, "", "", ""]])
      expect(seen.map { |_, gemfile| gemfile }).to all(include("bisect-"))
    end

    it "writes a failed verdict and removes the worktree when git bisect run fails" do
      good = commit({ "state.txt" => "ok 0" }, "f")
      commit({ "state.txt" => "EXPLODE 1" }, "c1")
      notes = []

      status = bisect(good:, staged: staged_tree("state.txt" => "EXPLODE 2"), notify: notes.method(:push)).call

      expect([status, verdict_log, notes.size]).to match([1, a_string_matching(/bisect failed/), 1])
      expect(git("worktree", "list", "--porcelain")).not_to include("tmp/worktrees/bisect-")
    end

    it "fails the bisect when the step cannot run at the staged commit" do
      good = commit({ "state.txt" => "ok 0" }, "f")
      commit({ "state.txt" => "FAIL 1" }, "c1")

      status = bisect(good:, staged: staged_tree("state.txt" => "SKIPME")).call

      expect([status, verdict_log, step_runs.size]).to match([1, a_string_matching(/bisect failed/), 1])
    end

    it "treats a step killed by a signal as a skip" do
      env = { described_class::STEP_VARIABLE => JSON.generate(["sh", "-c", "kill -9 $$"]) }

      expect(described_class.run_step([__FILE__], env:)).to eq(125)
    end

    it "boots under plain ruby with no bundler or ruby environment" do
      File.write(File.join(@repo, "state.txt"), "ok")
      env = { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil,
              described_class::STEP_VARIABLE => JSON.generate([@step]) }

      _, _, status = Open3.capture3(env, RbConfig.ruby, File.expand_path("../../../tools/test_map/bisect.rb", __dir__),
                                    "--step", "state.txt", chdir: @repo)

      expect(status.exitstatus).to eq(0)
    end
  end

  describe ".for" do
    it "rejects a missing --head with a usage error" do
      expect { described_class.for(%w[--staged abc --specs a.rb], repo: @repo) }.to raise_error(ArgumentError, /usage/)
    end

    it "rejects a stray word" do
      expect { described_class.for(%w[--head a --staged b stray], repo: @repo) }.to raise_error(ArgumentError, /usage/)
    end
  end

  describe ".suite_lock_path" do
    it "is the file Lain's suite lock holds for the same state home" do
      Dir.mktmpdir do |state|
        env = { "XDG_STATE_HOME" => state, "HOME" => state }
        lock = Lain::Isolation::SuiteLock.for(paths: Lain::Paths.new(env:))

        taken = nil
        lock.try do
          File.open(described_class.suite_lock_path(env), File::RDWR | File::CREAT) do |file|
            taken = file.flock(File::LOCK_EX | File::LOCK_NB)
          end
        end

        expect(taken).to be(false)
      end
    end
  end
end
