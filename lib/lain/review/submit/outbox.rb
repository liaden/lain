# frozen_string_literal: true

module Lain
  module Review
    class Submit
      # The one changeset review a chat has open, and the single chance it has
      # to reach the pull request.
      #
      # == Why a holder exists at all
      #
      # {Submit} takes a {Session}, and a session is memory: `/review` opens the
      # round, the human then spends minutes annotating and marking in the
      # editor, and `/review-submit` arrives at the same prompt long afterwards.
      # Nothing else in the run holds that session where a second command can
      # reach it -- {CLI::HumanReplies} binds it for the GESTURE rails and keeps
      # it private -- so this is the slot the two commands share, wired once in
      # {CLI::Command::Surface} and injected into both.
      #
      # It could have been the journal instead: {Session.from_journal} rebuilds
      # a round from the record. That was rejected because a rebuild has to
      # regenerate the CHANGESET too, and the author goes on pushing -- every
      # annotation authored against the old head would then fail
      # {Placer}'s `revision_moved` and degrade into a bullet under
      # {UNPLACED_HEADING}. A review that silently posts as prose instead of as
      # inline comments is the failure this whole path exists to avoid, so the
      # live session is held rather than reconstructed.
      #
      # == Three refusals, each naming its own cause
      #
      # {Submit}'s own rule, one tier up. Nothing open, nowhere to post, and
      # already sent are three different situations with three different
      # remedies, and one "cannot submit" would tell a human none of them.
      #
      # {Nowhere} is the interesting one: a review opened on a BRANCH is a
      # perfectly good review with no pull request under it. That is not an
      # error condition, so the round stays held and stays open -- what is
      # missing is a destination, not the review.
      #
      # == Sent at most once, and never retried
      #
      # {Forge::Gh#submit_review}'s constraint, enforced where a human can
      # actually trip over it: an accepted POST creates a NEW review every time,
      # so a second `/review-submit` on one round is refused rather than
      # attempted. That holds for a REFUSED first attempt too, and deliberately
      # -- `gh` timing out is a POST that may well have landed, and lain cannot
      # tell that from one GitHub never saw. The refusal says so and points at
      # the only thing that knows.
      #
      # The flag is set from what {#submit} RETURNS, never before the call, so a
      # raise burns nothing: {Submit} raises {Refused} and {Nothing} before the
      # executor is touched, and {Forge::Gh} itself raises only when there is no
      # `gh` to run -- a broken machine, and a review still owed a delivery.
      class Outbox
        # A submit with no round held. Named per the error-taxonomy convention:
        # a refusal subclasses {Lain::Error} next to the owner that raises it.
        class NotOpen < Error; end

        # A round opened on something that is not a pull request.
        class Nowhere < Error; end

        # A second submit of one round.
        class AlreadySent < Error; end

        NOTHING_OPEN = "no changeset review is open in this chat, so there is nothing to post -- " \
                       "open one with `/review <pull-request>` first"

        # What {#target} answers with no round held. A sentence rather than an
        # empty string, so a report that somehow reaches it says something true
        # instead of a blank.
        NOTHING_HELD = "no open changeset review"

        NOT_A_PULL_REQUEST = "this review was opened on %<label>s, and a branch has no pull request to post " \
                             "a review to -- the annotations and the verdict are on the journal either way. " \
                             "Run `/review <pull-request>` against the pull request itself to post one."

        SENT_ALREADY = "this review was already posted to pull request %<number>s -- GitHub creates a new " \
                       "review for every accepted POST, so this will not send a second one. %<outcome>s"

        # What the first attempt settled, in the words the AlreadySent sentence
        # ends on. The two are held apart because a refusal is NOT a
        # cancellation: lain sees `gh` exit non-zero and cannot tell a 422 that
        # created nothing from a timeout on a POST the remote accepted.
        RECORDED = "GitHub recorded it."
        UNCERTAIN = "GitHub refused that attempt, and whether it recorded a review anyway is a question " \
                    "only the pull request itself can answer -- read it before opening another round."

        # One round, and where it posts. `number` is nil for a branch review,
        # which is what {Nowhere} is about; `label` is the caller's own words
        # for the target, so the refusal names what the human typed rather than
        # a class.
        Held = Data.define(:session, :number, :label)

        def initialize
          @held = nil
          @sent = nil
        end

        # Take the round a `/review` just opened, replacing whatever was held.
        #
        # A second `/review` is a second review, so the sent flag is dropped
        # with the old round: what may not happen twice is one round reaching
        # GitHub twice, not a chat reviewing twice.
        #
        # @param session [Review::Session] the round, read and never written
        # @param number [Integer, String, nil] the pull request, or nil for a
        #   branch review
        # @param label [String] how the target was named on screen
        # @return [self]
        def hold(session:, number:, label:)
          @held = Held.new(session:, number:, label: -label.to_s)
          @sent = nil
          self
        end

        # @return [Boolean] whether a round is held at all
        def open? = !@held.nil?

        # How the held round's target was named on screen, which is what a
        # report says instead of restating a class or re-deriving a number.
        #
        # Answers a String either way -- {NOTHING_HELD} when no round is held --
        # so a caller reporting an outcome never nil-checks a slot it has just
        # sent something to.
        #
        # @return [String]
        def target = @held.nil? ? NOTHING_HELD : @held.label

        # Build the payload from the held round and send it, once.
        #
        # @param executor [#submit_review] {Forge::Gh}, {Forge::Gh::Recorded} or
        #   {Forge::Journaled} over either
        # @param body [String] the human's own summary of the review
        # @return [Forge::Gh::Answer] the executor's answer, unchanged --
        #   {Submit#call}'s doctrine, and this tier does not soften it either
        # @raise [NotOpen] with no round held
        # @raise [Nowhere] for a round opened on a branch
        # @raise [AlreadySent] for a second submit of one round
        # @raise [Submit::Refused] for a comment naming an unplaceable range
        # @raise [Submit::Nothing] for a review that would say nothing
        def submit(executor:, body: "")
          held = ready!
          answer = Submit.for(session: held.session, executor:, number: held.number).call(body:)
          @sent = answer
          answer
        end

        private

        # Every reason not to send, asked before a payload is built.
        def ready!
          raise NotOpen, NOTHING_OPEN if @held.nil?
          raise AlreadySent, format(SENT_ALREADY, number: @held.number, outcome:) unless @sent.nil?
          raise Nowhere, format(NOT_A_PULL_REQUEST, label: @held.label) if @held.number.nil?

          @held
        end

        def outcome = @sent.ok? ? RECORDED : UNCERTAIN
      end
    end
  end
end
