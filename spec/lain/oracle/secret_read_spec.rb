# frozen_string_literal: true

require "timeout"

# The oracle a parked SECRET read is judged by. Half of this file looks
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
  # construction site -- decorators and all.
  def model_provider(**opts)
    captured = nil
    allow(Lain::Oracle::Model).to receive(:new).and_wrap_original do |original, **kwargs|
      captured = kwargs[:provider]
      original.call(**kwargs)
    end
    described_class.tier(**opts)
    captured
  end

  # The same provider with every decorator peeled off: the object that finally
  # makes the round trip.
  #
  # {Lain::Provider::Journaled} sits in that gap, and the WALK rather than one
  # `#inner` hop is the point. "The judge is a LOCAL ollama" is a claim about
  # what reaches the wire, so it has to survive the next decorator too instead
  # of going quietly vacuous the moment one is added -- which is exactly how
  # this file would have read as green while asserting nothing.
  def provider_built(**opts) = terminal(model_provider(**opts))

  # Depth is peeled here deliberately, but peeling is not what makes the security claim safe: a
  # decorator that LIES about #inner defeats every assertion in this describe, since they all reach
  # the judge through `terminal`. Two other things cover that, and neither is this walk.
  # spec/provider_construction_discipline_spec.rb pins statically that this file may construct only
  # Provider::Ollama -- at any depth, without running anything. The `not_to receive(:new)`
  # expectations below catch a hosted provider CONSTRUCTED during the call, though not one handed in
  # from elsewhere. What this walk is for is the other half: the claim has to survive an honest extra
  # decorator instead of going vacuous the moment one is added.
  def terminal(provider) = provider.respond_to?(:inner) ? terminal(provider.inner) : provider

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
      expect(Lain::CLI::Backend::PROVIDERS).to include("anthropic")
      expect(Lain::Provider::Anthropic).not_to receive(:new)

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

    # The wrap is INSIDE `.tier`, never injected -- see the parameter
    # pin below, which is the security half of the same claim. A decorator built
    # here cannot move the endpoint, because the thing it decorates is still the
    # bare local Ollama constructed one line away.
    it "hands the tier a journaled provider, wrapped around that local one" do
      expect(model_provider).to be_a(Lain::Provider::Journaled)
    end

    # The upgrade-detection guard. A `provider:`, `backend:` or `router:` keyword
    # appearing here is the whole failure this arm exists to prevent, arriving
    # as an innocuous-looking seam -- so the parameter list itself is pinned.
    #
    # `options:` is admitted deliberately and is not that seam: it is a Hash of
    # sampler values that rides the request body, and nothing in it can name a
    # host, a provider or a model.
    it "takes no provider, backend or router seam: there is nothing to move it with" do
      keys = described_class.method(:tier).parameters.map(&:last)

      expect(keys).to contain_exactly(:model, :journal, :options)
    end

    it "stays on loopback when it is handed sampler options" do
      expect(provider_built(options: { "num_batch" => 2048 }).send(:resolved_endpoint))
        .to eq("http://localhost:11434")
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

    # WHAT `no_args` NOW BUYS, which is no longer the same sentence. The pin
    # above says the CALL states nothing; it used to follow that no `api_base`
    # could have been passed and the arm was therefore loopback. Since
    # `Provider::Ollama.new` gained a `deployment:` keyword, what it means is
    # "the default decides" -- so the guarantee moved to the default, and a
    # default is exactly the kind of thing that is edited later without anyone
    # noticing. These are the two ends of one keyword and neither implies the
    # other: `no_args` would stay green with a cloud default, and this would
    # stay green if `.tier` started passing `deployment: Local.new` explicitly.
    #
    # THE LITERAL, NOT `Transport::DEFAULT_API_BASE`, and that is not a style
    # preference. `resolved_endpoint` DERIVES from that constant through three
    # hops -- `Local#api_base` reads it, `Local#apply` writes it onto
    # `config.ollama_api_base`, `resolved_endpoint` reads it back -- so an
    # assertion spelled with the constant compares the value to itself. It
    # cannot tell "the default deployment is loopback" from "the default
    # deployment is whatever DEFAULT_API_BASE happens to say". Measured, not
    # reasoned: with `transport.rb:50` repointed at `https://evil.example.com`
    # this file stayed at 24 examples, 0 failures, while its own header calls
    # WHICH endpoint answers the security property this whole rung exists for.
    # The guarantee names a host, so the spec spells that host. Do not tidy it
    # back into the constant.
    it "gets a LOOPBACK endpoint out of that bare construction, whatever the default deployment is" do
      expect(provider_built.send(:resolved_endpoint)).to eq("http://localhost:11434")
    end

    # NOT hypothetical: `OLLAMA_API_KEY` is exported into some developers'
    # shells by direnv, so the suite really does run with it set. Nothing in
    # `lib/` or `exe/` reads it -- `Deployment` only NAMES it in a
    # refusal message, `Provider::Ollama.cloud` requires `api_key:` explicitly
    # rather than reaching for the environment, and
    # `Configuration.register_provider_options` registers `ollama_api_key` with
    # a nil default rather than an ENV-resolved one. So this cannot fail today,
    # and that is precisely why it is written down: an ENV-defaulted
    # `ollama_api_key` or `ollama_api_base` is the one mechanism that could
    # point this judge at somebody else's server without touching
    # `secret_read.rb` at all, and it would leave every other example here
    # green. `@transport`'s own `#headers` is asserted rather than the
    # deployment's declaration, because `Connection#provider_headers` asks the
    # transport and that is the only auth that reaches the wire. The host is
    # spelled out rather than read from `Transport::DEFAULT_API_BASE`, for the
    # reason the example above states at length.
    it "stays on loopback with a live OLLAMA_API_KEY in the environment, and sends no bearer" do
      with_env("OLLAMA_API_KEY" => "sk-this-would-be-the-disclosure") do
        provider = provider_built

        expect([provider.send(:resolved_endpoint), provider.instance_variable_get(:@transport).headers])
          .to eq(["http://localhost:11434", {}])
      end
    end
  end

  describe "the question" do
    it "names the path, the tool and the region COUNT" do
      question = described_class.definition.render(inputs)

      expect(question).to include("/repo/Gemfile.lock").and include("read").and include("2")
    end

    # Offline half of the live check below: `Model::JsonDecoder` demands a
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

  # `Oracle::Model::JsonDecoder` demands a JSON object, and the template is
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
      Lain::Provider::Mock.new(responses: [response], capabilities: Lain::Provider::Ollama::CAPABILITIES,
                               channel: frontend)
    end

    # A raw provider's live stream -- the frontend's TTY channel on the chat
    # path. Records must not reach it: an oracle round trip is not a turn, and
    # routing one there would paint the arm's traffic onto the human's screen.
    let(:frontend) { RecordingChannel.new }

    before { allow(Lain::Provider::Ollama).to receive(:new).and_return(provider) }

    # The verdict was already recorded; the QUESTION's own round trip
    # was not, so a round of QA left zero request_sent records for the arm.
    it "records the round trip on the journal it was handed, digest and all" do
      described_class.tier(journal:).ask(**inputs).await

      sent = journal.grep(Lain::Telemetry::RequestSent)
      expect(sent.map(&:digest)).to eq([provider.last_request.digest])
      expect(sent.last.payload).to eq(provider.last_request.cache_payload)
    end

    it "puts nothing on the provider's live channel" do
      described_class.tier(journal:).ask(**inputs).await

      expect(frontend.events).to be_empty
    end

    it "leaves the attempt before the answer it bought" do
      described_class.tier(journal:).ask(**inputs).await

      expect(journal.map(&:class)).to eq([Lain::Telemetry::RequestSent, Lain::Telemetry::OracleAnswer])
    end

    # Journaling to Channel::Null is what an unjournaled caller gets, and it
    # must stay silent rather than raising for want of a destination.
    it "asks happily when no journal was handed to it at all" do
      expect { described_class.tier.ask(**inputs).await }.not_to raise_error
    end

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

    # The value is resolved by the chat's Backend, which is the rule under
    # test here: this judge runs its own small model, so the chat's runner
    # knobs would force a reload of it, and the chat's temperature would move
    # its verdicts.
    it "judges a qwen3-coder chat's release with none of that chat's sampler options" do
      chat = Lain::CLI::Backend.new(provider: "ollama", model: "qwen3-coder:30b", temperature: 0.2, num_batch: 2048)
      options = chat.tier_options(provider: "ollama", model: Lain::Provider::Ollama::DEFAULT_MODEL)

      described_class.tier(journal:, options:).ask(**inputs).await

      expect(provider.last_request.extra.keys).not_to include("num_batch", "temperature")
    end

    it "carries the options it is handed onto the request it journals" do
      described_class.tier(journal:, options: { "num_batch" => 2048 }).ask(**inputs).await

      expect(journal.grep(Lain::Telemetry::RequestSent).last.extra).to include("num_batch" => 2048)
    end
  end
end
