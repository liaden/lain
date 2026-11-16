# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

RSpec.describe Lain::Review::Target, :seam do
  let(:pull_request) { 12 }
  let(:ledger) { Lain::Sensitivity::Ledger.new }
  let(:targets) { described_class.new(repo_root: @repo, shell_out_factory: factory, ledger:, account: none) }
  let(:none) { Lain::Forge::Gh::Account::None.new }

  around do |example|
    Dir.mktmpdir("lain-review-target") do |dir|
      @repo = File.join(File.realpath(dir), "repo")
      FileUtils.cp_r(SeedRepo.at("a.rb" => "a\nb\nc\n"), @repo)
      git("branch", "-M", "main")
      example.run
    end
  end

  def git(*) = SeedRepo.git(@repo, *)

  def commit(message, files)
    files.each { |path, body| File.write(File.join(@repo, path), body) }
    git("add", "-A")
    git("commit", "-q", "-m", message)
    git("rev-parse", "HEAD").stdout.strip
  end

  def answered(stdout)
    Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }.new(stdout:, stderr: "", exitstatus: 0)
  end

  def view_document(head)
    { "baseRefName" => "main", "baseRefOid" => git("rev-parse", "main").stdout.strip, "headRefOid" => head }
  end

  def factory
    lambda do |*argv, **options|
      return Lain::Shell::Out.new(*argv, **options) unless argv.first == "gh"

      raise "unarranged gh call #{argv.inspect}" unless argv[1..2] == %w[pr view]

      answered(JSON.generate(view_document(git("rev-parse", "feature").stdout.strip)))
    end
  end

  def feature_branch(files = { "a.rb" => "a\nCHANGED\nc\n" })
    git("checkout", "-q", "-b", "feature")
    head = commit("touch a", files)
    git("update-ref", "refs/pull/#{pull_request}/head", head)
    head
  end

  it "refuses to be built without an account, so no gh read runs as whichever token is lying about" do
    expect { described_class.new(repo_root: @repo, shell_out_factory: factory, ledger:) }
      .to raise_error(ArgumentError, /account/)
  end

  describe "a pull request under a configured account" do
    let(:account) { instance_double(Lain::Forge::Gh::Account, environment: { "GH_TOKEN" => "t0k" }) }
    let(:environments) { [] }
    let(:targets) { described_class.new(repo_root: @repo, shell_out_factory: recording, ledger:, account:) }
    let(:recording) do
      lambda do |*argv, **options|
        environments << options[:environment] if argv.first == "gh"
        factory.call(*argv, **options)
      end
    end

    before { feature_branch }

    it "runs the gh read with the account's token" do
      targets.resolve(pull_request.to_s)

      expect(environments).to eq([{ "GH_TOKEN" => "t0k" }])
    end
  end

  describe "#resolve" do
    before { feature_branch }

    it "resolves a branch to a local branch source with no number" do
      resolved = targets.resolve("feature")

      expect(resolved.source).to be_a(Lain::Review::Source::LocalBranch)
      expect(resolved.label).to eq("branch feature")
      expect(resolved.number).to be_nil
    end

    it "resolves a pull request spelling to a pull request source carrying its number" do
      resolved = targets.resolve("##{pull_request}")

      expect(resolved.source).to be_a(Lain::Review::Source::GithubPr)
      expect(resolved.label).to eq("pull request #{pull_request}")
      expect(resolved.number).to eq(pull_request)
    end

    it "reads the number out of a URL spelling too" do
      expect(targets.resolve("https://github.com/owner/repo/pull/#{pull_request}").number).to eq(pull_request)
    end

    it "names the source the round is journaled under after its class" do
      expect(targets.resolve("feature").name).to eq("local_branch")
    end

    it "refuses a bare number that also names a branch" do
      git("branch", pull_request.to_s, "feature")

      expect { targets.resolve(pull_request.to_s) }
        .to raise_error(described_class::Ambiguous, %r{refs/heads/#{pull_request}.*/pull/#{pull_request}}m)
    end

    it "refuses --base against a pull request" do
      expect { targets.resolve(pull_request.to_s, base: "main") }
        .to raise_error(Lain::Error, /--base cannot override the base of pull request/)
    end

    it "asks for a base when the repository has no default one" do
      git("branch", "-m", "main", "trunk")

      expect { targets.resolve("feature") }.to raise_error(Lain::Error, /name one with --base <ref>/)
    end
  end

  describe "a commit range" do
    it "diffs base..head when the target is the head and a base is named" do
      first = commit("first", "b.rb" => "one\n")
      second = commit("second", "b.rb" => "two\n")

      changeset = Lain::Review::Changeset.new(source: targets.resolve(second, base: first).source)

      expect([changeset.base_ref, changeset.head_ref]).to eq([first, second])
    end
  end

  describe "the region ledger a resolved target reads its evidence through" do
    let(:secret_line) { "API_KEY=sk-live-0000000000000000" }

    before { feature_branch("app.env" => "#{secret_line}\n") }

    def evidence
      source = targets.resolve("feature").source
      Lain::Review::Changeset.new(source:).anchor(path: "app.env", side: :new, line: 1).anchor_text
    end

    it "masks the line while nothing is released" do
      expect(evidence).to eq("API_KEY=<redacted:1>")
    end

    it "journals the released text once the ledger holds the release" do
      ledger.release(File.join(File.realpath(@repo), "app.env"), Lain::Sensitivity::Regions.detect("#{secret_line}\n"))

      expect(evidence).to eq(secret_line)
    end
  end

  it "carries the headline the review commands format" do
    expect(described_class::HEADLINE).to eq("reviewing %<label>s at %<scope>s scope: %<base>s..%<head>s")
  end
end
