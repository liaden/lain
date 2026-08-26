# frozen_string_literal: true

module Lain
  module Review
    # The sentence every review surface shows once its sidebar is up: where to
    # read it, and the two gestures that reach it. ONE object because the banner
    # was duplicated byte-for-byte between {CLI::Command::Survey} and
    # {CLI::Command::Review} until it drifted from the protocol without anything
    # failing -- the same failure shape each command's own class doc names for the
    # HEADLINE half of the sentence.
    #
    # `:LainReviewDone` is NOT what either surface hands back with, though it
    # reads as though it should: it is a protocol-5 EPIC command whose guard
    # requires `b:lain_review_epic_slug`, which neither a survey nor a changeset
    # review ever stamps. `:LainReviewVerdict {verdict}` is the command that
    # actually exists for these two surfaces.
    class OpenedBanner
      # The WALK is named because `<CR>` lands in the sidebar, not in the file: a
      # review is drawn beside the human rather than under their cursor, so the
      # marking keys the sidebar owns are the keys that work where they land.
      # `:LainNote` reads the current buffer and wants a stamped review side, so
      # it correctly refuses from the sidebar -- and a banner that named the
      # command without the motions taught a sequence whose second step fails.
      #
      # HOW MANY motions is per-ROUND, which is why this class is handed the
      # sides. The editor draws the sidebar and then the slots the round presents,
      # in {Review::SIDES} order, so the file sits one hop further right for every
      # side that precedes it: a changeset review is `sidebar | OLD | NEW` and
      # takes two, a survey is `sidebar | NEW` and takes one. A fixed two overshot
      # the survey into whatever else the tabpage held.
      TEMPLATE = "%<headline>s\nwalk it in lain://review; <CR> opens a row beside you, " \
                 "%<walk>s reaches the file where :LainNote annotates, " \
                 ":LainReviewVerdict %<verdict>s hands it back"

      # One window right, and REPEATED rather than counted. `2<C-w>l` is the same
      # motion to nvim and a character shorter, but it is a different STRING, and
      # the two-sided sentence has to stay byte-identical to the one a human has
      # already been taught. A count would also put the only part of the motion
      # that VARIES at the front, where a reader scanning for the keystroke they
      # recognise finds `<C-w>l` and stops before the digit that changes it.
      HOP = "<C-w>l"

      # Which side the file on disk is, asked of the table that already decides
      # it: {Review::Source::HEAD_SIDE_ONLY} is {Review::SIDES} minus whatever
      # rests on the base revision, which is exactly "the buffer that is the
      # real file". A `"new"` written here would be a second declaration of
      # that membership, free to disagree with the one the sources answer from.
      FILE_SIDE = Source::HEAD_SIDE_ONLY.first

      # `.first`, not the whole vocabulary: the banner shows ONE exemplar a human
      # can copy verbatim, not a grammar to read. Deliberately order-dependent
      # only while {VERDICTS} holds a single member; the day it does not, this
      # becomes a real choice rather than an arbitrary one.
      #
      # @param headline [String] the caller's own -- {CLI::Survey::HEADLINE} or
      #   {CLI::Review::HEADLINE}, already resolved -- so this class describes
      #   the GESTURE only and never restates what tree or changeset is under
      #   review
      # @param sides [Array<String>] what the round presents, off
      #   {Review::Changeset#sides} -- a subset of {Review::SIDES} in its order,
      #   which is the same order the editor lays the slots out in
      # @return [String]
      def self.call(headline, sides:) = format(TEMPLATE, headline:, walk: walk(sides), verdict: VERDICTS.first)

      # The file's 1-based position among the round's slots, which is its
      # distance from the sidebar. Derived from WHERE the file side sits and not
      # from `sides.length`, which the two rounds that ship cannot tell apart --
      # they agree on both. Any other layout parts them: a round drawing the
      # file FIRST (`sidebar | NEW | OLD`) is two slots wide and one hop away,
      # and a round holding only the base revision has no file to reach at all,
      # where a length would name a motion into the base revision and this
      # refuses instead.
      def self.walk(sides) = HOP * sides.index(FILE_SIDE).succ
      private_class_method :walk
    end
  end
end
