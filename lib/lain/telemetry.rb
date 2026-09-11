# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "bigdecimal"

module Lain
  # Structured events that flow through a {Lain::Channel}.
  #
  # Every event is a small, deeply frozen `Data` value object, so it is safe to
  # share across threads without copying. Equality, `#hash` and immutability come
  # from `Data` itself; {Journalable} adds the one behaviour they share —
  # serializing to a tagged JSON object for the {Lain::Journal}.
  module Telemetry
    # The NDJSON self-description every event owes the {Lain::Journal}: its
    # attributes plus a `type` tag a reader discriminates on without inspecting
    # shape. The Journal adds durability and a timestamp; an event only has to
    # describe itself.
    module Journalable
      # @return [Hash{String=>Object}] the attributes, string-keyed, tagged.
      def to_journal
        { "type" => journal_type }.merge(to_h.transform_keys(&:to_s))
      end

      # The class's short name in snake_case, so {ToolOutput} journals as
      # `"tool_output"`. `String#underscore` is byte-identical to the hand-rolled
      # gsub it replaced for every current event -- an equivalence the spec pins,
      # because recorded journals replay against this discriminator.
      # @return [String]
      def journal_type
        self.class.name.split("::").last.underscore
      end
    end

    # The construction contracts of this module's records: one named
    # {Lain::Declarative::Carrier} subclass each, validated and discarded BEFORE
    # the auto-frozen Data value exists. Named rather than anonymous
    # (`declare do ... end`) so they stay reachable for introspection and
    # shoulda-matchers. Each record group declares its own into this namespace.
    module Carriers
    end

    # A money figure as a fixed-point ("F") decimal String, the form every priced
    # record journals: `BigDecimal`'s default `to_s` emits scientific notation
    # (`"0.12345e-2"`) that is valid JSON but unreadable in an NDJSON line meant
    # for a human to scan. A String rather than the `BigDecimal` because
    # `Canonical.normalize` has no wire form for one, and every field must be an
    # immutable, JSON-safe value to keep the record `Ractor.shareable?`.
    #
    # nil passes through -- the REFUSAL a record with no quote it can stand
    # behind journals. `nil?` and not a truthy test: `value && ...` would wave
    # `false` through too, storing a JSON boolean in a money field.
    #
    # Tolerating nil is NOT permission to journal one. A record whose figures are
    # not optional says so in its own carrier ({Carriers::SeamDecision} does), so
    # the loudness lives with the record holding the contract rather than in a
    # shared formatter that cannot know which caller has a refusal to express.
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
require_relative "telemetry/seam_decision"
require_relative "telemetry/resend_dispatched"
require_relative "telemetry/switches"
require_relative "telemetry/handback"
require_relative "telemetry/worktree_reap"
require_relative "telemetry/context_derived"
require_relative "telemetry/approval_pending"
require_relative "telemetry/secret_boundary"
require_relative "telemetry/provider_wait"
require_relative "telemetry/malformed_response"
require_relative "telemetry/truncated_stream"
require_relative "telemetry/tool_cancelled"
require_relative "telemetry/shell_arm"
require_relative "telemetry/spawn_lifecycle"
require_relative "telemetry/questions_consumed"
require_relative "telemetry/test_layout"
