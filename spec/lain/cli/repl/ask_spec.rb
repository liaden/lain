# frozen_string_literal: true

require "stringio"

# The unit half of T16's Ruby rule. `repl_spec.rb` drives the whole thing --
# a real Agent, a real Conductor, a real Async task -- and measures what reaches
# the human's stderr, which is the only place the defect was ever visible. This
# file states the contract that makes that possible, on its own subject: which
# outcomes come back as VALUES, which still raise, and what a refusal costs the
# session record.
RSpec.describe Lain::CLI::Repl::Ask do
  let(:timeline) { instance_double(Lain::Timeline, head_digest: "sha-head") }
  let(:agent) { instance_double(Lain::Agent, timeline:) }
  let(:tty) { instance_double(Lain::Frontend::TTY, render_error: nil) }
  let(:chronicle) { instance_double(Lain::CLI::Chronicle::Null, catch_up: nil, interrupted: nil) }
  let(:ask) { described_class.new(agent:, tty:, chronicle:) }
  let(:response) { Lain::Response.new(content: [{ "type" => "text", "text" => "hi" }], stop_reason: :end_turn) }

  describe "#attempt" do
    it "answers what the agent answered when the ask settles" do
      allow(agent).to receive(:ask).with("go").and_return(response)

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
      expect(agent).to have_received(:ask).with("go")
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

    # B5's ordering, kept with the code that moved: a raise can land AFTER
    # commits, so the committed turns are journaled BEFORE the stop is recorded
    # and `interrupted` then names the true last commit rather than an earlier
    # head.
    it "journals the committed turns before anchoring the interruption" do
      ask.settle(Lain::Error.new("torn"))

      expect(chronicle).to have_received(:catch_up).with(timeline).ordered
      expect(chronicle).to have_received(:interrupted).with(head: "sha-head").ordered
    end

    it "leaves the session record alone when nothing was refused" do
      ask.settle(response)

      expect(chronicle).not_to have_received(:interrupted)
    end
  end
end
