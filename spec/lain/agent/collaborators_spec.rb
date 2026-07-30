# frozen_string_literal: true

RSpec.describe Lain::Agent::Collaborators do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:provider) { Lain::Provider::Mock.new(responses: []) }

  def resolve(**) = described_class.new(toolset:, **)

  # An injected runner must be built over the SAME toolset, because its harvest
  # feeds the committed turn's causal_parents. See {#refuse_foreign_toolset}.
  def runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Mock.new, toolset:)

  describe "the injected style" do
    it "hands back the very objects it was given" do
      model_caller = Lain::Agent::ModelCaller.new(provider:)
      tool_runner = runner
      accounting = Lain::Agent::Accounting.new
      resolved = resolve(model_caller:, tool_runner:, accounting:)

      expect(resolved.model_caller).to be(model_caller)
      expect(resolved.tool_runner).to be(tool_runner)
      expect(resolved.accounting).to be(accounting)
    end

    it "needs no ingredient at all -- not even a provider" do
      resolved = resolve(model_caller: Lain::Agent::ModelCaller.new(provider:))

      expect(resolved.tool_runner).to be_a(Lain::Agent::ToolRunner)
      expect(resolved.accounting).to be_a(Lain::Agent::Accounting)
    end
  end

  describe "the ingredient style" do
    it "builds a ModelCaller over the given provider" do
      expect(resolve(provider:).model_caller.provider).to be(provider)
    end

    it "builds a ToolRunner whose handler is Live over the same toolset" do
      handler = resolve(provider:).tool_runner.instance_variable_get(:@handler)

      expect(handler).to be_a(Lain::Effect::Handler::Live)
      expect(handler.tool_named("echo")).to be(toolset.to_a.first)
    end

    it "builds an Accounting over the given journal" do
      journal = RecordingChannel.new
      accounting = resolve(provider:, journal:).accounting
      accounting.observe(Lain::Response.new(content: [], stop_reason: :end_turn), digest: "d")

      expect(journal.events.map(&:class)).to eq([Lain::Telemetry::TurnUsage])
    end

    it "demands a provider, because there is nothing to call without one" do
      expect { resolve }.to raise_error(ArgumentError, /provider/)
    end
  end

  # The clash rule is PER collaborator, so the two styles compose: an injected
  # ToolRunner beside a `provider:` says nothing contradictory. `toolset:` is
  # shared besides -- the Agent renders it and the ToolRunner harvests answered
  # questions from it -- so it is never exclusive to a collaborator either.
  it "mixes the two styles across different collaborators" do
    tool_runner = runner
    resolved = resolve(provider:, tool_runner:)

    expect(resolved.tool_runner).to be(tool_runner)
    expect(resolved.model_caller.provider).to be(provider)
  end

  describe "the toolset an injected ToolRunner harvests from" do
    # The default-built runner gets the Agent's toolset by construction; an
    # injected one is the caller's, and it decides the committed turn's
    # causal_parents. Same set or refused -- there is no silent third option.
    it "is required to be the Agent's own, so the committed digest cannot move" do
      foreign = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Mock.new)

      expect { resolve(provider:, tool_runner: foreign) }.to raise_error(ArgumentError, /toolset/)
    end

    it "is satisfied by the same Toolset object" do
      expect(resolve(provider:, tool_runner: runner).tool_runner.toolset).to be(toolset)
    end

    it "is what a default-built runner already gets" do
      expect(resolve(provider:).tool_runner.toolset).to be(toolset)
    end

    # This seam exists for duck-typed runners, so the gate has to answer a duck
    # that cannot be asked. A NoMethodError from inside the resolver would be a
    # crash where every neighbouring mistake gets a named refusal.
    it "is demanded of a runner stand-in too, by name rather than by NoMethodError" do
      mute = Class.new { def delivery(_response, context:) = { content: [], causal_parents: [context] } }.new

      expect { resolve(provider:, tool_runner: mute) }
        .to raise_error(ArgumentError, /tool_runner:.*#toolset/m)
    end
  end

  describe "keywords a caller never wrote" do
    it "refuses an ingredient the table does not carry, rather than dropping it" do
      expect { resolve(provider:, tool_middlewear: Lain::Middleware::Stack.new) }
        .to raise_error(ArgumentError, /unknown ingredient: tool_middlewear:/)
    end

    # The `.compact`-first bug this pins: a typo whose value happens to be nil
    # used to vanish before the vocabulary check ever saw it. The assertion names
    # the WHOLE refusal, not just the keyword, because `providr: was given as
    # nil` mentions the keyword too -- so a looser match would pass with the
    # vocabulary check back behind the compaction, or with the two refusals in
    # the other order. Both regressions are exactly what this example exists for.
    it "refuses a nil-valued typo as a typo, which no compaction may swallow first" do
      expect { resolve(provider:, providr: nil) }
        .to raise_error(ArgumentError, /unknown ingredient: providr:/)
    end

    it "refuses an explicit nil for a keyword it does know" do
      expect { resolve(provider: nil) }.to raise_error(ArgumentError, /provider.*nil/m)
    end

    it "names every explicit nil at once, so one round trip fixes them all" do
      expect { resolve(provider: nil, journal: nil) }
        .to raise_error(ArgumentError, /provider.*journal|journal.*provider/m)
    end
  end

  described_class::INGREDIENTS.each do |collaborator, ingredients|
    ingredients.each do |ingredient|
      it "refuses #{collaborator}: together with #{ingredient}:, naming both" do
        values = { model_caller: Lain::Agent::ModelCaller.new(provider:),
                   tool_runner: runner,
                   accounting: Lain::Agent::Accounting.new,
                   provider:, model_middleware: Lain::Middleware::Stack.new,
                   handler: Lain::Effect::Handler::Mock.new, tool_middleware: Lain::Middleware::Stack.new,
                   tool_observer: Lain::Agent::ToolRunner::Observer::Null.new, journal: RecordingChannel.new }

        expect { resolve(collaborator => values.fetch(collaborator), ingredient => values.fetch(ingredient)) }
          .to raise_error(ArgumentError, /#{collaborator}.*#{ingredient}/m)
      end
    end
  end
end
