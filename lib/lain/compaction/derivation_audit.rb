# frozen_string_literal: true

module Lain
  module Compaction
    # The drift guard over "journal the edge, re-derive the chain": read
    # {Telemetry::ContextDerived} records back, re-derive each one over the
    # source it names, and say whether the same derived head comes out.
    #
    # It is also the record's READER. Nothing else reads a `compaction` record
    # back, and a write-only trace is this subsystem's default failure mode --
    # a field nobody consumes drifts from what it claims to mean without a
    # single spec going red.
    #
    # == It re-derives; it does not replay
    #
    # The derived EVENTS are deliberately not journalled, so there is nothing
    # here to compare event by event. The edge holds enough to REBUILD: a
    # deterministic strategy is a pure function of its source, and a
    # model-backed one answers through {Oracle::Recorded}, whose answers were
    # journalled separately. So a digest is vouched for exactly when a rebuild
    # reproduced it ({Bench::Session::ChainFold}'s discipline), and {#agreed?}
    # can never answer true for bytes nothing re-derived.
    #
    # That is why a record is CHECKED BEFORE IT IS BELIEVED. A
    # `context_derived` line carrying no heads would re-derive the empty
    # timeline to the empty timeline, and `nil == nil` would report an
    # agreement about nothing -- the inversion of the whole posture. Every
    # record therefore goes through {Telemetry::Guards::ContextDerived}, the
    # record type's own WRITE-side guard, plus a presence check on the keys it
    # does not cover; anything else is {Finding::Unverifiable}. Not
    # defensiveness: the Journal's fd is shared with foreign writers and the
    # record type is still growing, so a reader WILL meet a line it did not
    # write. Unknown fields are ignored, which keeps that forward-compatible.
    # A genuine empty-source edge is {Finding::Vacuous} rather than an
    # agreement, for the same reason -- it vouches for no bytes.
    #
    # Offline, and it opens nothing: a pure function of the ducks it is handed,
    # touching no file, holding no session, on no render path.
    #
    # == It grows the Store it is handed, in proportion to the drift it finds
    #
    # A re-derivation commits into the source's own Store, because a
    # replacement's causal edges name source digests and {Derivation} refuses
    # any other store. Content addressing makes an AGREEING audit free -- every
    # object it writes is already there, measured at 30 objects in and 30 out.
    # A DISAGREEING one is not: each such record leaves a dead chain behind
    # (measured 30 -> 37 -> 45 for two disagreeing audits of one record), and
    # nothing collects it, because the Store is append-only and a Timeline is a
    # handle rather than an owner. Each chain is bounded by `keep_last` plus
    # the number of ranges, never by history length, so this is bounded garbage
    # rather than a leak, and it is unreachable from the session timeline, so
    # {Ledger#unique_turns} prices none of it. Still: hand this a Store you are
    # willing to have grown, or re-load one from the session record afterwards.
    #
    # == Why `keep_last` is a parameter, and why the spans are compared anyway
    #
    # The record does not carry the window, so the caller supplies it -- which
    # means the auditor's own configuration can produce a disagreement, and a
    # guard that cries "derivation bug" at its own misconfiguration is a guard
    # that gets muted. So the re-derivation is asked for ITS OWN edge and the
    # two edges are compared before any verdict is reached. (The record has
    # since gained a `keep_last` field; this reader still prefers its
    # parameter. The comparison stays either way: the field says which window
    # was CONFIGURED, while comparing re-derived spans proves the boundary
    # LANDED where the record says.)
    #
    # The comparison is SOUND rather than heuristic. {Derivation}'s
    # `Plan#writes` retains every turn outside a proposed range whatever the
    # boundary index was, so the derived chain is a function of (source turns,
    # ranges) and the window reaches the head ONLY through the ranges. Equal
    # ranges therefore imply an equal head: a real window error for a
    # deterministic strategy CANNOT be missed, and a window difference that
    # changes no range correctly reports {Finding::Agreement} at both windows
    # rather than a drift nobody made.
    #
    # == The diagnosis, and the authorities it asks
    #
    # {DIAGNOSES} states each verdict in the finding's own voice, and
    # {Diagnosis} asks them in the order it does because each question is only
    # meaningful once the one before it is settled. Two things that live
    # nowhere else: `:derivation_bug` also covers a `cut` that is not
    # `:offered`, where the strategy was never asked and its purity cannot be
    # what a drift is about; and `moved` is read ONLY as half of the boundary
    # comparison, never as a verdict, since it is a distance whose meaning
    # depends on the `cut` beside it.
    #
    # Purity is asked of an injected {Algebra::Registry} rather than answered
    # here -- `is_a?` is not the classification, the registry is -- because a
    # second notion of purity living in an audit is precisely the drift this
    # class exists to catch.
    class DerivationAudit
      include Enumerable

      # A `strategies:` entry that is not a builder, or a builder that does not
      # answer a strategy. Raised rather than reported: a reader may be tolerant
      # about the bytes it reads and must not be tolerant about the objects it
      # was handed, and the alternative is a `NoMethodError` three frames down
      # naming neither the record nor the journalled name.
      class NotAStrategy < Error; end

      # {Telemetry::ContextDerived}'s discriminator.
      TYPE = "context_derived"

      # The one `cut` under which a strategy was actually asked something.
      # `:declined` needs no case of its own -- no derivation can reach one --
      # so it falls in with `:empty` under "the strategy was never asked".
      OFFERED = "offered"

      # The operation a purity claim is about. {Strategy::Base#blocks} is what
      # the algebra declares over, never `#collapse` (which answers a
      # {Strategy::Replacement}, not a monoid element).
      BLOCKS = :blocks

      # Checked for PRESENCE, because a missing key and a nil value are
      # different bugs and an absent `spans` passes the write-side guard.
      REQUIRED = %w[source_head derived_head strategy spans cut].freeze

      # The two fields that name content addresses, checked for shape as well as
      # presence -- see {Edge#misshapen}.
      HEADS = %w[source_head derived_head].freeze

      # Which fault a drift points at, given what the registry says about the
      # strategy's purity.
      VERDICTS = { pure: :derivation_bug, impure: :incomplete_replay, unclaimed: :unclaimed_purity }.freeze

      # What each diagnosis is claiming, in the finding's own voice.
      DIAGNOSES = {
        derivation_bug: "the strategy is declared pure on #blocks, so the same source must derive the same " \
                        "head -- the derivation itself has changed",
        incomplete_replay: "the strategy is refuted pure, so it answers from outside the source -- the replay " \
                           "was handed different answers, which is an incomplete oracle replay rather than a " \
                           "derivation bug",
        unclaimed_purity: "the registry makes no claim about pure on #blocks for this exact class, so this " \
                          "drift cannot be attributed to either side -- declare or refute it, then audit again",
        window_disagrees: "the two derivations did not collapse the same ranges, and the strategy is declared " \
                          "pure, so it was offered a different span -- check the keep_last this audit was " \
                          "given, which the record does not carry",
        window_or_replay: "the boundary did not move but the ranges did, and this strategy answers from " \
                          "outside the source, so BOTH remain open: the keep_last this audit was given may be " \
                          "wrong (a different span is a different question, which a question-keyed replay " \
                          "misses exactly as a short one does), or the replay may be missing an answer. The " \
                          "record cannot tell the two apart"
      }.freeze

      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
      # @param store [Lain::Store] the store holding the source chains the edges
      #   name. The re-derivation writes into it -- see the class doc; hand in
      #   one you are willing to have grown.
      # @param keep_last [Integer] the window the audited run derived with
      # @param strategies [#[]] journalled strategy name => a BUILDER answering
      #   a FRESH strategy per record. Keyed on what the edge carries, which for
      #   an anonymous strategy is `"(anonymous strategy)"` -- unresolvable by
      #   name, and reported as such rather than guessed at.
      #
      #   A builder rather than an instance because a replay strategy is
      #   STATEFUL BY DESIGN: {Strategy::Summarizing} memoizes per content
      #   address, and {Oracle::Recorded} consumes a FIFO queue per question.
      #   One instance across a journal couples records to one another -- a
      #   record this audit SKIPS leaves that state unconsumed, and every later
      #   record for the same strategy replays against it. So a builder must
      #   CONSTRUCT its strategy, never close over one: a builder answering the
      #   same instance every time satisfies this duck and silently restores
      #   exactly the coupling it exists to remove.
      # @param registry [Algebra::Registry] where the purity claim is read; the
      #   process-wide one by default, injectable because that is the {Algebra}
      #   module's contract for every verb it offers.
      def initialize(entries:, store:, keep_last:, strategies: {}, registry: Algebra.registry)
        @entries = entries
        @store = store
        @keep_last = keep_last
        @strategies = strategies
        @registry = registry
      end

      # Memoized: a re-derivation may ask an oracle, and {Enumerable} would
      # otherwise pay for one per message sent to this object.
      #
      # `to_a` is what makes that memo real. {Journal.records} is lazy so a
      # reader can stream a file, and a lazy `map` held in an ivar is a RECIPE
      # that re-derives on every walk -- `#empty?`, which {Enumerator::Lazy}
      # does not answer at all, is how that announced itself here.
      #
      # @return [Array<Finding>] one per derivation edge, in journal order
      def findings
        @findings ||= Journal.records(@entries, type: TYPE).map { |record| judged(Edge.new(record:)) }.to_a
      end

      def each(&block) = findings.each(&block)

      # The findings that are evidence about bytes -- everything but {Finding::Vacuous}.
      def checked = findings.select(&:checkable?)

      # Nothing on this journal vouched for any bytes: no derivation edge at
      # all, or none about a non-empty source. Distinct from agreement, and the
      # whole reason {#agreed?} asks.
      def nothing_to_check? = checked.empty?

      # True only when something was actually rebuilt and every rebuild matched.
      def agreed? = !nothing_to_check? && checked.all?(&:agreed?)

      private

      # Ordered by what each answer costs: a malformed record is judged by
      # nobody, an empty one vouches for nothing, and neither is worth building
      # a strategy for.
      def judged(edge)
        return malformed(edge) unless edge.complete?
        return Finding::Vacuous.new(strategy: edge.strategy, source_head: edge.source_head) if edge.vacuous?
        return absent(edge) unless held?(edge.source_head)

        strategy = built(edge)
        strategy.nil? ? unresolved(edge) : compared(edge, strategy)
      end

      # A `nil` source head is the EMPTY timeline, which is a source like any
      # other rather than a missing object -- {Edge#vacuous?} has already taken
      # that case, so this only guards a named digest.
      def held?(head) = head.nil? || @store.key?(head)

      def built(edge)
        builder = @strategies[edge.strategy]

        builder.nil? ? nil : answering(edge, builder)
      end

      def answering(edge, builder)
        refuse_unbuildable(edge, builder)
        builder.call.tap { |strategy| refuse_unusable(edge, strategy) }
      end

      # `respond_to?`, not `is_a?`: a strategy is a duck here as everywhere, and
      # {Strategy::Base} deliberately answers no `#call`, which is what lets a
      # builder and a strategy be told apart at all.
      def refuse_unbuildable(edge, builder)
        return if builder.respond_to?(:call)

        raise NotAStrategy, "#{edge.strategy.inspect} is registered as #{builder.inspect}, which does not " \
                            "answer #call; the strategies map holds BUILDERS, one fresh strategy per record"
      end

      # Both refusals name the journalled strategy AND what was found: the
      # mistake is in the caller's map, and the record is how they find which
      # entry made it.
      def refuse_unusable(edge, strategy)
        return if strategy.respond_to?(:ranges) && strategy.respond_to?(:collapse)

        raise NotAStrategy, "the builder for #{edge.strategy.inspect} answered #{strategy.inspect}, which does " \
                            "not answer #ranges and #collapse"
      end

      def compared(edge, strategy)
        rebuilt = []
        head = Derivation.new(strategy:, keep_last: @keep_last, journal: rebuilt)
                         .derive(Timeline.new(head_digest: edge.source_head, store: @store)).head_digest
        return agreement(edge, head) if head == edge.derived_head

        drift(edge, head, Edge.of(rebuilt.fetch(0)), purity(strategy.class))
      rescue Error => e
        refused(edge, e)
      end

      def agreement(edge, head)
        Finding::Agreement.new(strategy: edge.strategy, source_head: edge.source_head,
                               recorded: edge.derived_head, rederived: head)
      end

      def drift(edge, head, rebuilt, purity)
        Finding::Drift.new(strategy: edge.strategy, source_head: edge.source_head, recorded: edge.derived_head,
                           rederived: head, diagnosis: Diagnosis.new(recorded: edge, rebuilt:, purity:).name)
      end

      # Three-valued, because collapsing "refuted" with "never claimed" turns
      # silence into a positive claim. Asked of the EXACT class, as the
      # registry files it: a subclass inherits its parent's `#blocks` but not
      # its parent's declaration.
      def purity(subject)
        return :pure if @registry.declares?(subject:, operation: BLOCKS, structure: :pure)

        refuted?(subject) ? :impure : :unclaimed
      end

      def refuted?(subject)
        @registry.refutations.any? do |entry|
          entry.subject == subject && entry.operation == BLOCKS && entry.structure == :pure
        end
      end

      def malformed(edge)
        unverifiable(edge, "it is not a #{TYPE} record: #{edge.violations.join("; ")}")
      end

      def unresolved(edge)
        unverifiable(edge, "no strategy builder is registered under that name")
      end

      def absent(edge)
        unverifiable(edge, "the store does not hold that source head, so there is nothing to re-derive over")
      end

      # A {Derivation} can legitimately refuse -- an invalid chain, a proposal
      # that is not a partition, a causal edge the store never saw. A refusal is
      # REPORTED rather than allowed to abort the rest of the journal, and it is
      # not a drift: no second head was produced to disagree.
      def refused(edge, error)
        unverifiable(edge, "re-deriving it raises #{error.class}: #{error.message}")
      end

      def unverifiable(edge, reason)
        Finding::Unverifiable.new(strategy: edge.strategy, source_head: edge.source_head, reason: reason.freeze)
      end
    end
  end
end

# All three reopen the class above -- and read its constants, and are marked
# `private_constant` on it -- so they load after the class body.
require_relative "derivation_audit/edge"
require_relative "derivation_audit/diagnosis"
require_relative "derivation_audit/finding"
