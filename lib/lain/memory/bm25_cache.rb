# frozen_string_literal: true

module Lain
  module Memory
    # A small mutable holder that memoizes the last Bm25 built by
    # Memory::Index#root -- equal roots are the identical corpus by
    # construction (content addressing), so a repeat root is served from
    # cache instead of paying Bm25's O(corpus) rebuild again. Recorder is the
    # precedent for a deliberately mutable holder among frozen values; Bm25
    # itself is never touched here, only constructed and kept.
    #
    # Retention is deliberately just the most recent build: the intended
    # first consumer (push-recall over a moving index, M6) calls #for with
    # "latest root, repeatedly," never a working set of many roots, so an LRU
    # would be answering a question nobody is asking yet.
    #
    # @root tracks the last-served root and @bm25 the Bm25 built for it, but
    # #root is nil for BOTH "never built" and "built at the empty index" --
    # the two are not the same state, so the guard is on @bm25 being unbuilt
    # (a Bm25.new(index:) call never returns nil), not on @root.
    class Bm25Cache
      def initialize
        @root = nil
        @bm25 = nil
      end

      # @param index [Memory::Index] a snapshot; sent, not stored -- only
      #   #root is read to decide cache-or-rebuild, and the index itself is
      #   handed to Bm25.new only on a miss.
      # @return [Bm25] the cached build when index.root repeats, a fresh one
      #   otherwise.
      def for(index)
        rebuild(index) if @bm25.nil? || index.root != @root
        @bm25
      end

      private

      def rebuild(index)
        @root = index.root
        @bm25 = Bm25.new(index:)
      end
    end
  end
end
