# frozen_string_literal: true

require "stringio"

# The unit half of the value-path rule. `repl_spec.rb` drives the whole thing --
# a real Agent, a real Conductor, a real Async task -- and measures what reaches
# the human's stderr, which is the only place the defect was ever visible. This
# file states the contract that makes that possible, on its own subject: which
# outcomes come back as VALUES, which still raise, and what a refusal costs the
# session record.
RSpec.describe Lain::CLI::Repl::Ask do
  let(:timeline) { instance_double(Lain::Timeline, head_digest: "sha-head") }
  let(:agent) { instance_double(Lain::Agent, timeline:) }
  let(:tty) { instance_double(Lain::Frontend::TTY, render_error: nil, render_warning: nil) }
  let(:chronicle) { instance_double(Lain::CLI::Chronicle::Null, catch_up: nil, interrupted: nil, replaced: nil) }
  let(:ask) { described_class.new(agent:, tty:, chronicle:) }
  let(:response) { Lain::Response.new(content: [{ "type" => "text", "text" => "hi" }], stop_reason: :end_turn) }

  # The shape a stall ACTUALLY reaches an ask in. {Provider::HTTP::Streaming::
  # StalledStreamError} is not a {Lain::Error} and never escapes the provider as
  # itself: `ErrorWrapping#wrapping_errors` re-raises it as the backend's own
  # APIError, so the stall survives only as the `cause`. A spec that handed the
  # raw error in would pin a path production cannot take.
  let(:stall) { Lain::Provider::HTTP::Streaming::StalledStreamError.new("no chunk for 30.0s") }
  let(:wrapped_stall) do
    raise Lain::Provider::Anthropic::APIError.new("no chunk for 30.0s"), cause: stall
  rescue Lain::Provider::Anthropic::APIError => e
    e
  end

  describe "#attempt" do
    it "answers what the agent answered when the ask settles" do
      allow(agent).to receive(:ask).with("go", on_fold: anything).and_return(response)

      expect(ask.attempt("go")).to equal(response)
    end

    # THE WHOLE POINT. A raise here dies inside `Conductor#supervise`'s
    # `Async::Task`, which reports the harness's own decision to halt as
    # `Task may have ended with unhandled exception.` plus its backtrace.
    it "answers a harness refusal as a value rather than raising it" do
      refusal = Lain::Agent::Budget::Exceeded.new("loop ran 25 iterations, ceiling is 25")
      allow(agent).to receive(:ask).and_raise(refusal)

      expect(ask.attempt("go")).to equal(refusal)
    end

    # The other direction, and the reason the rescue is narrow: a bug is not a
    # refusal, and a session that swallows one is worse than a noisy one.
    it "lets anything outside the harness's own vocabulary keep raising" do
      allow(agent).to receive(:ask).and_raise(TypeError, "genuinely broken")

      expect { ask.attempt("go") }.to raise_error(TypeError, "genuinely broken")
      expect(agent).to have_received(:ask).with("go", on_fold: anything)
    end

    # The Agent folds a stranded prompt into the new one; the record and the
    # human are the chat's to tell. The written chain retreats to the stranded
    # turn's parent BEFORE the folded turn can be caught up, or the scribe
    # would refuse a chain that no longer extends what it wrote.
    describe "over a stranded prompt" do
      let(:stranded) do
        Lain::Timeline.empty(store: Lain::Store.new).commit(role: :user, content: [{ "type" => "text", "text" => "a" }])
                      .commit(role: :assistant, content: [{ "type" => "text", "text" => "b" }])
                      .commit(role: :user, content: [{ "type" => "text", "text" => "earlier" }])
      end
      let(:folded) do
        stranded.rewind(1).commit(role: :user, content: [{ "type" => "text", "text" => "earlier" },
                                                         { "type" => "text", "text" => "go" }])
      end

      def folding(outcome)
        allow(agent).to receive(:ask) do |_text, on_fold:|
          on_fold.call(stranded, folded)
          outcome.is_a?(Exception) ? raise(outcome) : outcome
        end
      end

      # The folded turn is durable before the request can reach the wire: a
      # crash while it is out resumes onto a turn still carrying the earlier
      # text, never onto the parent with both prompts gone.
      it "journals the stranded chain, then replaces it with the folded turn in the record" do
        folding(response)

        ask.attempt("go")

        expect(chronicle).to have_received(:catch_up).with(stranded).ordered
        expect(chronicle).to have_received(:replaced).with(to: stranded.head.parent, with: folded).ordered
      end

      # True for every head that folds -- a failure, a stop, a failed resend, a
      # /rewind onto an answered prompt -- and whether or not the request then
      # reaches a model; and it names the way out.
      it "tells the human the prompt at the head goes with this one, and how to leave it out" do
        folding(response)

        ask.attempt("go")

        expect(tty).to have_received(:render_warning).with(%r{no answer on this chain.*carries it too.*/rewind 1})
      end

      # The Agent stepped back to the stranded head, while the record holds the
      # folded turn: the record follows it back before the stop is recorded.
      it "replaces the folded turn with the stranded one in the record when the Agent withdraws the ask" do
        unsent = Lain::Provider::Ollama::PreWireError.new("connection refused").withdrawn!
        folding(unsent)

        ask.settle(ask.attempt("go"))

        expect(chronicle).to have_received(:replaced).with(to: stranded.head.parent, with: stranded).ordered
        expect(chronicle).to have_received(:interrupted).with(head: "sha-head", reason: :transport).ordered
      end

      it "leaves the folded turn in the record when the failure came after the wire" do
        folding(Lain::Provider::Ollama::APIError.new("connection reset"))

        ask.settle(ask.attempt("go"))

        expect(chronicle).not_to have_received(:replaced).with(to: stranded.head.parent, with: stranded)
      end
    end
  end

  describe "#settle" do
    it "passes a response through untouched" do
      expect(ask.settle(response)).to equal(response)
    end

    it "renders a refusal as its own message and delivers nothing over it" do
      ask.settle(Lain::Agent::Budget::Exceeded.new("spent 200 tokens, ceiling is 50"))

      expect(tty).to have_received(:render_error).with("spent 200 tokens, ceiling is 50")
    end

    it "answers nil for a refusal, so the caller has nothing to deliver" do
      expect(ask.settle(Lain::Error.new("torn"))).to be_nil
    end

    # This ordering, kept with the code that moved: a raise can land AFTER
    # commits, so the committed turns are journaled BEFORE the stop is recorded
    # and `interrupted` then names the true last commit rather than an earlier
    # head.
    it "journals the committed turns before anchoring the interruption" do
      ask.settle(Lain::Error.new("torn"))

      expect(chronicle).to have_received(:catch_up).with(timeline).ordered
      expect(chronicle).to have_received(:interrupted).with(head: "sha-head", reason: :torn).ordered
    end

    it "leaves the session record alone when nothing was refused" do
      ask.settle(response)

      expect(chronicle).not_to have_received(:interrupted)
    end

    # Triage has to be doable from the file: "the model went quiet" and
    # "the harness stopped the run" are different failures with different
    # owners, and before this they were one indistinguishable record.
    it "names a provider stall rather than a generic interruption" do
      ask.settle(wrapped_stall)

      expect(chronicle).to have_received(:interrupted).with(head: "sha-head", reason: :stalled_stream)
    end

    it "says why by type: a ceiling, a refusal, a stop, a transport failure, or torn" do
      over_window = Lain::Middleware::RequestBudget::OverWindow.new("refused", prompt_tokens: 9, window_tokens: 8,
                                                                               source: "ollama")
      { Lain::Agent::Budget::Exceeded.new("loop ran 25 iterations, ceiling is 25") => :ceiling,
        over_window => :over_window,
        Lain::Stopped.new("stopped") => :stopped,
        Lain::Provider::Ollama::PreWireError.new("connection refused") => :transport,
        Lain::Error.new("no known kind") => :torn }.each do |error, reason|
        ask.settle(error)

        expect(chronicle).to have_received(:interrupted).with(head: "sha-head", reason:)
      end
    end
  end
end
