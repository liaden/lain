# frozen_string_literal: true

# F26: nothing in lain owned a provider's CAPACITY, so the harness put two
# requests on a one-slot server and read the silence it caused itself as a dead
# stream. {Provider::Admission} is that missing concept -- a gate per RESOLVED
# ENDPOINT, entered around a round trip.
#
# The last example is not an ordinary unit test, and it is the reason this object
# is hand-rolled rather than an `Async::Semaphore`. It was a standalone probe
# during T1's escalation, where it measured three failures at once: the
# `FiberError: fiber called across threads` lands in the RELEASING fiber (the
# agent's turn, killed by an unrelated resend), the waiting thread stays parked
# after a 5s join, and `Semaphore#release` decrements before it resumes, so the
# gate silently stops gating. `Provider#complete` really is reached from a second
# OS thread on the `--nvim` path (`agent.rb:234-236`), so that example pins the
# property the whole design exists for.
RSpec.describe Lain::Provider::Admission do
  # A fresh endpoint per example: `.for` memoises per endpoint in a process-global
  # registry, so sharing a name would leak one example's width into the next.
  let(:endpoint) { "http://localhost:11434/#{SecureRandom.hex(4)}" }

  describe "#enter" do
    it "makes a second caller wait rather than overlap the first" do
      admission = described_class.new(endpoint:, width: 1)
      events = []

      Sync do |task|
        first = task.async do
          admission.enter do
            events << :first_in
            task.sleep(0.1)
            events << :first_out
          end
        end
        task.sleep(0.02)
        second = task.async { admission.enter { events << :second_in } }
        [first, second].each(&:wait)
      end

      expect(events).to eq(%i[first_in first_out second_in])
    end

    it "releases when the block raises, so the next caller is admitted" do
      admission = described_class.new(endpoint:, width: 1)
      admitted = false

      Sync do
        expect { admission.enter { raise "boom" } }.to raise_error(RuntimeError, "boom")
        admission.enter { admitted = true }
      end

      expect(admitted).to be(true)
    end

    # Async::Stop is < Exception, not < StandardError, so only an `ensure` covers
    # it (isolation/worker_handoff.rb:27-34 writes the same lesson out).
    it "releases when the holding fiber is cancelled rather than raising" do
      admission = described_class.new(endpoint:, width: 1)
      admitted = false

      Sync do |task|
        holder = task.async { admission.enter { task.sleep(10) } }
        task.sleep(0.02)
        holder.stop
        task.sleep(0.02)
        admission.enter { admitted = true }
      end

      expect(admitted).to be(true)
    end

    it "bounds the wait and refuses with a message naming the endpoint and the deadline" do
      admission = described_class.new(endpoint:, width: 1, deadline: 0.05)
      refusal = nil

      Sync do |task|
        holder = task.async { admission.enter { task.sleep(5) } }
        task.sleep(0.02)
        begin
          admission.enter { nil }
        rescue Lain::Provider::Admission::Busy => e
          refusal = e
        end
        holder.stop
      end

      expect(refusal).to be_a(Lain::Provider::Admission::Busy)
      expect(refusal.message).to include(endpoint).and include("0.05")
    end

    it "reports the wait to the caller, and reports none to the caller that never waited" do
      admission = described_class.new(endpoint:, width: 1)
      waits = {}

      Sync do |task|
        first = task.async do
          admission.enter do |waited|
            waits[:first] = waited
            task.sleep(0.2)
          end
        end
        task.sleep(0.02)
        second = task.async { admission.enter { |waited| waits[:second] = waited } }
        [first, second].each(&:wait)
      end

      expect(waits[:first]).to eq(0.0)
      expect(waits[:second]).to be >= 0.1
    end
  end

  describe "#try_enter" do
    it "turns a caller away immediately rather than queueing it, without running its block" do
      admission = described_class.new(endpoint:, width: 1)
      ran = false
      answer = nil

      Sync do |task|
        holder = task.async { admission.enter { task.sleep(5) } }
        task.sleep(0.02)
        answer = admission.try_enter { ran = true }
        holder.stop
      end

      expect(answer).to be(described_class::REFUSED)
      expect(ran).to be(false)
    end

    it "admits when the endpoint is free, and returns the block's value" do
      admission = described_class.new(endpoint:, width: 1)

      expect(Sync { admission.try_enter { :summarised } }).to eq(:summarised)
    end
  end

  describe ".for" do
    it "does not make two different resolved endpoints contend" do
      other = "http://localhost:11435/#{SecureRandom.hex(4)}"
      admitted = false

      Sync do |task|
        holder = task.async { described_class.for(endpoint:).enter { task.sleep(5) } }
        task.sleep(0.02)
        described_class.for(endpoint: other).enter { admitted = true }
        holder.stop
      end

      expect(admitted).to be(true)
    end

    it "returns the same admission for the same endpoint" do
      expect(described_class.for(endpoint:)).to be(described_class.for(endpoint:))
    end

    # The documented escape hatch for a session admission has wedged; the house
    # pattern for an env-only off switch is provider/http/configuration.rb:127-131.
    it "admits everyone concurrently when LAIN_PROVIDER_CONCURRENCY is 0" do
      inside = 0
      peak = 0

      with_env("LAIN_PROVIDER_CONCURRENCY" => "0") do
        admission = described_class.for(endpoint:)
        expect(admission).to be_a(described_class::Null)

        Sync do |task|
          Array.new(3) do
            task.async do
              admission.enter do
                inside += 1
                peak = [peak, inside].max
                task.sleep(0.05)
                inside -= 1
              end
            end
          end.each(&:wait)
        end
      end

      expect(peak).to eq(3)
    end

    # THE BLOCKER the panel found. `-1` passes `Integer()`, so `@count < @width`
    # is `0 < -1` -- false with NOTHING in flight -- and every caller polls the
    # full deadline before raising. It is also the exact idiom someone reaches
    # for meaning "no limit", so the failure mode is a hung session produced by
    # a user trying to turn the feature OFF. Format was validated; domain was not.
    it "refuses a negative width rather than building a permanently shut gate" do
      with_env("LAIN_PROVIDER_CONCURRENCY" => "-1") do
        expect { described_class.for(endpoint:) }
          .to raise_error(Lain::Error, /LAIN_PROVIDER_CONCURRENCY/)
      end
    end

    it "names the value in the refusal, the way a non-numeric one is named" do
      with_env("LAIN_PROVIDER_CONCURRENCY" => "-4") do
        expect { described_class.for(endpoint:) }.to raise_error(Lain::Error, /"-4"/)
      end
    end
  end

  describe "a width that could never admit anyone" do
    # The sibling hole: `.for` routes 0 to Null, but a direct construction does
    # not, so `new(width: 0)` is the same shut gate by another door.
    it "refuses a zero width at construction" do
      expect { described_class.new(endpoint:, width: 0) }
        .to raise_error(Lain::Error, /width/)
    end

    it "refuses a negative width at construction" do
      expect { described_class.new(endpoint:, width: -1) }
        .to raise_error(Lain::Error, /width/)
    end
  end

  describe ".reset!" do
    # The spec used to mint a random endpoint per example to dodge cross-example
    # leakage -- a fixture working around a missing affordance. This is the
    # affordance: the registry pins the env at an endpoint's FIRST resolution,
    # so re-reading it needs an explicit clear.
    it "drops the memoised admissions, so the env is read afresh" do
      before_reset = described_class.for(endpoint:)
      described_class.reset!

      expect(described_class.for(endpoint:)).not_to be(before_reset)
    end

    it "lets a later env change take effect for an endpoint already resolved" do
      expect(described_class.for(endpoint:)).to be_a(described_class)

      described_class.reset!
      with_env("LAIN_PROVIDER_CONCURRENCY" => "0") do
        expect(described_class.for(endpoint:)).to be_a(described_class::Null)
      end
    end
  end

  describe described_class::Null do
    # A Null Object may do nothing; it may not LIE. T3's journal reads this.
    it "reports the callers actually inside it, rather than a flat zero" do
      admission = described_class.new(endpoint: "http://unbounded.example")
      seen = nil

      Sync { admission.enter { seen = admission.in_flight } }

      expect(seen).to eq(1)
      expect(admission.in_flight).to eq(0)
    end

    it "reports them from try_enter too, and unwinds when the block raises" do
      admission = described_class.new(endpoint: "http://unbounded.example")
      seen = nil

      Sync do
        admission.try_enter { seen = admission.in_flight }
        expect { admission.enter { raise "boom" } }.to raise_error(RuntimeError)
      end

      expect(seen).to eq(1)
      expect(admission.in_flight).to eq(0)
    end
  end

  # THE cross-thread example. `Provider#complete` is reached from the Neovim
  # resend-worker thread (repl.rb:135 -> neovim.rb:351 -> resend_bridge.rb:156 ->
  # agent.rb:240's `Sync`, which spins a SECOND reactor because there is none to
  # join) while the eager oracle, span summarizer and window probes run on the
  # conductor's. An Async::Semaphore fails every assertion below.
  describe "two reactors on two threads" do
    it "gates them without corrupting itself, wedging a waiter, or raising into the holder" do
      admission = described_class.new(endpoint:, width: 1)
      events = Queue.new
      errors = Queue.new
      held = Queue.new
      second_waited = nil

      holder = Thread.new do
        Sync do
          admission.enter do
            events << :holder_in
            held << :held
            sleep(0.15)
            events << :holder_out
          end
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        errors << e
      end

      held.pop
      waiter = Thread.new do
        Sync do
          admission.enter do |waited|
            second_waited = waited
            events << :waiter_in
          end
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        errors << e
      end

      expect([holder, waiter].map { |t| t.join(5) }).to all(be_truthy) # nothing wedged
      expect(errors.size).to eq(0)
      expect(Array.new(events.size) { events.pop }).to eq(%i[holder_in holder_out waiter_in])
      expect(second_waited).to be_positive # it really was gated, not waved through
      expect(Sync { admission.try_enter { :free } }).to eq(:free) # and the gate is not stuck held
    end
  end
end
