# frozen_string_literal: true

RSpec.describe Lain::CLI::Backend::Tier do
  let(:journal) { [] }
  let(:provider) { Lain::Provider::Mock.new(responses: [text_response("ok")]) }
  let(:backend) do
    Lain::CLI::Backend.new({ provider: "ollama", model: "qwen3:4b", num_batch: 1024, num_ctx: 8192 }, root: Dir.pwd)
                      .tap { |built| allow(built).to receive(:provider).and_return(provider) }
  end
  let(:model_switch) { Lain::Context::ModelSwitch.new("qwen3:4b", journal: instance_double(Lain::Journal, record: nil)) }
  let(:board) do
    egress = Lain::Sensitivity::Secrets::Egress.new(refused: [], flagged: [])
    Struct.new(:guard_inputs, :approvals, :ledger, :sensitivity, :model_switch)
          .new(Struct.new(:secrets).new(Class.new { define_method(:egress) { |**| egress } }.new), nil,
               Lain::Sensitivity::Ledger.new, Lain::Sensitivity::Policy::Null.instance, model_switch)
  end
  let(:request) do
    Lain::Request.new(model: "x", messages: [{ "role" => "user", "content" => "hi" }], max_tokens: 8, stream: false)
  end

  def tier(model: :follow, **) = described_class.new(role: :auto_approver, backend:, model:, queue: true, **)

  before { backend.journal_slot.bind(journal) }

  it "answers the launch model before the backend is attached" do
    expect(tier.model).to eq("qwen3:4b")
  end

  it "follows /model once the backend is attached" do
    backend.attach(board, [])
    model_switch.switch("qwen3-coder:30b", surface: :spec)

    expect(tier.model).to eq("qwen3-coder:30b")
  end

  it "carries the chat's runner options" do
    expect(tier.extra).to eq("num_batch" => 1024, "num_ctx" => 8192)
  end

  it "carries the chat's runner options on the model the chat switched to" do
    backend.attach(board, [])
    model_switch.switch("qwen3-coder:30b", surface: :spec)

    expect(tier.extra).to eq("num_batch" => 1024, "num_ctx" => 8192)
  end

  it "keeps a pinned model through /model, with no runner options carried to a different model" do
    backend.attach(board, [])
    model_switch.switch("qwen3-coder:30b", surface: :spec)
    pinned = tier(model: "llama3:8b")

    expect([pinned.model, pinned.extra]).to eq(["llama3:8b", {}])
  end

  it "journals the request as the role's, and the payment" do
    tier.provider.complete(request)

    expect(journal.map { _1.to_journal.values_at("type", "requester") })
      .to eq([%w[request_sent auto_approver], %w[turn_usage auto_approver]])
  end

  describe "what a tier's answer costs" do
    let(:shared) { Lain::Budget::Shared.new }
    let(:priced) { Lain::Usage.new(input_tokens: 10_000) }
    let(:provider) do
      Lain::Provider::Mock.new(responses: [text_response('{"summary": "ok"}', model: "claude-opus-5-5", usage: priced)])
    end

    before { backend.attach(board, [], spend: shared) }

    it "pays its dollars into the spend the backend was attached with, once per answer" do
      tier.provider.complete(request)

      expect([shared.spent.dollars.amount, shared.spent.usage]).to eq([BigDecimal("0.04"), Lain::Usage.zero])
    end

    it "pays for an oracle's answer too, journaling one payment beside it" do
      definition = Lain::Oracle::Summarize.definition
      tier.oracle(definition:, max_tokens: 64).ask("source" => "a long tool result")

      expect([shared.spent.dollars.amount, journal.count { _1.is_a?(Lain::Telemetry::TurnUsage) }])
        .to eq([BigDecimal("0.04"), 1])
    end
  end

  it "pays nothing anywhere before the backend is attached" do
    tier.provider.complete(request)

    expect(backend.attachment.spend.spent).to eq(Lain::Budget::Spent.zero)
  end

  describe "on another arm than the chat's" do
    it "builds its provider on that arm" do
      allow(backend).to receive(:provider).and_return(provider)

      tier(arm: "ollama-cloud").provider

      expect(backend).to have_received(:provider).with(name: "ollama-cloud", requester: :auto_approver, queue: true)
    end

    it "carries no runner options of the chat's, whether it follows or is pinned to the chat's model" do
      expect([tier(arm: "ollama-cloud").extra, tier(model: "qwen3:4b", arm: "ollama-cloud").extra]).to eq([{}, {}])
    end

    it "carries the runner options when the arm is the chat's own" do
      expect(tier(arm: "ollama").extra).to eq("num_batch" => 1024, "num_ctx" => 8192)
    end
  end
end
