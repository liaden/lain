# frozen_string_literal: true

# Deliberately OUTSIDE spec/support/: spec_helper glob-requires
# `spec/support/**/*.rb` as configuration, and RSpec's own discovery matches
# `spec/**/*_spec.rb` via `load` -- which does not consult $LOADED_FEATURES,
# so the earlier `require` dedupes nothing. A `_spec.rb` inside the support
# glob is therefore registered TWICE (once by the glob's require, once by
# discovery's load) and every example runs and is counted twice. This file
# tests the matchers defined under spec/support/matchers/, so it lives one
# level up where only discovery finds it. Do not "tidy" it back inside
# spec/support/.

require "stringio"
require "json"

RSpec.describe "custom matchers (spec/support/matchers/)" do
  describe "be_ractor_shareable" do
    it "passes for a deeply frozen value object" do
      turn = Lain::Turn.new(role: "user", content: [{ "type" => "text", "text" => "hi" }])
      expect(turn).to be_ractor_shareable
    end

    it "fails, naming the object, for one with reachable mutable state" do
      mutable = Struct.new(:box).new(+"unfrozen string").freeze

      expect { expect(mutable).to be_ractor_shareable }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /Ractor\.shareable\?.*was not/m)
    end

    it "negated failure message names the object too" do
      turn = Lain::Turn.new(role: "user", content: [{ "type" => "text", "text" => "hi" }])

      expect { expect(turn).not_to be_ractor_shareable }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /not to be Ractor\.shareable\?, but it was/)
    end

    it "names the offending leaf's path when a nested node is the only unfrozen one" do
      carrier = Class.new do
        attr_reader :blocks

        def initialize(blocks)
          @blocks = blocks
          freeze
        end
      end
      nested = carrier.new([{ "text" => "frozen" }.freeze, { "text" => +"mutable" }.freeze].freeze)

      expect { expect(nested).to be_ractor_shareable }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /@blocks\[1\]\["text"\] \(String, unfrozen\)/)
    end

    # T2 re-review rider: the depth-first walk is cut by an identity-keyed
    # `seen` set, not by depth alone. A frozen structure that references
    # ITSELF (a cycle, not just deep nesting) must still terminate and name
    # the real offender rather than looping forever chasing the self-edge.
    it "terminates on a frozen self-referential structure instead of looping forever" do
      carrier = Struct.new(:self_ref, :payload).new(nil, +"mutable")
      carrier.self_ref = carrier
      carrier.freeze

      expect { expect(carrier).to be_ractor_shareable }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /payload \(String, unfrozen\)/)
    end
  end

  describe "have_same_digest_as" do
    def turn(text)
      Lain::Turn.new(role: "user", content: [{ "type" => "text", "text" => text }])
    end

    it "passes for two values that content-address to the same digest" do
      expect(turn("same")).to have_same_digest_as(turn("same"))
    end

    it "fails, naming both hex-prefixed digests, when they diverge" do
      a = turn("alpha")
      b = turn("bravo")

      expect { expect(a).to have_same_digest_as(b) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError,
                        /#{Regexp.escape(a.digest[0, 19])}.*#{Regexp.escape(b.digest[0, 19])}/m)
    end

    it "negated failure message also names both prefixes" do
      a = turn("same")
      b = turn("same")

      expect { expect(a).not_to have_same_digest_as(b) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /not to have the same digest as/)
    end
  end

  describe "stop_with" do
    def response(stop_reason)
      Lain::Response.new(content: [{ "type" => "text", "text" => "x" }], stop_reason:)
    end

    it "passes when stop_reason matches" do
      expect(response(:tool_use)).to stop_with(:tool_use)
    end

    it "fails, naming expected vs actual stop_reason, when it does not" do
      expect { expect(response(:end_turn)).to stop_with(:tool_use) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /expected stop_reason :tool_use, got :end_turn/)
    end
  end

  describe "be_deeply_frozen" do
    it "passes for a value object that is frozen with no reachable mutable state" do
      turn = Lain::Turn.new(role: "user", content: [{ "type" => "text", "text" => "hi" }])
      expect(turn).to be_deeply_frozen
    end

    it "fails, distinguishing not-frozen from shallow-frozen-but-not-shareable" do
      not_frozen = Struct.new(:x).new(1)
      expect { expect(not_frozen).to be_deeply_frozen }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /to be frozen, but #frozen\? is false/)

      shallow = Struct.new(:box).new(+"mutable").freeze
      expect { expect(shallow).to be_deeply_frozen }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /Ractor\.shareable\? is false/)
    end

    it "names the offending leaf's path, not just the top-level verdict" do
      carrier = Class.new do
        attr_reader :blocks

        def initialize(blocks)
          @blocks = blocks
          freeze
        end
      end
      nested = carrier.new([{ "text" => "frozen" }.freeze, { "text" => +"mutable" }.freeze].freeze)

      expect { expect(nested).to be_deeply_frozen }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /@blocks\[1\]\["text"\] \(String, unfrozen\)/)
    end
  end

  describe "journal_matchers (include_journal_record / be_valid_ndjson)" do
    let(:journal_io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io: journal_io, clock: -> { "T" }) }

    before do
      journal.record("type" => "turn_usage", "digest" => "d1", "input_tokens" => 10)
      journal.record("type" => "tool_result", "tool_use_id" => "tu_1")
    end

    it "matches over the IO directly" do
      expect(journal_io).to include_journal_record("turn_usage", digest: "d1")
    end

    it "matches over the underlying String equally" do
      expect(journal_io.string).to include_journal_record("turn_usage", digest: "d1")
    end

    it "matches on type alone, with no attrs" do
      expect(journal_io).to include_journal_record("tool_result")
    end

    it "fails, listing the types actually present, when the type is absent" do
      expect { expect(journal_io).to include_journal_record("turn_error") }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /types seen: \["turn_usage", "tool_result"\]/)
    end

    it "fails, naming the closest same-type record, when attrs don't match" do
      expect { expect(journal_io).to include_journal_record("turn_usage", digest: "nope") }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /closest: .*"digest" => "d1"/)
    end

    it "is valid NDJSON over both IO and String" do
      expect(journal_io).to be_valid_ndjson
      expect(journal_io.string).to be_valid_ndjson
    end

    it "fails and names the offending line verbatim when a line is torn" do
      torn = "#{journal_io.string}not json at all {\n"

      expect { expect(torn).to be_valid_ndjson }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /line 3 of 3 did not parse: "not json at all \{"/)
    end

    # The reviewer's repro: two same-type records where only the SECOND matches
    # the attrs. The negated failure message must cite the record that matched,
    # not merely the first record of that type.
    it "negated failure names the record that actually matched, not the first of its type" do
      journal.record("type" => "turn_usage", "digest" => "d2")

      expect { expect(journal_io).not_to include_journal_record("turn_usage", digest: "d2") }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /found one: .*"digest" => "d2"/)
    end

    it "raises loudly on a journal argument that is neither an IO nor a String" do
      expect { expect(42).to be_valid_ndjson }
        .to raise_error(ArgumentError, /journal must be an IO or String, got Integer/)
    end
  end
end
