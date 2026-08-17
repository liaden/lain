# frozen_string_literal: true

require "timeout"

# T17. The oracle a parked SECRET read is judged by. Half of this file looks
# like plumbing and is not: WHICH endpoint answers is the security property this
# whole rung exists for, so "it is built against the local ollama provider" is
# the claim under test, and the questions about verdict shape are the smaller
# half.
#
# Every provider assertion captures the collaborator that REACHED the tier
# rather than counting `.new` calls: a `Provider::Ollama` can be built and
# thrown away, and only the object the tier will actually ask proves anything.

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module SecretReadSpecSupport
  # Under SpecWatchdog::BUDGET (30s), so a slow local model skips rather than
  # tripping a watchdog whose message would blame a hang.
  WATCHDOG_SAFE_SECONDS = 25
end

RSpec.describe Lain::Oracle::SecretRead do
  # The provider {Oracle::Model} was constructed over, captured at the one
  # construction site.
  def provider_built(**opts)
    captured = nil
    allow(Lain::Oracle::Model).to receive(:new).and_wrap_original do |original, **kwargs|
      captured = kwargs[:provider]
      original.call(**kwargs)
    end
    described_class.tier(**opts)
    captured
  end

  def inputs(path: '"/repo/Gemfile.lock"', tool: "read", region_count: "2")
    { path:, tool:, region_count: }
  end

  describe "which model judges a candidate secret" do
    it "builds the model tier against a LOCAL ollama provider" do
      expect(provider_built).to be_a(Lain::Provider::Ollama)
    end

    # AC: "a provider knob cannot move the oracle off the local model." The knob
    # this refuses to copy is live and really does name remote arms one object
    # over ({CLI::Backend::PROVIDERS}), which is what keeps this non-vacuous:
    # `--summarizer-provider anthropic` moves THAT tier, and nothing moves this
    # one.
    it "constructs no remote provider at all, whatever a run's knobs say" do
      expect(Lain::CLI::Backend::PROVIDERS).to include("anthropic", "bedrock")
      expect(Lain::Provider::Anthropic).not_to receive(:new)
      expect(Lain::Provider::Bedrock).not_to receive(:new)

      expect(provider_built).to be_a(Lain::Provider::Ollama)
    end

    # The knob is LIVE and really does take a remote name: `Backend`'s
    # constructor validates it, so "anthropic" is accepted there and nonsense is
    # refused. That is what stops the assertions above from being vacuous -- the
    # thing this builder refuses to read is a working provider selector one
    # object over.
    it "refuses a knob that genuinely selects a remote summarizer tier" do
      expect { Lain::CLI::Backend.new(summarizer_provider: "anthropic") }.not_to raise_error
      expect { Lain::CLI::Backend.new(summarizer_provider: "not-a-provider") }
        .to raise_error(Lain::CLI::UnknownProvider)

      expect(provider_built).to be_a(Lain::Provider::Ollama)
    end

    # The upgrade-detection guard. A `provider:`, `backend:` or `router:` keyword
    # appearing here is the whole failure this card exists to prevent, arriving
    # as an innocuous-looking seam -- so the parameter list itself is pinned.
    it "takes no provider, backend or router seam: there is nothing to move it with" do
      keys = described_class.method(:tier).parameters.map(&:last)

      expect(keys).to contain_exactly(:model, :journal)
    end

    # AC: "the router cannot move it either." {Oracle::Router} answers "which
    # model should run this" for spawned children; a builder that consulted it
    # would let a routed answer name a remote model.
    it "consults no router, so a router that names a remote model never reaches it" do
      expect(Lain::Oracle::Router).not_to receive(:definition)
      expect(Lain::Oracle::Router).not_to receive(:heuristic)

      expect(provider_built).to be_a(Lain::Provider::Ollama)
    end

    # `Backend#provider` hands `--api-base` straight to `Provider::Ollama`, so a
    # copied line here would let `--api-base https://elsewhere` redirect the
    # "local" judge at a remote host with every other assertion in this file
    # still green.
    it "passes no api_base, so no base-URL flag can redirect the local judge" do
      allow(Lain::Provider::Ollama).to receive(:new).and_call_original

      described_class.tier

      expect(Lain::Provider::Ollama).to have_received(:new).with(no_args)
    end
  end

  describe "the question" do
    it "names the path, the tool and the region COUNT" do
      question = described_class.definition.render(inputs)

      expect(question).to include("/repo/Gemfile.lock").and include("read").and include("2")
    end

    # B2. Offline half of the live check below: `Model::JsonDecoder` demands a
    # JSON object, and without this sentence the default local model answers
    # with the bare word the rest of the template asked for and every call
    # raises UndecodableAnswer. Deleting the sentence is therefore deleting the
    # arm, silently -- and the :ollama example is the only other thing that
    # would notice, which is excluded by default.
    it "asks for a JSON object, because the decoder demands one and prose is what a model gives otherwise" do
      question = described_class.definition.render(inputs)

      expect(question).to include("JSON").and include("verdict").and include("confidence")
    end

    it "fails loudly when a caller leaves a slot unfilled, rather than asking a blank question" do
      expect { described_class.definition.render(inputs.except(:region_count)) }.to raise_error(KeyError)
    end

    it "is a different oracle per tier, so a heuristic answer never replays as a model one" do
      expect(described_class.definition(tier: :model).digest)
        .not_to eq(described_class.definition(tier: :heuristic).digest)
    end
  end

  # B2. `Oracle::Model::JsonDecoder` demands a JSON object, and the template is
  # the only thing that asks for one. Whether a 4B local model actually complies
  # is not a question a double can answer -- with the JSON sentence removed,
  # this arm returned the bare word `deny` and raised UndecodableAnswer on every
  # call, which is an opt-in security surface that silently never fires.
  #
  # Pinned to the DEFAULT base rather than OLLAMA_API_BASE on purpose: `.tier`
  # takes no api_base, which is the security property, so a developer pointing
  # the other :ollama specs elsewhere correctly does not move this one.
  #
  # SKIPS rather than fails when the model is merely slow, which is the same
  # skip-not-fail rule `spec/support/ollama_tag.rb` already applies to a server
  # that is down: measured judgement latency on this model is 13.4-49.3s across
  # two independent runs, and the suite watchdog's budget is 30s, so an
  # unguarded example here would be red about half the time for an environment
  # fact rather than a regression. The bound is deliberately under that budget
  # so the skip wins the race.
  #
  # DO NOT read this example as the thing keeping the JSON sentence honest. At
  # that latency spread against a 25s bound it actually RUNS about one time in
  # five even with LAIN_OLLAMA=1, so the offline pin above is doing the real
  # work; this one is what proved the claim once, and re-proves it occasionally.
  it "gets a decodable, schema-valid answer out of the real default model", :ollama, :seam do
    bound = SecretReadSpecSupport::WATCHDOG_SAFE_SECONDS
    typed = Timeout.timeout(bound) { described_class.tier.ask(**inputs).await }

    expect(typed.verdict.to_s.strip.downcase).to match(/\A(approve|deny|defer)\z/)
    expect(typed.confidence).to be_between(0.0, 1.0)
  rescue Timeout::Error
    skip "#{Lain::Provider::Ollama::DEFAULT_MODEL} did not answer within #{bound}s; that is a slow box, " \
         "not a decode failure -- run the file alone with LAIN_SPEC_BUDGET raised"
  end

  describe "the answer schema" do
    def answer(attributes) = described_class.definition.answer(attributes)

    it "carries a verdict, a confidence and a reason" do
      typed = answer("verdict" => "approve", "confidence" => 0.91, "reason" => "a lockfile").await

      expect([typed.verdict, typed.confidence, typed.reason]).to eq(["approve", 0.91, "a lockfile"])
    end

    it "accepts a zero confidence -- the least certain answer is still an answer" do
      expect(answer("verdict" => "defer", "confidence" => 0.0).await.confidence).to eq(0.0)
    end

    it "refuses an answer with no verdict" do
      expect { answer("confidence" => 0.9) }.to raise_error(Lain::Oracle::InvalidAnswer, /verdict/i)
    end

    it "refuses an answer with no confidence, so a threshold can never be applied to a blank" do
      expect { answer("verdict" => "approve") }.to raise_error(Lain::Oracle::InvalidAnswer, /confidence/i)
    end

    it "refuses a field the schema never declared" do
      expect { answer("verdict" => "approve", "confidence" => 1.0, "contents" => "sk-ant-...") }
        .to raise_error(Lain::Oracle::InvalidAnswer)
    end
  end

  # The calibration half of the card: a local model's self-reported confidence
  # is a rank, not a probability, so the threshold has to be set from
  # measurement -- and this is what accrues the measurements.
  describe "the journaled answer" do
    let(:reply) { '{"verdict":"approve","confidence":0.91,"reason":"a lockfile"}' }
    let(:response) do
      Lain::Response.new(model: "qwen3:4b", stop_reason: :end_turn,
                         content: [{ "type" => "text", "text" => reply }],
                         usage: Lain::Usage.new(input_tokens: 40, output_tokens: 12))
    end
    let(:journal) { [] }

    # A real Provider::Mock carrying ollama's OWN capability set, rather than a
    # double stubbed to say yes to everything: Oracle::Model asks #supports?
    # before it builds a request, and ollama declares three of the nine.
    let(:provider) do
      Lain::Provider::Mock.new(responses: [response], capabilities: Lain::Provider::Ollama::CAPABILITIES)
    end

    before { allow(Lain::Provider::Ollama).to receive(:new).and_return(provider) }

    it "records the verdict, the model that gave it and the wall clock it took" do
      described_class.tier(journal:).ask(**inputs).await

      recorded = journal.last
      expect(recorded).to be_a(Lain::Telemetry::OracleAnswer)
      expect(recorded.answer).to include("verdict" => "approve", "confidence" => 0.91)
      expect(recorded.model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
      expect(recorded.wall_clock).to be_a(Numeric)
    end

    it "hands the caller the validated answer, not the raw reply" do
      typed = described_class.tier(journal:).ask(**inputs).await

      expect([typed.verdict, typed.confidence]).to eq(["approve", 0.91])
    end
  end
end
