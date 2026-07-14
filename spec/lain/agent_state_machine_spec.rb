# frozen_string_literal: true

# The Agent's loop is a declared `state_machines` machine. These examples pin the
# two things that adoption buys over a hand-rolled `@state`: illegal moves raise,
# and every transition is announced to an injected listener. The gate-6 totality
# and public-surface examples live in `agent_spec.rb` and pass unchanged; this
# file covers the machine itself.
RSpec.describe Lain::Agent do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

  def agent(responses, **overrides)
    described_class.new(
      provider: Lain::Provider::Mock.new(responses: Array(responses)),
      toolset:,
      context:,
      **overrides
    )
  end

  # A listener that records every announced transition, standing in for the
  # Journal the seam exists for.
  recording_listener = Class.new do
    attr_reader :seen

    def initialize = @seen = []
    def on_transition(from:, to:, event:) = @seen << { from:, to:, event: }
  end

  describe "declared moves" do
    it "starts in awaiting_user without announcing a transition" do
      listener = recording_listener.new
      a = agent(text_response, transition_listener: listener)

      expect(a.state).to eq(:awaiting_user)
      expect(listener.seen).to be_empty
    end

    it "makes a legal transition on a named event" do
      a = agent(text_response)
      expect { a.__send__(:dispatch!) }.to change(a, :state).from(:awaiting_user).to(:awaiting_model)
    end

    it "raises on an illegal transition rather than silently accepting it" do
      a = agent(text_response) # fresh: awaiting_user
      expect { a.__send__(:use_tools!) }
        .to raise_error(StateMachines::InvalidTransition, /from :awaiting_user/)
    end

    it "raises when dispatching from a terminal state" do
      a = agent(text_response)
      a.ask("hi")
      expect(a).to be_done

      expect { a.__send__(:dispatch!) }
        .to raise_error(StateMachines::InvalidTransition, /from :done/)
    end
  end

  describe "every stop_reason lands where it did before adoption" do
    {
      end_turn: :done,
      stop_sequence: :done,
      max_tokens: :failed,
      refusal: :failed
    }.each do |stop_reason, final_state|
      it "settles #{final_state} on #{stop_reason}" do
        a = agent(text_response("x", stop_reason:))
        a.ask("hi")
        expect(a.state).to eq(final_state)
      end
    end

    it "fails on an unrecognized stop_reason, the enum's non-exhaustive case" do
      a = agent(Lain::Response.new(content: [], stop_reason: "coined_in_2099"))
      a.ask("hi")
      expect(a.state).to eq(:failed)
      expect(a.failure_reason).to match(/unrecognized/)
    end
  end

  describe "the transition listener" do
    it "fires with from/to/event for each move of a tool-using run" do
      listener = recording_listener.new
      a = agent([tool_response(["tu_1", "echo", { "text" => "x" }]), text_response],
                transition_listener: listener)
      a.ask("hi")

      expect(listener.seen).to eq(
        [
          { from: :awaiting_user, to: :awaiting_model, event: :dispatch },
          { from: :awaiting_model, to: :awaiting_tools, event: :use_tools },
          { from: :awaiting_tools, to: :awaiting_model, event: :dispatch },
          { from: :awaiting_model, to: :done, event: :complete }
        ]
      )
    end

    it "announces pause and re-dispatch on a paused turn" do
      listener = recording_listener.new
      a = agent([text_response("", stop_reason: :pause_turn), text_response("finished")],
                transition_listener: listener)
      a.ask("hi")

      events = listener.seen.map { |t| t[:event] }
      expect(events).to eq(%i[dispatch pause dispatch complete])
    end

    it "defaults to a harmless no-op when none is injected" do
      a = agent(text_response)
      expect { a.ask("hi") }.not_to raise_error
      expect(a).to be_done
    end
  end

  describe "reopening a settled loop" do
    it "continues the conversation when asked again after done" do
      a = agent([text_response("first"), text_response("second")])
      a.ask("hi")
      expect(a).to be_done

      response = a.ask("again")
      expect(response.text).to eq("second")
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
    end

    it "rewind reopens via a declared event, from any state" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "a" }]), text_response])
      a.ask("hi")

      expect { a.rewind(2) }.to change(a, :state).to(:awaiting_user)
    end
  end
end
