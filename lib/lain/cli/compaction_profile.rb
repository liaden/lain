# frozen_string_literal: true

module Lain
  module CLI
    CompactionProfile = Data.define(:strategy, :keep, :bytes, :cap, :fallback)

    # Which compaction arm a run takes: the strategy that collapses a span and
    # the four knobs that decide when and how far. A field is nil until someone
    # SAYS it. That is the whole point of the value: a flag Thor filled from a
    # `default:` is indistinguishable from one the human typed, so a resume
    # could never tell "keep the recorded arm" from "the human asked for the
    # default", and rendered a session under a different arm than it recorded.
    # {Backend} owns what an unset field means.
    class CompactionProfile
      FLAGS = { strategy: :compact_strategy, keep: :compact_keep, bytes: :compact_bytes,
                cap: :compact_cap, fallback: :compact_fallback }.freeze

      class << self
        # Read by literal key, so `chat_flags_spec`'s scan of what the CLI reads
        # still sees every flag.
        #
        # @param options [#[]] Thor's parse, or any hash spelling the same keys
        # @return [CompactionProfile] nil for each flag not typed
        def typed(options)
          new(strategy: options[:compact_strategy], keep: options[:compact_keep], bytes: options[:compact_bytes],
              cap: options[:compact_cap], fallback: options[:compact_fallback])
        end

        # @param record [Hash{String=>Object}] a session header record
        # @return [CompactionProfile] nil for each key the header lacks
        def from_header(record)
          new(**FLAGS.to_h { |field, flag| [field, record[flag.to_s]] })
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

      def initialize(strategy:, keep:, bytes:, cap:, fallback:)
        super(strategy: strategy&.dup&.freeze, keep:, bytes:, cap:, fallback: fallback&.dup&.freeze)
      end

      UNSET = new(strategy: nil, keep: nil, bytes: nil, cap: nil, fallback: nil)
    end
  end
end
