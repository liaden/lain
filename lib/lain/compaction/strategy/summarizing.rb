# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # The model-backed strategy: collapse a span into the summary an oracle
      # writes for it.
      #
      # == It is NOT elementwise, and that is the whole design
      #
      # Summarizing a concatenation is not the concatenation of summaries, so
      # this cannot include {Algebra::Elementwise} -- and the two refutations at
      # the foot of this file record the negative where a walk of the registry
      # can read it, rather than in a comment a later reader would tidy away.
      # Everything else here follows from that one fact: a non-homomorphic
      # collapse cannot be re-derived from its parts, so its answer has to be
      # addressable (the content address below) and recoverable (the recorded
      # oracle above it).
      #
      # == "Only summarize what is new" is a property of the ORACLE
      #
      # A first draft had the range proposal SKIP ranges whose answer was
      # already recorded, which is the opposite of the intent: skipping them
      # means the history stops shrinking after the first compaction. The range
      # is always offered; what varies is whether asking costs anything.
      # {Oracle::Recorded} delivers that for free -- an already-answered
      # question comes back from the journal with no model call -- and the
      # answers held here are the same saving one derivation earlier, so the
      # proposal and the collapse of one range never pay twice.
      #
      # The oracle MUST therefore be a {Oracle::Recorded}-wrapped tier
      # ({Oracle::Recorded::Journaling} recording, {Oracle::Recorded} replaying).
      # Over a bare {Oracle::Model} the "journal the edge, re-derive" ruling
      # breaks in silence: a resumed session would re-ask a live model and
      # derive a different chain from the same source.
      #
      # == The key is the range's content address
      #
      # {#question} and {#whole_span} are two readings of ONE set of canonical
      # bytes -- the range's own projection -- so an unchanged range re-derives
      # to a byte-identical question and hits the recorded answer, and a changed
      # one asks a different question. That is deliberately NOT a message
      # digest: {SummarySnapshot} records what a well-formed but wrongly-keyed
      # address costs (`summary_snapshot.rb:23-30`), which is every lookup,
      # silently and permanently. It is not an EVENT digest either, and cannot
      # be: {Event#payload} folds `render_parent`, so a range's event digests
      # move when anything ahead of them in the chain does, while its content
      # does not -- and the seam hands a strategy messages precisely because
      # timelines and events belong to the caller.
      #
      # == IT MUST NEVER BE REACHABLE FROM ANYTHING MADE SHAREABLE
      #
      # {SummarySnapshot}'s own doc (`summary_snapshot.rb:5-17`) records this
      # bug one seam over: a {Context::Compact} holding a live {Oracle::Eager}
      # is not `Ractor.shareable?`, and {Scheduler::COMPOSE}'s
      # `Ractor.make_shareable` then raises "in the live loop, not in any spec
      # that holds the summarizer by itself". This object is the second to hold
      # a live oracle and a mutable map, and it is the first for which the
      # enforcement is SILENT: `make_shareable` raises for a Proc with
      # unshareable `self`, but a plain object graph -- which this is -- is
      # merely DEEP-FROZEN, with no error. The first derivation then compacts
      # normally against a populated memo and the NEXT new span dies of
      # `FrozenError` on the render path, which is not a {Lain::Error} and so is
      # deliberately not contained below.
      #
      # So: the derived chain is substituted as MESSAGES ({Compaction::Source}
      # derives, then replays), and neither this strategy nor the {Derivation}
      # holding it may be carried into a pipeline that is made shareable --
      # `source_spec.rb:535-551` asserts shareability on the compacting path.
      # The example pinning the frozen memo is a defect and not a contained miss
      # is in the spec beside this class. Making {Answers} degrade quietly when
      # frozen would be worse than the crash: see why the memo is a correctness
      # condition, below.
      #
      # == What is contained, and what is not
      #
      # A tier that is DOWN is a miss: the failure is reported to the sink and
      # the range is simply not proposed, so the derivation keeps those turns
      # verbatim rather than dying on the render path. An answer that ARRIVED
      # and cannot be used is loud -- a blank summary reaches
      # {Replacement.text}, which raises {Blank} -- because that is a strategy
      # bug and papering over it would render an empty block the provider
      # rejects. The rescue names {Lain::Error} and not `StandardError`:
      # `NotImplementedError < ScriptError` and `Async::Cancel < Exception` have
      # both bitten this codebase, and a NoMethodError from inside a tier is a
      # defect to surface rather than an outage to absorb.
      class Summarizing < Base
        # Reused, NOT a new symbol. {Oracle::Definition#digest} folds the
        # template and the schema as well as the tier, so this span question is
        # already a different oracle from the eager tool-result summarizer at
        # this same tier -- the separation a new symbol would buy is one the
        # template has already bought. Minting one would instead move an address
        # every existing {Oracle::Recorded} journal is keyed under, and those
        # miss LOUDLY ({Oracle::Recorded::Unrecorded}).
        TIER = :model

        # The slot {TEMPLATE} renders. Named for what it carries, and ours: this
        # question is about a span of conversation, never about a tool result.
        SLOT = :source

        # Deliberately says the summary REPLACES the messages, for the reason
        # {Oracle::Summarize::TEMPLATE} does: a summarizer that does not know it
        # is writing the only surviving record writes a table of contents
        # instead of a substitute.
        TEMPLATE = <<~ERB
          These messages are about to be replaced, in a later prompt, by your summary:

          <%= render("source") %>

          Summarize them. The summary will REPLACE this stretch of the
          conversation, so state what was asked, what was found, what was
          decided, and anything still open -- the facts a reader would otherwise
          have to go back to the originals for. Do not editorialize and do not
          offer to help.
        ERB

        # Hoisted, because a `[].freeze` literal allocates a fresh Array per
        # read and both of these are answered on every quiet span.
        NO_RANGES = [].freeze
        NOTHING = [].freeze
        private_constant :NOTHING

        # The oracle this strategy speaks to, as a value: a tier is built over
        # ONE definition, and the tier symbol, the template and the answer
        # schema are three halves of one address.
        #
        # THIS IS THE ONE DEFINITION OF THE SPAN QUESTION, and every consumer
        # keys off it -- {CLI::CompactionStrategy} builds the tier wrap
        # ({Oracle::Recorded::Journaling} over {Oracle::Model} live,
        # {Oracle::Recorded.from_journal} on resume) from here rather than
        # writing its own. A second definition of the same question is not a
        # duplicate but a FALSE RECORD: {Oracle::Model#ask} renders from the
        # definition IT holds while {Oracle::Recorded::Journaling} journals the
        # question rendered from the one IT was handed, so a mismatched pair
        # asks the model one question and records another under a third address,
        # with every spec green.
        #
        # {TEMPLATE} is therefore a JOURNAL ADDRESS and not only a prompt:
        # editing its wording silently re-keys every recorded answer, and the
        # miss ({Oracle::Recorded::Unrecorded}) surfaces on RESUME, after the
        # model has already been paid.
        #
        # @param tier [Symbol] see {TIER}
        # @return [Oracle::Definition]
        def self.definition(tier: TIER)
          Oracle::Definition.new(template: TEMPLATE, schema: Oracle::Summarize::SCHEMA, tier:)
        end

        # @param oracle [#ask] a tier over {.definition} -- {Oracle::Recorded}
        #   or {Oracle::Recorded::Journaling}, never a bare {Oracle::Model}
        # @param sink [Lain::Sink] where a tier's failure is reported; the Null
        #   sink by default, so no caller writes `if sink`
        def initialize(oracle:, sink: Sink::Null.new)
          super()
          # NOT frozen, and it never can be: holding an oracle is the point, and
          # it is what the purity refutation below rests on.
          @oracle = oracle
          @sink = sink
          @answers = Answers.new
        end

        # How many ranges were answered from an address already held, and how
        # many had to be asked about. {SummarySnapshot}'s discipline: a
        # mis-keyed address is invisible except as a count that never rises.
        def hits = @answers.hits

        def misses = @answers.misses

        # The whole span, whenever there is an answer for it. A range the oracle
        # could not answer is not proposed at all, which is how a tier that is
        # down leaves the derivation with those turns retained verbatim rather
        # than collapsed to nothing.
        def propose_ranges(messages, span:)
          blocks(Array(messages[span])).empty? ? NO_RANGES : [span]
        end

        # @return [Array<Hash>] one text block, or none at all -- which is DROP,
        #   the unit, and is what an empty span and an unanswerable one both
        #   collapse to.
        def blocks(messages)
          summary = summarized(messages)

          summary.nil? ? NOTHING : [{ "type" => "text", "text" => summary }]
        end

        # The whole-span analysis: this range's content address, which is the
        # key its answer is held under. See the class doc on why the address is
        # of the range's own bytes.
        def whole_span(messages) = Canonical.digest(messages)

        # The question's variable half -- the bytes {TEMPLATE} renders. Canonical
        # rather than pretty: deterministic, injective, and the same bytes
        # {#whole_span} addresses, so the question and the key cannot drift.
        def question(messages) = Canonical.dump(messages)

        private

        # What an elementwise reading of this strategy WOULD be: summarize each
        # message on its own. It exists so the negative is demonstrable -- the
        # laws need a per-element map to hold the operation against -- and the
        # analysis is deliberately unread, since a summary of one message does
        # not depend on the span it came from.
        def per_message(message, _analysis) = blocks([message])

        def summarized(messages)
          return nil if messages.empty?

          @answers.fetch(whole_span(messages)) { asked(messages) }
        end

        def asked(messages)
          @oracle.ask(SLOT => question(messages)).await.summary
        rescue Error => e
          @sink.puts("#{name} leaves #{whole_span(messages)} uncollapsed: #{e.class}: #{e.message}")
          nil
        end

        # Answers held by content address, with the two counts that say whether
        # holding them is working at all.
        #
        # THIS IS A CORRECTNESS CONDITION, NOT A SAVING. One range touches
        # {Summarizing#blocks} TWICE -- once when {#propose_ranges} asks whether
        # it can be collapsed, once through {Base#collapse} -- and
        # {Oracle::Recorded#ask} consumes a FIFO QUEUE per question
        # (`recorded.rb:73-78`), because two identical questions to a model can
        # legitimately have two different answers. So a second ask against one
        # journalled answer raises {Oracle::Recorded::Unrecorded}, which the
        # rescue above CONTAINS: the range would answer DROP and vanish from the
        # derived chain, silently, with no error and no sink line. Holding the
        # answer is what makes the pair one ask.
        #
        # It must therefore be held for at least the life of one derivation, and
        # it is held for the life of the strategy -- which is also why nothing
        # may freeze this object (see the class doc): a memo that quietly
        # stopped memoizing would put that silent vanishing back.
        #
        # A FAILURE is never held: an outage is transient, and memoizing one
        # would disable that range for the life of the strategy rather than for
        # one derivation.
        class Answers
          attr_reader :hits, :misses

          def initialize
            @summaries = {}
            @hits = 0
            @misses = 0
          end

          def fetch(address)
            return held(address) if @summaries.key?(address)

            @misses += 1
            answer = yield
            @summaries[address] = answer unless answer.nil?
            answer
          end

          private

          def held(address)
            @hits += 1
            @summaries.fetch(address)
          end
        end
        private_constant :Answers

        # Filed directly rather than through the concerns, which is the escape
        # hatch {Algebra::Elementwise}'s own doc names: for a structural property
        # the absence of the module IS the negative, and
        # {Algebra::Elementwise.not_elementwise} deliberately raises
        # {Algebra::Contradiction} on an includer. Below #blocks, because a
        # refutation is checked against the operation it names.
        Algebra.registry.refute(
          subject: self, operation: :blocks, structure: :elementwise,
          reason: "summarizing a concatenation is not the concatenation of summaries -- one span answers ONE " \
                  "block where its halves answer two, so no per-message map concatenates to #blocks"
        )

        Algebra.registry.refute(
          subject: self, operation: :blocks, structure: :pure,
          reason: "it holds an oracle, so it reaches mutable state and is not Ractor.shareable? -- which is why " \
                  "re-derivation needs the journalled answer rather than the edge alone"
        )
      end
    end
  end
end
