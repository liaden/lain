# frozen_string_literal: true

module Lain
  module Review
    class Session
      # Turns a wire `(hunk_key, state)` pair into a validated, journaled
      # {HunkMarked} record -- the one step {Session#mark} and
      # {Session#mark_row} share, moved out here because `Metrics/ClassLength`
      # named {Session} as carrying two responsibilities: this validation, and
      # being the review aggregate itself (the repo's own reading of a
      # tripped `Metrics` cop -- an object was missing).
      #
      # BUILT FRESH by {Session#marking} for every gesture rather than held,
      # because `known_hunks` is a SNAPSHOT of {Session#hunk_keys}, which is
      # deliberately not memoized (see that method's own doc: "a survey reads
      # more of itself as it is looked at"). Holding one {Marking} across two
      # gestures would answer the second from a set the first was resolved
      # against, which is exactly the staleness `#hunk_keys` refuses to risk.
      #
      # It does NOT apply the record to `@marks` or notify a surface -- both
      # stay with `Session`, which is the object that owns that state and
      # decides who else hears about it (`#mark` tells the surface per call,
      # `#mark_row` does not; see that method's own doc for why).
      #
      # WHY `#mark` KEEPS TELLING THE SURFACE, STATED PRECISELY, because an
      # earlier draft of this reasoning got it wrong: it is NOT because
      # `spec/support/shared_examples/review_surface.rb`'s port contract binds
      # `Session#mark` -- it does not. That contract constructs a SURFACE
      # (`Surface::Neovim`/`Surface::Text`) and calls `#mark` on IT directly;
      # `Session` never appears in it, and a mutation check proves the
      # boundary: deleting `Session#mark`'s `@surface.mark` call leaves every
      # one of those port-contract examples green, because none of them route
      # through `Session` at all. The real reason is `Session`'s OWN
      # commitment, stated once here so it is not re-derived wrongly again:
      # a hunk marked ANY way this class offers notifies the surface exactly
      # once, and `#mark` is the leg that still promises that for a single
      # hunk marked in isolation (`#mark_row` promises it for a whole row,
      # once, from the caller -- see that method's doc).
      class Marking
        # @param journal [#<<] where the record lands
        # @param known_hunks [#include?] this changeset's own keys, as
        #   {Session#hunk_keys} stood at the moment this was built
        def initialize(journal:, known_hunks:)
          @journal = journal
          @known_hunks = known_hunks
        end

        # @param hunk_key [String]
        # @param state [String, Symbol] a member of {Review::MARK_STATES}
        # @return [HunkMarked] the record, as journaled
        # @raise [UnknownHunk] for a key this changeset does not produce
        # @raise [Marks::UnknownState] for a state outside the vocabulary
        def call(hunk_key, state)
          key = Wire.token(hunk_key)
          refuse_unknown_hunk!(key)
          HunkMarked.new(hunk_key: key, state: Marks.state!(state)).tap { |marked| @journal << marked }
        end

        private

        def refuse_unknown_hunk!(key)
          return if @known_hunks.include?(key)

          raise UnknownHunk, "#{key.inspect} is not a hunk key this changeset produces -- a mark under it " \
                             "could never be reconciled onto anything, and the next replay would prune it unread"
        end
      end
    end
  end
end
