# frozen_string_literal: true

module Lain
  module Review
    class Session
      # {Widening#record} was handed a changeset that is not wider than the one
      # the round already spans -- it drops a path, or it adds none. Beside the
      # object that raises it, per the error-taxonomy convention, and reachable
      # as `Session::NotWidened` where every other refusal of a round lives.
      class NotWidened < Error; end

      # A widening that has been carried out: the record now on the journal, and
      # the marks as they stand after reconciling against the wider changeset.
      # Two values, because the aggregate has to assign both and neither can be
      # derived from the other.
      Widened = Data.define(:record, :marks)

      Widening = Data.define(:from, :to)

      # Whether one changeset is WIDER than another, by which paths, and the
      # widening itself carried out.
      #
      # Its own object because {Session} was at `Metrics/ClassLength` and the cop
      # was naming a real seam rather than a size: a survey accretes, and "is
      # this changeset a widening of that one" is a question about two changesets
      # that the aggregate holding marks, a journal, a surface and a verdict has
      # no other reason to know how to answer.
      #
      # == The DROP is the half that matters
      #
      # An addition refused is a gesture that did not land, which the human sees
      # and repeats. A drop accepted is silent and unrecoverable: {#into}
      # re-reconciles, so a "widening" that lost a path would discard every mark
      # on it and journal the loss as an accretion. A swap -- one file gone, one
      # arrived -- is the shape that reads as a widening and is not one.
      #
      # == It reads FILES, never hunks
      #
      # `changeset.hunks` would chunk both corpora to find out which paths they
      # name, which is the whole cost a survey defers ({LazyFile}). Every message
      # here is answerable from the file list, which a corpus has already built
      # for its identity pass. {Marks#reconcile} is the one step that does read
      # hunks, and it does so only when there is a mark that could have gone
      # stale -- its own doc prices that.
      class Widening
        # @return [Array<String>] the paths `to` has and `from` does not
        def added = to_paths - from_paths

        # @return [Array<String>] the paths `from` has and `to` does not
        def dropped = from_paths - to_paths

        # The record, minted only for a changeset that really is wider.
        #
        # @return [CorpusExtended]
        # @raise [NotWidened] naming both faults at once, because a caller that
        #   dropped a path AND added none has made both mistakes, and a message
        #   naming either alone sends them looking for half a cause
        def record
          refuse_narrowing!

          CorpusExtended.new(paths: added, digest: Session.digest(to))
        end

        # Carry the widening out: refuse, reconcile, then journal, in that order.
        #
        # The ORDER is the contract and it is {Session#submit}'s: everything that
        # can refuse runs before anything is written, so a widening that did not
        # happen leaves no record of having happened. {Marks#reconcile} is what
        # refuses a changeset from another base, ahead of any key being
        # consulted, which is why nothing here tests a base.
        #
        # @param journal [#<<] where the record of this round lands
        # @param marks [Review::Marks] the round's marks, as they stand
        # @return [Widened]
        # @raise [NotWidened] for a changeset that drops a path or adds none
        # @raise [Marks::BaseMismatch] for a changeset from another base
        def into(journal, marks:)
          extended = record
          reconciled = marks.reconcile(to)
          journal << extended

          Widened.new(record: extended, marks: reconciled)
        end

        private

        def from_paths = from.files.map(&:path)

        def to_paths = to.files.map(&:path)

        def refuse_narrowing!
          faults = [("drops #{dropped.inspect}" unless dropped.empty?), ("adds no path" if added.empty?)].compact
          return if faults.empty?

          raise NotWidened, "a widening must span every path this round already has and at least one more -- " \
                            "this one #{faults.join(" and ")}"
        end
      end
    end
  end
end
