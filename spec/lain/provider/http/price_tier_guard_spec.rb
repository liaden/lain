# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Lain::Provider::HTTP::PriceTierGuard do
  let(:messages_url) { "https://api.anthropic.com/v1/messages" }
  let(:count_url) { "https://api.anthropic.com/v1/messages/count_tokens" }
  let(:counted) { [] }
  let(:journal) { [] }
  let(:asked) { [] }
  let(:answer) { :approve }
  let(:shown) { [] }
  let(:channel) do
    log = shown
    Class.new { define_method(:push) { |event| (log << event) && self } }.new
  end
  let(:hold) do
    log = asked
    replies = Array(answer)
    scripted = Class.new(described_class::Hold) do
      define_method(:decide) do |decision|
        log << decision
        replies.length > 1 ? replies.shift : replies.first
      end
    end
    scripted.new.tap { |built| built.bind(nil, channel) }
  end

  def counter(tokens)
    log = counted
    ->(body) { (log << body) && tokens }
  end

  def failing_counter = ->(_body) { raise Lain::Provider::Anthropic::APIError, "count says no" }

  def build_connection(counter:, hold: self.hold, mode: :ask, max_retries: 0,
                       prices: Lain::CLI::Backend::COMPACTION_PRICES)
    config = zero_retry_config(max_retries:)
    config.anthropic_api_key = "sk-ant-test"
    config.http_middleware = [[described_class, { prices:, counter:, hold:, journal:, mode: }]]
    provider = Lain::Provider::HTTP::Providers::Anthropic.new(config)
    Lain::Provider::HTTP::Connection.new(provider, config)
  end

  def body(model:, bytes:)
    { model:, max_tokens: 64, stream: false, system: "be terse", tools: [],
      messages: [{ role: "user", content: "x" * bytes }] }
  end

  def near_tier = body(model: "claude-haiku-5-5", bytes: 400_000)

  # A haiku body whose canonical bytes over 4 come to exactly `tokens`.
  def estimated_at(tokens)
    empty = body(model: "claude-haiku-5-5", bytes: 0)
    body(model: "claude-haiku-5-5", bytes: (tokens * 4) - Lain::Canonical.dump(empty).bytesize)
  end

  def stub_messages(*replies)
    stub_request(:post, messages_url)
      .to_return(*(replies.empty? ? [ok] : replies))
  end

  def ok = { status: 200, body: "{}", headers: { "Content-Type" => "application/json" } }

  it "sends a request far below the tier without counting it" do
    sent = stub_messages

    build_connection(counter: counter(1)).post("/v1/messages", body(model: "claude-haiku-5-5", bytes: 4_000))

    expect(counted).to be_empty
    expect(asked).to be_empty
    expect(sent).to have_been_requested.once
  end

  it "asks once about a request counted past the tier, naming the figures, then sends it" do
    sent = stub_messages

    build_connection(counter: counter(104_000)).post("/v1/messages", near_tier)

    expect(asked.size).to eq(1)
    expect(asked.first.kind).to eq("price_tier")
    expect(asked.first.summary).to include("claude-haiku-5-5", "104,000", "100,000", "$0.0104", "$0.052")
    expect(asked.first.summary)
      .to include("Approving sends this and every later request in this chat, its subagents included, " \
                  "on claude-haiku-5-5 at the tier rate")
    expect(sent).to have_been_requested.once
  end

  it "journals the crossing with the decision" do
    stub_messages

    build_connection(counter: counter(104_000)).post("/v1/messages", near_tier)

    expect(journal.map(&:to_journal)).to eq([{ "type" => "price_tier_crossed", "model" => "claude-haiku-5-5",
                                               "prompt_tokens" => 104_000, "boundary" => 100_000,
                                               "standard_cost" => "0.0104", "tier_cost" => "0.052",
                                               "decision" => :approve }])
    expect(Ractor.shareable?(journal.first)).to be(true)
  end

  it "hands the counter the whole body, leaving the count endpoint's fields to the provider" do
    stub_messages

    build_connection(counter: counter(104_000)).post("/v1/messages", near_tier)

    expect(counted).to eq([near_tier])
  end

  it "reads the body's canonical bytes once, for both the estimate and the remembered answer" do
    stub_messages
    allow(Lain::Canonical).to receive(:dump).and_call_original

    build_connection(counter: counter(104_000)).post("/v1/messages", near_tier)

    expect(Lain::Canonical).to have_received(:dump).once
  end

  it "counts a dense body, about 3 bytes a token, that crosses the tier" do
    stub_messages
    dense = body(model: "claude-haiku-5-5", bytes: 315_000)

    build_connection(counter: counter(105_000)).post("/v1/messages", dense)

    expect(asked.size).to eq(1)
  end

  it "counts a body estimated just inside the margin" do
    stub_messages

    build_connection(counter: counter(1)).post("/v1/messages", estimated_at(60_000))

    expect(counted.size).to eq(1)
  end

  it "does not count a body estimated just outside the margin" do
    stub_messages

    build_connection(counter: counter(1)).post("/v1/messages", estimated_at(59_999))

    expect(counted).to be_empty
  end

  it "sends a prompt of exactly the boundary without asking, since a tier bills only above it" do
    sent = stub_messages

    build_connection(counter: counter(100_000)).post("/v1/messages", near_tier)

    expect(asked).to be_empty
    expect(sent).to have_been_requested.once
  end

  it "sends a request for an unpriced model without counting it" do
    sent = stub_messages

    build_connection(counter: counter(2_000_000)).post("/v1/messages",
                                                       body(model: "claude-fable-5", bytes: 4_000_000))

    expect(counted).to be_empty
    expect(sent).to have_been_requested.once
  end

  it "sends a near request that counts under the tier without asking" do
    sent = stub_messages

    build_connection(counter: counter(99_000)).post("/v1/messages", near_tier)

    expect(counted.size).to eq(1)
    expect(asked).to be_empty
    expect(journal).to be_empty
    expect(sent).to have_been_requested.once
  end

  it "reuses the answer when Faraday retries the same body after a 529" do
    sent = stub_messages({ status: 529, body: "{}", headers: { "Content-Type" => "application/json" } }, ok)

    build_connection(counter: counter(104_000), max_retries: 1).post("/v1/messages", near_tier)

    expect(asked.size).to eq(1)
    expect(counted.size).to eq(1)
    expect(sent).to have_been_requested.twice
  end

  context "when the human denies the crossing" do
    let(:answer) { :deny }

    it "refuses with a message naming the tier and sends nothing" do
      sent = stub_messages

      expect { build_connection(counter: counter(104_000)).post("/v1/messages", near_tier) }
        .to raise_error(described_class::Refused, /100,000-token price tier/)
      expect(sent).not_to have_been_requested
      expect(journal.map(&:decision)).to eq([:deny])
    end
  end

  context "when the human denies a crossing and then approves its resend" do
    let(:answer) { %i[deny approve] }

    it "asks again rather than remembering the denial" do
      sent = stub_messages
      connection = build_connection(counter: counter(104_000))

      expect { connection.post("/v1/messages", near_tier) }.to raise_error(described_class::Refused)
      connection.post("/v1/messages", near_tier)

      expect(asked.size).to eq(2)
      expect(journal.map(&:decision)).to eq(%i[deny approve])
      expect(sent).to have_been_requested.once
    end
  end

  it "remembers an approval, so a resend of the same body is neither asked about nor shown again" do
    stub_messages
    connection = build_connection(counter: counter(104_000))

    2.times { connection.post("/v1/messages", near_tier) }

    expect(asked.size).to eq(1)
    expect(shown).to be_empty
  end

  it "carries an approval to a later crossing on the same model, journaling and showing it" do
    sent = stub_messages
    connection = build_connection(counter: counter(104_000))

    connection.post("/v1/messages", near_tier)
    connection.post("/v1/messages", near_tier.merge(system: "a later turn"))

    expect(asked.size).to eq(1)
    expect(sent).to have_been_requested.twice
    expect(journal.map(&:decision)).to eq(%i[approve carried])
    expect(shown).to eq([journal.last])
  end

  it "carries an approval across every guard built over the same hold, as a chat's subagents are" do
    stub_messages

    build_connection(counter: counter(104_000)).post("/v1/messages", near_tier)
    build_connection(counter: counter(104_000)).post("/v1/messages", near_tier.merge(system: "a subagent"))

    expect(asked.size).to eq(1)
    expect(shown.map(&:decision)).to eq([:carried])
  end

  it "lets a defect in counting propagate rather than reading it as an uncountable prompt" do
    stub_messages
    broken = ->(_body) { raise NoMethodError, "undefined method 'fetch' for nil" }

    expect { build_connection(counter: broken, mode: :allow).post("/v1/messages", near_tier) }
      .to raise_error(NoMethodError)
  end

  it "asks fresh about a crossing on a different model" do
    stub_messages
    haiku = Lain::PriceBook::DEFAULTS.fetch("claude-haiku-5-5")
    prices = Lain::PriceBook.new(prices: Lain::PriceBook::DEFAULTS.merge("claude-twin-5-5" => haiku))
    connection = build_connection(counter: counter(104_000), prices:)

    connection.post("/v1/messages", near_tier)
    connection.post("/v1/messages", near_tier.merge(model: "claude-twin-5-5"))

    expect(asked.map(&:summary)).to contain_exactly(a_string_including("claude-haiku-5-5"),
                                                    a_string_including("claude-twin-5-5"))
    expect(shown).to be_empty
  end

  it "refuses a resend again under refuse mode, judging it afresh" do
    stub_messages
    connection = build_connection(counter: counter(104_000), mode: :refuse)

    2.times { expect { connection.post("/v1/messages", near_tier) }.to raise_error(described_class::Refused) }

    expect(counted.size).to eq(2)
  end

  it "refuses an uncountable request under ask, saying why, and sends nothing" do
    sent = stub_messages

    expect { build_connection(counter: failing_counter).post("/v1/messages", near_tier) }
      .to raise_error(described_class::Refused,
                      "could not count the prompt to check its price tier: count says no")
    expect(asked).to be_empty
    expect(sent).not_to have_been_requested
  end

  it "refuses an uncountable request under refuse mode" do
    sent = stub_messages

    expect { build_connection(counter: failing_counter, mode: :refuse).post("/v1/messages", near_tier) }
      .to raise_error(described_class::Refused, /could not count the prompt/)
    expect(sent).not_to have_been_requested
  end

  it "sends an uncountable request under allow mode, journaling no token figure" do
    sent = stub_messages

    build_connection(counter: failing_counter, mode: :allow).post("/v1/messages", near_tier)

    expect(sent).to have_been_requested.once
    expect(journal).to be_empty
  end

  it "refuses without asking under refuse mode" do
    sent = stub_messages

    expect { build_connection(counter: counter(104_000), mode: :refuse).post("/v1/messages", near_tier) }
      .to raise_error(described_class::Refused, /100,000-token price tier/)
    expect(asked).to be_empty
    expect(sent).not_to have_been_requested
    expect(journal.map(&:decision)).to eq([:refuse])
  end

  it "refuses with the same message when no human is bound to the hold" do
    sent = stub_messages
    unbound = described_class::Hold.new

    expect { build_connection(counter: counter(104_000), hold: unbound).post("/v1/messages", near_tier) }
      .to raise_error(described_class::Refused, /100,000-token price tier/)
    expect(sent).not_to have_been_requested
  end

  it "sends without asking under allow mode, and still journals the crossing" do
    sent = stub_messages

    build_connection(counter: counter(104_000), mode: :allow).post("/v1/messages", near_tier)

    expect(asked).to be_empty
    expect(sent).to have_been_requested.once
    expect(journal.map(&:decision)).to eq([:allow])
  end

  it "refuses a mode it does not know" do
    expect { build_connection(counter: counter(1), mode: :maybe).post("/v1/messages", near_tier) }
      .to raise_error(ArgumentError, /maybe/)
  end

  it "never counts a model without tiers" do
    sent = stub_messages

    build_connection(counter: counter(2_000_000)).post("/v1/messages",
                                                       body(model: "claude-opus-5-5", bytes: 4_000_000))

    expect(counted).to be_empty
    expect(sent).to have_been_requested.once
  end

  it "lets the count request itself through on the same connection" do
    count = stub_request(:post, count_url).to_return(ok)

    build_connection(counter: counter(104_000)).post("/v1/messages/count_tokens",
                                                     near_tier.slice(:model, :system, :tools, :messages))

    expect(counted).to be_empty
    expect(asked).to be_empty
    expect(count).to have_been_requested.once
  end

  describe described_class::Hold do
    let(:decision) do
      Lain::Approval::Parked::Queue::Decision.new(requester: Lain::Requester.main, kind: "price_tier",
                                                  summary: "s", digest: "blake3:00")
    end

    it "refuses while nothing is bound" do
      expect(described_class.new.decide(decision)).to eq(:refuse)
    end

    it "asks the bound queue and answers its verdict" do
      queue = instance_double(Lain::Approval::Parked::Queue)
      allow(queue).to receive(:ask_decision).with(decision).and_return(true, false)
      hold = described_class.new.tap { _1.bind(queue) }

      expect([hold.decide(decision), hold.decide(decision)]).to eq(%i[approve deny])
    end

    it "refuses again once bound to nobody, as an unattended run is" do
      expect(described_class.new.tap { _1.bind(nil) }.decide(decision)).to eq(:refuse)
    end

    it "carries an approved model and no other" do
      hold = described_class.new.tap { _1.approve("claude-haiku-5-5") }

      expect([hold.carries?("claude-haiku-5-5"), hold.carries?("claude-twin-5-5")]).to eq([true, false])
    end

    it "shows a record on the channel it was bound with, and nowhere before that" do
      hold = described_class.new
      hold.show(:early)
      hold.bind(nil, channel)
      hold.show(:late)

      expect(shown).to eq([:late])
    end
  end
end
