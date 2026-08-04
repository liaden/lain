# frozen_string_literal: true

module Lain
  module Compaction
    class Source
      # The derive-and-substitute step: THIS turn's derived chain, rendered as
      # the messages the provider will see.
      #
      # Its own object because {Source} is already at the {Metrics/ClassLength}
      # cap and this is a second responsibility anyway (CLAUDE.md: a tripped
      # cop names a missing object). {Source} decides WHETHER this turn
      # compacts; this decides WHAT it renders when it does.
      #
      # == Why a materialized array and not the {Derivation} itself
      #
      # {Scheduler::COMPOSE} calls `Ractor.make_shareable` on the composed
      # pipeline, and {Compaction::Strategy::Summarizing} holds a live oracle
      # and a mutable memo -- so it is not, and cannot be made, shareable.
      # `make_shareable` DEEP-FREEZES a plain object graph in silence rather
      # than raising, and the next new span would then die of an uncontained
      # `FrozenError` on the render path. So the derivation runs HERE, off the
      # pipeline, and only {Replay} -- a frozen combinator holding the finished
      # array -- ever crosses into it. That is what the Open decisions ruling
      # ("substituted as messages, not handed to `Context#render` as a
      # timeline") buys, and it is why nothing in this file may be captured by
      # the pipeline it feeds.
      #
      # == Pins are CUT POINTS, not shields
      #
      # {Derivation} takes no pin policy, by design: a pin splits one span into
      # several ranges rather than being lifted out of one (F8 -- `#ranges` is
      # an interval partition, and a pin is a cut point in it). {PinCuts} is
      # where that happens, and it is what keeps a pinned turn RETAINED, in
      # position, between the two replacements either side of it. The
      # partition-hoisting F3 measured is structurally unreachable from here:
      # the derivation writes retained turns in source order and can do nothing
      # else.
      #
      # A pinned turn whose tool counterpart is inside a collapsed range is a
      # different matter, and it is follow-up 14's hole. On this path it does
      # NOT ship the 400 the projection path ships: {Derivation} validates its
      # own projection through {Context::Conversation} and raises
      # {Derivation::Invalid}, so the turn falls back to the uncompacted render
      # and says so on the record ({Source::DerivationRefused}). Refusing is
      # not the repair -- a session pinned that way stops compacting for as
      # long as the pin stands -- which is why the record carries the streak.
      class Derived
        Outcome = Data.define(:replay, :hits, :misses) do
          # The derivation refused this turn's chain; the caller renders
          # uncompacted.
          def refused? = replay.nil?
        end

        # What this turn renders through, and what finding out cost.
        #
        # `hits`/`misses` are the POLICY's, not a snapshot's: a mis-keyed
        # content address is invisible except as a count that never rises
        # ({SummarySnapshot}'s discipline, `summary_snapshot.rb:23-30`), and
        # after this card the address that matters is the one the strategy
        # keys its answers under.
        class Outcome
          # Reopened rather than bodied inside the `Data.define(...) do ... end`
          # block: a constant declared there binds to the enclosing module, not to
          # the Data class (the trap {Request::SYSTEM_PREFIX} records).

          # A turn that deferred before any derivation was attempted. The rates
          # are honest zeros rather than the last derivation's, which is what
          # keeps a bench reading `summary_hits` from folding warm defers into
          # the hit rate.
          NOTHING = new(replay: nil, hits: 0, misses: 0)
        end

        # @param keep_last [Integer] the trailing messages the derivation
        #   retains verbatim -- {Source}'s own, so the two cannot disagree
        # @param strategy [Strategy::Base, nil] the policy `--compact-strategy`
        #   named. nil is the un-flagged wiring, which collapses a span into
        #   the run's own eager tier exactly as {Context::Compact} did (see
        #   {Held}) -- a default, not a Null: it is a real policy with a real
        #   answer, and it is the one every spec that injects nothing gets.
        # @param journal [#<<] where the derivation edge and any refusal land
        def initialize(keep_last:, strategy: nil, journal: Channel::Null.instance)
          @keep_last = keep_last
          @strategy = strategy
          @journal = journal
          @consecutive = 0
        end

        # Held here and asked back for the {Head}: the cut a derivation makes
        # and the span {Need} measures must come from ONE number.
        attr_reader :keep_last

        # @param timeline [Timeline] the SOURCE timeline; the derived chain is
        #   built in its own Store, which is the only store whose objects its
        #   replacements' causal edges can name
        # @param walk [Derivation::Walk] that timeline already walked and
        #   projected -- the caller decided on this very projection, so the
        #   derivation reads it rather than walking the chain a second time
        # @param pins [Context::PinnedMessages] this turn's pin set, the very
        #   value {Head} was measured with
        # @param snapshot [SummarySnapshot] the eager tier, frozen for this
        #   turn; read only by the un-flagged default policy
        # @return [Outcome]
        def over(timeline, walk:, pins:, snapshot:)
          policy = PinCuts.new(inner: @strategy || Held.new(snapshot), pins:)
          # BOUND FIRST, DELIBERATELY. `#replayed` is the only thing that runs
          # the strategy, so it is the only thing that moves its counters --
          # reading them in the same argument list would make the figures
          # correct purely because Ruby evaluates keyword arguments in source
          # order. Put `hits:` ahead of `replay:` there and every journalled
          # rate shifts back one turn, permanently and silently, with the whole
          # suite still green. That is the hazard {SummarySnapshot} warns about
          # ("invisible EXCEPT as a count that never rises") reproduced at the
          # site that READS the count. The local makes the ordering a statement.
          replay = replayed(policy, timeline, walk)

          Outcome.new(replay:, hits: policy.hits, misses: policy.misses)
        end

        private

        # The rescue is scoped to the ONE call that can raise {Invalid}, and
        # `policy` reaches it as a parameter rather than as a local a
        # method-level rescue would read before its assignment. A method-level
        # `rescue` sees `policy` as nil whenever anything ahead of it raises,
        # and the handler then dies of `NoMethodError` while reporting -- the
        # real error lost behind the reporting of it.
        def replayed(policy, timeline, walk)
          derived = derivation(policy).derive(timeline, walk:)
          @consecutive = 0
          Replay.new(Derivation.projected(derived.to_a))
        rescue Derivation::Invalid => e
          refused(policy, e)
          nil
        end

        # A fresh {Derivation} per turn, because the policy it is frozen around
        # is this turn's -- {PinCuts} closes over a pin set that moves. Both
        # are cheap frozen values, the same trade {Source#scheduler_for} makes.
        def derivation(policy) = Derivation.new(strategy: policy, keep_last: @keep_last, journal: @journal)

        # {Derivation::Invalid} and NOTHING wider. `NotAPartition`, `NotBlocks`,
        # `Blank`, `Sealed` and `Canonical::UnsupportedType` all mean the
        # STRATEGY is broken rather than the history awkward, and swallowing
        # them here would turn a defect into a session that quietly stopped
        # compacting. (`rescue StandardError` would also be wrong for the
        # opposite reason: `NotImplementedError < ScriptError` escapes it
        # entirely, so it neither catches what it should nor stops at what it
        # should.)
        #
        # ITS OWN RECORD TYPE, never a {Telemetry::ContextDerived} with empty
        # `spans`: that field's whole purpose is to make an empty collapse
        # readable, and a fallback wearing a derivation's badge would put back
        # the ambiguity `cut` was added to destroy.
        #
        # It does not raise, at any streak length. A deterministic strategy
        # over a stable history refuses identically every turn, forever -- the
        # silent-stop mode wearing a badge -- but raising inside the render
        # path over a history that is perfectly legal is worse than not
        # compacting ({Boundary}'s own argument). So the STREAK is on the
        # record instead: a bench arm reads `consecutive` rising and knows the
        # difference between one awkward turn and a session that has stopped.
        def refused(policy, error)
          @consecutive += 1
          @journal << DerivationRefused.new(strategy: policy.name, violations: error.message,
                                            consecutive: @consecutive)
        end

        # A combinator that discards whatever `#render` projected and
        # substitutes the derived chain. {Compaction::Prepared}'s own `Replay`
        # is the shape (`prepared.rb:138-146`) and not the object: that one is
        # `private_constant` and computes its compaction from a `compact:`
        # collaborator, which is the wrong collaborator for a derived chain.
        #
        # `Ractor.make_shareable` on the messages and not merely `freeze` on
        # self. {Scheduler::COMPOSE} makes a PROC shareable, and that does not
        # deep-freeze what the Proc refers to -- it RAISES on anything not
        # already shareable, so a frozen combinator holding an ordinary Array
        # fails with `Ractor::IsolationError` on the first compacting turn of
        # every real chat. (Measured: the A8 regression at
        # `wiring_spec.rb:397-403` is exactly this, one object further in.)
        # Deep-freezing here is safe because the array is ours -- built by
        # {Derivation.projected} out of already-frozen event bodies -- and it is
        # what makes "substituted as messages" a shareability argument rather
        # than a hope.
        class Replay < Context::Combinator
          def initialize(messages)
            super()
            @messages = Ractor.make_shareable(messages)
            freeze
          end

          def call(_messages) = @messages

          # The parameter `#call` ignores, declared so {Context#render} stops
          # BUILDING it: without this the render walks the whole source chain
          # and projects every turn of it, on every compacting turn, to hand
          # this method an argument it drops on the floor -- a third full walk
          # of a lineage this turn has already walked twice.
          def reads_messages? = false
        end
        private_constant :Replay

        # The un-flagged policy: collapse a span into the run's eager tier,
        # which is byte-for-byte what {Context::Compact} rendered through this
        # same {SummarySnapshot}. It exists so that moving the render onto the
        # derived chain does not silently retire the tool-result summarizer
        # tier -- the eager fires, the snapshot holds, and this is what reads
        # them back.
        #
        # One range for the whole span it is offered: the snapshot summarizes
        # per MESSAGE and attests the rest, so where a cut falls changes only
        # how many replacement events carry the same lines.
        class Held < Strategy::Base
          def initialize(snapshot)
            super()
            @snapshot = snapshot
            freeze
          end

          # {SummarySnapshot} counts what it held and what it had to elide,
          # which is the bench's read on whether the eager fires are landing.
          def hits = @snapshot.hits

          def misses = @snapshot.misses

          def propose_ranges(_messages, span:) = [span]

          def blocks(messages) = [{ "type" => "text", "text" => @snapshot.call(messages) }]
        end
        private_constant :Held

        # A policy cut at the pins: the span becomes one sub-span per
        # contiguous run of UNPINNED messages, and the inner policy is asked
        # about each. Everything a pin separates stays separated, and the
        # pinned turns themselves fall in no range at all -- so the derivation
        # retains them, verbatim and in position, without ever being told that
        # pins exist.
        #
        # It answers the INNER policy's name, so the journalled edge and every
        # refusal name the strategy an operator chose rather than this wrapper.
        class PinCuts < Strategy::Base
          def initialize(inner:, pins:)
            super()
            @inner = inner
            @pins = pins
            # SHALLOW, like every other frozen wrapper here: it fixes this
            # object's own two references and says nothing about `inner`, which
            # is an operator-chosen strategy that may legitimately hold a live
            # oracle and a mutable memo and must NOT be frozen (see the class
            # doc's `make_shareable` paragraph). Its two siblings freeze; this
            # is the one wrapping something a flag chose, so it is the one
            # where an accidental ivar rebind would be hardest to find.
            freeze
          end

          def name = @inner.name

          def hits = @inner.hits

          def misses = @inner.misses

          # `#ranges` and not `#propose_ranges` on the inner: the inner's
          # answer is validated against the run it was asked about, and this
          # object's own answer is then validated against the whole span by
          # {Strategy::Base#ranges}. Two checks over two different questions,
          # neither of which subsumes the other.
          def propose_ranges(messages, span:)
            runs(span, @pins.indices_in(messages)).flat_map { |run| @inner.ranges(messages, span: run) }
          end

          def blocks(messages) = @inner.blocks(messages)

          # THE ONE THE COLLAPSE TAKES, and it has to be forwarded separately:
          # this wrapper sits between the derivation and EVERY operator-supplied
          # strategy (`:103`), so an inner {Strategy::Composed} -- which routes a
          # collapse by the range's tag and implements no `#blocks` of its own --
          # reached the delegation above, fell through to
          # {Strategy::Base#blocks}, and died of NotImplementedError with its
          # ranges perfectly correct.
          def blocks_for(messages, range) = @inner.blocks_for(messages, range)

          private

          # The runs a cut leaves are an interval partition of the span in their
          # own right, so they are built by the value that owns that shape --
          # and a refusal in them names `IntervalPartition.covering` rather than
          # an inner hook nobody asked.
          def runs(span, pinned)
            IntervalPartition.covering(span, excluding: pinned, owner: cutter).validated
          end

          # NOT {Strategy::Base#name}, which this class overrides to answer the
          # INNER strategy. That is right for the journalled edge and wrong here:
          # computing the runs is this wrapper's own work, and a fault in it must
          # not be reported against the strategy an operator chose.
          def cutter = -(self.class.name || self.class.to_s)
        end
        private_constant :PinCuts
      end
    end
  end
end
