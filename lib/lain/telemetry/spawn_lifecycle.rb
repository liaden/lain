# frozen_string_literal: true

module Lain
  module Telemetry
    # The closed vocabulary a spawn's own lineage speaks about itself, and the
    # one question both live-fleet readers ask of it: has this spawn finished,
    # so a tmux window or a published roster can drop it?
    #
    # Three marks ride a `:spawn` or `:message` body's `"lifecycle"` field --
    # `"launched"`, `"settled"`, `"stopped"` -- and a one-shot's completion
    # speaks none of them, carrying a `"result"` key instead. That asymmetry
    # is history, not a defect this object corrects: a mark added to future
    # completions cannot be backfilled onto journals already on disk, since
    # `Bench::Session::MessageReplay` re-derives a historical digest from the
    # historical body. So both shapes are read here, by name, rather than one
    # reader growing its own copy of this test and the next growing another.
    #
    # Written to the shape of {Compaction::Boundary}: read once at
    # construction, frozen, and never raising -- both readers of this object
    # are per-turn status sinks riding `CLI::JournalTee`, which turns a raised
    # sink into a lost turn. A record this object cannot make sense of reads
    # as an ordinary, non-terminal one rather than blowing up the turn that
    # carried it; `#unrecognized` is where that refusal is reported instead.
    class SpawnLifecycle
      LAUNCHED = "launched"
      SETTLED = "settled"
      STOPPED = "stopped"

      # The closed set a `"lifecycle"` mark is checked against. A value
      # outside it is never trusted as terminal OR as safely non-terminal --
      # it is named on {#unrecognized} so a caller can tell "nothing happened
      # yet" apart from "something happened that this object does not know".
      MARKS = [LAUNCHED, SETTLED, STOPPED].freeze

      # @return [String, nil] the `"lifecycle"` value the record's body
      #   carried, when that value falls outside {MARKS}. nil when the body
      #   carried a recognized mark, no mark at all, or no body this object
      #   could read.
      attr_reader :unrecognized

      # @param record [#body, #payload] a {Telemetry::Message} or a raw
      #   {Event} -- the two shapes this reads a body out of differently, on
      #   purpose. `Event#payload` is the CONTENT-ADDRESS ENVELOPE (kind,
      #   from, to, causal_parents, correlation, payload_digest) and never
      #   carries the body at all, by that class's own doc; `Event#body` is
      #   where the body actually is. `Telemetry::Message` carries no `#body`
      #   member, and its `#payload` field IS the body
      #   (`Message.from_event` sets `payload: event.body`). `#body` is
      #   therefore tried first -- an Event answers it, a Message does not --
      #   and `#payload` is the fallback for the Message shape. A record
      #   answering neither, or answering one with something other than a
      #   Hash, reads as an ordinary tell rather than raising.
      def initialize(record)
        body = read_body(record)
        body = {} unless body.is_a?(Hash)
        # `-mark`, the house idiom (`Event.normalize_role`'s `-role.to_s`):
        # `Kernel#freeze` on `self` below is not transitive, so a mark read
        # out of an unfrozen source String -- one whose body did not pass
        # through `Canonical.normalize` before reaching this object, e.g. a
        # raw `JSON.parse` result -- would otherwise leave this object
        # unshareable despite calling `freeze`.
        mark = body["lifecycle"]
        mark = -mark if mark.is_a?(String)
        @mark = MARKS.include?(mark) ? mark : nil
        @unrecognized = mark if !mark.nil? && @mark.nil?
        # A "result" key names a one-shot's completion body (only
        # {Tools::Subagent::Lineage#message} ever writes one, and it always
        # writes a finished child), so its presence is read as terminal ON
        # ITS OWN -- never conditioned on which mark, if any, rides beside
        # it. That is deliberate slack for a future writer: today's body
        # carries no mark at all, and a later one is free to add any mark
        # from {MARKS} (or none) without this object's reading of it
        # changing. The one thing a "result" body can never mean is
        # "settled" -- an actor's settled reply and a one-shot's completion
        # are written by different methods and never share a key. This
        # reading rests on convention, not on type: nothing stops a FUTURE
        # `:message` writer from emitting its own "result" key, and whoever
        # adds the next one should read this comment before assuming the
        # inference still holds.
        @result = body.key?("result")
        freeze
      end

      # `"settled"` is deliberately excluded: an actor writes it on EVERY
      # turn it answers back to its parent, not only its last, so treating it
      # as terminal would retire a long-lived actor on its first reply -- the
      # specific mistake this object exists to prevent.
      #
      # @return [Boolean]
      def terminal?
        @mark == STOPPED || @result
      end

      private

      # Both accessor calls are wrapped, narrowly: a collaborator whose own
      # `#body` or `#payload` raises must read the same as any other record
      # this object cannot make sense of, not propagate -- both consumers
      # ride `CLI::JournalTee`, which turns a raised sink into a lost turn.
      def read_body(record)
        return record.body if record.respond_to?(:body)
        return record.payload if record.respond_to?(:payload)

        nil
      rescue StandardError
        nil
      end
    end
  end
end
