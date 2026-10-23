# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Isolation::MergeCoordinator::LandedFlags, :seam do
  around do |example|
    Dir.mktmpdir("lain-landed-flags") do |repo|
      @repo = File.realpath(repo)
      FileUtils.cp_r("#{SeedRepo.at({ "a.rb" => "a\n" })}/.", @repo)
      example.run
    end
  end

  let(:flags) { described_class.new(git: Lain::Isolation::Checkout.new(@repo)) }

  def git(*) = SeedRepo.git(@repo, *).stdout.strip

  def commit(files = {}, links: {})
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
      File.write(File.join(@repo, path), body)
    end
    links.each do |path, target|
      FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
      File.symlink(target, File.join(@repo, path))
    end
    git("add", "-A")
    git("commit", "-q", "-m", "change")
    git("rev-parse", "HEAD")
  end

  def report(base, sha, kind: :merged)
    Lain::Isolation::WorkerHandoff::Report.new(kind:, sha:, base:)
  end

  def landing(files = {}, links: {}) = git("rev-parse", "HEAD").then { |base| report(base, commit(files, links:)) }

  it "names a CI config file as ci_config" do
    expect(flags.for(landing({ ".github/workflows/main.yml" => "on: push\n" })))
      .to eq(["ci_config .github/workflows/main.yml"])
  end

  it "sorts the flags of a change spanning classes" do
    changed = { ".pre-commit-config.yaml" => "x\n", ".husky/pre-push" => "x\n", "CLAUDE.md" => "x\n",
                ".lain/config.rb" => "x\n", "Gemfile" => "x\n", "sub/Cargo.toml" => "x\n", ".envrc" => "x\n" }

    expect(flags.for(landing(changed))).to eq(
      ["agent_config .envrc", "agent_config .lain/config.rb", "agent_config CLAUDE.md", "build_input Gemfile",
       "build_input sub/Cargo.toml", "ci_config .pre-commit-config.yaml", "hooks .husky/pre-push"]
    )
  end

  it "names a path under the configured core.hooksPath as hooks" do
    git("config", "core.hooksPath", "tools/hooks")

    expect(flags.for(landing({ "tools/hooks/pre-commit" => "x\n" }))).to eq(["hooks tools/hooks/pre-commit"])
  end

  it "names a symlink the change added" do
    expect(flags.for(landing({}, links: { "docs/link" => "../secrets" }))).to eq(["symlink docs/link"])
  end

  it "names nothing for an ordinary change" do
    expect(flags.for(landing({ "lib/a.rb" => "b\n" }))).to eq([])
  end

  it "names nothing for a resolved report, which carries no base" do
    sha = commit({ ".github/x.yml" => "x\n" })

    expect(flags.for(report(nil, sha, kind: :resolved))).to eq([])
  end

  it "names nothing for a report that landed onto no base" do
    sha = commit({ ".github/x.yml" => "x\n" })

    expect(flags.for(report(nil, sha, kind: :declined))).to eq([])
  end

  it "does not flag the second of two workers landed in one run for the first one's files" do
    start = git("rev-parse", "HEAD")
    first = commit({ ".github/workflows/main.yml" => "x\n" })
    second = commit({ "lib/a.rb" => "b\n" })

    expect([flags.for(report(start, first)), flags.for(report(first, second))])
      .to eq([["ci_config .github/workflows/main.yml"], []])
  end

  it "answers nothing for every report when it is NONE" do
    expect(described_class::NONE.for(landing({ ".github/x.yml" => "x\n" }))).to eq([])
  end
end
