# frozen_string_literal: true

module Lain
  module Compaction
    class Source
      # What happens when no cut can make room: `--compact-fallback`'s two arms.
      #
      # It is a FALLBACK and not a strategy. Every other compaction decision is
      # taken before a request is sent, off a byte measurement this run owns;
      # this one is taken AFTER a provider has refused a prompt whole, off the
      # provider's own token count, because there is no estimate good enough to
      # anticipate it -- the same measurement {Middleware::RequestBudget}
      # refuses to guess at.
      #
      # It is also the one collapse that is not measured for shrinkage. A
      # handoff replaces nearly the whole history with one document, so asking
      # whether it shrinks the render would be asking a question whose answer
      # is never in doubt; what IS in doubt is whether there was anything to
      # replace, and {HeldCut::Handoff#empty?} answers that before a model call
      # is spent.
      #
      # The document it records is a compaction replacement. It is never
      # written to project memory -- nothing here holds a memory store, and
      # nothing here can reach one.
      class Fallback
        # What a caller that cannot resolve the tier's model is asked in.
        CONSERVATIVE = -> { ContextWindow::CONSERVATIVE_FALLBACK }

        # `--compact-fallback none`: the refusal stands, exactly as it did
        # before this object existed. A Null Object, so {Source} writes no
        # `if fallback`.
        module None
          module_function

          # @return [false] no room made, on every chain
          def call(_held_cut, **) = false
        end

        # @param tier [#call] answers a `#ask` oracle over
        #   {Oracle::Handoff.definition}, journaling WRAPPED -- a failed
        #   handoff has to leave an `oracle_failed` record, and only the
        #   wrapper holds the definition that names it.
        #
        #   A FACTORY and not the tier itself, because this object is wired on
        #   every compacting run and fires on almost none of them: building the
        #   tier here would open a second provider for every chat that never
        #   needs one. The build happens after a prompt has already been
        #   refused, where one construction costs nothing measurable.
        # @param window [#call] the summarizer tier's resolved window, in
        #   tokens, which is what sizes the question's own byte budget. A thunk
        #   for `tier`'s reason and one of its own: resolving a window can put
        #   a probe on the wire, and a compacting run must not pay that at
        #   wiring time. The conservative fallback by default -- the window a
        #   run whose book cannot identify the model is asked in anyway.
        def initialize(tier:, window: CONSERVATIVE)
          @tier = tier
          @window = window
        end

        # Write the state document and commit the cut that holds it.
        #
        # @param held_cut [HeldCut] this chain's cuts, as the refused render
        #   rendered them
        # @param pins [Context::PinnedMessages] this turn's pins
        # @return [Boolean] whether a handoff cut committed -- and so whether
        #   the refused render is worth one retry
        def call(held_cut, pins:)
          handoff = held_cut.handoff(pins:, budget: Oracle::Handoff.budget_for(@window.call))
          return false if handoff.empty?

          answered(handoff) { |document| held_cut.hand_off(handoff.ranges, document) }
        end

        private

        # ONLY the tier call is contained, and the narrowness is the point.
        # {Oracle::Eager#fire}'s task boundary wraps `ask(...).await` and
        # nothing else; a rescue around the whole method would report a bug in
        # the range arithmetic, or a journal that could not write, as "the
        # summarizer was down" -- so a full disk would reach a human as an
        # over-window refusal with no trace of the real fault.
        #
        # The tier's own failure is already on the record:
        # {Oracle::Recorded::Journaling} writes `oracle_failed` before it
        # re-raises, and what this object owes its caller is only whether room
        # was made.
        def answered(handoff)
          document = Oracle::Handoff.document(@tier.call.ask(**handoff.question).await)
        rescue ScriptError, StandardError, SystemStackError
          false
        else
          yield(document)
          true
        end
      end
    end
  end
end
