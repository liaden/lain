# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe "a note placed on a line holding a secret", :seam do
  RSpec::Matchers.define_negated_matcher :not_include, :include

  let(:secret) { "API_KEY=sk-live-0000000000000000\n" }
  let(:journal) { [] }

  around do |example|
    Dir.mktmpdir("lain-masked-note") do |root|
      @repo = File.join(File.realpath(root), "repo")
      FileUtils.cp_r(SeedRepo.at({ "README.md" => "seed\n" }), @repo)
      @base = git("rev-parse", "HEAD").strip
      git("checkout", "-q", "-b", "feature")
      File.write(File.join(@repo, "app.env"), secret)
      git("add", "-A")
      git("commit", "-q", "-m", "add the env file")
      example.run
    end
  end

  def git(*)
    shell = Mixlib::ShellOut.new("git", "-C", @repo, *, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout
  end

  def place_note(ledger: Lain::Sensitivity::Ledger.new)
    source = Lain::Review::Source::LocalBranch.new(base: @base, repo_root: @repo)
    source.projection = Lain::Survey::Projection.new(ledger:)
    changeset = Lain::Review::Changeset.new(source:)
    session = Lain::Review::Session.open(changeset:, journal:, source: "local_branch")
    anchor = changeset.anchor(path: "app.env", side: :new, line: 1)
    session.annotate(anchor, "rotate this", kind: :note, drifted: false)
  end

  it "journals the mask and never the value" do
    placed = place_note

    expect([placed.anchor_text, journal.map { |record| JSON.generate(record.to_h) }.join])
      .to match([include("<redacted:1>"), not_include("sk-live-")])
  end

  it "journals the released text once the region was released" do
    ledger = Lain::Sensitivity::Ledger.new
    ledger.release(File.join(@repo, "app.env"), Lain::Sensitivity::Regions.detect(secret))

    expect(place_note(ledger:).anchor_text).to eq("API_KEY=sk-live-0000000000000000")
  end
end
