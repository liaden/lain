# frozen_string_literal: true

RSpec.describe Lain::QA::ClaimCheck do
  def check(claims, changed) = described_class.new(claims:, changed:, range: "main..HEAD").findings

  it "finds nothing when the changeset is exactly what the cards claimed" do
    expect(check({ "T1" => %w[a.rb a_spec.rb] }, %w[a.rb a_spec.rb])).to be_empty
  end

  # The case that matters: a named spec file that never appeared means the
  # card's criteria were never turned into anything that can fail.
  it "holds on a claimed path the changeset never touched, naming the card and the missing file" do
    finding = check({ "T1" => %w[a.rb a_spec.rb] }, %w[a.rb]).first

    expect(finding).to have_attributes(severity: "major", criterion: "T1/Files", tier: "t0")
    expect(finding.summary).to eq("T1 claims a_spec.rb, and the changeset never touches it")
    expect(finding.reproduction).to eq("git diff --name-only main..HEAD -- a_spec.rb   # prints nothing")
    expect(finding).to be_holds
  end

  it "carries work no card claimed without holding on it" do
    finding = check({ "T1" => %w[a.rb] }, %w[a.rb .rubocop.yml]).first

    expect(finding).to have_attributes(severity: "minor", tier: "t0", summary: include(".rubocop.yml"))
    expect(finding).not_to be_holds
  end

  it "counts a path claimed by another card as claimed" do
    expect(check({ "T1" => %w[a.rb], "T2" => %w[shared.rb] }, %w[a.rb shared.rb])).to be_empty
  end

  it "reports unperformed claims ahead of unclaimed work" do
    expect(check({ "T1" => %w[a.rb] }, %w[b.rb]).map(&:severity)).to eq(%w[major minor])
  end

  it "quotes the range it was handed in every finding, so each one reproduces itself" do
    findings = check({ "T1" => %w[a.rb] }, %w[b.rb])

    expect(findings.map(&:reproduction)).to all(include("main..HEAD"))
    expect(findings.map(&:evidence)).to all(include("main..HEAD"))
  end

  it "holds nothing when a card claims nothing and the changeset is empty" do
    expect(check({ "T1" => [] }, [])).to be_empty
  end

  # A plan states template and generated paths as globs, so an exact match
  # would report work that was done as a card that never did it.
  describe "a claim is a pathspec, not a literal" do
    it "reads a glob claim as performed by any path it matches" do
      expect(check({ "T1" => ["lib/skill/*/skill.md"] }, ["lib/skill/qa/skill.md"])).to be_empty
    end

    it "does not let a glob's wildcard cross a directory boundary" do
      findings = check({ "T1" => ["lib/skill/*.md"] }, ["lib/skill/qa/skill.md"])

      expect(findings.map(&:severity)).to eq(%w[major minor])
    end

    # Every shape below is on a `**Files:**` line in this repo's own plans, and
    # each was a guaranteed false major finding the moment QA read that plan.
    it "reads the pathspec shapes a plan actually writes" do
      rows = { "lib/skill/*/skill.md" => "lib/skill/qa/skill.md",
               "lib/lain/handler/{live,mock}.rb" => "lib/lain/handler/live.rb",
               "spec/support/nulls/" => "spec/support/nulls/sink.rb",
               "lib/lain/algebra" => "lib/lain/algebra/order.rb",
               "lib/**" => "lib/deep/very/a.rb" }

      expect(rows.reject { |claim, path| check({ "T1" => [claim] }, [path]).empty? }).to eq({})
    end

    it "keeps a wildcard inside one directory unless the claim asks to recurse" do
      rows = { "lib/*.rb" => "lib/deep/a.rb",
               "lib/{a,b}.rb" => "lib/c.rb",
               "lib" => "library/a.rb",
               "libs/" => "lib/a.rb" }

      expect(rows.select { |claim, path| check({ "T1" => [claim] }, [path]).empty? }).to eq({})
    end

    it "carries a path no glob reaches as unclaimed" do
      expect(check({ "T1" => ["lib/skill/*/skill.md"] }, ["exe/lain"]).map(&:severity)).to eq(%w[major minor])
    end
  end

  # A reproduction a human is invited to paste is a shell command, so a path
  # with a space is two pathspecs and prints nothing whatever the truth is.
  describe "every command it quotes survives being pasted" do
    it "quotes a path holding a space as one pathspec" do
      finding = check({ "T1" => ["two words.rb"] }, []).first

      expect(finding.reproduction).to include("-- two\\ words.rb")
    end

    it "quotes a range holding shell metacharacters rather than letting them run" do
      finding = described_class.new(claims: { "T1" => ["a.rb"] }, changed: [],
                                    range: "$(rm -rf /)..HEAD").findings.first

      expect(finding.reproduction).to include("\\$\\(rm")
    end
  end

  # QA.words! scrubs, and the summary around a blank path stays non-blank, so
  # Finding's own refusal never fires: the opinion has to be refused here.
  describe "a claim that names no path is refused rather than filed" do
    it "refuses a claim that is not a string at all" do
      expect { check({ "T1" => [nil] }, []) }.to raise_error(Lain::QA::MalformedFinding, /must be a string/)
    end

    it "refuses a claim whose bytes scrub away to nothing" do
      expect { check({ "T1" => [(+"\xC3").force_encoding("UTF-8")] }, []) }
        .to raise_error(Lain::QA::MalformedFinding, /cannot be blank/)
    end

    it "refuses a changed path that names nothing, by the same rule" do
      expect { check({ "T1" => ["a.rb"] }, ["  "]) }.to raise_error(Lain::QA::MalformedFinding, /cannot be blank/)
    end

    it "refuses a range that says nothing, since every finding quotes it" do
      expect { described_class.new(claims: {}, changed: ["a.rb"], range: "") }
        .to raise_error(Lain::QA::MalformedFinding, /cannot be blank/)
    end
  end
end
