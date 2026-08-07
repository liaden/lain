# frozen_string_literal: true

require "async"
require "stringio"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module QueueSurfaceSpecSupport
  Effect = Struct.new(:name, :input, :tool_use_id)

  # A concrete surface over the template, judging everything and approving
  # everything -- the minimum that shows the template's own machinery running.
  class Everything < Lain::Approval::QueueSurface
    SURFACE = "spec_surface"

    attr_reader :asked

    def initialize(**)
      super
      @asked = []
    end

    def judges?(_outstanding) = true

    private

    def answer_for(pending)
      @asked << pending
      :approve
    end

    def settle(pending, answer)
      pending.approve(surface: SURFACE) if answer == :approve
    end
  end

  # A surface whose sweep raises every pass, for the fiber-survival guard.
  class Broken < Lain::Approval::QueueSurface
    SURFACE = "broken_surface"

    def judges?(_outstanding) = raise(NoMethodError, "undefined method 'any?' for nil")
  end
end

# The template {AutoSurface} and {SecretSurface} share, and -- the reason it
# exists -- the PARTITION between them. Two LLM surfaces over one queue is only
# safe if their filters are disjoint AND total, and that is a property of the
# two answers taken together, which neither surface's own spec can state.
RSpec.describe Lain::Approval::QueueSurface do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:faults) { [] }

  def effect = QueueSurfaceSpecSupport::Effect.new("read", { "path" => "/repo/.env" }, "tu_1")

  def regions = Lain::Sensitivity::Regions.detect("API_KEY=sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE\n")

  def carrying = Lain::Approval::Queue::Outstanding.new(path: "/repo/.env", regions:)

  def none = Lain::Approval::Queue::Outstanding::NONE

  def parked(surface, outstanding:)
    queue = Lain::Approval::Queue.new(journal:, timeout: 0.05)
    Sync do |task|
      gated = task.async { queue.adjudicate(effect, nil, outstanding:) }
      task.with_timeout(1) { queue.dequeue }
      surface.sweep(queue)
      task.with_timeout(2) { gated.wait }
    ensure
      gated&.stop
    end
  end

  describe "the abstract contract" do
    it "refuses to be used directly: a surface that judges nothing in particular is not a surface" do
      expect { described_class.new.judges?(none) }.to raise_error(NotImplementedError)
    end

    it "runs the shared machinery for a concrete subclass" do
      surface = QueueSurfaceSpecSupport::Everything.new
      settled = parked(surface, outstanding: none)

      expect(surface.asked.size).to eq(1)
      expect(settled.surface).to eq(QueueSurfaceSpecSupport::Everything::SURFACE)
    end
  end

  # S1. The property neither surface could assert about itself.
  describe "the partition between the two shipped surfaces" do
    let(:auto) { Lain::Approval::AutoSurface.new(role_spawn: ->(*) { Lain::Tool::Result.ok("DEFER") }) }
    let(:secret) do
      Lain::Approval::SecretSurface.new(oracle: instance_double(Lain::Oracle::Model))
    end

    it "sends every possible pending to EXACTLY ONE of them -- disjoint, and total" do
      [carrying, none].each do |outstanding|
        expect(auto.judges?(outstanding) ^ secret.judges?(outstanding))
          .to be(true), "both or neither claimed #{outstanding.inspect}"
      end
    end

    it "splits them the right way round, so the exclusive-or above is not two surfaces swapped" do
      expect([auto.judges?(none), secret.judges?(carrying)]).to eq([true, true])
    end

    # The same property one level up, over real parked Pendings rather than the
    # values: `mine?` also folds in decided? and the seen-set, and a partition
    # that held for `judges?` and not for `mine?` would be no partition at all.
    it "holds for the pendings themselves, not only for what they carry" do
      queue = Lain::Approval::Queue.new(journal:, timeout: 0.5)
      Sync do |task|
        a = task.async { queue.adjudicate(effect, nil, outstanding: carrying) }
        b = task.async { queue.adjudicate(effect, nil, outstanding: none) }
        task.with_timeout(1) { [queue.dequeue, queue.dequeue] }

        queue.each { |pending| expect(auto.mine?(pending) ^ secret.mine?(pending)).to be(true) }
      ensure
        [a, b].each(&:stop)
      end
    end
  end

  # S2. A pending whose `outstanding:` was explicitly nil used to raise inside
  # `mine?`, killing the watch fiber for the rest of the session -- so a LATER
  # well-formed pending was never asked about, with nothing journaled and the
  # queue still looking healthy. Two answers, and both are pinned: the Pending
  # never holds a nil, and a sweep that raises anyway does not take the fiber.
  describe "a surface fiber that meets something it cannot judge" do
    it "is never handed a nil outstanding, because the Pending resolves one to the Null value" do
      settled = parked(QueueSurfaceSpecSupport::Everything.new, outstanding: nil)

      expect(settled.outstanding).to be(Lain::Approval::Queue::Outstanding::NONE)
      expect(settled.surface).to eq(QueueSurfaceSpecSupport::Everything::SURFACE)
    end

    it "keeps watching after a sweep that raised, and journals the fault once rather than per poll" do
      queue = Lain::Approval::Queue.new(journal:, timeout: 5)
      surface = QueueSurfaceSpecSupport::Broken.new(poll_interval: 0.005, journal: faults)

      Sync do |task|
        watcher = task.async { surface.watch(queue) }
        gated = task.async { queue.adjudicate(effect, nil, outstanding: carrying) }
        # Long enough for many polls; the fiber must still be alive at the end.
        task.sleep(0.1)
        expect(watcher).to be_running
        gated.stop
        watcher.stop
      end

      expect(faults.size).to eq(1)
      expect(faults.first).to include("type" => described_class::FAULT_TYPE,
                                      "surface" => QueueSurfaceSpecSupport::Broken::SURFACE)
    end
  end
end
