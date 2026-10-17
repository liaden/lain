# frozen_string_literal: true

module Lain
  module CLI
    CompactionProfile = Data.define(:strategy, :keep, :bytes, :cap, :fallback, :schedule)

    # Which compaction arm a run takes: the strategy that collapses a span and
    # the four knobs that decide when and how far. A field is nil until someone
    # SAYS it. That is the whole point of the value: a flag Thor filled from a
    # `default:` is indistinguishable from one the human typed, so a resume
    # could never tell "keep the recorded arm" from "the human asked for the
    # default", and rendered a session under a different arm than it recorded.
    # {Backend} owns what an unset field means.
    class CompactionProfile
      FLAGS = { strategy: :compact_strategy, keep: :compact_keep, bytes: :compact_bytes,
                cap: :compact_cap, fallback: :compact_fallback, schedule: :compact_schedule }.freeze
      SCHEDULES = %w[idle turn].freeze
      DEFAULT_SCHEDULE = "turn"

      class << self
        # Read by literal key, so `chat_flags_spec`'s scan of what the CLI reads
        # still sees every flag.
        #
        # @param options [#[]] Thor's parse, or any hash spelling the same keys
        # @return [CompactionProfile] nil for each flag not typed
        def typed(options)
          new(strategy: options[:compact_strategy], keep: options[:compact_keep], bytes: options[:compact_bytes],
              cap: options[:compact_cap], fallback: options[:compact_fallback],
              schedule: options[:compact_schedule])
        end

        # A header without the key predates the field, and that run scheduled on the turn.
        #
        # @param record [Hash{String=>Object}] a session header record
        # @return [CompactionProfile] nil for each key the header lacks; schedule "turn" for a
        #   non-empty header without the key, and every field nil for an empty one
        def from_header(record)
          recorded = new(**FLAGS.to_h { |field, flag| [field, record[flag.to_s]] })
          record.empty? || recorded.schedule ? recorded : recorded.with(schedule: "turn")
        end
      end

      # These fields laid over a recording: a field nobody set takes the
      # recorded one, so a typed flag wins field by field.
      #
      # @param recorded [CompactionProfile]
      # @return [CompactionProfile]
      def over(recorded) = with(**recorded.to_h.compact.except(*to_h.compact.keys))

      # @return [Hash{Symbol=>Object}] the set fields, keyed as {Backend} reads its flags
      def to_options = FLAGS.to_h { |field, flag| [flag, public_send(field)] }.compact

      # @return [Hash{String=>Object}] the set fields, keyed as the header records them
      def to_header = to_options.transform_keys(&:to_s)

      # @return [String] the schedule that runs: typed, else recorded, else {DEFAULT_SCHEDULE}
      def schedule_or_default = schedule || DEFAULT_SCHEDULE

      def initialize(strategy:, keep:, bytes:, cap:, fallback:, schedule:)
        super(strategy: strategy&.dup&.freeze, keep:, bytes:, cap:, fallback: fallback&.dup&.freeze,
              schedule: schedule&.dup&.freeze)
      end

      UNSET = new(strategy: nil, keep: nil, bytes: nil, cap: nil, fallback: nil, schedule: nil)
    end
  end
end
