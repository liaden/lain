# frozen_string_literal: true

module Lain
  module Grader
    # Behavioral failure signals -- an agent stuck re-trying the same tool
    # after it errored -- walked back through the causal DAG to the turn that
    # plausibly caused them, rather than credited to whichever turn happens to
    # sit immediately before.
    #
    # Built on the {ToolCallIndex}: `#calls` supplies the deterministic
    # name/is_error signal per turn, and `#lineage` supplies the causal walk
    # attribution rides. {#nearest_prior_use} climbs that lineage and SKIPS any
    # ancestor that did not call the same tool, which is the whole point: a
    # decoy call to an UNRELATED tool sitting between the failure and the repeat
    # never earns the attribution just for being closer in turn order.
    # Attribution is over CONTENT-ADDRESSED LINEAGE, never turn-ordinal
    # proximity.
    #
    # The mechanical floor stays loop-detection-simple ON PURPOSE: "the same
    # tool name was retried after an is_error outcome" needs no model, so it can
    # never make the grader's answer depend on a live API call. A genuinely
    # fuzzy judgment -- "is this differently-shaped retry still the same
    # frustrated attempt, even though the prior call technically succeeded?" --
    # is gated behind the injected `oracle:`, Null by default. The oracle is
    # consulted ONLY where the mechanical floor already declined to signal, so a
    # live oracle can only ADD signals beyond the deterministic floor, never
    # suppress or relabel one of its own.
    #
    #   FrustrationRepair.new.grade(Journal.records(File.foreach(path)))
    #   #=> Grade(score: 0.0, pass: false, why: "1 frustration signal, 0 repaired: ..." ...)
    #
    # {ToolCallIndex#lineage} is a single deterministic path, so this floor
    # cannot itself produce more than one cause. `caused_by` is still an Array:
    # {Timeline#causal_meets}'s shape is the SET of maximal common ancestors at
    # a criss-cross fan-in, and a journaled `turn` record carries no
    # `causal_parents` field to reconstruct that richer walk from -- so a caller
    # must never assume a single element, because the type does not promise one.
    class FrustrationRepair
      # The fuzzy-signal seam, Null by default: one swappable arm over one
      # interface, decided without a model call until one is wired in.
      class NullOracle
        def frustrated?(_prior_call, _next_call) = false

        INSTANCE = new.freeze

        def self.instance = INSTANCE
      end

      # One detected signal. `repaired` is whether THIS turn's own call
      # succeeded -- the retry that ends the loop, as opposed to one that
      # persists it. `source` says which arm found it: `:mechanical` for the
      # deterministic floor, `:oracle` for the injected fuzzy signal.
      Signal = Data.define(:kind, :turn_digest, :caused_by, :repaired, :source, :why)

      # @param oracle [#frustrated?] the fuzzy-signal seam; Null by default
      def initialize(oracle: NullOracle.instance)
        @oracle = oracle
        freeze
      end

      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck,
      #   the same input {ToolCallIndex} takes
      # @param tool_call_index [ToolCallIndex] see {#signals}
      # @return [Grade] score = fraction of signals repaired (1.0 with none
      #   detected -- nothing went wrong is a clean pass, not a zero)
      def grade(entries, tool_call_index: ToolCallIndex.new(entries))
        found = signals(entries, tool_call_index:)
        Grade.new(score: score(found), pass: found.all?(&:repaired), why: explain(found))
      end

      # @param entries [Enumerable<Hash, String>]
      # @param tool_call_index [ToolCallIndex] the projection to detect over,
      #   built from `entries` when absent. A caller folding several graders
      #   over ONE record array already holds the index this one would build,
      #   and re-parsing the same records per grader is what the keyword saves.
      # @return [Array<Signal>] every detected signal, turn order, frozen
      def signals(entries, tool_call_index: ToolCallIndex.new(entries))
        tool_call_index.calls.flat_map do |digest, calls|
          calls.filter_map { |call| detect(tool_call_index, digest, call) }
        end.freeze
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

      # The three `-` calls freeze what {Data.define} does not: it freezes the
      # Signal itself but not a mutable value reachable through it. String
      # interpolation always returns a fresh unfrozen String, and a lineage
      # digest read out of a raw JSON-parsed record is unfrozen too -- ONLY a
      # String used as a Hash KEY is auto-frozen by Ruby, and `prior.first` is a
      # value, never a key. Skipping any of the three leaves
      # `Ractor.shareable?(signal)` false despite the Signal looking frozen.
      def build_signal(digest, call, prior, source:, why:)
        Signal.new(kind: :rephrase_loop, turn_digest: -digest, caused_by: [-prior.first].freeze,
                   repaired: call.is_error == false, source:, why: -why)
      end

      # The nearest ANCESTOR that also called `tool_name` -- never `digest`
      # itself, since a sibling call in the same turn is concurrent rather than
      # causally prior. Lazy, so a long unrelated prefix costs nothing once a
      # match is found.
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
