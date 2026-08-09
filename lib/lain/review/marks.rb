# frozen_string_literal: true

module Lain
  module Review
    # Marks are recorded at hunk granularity only ({MARK_STATES}'s own comment
    # explains why a coarser record would be a second, disagreeing fact). Every
    # coarser indicator -- a file's, a commit's -- is DERIVED from this set, on
    # demand, against whatever {Hunk} keys a changeset currently produces.
    #
    # A mark set is pinned to the base revision it was recorded against.
    # {Hunk}'s span-qualified fallback key is positional (old-side span), and a
    # BASE-side edit can slide one duplicate hunk onto another's former span
    # without moving either hunk's own lines -- old and new side shift by the
    # same amount under a base move, so the span stays internally consistent
    # while it now names the WRONG hunk. No hunk key can close that (see the
    # spec's "base revision scoping" group for the literal string collision);
    # only refusing to reuse a mark set across a base change can, so that is
    # what {#reconcile}, {#state_for} and {#states} all do first.
    class Marks
      # A mark whose state is not one of {MARK_STATES}.
      class UnknownState < Error; end

      # A `base_ref` that cannot name a revision: nil, or blank once stripped.
      class InvalidBaseRef < Error; end

      # Reconciling or deriving state against a changeset recorded from a
      # different base revision than this mark set was.
      class BaseMismatch < Error; end

      # {#state_for} was asked about a path the changeset never named.
      # Answering `:unreviewed` for that would read a renamed or mistyped path
      # as real unreviewed work -- indistinguishable from a file with hunks
      # nobody has looked at, which is exactly the silent wrong answer this
      # chunk keeps finding elsewhere. {#states} already tells the two apart
      # (the key is simply absent); this is that same fact, refused loudly
      # instead of collapsed.
      class UnknownPath < Error; end

      # The one {MARK_STATES} member {#states} and {#state_for} count as
      # reviewed. Named once so a rename of that spelling has exactly one call
      # site to fix rather than a bare literal hiding inside the derivation --
      # the same derive-don't-restate rule `Anchor::SIDES` follows for
      # `Review::SIDES`. The spec pins it a genuine member of {MARK_STATES} so
      # the two cannot drift apart silently.
      REVIEWED = "reviewed"

      attr_reader :base_ref

      # @param base_ref [String, Symbol] the resolved base revision these
      #   marks were recorded against
      # @param marks [Hash{String => String}] hunk key => a member of
      #   {MARK_STATES}
      # @raise [InvalidBaseRef] if `base_ref` is nil or blank
      def initialize(base_ref:, marks: {})
        @base_ref = self.class.base_ref!(base_ref)
        @marks = marks.each_with_object({}) do |(hunk_key, state), frozen|
          frozen[-hunk_key.to_str] = self.class.state!(state)
        end.freeze
        freeze
      end

      # Wire-tolerant, the same discipline {.state!} already applies: accepts
      # a Symbol as readily as a String, and refuses nil or blank BY NAME
      # rather than let a bare `nil.to_str` raise a message naming neither the
      # class nor the field.
      #
      # @return [String] the normalized base revision
      # @raise [InvalidBaseRef] naming the value given
      def self.base_ref!(value)
        token = Wire.token(value)
        return token unless token.nil? || token.empty?

        raise InvalidBaseRef, "base_ref must name the resolved base revision, got #{value.inspect}"
      end

      # @return [String] the normalized state, one of {MARK_STATES}
      # @raise [UnknownState] naming the value given
      def self.state!(value)
        token = Wire.token(value)
        return token if MARK_STATES.include?(token)

        raise UnknownState, "state must be one of #{MARK_STATES.join("/")}, got #{value.inspect}"
      end

      # @return [Marks] a new mark set with `hunk_key` set to `state`
      def mark(hunk_key, state)
        self.class.new(base_ref:, marks: @marks.merge(hunk_key => state))
      end

      # @return [Hash{String => String}] the mark set, already frozen (every
      #   key and value inside it was frozen at construction) -- returned
      #   directly rather than dup'd, since there is nothing left for a copy
      #   to protect that the freeze does not already.
      def to_h = @marks

      # Prunes marks for hunk keys the given changeset no longer produces.
      # `changeset` must be the WHOLE, unfiltered changeset -- there is no
      # `scope:` parameter to accept a narrower one, on purpose (tuicr#247: a
      # `preserve_hunks` flag on the wrong side of this call is the bug, not
      # the fix).
      #
      # == An empty set is pruned without reading anything
      #
      # A set with nothing in it has nothing that could be stale, so the walk
      # below would establish only what the emptiness already says. Over a
      # lazily-chunked corpus that walk is the whole chunking cost, so a review
      # that has marked nothing would otherwise pay it to prune nothing.
      #
      # What that is worth is a RESUME of a round nobody marked, and only until
      # the first question is asked -- said precisely because the obvious wider
      # claim is false. {Session.open} composes its journaled digest through
      # `MarkedChangeset.keys_by_path` BEFORE it builds the session, so an open
      # has already read every file by the time this runs (measured: `.open`
      # chunks 50 of 50 at zero marks, `.from_journal` chunks 0 of 50).
      #
      # It goes no further than that, and the limit is worth stating rather
      # than leaving to be rediscovered: a mark carries a hunk key and NOTHING
      # else ({Review::HunkMarked}), and a key is a digest no path can be read
      # back out of ({Hunk#key}). So a mark set cannot name the paths it
      # belongs to, and a surviving mark is told from a stale one only by
      # walking every path to prove absence. A non-empty set reads the
      # changeset whole.
      #
      # The base check stays ahead of the shortcut: a base move is refused
      # whether or not there is a mark to carry across it.
      #
      # @param changeset [#base_ref, #hunks] the unfiltered changeset
      # @return [Marks] `self` when there was nothing to prune -- this object is
      #   frozen and immutable, so a copy would differ from it in nothing
      # @raise [BaseMismatch] if `changeset` was not built against this mark
      #   set's {#base_ref}
      def reconcile(changeset)
        assert_same_base!(changeset)
        return self if @marks.empty?

        valid = valid_keys(changeset)
        self.class.new(base_ref:, marks: @marks.select { |hunk_key, _| valid.key?(hunk_key) })
      end

      # The tri-state indicator for one file, at full scope: reviewed only
      # when every one of its hunks -- across every commit `changeset` carries
      # -- is marked reviewed, partial when some are, unreviewed otherwise.
      #
      # A single-path CONVENIENCE, not a cheaper primitive: it builds the
      # whole {#states} Hash on every call, so a caller looping this over N
      # files pays O(N x changeset) where {#states} pays for the changeset
      # once. Prefer {#states} for anything but one path.
      #
      # @param path [String]
      # @param changeset [#base_ref, #hunks]
      # @return [:reviewed, :partial, :unreviewed]
      # @raise [BaseMismatch] see {#reconcile}
      # @raise [UnknownPath] if `path` names no file in `changeset` -- call
      #   {#states} instead to see every file this changeset does name
      def state_for(path, changeset)
        states(changeset).fetch(path) do
          raise UnknownPath, "#{path.inspect} is not a file in this changeset -- #states lists what is"
        end
      end

      # Every file's tri-state indicator, in one pass over `changeset`.
      #
      # @param changeset [#base_ref, #hunks]
      # @return [Hash{String => Symbol}]
      # @raise [BaseMismatch] see {#reconcile}
      def states(changeset)
        assert_same_base!(changeset)

        changeset.hunks.group_by(&:path).each_with_object({}) do |(path, hunks), result|
          keys = Hunk.keys(hunks)
          reviewed = keys.count { |hunk_key| @marks[hunk_key] == REVIEWED }
          result[path] = tri_state(reviewed, keys.size)
        end
      end

      private

      def assert_same_base!(changeset)
        # Both sides through the SAME normalization `#initialize` already
        # applies to `base_ref` -- comparing one normalized side against the
        # other raw let the identical revision, spelled as a Symbol or with
        # wire whitespace, read as a base change that never happened.
        other = self.class.base_ref!(changeset.base_ref)
        return if other == base_ref

        raise BaseMismatch,
              "marks were recorded against #{base_ref.inspect}, not #{other.inspect} -- " \
              "reconciling across a base change can hand a stale mark to the wrong hunk"
      end

      def valid_keys(changeset)
        changeset.hunks.group_by(&:path)
                 .flat_map { |_path, hunks| Hunk.keys(hunks) }
                 .to_h { |hunk_key| [hunk_key, true] }
      end

      # Ordered so a hunkless file (`total.zero?`) reads honestly as
      # :unreviewed rather than :reviewed, even though {#states} never
      # produces one -- `group_by` only ever yields non-empty groups, so
      # `keys.size` cannot be 0 there. Kept honest anyway: a private method is
      # still a promise to whatever calls it next.
      def tri_state(reviewed, total)
        return :unreviewed if reviewed.zero?
        return :reviewed if reviewed == total

        :partial
      end
    end
  end
end
