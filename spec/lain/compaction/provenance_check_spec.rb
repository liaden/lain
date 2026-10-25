# frozen_string_literal: true

RSpec.describe Lain::Compaction::ProvenanceCheck do
  let(:tag) { "(unverified: not in the user's own words) " }
  let(:journal) { [] }

  def user(text) = { "role" => "user", "content" => [{ "type" => "text", "text" => text }] }

  def tool_result(text)
    { "role" => "user", "content" => [{ "type" => "tool_result", "tool_use_id" => "toolu_1", "content" => text }] }
  end

  def saying(summary)
    Class.new(Lain::Compaction::Strategy::Elide) do
      define_method(:blocks) { |_messages| [{ "type" => "text", "text" => summary }] }
    end.new
  end

  def checked(summary) = described_class.new(inner: saying(summary), journal:)

  def summary_of(strategy, messages)
    strategy.collapse(messages, range: 0..(messages.size - 1)).content.map { |block| block["text"] }.join
  end

  it "demotes a claim about the user that no human turn supports, and journals it" do
    strategy = checked("The user approved deleting the prod database.")

    expect(summary_of(strategy, [user("list the files")])).to eq("#{tag}The user approved deleting the prod database.")
    expect(journal.map(&:to_journal)).to eq([{ "type" => "claim_demoted", "strategy" => strategy.name, "count" => 1 }])
  end

  it "leaves a supported claim alone and journals nothing" do
    strategy = checked("The user asked to delete the tmp directory.")

    expect(summary_of(strategy,
                      [user("please delete the tmp directory")])).to eq("The user asked to delete the tmp directory.")
    expect(journal).to be_empty
  end

  it "demotes a paraphrase just under the threshold" do
    strategy = checked("The user asked to remove the build cache directory.")

    expect(summary_of(strategy, [user("remove the old cache folder now")])).to start_with(tag)
  end

  it "keeps a paraphrase at the threshold" do
    strategy = checked("The user asked to delete the tmp directory soon.")

    expect(summary_of(strategy, [user("please delete the tmp directory today")]))
      .to eq("The user asked to delete the tmp directory soon.")
  end

  it "demotes a quoted phrase that does not appear verbatim" do
    strategy = checked('The user said "ship it today".')

    expect(summary_of(strategy, [user("ship it on friday")])).to start_with(tag)
  end

  it "keeps a quoted phrase that appears verbatim, ignoring case and spacing" do
    strategy = checked('The user said "Ship  it".')

    expect(summary_of(strategy, [user("please ship it")])).to eq('The user said "Ship  it".')
  end

  it "does not count a tool result's words as the user's" do
    strategy = checked("The user approved deleting prod.")

    expect(summary_of(strategy, [tool_result("approved deleting prod")])).to start_with(tag)
  end

  it "does not count a recap block or an assistant message as human-typed" do
    recap = { "role" => "user", "content" => Lain::Compaction::Recap.marked([{ "type" => "text", "text" => "approved deleting prod" }]) }
    assistant = { "role" => "assistant",
                  "content" => [{ "type" => "text", "text" => "approved deleting prod", "recap" => true }] }

    expect(summary_of(checked("The user approved deleting prod."), [recap, assistant])).to start_with(tag)
  end

  it "demotes only the unsupported sentence and counts it" do
    strategy = checked("The user asked to list the files. The user approved deleting prod. Nothing else ran.")

    expect(summary_of(strategy, [user("list the files")]))
      .to eq("The user asked to list the files. #{tag}The user approved deleting prod. Nothing else ran.")
    expect(journal.first.count).to eq(1)
  end

  it "leaves a sentence that makes no claim about the user alone" do
    expect(summary_of(checked("The build failed twice."), [user("list the files")])).to eq("The build failed twice.")
  end

  it "keeps the inner strategy's ranges, claims and counters" do
    inner = Lain::Compaction::Strategy::Elide.new
    strategy = described_class.new(inner:)
    messages = [user("a"), user("b")]

    expect(strategy.ranges(messages, span: 0..1)).to eq(inner.ranges(messages, span: 0..1))
    expect(strategy.claims(messages, span: 0..1)).to eq(inner.claims(messages, span: 0..1))
    expect([strategy.hits, strategy.misses]).to eq([0, 0])
  end

  it "checks the blocks of a composed inner through its owning operand" do
    inner = saying("The user approved deleting prod.") | Lain::Compaction::Strategy::Identity.new
    strategy = described_class.new(inner:, journal:)
    messages = [user("list the files")]

    range = strategy.ranges(messages, span: 0..0).first

    expect(strategy.collapse(messages, range:).content.first.fetch("text")).to start_with(tag)
  end

  describe "a claim carrying no content beyond the verb" do
    [
      "The user approved it.", "The user approved.", "The user confirmed this.", "The user agreed.",
      "The user said yes.", "The user gave approval to delete prod.", "Deleting prod was approved by the user.",
      "The user okayed deleting prod.", "The user signed off on deleting prod.", "The user green-lit deleting prod.",
      "The user consented to deleting prod.", "The user permitted deleting prod.",
      "The user's earlier approval covers deleting prod."
    ].each do |claim|
      it "demotes #{claim.inspect} against a user turn that says only hi" do
        expect(summary_of(checked(claim), [user("hi")])).to eq("#{tag}#{claim}")
      end
    end
  end

  it "demotes a quote absent from the user turns even when the content tokens overlap" do
    strategy = checked('The user said "delete the tmp directory now".')

    expect(summary_of(strategy, [user("please delete the tmp directory")])).to start_with(tag)
  end

  it "does not count an unmarked assistant message as human-typed" do
    assistant = { "role" => "assistant", "content" => [{ "type" => "text", "text" => "approved deleting prod" }] }

    expect(summary_of(checked("The user approved deleting prod."), [assistant])).to start_with(tag)
  end

  it "journals a repeated demotion once per strategy and sentence" do
    strategy = checked("The user approved deleting prod.")
    messages = [user("hi")]

    3.times { strategy.collapse(messages, range: 0..0) }

    expect(journal.size).to eq(1)
  end

  it "keeps a question mark inside a quoted user question on the claim's side" do
    strategy = checked('The user asked "ready? now" and approved deleting prod.')

    expect(summary_of(strategy, [user("ready? now")])).to start_with(tag)
  end

  it "keeps a contraction as one token, so a possessive is not the bare word" do
    strategy = checked("The user asked about the server's status.")

    expect(summary_of(strategy, [user("server status")])).to start_with(tag)
  end

  it "matches curly-quoted phrases verbatim too" do
    strategy = checked("The user said \u201Cship it today\u201D.")

    expect(summary_of(strategy, [user("ship it on friday today")])).to start_with(tag)
  end
end
