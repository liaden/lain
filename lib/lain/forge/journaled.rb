# frozen_string_literal: true

module Lain
  module Forge
    # The intent-before-effect bracket around either executor: an {Intent} on the
    # journal, then the effect, then an {Outcome}. Every call forwards untouched,
    # so the executor stays journal-ignorant -- {Isolation::Journal}'s decorator
    # shape, and what keeps {Gh}'s own spec free of a journal.
    #
    # == Intent first, and this is NOT Epic::Home::Journaled's ordering
    #
    # {Epic::Home::Journaled} writes the file and journals afterwards, because
    # `doc_written` is an ACK: the bytes are on disk and a reader may join to
    # them. Here the ordering is the opposite and equally deliberate. A forge
    # action pushes a ref or merges a pull request -- effects no local file can
    # be re-read to discover -- so an intent with no outcome is precisely the
    # shape of a crash, and {Reconcile} is what reads it back and asks the world
    # which of them landed. Do not harmonise the two.
    #
    # A raise BETWEEN the two records is the one crash still legible from inside
    # the process, so it is journaled as a not-ok outcome and then allowed
    # through: the caller sees the failure, and the record shows an attempt that
    # was made and failed rather than an intent that looks abandoned.
    #
    # == One issue's worth of work
    #
    # `epic_slug` and `issue_id` are constructor state rather than per-call
    # arguments, which is what keeps every verb's arity equal to the executor's.
    # A decorator with wider verbs than the thing it wraps is not substitutable
    # for it, and substitutability is the whole reason this exists.
    class Journaled
      # @param executor [#pr_create, #pr_merge, #pr_view, #merge_state, #submit_review]
      #   the real executor every call forwards to -- {Gh} or {Gh::Recorded}
      # @param journal [#<<] where {Intent} and {Outcome} records land
      # @param epic_slug [String] the epic this run's actions belong to
      # @param issue_id [String] the issue they are being done for
      def initialize(executor, journal:, epic_slug:, issue_id:)
        @executor = executor
        @journal = journal
        @epic_slug = epic_slug
        @issue_id = issue_id
        freeze
      end

      # The address is `head` AND `base`, and the pair is deliberate: GitHub's
      # uniqueness key for an OPEN pull request is (head, base), so two pull
      # requests from one head into different bases can both exist. `head` alone
      # would satisfy {Intent.id_for}'s "uniquely address the effect repo-wide"
      # only by the CONVENTION that base is always main -- and a convention is
      # not what that doc claims. The title and body stay out: they are the
      # effect's content, and journaling them would make a retry with a
      # corrected title read as different work, costing {Reconcile}'s pairing law
      # its repeat.
      #
      # {Reconcile::Observer} asks `pr_for(head:)`, which is COARSER than this
      # address -- it cannot name a base. That is fine while base is main and is
      # T24's `world` duck to sharpen if a repo ever targets two.
      def pr_create(base:, head:, title:, body:)
        attempt(action: PR_CREATE, params: { "head" => head, "base" => base }) do
          @executor.pr_create(base:, head:, title:, body:)
        end
      end

      def pr_merge(number:, auto: false)
        attempt(action: PR_MERGE, params: { "number" => number }) { @executor.pr_merge(number:, auto:) }
      end

      # The address is the number AND the payload, and this spelling must match
      # {Gh::Recorded#submit_review}'s exactly -- a recording keyed on one and
      # looked up by the other replays nothing.
      #
      # The payload is IN the address rather than beside it, unlike pr_create's
      # title and body. It has to be: an accepted review POST creates a review
      # each time, so a reworded review is different work, and the whole of what
      # was sent belongs on the journal anyway -- it is the only record of what
      # a human actually said about the diff.
      def submit_review(number:, review:)
        attempt(action: REVIEW_SUBMIT, params: { "number" => number, "review" => review }) do
          @executor.submit_review(number:, review:)
        end
      end

      # Observations forward and journal NOTHING: asking whether a pull request
      # is mergeable causes nothing, so there is no bet to record and no crash it
      # could leave half-done.
      def pr_view(ref:, fields:) = @executor.pr_view(ref:, fields:)

      def merge_state(number:) = @executor.merge_state(number:)

      # The bracket itself, public because a producer of any closed {ACTIONS}
      # member needs it and not all of them are gh verbs -- a promotion is a git
      # push, and it owes the same pair. The two verbs above are this method with
      # their address filled in.
      #
      # `params` must ADDRESS the effect repo-wide, because it is the whole of
      # the intent_id ({Intent.id_for} states the obligation in full).
      #
      # THE CONTRACT ON THE BLOCK: it must answer something that responds to
      # `ok?`, `observed?` and `detail` -- {Gh::Answer} is the shipped one. Those
      # three are sent inside the same protected region as the block itself, so a
      # block answering anything else journals a not-ok outcome and then raises;
      # it never leaves the intent unanswered. A block that raises does the same.
      # Either way the caller sees the exception and the journal shows an attempt
      # that was made and failed.
      #
      # @param action [String] one of {Forge::ACTIONS}
      # @param params [Hash] the effect's address
      # @yieldreturn [#ok?, #observed?, #detail] what the effect answered
      # @return the block's own answer, unchanged
      # @raise [ArgumentError] before anything is journaled, for an action
      #   outside {Forge::ACTIONS}
      def attempt(action:, params:, &block)
        intent = Intent.new(action:, epic_slug: @epic_slug, issue_id: @issue_id, params:)
        @journal << intent
        attempted(intent, &block)
      end

      private

      # The block's answer is READ inside this rescue, not after it, and the
      # placement is the whole point of the method.
      #
      # {#attempt} is public so a producer that is not a gh verb can reuse the
      # bracket -- T18's promote is the intended caller -- and nothing can make
      # such a block answer a {Gh::Answer}. Read one line further out, a block
      # answering anything else raises AFTER the intent is journaled and BEFORE
      # any outcome, which is the exact shape {Reconcile} reads as "we may have
      # pushed and died": the worst lie this tier can tell, told by a caller that
      # never reached the world at all.
      #
      # The duck is held by SENDING it the three messages inside the protected
      # region rather than by testing the block's return type -- depend on
      # messages, not on types, and let a producer that answers them do so.
      def attempted(intent)
        answer = yield
        record(intent, ok: answer.ok?, observed: answer.observed?, detail: answer.detail)
        answer
      rescue StandardError => e
        record(intent, ok: false, observed: false, detail: { "error" => "#{e.class}: #{e.message}" })
        raise
      end

      # rubocop:disable Naming/MethodParameterName -- `ok` is {Outcome}'s
      # journaled field name; renaming it here would only have to be renamed back
      # on the next line.
      def record(intent, ok:, observed:, detail:)
        @journal << Outcome.new(intent_id: intent.intent_id, ok:, observed:, detail: attributed(detail))
      end
      # rubocop:enable Naming/MethodParameterName

      # {Outcome} carries only a digest, so an ORPHANED outcome -- one answering
      # no intent the journal still holds -- could not otherwise be traced to
      # anybody's problem. The convention is that producers put the attribution
      # in `detail`, and this is the producer.
      #
      # Attribution wins the merge: an executor that happened to put an
      # `epic_slug` in its own detail would otherwise name a different epic than
      # the intent one line above it.
      def attributed(detail) = detail.to_h.merge("epic_slug" => @epic_slug, "issue_id" => @issue_id)
    end
  end
end
