# frozen_string_literal: true

module Lain
  module Forge
    # The serial protocol that takes a finished epic to main as one pull
    # request: promote its working branch, open the pull request against main,
    # merge it, delete the remote branch. Every external effect goes through
    # {Journaled}, so each is an {Intent} on the journal before it is attempted
    # and an {Outcome} after.
    #
    # Each issue already landed onto the working branch through
    # {LocalLanding}, behind its own implementation gate; whether the epic may
    # finish at all -- every issue done -- is decided before this is built.
    #
    # == There is ONE sequence here, and it is a fold
    #
    # {#call} and {#resume_from} differ in the EVIDENCE they fold against and in
    # nothing else: a fresh landing folds the plan against {Evidence::NONE}, a
    # resume folds the same plan against what {Reconcile} read back. A second
    # copy of a protocol is a second protocol; there is one, and it is {Plan}.
    #
    # == Every verdict is READ, and any step can stop the run
    #
    # {Promotion} refuses a diverged remote, an occupied namespace, an
    # unreachable remote and an inexact sha as `ok: false` VALUES, so {Step#missing}
    # reads the answer it got, and a not-ok answer turns the {Running} run into a
    # {Stopped} one that every later step answers with itself.
    #
    # == Refusals are values here too
    #
    # A conflict, an unreadable merge state, an inconsistent journal: each
    # answers a not-ok {Gh::Answer} carrying a `reason` a human can act on --
    # never a raise, and never a bare {Reconcile::Report}.
    class Landing
      # The one base. {Reconcile}'s `pr_for(head:)` cannot name a base, so a
      # repo targeting two would need that sharpened first.
      BASE = "main"

      # The issue an epic-wide intent is attributed to. An {Intent} names the
      # issue its work is for, and the epic's one pull request is for every
      # issue at once.
      WHOLE_EPIC = "*"

      # GitHub's own merge-state words, and the two verdicts this class draws
      # from them. Constants rather than sentences: a reworded string must not
      # move a decision.
      CLEAN = "CLEAN"
      DIRTY = "DIRTY"
      CONFLICTED = "conflicted"
      NOT_MERGEABLE = "not_mergeable"

      # A journal no landing may continue from -- an orphaned outcome, an intent
      # the world cannot be asked about, a head ref that answers ambiguously.
      INCONSISTENT = "inconsistent_journal"

      # A pull request somebody else merged: the merge step's effect, found in place.
      ALREADY_MERGED = "already_merged"

      # @param epic_slug [String] the epic whose working branch lands
      # @param sha [String] the full object name of `epic/<slug>`'s tip
      # @param promotion [#call, #delete] {Promotion}, for this same epic
      # @param journaled [#pr_create, #pr_merge, #merge_state, #attempt] the
      #   intent/outcome bracket. ONE executor collaborator, not two:
      #   {Journaled#merge_state} forwards untouched and journals nothing, so a
      #   second handle on the raw {Gh} could only be wired to a different repo
      # @param base [String] the branch the pull request lands against
      # @param title [String, nil] the pull request title
      # @param body [String, nil] the pull request body
      def initialize(epic_slug:, sha:, promotion:, journaled:, base: BASE, title: nil, body: nil)
        @head = "epic/#{epic_slug}".freeze
        @sha = sha
        @plan = Plan.new(promotion:, journaled:, sha:, base:, head: @head, title: title || "epic #{epic_slug}",
                         body: body || "Land epic #{epic_slug}: every issue is done")
        freeze
      end

      # A landing with nothing already known about it.
      #
      # @return [Gh::Answer] ok carrying the merged pull request's number, or
      #   not-ok carrying the reason the run stopped
      def call = land(Evidence::NONE)

      # Continue a landing from what its journal and the world can be made to
      # agree on.
      #
      # @param entries [Enumerable<Hash, String>] this epic's journal records
      # @param world [#ref_exists?, #sha_of, #pr_state, #pr_for] {Reconcile}'s
      #   observation seam
      # @param wiring [Hash] {#initialize}'s keywords
      # @return [Gh::Answer]
      def self.resume(entries:, world:, **wiring) = new(**wiring).resume_from(entries:, world:)

      # @return [Gh::Answer]
      def resume_from(entries:, world:)
        records = Journal.records(entries).to_a
        land(Evidence.gathered(entries: current(records), whole: records, world:, head: @head))
      end

      private

      # A landing is addressed by the sha it lands: its records start at the
      # first promote of that sha to this branch. An epic that gained an issue
      # after it finished lands again at its new tip, and the earlier
      # landing's settled steps are that landing's, not this one's.
      def current(records)
        start = records.index { |record| promotes_this?(record) }
        start.nil? ? [] : records.drop(start)
      end

      def promotes_this?(record)
        record["type"] == Intent::JOURNAL_TYPE && record["action"] == PROMOTE &&
          record["params"].to_h.values_at("ref", "sha") == ["refs/heads/#{@head}", @sha]
      end

      def land(evidence) = @plan.inject(evidence.opening) { |run, step| run.advance(step, evidence) }.answer
    end
  end
end
