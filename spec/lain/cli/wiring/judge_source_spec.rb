# frozen_string_literal: true

# Defines LainCLI (and Thor) without starting it; the flags are parsed by the real command.
load File.expand_path("../../../../exe/lain", __dir__)

RSpec.describe Lain::CLI::Wiring::JudgeSource do
  let(:question) { { tool: "bash", input: { "command" => "rm -rf build" }, place: } }
  let(:place) { Lain::Approval::Judge::Place.new(root: "/p", cwd: "/p", requester: "main", outside: []) }
  let(:judge) { instance_double(Lain::Approval::Judge, call: :approve) }
  let(:slots) { Lain::Prompt::Slots.new(fills: {}) }
  let(:journal) { [] }
  let(:provider) { Lain::Provider::Mock.new(responses: [text_response("APPROVE")]) }

  def source(provider: -> { self.provider }, timeout: 30)
    described_class.new(provider:, model: "judge-model", slots:, timeout:)
  end

  it "builds the provider at the first judged call, not when it is built" do
    builds = 0
    source(provider: -> { builds += 1 })

    expect(builds).to eq(0)
  end

  it "builds the judge with the timeout the project configured" do
    allow(Lain::Approval::Judge).to receive(:new).and_return(judge)

    source(timeout: 90).call(**question)

    expect(Lain::Approval::Judge).to have_received(:new)
      .with(provider:, model: "judge-model", extra: {}, slots:, timeout: 90)
  end

  it "builds the judge once across two judged calls, and answers its verdict" do
    allow(Lain::Approval::Judge).to receive(:new).and_return(judge)
    built = source

    expect(Array.new(2) { built.call(**question) }).to eq(%i[approve approve])
    expect(Lain::Approval::Judge).to have_received(:new).once
  end

  # A judge that cannot be built is a fault like any other the judge has.
  it "answers :fault and tells the fault callback when the judge cannot be built" do
    faults = []

    verdict = source(provider: -> { raise IOError, "no provider" }).call(**question) { |why| faults << why }

    expect([verdict, faults]).to eq([:fault, ["IOError: no provider"]])
  end

  it "forwards the place to the judge" do
    allow(Lain::Approval::Judge).to receive(:new).and_return(judge)

    source.call(**question)

    expect(judge).to have_received(:call).with(**question)
  end

  it "answers :fault with no callback given" do
    expect(source(provider: -> { raise IOError, "no provider" }).call(**question)).to eq(:fault)
  end

  it "rules in one request to the provider it builds" do
    verdict = source.call(**question)

    expect([verdict, provider.requests.size, provider.requests.sole.tools]).to eq([:approve, 1, []])
  end

  describe "a judge built through .for on an ollama chat" do
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
    let(:built) do
      described_class.for(backend, config: instance_double(Lain::Config, judge_timeout: 30))
    end

    it "sends the chat's num_batch and num_ctx" do
      built.call(**question)

      expect(provider.requests.sole.extra).to include("num_batch" => 1024, "num_ctx" => 8192)
    end

    it "records exactly one request_sent per judged call" do
      backend.journal_slot.bind(journal)
      built.call(**question)

      expect(journal.map { _1.to_journal.fetch("type") }.tally.fetch("request_sent")).to eq(1)
    end

    it "asks through its Tier, which journals the request and its payment once, as auto_approver's" do
      backend.journal_slot.bind(journal)
      built.call(**question)

      expect(journal.map { _1.to_journal.values_at("type", "requester") })
        .to eq([%w[request_sent auto_approver], %w[turn_usage auto_approver]])
    end

    it "asks the model /model switched to, after the judge was first built" do
      backend.attach(board, [])
      built.call(**question)
      model_switch.switch("qwen3-coder:30b", surface: :spec)
      built.call(**question)

      expect(provider.requests.map(&:model)).to eq(%w[qwen3:4b qwen3-coder:30b])
      expect(provider.requests.last.extra).to include("num_batch" => 1024)
    end
  end

  describe ".for" do
    def parse(*argv) = Thor::Options.new(LainCLI.commands.fetch("chat").options).parse(argv)

    def judge_model(backend)
      model = nil
      allow(Lain::Approval::Judge).to receive(:new) { |**built| (model = built[:model].call) && judge }
      described_class.for(backend, config: instance_double(Lain::Config, judge_timeout: 30))
                     .call(**question)
      model
    end

    def contextless_backend(argv)
      Lain::CLI::Backend.new(parse(*argv), root: Dir.pwd).tap do |backend|
        allow(backend).to receive(:provider).and_return(provider)
        allow(backend).to receive(:context).and_raise("a whole Context was built just to read a model name")
      end
    end

    [
      ["the default anthropic model", %w[--provider anthropic]],
      ["an explicit anthropic model", %w[--provider anthropic --model claude-opus-4-6]],
      ["the default ollama model", %w[--provider ollama]],
      ["an explicit ollama model", %w[--provider ollama --model qwen3-coder:30b]]
    ].each do |kind, argv|
      it "gives the judge the chat's model for #{kind} without building a Context" do
        chat_model = Lain::CLI::Backend.new(parse(*argv), root: Dir.pwd).context.model

        expect(judge_model(contextless_backend(argv))).to eq(chat_model)
      end
    end
  end
end
