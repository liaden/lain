# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/deny <reason>`: refuses a parked call with the human's reason, which
      # the agent reads as the last clause of its tool result. With one call
      # parked it is denied at once. With several, each is asked y/N in turn
      # through the same prompt `/approve` asks with, and the first this walk
      # denies ends it. While a call is asked the reason is offered on it, so a
      # bare `n` at any terminal prompt about that call carries the reason.
      class Deny
        NOTHING_PENDING = Approve::NOTHING_PENDING

        # How much of the call a line names: enough to tell two calls apart.
        PREVIEW = 60

        # @param prompt [#decide] asks one pending y/N, as {Approve}'s does
        def initialize(prompt:)
          @prompt = prompt
          freeze
        end

        def name = "deny"

        def usage = "/deny <reason> -- deny the parked call with a reason; with several, asks which"

        # With several calls parked it asks its `[y/N]` off the input rail, as {Approve} does.
        def serves_replies? = true

        # Held behind a run, a deny reaches a call already decided or gone.
        def disposition = :control

        # @return [String, nil] why there is nothing to deny now
        def refusal(env) = (NOTHING_PENDING if undecided(env).empty?)

        def call(args, env)
          undecided = undecided(env)
          return NOTHING_PENDING if undecided.empty?

          verdict = Approval::Reply.parse("deny #{args}")
          decided = undecided.one? ? denied(undecided.first, verdict) : chosen(undecided, verdict.note)
          decided.map { |pending| Approve.outcome_line(pending, preview(pending)) }.join("\n")
        end

        private

        def undecided(env) = env.approvals.each.reject(&:decided?)

        def denied(pending, verdict)
          pending.decide(verdict, surface: Frontend::ApprovalPolicy::SURFACE, authority: :human)
          [pending]
        end

        # Only a deny this walk's own prompt made ends it: a call another
        # surface decided meanwhile is not the one the human chose.
        def chosen(undecided, reason)
          asked = undecided.lazy.map { |pending| [pending, pending.offering(reason) { @prompt.decide(pending) }] }
          asked.slice_after { |pending, won| won && pending.decision == :deny }.first.map(&:first)
        end

        def preview(pending)
          face = pending.call_face
          face.length > PREVIEW ? "#{face[0, PREVIEW]}…" : face
        end
      end
    end
  end
end
