# frozen_string_literal: true

module Lain
  module Memory
    # The AAAK shape: a lossy pointer layer over verbatim drawers. One line per
    # live item -- "id | description" -- scanned in-context, with the body left
    # in the store until a tool opens it. Projected at construction from
    # anything that #maps items responding to #id and #description (an Index,
    # usually), sorted by id, free of timestamps and insertion order, so equal
    # entries always render equal bytes: the Manifest rides the Request (sent,
    # not stored) and any nondeterminism here would break the prompt cache
    # silently.
    #
    # "Signal, never a gate" (references/memory-and-retrieval.md #2): the
    # Manifest may RANK, it must never HIDE. Every live entry is always in
    # #lines, and #search is the always-runs floor of the retrieval stack --
    # when richer indexes (BM25, vectors, the temporal KG) land, they may only
    # boost what this floor surfaces, never filter it out. An index bug must
    # degrade ranking, not suppress truth.
    class Manifest
      # A search result that explains itself. #why is as non-negotiable here as
      # it is on Grader::Grade: a ranking you cannot read the reason for is
      # unusable on a bench whose product is the comparison.
      #
      # Score is validated, not clamped: Manifest itself only emits 0..1 (a
      # token fraction, or a substring ratio bounded by it), and a future
      # boosting arm that exceeds 1.0 must renormalize -- a hard clamp here
      # would hide exactly that bug. The loud floor is finite and non-negative.
      Hit = Data.define(:id, :description, :score, :why) do
        def initialize(id:, description:, score:, why:)
          raise ArgumentError, "a Hit must explain itself: #why is blank" if why.to_s.strip.empty?

          # Float(), not #to_f: to_f coerces garbage to a valid-looking 0.0,
          # which is exactly the silent bug the floor below exists to catch.
          value = Float(score)
          raise ArgumentError, "score must be finite and non-negative, got #{score.inspect}" unless
            value.finite? && value >= 0

          super(id: -id.to_s, description: -description.to_s, score: value, why: -why.to_s)
        end
      end

      # One entry's search-ready projection. Tokens are computed once at
      # construction because entries never change and #search should not
      # re-tokenize the whole manifest per query.
      Entry = Data.define(:id, :description, :tokens)
      private_constant :Entry

      # Tokenization rule: lowercase \w+ runs, deduplicated. \w is ASCII-only
      # in Ruby, so accented and symbol characters act as separators: "café"
      # tokenizes to "caf", "µg" to "g", and hyphenated drug names split
      # ("co-amoxiclav" -> co, amoxiclav). Applied symmetrically to query and
      # entry, so still deterministic -- but medical text is full of such
      # names, and the substring floor in #search exists precisely because
      # this rule cannot express them all. If a fixture ever needs more,
      # extend the floor, not the tokenizer.
      TOKEN = /\w+/

      attr_reader :lines

      # Sorted HERE: "sorted by id" is Manifest's own claim, so Manifest
      # enforces it rather than inheriting Index#each's walk order.
      # Duplicate-id resolution (last write wins) stays the Index's job --
      # Manifest trusts the source for LWW, never for ordering.
      #
      # @entries/@lines look like a duplicate of the Index's items, but they
      # are a RENDER cache, not a second copy of the same data: @entries is
      # tokenized (Entry#tokens) and joined into one String (@reminder) --
      # work #search and #to_reminder would otherwise redo on every call.
      # LWW is already resolved by the source that fed #initialize, so
      # consolidating the two would not remove a responsibility, only force
      # the tokenize+join to happen once per render instead of once per
      # Manifest. The sort_by(&:id) below is redundant over an Index (whose
      # #each already yields id-sorted) but kept as cheap defensive ordering:
      # the source contract is only "#maps items responding to #id and
      # #description", and Manifest's determinism claim must not lean on an
      # iteration-order promise the duck never made.
      def initialize(index)
        @entries = index.map { |item| entry_for(item) }.sort_by(&:id).freeze
        @lines = @entries.map { |entry| -"#{entry.id} | #{entry.description}" }.freeze
        @reminder = @lines.join("\n").freeze
        freeze
      end

      # One String for Workspace#with -- the "one-line descriptions in
      # context" seam. Joined and frozen at construction; #search is the hot
      # path, but this String reaches every render, so it must be one object.
      def to_reminder
        @reminder
      end

      # Deterministic lexical match: score is the fraction of query tokens
      # found among the entry's id + description tokens, with a substring
      # match on the id as a floor (a query containing the id literally always
      # hits, scored by how much of the query the id covers). Zero scores are
      # excluded -- from the RANKING, never from the manifest itself.
      # @return [Array<Hit>] sorted by (score desc, id asc); [] on no match
      def search(query)
        needle = query.to_s.downcase
        query_tokens = tokenize(needle)
        @entries.filter_map { |entry| hit_for(entry, needle, query_tokens) }
                .sort_by { |hit| [-hit.score, hit.id] }
      end

      def to_s
        "#<Lain::Memory::Manifest entries=#{@entries.size}>"
      end
      alias inspect to_s

      private

      def entry_for(item)
        tokens = tokenize("#{item.id} #{item.description}".downcase).map(&:-@).freeze
        Entry.new(id: item.id, description: item.description, tokens:)
      end

      def tokenize(downcased)
        downcased.scan(TOKEN).uniq
      end

      def hit_for(entry, needle, query_tokens)
        matched = query_tokens & entry.tokens
        fraction = query_tokens.empty? ? 0.0 : matched.size.fdiv(query_tokens.size)
        floor = id_floor(entry.id, needle)
        score = [fraction, floor].max
        return nil if score.zero?

        Hit.new(id: entry.id, description: entry.description, score:,
                why: why_for(matched, entry.id, floor > fraction))
      end

      def id_floor(id, needle)
        target = id.downcase
        needle.include?(target) ? target.length.fdiv(needle.length) : 0.0
      end

      # The explanation must explain the NUMBER: when the floor outscored the
      # token fraction, naming matched tokens would misattribute the score.
      def why_for(matched, id, floor_won)
        floor_won ? "query contains id #{id.inspect} (substring floor)" : "matched tokens: #{matched.sort.join(", ")}"
      end
    end
  end
end
