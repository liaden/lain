# frozen_string_literal: true

module Lain
  module CLI
    CompactionProfile = Data.define(:compact, :strategy, :keep, :bytes, :cap, :fallback, :schedule)

    # Which compaction arm a run takes: whether it compacts at all, the strategy
    # that collapses a span, and the four knobs that decide when and how far. A field is nil until someone
    # SAYS it. That is the whole point of the value: a flag Thor filled from a
    # `default:` is indistinguishable from one the human typed, so a resume
    # could never tell "keep the recorded arm" from "the human asked for the
    # default", and rendered a session under a different arm than it recorded.
    # {Backend} owns what an unset field means.
    class CompactionProfile
      FLAGS = { compact: :compact, strategy: :compact_strategy, keep: :compact_keep, bytes: :compact_bytes,
                cap: :compact_cap, fallback: :compact_fallback, schedule: :compact_schedule }.freeze
      SCHEDULES = %w[idle turn].freeze
      DEFAULT_SCHEDULE = "idle"

      class << self
        # Read by literal key, so `chat_flags_spec`'s scan of what the CLI reads
        # still sees every flag.
        #
        # @param options [#[]] Thor's parse, or any hash spelling the same keys
        # @return [CompactionProfile] nil for each flag not typed
        def typed(options)
          new(compact: options[:compact], strategy: options[:compact_strategy], keep: options[:compact_keep],
              bytes: options[:compact_bytes], cap: options[:compact_cap], fallback: options[:compact_fallback],
              schedule: options[:compact_schedule])
        end

        # An off run's `compact_schedule` is the placeholder every off header
        # carries, not a choice, so a `--compact` resume must not inherit it.
        #
        # @param record [Hash{String=>Object}] a session header record
        # @return [CompactionProfile] nil for each key the header lacks
        def from_header(record)
          recorded = new(**FLAGS.to_h { |field, flag| [field, record[flag.to_s]] })
          recorded.compacts? ? recorded : recorded.with(schedule: nil)
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

      # An on switch is left out because it is what an untyped run does, so a
      # compacting run's header stays the one it always was.
      #
      # @return [Hash{String=>Object}] the set fields, keyed as the header records them
      def to_header
        options = compacts? ? to_options.except(:compact) : to_options
        options.transform_keys(&:to_s)
      end

      # @return [Boolean] false only when `--no-compact` was typed or recorded
      def compacts? = compact != false

      # @return [String] the schedule that runs: typed, else recorded, else {DEFAULT_SCHEDULE}
      def schedule_or_default = schedule || DEFAULT_SCHEDULE

      def initialize(compact:, strategy:, keep:, bytes:, cap:, fallback:, schedule:)
        super(compact:, strategy: strategy&.dup&.freeze, keep:, bytes:, cap:, fallback: fallback&.dup&.freeze,
              schedule: schedule&.dup&.freeze)
      end

      UNSET = new(compact: nil, strategy: nil, keep: nil, bytes: nil, cap: nil, fallback: nil, schedule: nil)
    end
  end
end
