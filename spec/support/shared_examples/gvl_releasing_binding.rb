# frozen_string_literal: true

# What a binding owes once its call runs with the lock between threads released. Restart
# bounding, slot overflow, raise propagation and wakeup handling live in the one loop under
# ext/lain/src/nogvl, so a binding is held to them here only as far as its own call reaches
# that loop; what its answer should be stays in its own spec.
#
# The including group provides, as lets:
#   work        a lambda making a releasing call, long enough to interrupt (about 0.1 s or more)
#   small_work  a lambda making a call under the binding's threshold, which must keep the lock
#   complete    a lambda saying whether a value is the whole answer of `work`
# and may override:
#   crowd_work / crowd_complete  a cheaper releasing call, for the 80 at once
#   settle (how long a call runs before it is interrupted), stop_bound, max_gap_share
RSpec.shared_examples "a GVL-releasing binding" do
  include GapShare

  let(:crowd_work) { work }
  let(:crowd_complete) { complete }
  let(:settle) { 0.05 }
  let(:stop_bound) { 0.1 }
  let(:max_gap_share) { 0.3 }

  def clock = Lain::RunClock::MONOTONIC

  # `work` is read before the thread starts, so building its input never lands inside the timed call.
  def working
    job = work
    Thread.new do
      Thread.current.report_on_exception = false
      job.call
    end
  end

  def interrupted_after_settling
    worker = working
    sleep settle
    expect(worker).to be_alive
    sent = clock.call
    yield worker
    clock.call - sent
  end

  it "lets the calling thread keep running while it works" do
    GC.start # a collection pause over the heap other examples left would count as one long gap
    worker = working
    share = longest_gap_share(worker)

    expect(worker.value).to satisfy("be the whole answer", &complete)
    expect(share).to be < max_gap_share
  end

  # Timed from the signal: a call holding the lock also keeps this thread's sleep from ending,
  # which the be_alive guard catches.
  it "stops soon after its thread is killed, rather than at the end of the call" do
    GC.start # a collection pause inside the window would count against the bound
    elapsed = interrupted_after_settling { |worker| worker.kill.join }

    expect(elapsed).to be < stop_bound
  end

  it "raises the interrupt's error rather than returning a partial answer" do
    GC.start
    failure = nil
    elapsed = interrupted_after_settling do |worker|
      worker.raise(IOError, "stopped")
      failure = begin
        worker.value
      rescue IOError => e
        e
      end
    end

    expect(failure).to have_attributes(class: IOError, message: "stopped")
    expect(elapsed).to be < stop_bound
  end

  it "answers the whole call when an interrupt that raises nothing lands mid-call" do
    answer = nil
    interrupted_after_settling do |worker|
      worker.wakeup
      answer = worker.value
    end

    expect(answer).to satisfy("be the whole answer", &complete)
  end

  it "still finishes under a stream of interrupts that raise nothing, since its restarts are bounded" do
    worker = working
    waker = Thread.new do
      while worker.alive?
        sleep 0.001
        worker.wakeup
      end
    rescue ThreadError
      nil
    end

    expect(worker.join(30)).to eq(worker)
    expect(worker.value).to satisfy("be the whole answer", &complete)
  ensure
    waker&.kill&.join
  end

  it "answers every call when more run at once than it has slots for" do
    job = crowd_work
    answers = Array.new(80) { Thread.new { job.call } }.map(&:value)

    expect(answers.uniq.size).to eq(1)
    expect(answers.first).to satisfy("be the whole crowd answer", &crowd_complete)
  end

  # Releasing hands the lock to a busy thread, and getting it back waits out that thread's time
  # slice, about 20 ms; the bound is loose for a loaded suite and well under a slice.
  it "keeps the lock for a small call, so a busy thread at the offload priority does not slow it" do
    busy = Thread.new do
      Thread.current.priority = Lain::Tool::Offload::PRIORITY
      loop { nil }
    end
    sleep 0.05
    small_work.call
    started = clock.call
    20.times { small_work.call }

    expect((clock.call - started) / 20).to be < 0.008
  ensure
    busy&.kill&.join
  end
end
