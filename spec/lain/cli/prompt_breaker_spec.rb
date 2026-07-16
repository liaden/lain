# frozen_string_literal: true

require "timeout"

# T22: the parked-prompt breakout. Reline owns the terminal in a blocking read
# while the human is at the `you>` prompt, so a signal there cannot render an
# interactive countdown until the readline is broken out of first (the ruled UX,
# probe-verified: Reline propagates an exception raised into its thread and runs
# its own terminal-restoring ensure). PromptBreaker is the trap-safe seam that
# does the breaking: {Signals} routes prompt-time signals to it, its `#signal` is
# the same one-pipe-write as the coordinator's, and a side thread turns the byte
# into a {Break} raised into the prompt thread.
RSpec.describe Lain::CLI::PromptBreaker do
  it "breaks the prompt thread out of a blocking read, carrying the signal input" do
    broken = Thread::Queue.new
    victim = Thread.new do
      sleep # stands in for Reline.readline's blocking read
    rescue described_class::Break => e
      broken << e.input
    end
    Timeout.timeout(2) { sleep(0.005) until victim.status == "sleep" }

    breaker = described_class.new(main: victim)
    breaker.signal(:sigterm)

    expect(Timeout.timeout(2) { broken.pop }).to eq(:sigterm)
  ensure
    breaker&.dispose
    victim&.join
  end

  it "signal is a push-only pipe write, safe to call after dispose (a late trap)" do
    breaker = described_class.new(main: Thread.current)
    breaker.dispose

    expect { breaker.signal(:sigint) }.not_to raise_error
  end

  it "dispose ends the watcher thread cleanly, raising nothing into the prompt thread" do
    breaker = described_class.new(main: Thread.current)

    expect { breaker.dispose }.not_to raise_error
  end
end
