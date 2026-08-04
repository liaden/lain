# frozen_string_literal: true

module Lain
  module Review
    # What a review CONCLUDES, and who is allowed to say so.
    #
    # The vocabulary itself is not here -- it is {Review::VERDICTS}, in the
    # String form the journal stores, and it has one member on purpose (research
    # open question 3 is unsettled). This namespace holds the two things around
    # that word: {Policy}, which decides whether a verdict may be recorded at
    # all, and {None}, which is what a session answers before one has been.
    module Verdict
      # The verdict a session has not been given yet.
      #
      # A Null Object rather than `nil`, and the tension it settles is recorded
      # at `Surface::Null#verdict`: {Sink::Null#write} returns the byte count
      # precisely so no caller nil-checks it, and a verdict is a QUERY, so `nil`
      # from one reintroduces the `if verdict` guard the pattern exists to
      # delete. {Session#verdict} therefore never answers nil.
      #
      # The duck it satisfies is a String's, because a recorded verdict IS a
      # String -- a member of {Review::VERDICTS}. `#empty?` is the one predicate
      # both sides answer, so `session.verdict.empty?` reads "nothing has been
      # concluded" without a type test, and `#to_s` is "" so an interpolating
      # surface renders nothing rather than a placeholder nobody chose.
      #
      # Deliberately NOT `#to_str`. Answering that would make it implicitly a
      # String -- `"verdict: " + None` would concatenate -- and absence would
      # then be indistinguishable from a real empty verdict at exactly the sites
      # that most need to tell them apart. It is also not a member of
      # {Review::VERDICTS}, which is what keeps it from being journaled by
      # accident: {ReviewVerdict}'s own guard refuses it.
      module None
        # @return [String]
        def self.to_s = ""

        # @return [Boolean]
        def self.empty? = true

        # Answers ITSELF, so `judgement.verdict` needs no test on either side:
        # {ReviewVerdict#verdict} gives the word, this gives the absence of one,
        # and both answer `#empty?`. The verdict of no judgement is no verdict.
        #
        # It deliberately does NOT answer `#changeset_digest`. There is no
        # changeset it judged, and nil would be a lie about the one field
        # {ReviewVerdict} requires precisely so that a judgement can never be of
        # nothing -- so asking raises, at the only call site that could have
        # reached it without checking `#empty?` first.
        #
        # @return [None]
        def self.verdict = self
      end
    end
  end
end

require_relative "verdict/policy"
