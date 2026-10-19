# frozen_string_literal: true

require "tmpdir"

# Whether an issue branch holds only the failing-test commit, read off a real
# repository: the answer is the commit subjects past the epic branch's base.
RSpec.describe Lain::Epic::RedCommit do
  let(:dir) { Dir.mktmpdir("red-commit") }
  let(:checkout) { Lain::Isolation::Checkout.new(dir) }
  let(:red) { described_class.subject("spec/a_spec.rb", "abc123") }

  after { FileUtils.remove_entry(dir) }

  def git(*args) = checkout.run(*args, pins: ["user.name=t", "user.email=t@example.com", "commit.gpgsign=false"])

  def commit(subject)
    File.write(File.join(dir, "#{subject.hash.abs}.txt"), subject)
    git("add", "-A")
    git("commit", "--no-verify", "-q", "-m", subject)
    git("rev-parse", "HEAD").stdout.strip
  end

  def base_sha
    git("init", "-q", "-b", "epic/demo")
    commit("chore: seed")
  end

  def only?(sha) = described_class.new(git: checkout, base: "epic/demo").only?(sha)

  it "writes the subject the red step commits under" do
    expect(red).to eq("test: failing tests at spec/a_spec.rb, from criteria abc123")
  end

  it "is true for a branch whose one commit has the red subject" do
    base_sha
    git("checkout", "-q", "-b", "issue/a")

    expect(only?(commit(red))).to be(true)
  end

  it "is false for the epic branch's own tip" do
    expect(only?(base_sha)).to be(false)
  end

  it "is false for an ancestor of the epic branch" do
    first = base_sha
    commit("chore: more")

    expect(only?(first)).to be(false)
  end

  it "is false when an implementation commit sits on top" do
    base_sha
    git("checkout", "-q", "-b", "issue/a")
    commit(red)

    expect(only?(commit("feat: greet"))).to be(false)
  end

  it "is false when a non-red commit sits below a red one" do
    base_sha
    git("checkout", "-q", "-b", "issue/a")
    commit("feat: greet")

    expect(only?(commit(red))).to be(false)
  end

  it "is true for two stacked red commits" do
    base_sha
    git("checkout", "-q", "-b", "issue/a")
    commit(red)

    expect(only?(commit(described_class.subject("spec/b_spec.rb", "def456")))).to be(true)
  end

  it "is false for a sha git does not know" do
    base_sha

    expect(only?("0" * 40)).to be(false)
  end
end
