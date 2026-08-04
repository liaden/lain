# frozen_string_literal: true

RSpec.describe Lain::Review::Marks do
  # The ordinary modification hunk, matching hunk_spec.rb's shape so the two
  # specs read the same fixtures the same way.
  def hunk(path: "lib/lain/agent.rb", old_start: 10, old_count: 3, new_start: 10, new_count: 3,
           heading: "def call", lines: ["   @store = store", "-  audit!(input)", "+  audit!(validated)", "   run!"])
    Lain::Review::Hunk.new(path:, old_start:, old_count:, new_start:, new_count:, heading:, lines:)
  end

  # The narrowest duck this card assumes of T7's not-yet-built Changeset:
  # `#base_ref` (the resolved base revision, matching T3/T5's own naming) and
  # `#hunks` (every Hunk in the WHOLE, unfiltered changeset -- across every
  # commit, not collapsed into one base..head diff, which is what makes "4
  # hunks total across 2 commits" a countable thing at all).
  def changeset(base_ref:, hunks:)
    Data.define(:base_ref, :hunks).new(base_ref:, hunks:)
  end

  def marked(base_ref, pairs)
    pairs.reduce(described_class.new(base_ref:)) { |marks, (key, state)| marks.mark(key, state) }
  end

  describe "deriving a file's tri-state indicator" do
    it "is :partial when only some of a file's hunks are marked" do
      hunks = [hunk(lines: ["+a"]), hunk(lines: ["+b"]), hunk(lines: ["+c"])]
      keys = Lain::Review::Hunk.keys(hunks)
      cs = changeset(base_ref: "base1", hunks:)
      marks = marked("base1", [[keys[0], "reviewed"], [keys[1], "reviewed"]])

      expect(marks.state_for(hunks.first.path, cs)).to eq(:partial)
    end

    it "is :reviewed when every hunk across every commit is marked" do
      commit1 = [hunk(lines: ["+a"]), hunk(lines: ["+b"])]
      commit2 = [hunk(lines: ["+c"]), hunk(lines: ["+d"])]
      all = commit1 + commit2
      keys = Lain::Review::Hunk.keys(all)
      cs = changeset(base_ref: "base1", hunks: all)
      marks = marked("base1", keys.map { |key| [key, "reviewed"] })

      expect(marks.state_for(all.first.path, cs)).to eq(:reviewed)
    end

    it "is :unreviewed when none of a file's hunks are marked" do
      hunks = [hunk(lines: ["+a"])]
      cs = changeset(base_ref: "base1", hunks:)
      marks = described_class.new(base_ref: "base1")

      expect(marks.state_for(hunks.first.path, cs)).to eq(:unreviewed)
    end

    it "answers every file's state in one pass" do
      a = hunk(path: "a.rb", lines: ["+a"])
      b = hunk(path: "b.rb", lines: ["+b"])
      keys = Lain::Review::Hunk.keys([a, b])
      cs = changeset(base_ref: "base1", hunks: [a, b])
      marks = marked("base1", [[keys[0], "reviewed"]])

      expect(marks.states(cs)).to eq({ "a.rb" => :reviewed, "b.rb" => :unreviewed })
    end

    # Fix round, Schneeman: #states already tells "absent" from "present, none
    # marked" apart -- the key is simply missing. #state_for collapsed both to
    # :unreviewed, which reads a renamed or mistyped path as real unreviewed
    # work. A path the changeset never named gets a named refusal instead.
    it "refuses to answer state_for a path the changeset never named, rather than reading it as unreviewed" do
      hunks = [hunk(path: "a.rb", lines: ["+a"])]
      cs = changeset(base_ref: "base1", hunks:)
      marks = described_class.new(base_ref: "base1")

      expect { marks.state_for("missing.rb", cs) }
        .to raise_error(described_class::UnknownPath, /missing\.rb/)
    end

    it "refuses a nil path the same way, rather than reading it as unreviewed" do
      hunks = [hunk(path: "a.rb", lines: ["+a"])]
      cs = changeset(base_ref: "base1", hunks:)
      marks = described_class.new(base_ref: "base1")

      expect { marks.state_for(nil, cs) }.to raise_error(described_class::UnknownPath)
    end

    # Linus: the derivation must not restate MARK_STATES' spelling as a bare
    # literal. REVIEWED is named once and pinned a genuine member, matching
    # Anchor::SIDES' derivation from Review::SIDES.
    it "names its 'reviewed' comparison against MARK_STATES rather than restating the spelling" do
      expect(Lain::Review::MARK_STATES).to include(described_class::REVIEWED)
    end

    # Evans: tri_state(0, 0) read as :reviewed before this fix -- unreachable
    # through the public API (group_by never yields an empty group), but
    # answered dishonestly if it ever were. Grey-box on purpose, the same
    # justification hunk_spec.rb gives its own `.send(:key, ...)` example.
    it "answers :unreviewed for zero-of-zero, kept honest even though group_by never produces it" do
      marks = described_class.new(base_ref: "base1")

      expect(marks.send(:tri_state, 0, 0)).to eq(:unreviewed)
    end
  end

  describe "reconciliation" do
    it "drops a mark whose hunk key is no longer in the changeset" do
      present = hunk(lines: ["+a"])
      present_key = Lain::Review::Hunk.keys([present]).first
      absent_key = Lain::Review::Hunk.keys([hunk(lines: ["+z"])]).first
      cs = changeset(base_ref: "base1", hunks: [present])
      marks = marked("base1", [[present_key, "reviewed"], [absent_key, "reviewed"]])

      reconciled = marks.reconcile(cs)

      expect(reconciled.to_h).to eq(present_key => "reviewed")
    end

    it "keeps marks for hunks in commits a presented scope hides, when given the UNFILTERED changeset" do
      commit1 = [hunk(lines: ["+a"])]
      commit2 = [hunk(lines: ["+b"])]
      commit3 = [hunk(lines: ["+c"])]
      full = commit1 + commit2 + commit3
      keys = Lain::Review::Hunk.keys(full)
      full_changeset = changeset(base_ref: "base1", hunks: full)
      marks = marked("base1", keys.map { |key| [key, "reviewed"] })

      reconciled = marks.reconcile(full_changeset)

      expect(reconciled.to_h.keys).to match_array(keys)
    end

    # The escalation trigger, pinned directly: a `scope:` keyword here would be
    # the flag tuicr#247 warns against reinventing. There is no parameter to
    # hand one through.
    it "has no scope parameter -- a caller cannot filter what reconcile sees" do
      expect(described_class.instance_method(:reconcile).parameters).to eq([%i[req changeset]])
    end
  end

  describe "base revision scoping" do
    it "refuses to reconcile against a changeset from a different base" do
      hunks = [hunk(lines: ["+a"])]
      key = Lain::Review::Hunk.keys(hunks).first
      marks = marked("base-v1", [[key, "reviewed"]])
      other_base = changeset(base_ref: "base-v2", hunks:)

      expect { marks.reconcile(other_base) }
        .to raise_error(described_class::BaseMismatch, /base-v1/)
    end

    it "refuses to derive state against a changeset from a different base" do
      hunks = [hunk(lines: ["+a"])]
      marks = described_class.new(base_ref: "base-v1")
      other_base = changeset(base_ref: "base-v2", hunks:)

      expect { marks.state_for(hunks.first.path, other_base) }
        .to raise_error(described_class::BaseMismatch)
      expect { marks.states(other_base) }
        .to raise_error(described_class::BaseMismatch)
    end

    # The hazard T2's key alone cannot close: a BASE-side edit slides duplicate
    # #2 onto duplicate #1's former old-side span. Old and new side shift
    # together under a base move, so the span stays self-consistent while
    # naming the wrong hunk -- proved here as a literal string collision, not
    # asserted on faith.
    it "closes the hazard where a base-side edit slides duplicate #2 onto duplicate #1's former span" do
      dup1_old = hunk(old_start: 10, old_count: 3, new_start: 10, new_count: 3, lines: ["+dup"])
      dup2_old = hunk(old_start: 90, old_count: 3, new_start: 90, new_count: 3, lines: ["+dup"])
      key1_old = Lain::Review::Hunk.keys([dup1_old, dup2_old]).first
      marks = marked("base-v1", [[key1_old, "reviewed"]])

      # Under the new base, the original #1 is gone; the surviving duplicate
      # now sits exactly on #1's old span, beside a second duplicate that
      # keeps the fallback span-qualified rather than content-keyed.
      dup2_new = hunk(old_start: 10, old_count: 3, new_start: 10, new_count: 3, lines: ["+dup"])
      dup3_new = hunk(old_start: 200, old_count: 3, new_start: 200, new_count: 3, lines: ["+dup"])
      keys_new = Lain::Review::Hunk.keys([dup2_new, dup3_new])

      # The collision is real: same string, wrong hunk -- dup2_new was never reviewed.
      expect(keys_new.first).to eq(key1_old)

      new_changeset = changeset(base_ref: "base-v2", hunks: [dup2_new, dup3_new])

      expect { marks.reconcile(new_changeset) }.to raise_error(described_class::BaseMismatch)
      expect { marks.state_for(dup2_new.path, new_changeset) }.to raise_error(described_class::BaseMismatch)
    end

    it "reconciles cleanly when the base is unchanged" do
      hunks = [hunk(lines: ["+a"])]
      key = Lain::Review::Hunk.keys(hunks).first
      marks = marked("base-v1", [[key, "reviewed"]])
      same_base = changeset(base_ref: "base-v1", hunks:)

      expect(marks.reconcile(same_base).to_h).to eq(key => "reviewed")
    end

    # Fix round 2, Jeremy: base_ref now normalizes through Wire.token on
    # construction, but the comparison in assert_same_base! used to compare
    # the normalized `base_ref` against `changeset.base_ref` RAW -- so the
    # identical revision, spelled as a Symbol on the changeset side, read as a
    # mismatch. It failed closed (no stale mark was ever honoured), but the
    # message lied about a base change that never happened.
    it "does not raise when the same base is merely spelled differently (Symbol vs. String)" do
      hunks = [hunk(lines: ["+a"])]
      key = Lain::Review::Hunk.keys(hunks).first
      marks = marked(:deadbeef, [[key, "reviewed"]])
      same_base_as_symbol = changeset(base_ref: :deadbeef, hunks:)

      expect { marks.states(same_base_as_symbol) }.not_to raise_error
      expect(marks.reconcile(same_base_as_symbol).to_h).to eq(key => "reviewed")
    end

    it "does not raise when the same base carries different wire whitespace" do
      hunks = [hunk(lines: ["+a"])]
      marks = described_class.new(base_ref: " abc ")
      padded_same_base = changeset(base_ref: "abc", hunks:)

      expect { marks.states(padded_same_base) }.not_to raise_error
    end
  end

  describe "construction" do
    it "refuses a mark state outside MARK_STATES" do
      expect { described_class.new(base_ref: "base1").mark("hunk-content-v1:abc", "partial") }
        .to raise_error(described_class::UnknownState, /partial/)
    end

    it "is deeply frozen" do
      marks = marked("base1", [["hunk-content-v1:abc", "reviewed"]])

      expect(marks).to be_deeply_frozen
    end

    # Fix round, Evans/Schneeman: base_ref used to fail with a raw
    # `NoMethodError: undefined method 'to_str'`, naming neither the class nor
    # the field, while `state` already goes through Wire.token and accepts a
    # Symbol -- two disciplines for two String fields on the same object. Both
    # now go through Wire.token, and a blank one is refused BY NAME.
    it "accepts a Symbol base_ref, matching the wire-tolerant discipline #mark's state already uses" do
      marks = described_class.new(base_ref: :deadbeef)

      expect(marks.base_ref).to eq("deadbeef")
    end

    it "refuses a nil or blank base_ref by name, not with a raw NoMethodError" do
      expect { described_class.new(base_ref: nil) }
        .to raise_error(described_class::InvalidBaseRef, /base_ref/)
      expect { described_class.new(base_ref: "") }
        .to raise_error(described_class::InvalidBaseRef, /base_ref/)
    end

    # Aaron: @marks is already frozen at construction, so a defensive #dup on
    # every #to_h call is a pure allocation buying nothing -- the freeze alone
    # is what stops a caller mutating the live set, and it is already there.
    it "answers #to_h without allocating a new Hash, since the mark set is already frozen" do
      marks = marked("base1", [["hunk-content-v1:abc", "reviewed"]])

      expect(marks.to_h).to equal(marks.to_h)
    end
  end
end
