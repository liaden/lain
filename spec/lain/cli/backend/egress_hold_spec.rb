# frozen_string_literal: true

RSpec.describe Lain::CLI::Backend::EgressHold do
  let(:summary) do
    { endpoint: "api.anthropic.com/v1/messages", bytes: 1_234, body_digest: "blake3:#{"ab" * 32}", literal_hits: 1,
      flagged: 2 }
  end

  # A queue that records each decision and answers the next of `answers`.
  def queue_answering(*answers)
    Class.new do
      define_method(:asked) { @asked ||= [] }
      define_method(:ask_decision) { |decision, timeout: nil| (asked << [decision, timeout]) && answers.shift }
    end.new
  end

  def supervising?(hold) = hold.supervises?

  describe "off" do
    it "hands every requester a hold that supervises nothing and sends, bound or not" do
      queue = queue_answering(false, false)
      hold = described_class.new("off")
      unbound = [hold.for(:agent), hold.for(:secret_oracle)]
      hold.bind(queue)
      holds = [*unbound, hold.for(:agent), hold.for(:secret_oracle)]

      expect(holds.map { supervising?(_1) }).to all(be(false))
      expect(holds.map { _1.call(summary) }).to all(be(true))
      expect(queue.asked).to be_empty
    end

    it "is the scope when no flag was given" do
      expect(supervising?(described_class.new(nil).for(:agent))).to be(false)
    end
  end

  describe "all" do
    it "parks an egress decision for each requester and answers what the human answered" do
      queue = queue_answering(true, false)
      hold = described_class.new("all").bind(queue)

      answers = [hold.for(:agent).call(summary), hold.for(:summarizer).call(summary)]

      expect(answers).to eq([true, false])
      decision = queue.asked.first.first
      expect([decision.kind, decision.digest]).to eq(["egress", summary[:body_digest]])
      expect(decision.requester).to eq(Lain::Requester.main)
      expect(queue.asked.last.first.requester.name).to eq("summarizer")
    end

    it "summarizes the request in one line, naming who sends it, from the summary alone" do
      queue = queue_answering(true)

      described_class.new("all").bind(queue).for(:summarizer).call(summary)

      expect(queue.asked.first.first.summary)
        .to include("summarizer", "api.anthropic.com/v1/messages", "1,234 canonical bytes", summary[:body_digest],
                    "1 known value", "2 region")
    end

    it "refuses before it is bound, naming why" do
      hold = described_class.new("all").for(:agent)

      expect { hold.call(summary) }
        .to raise_error(Lain::Provider::HTTP::EgressGuard::Refused, /egress supervision not ready/)
    end

    it "refuses at once with nobody to ask, naming the flag" do
      hold = described_class.new("all").bind(nil).for(:agent)

      expect { hold.call(summary) }
        .to raise_error(Lain::Provider::HTTP::EgressGuard::Refused, /--supervise-egress/)
    end
  end

  describe "oracle" do
    it "parks only the secret oracle's requests" do
      queue = queue_answering(true)
      hold = described_class.new("oracle").bind(queue)

      expect(supervising?(hold.for(:agent))).to be(false)
      expect(hold.for(:secret_oracle).call(summary)).to be(true)
      expect(queue.asked.map { _1.first.requester.name }).to eq(["secret_oracle"])
    end
  end

  it "binds to one queue" do
    queue = queue_answering
    hold = described_class.new("all").bind(queue)

    expect(hold.bind(queue)).to be(hold)
    expect { hold.bind(queue_answering) }.to raise_error(Lain::CLI::Backend::Rebound)
    expect { described_class.new("all").bind(nil).bind(queue) }.to raise_error(Lain::CLI::Backend::Rebound)
  end

  it "refuses a scope it does not know" do
    expect { described_class.new("sometimes") }.to raise_error(ArgumentError, /off, oracle, all/)
  end
end
