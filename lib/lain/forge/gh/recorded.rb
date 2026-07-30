# frozen_string_literal: true

module Lain
  module Forge
    class Gh
      # Replays journaled {Outcome}s instead of shelling out. The same four verbs
      # as {Gh}, so a landing holds one or the other and never asks which.
      #
      # This is {Effect::Handler::Recorded}'s doctrine at the forge tier: outcomes
      # are keyed by `intent_id`, {#handles?}'s equivalent ({#recorded?}) is true
      # only for addresses it actually holds, and a MISS is declined -- passed to
      # the inner executor, or refused loudly when a caller supplied none. A
      # replay miss is never turned into a made-up success, because at this tier
      # a made-up success is a pull request nobody opened.
      #
      # == Only effects can be replayed
      #
      # `pr_view` and `merge_state` ask a question rather than cause one, so no
      # {Intent} addresses them and there is nothing to key a recording on. Both
      # fall through to the inner executor unconditionally. That is not a gap:
      # replaying an observation would be asserting what the world looks like
      # NOW from a record of what it looked like then, which is the one thing
      # this tier refuses to do anywhere else either.
      class Recorded
        # A call with no recording and nothing behind it. Named per the
        # error-taxonomy convention: a refusal subclasses {Lain::Error} next to
        # the owner that raises it.
        class Declined < Error; end

        # The inner an unrecorded call falls through to when a caller supplied
        # none: it refuses, loudly. A Null Object rather than a nil the four
        # verbs would each have to test for -- and stating the duck as four
        # methods is also what keeps the verb set closed here, since a fifth verb
        # would have to be written down in one more place.
        module Unrecorded
          class << self
            def pr_create(**kwargs) = refuse("pr_create", kwargs)
            def pr_merge(**kwargs) = refuse("pr_merge", kwargs)
            def pr_view(**kwargs) = refuse("pr_view", kwargs)
            def merge_state(**kwargs) = refuse("merge_state", kwargs)

            private

            def refuse(verb, kwargs)
              raise Declined, "no recorded outcome for #{verb}(#{kwargs.inspect}) and nothing behind the " \
                              "recording to perform it -- a replay miss is not a success"
            end
          end
        end

        # Build from journaled records. `Recorded.from_journal(File.foreach(path))`
        # reconstitutes an executor straight from a session file.
        #
        # Two attempts at one address share an intent_id ({Intent.id_for}), so an
        # index keyed on it can hold only one of them: the LAST wins, because the
        # last outcome for an address is the one that settled it and the one a
        # resume has to see. Positional pairing over the same records is
        # {Reconcile}'s job, not this one's.
        #
        # A malformed forge record ABORTS rather than being skipped --
        # {Outcome.from_record} re-checks the write-side guards. Skipping one
        # would replay a landing with a step silently missing from it.
        #
        # @param entries [Enumerable<Hash, String>]
        # @param inner [#pr_create, #pr_merge, #pr_view, #merge_state]
        # @return [Recorded]
        def self.from_journal(entries, inner: Unrecorded)
          outcomes = Journal.records(entries, type: Outcome::JOURNAL_TYPE)
                            .each_with_object({}) do |record, acc|
            outcome = Outcome.from_record(record)
            acc[outcome.intent_id] = outcome
          end
          new(outcomes:, inner:)
        end

        # @param outcomes [Hash{String=>Outcome}] intent_id => recorded outcome
        # @param inner [#pr_create, #pr_merge, #pr_view, #merge_state] performs
        #   the calls this holds no recording for
        def initialize(outcomes:, inner: Unrecorded)
          @outcomes = normalize(outcomes)
          @inner = inner
          freeze
        end

        # The address is (head, base) -- GitHub's own uniqueness key for an open
        # pull request, and the same pair {Journaled} writes. The two spellings
        # must not drift: a recording keyed on one and looked up by the other
        # replays nothing.
        def pr_create(base:, head:, title:, body:)
          replay(PR_CREATE, "head" => head, "base" => base) { @inner.pr_create(base:, head:, title:, body:) }
        end

        def pr_merge(number:, auto: false)
          replay(PR_MERGE, "number" => number) { @inner.pr_merge(number:, auto:) }
        end

        def pr_view(ref:, fields:) = @inner.pr_view(ref:, fields:)

        def merge_state(number:) = @inner.merge_state(number:)

        # @return [Boolean] whether this holds a recording for that address --
        #   {Effect::Handler::Recorded#handles?}'s question, asked the way this
        #   tier addresses things.
        def recorded?(action:, params:) = @outcomes.key?(Intent.id_for(action:, params:))

        private

        # The address is the params alone, so a retry that reworded the title
        # replays as the same attempt at the same pull request -- which is what
        # {Intent.id_for}'s obligation says it is.
        def replay(action, params)
          recorded = @outcomes[Intent.id_for(action:, params:)]
          return yield if recorded.nil?

          Gh::Answer.new(ok: recorded.ok?, observed: recorded.observed?, detail: recorded.detail)
        end

        def normalize(outcomes)
          outcomes.each_with_object({}) do |(id, outcome), acc|
            unless outcome.is_a?(Outcome)
              raise ArgumentError, "recorded outcome for #{id.inspect} must be a Forge::Outcome, got #{outcome.class}"
            end

            acc[-id.to_s] = outcome
          end.freeze
        end
      end
    end
  end
end
