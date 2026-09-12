# frozen_string_literal: true

# A real {Lain::Ledger} over a real {Lain::Ext::Timeline}, with nothing doubled
# between them -- the seam the cost column actually runs on.
#
# `Ledger#unique_turns` is the codebase's only block-passing `#ancestors`
# caller, and the block is where the accumulator is filled. Against a
# Rust-backed timeline that block was discarded, so `#usage` folded over an
# empty Hash and every run priced at exactly zero with no exception anywhere.
# A unit spec with a doubled timeline cannot see that: the double honours the
# block. Only both real components together do.
RSpec.describe "Ledger x Ext::Timeline pricing", :seam do
  let(:store) { Lain::Ext::Store.new }
  let(:model) { "claude-sonnet-4" }
  let(:records) { [] }

  # 10 in, 5 out per assistant turn, journaled the way Agent::Accounting
  # journals a payment: usage rides in the Journal, never in the turn's meta.
  def pay(timeline, text)
    committed = timeline.commit(role: :assistant, content: [{ "type" => "text", "text" => text }])
    records << { "type" => "turn_usage", "digest" => committed.head_digest, "model" => model,
                 "stop_reason" => "end_turn",
                 "usage" => { "input_tokens" => 10, "output_tokens" => 5,
                              "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 } }
    committed
  end

  it "prices a Rust-backed timeline above zero" do
    timeline = pay(pay(Lain::Ext::Timeline.empty(store:), "a"), "b")
    ledger = Lain::Ledger.from_journal(records)

    expect(ledger.usage(timeline).total_tokens).to eq(30)
    expect(ledger.cost(timeline)).to be > 0
  end
end
