# frozen_string_literal: true

# Gesture resolution, without an editor. Until this object existed the only
# coverage that a cursor line resolves to the row a human is looking at ran
# through a real headless nvim, per example, in two view specs that each had
# their own ring -- so the rule was tested twice, slowly, and neither test
# could see the other's edge cases.
#
# What is pinned here is the STAMP, which is a correctness property rather than
# a tidiness one: a line names a POSITION, these buffers' positions move under
# the human, and both values a mis-resolved keypress could answer are legal, so
# nothing downstream can notice the wrong one. The owners below are plain
# strings; what a real view hangs off a line (a question digest, a parked
# approval) is deliberately not this object's business.
RSpec.describe Lain::Frontend::Neovim::ListView do
  subject(:renderings) { described_class.new(held: 8) }

  # Three rows, one owner each, as a one-line-per-item list renders.
  def render(*owners) = renderings.remember(owners:)

  describe "a gesture on a current rendering resolves to its row" do
    it "answers the row the line names" do
      generation = render("a", "b", "c")

      expect(renderings.at(2, generation:).owner).to eq("b")
    end

    it "says the line is owned rather than leaving the caller to read a nil" do
      generation = render("a", "b", "c")
      resolved = renderings.at(2, generation:)

      expect(resolved).to be_owned
      expect(resolved).not_to be_unshown
    end

    # One entry per LINE is the whole of the multi-line rule: an item that
    # wraps owns every line it drew, and position arithmetic over ITEMS would
    # answer the neighbour from the second line on.
    it "resolves every line of an item that wrapped to that same item" do
      generation = render("a", "a", "a", "b")

      expect((1..4).map { |line| renderings.at(line, generation:).owner }).to eq(%w[a a a b])
    end

    # The stamp a rendering was given is the one to send to the editor, and the
    # newest is what a freshly stamped buffer carries.
    it "hands back the stamp it minted, which is also the newest it reports" do
      generation = render("a")

      expect(generation).to eq(renderings.generation)
    end
  end

  describe "a gesture carrying an old generation is refused as stale" do
    # The refusal is BY NAME rather than by a nearest-match: an aged-out
    # rendering resolving to whatever the ring still has is exactly the
    # neighbour-answering defect the stamp closes.
    it "refuses a stamp this ring has aged out" do
      stale = render("a")
      8.times { render("b") }

      resolved = renderings.at(1, generation: stale)

      expect(resolved).to be_unshown
      expect(resolved.owner).to be_nil
    end

    it "refuses a stamp nothing was ever rendered at" do
      render("a")

      expect(renderings.at(1, generation: 9_999)).to be_unshown
    end

    # A buffer that was never stamped sends nothing back, which is not a row
    # and must not read as one.
    it "refuses a gesture carrying no stamp at all" do
      render("a")

      expect(renderings.at(1, generation: nil)).to be_unshown
    end

    # THE RACE, stated as an example rather than as a comment. Two renders in
    # flight leave two stamps live, and each gesture is answered by the
    # rendering it was actually made on -- the later render does not overwrite
    # the earlier one's answer, and the earlier one does not reach forward.
    it "answers each of two racing renderings from its own rows, never from the other's" do
      older = render("a", "b")
      newer = render("b")

      expect(renderings.at(1, generation: older).owner).to eq("a")
      expect(renderings.at(1, generation: newer).owner).to eq("b")
    end

    # The counterfactual for the ring being a ring: a rendering still held
    # answers even after later ones have landed on top of it.
    it "keeps answering a rendering the ring still holds" do
      stale = render("a")
      7.times { render("b") }

      expect(renderings.at(1, generation: stale).owner).to eq("a")
    end
  end

  describe "a gesture on a line that is not a row is refused" do
    it "refuses a line past the end of the list" do
      generation = render("a", "b", "c")
      resolved = renderings.at(9, generation:)

      # `:unowned` has no predicate of its own (see {Resolution}), so it is
      # stated as the pair that distinguishes it from a stale stamp: the
      # rendering IS still held, and the line simply owns nothing in it.
      expect(resolved).not_to be_owned
      expect(resolved).not_to be_unshown
      expect(resolved.owner).to be_nil
    end

    # Line 0 is the one nvim never reports, and `owners[-1]` is the LAST row --
    # so an unguarded seam answers the newest row for a cursor that does not
    # exist.
    it "refuses line 0 rather than answering the last row" do
      generation = render("a", "b", "c")

      expect(renderings.at(0, generation:)).not_to be_owned
    end

    it "refuses a negative line for line 0's reason" do
      generation = render("a", "b", "c")

      expect(renderings.at(-1, generation:)).not_to be_owned
    end

    # A line that crossed msgpack as something other than an Integer owns
    # nothing rather than raising on the consumer's fiber -- the editor-command
    # path has no caller left to report to.
    it "refuses a line that is not a number rather than raising" do
      generation = render("a", "b", "c")

      expect(renderings.at("not a line", generation:)).not_to be_owned
    end

    # An empty-state placeholder is REMEMBERED like any other rendering -- a
    # human still holding it gets "no row there" rather than "that buffer never
    # existed".
    it "holds a rendering that owns no lines at all, and refuses every line of it" do
      generation = renderings.remember(owners: [])

      expect(renderings.at(1, generation:)).not_to be_owned
    end
  end

  describe "only the last N renderings are remembered" do
    it "refuses the first of ten renderings through a ring that holds eight" do
      first = render("a")
      9.times { render("b") }

      expect(renderings.at(1, generation: first)).to be_unshown
    end

    # The bound is the caller's, not this object's: lain://inbox holds sixteen
    # and lain://approval eight, and nothing known reconciles the two.
    it "holds as many as its owner asked for" do
      wider = described_class.new(held: 16)
      first = wider.remember(owners: ["a"])
      15.times { wider.remember(owners: ["b"]) }

      expect(wider.at(1, generation: first).owner).to eq("a")
    end
  end

  describe "a rendering the editor refused" do
    # A stamp nothing ever wrote onto a buffer is one no gesture can cite, and
    # keeping it would let a burst of refused posts evict every rendering a
    # human IS looking at.
    it "stops resolving once it is forgotten" do
      generation = render("a")
      renderings.forget(generation)

      expect(renderings.at(1, generation:)).to be_unshown
    end

    it "answers nothing, so a caller can report the refusal with it" do
      expect(renderings.forget(render("a"))).to be_nil
    end

    it "leaves every other rendering alone" do
      kept = render("a")
      dropped = render("b")
      renderings.forget(dropped)

      expect(renderings.at(1, generation: kept).owner).to eq("a")
    end

    # THE COUNTER IS NOT REWOUND. A reused stamp would name two different
    # renderings, which is the one thing the stamp exists to make impossible --
    # so a forgotten rendering costs its number permanently.
    it "never mints a forgotten rendering's stamp again" do
      forgotten = render("a")
      renderings.forget(forgotten)

      expect(render("b")).to be > forgotten
    end

    # The ring is a bound on what is HELD, so eight refused posts must not cost
    # the eight renderings a human can still be looking at.
    it "gives its ring slot back, so refused posts do not evict live renderings" do
      live = render("a")
      8.times { renderings.forget(renderings.remember(owners: ["b"])) }

      expect(renderings.at(1, generation: live).owner).to eq("a")
    end
  end
end
