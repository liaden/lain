# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe "a note placed on a line holding a secret", :seam do
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

  def git(*) = SeedRepo.git(@repo, *).stdout

  def place_note(ledger: Lain::Sensitivity::Ledger.new, secrets: Lain::Sensitivity::Secrets::Source::DEFAULT,
                 path: "app.env")
    source = Lain::Review::Source::LocalBranch.new(base: @base, repo_root: @repo)
    source.projection = Lain::Survey::Projection.new(ledger:, secrets:)
    changeset = Lain::Review::Changeset.new(source:)
    session = Lain::Review::Session.open(changeset:, journal:, source: "local_branch")
    anchor = changeset.anchor(path:, side: :new, line: 1)
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

  it "journals a placeholder for a lent value no detector reports" do
    File.write(File.join(@repo, "notes.txt"), "the word is plainwordvalue today\n")
    git("add", "-A")
    git("commit", "-q", "-m", "add notes")
    lent = ["plainwordvalue"]

    placed = place_note(secrets: lent, path: "notes.txt")

    expect([placed.anchor_text, journal.map { |record| JSON.generate(record.to_h) }.join])
      .to match([include("<redacted:1>"), not_include("plainwordvalue")])
  end

  it "carries the same lent value from the target to the source it resolves" do
    lent = ["plainwordvalue"]
    target = Lain::Review::Target.new(repo_root: @repo, shell_out_factory: Lain::Shell::Out.public_method(:new),
                                      account: Lain::Forge::Gh::Account::None.new, secrets: lent)
    File.write(File.join(@repo, "notes.txt"), "the word is plainwordvalue today\n")
    git("add", "-A")
    git("commit", "-q", "-m", "add notes")

    source = target.resolve("feature", base: @base).source

    expect(source.projection.line(File.join(@repo, "notes.txt"), "the word is plainwordvalue today\n", 1,
                                  verdict: Lain::Survey::Projection::UNJUDGED)).to eq("the word is <redacted:1> today")
  end
end
