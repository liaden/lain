# frozen_string_literal: true

RSpec.describe Lain::Review::Surface::Null do
  subject(:surface) { described_class.new }

  it_behaves_like "a review surface"

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
      # "missing #verdict" and become five unrelated "wrong shape" defects,
      # which is not what this example is meant to pin.
      incomplete = Class.new do
        def present(changeset, scope:) = nil # rubocop:disable Lint/UnusedMethodArgument
        def annotate(anchor, text, kind:) = nil # rubocop:disable Lint/UnusedMethodArgument
        def mark(hunk_key, state) = nil # rubocop:disable Lint/UnusedMethodArgument
        def thread(anchor) = nil # rubocop:disable Lint/UnusedMethodArgument
        def refuse(message) = nil # rubocop:disable Lint/UnusedMethodArgument
      end.new

      # `/verdict/` alone matches ANY Incomplete -- every message ends "...
      # the full present, annotate, mark, thread, verdict, refuse port", so
      # the word appears whether or not verdict itself is what's missing.
      # `/does not answer verdict/` is the clause that only appears when
      # verdict specifically is absent.
      expect { Lain::Review::Surface.check!(incomplete) }
        .to raise_error(Lain::Review::Surface::Incomplete, /does not answer verdict/)
    end
  end
end
