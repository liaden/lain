# frozen_string_literal: true

require "async"
require "stringio"

# What {Approval::Queue#settle} does to `@parked` when SEVERAL pendings are
# parked at once. The load-bearing example is the third one, and the property it
# owns is not an arity claim: *the answered pending, and only it, leaves the
# parked list, by identity, promptly, with oldest-first order preserved.* Three
# defects red it and nothing else in the suite: `settle` dropping the oldest
# entry (`@parked.shift`), {Queue#each} yielding a stale memoized snapshot, and
# `settle` never removing the settled pending at all. Every surface that renders
# the queue between one answer and the next reads exactly that list.
#
# The first two examples are NOT the point, and a reader deciding what this file
# is for should know it. `spec/lain/notify_spec.rb` ALREADY measures both of
# them at arity three on a real queue -- `:1078` asserts `count == 3` with all
# three `decided? == false`, and `:1113` denies `tu_0` and asserts the other two
# stay undecided -- both landed in 21176738, the same commit as the
# `ParkedApprovals` fixture reused here, with `:1096` correlating three
# notifications back to three distinct pendings. Examples 1 and 2 below catch no
# defect those three do not; they are kept because they are microseconds each
# and they state the queue's own claim in the queue's own directory, where
# somebody changing `queue.rb` will look. Deleting them would cost no coverage.
#
# SCOPE BOUNDARY, deliberately not closed here: these examples observe `@parked`
# only. A queue that admits three pendings to `@parked` but never
# `@arrivals.enqueue`s them passes every example in this file AND all three in
# notify_spec -- three pendings park, are addressable, decide independently --
# while {Frontend::ApprovalPolicy#watch}, the one sanctioned consumer, is handed
# nothing and no human is ever asked. `approval_spec.rb` covers arrival at arity
# one and `queue_concurrency_spec.rb` at two; nothing covers it at three. Off
# limits here by instruction (arrival lives in `#dequeue`'s
# one-arrival-one-waiter FIFO, and draining it here would consume what a surface
# is owed); raised as its own follow-up.
#
# The reactor dance is spec/support/parked_approvals.rb, not a fresh one:
# `ParkedApprovals.park` already generalises queue_concurrency_spec's
# Sync/async/spin-until shape to N against a REAL queue, and it SPINS until
# `queue.count == count` before yielding -- so a build that quietly parks one
# pending instead of three times out loudly here rather than going green on a
# single-pending measurement.
#
# Proven RED with two probes, both applied to the real queue and reverted: the
# read-yield-write lost update in `admit` (which reds all three examples on the
# park timeout, and reds notify_spec too), and a SHARED promise across `Pending`
# instances (example 1 green, 2 and 3 red -- and notify_spec:1113 reds on it as
# well, which is why that probe does not distinguish this file from what already
# existed). What distinguishes this file is the third example alone.
RSpec.describe "Approval::Queue with three pendings parked at once" do
  let(:journal_io) { StringIO.new }

  # Long enough that the queue's own fail-closed window is never the thing
  # under test here -- these examples answer in microseconds.
  let(:queue) { Lain::Approval::Queue.new(journal: Lain::Journal.new(io: journal_io), timeout: 5) }

  it "holds three individually addressable pendings at once" do
    ParkedApprovals.park(queue, count: 3) do |parked|
      expect(parked.count).to eq(3)

      addressed = %w[tu_0 tu_1 tu_2].map { |id| parked.find { |pending| pending.tool_use_id == id } }
      # Found BEFORE dereferenced: `find` answers nil for an absent id, and a
      # nil that reaches the line below reports a NoMethodError instead of the
      # missing pending it actually means.
      expect(addressed).to all(be_a(Lain::Approval::Queue::Pending))
      # An aliasing queue that answered all three lookups with one pending
      # reports %w[tu_0 tu_0 tu_0] here -- the diff names the defect.
      expect(addressed.map { |pending| pending.input.fetch("command") }).to eq(%w[tu_0 tu_1 tu_2])
      expect(addressed.map(&:decided?)).to eq([false, false, false])
    end
  end

  # `decided?` is {Promise#resolved?} on the pending's OWN promise, set only by
  # {Pending#decide}. That is the predicate this scenario needs and `decision`
  # / `approved?` are not sufficient for: a pending nobody has looked at is
  # indistinguishable from one nobody has answered by any field a surface
  # reads, but it cannot have a resolved promise -- only a decide resolves one.
  it "decides the pending that was answered and leaves the other two undecided" do
    ParkedApprovals.park(queue, count: 3) do |parked|
      answered = parked.find { |pending| pending.tool_use_id == "tu_1" }
      others = parked.reject { |pending| pending.tool_use_id == "tu_1" }

      expect(answered.approve(surface: "spec")).to be(true)

      expect(answered).to be_decided
      expect(answered).to be_approved
      expect(others.map(&:decided?)).to eq([false, false])
      expect(others.map(&:decision)).to eq([nil, nil])
    end
  end

  # This file's reason to exist. {Queue#settle}'s `@parked.delete(pending)`
  # removes the answered pending by IDENTITY -- {Pending} defines no `==`, and
  # that absence is load-bearing rather than incidental: `Array#delete` removes
  # EVERY match, so a plausible coarse `==` (same tool implies equal) wipes all
  # three at the first answer. Naming the survivors is what makes the deletion
  # the answered one's rather than merely a smaller list, and the order pins the
  # "oldest first" contract {Queue#each} documents for the surfaces that render
  # it.
  it "drops only the answered pending from the parked list" do
    ParkedApprovals.park(queue, count: 3) do |parked|
      parked.find { |pending| pending.tool_use_id == "tu_1" }.approve(surface: "spec")

      expect(settled_down_to(parked, 2)).to be(true), -> { unsettled_message(parked) }

      expect(parked.map(&:tool_use_id)).to eq(%w[tu_0 tu_2])
      expect(parked.map(&:decided?)).to eq([false, false])
    end
  end

  # Bounded HERE, not by ParkedApprovals' timeout. The fixture's `timeout:`
  # documents itself as the wait for every pending to be ADMITTED, which
  # licenses a later refactor to move its `yield` outside `with_timeout` -- and
  # a spin relying on someone else's undertaking then runs to the spec
  # watchdog's 30s budget instead of failing in two. Answers rather than raises,
  # so the caller can say what a timeout MEANT.
  def settled_down_to(queue, size)
    Async::Task.current.with_timeout(2) do
      Async::Task.current.sleep(0.001) until queue.count == size
      true
    end
  rescue Async::TimeoutError
    false
  end

  # Every defect this example catches surfaces as the same silence -- a spin
  # that never reaches two -- so the message has to carry the diagnosis a diff
  # would otherwise have carried.
  def unsettled_message(queue)
    "settle did not leave exactly the two unanswered pendings parked; @parked holds " \
      "#{queue.map(&:tool_use_id).inspect}. Fewer than two means the delete removed more than " \
      "the answered pending (Array#delete removes EVERY match, so a Pending that gained a " \
      "coarse `==` wipes them all); three unchanged means settle never removed it, or #each " \
      "is yielding a stale snapshot."
  end
end
