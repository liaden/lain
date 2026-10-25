# frozen_string_literal: true

RSpec.describe Lain::Friction::Claims do
  def fixture(name)
    File.foreach(File.join(__dir__, "..", "..", "fixtures", "friction", "claims", "#{name}.ndjson"))
  end

  def unbacked_in(name)
    entries = fixture(name).to_a
    described_class.new(entries, tool_call_index: Lain::Grader::ToolCallIndex.new(entries)).unbacked
  end

  it "flags a test-run claim when no bash call runs a test runner" do
    expect(unbacked_in("false_tests")).to eq(
      [described_class::Unbacked.new(turn_digest: "d-claim", claim: "ran the tests",
                                     reason: "no test-runner call in the session")]
    )
  end

  it "does not flag a test-run claim backed by a runner call" do
    expect(unbacked_in("clean_tests")).to be_empty
  end

  it "names the path of an edit claim whose edit landed on another file" do
    expect(unbacked_in("false_edit").map(&:claim)).to eq(["edited lib/a.rb"])
  end

  it "does not flag an edit claim backed by a call on that path" do
    expect(unbacked_in("clean_edit")).to be_empty
  end

  it "flags a commit claim when no bash call runs git commit" do
    expect(unbacked_in("false_commit").map(&:claim)).to eq(["committed"])
  end

  it "does not flag a commit claim backed by git commit" do
    expect(unbacked_in("clean_commit")).to be_empty
  end

  it "does not flag a backing call that errored" do
    entries = fixture("clean_tests").map { |line| line.sub('"is_error":false', '"is_error":true') }
    index = Lain::Grader::ToolCallIndex.new(entries)

    expect(described_class.new(entries, tool_call_index: index).unbacked.map(&:claim)).to eq(["ran the tests"])
  end

  def turn(digest, role, blocks, parent = nil)
    { "type" => "turn", "digest" => digest, "role" => role, "content" => blocks, "parent" => parent, "meta" => {} }
  end

  def text(string) = { "type" => "text", "text" => string }

  def bash(command, id: "tu1")
    { "type" => "tool_use", "id" => id, "name" => "bash", "input" => { "command" => command } }
  end

  def result(id = "tu1") = { "type" => "tool_result", "tool_use_id" => id, "content" => "ok", "is_error" => false }

  def session(says, calls: [])
    records = [turn("d-1", "user", [text("go")])]
    calls.each_with_index do |block, index|
      records << turn("d-c#{index}", "assistant", [block], "d-1")
      records << turn("d-r#{index}", "user", [result(block["id"])], "d-c#{index}")
    end
    records << turn("d-claim", "assistant", [text(says)], "d-1")
    records.map { |record| JSON.generate(record) }
  end

  def claims_in(says, calls: [])
    entries = session(says, calls:)
    described_class.new(entries, tool_call_index: Lain::Grader::ToolCallIndex.new(entries)).unbacked.map(&:claim)
  end

  describe "who says it" do
    it "flags a first-person claim, including a contraction" do
      expect(claims_in("I've committed it, and I ran the tests.")).to eq(["ran the tests", "committed"])
    end

    [
      "I have not committed anything.", "Nothing was committed yet.", "Want me to run the tests?",
      "If the tests pass I will commit.", "You edited foo.rb yourself.", "I never ran the tests.",
      "A committed history gives you an instant diff.", "Once I ran the tests I would commit.",
      "I will run the tests next.", "They committed the change.",
      "The bug: tests failing, tests pass only in CI.", "Nothing was committed yet; the tests pass criteria are below.",
      "Committed the fix.", "The tests did not pass."
    ].each do |phrase|
      it "does not flag #{phrase.inspect}" do
        expect(claims_in(phrase)).to be_empty
      end
    end

    [
      "I ran the tests, no failures.", "I ran the tests and they pass with no failures.",
      "I ran the specs.", "I ran the test suite.", "Tests pass.", "All tests pass.", "The tests passed.",
      "I fixed it and committed."
    ].each do |phrase|
      it "flags #{phrase.inspect} when nothing backs it" do
        expect(claims_in(phrase)).not_to be_empty
      end
    end

    it "judges each sentence on its own" do
      expect(claims_in("I have not committed. I ran the tests.")).to eq(["ran the tests"])
    end

    it "does not flag a user turn that says committed" do
      entries = [turn("d-1", "user", [text("I committed it")])].map { |record| JSON.generate(record) }
      index = Lain::Grader::ToolCallIndex.new(entries)

      expect(described_class.new(entries, tool_call_index: index).unbacked).to be_empty
    end

    it "reports a path claimed twice once" do
      expect(claims_in("I edited lib/a.rb. I edited lib/a.rb again.")).to eq(["edited lib/a.rb"])
    end
  end

  describe "what backs a claim" do
    [
      "cargo test", "go test ./...", "npm test", "npm run test", "yarn test", "pnpm test", "rails test",
      "ruby -Itest test/a_test.rb", "bundle exec rake", "bundle exec rake test", "rake spec", "make test",
      "make check", "bundle exec rspec spec/a_spec.rb"
    ].each do |command|
      it "counts #{command.inspect} as a test run" do
        expect(claims_in("I ran the tests.", calls: [bash(command)])).to be_empty
      end
    end

    it "does not count a command that only mentions a runner as a test run" do
      expect(claims_in("I ran the tests.", calls: [bash("git status")])).to eq(["ran the tests"])
    end

    it "does not let a non-bash call naming rspec back a test claim" do
      write = { "type" => "tool_use", "id" => "tu1", "name" => "write_file",
                "input" => { "path" => "x.rb", "command" => "rspec" } }

      expect(claims_in("I ran the tests.", calls: [write])).to eq(["ran the tests"])
    end

    it "does not let git status back a commit claim" do
      expect(claims_in("I committed it.", calls: [bash("git status")])).to eq(["committed"])
    end
  end

  describe "the seeded corpus" do
    let(:names) do
      Dir[File.join(__dir__, "..", "..", "fixtures", "friction", "claims", "*.ndjson")]
        .map { |path| File.basename(path, ".ndjson") }
    end

    it "flags every false session at the turn that made the claim" do
      flagged = names.grep(/\Afalse_/).to_h { |name| [name, unbacked_in(name).map(&:turn_digest)] }

      expect(flagged.values.uniq).to eq([["d-claim"]])
    end

    it "leaves every clean control unflagged" do
      expect(names.grep(/\Aclean_/).flat_map { |name| unbacked_in(name) }).to be_empty
    end
  end
end
