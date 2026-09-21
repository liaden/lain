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
  #
  # One grouping the file names no longer carry: {ToolOutput}, {Dropped},
  # {ProviderRetry}, {TurnUsage}, {RequestSent}, {RequestResent}, {MemoryRoot},
  # {CapabilityDegraded}, {SlotFills}, {WriteRefused} and {Verdict} are one
  # stream — the durable per-turn/per-request record of what left for the model,
  # what it cost, and what a tool produced. They shared a file until each record
  # took the path that names it, and a reader meeting them among fifty-odd
  # siblings has nothing else to tell them they belong together.
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
    # shoulda-matchers. Each record declares its own into this namespace.
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
