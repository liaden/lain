# frozen_string_literal: true

module Lain
  module Grader
    # GR-3 (T11): behavioral failure signals -- an agent stuck re-trying the
    # same tool after it errored -- walked back through the causal DAG to the
    # turn that plausibly caused them, rather than credited to whichever turn
    # happens to sit immediately before.
    #
    # Built on T8's {ToolCallIndex}: `#calls` supplies the deterministic
    # name/is_error signal per turn, and `#lineage` supplies the causal walk
    # (render `parent`, then -- at a chain root -- `spawned_from`) that
    # attribution rides. T8's own doc names this exact mechanism as "how GR-3
    # resolves an outcome back to its causing turn across a fan-out," so
    # {#nearest_prior_use} spends no new machinery inventing a second walk --
    # it climbs {ToolCallIndex#lineage}'s ancestors and skips any that did not
    # call the same tool. That skip is the whole point: a decoy call to an
    # UNRELATED tool sitting between the failure and the repeat never earns
    # the attribution just for being closer in turn order. Attribution is
    # over CONTENT-ADDRESSED LINEAGE, never turn-ordinal proximity.
    #
    # The mechanical floor stays regex/loop-detection-simple ON PURPOSE: "the
    # same tool name was retried after an is_error outcome" needs no model,
    # so it can never make the grader's answer depend on a live API call --
    # DryReplay-reproducible by construction. A genuinely fuzzy judgment --
    # "is this differently-shaped retry still the same frustrated attempt,
    # even though the prior call technically succeeded?" -- is gated behind
    # the injected `oracle:`, Null by default ({NullOracle}, the same seam
    # shape as {Middleware::RefuseSecretWrites::NullOracle}). The oracle is
    # consulted ONLY where the mechanical floor already declined to signal
    # (the prior use succeeded), so a live oracle can only ADD signals beyond
    # the deterministic floor, never suppress or relabel one of its own.
    #
    #   FrustrationRepair.new.grade(Journal.records(File.foreach(path)))
    #   #=> Grade(score: 0.0, pass: false, why: "1 frustration signal, 0 repaired: ..." ...)
    #
    # {ToolCallIndex#lineage} is a single deterministic path (a turn's
    # `parent` OR, only at a root, its `spawned_from` -- never both), so it
    # can never itself branch into more than one ancestor. `caused_by` is
    # still an Array, not a bare digest: {Timeline#causal_meets}'s documented
    # shape is the set of maximal common ancestors at a criss-cross causal
    # fan-in, and a journaled `turn` record ({SessionRecord.turn}) carries no
    # `causal_parents` field to reconstruct that richer walk from -- so this
    # mechanical floor cannot itself produce more than one cause today, but a
    # caller reading `caused_by` must never assume a single element, because
    # the type does not promise one.
    class FrustrationRepair
      # The fuzzy-signal seam, Null by default: mirrors
      # {Middleware::RefuseSecretWrites::NullOracle} -- one swappable arm over
      # one interface, decided without a model call until one is wired in.
      class NullOracle
        def frustrated?(_prior_call, _next_call) = false

        INSTANCE = new.freeze

        def self.instance = INSTANCE
      end

      # One detected signal. `caused_by` is an Array of turn digests (see the
      # class doc's note on why it is never a bare String). `repaired` is
      # whether THIS turn's own call succeeded -- the retry that ends the
      # loop, as opposed to one that persists it. `source` says which arm
      # found it: `:mechanical` (the deterministic floor) or `:oracle` (the
      # injected fuzzy signal).
      Signal = Data.define(:kind, :turn_digest, :caused_by, :repaired, :source, :why)

      # @param oracle [#frustrated?] the fuzzy-signal seam; Null by default
      def initialize(oracle: NullOracle.instance)
        @oracle = oracle
        freeze
      end

      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck,
      #   the same input {ToolCallIndex} takes
      # @return [Grade] score = fraction of signals repaired (1.0 with none
      #   detected -- nothing went wrong is a clean pass, not a zero)
      def grade(entries)
        found = signals(entries)
        Grade.new(score: score(found), pass: found.all?(&:repaired), why: explain(found))
      end

      # @param entries [Enumerable<Hash, String>]
      # @return [Array<Signal>] every detected signal, turn order, frozen
      def signals(entries)
        index = ToolCallIndex.new(entries)
        index.calls.flat_map { |digest, calls| calls.filter_map { |call| detect(index, digest, call) } }.freeze
      end

      private

      def detect(index, digest, call)
        prior = nearest_prior_use(index, digest, call.name)
        return nil unless prior

        mechanical_signal(digest, call, prior) || oracle_signal(digest, call, prior)
      end

      def mechanical_signal(digest, call, prior)
        return nil unless prior.last.is_error

        build_signal(digest, call, prior, source: :mechanical,
                                          why: "#{call.name} retried at #{short(digest)} after it errored " \
                                               "at #{short(prior.first)}")
      end

      def oracle_signal(digest, call, prior)
        return nil if prior.last.is_error
        return nil unless @oracle.frustrated?(prior.last, call)

        build_signal(digest, call, prior, source: :oracle,
                                          why: "#{call.name} retried at #{short(digest)}; oracle judged it a " \
                                               "frustrated repeat of #{short(prior.first)}")
      end

      # `-why`/`-digest`/`-prior.first` freeze what {Data.define} does not:
      # it freezes the Signal itself but not a mutable value reachable
      # through it. String interpolation always returns a fresh, unfrozen
      # String (the same trap `Grade#initialize`'s own `-why.to_s` guards
      # against), and a lineage digest read out of a raw JSON-parsed record
      # is unfrozen too -- ONLY a String used as a Hash KEY is auto-frozen by
      # Ruby, and `prior.first` is a value read out of {ToolCallIndex#lineage},
      # never a key. Skipping any of the three would leave
      # `Ractor.shareable?(signal)` false despite the Signal looking frozen
      # at a glance.
      def build_signal(digest, call, prior, source:, why:)
        Signal.new(kind: :rephrase_loop, turn_digest: -digest, caused_by: [-prior.first].freeze,
                   repaired: call.is_error == false, source:, why: -why)
      end

      # The nearest ANCESTOR (never `digest` itself -- a sibling call in the
      # same turn is concurrent, not causally prior) that also called
      # `tool_name`, found by climbing {ToolCallIndex#lineage} and skipping
      # every ancestor whose calls do not match. Lazy, so a long, unrelated
      # prefix costs nothing once a match is found.
      #
      # @return [Array(String, ToolCallIndex::Call), nil] the matching
      #   ancestor's digest paired with its call, or nil if `tool_name` was
      #   never called before `digest`
      def nearest_prior_use(index, digest, tool_name)
        index.lineage(digest).lazy.drop(1).filter_map { |ancestor| matching_call(index, ancestor, tool_name) }.first
      end

      def matching_call(index, ancestor, tool_name)
        call = index.calls[ancestor]&.find { |candidate| candidate.name == tool_name }
        call && [ancestor, call]
      end

      def score(found)
        return 1.0 if found.empty?

        found.count(&:repaired).fdiv(found.size)
      end

      def explain(found)
        return "no frustration signals" if found.empty?

        "#{found.size} frustration signal(s), #{found.count(&:repaired)} repaired: #{found.map(&:why).join("; ")}"
      end

      def short(digest) = digest[0, 12]
    end
  end
end
