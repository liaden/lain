# frozen_string_literal: true

# The module itself owns exactly one thing: the `keep_last` rule. It sat in
# triplicate -- Head, Boundary, and a Source that applied it by BUILDING a
# throwaway Head -- and three copies of a refusal is three chances for one of
# them to relax. These are the examples that would catch that.
RSpec.describe Lain::Compaction do
  describe ".validate_keep_last" do
    it "answers the value coerced, so a consumer holds a number and not whatever it was handed" do
      expect(described_class.validate_keep_last("3")).to eq(3)
    end

    # A keep_last of 0 makes `messages[0...0]` and `messages.last(0)` both
    # empty, so a derivation replaces the ENTIRE history with a summary of
    # nothing while the head reports nothing droppable.
    it "refuses zero, naming the value" do
      expect { described_class.validate_keep_last(0) }
        .to raise_error(ArgumentError, "keep_last must be positive, got 0")
    end

    # A negative one slices happily here and dies as `negative array size`
    # inside `#call`, which is inside `Context#render`.
    it "refuses a negative, naming the value" do
      expect { described_class.validate_keep_last(-1) }
        .to raise_error(ArgumentError, "keep_last must be positive, got -1")
    end

    it "refuses a String it cannot read, rather than comparing it" do
      expect { described_class.validate_keep_last("several") }.to raise_error(ArgumentError, /invalid value/)
    end

    # `Integer()`'s own refusal, passed through rather than reclassified: it names
    # the value AND its type, which a uniform ArgumentError would not.
    it "lets Integer() refuse a value it will not convert at all" do
      expect { described_class.validate_keep_last(nil) }.to raise_error(TypeError)
      expect { described_class.validate_keep_last([]) }.to raise_error(TypeError)
    end
  end

  # Every door that consults the rule, asked the same two questions: the drift
  # this extraction closes is invisible in a spec that only asks one of them, and
  # the exact message is the assertion because a door quietly relaxing to a
  # different wording is the same defect as one relaxing the rule.
  #
  # THREE doors, not four. {Head} takes a keep_last but is not a door -- it builds
  # a {Boundary} as its first statement, so the refusal fires there. An example
  # aimed at "Head's door" passes whether or not Head validates anything, which is
  # a row that measures nothing; Head's own refusal is pinned behaviourally in
  # `head_spec.rb`.
  describe "the doors that consult the rule" do
    def degenerate = [0, -1]

    def refuses_both
      degenerate.each do |bad|
        expect { yield bad }.to raise_error(ArgumentError, "keep_last must be positive, got #{bad}")
      end
    end

    it "refuses both degenerate values at Boundary's door, in the module's own words" do
      refuses_both { |bad| Lain::Compaction::Boundary.new(messages: [], keep_last: bad) }
    end

    it "refuses both degenerate values at Context::Compact's door, in the module's own words" do
      refuses_both { |bad| Lain::Context::Compact.new(threshold: 1, keep_last: bad, summarizer: ->(_) { "s" }) }
    end

    # At WIRING time, which is the whole reason this door exists: the live source
    # would otherwise take the number into a derivation and raise mid-turn.
    it "refuses both degenerate values at Source's door, in the module's own words" do
      refuses_both do |bad|
        Lain::Compaction::Source.new(need: Lain::Compaction::Need.new(byte_threshold: 1),
                                     cold: Lain::Compaction::Cold.new(cache_profile: { ttl: 300 }),
                                     hard_cap: 1, keep_last: bad)
      end
    end
  end
end
