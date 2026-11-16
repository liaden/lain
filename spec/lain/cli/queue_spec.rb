# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Lain::CLI::Queue, :seam do
  let(:old) { { "GIT_AUTHOR_DATE" => "2020-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2020-01-01T00:00:00Z" } }

  around do |example|
    Dir.mktmpdir("lain-cli-queue") do |dir|
      @repo = File.realpath(dir)
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", @repo)
      Dir.mktmpdir("lain-cli-queue-state") do |state|
        with_env("XDG_STATE_HOME" => state) { example.run }
      end
    end
  end

  def git(*, env: {}) = SeedRepo.git(@repo, *, env:).stdout.strip

  def commit(name, body = "#{name}\n")
    File.write(File.join(@repo, name), body)
    git("add", name)
    git("commit", "-q", "-m", name, env: old)
    git("rev-parse", "HEAD")
  end

  def capture(*argv, dir: @repo)
    out = err = nil
    Dir.chdir(dir) do
      out = StringIO.new
      err = StringIO.new
      saved = [$stdout, $stderr]
      $stdout = out
      $stderr = err
      begin
        described_class.start(argv, debug: true)
      ensure
        $stdout, $stderr = saved
      end
    end
    [out.string, err.string]
  end

  def finished_plan(title: "Ship it", name: "run")
    base = git("rev-parse", "HEAD")
    head = commit("work.txt")
    plan = ["# #{title}", "", "status: done", "base: #{base}", "head: #{head}", ""].join("\n")
    FileUtils.mkdir_p(File.join(@repo, "planning"))
    commit("planning/#{name}.md", plan)
    [base, head]
  end

  def unmerged_branch(name)
    git("checkout", "-q", "-b", name)
    commit("#{name}.txt")
    git("checkout", "-q", "-")
  end

  describe "here" do
    it "prints the plan run, then the unmerged branch, one tab-separated line each" do
      base, head = finished_plan
      unmerged_branch("feature")

      out, = capture("here")

      trunk = git("symbolic-ref", "--short", "HEAD")
      expect(out.lines(chomp: true).map { |line| line.split("\t") }).to eq(
        [["plan:planning/run.md", "plan done: Ship it", "#{base[0, 8]}..#{head[0, 8]}"],
         ["branch:#{@repo}:feature", "unmerged branch feature", "feature against #{trunk}"]]
      )
    end

    it "strips tabs and escape sequences from a plan's title" do
      finished_plan(title: "Red\e[31m\tTitle\e]0;owned\a done")

      out, = capture("here")

      expect(out.lines.size).to eq(1)
      expect(out).to include("plan done: Red Title done")
      expect(out).not_to match(/[\e\a]/)
      expect(out.lines.first.count("\t")).to eq(2)
    end

    it "prints one JSON object per row with --json" do
      finished_plan
      unmerged_branch("feature")

      out, = capture("here", "--json")
      rows = out.lines.map { |line| JSON.parse(line) }

      expect(rows.map { |row| row["id"] }).to eq(["plan:planning/run.md", "branch:#{@repo}:feature"])
      expect(rows.first).to include("rank" => "plan_run", "reason" => "plan done: Ship it")
    end

    it "refuses an unknown switch" do
      expect { capture("here", "--nope") }.to raise_error(Thor::UnknownArgumentError, /--nope/)
    end
  end

  describe "here, beyond the rows" do
    it "puts a refused row's note on stderr and keeps it off stdout" do
      base = git("rev-parse", "HEAD")
      FileUtils.mkdir_p(File.join(@repo, "planning"))
      commit("planning/bad.md", "# Bad\n\nstatus: done\nbase: nope\nhead: #{base}\n")

      out, err = capture("here")

      expect(err).to match(%r{skipped plan:planning/bad.md})
      expect(out).not_to include("skipped")
    end

    it "hides a row whose head was opened, while show still finds it" do
      _, head = finished_plan
      log = Lain::Review::Queue::Log.new(paths: Lain::Paths.new)
      log.append(Lain::Review::Queue::Log::Event.new(kind: :opened, at: nil, row_id: "plan:planning/run.md",
                                                     head_sha: head))

      expect(capture("here").first).to eq("")
      expect(capture("show", "plan:planning/run.md").first).to include("reason: plan done: Ship it")
    end

    it "shows a row by the id `here` printed, even when the path holds 2 spaces" do
      finished_plan(name: "a  b")

      printed = capture("here").first.split("\t").first

      expect(capture("show", printed).first).to include("reason: plan done: Ship it")
    end
  end

  describe "local" do
    it "lists the local changes without the plan runs" do
      finished_plan
      unmerged_branch("feature")

      out, = capture("local")

      expect(out.lines.map { |line| line.split("\t").first }).to eq(["branch:#{@repo}:feature"])
    end
  end

  describe "prs and show on a PR" do
    let(:bin) { File.join(@repo, "..", "queue-bin-#{Process.pid}") }
    let(:title) { "Fix\tthe\nthing\e[31m red\e]0;owned\a" }
    let(:answer) do
      node = {
        "number" => 12, "title" => title, "url" => "https://github.com/acme/api/pull/12", "isDraft" => false,
        "headRefOid" => "a" * 40, "author" => { "login" => "ali\e[31mce\e]0;x\a" },
        "repository" => { "nameWithOwner" => "acme/api" },
        "files" => { "nodes" => [{ "path" => "lib/a.rb" }], "totalCount" => 1 },
        "timelineItems" => { "nodes" => [{ "createdAt" => "2026-11-11T10:30:00Z",
                                           "requestedReviewer" => { "login" => "me" } }] },
        "reviewRequests" => { "nodes" => [{ "asCodeOwner" => false,
                                            "requestedReviewer" => { "__typename" => "User", "login" => "me" } }] },
        "latestReviews" => { "nodes" => [] }
      }
      { "data" => { "viewer" => { "login" => "me", "organizations" => { "nodes" => [] } },
                    "search" => { "issueCount" => 1, "nodes" => [node] } } }
    end

    around do |example|
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "answer.json"), JSON.generate(answer))
      File.write(File.join(bin, "gh"), "#!/bin/sh\nexec cat #{File.join(bin, "answer.json")}\n")
      File.chmod(0o755, File.join(bin, "gh"))
      saved = ENV.fetch("PATH")
      ENV["PATH"] = "#{bin}:#{saved}"
      example.run
    ensure
      ENV["PATH"] = saved
      FileUtils.remove_entry(bin)
    end

    it "prints a PR as one line whose title holds no control character" do
      out, = capture("prs")

      expect(out.lines.size).to eq(1)
      fields = out.chomp.split("\t")
      expect(fields.first).to eq("pr:acme/api#12")
      expect(fields.last).to eq("Fix the thing red")
      expect(out).not_to match(/[\e\a]/)
    end

    it "prints one JSON object per PR with --json" do
      out, = capture("prs", "--json")

      expect(out.lines.map { |line| JSON.parse(line) })
        .to match([include("id" => "pr:acme/api#12", "reason" => "direct, no local checkout")])
    end

    it "shows the reason, the pull request, its title, author and requested time" do
      out, = capture("show", "pr:acme/api#12")

      expect(out).to include("reason: direct, no local checkout", "range: https://github.com/acme/api/pull/12",
                             "title: Fix the thing red", "author: ali", "requested: 2026-11-11T10:30:00Z")
      expect(out).not_to match(/[\e\a]/)
    end
  end

  describe "show on a local row" do
    it "prints the reason and the range" do
      base, head = finished_plan

      out, = capture("show", "plan:planning/run.md")

      expect(out.lines(chomp: true)).to eq(["id: plan:planning/run.md", "reason: plan done: Ship it",
                                            "range: #{base}..#{head}"])
    end

    it "names a row no source lists" do
      expect { capture("show", "plan:nope.md") }.to raise_error(Thor::Error, /no queue row plan:nope.md/)
    end
  end
end
