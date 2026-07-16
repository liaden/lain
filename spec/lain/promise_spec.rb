# frozen_string_literal: true

require "async"

# The process-local coordination primitive ask_human (OM-4) resolves: a thin,
# domain-named wrapper over Async::Variable. Awaiting parks the FIBER, not the
# reactor -- the property the whole promise model rests on -- and a second
# resolve fails LOUDLY in our own vocabulary rather than with Async::Variable's
# incidental FrozenError.
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

  it "raises a loud domain error on a second resolve, not FrozenError" do
    Sync do
      promise = described_class.new
      promise.resolve(:first)

      expect { promise.resolve(:second) }.to raise_error(Lain::Promise::AlreadyResolved)
    end
  end
end
