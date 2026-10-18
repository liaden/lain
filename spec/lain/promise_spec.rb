# frozen_string_literal: true

require "async"
require "open3"

# The process-local coordination primitive ask_human resolves: a thin,
# domain-named wrapper over Async::Promise. Awaiting parks the FIBER, not the
# reactor -- the property the whole promise model rests on -- and a second
# resolve fails LOUDLY in our own vocabulary rather than being silently
# ignored, as Async::Promise ignores it.
RSpec.describe Lain::Promise do
  it "starts unresolved and resolves to a value that #await returns" do
    Sync do
      promise = described_class.new

      expect(promise.resolved?).to be(false)
      promise.resolve("hello")

      expect(promise.resolved?).to be(true)
      expect(promise.await).to eq("hello")
    end
  end

  it "returns immediately from #await when already resolved (the degenerate sync case)" do
    Sync do
      promise = described_class.new
      promise.resolve(42)

      expect(promise.await).to eq(42)
    end
  end

  it "parks the awaiting fiber while a concurrent fiber makes progress" do
    Sync do |task|
      log = []
      promise = described_class.new

      waiter = task.async do
        log << :awaiting
        log << [:got, promise.await]
      end
      worker = task.async { log << :worker_ran }
      worker.wait

      # The waiter is parked on the unresolved promise; the worker ran to
      # completion meanwhile -- the reactor was never blocked.
      expect(log).to eq(%i[awaiting worker_ran])
      expect(promise.resolved?).to be(false)

      promise.resolve("done")
      waiter.wait
      expect(log.last).to eq([:got, "done"])
    end
  end

  it "raises a loud domain error on a second resolve and keeps the first value" do
    Sync do
      promise = described_class.new
      promise.resolve(:first)

      expect { promise.resolve(:second) }.to raise_error(Lain::Promise::AlreadyResolved)
      expect(promise.await).to eq(:first)
    end
  end

  it "keeps the awaiter parked until a later fiber resolves, then returns the value rather than nil" do
    Sync do |task|
      promise = described_class.new
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      task.async do
        task.sleep(0.05)
        promise.resolve(:late)
      end

      expect(promise.await).to eq(:late)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.04
    end
  end

  it "lets exactly one of two racing threads resolve" do
    # Holds each caller of resolved? open until the other has also looked (or a
    # bounded wait), so an unguarded check-then-resolve loses a value every time.
    slow = Class.new(Async::Promise) do
      def resolved?
        seen = super
        @looks = (@looks || 0) + 1
        sleep(0.01) until @looks >= 2 || (@waited = (@waited || 0) + 1) > 20
        seen
      end
    end.new
    allow(Async::Promise).to receive(:new).and_return(slow)
    promise = described_class.new
    gate = Queue.new
    threads = Array.new(2) do |i|
      Thread.new do
        gate.pop
        promise.resolve(i)
        :resolved
      rescue Lain::Promise::AlreadyResolved
        :refused
      end
    end
    2.times { gate << :go }

    expect(threads.map(&:value).sort).to eq(%i[refused resolved])
  end

  it "builds without an Async::Variable deprecation warning under -W" do
    root = File.expand_path("../..", __dir__)
    _out, err, status = Open3.capture3(RbConfig.ruby, "-W", "-I", File.join(root, "lib"),
                                       "-e", 'require "lain"; Lain::Promise.new', chdir: root)

    expect(status).to be_success, err
    expect(err).not_to include("Async::Variable")
  end
end
