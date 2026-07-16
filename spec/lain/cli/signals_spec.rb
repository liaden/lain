# frozen_string_literal: true

require "timeout"

# T22: the OS-signal installer that drives a Shutdown coordinator. INT/TERM/QUIT
# traps whose bodies are PUSH-ONLY -- each does exactly one `sink.signal(symbol)`,
# the single async-signal-safe pipe write Shutdown::Ingress documents. The sink is
# swappable (a fresh coordinator per ask), and prior handlers are restored on
# teardown. Real signals are delivered to self, exactly as the T20 SIGUSR2 example
# does -- safe because OUR trap is installed for the delivery's whole duration, so
# the default action (which would kill the runner for TERM/QUIT) never runs.
RSpec.describe Lain::CLI::Signals do
  # Records the symbols routed to it -- the coordinator's #signal duck, but with
  # no pipe behind it so an example needs no reactor.
  let(:sink) do
    Class.new do
      def initialize = @received = []
      attr_reader :received

      def signal(name) = @received << name
    end.new
  end

  # Save and restore the three real handlers around every example, independent of
  # the code under test, so a bug in install/uninstall can never leave the runner
  # with a broken INT/TERM/QUIT.
  around do |example|
    saved = described_class::MAP.keys.to_h { |name| [name, Signal.trap(name, "DEFAULT")] }
    example.run
  ensure
    saved.each { |name, handler| Signal.trap(name, handler) }
  end

  describe "the signal map" do
    it "maps INT/TERM/QUIT to the coordinator inputs, INT/TERM graceful and QUIT immediate" do
      expect(described_class::MAP).to eq("INT" => :sigint, "TERM" => :sigterm, "QUIT" => :sigquit)
    end
  end

  describe "delivering a real signal while installed" do
    it "routes each of INT/TERM/QUIT to the current sink as its mapped symbol" do
      signals = described_class.new(sink:).install

      %w[INT TERM QUIT].each { |name| Process.kill(name, Process.pid) }
      # The VM runs deferred trap bodies at the next checkpoint; a bounded spin
      # keeps the example deterministic without a bare sleep.
      Timeout.timeout(2) { sleep(0.001) until sink.received.size == 3 }

      expect(sink.received).to contain_exactly(:sigint, :sigterm, :sigquit)
    ensure
      signals.uninstall
    end
  end

  describe "a swappable sink (a fresh coordinator per ask)" do
    it "routes to whichever sink is currently in force" do
      other = sink.class.new
      signals = described_class.new(sink:).install

      signals.route(other)
      Process.kill("INT", Process.pid)
      Timeout.timeout(2) { sleep(0.001) until other.received.size == 1 }

      expect(other.received).to eq([:sigint])
      expect(sink.received).to be_empty
    ensure
      signals.uninstall
    end
  end

  describe "restoring prior handlers" do
    it "puts back exactly the handler that was installed before" do
      sentinel = ->(_signo) {}
      Signal.trap("INT", sentinel)

      signals = described_class.new(sink:).install
      restored = signals.uninstall

      expect(restored).to be(signals)
      # Trapping again returns the handler currently in force -- proof the
      # sentinel is back. Re-set it to the default so the assertion leaves no
      # trap behind for the around hook to reason about.
      expect(Signal.trap("INT", "DEFAULT")).to be(sentinel)
    end
  end

  describe "the block form" do
    it "installs for the block and restores afterward, even when the block raises" do
      sentinel = ->(_signo) {}
      Signal.trap("TERM", sentinel)

      expect do
        described_class.guarding(sink:) { raise "boom" }
      end.to raise_error("boom")

      expect(Signal.trap("TERM", "DEFAULT")).to be(sentinel)
    end

    it "yields the installer so the caller can swap the sink per ask" do
      described_class.guarding(sink:) do |signals|
        expect(signals).to be_a(described_class)
        signals.route(sink)
        Process.kill("QUIT", Process.pid)
        Timeout.timeout(2) { sleep(0.001) until sink.received.size == 1 }
      end

      expect(sink.received).to eq([:sigquit])
    end
  end

  describe "the default sink" do
    it "drops signals silently when nothing is routed (between asks, no coordinator)" do
      signals = described_class.new.install

      expect { Process.kill("INT", Process.pid) }.not_to raise_error
      Timeout.timeout(2) { sleep(0.01) }
    ensure
      signals.uninstall
    end
  end
end
