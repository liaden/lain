# frozen_string_literal: true

module Lain
  module Forge
    class Landing
      # One named step of the protocol, and the object the first version of this
      # class was missing.
      #
      # A step knows four things and nothing else: which {ACTIONS} member it
      # performs, how to tell from the {Evidence} that its effect is already in
      # place, how to perform it through the journaled bracket, and what the
      # {Running} run carries away. With those four, {Landing#call} and
      # {Landing#resume_from} are one fold over one {Plan} -- there is no second
      # place a step could be skipped, repeated, or have its verdict dropped.
      #
      # A module rather than a superclass: the three steps share a PROTOCOL, not
      # any state, and each holds a different set of collaborators. Inheriting an
      # empty constructor to satisfy a template would be the shared thing
      # inventing itself.
      module Step
        # Double dispatch, and it is what removes the nil check: the evidence
        # answers a {Evidence::Held} or a {Evidence::Missing}, and IT decides
        # which of this step's two branches runs.
        def advance(run, evidence) = found(evidence).through(self, run)

        # Found already in place. Most steps carry nothing away from that, and
        # nothing was performed, so the run passes through untouched -- which is
        # what makes a repeated resume a fixpoint rather than a second landing.
        def held(run, _value) = run

        # Nothing shows it in place, so perform it -- AND READ THE ANSWER.
        #
        # B1: {Promotion} refuses a diverged remote, an occupied namespace and an
        # inexact sha as `ok: false` values. A step that discarded that verdict
        # would carry on to open a pull request from a branch the promotion
        # never wrote, and merge somebody else's commit as this issue's approved
        # work. Every refusal in this tier is a value; a value nobody reads is a
        # refusal that did not happen.
        def missing(run)
          answer = call(run)
          return Stopped.new(answer:) unless answer.ok?

          advanced(run.after(answer), answer)
        end

        private

        # Most steps ask one question: did this issue's journal settle this
        # action, or does the world say it happened anyway.
        def found(evidence) = evidence.about(action)

        # What a performed step adds to the run beyond "something happened".
        def advanced(run, _answer) = run
      end

      # Put the approved commit on the remote as `epic/<slug>/<issue>`.
      #
      # The sha is constructor state, not a per-call argument: it is the one the
      # gate cleared, and a step that could be handed another would be a step
      # that could land an unapproved commit.
      class Promote
        include Step

        def initialize(promotion:, sha:)
          @promotion = promotion
          @sha = sha
          freeze
        end

        def action = PROMOTE

        def call(_run) = @promotion.call(sha: @sha)
      end

      # Open the pull request, against main.
      class Open
        include Step

        def initialize(journaled:, base:, head:, title:, body:)
          @journaled = journaled
          @base = base
          @head = head
          @title = title
          @body = body
          freeze
        end

        def action = PR_CREATE

        # The one step with a result a later step needs, so it is the one step
        # that carries something away from having been skipped.
        def held(run, value) = run.with(number: value)

        def call(_run) = @journaled.pr_create(base: @base, head: @head, title: @title, body: @body)

        private

        # The awkward address: a crash between the intent and its outcome leaves
        # nothing recording the number, so the head ref is the only thing that
        # exists on both sides. {Evidence} resolves it, once, under its own
        # catch.
        def found(evidence) = evidence.pull_request

        def advanced(run, answer) = run.with(number: answer.value)
      end

      # Merge the pull request, but only into a state that says it may be.
      class Merge
        include Step

        def initialize(journaled:)
          @journaled = journaled
          freeze
        end

        def action = PR_MERGE

        # {Journaled#merge_state} forwards untouched and journals nothing --
        # asking whether a pull request is mergeable causes nothing, so there is
        # no bet to record. Which is why this class needs no second handle on the
        # raw {Gh}.
        def call(run)
          state = @journaled.merge_state(number: run.number)
          return state unless state.ok?
          return refusal(state.value) unless state.value.to_s == CLEAN

          @journaled.pr_merge(number: run.number)
        end

        private

        # S5: only DIRTY is a merge CONFLICT. {Gh::Poll} answers UNKNOWN when its
        # own bound runs out -- GitHub has not finished computing mergeability,
        # which usually means CI is still running -- and BLOCKED, BEHIND and
        # UNSTABLE are review and branch protection saying "not yet". Telling a
        # human there is a merge conflict sends them to resolve nothing, and the
        # remedy for each of these is different. The state itself is carried
        # either way, so the record never loses GitHub's own word.
        def refusal(state)
          Gh::Answer.new(ok: false,
                         detail: { "reason" => state.to_s == DIRTY ? CONFLICTED : NOT_MERGEABLE, "state" => state })
        end
      end
    end
  end
end
