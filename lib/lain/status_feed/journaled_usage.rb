# frozen_string_literal: true

module Lain
  class StatusFeed
    # A {Telemetry::TurnUsage}'s `usage` -- {Usage} in canonical wire form,
    # String-keyed, as it comes back OFF the journal -- answering the three
    # questions the feed asks of one turn's payment: did it touch the cache,
    # what filled the window on the way in, and what did it cost in total.
    #
    # It restates {Usage}'s arithmetic rather than delegating to it, because the
    # feed is handed the RECORD, never the {Usage} value the record was built
    # from. {Usage.from_anthropic_wire} decodes these same four keys and would
    # remove the restatement -- but it goes through `Integer()`, and a raise is
    # exactly what this object may not do: {StatusFeed} rides {CLI::JournalTee},
    # which RE-RAISES a sink's failure into the agent loop, so a malformed
    # record costs the turn rather than costing a status line. Hence `to_i`
    # throughout, and hence the two "cannot drift apart" pins in this object's
    # spec, which are all that holds the restatement to the original.
    class JournaledUsage
      # Either field nonzero means the cache was actually touched this turn
      # (written OR read) -- that is what "in use" means for a sliding TTL.
      CACHE_ACTIVITY_FIELDS = %w[cache_read_input_tokens cache_creation_input_tokens].freeze

      # {Usage#total_input_tokens}. Cached tokens count -- the window holds them
      # whether or not they were billed at full rate.
      INPUT_TOKEN_FIELDS = (CACHE_ACTIVITY_FIELDS + %w[input_tokens]).freeze

      # {Usage#total_tokens}. Everything the provider billed for, both
      # directions -- a cached read is cheaper than a fresh one, never free, so
      # it belongs in a figure whose whole subject is what a session PAID.
      TOKEN_FIELDS = (INPUT_TOKEN_FIELDS + %w[output_tokens]).freeze

      # @param fields [Hash{String=>Object}] the record's `usage`, canonical
      def initialize(fields)
        @fields = fields
      end

      def cache_active? = CACHE_ACTIVITY_FIELDS.any? { |field| tokens(field).positive? }

      def total_input_tokens = INPUT_TOKEN_FIELDS.sum { |field| tokens(field) }

      def total_tokens = TOKEN_FIELDS.sum { |field| tokens(field) }

      private

      def tokens(field) = @fields[field].to_i
    end
  end
end
