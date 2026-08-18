# frozen_string_literal: true

RSpec.describe Lain::Review::Surface::Null do
  subject(:surface) { described_class.new }

  # Discarding every message is this surface's whole point, so it declines
  # the transcript law EXPLICITLY -- a declaration, not a silent omission
  # (spec/support/shared_examples/review_surface.rb's class doc, #3a).
  it_behaves_like "a review surface", transcript: :no_observation_channel

  describe "the whole port, accepted and discarded" do
    it "returns nil from #present" do
      expect(surface.present(Object.new, scope: :cumulative)).to be_nil
    end

    it "returns nil from #annotate" do
      expect(surface.annotate(Object.new, "looks fine", kind: :note)).to be_nil
    end

    it "returns nil from #mark" do
      expect(surface.mark("hunk-content-v1:deadbeef", :reviewed)).to be_nil
    end

    it "returns nil from #thread" do
      expect(surface.thread(Object.new)).to be_nil
    end

    it "returns nil from #verdict" do
      expect(surface.verdict).to be_nil
    end

    it "returns nil from #refuse" do
      expect(surface.refuse("not today")).to be_nil
    end
  end

  describe ".check!" do
    it "accepts a real Null surface" do
      expect { Lain::Review::Surface.check!(surface) }.not_to raise_error
    end

    it "raises Incomplete naming :verdict when a candidate answers every message but that one" do
      # Every OTHER message uses the port's REAL signature -- a generic
      # `(*, **)` stub would ALSO fail the shape check `check!` now runs
      # (fix round item 2), so this candidate's only defect would stop being
      # "missing #verdict" and become six unrelated "wrong shape" defects,
      # which is not what this example is meant to pin.
      incomplete = Class.new do
        def present(changeset, scope:) = nil # rubocop:disable Lint/UnusedMethodArgument
        def annotate(anchor, text, kind:) = nil # rubocop:disable Lint/UnusedMethodArgument
        def mark(hunk_key, state) = nil # rubocop:disable Lint/UnusedMethodArgument
        def thread(anchor) = nil # rubocop:disable Lint/UnusedMethodArgument
        def settle(verdict) = nil # rubocop:disable Lint/UnusedMethodArgument
        def refuse(message) = nil # rubocop:disable Lint/UnusedMethodArgument
      end.new

      # `/verdict/` alone matches ANY Incomplete -- every message ends "...
      # the full present, annotate, mark, thread, verdict, settle, refuse
      # port", so
      # the word appears whether or not verdict itself is what's missing.
      # `/does not answer verdict/` is the clause that only appears when
      # verdict specifically is absent.
      expect { Lain::Review::Surface.check!(incomplete) }
        .to raise_error(Lain::Review::Surface::Incomplete, /does not answer verdict/)
    end
  end

  # `.check!`'s sibling at the port, and the two examples that hold its WIDTH
  # where it is. `.acknowledge` swallows deliberately -- a verdict is already
  # durable before it runs, so an adapter that breaks the port's
  # decline-in-words promise must not come back as a refusal of a verdict that
  # landed.
  #
  # Driven HERE, beside `.check!`, for `.check!`'s reason: both are port-level
  # module functions belonging to no adapter, and this file already owns the
  # port's own laws because there is no `surface_spec.rb`.
  describe ".acknowledge" do
    it "absorbs an adapter that raises instead of declining in words" do
      broken = Class.new(described_class) do
        def settle(_verdict) = raise(IOError, "the editor's socket is gone")
      end.new

      expect { @answer = Lain::Review::Surface.acknowledge(broken, "approve") }.not_to raise_error
      expect(@answer).to be_nil
    end

    # `StandardError` and not `Exception` -- the one narrowing decision inside a
    # method built to swallow, and the one a later hand is most likely to undo,
    # because widening something that already swallows on purpose reads like
    # more of the same rather than like a new decision.
    #
    # Swallowing `SystemExit`/`Interrupt` too would make a review hand-back
    # uninterruptible and a spec run unstoppable, and CLAUDE.md records the
    # shape that leaves: a `SystemExit` inside an example truncates the run
    # while still reporting "0 failures", which under `parallel_rspec` is
    # indistinguishable from an OOM kill. `Lint/RescueException` says so too,
    # but a cop is one inline disable from silent.
    it "lets a SystemExit and an Interrupt straight through, which rescuing Exception would not" do
      %w[SystemExit Interrupt].each do |escaping|
        aborting = Class.new(described_class) do
          define_method(:settle) { |_verdict| raise(Object.const_get(escaping)) }
        end.new

        expect { Lain::Review::Surface.acknowledge(aborting, "approve") }
          .to raise_error(Object.const_get(escaping))
      end
    end
  end
end
