# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # {Summarizing}, cut to the CONVERSATIONAL stretches: the model is asked
      # about the turns either side of the tool rounds, never about the
      # observations themselves. Its complement is {ElideToolObservations}, and
      # `elide_tools | summarize_conversation` is the first composition of this
      # bench's strategies that does not raise {Composed::Overlap}, because
      # every strategy shipped before these two claimed the whole span.
      #
      # == It changes WHICH ranges, never WHAT is asked about them
      #
      # {Summarizing::TEMPLATE} is a JOURNAL ADDRESS as well as a prompt:
      # rewording it silently re-keys every recorded answer, and the miss
      # surfaces on RESUME, after the model has already been paid. This
      # subclass overrides {#propose_claims} and nothing else, so the address is
      # the parent's by construction rather than by care, and a spec pins the
      # TEMPLATE by object IDENTITY so that any re-definition here fails whether
      # or not the wording happens to match. The corollary: a session may run
      # {Summarizing} and this strategy over ONE recorded tier, because the
      # question a range asks is a function of the range's bytes and not of the
      # strategy that proposed it.
      #
      # The runs come from {Compaction::ToolMessages} because this strategy and
      # {ElideToolObservations} must be exact complements: two independent
      # spellings of "does this message carry a tool block" could drift on real
      # input, and {Composed} would then raise at proposal time, mid-turn, in a
      # live chat, for a reason neither strategy alone could see. A run of ONE
      # message is deliberately not claimed -- a lone conversational turn
      # between two tool rounds would cost a whole model call to summarize one
      # message into a message, which is a cost with no saving.
      #
      # == Why each run goes back through the parent
      #
      # {Summarizing#propose_ranges} asks the oracle about each claimed run and
      # drops any whose answer does not come back, so a tier that is DOWN leaves
      # those turns standing rather than collapsing them to nothing. One
      # question per run keeps that containment at RUN granularity -- one
      # unanswerable stretch is left verbatim while its neighbours still
      # collapse.
      #
      # IT ALSO MULTIPLIES THE COST OF A REFUSED DERIVATION BY N, deliberately.
      # Under an oracle-backed strategy the model call is made and journalled
      # as an `oracle_answer` even when the derivation is then REFUSED, and
      # because the memo keys on span content address a session that keeps
      # chatting pays it again every turn. At whole-span granularity that is one
      # call per turn; here it is one per claimed run. The alternative is a
      # single unanswerable stretch taking the whole span down with it, but a
      # caller wiring this onto the live chat path should know the multiplier.
      class SummarizeConversation < Summarizing
        # @param messages [Array<Hash>] the rendered messages
        # @param span [Range] the droppable span, as message indices
        # @return [Array<Range>] the conversational runs of more than one
        #   message, ascending and disjoint from every tool-carrying message in
        #   the span. {Summarizing#propose_ranges} keeps those the oracle
        #   answers for.
        def propose_claims(messages, span:)
          ToolMessages.conversational_runs(messages, span:, owner: name)
                      .map { |run| unanswered_prompt_kept(messages, run) }
                      .select { |run| run.size > 1 }
                      .flat_map { |run| super(messages, span: run) }
        end

        private

        # A summary of a prompt whose answer lies past the run reads as a
        # request that went unanswered, so the prompt stays verbatim beside it
        # (and, sitting below the cut's floor, no later collapse folds it).
        def unanswered_prompt_kept(messages, run)
          prompt_awaiting_answer?(messages, run) ? run.begin..(run.last - 1) : run
        end

        def prompt_awaiting_answer?(messages, run)
          messages[run.last + 1] && Oracle::Handoff.human?(messages.fetch(run.last))
        end
      end
    end
  end
end
