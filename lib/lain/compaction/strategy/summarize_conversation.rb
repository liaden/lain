# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # {Summarizing}, cut to the CONVERSATIONAL stretches: the model is asked
      # about the turns either side of the tool rounds, and never about the
      # observations themselves. Its complement is
      # {Strategy::ElideToolObservations}, and the pair is the whole point --
      # `elide_tools | summarize_conversation` is the first composition of this
      # bench's strategies that does not raise {Composed::Overlap}, because
      # every strategy shipped before these two claimed the whole span.
      #
      # == It changes WHICH ranges, never WHAT is asked about them
      #
      # That sentence is the design, and it is what makes this class safe to
      # write. {Summarizing::TEMPLATE} is a JOURNAL ADDRESS as well as a prompt
      # (see its own doc on `.definition`): rewording it silently re-keys every
      # recorded answer, and the miss surfaces on RESUME, after the model has
      # already been paid. This subclass overrides {#propose_ranges} and nothing
      # else -- {#blocks}, {#question}, {#whole_span}, the {Answers} memo and
      # `.definition` are all inherited unaltered -- so the address is the
      # parent's by construction rather than by care, and a spec pins the
      # TEMPLATE by object IDENTITY so that any re-definition here fails whether
      # or not the wording happens to match.
      #
      # The corollary is worth stating for whoever wires this up: a session may
      # run {Summarizing} and this strategy over ONE recorded tier, because the
      # question a range asks is a function of the range's bytes and not of the
      # strategy that proposed it. Two strategies, one oracle, one journal.
      #
      # == Why the runs come from {Compaction::ToolMessages}
      #
      # Because this strategy and {ElideToolObservations} must be exact
      # complements. Two independent spellings of "does this message carry a
      # tool block" could drift on real input, and the moment they did,
      # {Composed} would raise at proposal time, mid-turn, in a live chat --
      # for a reason neither strategy alone could see. So the predicate is
      # asked, never re-written.
      #
      # A run of ONE message is deliberately not claimed. That filter lives in
      # {ToolMessages.conversational_runs} rather than here, and it is not
      # tidiness: a lone conversational turn between two tool rounds would cost
      # a whole model call to "summarize" a single message into a message, which
      # is a cost with no saving. Unclaimed, it is retained verbatim and in
      # position by the derivation, which is the better answer as well as the
      # cheaper one.
      #
      # == Why each run goes back through the parent
      #
      # {Summarizing#propose_ranges} does not merely answer `[span]`: it asks
      # the oracle first, and proposes nothing when the answer does not come
      # back, so a tier that is DOWN leaves those turns standing rather than
      # collapsing them to nothing. Calling it once per run keeps that
      # containment at RUN granularity -- one unanswerable stretch is left
      # verbatim while its neighbours still collapse -- and means the rule is
      # implemented once, where the rescue and the sink line already live.
      # Re-deciding it here would be a second copy of a policy whose failure
      # mode is silence.
      #
      # IT ALSO MULTIPLIES THE COST OF A REFUSED DERIVATION BY N, and that is
      # the price of the containment rather than an oversight.
      # `chunk-derived-context-timeline.md:1753-1757` records that under an
      # oracle-backed strategy the model call is made and journalled as an
      # `oracle_answer` even when the derivation is then REFUSED, and that
      # because the memo keys on span content address, a session that keeps
      # chatting pays it again every turn. At whole-span granularity that is one
      # call per turn; here it is one per claimed run. The trade is deliberate
      # -- the alternative is a single unanswerable stretch taking the whole
      # span down with it -- but a caller wiring this onto the live chat path
      # should know the multiplier is N and not 1.
      #
      # == The one claim it has to say again
      #
      # {Summarizing} refutes BOTH `elementwise` and `pure` on {#blocks}, and
      # this class inherits that operation unoverridden, so its behaviour is the
      # parent's exactly. The two refutations still part company here, because
      # the two structures are classified by different mechanisms and only one
      # of them survives inheritance:
      #
      # - **Elementwise is structural, and the absence IS the negative.**
      #   {Algebra::Elementwise} classifies by `is_a?`, and this class does not
      #   include it, so the refutation needs no restatement to remain true.
      # - **Purity is registry-keyed on the EXACT class, so it is DROPPED.**
      #   {Algebra::Registry#declares?} and {DerivationAudit#refuted?} are both
      #   exact-subject scans, and a subclass therefore drops a REFUTATION
      #   exactly as it drops a claim -- the mechanism is sign-agnostic. Left
      #   unsaid, {DerivationAudit#purity} answers `:unclaimed` for this class
      #   where it answers `:impure` for its parent, which costs the audit two
      #   named diagnoses (`:incomplete_replay` and `:window_or_replay`) and
      #   collapses both into `:unclaimed_purity`, whose text can only tell the
      #   reader to go and declare it. That is the wrong loss to take HERE of
      #   all places: `:incomplete_replay` reads "the strategy is refuted pure,
      #   so it answers from outside the source -- the replay was handed
      #   different answers", which is precisely the diagnosis for an
      #   oracle-backed strategy that drifts after a resume, and this is the
      #   half of the pair that can drift for oracle reasons at all.
      #
      # Restating costs a generator in spec/support/algebra_generators.rb, keyed
      # `[SummarizeConversation, :blocks]`, because `spec/algebra_laws_spec.rb`
      # builds its claim list from `registry.map` -- which yields refutations
      # too -- so a new refutation is a new claim needing the means to prove it.
      # It fails as MISSING until that entry exists, never as an orphan; an
      # orphan is the opposite direction, a generator for a claim nobody makes.
      class SummarizeConversation < Summarizing
        # @param messages [Array<Hash>] the rendered messages
        # @param span [Range] the droppable span, as message indices
        # @return [Array<Range>] the conversational runs of more than one
        #   message that the oracle answered for, ascending and disjoint from
        #   every tool-carrying message in the span
        def propose_ranges(messages, span:)
          ToolMessages.conversational_runs(messages, span:, owner: name)
                      .flat_map { |run| super(messages, span: run) }
        end

        # Said again rather than inherited, for the reason in the class doc: the
        # registry is keyed on the exact class, so the parent's refutation does
        # not reach this one and {DerivationAudit} would read `:unclaimed`. The
        # reason is the parent's own, because the fact is the parent's own -- it
        # holds an oracle and a mutable memo, and this class adds neither.
        #
        # Filed directly rather than through {Algebra::Pure}, which is what
        # {Summarizing} does, and for its reason: {Summarizing} does not
        # `include Algebra::Pure` at all, so `not_pure` is not in scope here.
        # (An earlier draft of this comment said `not_pure` raises
        # {Algebra::Contradiction} on an includer. It does not -- it files the
        # refutation normally; that behaviour is `Elementwise.not_elementwise`'s,
        # and only because elementwise is structural.)
        #
        # The elementwise refutation is deliberately NOT restated beside it --
        # that structure is classified by `is_a?`, so its absence is already the
        # negative and a second filing would be a duplicate the registry would
        # then demand a second proof of.
        Algebra.registry.refute(
          subject: self, operation: :blocks, structure: :pure,
          reason: "it holds an oracle, so it reaches mutable state and is not Ractor.shareable? -- which is why " \
                  "re-derivation needs the journalled answer rather than the edge alone"
        )
      end
    end
  end
end
