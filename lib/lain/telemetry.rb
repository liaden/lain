# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "bigdecimal"

module Lain
  # Structured events that flow through a {Lain::Channel}.
  #
  # Every event is a small, deeply frozen `Data` value object: two events with
  # equal attributes are equal (`Regular` in the project's algebra), and nothing
  # about an event can mutate after construction, so it is safe to share across
  # threads without copying. Equality, `#hash`, and immutability come from `Data`
  # itself; {Journalable} adds the one behaviour they share — serializing to a
  # tagged JSON object for the {Lain::Journal}.
  module Telemetry
    # The NDJSON self-description every event owes the {Lain::Journal}. Mixed into
    # each `Data` event: its journal form is its attributes plus a `type` tag that
    # lets a reader discriminate the record without inspecting its shape. The
    # Journal adds durability and a timestamp; an event only has to describe
    # itself.
    module Journalable
      # @return [Hash{String=>Object}] the attributes, string-keyed, tagged.
      def to_journal
        { "type" => journal_type }.merge(to_h.transform_keys(&:to_s))
      end

      # The record's discriminator: the class's short name in snake_case, so
      # {ToolOutput} journals as `"tool_output"`. `String#underscore` produces
      # the byte-identical string the hand-rolled gsub did for every current
      # event -- an equivalence the spec pins, because this string is the journal
      # discriminator and recorded journals replay against it.
      # @return [String]
      def journal_type
        self.class.name.split("::").last.underscore
      end
    end

    # Construction contracts for the events whose hand-rolled guards moved to
    # validate-then-freeze (Ruling 2). Each is a throwaway {Lain::Guard} carrier
    # validated BEFORE the (auto-frozen) Data value exists -- see {Lain::Guard}
    # for why validation must live off the frozen value. Named, so they stay
    # reachable for introspection and shoulda-matchers.
    #
    # Each record group declares its own carriers into this namespace, from its
    # own file in `telemetry/`.
    module Guards
    end

    # A money figure as a fixed-point ("F") decimal String, the form every priced
    # record journals: `BigDecimal`'s default `to_s` emits scientific notation
    # (`"0.12345e-2"`) that is technically valid JSON but unreadable in an NDJSON
    # line meant for a human to scan. A String rather than the `BigDecimal` itself
    # because `Canonical.normalize` has no canonical wire form for one, and every
    # field of a record must be an immutable, JSON-safe value to keep it
    # `Ractor.shareable?`.
    #
    # nil passes through as nil -- the REFUSAL a record with no quote it can stand
    # behind journals ({Compaction} documents what absence means there). `nil?` and
    # not a truthy test: `value && ...` would wave `false` through as well, storing
    # a JSON boolean in a money field. Everything that is not nil goes to
    # `BigDecimal`, which raises on `"false"` as it always did.
    #
    # Tolerating nil here is NOT permission to journal one. A record whose figures
    # are not optional says so in its own {Guard} ({Guards::SeamDecision} does), so
    # the loudness lives with the record that holds the contract rather than in a
    # shared formatter, which cannot know which caller has a refusal to express.
    #
    # @param value [BigDecimal, Numeric, String, nil]
    # @return [String, nil] frozen fixed-point decimal, or nil
    def self.fixed_point(value)
      return nil if value.nil?

      (value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)).to_s("F").freeze
    end
  end
end

# Every record group `include Journalable` while its `Data.define` body runs, so
# the groups load AFTER the module body above -- that placement is forced. The
# order AMONG them is not: no group names another's constant, so any order loads.
require_relative "telemetry/turn_stream"
require_relative "telemetry/stream_signals"
require_relative "telemetry/session_lifecycle"
require_relative "telemetry/session_state"
require_relative "telemetry/salvaged"
require_relative "telemetry/oracle_answer"
require_relative "telemetry/compaction"
require_relative "telemetry/isolation_lease"
require_relative "telemetry/grade_record"
require_relative "telemetry/closure_record"
require_relative "telemetry/supersession_record"
require_relative "telemetry/gherkin_approval"
require_relative "telemetry/seam_decision"
require_relative "telemetry/resend_dispatched"
require_relative "telemetry/switches"
require_relative "telemetry/handback"
require_relative "telemetry/context_derived"
require_relative "telemetry/approval_pending"
