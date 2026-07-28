# frozen_string_literal: true

module Lain
  module Compaction
    # The drift guard over "journal the edge, re-derive the chain": read
    # {Telemetry::ContextDerived} records back, re-derive each one over the
    # source it names, and say whether the same derived head comes out.
    #
    # The ruling is only trustworthy if something checks it, and this is that
    # something. It is also the record's READER: nothing reads a `compaction`
    # record back today (Grounding F7), and a write-only trace is this
    # subsystem's default failure mode -- a field nobody consumes drifts from
    # what it claims to mean without a single spec going red.
    #
    # == It re-derives; it does not replay
    #
    # The derived EVENTS are deliberately not journalled ({Telemetry::ContextDerived}'s
    # own doc says why), so there is nothing here to compare event-by-event.
    # What the edge holds is enough to REBUILD: a deterministic strategy is a
    # pure function of its source, and a model-backed one answers through
    # {Oracle::Recorded}, whose answers were journalled separately. So this
    # object is handed the source's Store and a strategy builder per name, and
    # it does the derivation again -- {Bench::Session::ChainFold}'s discipline
    # (`chain_fold.rb:13-19`) one level up: a digest is vouched for exactly when
    # a rebuild reproduced it, so {#agreed?} can never answer true for bytes
    # nothing re-derived.
    #
    # That discipline is why a record is CHECKED BEFORE IT IS BELIEVED. A
    # `context_derived` line carrying no heads at all would re-derive the empty
    # timeline to the empty timeline, and `nil == nil` would report an agreement
    # about nothing -- the inversion of the whole posture. Every record
    # therefore goes through {Telemetry::Guards::ContextDerived}, the record
    # type's own WRITE-side guard, plus a check that the keys it does not cover
    # are present at all; anything else is {Finding::Unverifiable}. This is not
    # defensiveness: `journal.rb:93-97` says the fd is shared with foreign
    # writers, and the record type is still growing, so a reader WILL meet a
    # line it did not write. Unknown fields are ignored, which is what keeps
    # that forward-compatible.
    #
    # A genuine empty-source edge is {Finding::Vacuous} rather than an
    # agreement, for the same reason: it vouches for no bytes, so a journal of
    # nothing but those is {#nothing_to_check?}.
    #
    # == Offline, and it opens nothing
    #
    # {SessionRecord::Salvage}'s posture (`salvage.rb:56-63`): a pure function of
    # the ducks it is handed -- `entries` ({Journal.records}'s duck: parsed
    # Hashes or raw NDJSON lines), a Store, a name => builder map and an
    # {Algebra::Registry}. It touches no file, holds no session, and is on no
    # render path. Foreign and unparseable lines are skipped by {Journal.records}
    # because that is the contract and not a convenience -- the Journal's fd can
    # be shared with other writers, and a reader that raised over somebody
    # else's bytes would make the audit the fragile thing in the room.
    #
    # == IT GROWS THE STORE IT IS HANDED, IN PROPORTION TO THE DRIFT IT FINDS
    #
    # A re-derivation commits into the source's own Store, because a
    # replacement's causal edges name source digests and {Derivation} refuses
    # any other store. Content addressing makes an AGREEING audit free -- every
    # object it writes is already there, measured at 30 objects in and 30 out.
    # A DISAGREEING one is not: each such record leaves a dead chain behind
    # (measured 30 -> 37 -> 45 for two disagreeing audits of one record), and
    # nothing collects it, because the Store is append-only and a Timeline is a
    # handle rather than an owner.
    #
    # Each chain is bounded by `keep_last` plus the number of ranges, never by
    # history length, so this is bounded garbage rather than a leak -- and it is
    # unreachable from the session timeline, so {Ledger#unique_turns} (which
    # walks render ancestry) prices none of it. But a caller hunting drift over
    # a long journal should hand this a Store it is willing to have grown, or
    # re-load one from the session record afterwards. A copy-on-write Store
    # would make the question go away, and is a Store-level design decision
    # rather than this reader's to take.
    #
    # == Why `keep_last` is a parameter, and why the spans are compared anyway
    #
    # The record does not carry the window. {Telemetry::ContextDerived} names the
    # source, the derived head, the strategy, the spans, the cut and the
    # distance walked -- not the window the {Boundary} was built with. So the
    # caller supplies it.
    #
    # Which means the auditor's own configuration can produce a disagreement,
    # and a guard that cries "derivation bug" at its own misconfiguration is a
    # guard that gets muted -- F7's write-only trace with extra steps. So the
    # re-derivation is asked for ITS OWN edge ({Derivation} takes any `#<<` duck
    # as `journal:`) and the two edges are compared before any verdict is
    # reached.
    #
    # T9 has since added `keep_last` to the record. This reader still prefers
    # its parameter and ignores that field; switching the precedence -- record
    # first, parameter as the fallback for older journals -- is a filed
    # follow-up. The comparison stays either way, and this is why: the field
    # says which window was CONFIGURED, while comparing re-derived spans proves
    # the boundary LANDED where the record says.
    #
    # THE COMPARISON IS SOUND RATHER THAN HEURISTIC, and this is the property
    # that makes it so. {Derivation}'s `Plan#writes` retains every turn outside
    # a proposed range whatever the boundary index was, so the derived chain is
    # a function of (source turns, ranges) and the window reaches the head ONLY
    # through the ranges. Equal ranges therefore imply an equal head. Two
    # consequences, both load-bearing: a real window error for a deterministic
    # strategy CANNOT be missed by this comparison (a window that moved the
    # ranges moved the head, and one that did not is not an error), and a window
    # difference that changes no range correctly reports {Finding::Agreement} at
    # both windows rather than a drift nobody made.
    #
    # == The diagnosis, and the authorities it asks
    #
    # In order, because each question is only meaningful once the one before it
    # is settled:
    #
    #   :window_disagrees   -- the ranges differ, and either the BOUNDARY itself
    #     differs (`cut` and `moved` are its own outputs and consult no
    #     strategy) or the strategy is DECLARED pure, in which case it is a
    #     function of the span it was offered and could only have been offered a
    #     different one.
    #   :window_or_replay   -- the boundary did not move, the ranges did, and
    #     the strategy answers from outside the source. Both causes stay open,
    #     because a wrong window changes the span, hence the question, hence the
    #     content address -- so a question-keyed {Oracle::Recorded} misses on it
    #     exactly as a short recording does, and proposes no range either way.
    #     Naming one cause here would be the same guess {#purity} refuses to
    #     make.
    #   :derivation_bug     -- the ranges agree and the strategy is declared
    #     pure, so the same source must give the same head; or `cut` is not
    #     `:offered`, meaning the strategy was never asked and its purity cannot
    #     be what a drift is about.
    #   :incomplete_replay  -- the ranges agree, and the strategy is REFUTED
    #     pure: it reaches outside the source, and the same span answering
    #     differently says the replay was handed different answers.
    #   :unclaimed_purity   -- the registry makes no claim either way, so the
    #     drift cannot be attributed. Loud, per CLAUDE.md's premise: the wrong
    #     answer here is to guess "not pure", which reads as a positive claim
    #     about a class the registry has said nothing about -- and for a
    #     SUBCLASS of a pure strategy ({Algebra::Registry#declares?} matches the
    #     exact subject) it would be a claim the registry contradicts.
    #
    # `moved` is read ONLY as half of the boundary comparison, never as a
    # verdict: it is a distance whose meaning depends on the `cut` beside it.
    #
    # Purity is asked of an injected {Algebra::Registry} rather than answered
    # here. {Algebra::Pure}'s doc says it in as many words -- `is_a?` is not the
    # classification, the registry is -- and a second notion of purity living in
    # an audit is precisely the drift this class exists to catch.
    class DerivationAudit
      include Enumerable

      # A `strategies:` entry that is not a builder, or a builder that does not
      # answer a strategy. Raised rather than reported: a reader may be tolerant
      # about the bytes it reads and must not be tolerant about the objects it
      # was handed, and the alternative is a `NoMethodError` three frames down
      # naming neither the record nor the journalled name.
      class NotAStrategy < Error; end

      # {Telemetry::ContextDerived}'s discriminator ({Telemetry::Journalable#journal_type}).
      TYPE = "context_derived"

      # The one `cut` under which a strategy was actually asked something. The
      # other two are `:empty` and `:declined`; no journal anywhere carries a
      # `:declined` (the record type ships with this chunk and a derivation
      # cannot reach one), so nothing here waits for one -- it falls in with
      # `:empty` under "the strategy was never asked", which is what both mean.
      OFFERED = "offered"

      # The operation a purity claim is about. {Strategy::Base#blocks} is what
      # the algebra declares over, never `#collapse` (which answers a
      # {Strategy::Replacement}, not a monoid element).
      BLOCKS = :blocks

      # What a record must carry to be the thing it says it is. `strategy`,
      # `spans` and `cut` are checked for CONTENT by the write-side guard as
      # well; these five are checked for PRESENCE, because a missing key and a
      # nil value are different bugs and an absent `spans` passes that guard.
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
      #   address and may not be frozen, and {Oracle::Recorded} consumes a FIFO
      #   queue per question. One instance across a journal therefore couples
      #   records to one another -- a record this audit SKIPS (an absent source,
      #   a malformed line) leaves that state unconsumed, and every later record
      #   for the same strategy replays against it. Building per record makes
      #   each judgement independent of the ones before it, which is the only
      #   reading under which a single finding means anything on its own.
      #
      #   So a builder must CONSTRUCT its strategy, never close over one: a
      #   builder answering the same instance every time satisfies this duck and
      #   restores exactly the coupling it exists to remove, silently, because
      #   the shared memo is invisible from here.
      # @param registry [Algebra::Registry] where the purity claim is read; the
      #   process-wide one by default, injectable because that is the {Algebra}
      #   module's own contract for every verb it offers.
      def initialize(entries:, store:, keep_last:, strategies: {}, registry: Algebra.registry)
        @entries = entries
        @store = store
        @keep_last = keep_last
        @strategies = strategies
        @registry = registry
      end

      # Memoized like {Bench::Session::ChainFold#timeline}: a re-derivation may
      # ask an oracle, and {Enumerable} would otherwise pay for one per message
      # sent to this object.
      #
      # `to_a` is what makes that memo real. {Journal.records} is lazy so a
      # reader can stream a file, and a lazy `map` held in an ivar is a RECIPE:
      # it re-derives on every walk, and `#empty?` -- which {Enumerator::Lazy}
      # does not answer at all -- is how that announced itself here.
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

      # Ordered by what each answer costs and by what it would otherwise hide: a
      # malformed record is judged by nobody, an empty one vouches for nothing,
      # and neither is worth building a strategy for.
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

      # Three-valued, because {Algebra::Registry} distinguishes three states and
      # collapsing "refuted" with "never claimed" turns silence into a positive
      # claim. Asked of the EXACT class, as the registry files it: a subclass
      # inherits its parent's `#blocks` but not its parent's declaration.
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
      # that is not a partition, a causal edge the store never saw. An audit is a
      # reader over bytes that can be wrong, so a refusal is REPORTED (naming the
      # class, which is the diagnosis) rather than allowed to abort the rest of
      # the journal. It is not a drift: no second head was produced to disagree.
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
# `private_constant` on it -- so they load after the class body, the same order
# `effect/handler.rb` loads its subclasses in.
require_relative "derivation_audit/edge"
require_relative "derivation_audit/diagnosis"
require_relative "derivation_audit/finding"
