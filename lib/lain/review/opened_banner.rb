# frozen_string_literal: true

module Lain
  module Review
    # The sentence every review surface shows once its sidebar is up: where to
    # read it, and the two gestures that reach it. ONE object because the
    # banner was duplicated byte-for-byte between {CLI::Command::Survey} and
    # {CLI::Command::Review} until it drifted from the protocol without
    # anything failing (F4) -- two files carrying one instruction string about
    # two different surfaces is exactly how it drifted, and it is the same
    # failure shape each command's own class doc already names for the
    # HEADLINE half of this sentence ("so the two surfaces cannot describe
    # the same review differently"). This class is that promise, kept for the
    # gesture half too.
    #
    # `:LainReviewDone` is NOT what either surface hands back with, though it
    # reads as though it should: it is a protocol-5 EPIC command whose guard
    # (`runtime/65_review.lua:93-98`) requires `b:lain_review_epic_slug`, which
    # neither a survey nor a changeset review ever stamps. `:LainReviewVerdict
    # {verdict}` (`runtime/46_sidebar.lua:188`, protocol 10) is the command
    # that actually exists for these two surfaces.
    class OpenedBanner
      TEMPLATE = "%<headline>s\nwalk it in lain://review; <CR> opens a row, :LainNote annotates, " \
                 ":LainReviewVerdict %<verdict>s hands it back"

      # `.first`, not the whole vocabulary: the banner shows ONE exemplar a
      # human can copy verbatim, not a grammar to read -- `usage`'s `--scope`
      # list enumerates every registered strategy because a human choosing a
      # scope has to see them all, but a human confirming a review needs to
      # see one working command. Deliberately order-dependent only while
      # {VERDICTS} holds a single member (its own class doc says why); the day
      # it does not, this becomes a real choice rather than an arbitrary one.
      #
      # @param headline [String] the caller's own -- {CLI::Survey::HEADLINE} or
      #   {CLI::Review::HEADLINE}, already resolved -- so this class describes
      #   the GESTURE only and never restates what tree or changeset is under
      #   review
      # @return [String]
      def self.call(headline) = format(TEMPLATE, headline:, verdict: VERDICTS.first)
    end
  end
end
