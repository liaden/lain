# frozen_string_literal: true

module Lain
  module Forge
    # The serial protocol that lands ONE approved issue: check the gate, promote
    # the anchored commit, open a pull request against main, merge it, move the
    # issue to done. Every external effect goes through {Journaled}, so each is
    # an {Intent} on the journal before it is attempted and an {Outcome} after.
    #
    # == There is ONE sequence here, and it is a fold
    #
    # {#call} and {#resume_from} differ in the EVIDENCE they fold against and in
    # nothing else: a fresh landing folds the plan against {Evidence::NONE}, a
    # resume folds the same plan against what {Reconcile} read back. The first
    # version of this class inlined the sequence twice and the two copies
    # disagreed in five ways -- a skipped verdict, a repeated transition, an
    # uncaught {Unobservable}, a raw Report returned where an Answer was, and a
    # `settled?` that did not look at `ok`. A second copy of a protocol is a
    # second protocol; there is one, and it is {Plan}.
    #
    # == Every verdict is READ, and any step can stop the run
    #
    # {Promotion} refuses a diverged remote, an occupied namespace, an
    # unreachable remote and an inexact sha as `ok: false` VALUES -- "every
    # refusal is a value; only a caller's own nonsense raises". A caller that
    # discards those answers opens a pull request from a branch standing at
    # somebody else's commit and merges it as this issue's approved work. So
    # {Step#missing} reads the answer it got, and a not-ok answer stops the fold
    # by turning the {Running} into a {Stopped} that every later step answers
    # with itself. No `break`, no early return threaded through two methods.
    #
    # == Refusals are values here too
    #
    # A conflict, an unreadable merge state, an inconsistent journal: each
    # answers a not-ok {Gh::Answer} carrying a `reason` a human can act on --
    # never a raise, and never a bare {Reconcile::Report}, which a caller
    # sending `ok?` meets as a NoMethodError. `base` is always main; retargeting
    # and cascade are a later chunk's, and nothing here forces anything.
    class Landing
      # Serial landing means one base, and it is main. A repo that ever targets
      # two would need {Reconcile}'s `pr_for(head:)` sharpened first -- it
      # cannot name a base -- which is the cascade chunk's boundary, not this
      # one's.
      BASE = "main"

      # GitHub's own merge-state words, and the two verdicts this class draws
      # from them. Constants rather than sentences: {CLI::EpicLand} renders
      # `reason` to a human and a reworded string must not move a decision.
      CLEAN = "CLEAN"
      DIRTY = "DIRTY"
      CONFLICTED = "conflicted"
      NOT_MERGEABLE = "not_mergeable"

      # A journal no landing may continue from -- an orphaned outcome, an intent
      # the world cannot be asked about, a head ref that answers ambiguously.
      INCONSISTENT = "inconsistent_journal"

      # The status an issue holds while its implementation is in flight. Not
      # {Epic::DONE}'s neighbour in a constant of its own over there, so it is
      # named here where the transition is written.
      IN_FLIGHT = "in_flight"

      # @param epic_slug [String] the epic this issue belongs to
      # @param issue_id [String] the issue being landed
      # @param artifact [#digest] the implementation submission the gate judged
      # @param sha [String] the full object name of the approved commit
      # @param gate [#ensure_approved!] {Approval::Gate}
      # @param promotion [#call] {Promotion}, wired for this same issue
      # @param journaled [#pr_create, #pr_merge, #merge_state, #attempt] the
      #   intent/outcome bracket. ONE executor collaborator, not two:
      #   {Journaled#merge_state} and {Journaled#pr_view} forward untouched and
      #   journal nothing, precisely so a caller needs no second handle on the
      #   raw {Gh}. A second one could be wired to a different repo than the
      #   bracket, which is the mis-wiring {Promotion} documents at length.
      # @param scribe [#issue_moved] {Epic::Scribe}
      # @param base [String] the branch the pull request lands against; {BASE}
      #   unless the epic is targeting something other than the trunk
      # @param title [String, nil] the pull request title; nil falls back to
      #   the issue id itself
      # @param body [String, nil] the pull request body; nil falls back to
      #   "Land #{issue_id}"
      def initialize(epic_slug:, issue_id:, artifact:, sha:, gate:, promotion:, journaled:, scribe:,
                     base: BASE, title: nil, body: nil)
        @artifact = artifact
        @gate = gate
        @head = "epic/#{epic_slug}/#{issue_id}".freeze
        @plan = Plan.new(promotion:, journaled:, scribe:, sha:, base:, issue_id:, head: @head,
                         title: title || issue_id.to_s, body: body || "Land #{issue_id}")
        freeze
      end

      # A landing with nothing already known about it.
      #
      # @return [Gh::Answer] ok carrying the merged pull request's number, or
      #   not-ok carrying the reason the run stopped
      # @raise [Approval::Gate::NotApproved] before the first intent
      def call = land(Evidence::NONE)

      # Continue a landing from what its journal and the world can be made to
      # agree on.
      #
      # @param entries [Enumerable<Hash, String>] this issue's journal records
      # @param world [#ref_exists?, #sha_of, #pr_state, #pr_for] {Reconcile}'s
      #   observation seam
      # @param wiring [Hash] {#initialize}'s keywords
      # @return [Gh::Answer]
      def self.resume(entries:, world:, **wiring) = new(**wiring).resume_from(entries:, world:)

      # @return [Gh::Answer]
      def resume_from(entries:, world:) = land(Evidence.gathered(entries:, world:, head: @head))

      private

      # The whole protocol, and the only place it is spelled.
      def land(evidence)
        @gate.ensure_approved!(@artifact)
        @plan.inject(evidence.opening) { |run, step| run.advance(step, evidence) }.answer
      end
    end
  end
end

# This file is the landing/ subtree's index. Every child reopens `class Landing`
# and reads its constants in method bodies only, so any order loads -- they are
# listed in the order the fold uses them (CLAUDE.md, Requires).
require_relative "landing/run"
require_relative "landing/evidence"
require_relative "landing/step"
require_relative "landing/transition"
require_relative "landing/plan"
