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

        NOT_A_PULL_REQUEST = "this review was opened on %<label>s, which has no pull request to post a " \
                             "review to -- the annotations and the verdict are on the journal either way. " \
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

        # One round, and where it posts. `number` is nil for a round with no
        # pull request under it -- a branch review, a survey -- which is what
        # {Nowhere} is about; `label` is the caller's own words for the target,
        # so the refusal names what the human typed rather than a class.
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
        # @param session [Review::Session] the round, read and never written.
        #   Read for `#source` as well as at submit time, since {#held_source}
        #   answers off it -- a holder passing something that cannot name its
        #   source will hear about it from there.
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

        # WHAT the held round was opened over, in its source's own word --
        # `local_branch`, `github_pr`, `corpus`. Data, not a judgement: a chat
        # has one set of gesture rails, so `/review` and `/survey` each need to
        # tell the round THEY opened from the other command's before rebinding
        # them, and each of them already knows its own word. Deciding here which
        # word means what would put a kind test on the object whose one
        # responsibility is submission.
        #
        # nil with nothing held, which is what makes every caller's `open? &&
        # ...` read as one question rather than two.
        #
        # @return [String, nil]
        def held_source = held_session&.source

        # HOW MUCH the held round has to say, for a report rather than for a
        # submission: `/introspect` names it at the prompt so a human can see a
        # round they have annotated and one they have only opened as the
        # different things they are.
        #
        # A COUNT and not the notes themselves, deliberately -- this class's one
        # responsibility is submission, and handing out the round's annotations
        # would let a caller build a payload beside {#submit}, which is the one
        # thing that may not happen twice.
        #
        # nil with nothing held, on {#held_source}'s terms and for its reason:
        # zero is a real answer about a real round (opened, nothing written yet)
        # and must not be how absence reads. Callers ask `open? && ...`, one
        # question, exactly as they do there.
        #
        # @return [Integer, nil]
        def annotation_count = held_session&.annotations&.size

        # WHAT the held round concluded, in the session's own word -- or
        # {Verdict::None} while it is still awaiting judgement, and with nothing
        # held at all.
        #
        # The same forwarding {#held_source} is, and held to the same rule: the
        # question goes to the session this object already holds and the answer
        # comes back unread. Nothing here judges, so nothing here remembers a
        # judgement either -- the word is read at the moment of asking, which is
        # why {Session#submit} needs no outbox to settle a round.
        #
        # A verdict answers `#empty?` on both sides ({Verdict::None}, and a
        # {Review::VERDICTS} String), so a caller asking whether a round is
        # still live writes `held_verdict.empty?` with no type test -- and
        # {Verdict::None} with nothing held keeps that from being a nil check
        # either.
        #
        # It navigates the held round EXACTLY as {#held_source} and
        # {#annotation_count} do -- through {#held_session}, the one peek all
        # three share -- so the three readers tolerate the same amount of absence
        # and no caller has to know which of them it is holding: `&.` for a round
        # that is not there, and a loud `NoMethodError` for a `session:` that is
        # not a {Session}, which is what {#hold}'s own doc defers to its readers.
        # All that differs is what stands in for the absence, and only because a
        # verdict HAS a null object to stand in with and the other two do not.
        #
        # @return [String, Verdict::None]
        def held_verdict = held_session&.verdict || Verdict::None

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

        # The held round's own model, or nothing -- the ONE `@held` peek all
        # reading readers above go through ({#held_source},
        # {#annotation_count}, {#held_verdict}), so "is a round held" is asked in
        # one place rather than spelled as a safe-navigation chain per reader,
        # which is how the three would come to tolerate different amounts of
        # absence one edit at a time.
        def held_session = @held&.session

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
