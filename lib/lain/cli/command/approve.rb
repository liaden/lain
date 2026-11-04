# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/approve`: drains the parked approval queue inline -- each undecided
      # {Approval::Parked::Queue::Pending} is rendered for y/N in turn through the
      # injected prompt ({Frontend::ApprovalPolicy}, the SAME prompt loop the
      # watch surface uses, so decisions are signed "tty" and fail closed on
      # anything but an explicit yes). The prompt collaborator owns the
      # terminal question (its reader routes through the conductor); this
      # command only walks the queue and RETURNS the outcome as text.
      class Approve
        NOTHING_PENDING = "no pending approvals"

        # @param prompt [#decide] answers one pending y/N; injected so the
        #   wiring's conductor-routed reader -- not a bare gets -- owns stdin
        def initialize(prompt:)
          @prompt = prompt
          freeze
        end

        def name = "approve"

        def usage = "/approve -- answer each pending tool approval y/N"

        # THIS command reads the human's answer itself too: the `[y/N]` it asks
        # takes its line off the input rail like every other prompt. Typed at a
        # reply prompt it still RUNS -- that prompt's `/inbox` detour asks which
        # command it is, not this.
        def serves_replies? = true

        # Held behind a run, a line of this goes stale: what it would approve
        # is decided or gone by the time `you>` returns.
        def disposition = :control

        # @return [String, nil] why there is nothing to approve now
        def refusal(env) = (NOTHING_PENDING if undecided(env).empty?)

        def call(_args, env)
          undecided = undecided(env)
          return NOTHING_PENDING if undecided.empty?

          undecided.each { |pending| @prompt.decide(pending) }
          undecided.map { |pending| Approve.outcome_line(pending) }.join("\n")
        end

        # A surface other than ours can win a pending mid-drain (first answer
        # wins is the queue's own doctrine); the line then NAMES the deciding
        # surface, so a "denied (timeout)" never reads as the human's no.
        #
        # @param pending [Approval::Parked::Queue::Pending] a decided call
        # @param subject [String] how the line names the call
        # @return [String]
        def self.outcome_line(pending, subject = pending.tool)
          surface = Frontend::ApprovalPolicy::SURFACE
          "#{subject}: #{pending.verdict_face}#{" (#{pending.surface})" unless pending.surface == surface}"
        end

        private

        def undecided(env) = env.approvals.each.reject(&:decided?)
      end
    end
  end
end
