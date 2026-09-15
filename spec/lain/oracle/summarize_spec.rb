# frozen_string_literal: true

# The eager summarizer's question. Almost everything here is a CONTRACT WITH A
# NEIGHBOUR: the slot name is the one {Lain::Oracle::Eager} fills, and the
# answer field is the one {Lain::Compaction::SummarySnapshot.take} reads. Either
# drifting alone is a total, silent miss -- every fire lands somewhere no render
# looks -- with `hits`/`misses` unable to tell it from "no summaries yet".
RSpec.describe Lain::Oracle::Summarize do
  let(:definition) { described_class.definition }

  it "fills the slot Oracle::Eager fires under" do
    rendered = definition.render(Lain::Oracle::Eager::DEFAULT_SLOT => "a large tool result")

    expect(rendered).to include("a large tool result")
  end

  it "answers with the field SummarySnapshot.take reads off a held answer" do
    answer = definition.answer("summary" => "three exports, no tests").await

    expect(answer.summary).to eq("three exports, no tests")
  end

  it "refuses an answer with no summary in it rather than holding a blank" do
    expect { definition.answer({}) }.to raise_error(Lain::Oracle::InvalidAnswer, /summary/i)
  end

  # The tier is folded into the digest, so the live model arm and a heuristic
  # baseline answering the same question are two oracles at two addresses.
  it "addresses a model answer and a heuristic answer separately" do
    expect(definition.digest).not_to eq(described_class.definition(tier: :heuristic).digest)
  end

  # AC: the template asks for JSON. Bare format constraints go unheard on a
  # provider that ignores them -- measured on the hosted `ollama-cloud` arm,
  # which declares the same structured_output capability the local arm does --
  # so the question asks in words too, the same reasoning
  # {Lain::Oracle::SecretRead::TEMPLATE} states.
  it "asks for JSON matching the answer schema, in words, not only via the format constraint" do
    rendered = definition.render(Lain::Oracle::Eager::DEFAULT_SLOT => "a large tool result")

    expect(rendered).to match(/JSON object/i)
    expect(rendered).to include(%({"summary":))
  end
end
