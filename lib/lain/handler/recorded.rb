# frozen_string_literal: true

require_relative "../effect"
require_relative "../handler"
require_relative "../journal"
require_relative "../tool"

module Lain
  class Handler
    # Replays a recorded outcome for a tool call instead of performing it.
    # "Deterministic replay is a recorded handler" -- the same decoration shape as
    # {Live} (which does it for real) and {Mock} (canned answers for specs), the
    # third interpretation of one effect vocabulary. The {Lain::Journal} is the
    # recording; this is the playback.
    #
    # Outcomes are keyed by `tool_use_id`, not by tool name. A recorded session is
    # a specific sequence of calls with unique ids, so replay is exact: the outcome
    # a given call had, verbatim, with no dependence on the tool's current behavior
    # or on the environment. That is what makes a recorded run reproducible when the
    # real tool is unavailable, non-deterministic, or costly.
    #
    # It composes by decoration like every Handler. Crucially, {#handles?} is true
    # ONLY for ids it has a recording for, so a call with no recording falls through
    # to `inner` (perform it live) or, with no inner, surfaces as the usual
    # {Handler::UnhandledEffect} -- a replay miss is never silently turned into a
    # made-up success. Stack {Recorded} in front of {Live} to replay the calls you
    # recorded and run the rest for real.
    class Recorded < Handler
      # Build from journaled records: each `tool_result` record becomes a
      # replayable outcome keyed by its `tool_use_id`. Entries are the
      # {Journal.records} duck -- parsed Hashes or raw NDJSON line Strings -- so
      # `Recorded.from_journal(File.foreach(path))` reconstitutes a handler
      # straight from the record.
      #
      # @param entries [Enumerable<Hash, String>]
      # @param inner [Lain::Handler, nil]
      # @return [Recorded]
      def self.from_journal(entries, inner: nil)
        outcomes = Journal.records(entries, type: "tool_result")
                          .each_with_object({}) { |record, acc| store_outcome(acc, record) }
        new(outcomes: outcomes, inner: inner)
      end

      def self.store_outcome(acc, hash)
        id = hash["tool_use_id"]
        return if id.nil?

        result = hash["is_error"] ? Tool::Result.error(hash["content"]) : Tool::Result.ok(hash["content"])
        acc[id.to_s] = result
      end
      private_class_method :store_outcome

      # @param outcomes [Hash{String=>Tool::Result}] tool_use_id => recorded result
      # @param inner [Lain::Handler, nil] performs (or live-runs) unrecorded calls
      def initialize(outcomes:, inner: nil)
        super(inner: inner)
        @outcomes = normalize(outcomes)
      end

      # True only for a call this handler has a recording for -- so a miss delegates
      # to `inner` through {Handler#call} rather than being handled here.
      def handles?(effect)
        case effect
        when Effect::Approval then handles?(effect.effect)
        when Effect::ToolCall then @outcomes.key?(effect.tool_use_id)
        else false
        end
      end

      protected

      # Replay the recorded result. An {Effect::Approval} on replay needs no gate --
      # the recording already reflects whatever was decided -- so it unwraps to the
      # inner call. {#handles?} guarantees the id is present, so the fetch cannot
      # miss.
      def perform(effect, context)
        return call(effect.effect, context) if effect.is_a?(Effect::Approval)

        @outcomes.fetch(effect.tool_use_id)
      end

      private

      def normalize(outcomes)
        outcomes.each_with_object({}) do |(id, result), acc|
          unless result.is_a?(Tool::Result)
            raise ArgumentError, "recorded outcome for #{id.inspect} must be a Tool::Result, got #{result.class}"
          end

          acc[id.to_s] = result
        end
      end
    end
  end
end
