# frozen_string_literal: true

require_relative "../journal"

module Lain
  module Bench
    # An OFFLINE projection over a Journal's `request_sent` records (CE-2):
    # `diverge_at` recreated at the request level, over the digest chain
    # `Request#prefix_digests` already computes and `Event::RequestSent`
    # already journals. No Timeline access -- journal bytes only.
    #
    # A REWRITE is a position present in BOTH of two consecutive chains but
    # carrying a DIFFERENT digest; its DEPTH is the smallest such position.
    # A position present in only one chain -- a marker slid
    # (`Context::CacheBreakpoints`' lookback window moving), or a message got
    # appended -- is NOT a rewrite: `Request#prefix_digests` is built
    # precisely so a shared position hashes identically regardless of
    # whether a marker sits on it (see request.rb), so only genuinely
    # rewritten bytes disagree on a position both chains carry.
    #
    # `prefix_digests` distinguishes nil ("not computed" -- an older Journal,
    # or a run that never enabled the chain) from `[]` ("computed, empty" --
    # no cache markers were placed at all). A nil chain is skipped entirely
    # rather than compared, so it never straddles two real chains as a false
    # gap; an `[]` chain participates normally -- it shares no positions with
    # any neighbor, so it can only rule a rewrite out, never be one.
    #
    # ONE CONFLATION, inherited from the chain itself: `Request#prefix_digests`
    # folds `model` into every entry (the chains are per-model by design --
    # a prompt cache never spans models), so a model switch between
    # consecutive calls disagrees at every shared position and reads here as
    # one rewrite at the earliest one, indistinguishable from a real prefix
    # edit. Faithful to the cache (a model switch DOES forfeit the whole
    # prefix), but misleading as edit-attribution -- callers comparing across
    # models must segment the journal per arm before projecting. Pinned in
    # the spec.
    class Rewrites
      include Enumerable

      # One rewrite: `depth` is the smallest shared position whose digest
      # differs between two consecutive chains; `from_digest`/`to_digest`
      # are that position's digest in the earlier and later chain -- the
      # bytes the prefix broke FROM and the bytes it broke TO, i.e. the
      # breaking turn's attribution.
      Rewrite = Data.define(:depth, :from_digest, :to_digest) do
        def initialize(depth:, from_digest:, to_digest:)
          super(depth: Integer(depth), from_digest: -from_digest.to_s, to_digest: -to_digest.to_s)
        end
      end

      # Project straight from a Journal's raw entries -- the
      # {Journal.records} duck: parsed Hashes or raw NDJSON lines.
      #
      # @param entries [Enumerable<Hash, String>]
      # @return [Rewrites]
      def self.from_journal(entries)
        chains = Journal.records(entries, type: "request_sent")
                        .reject { |record| record["prefix_digests"].nil? }
                        .map { |record| record["prefix_digests"] }
        new(chains: chains)
      end

      # @param chains [Enumerable<Array<Array(Integer, String)>>] one
      #   position/digest chain per request_sent record that HAD one
      #   computed, in journal (call) order
      def initialize(chains:)
        # `.to_a` before `.freeze`: `chains` from {.from_journal} is
        # `Journal.records`' lazy walk, and `each_cons`/`filter_map` on a
        # `Lazy` stay `Lazy` -- freezing THAT freezes the enumerator object,
        # not an Array, and an unrealized `Enumerator::Lazy` never clears
        # `Ractor.shareable?`. Materializing here is also what makes this a
        # value object at all: a Rewrites answers the same rewrites on every
        # read, not a stream that can only be walked once.
        @rewrites = chains.each_cons(2).filter_map { |before, after| rewrite_between(before, after) }.to_a.freeze
        freeze
      end

      # @yieldparam rewrite [Rewrite]
      # @return [Enumerator<Rewrite>, self]
      def each(&block)
        return @rewrites.each unless block

        @rewrites.each(&block)
        self
      end

      private

      def rewrite_between(before, after)
        before_chain = before.to_h
        after_chain = after.to_h
        diverging = (before_chain.keys & after_chain.keys)
                    .reject { |position| before_chain[position] == after_chain[position] }
        return nil if diverging.empty?

        depth = diverging.min
        Rewrite.new(depth: depth, from_digest: before_chain[depth], to_digest: after_chain[depth])
      end
    end
  end
end
