# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/approve`: drains the parked approval queue inline -- each undecided
      # {Approval::Queue::Pending} is rendered for y/N in turn through the
      # injected prompt ({Frontend::ApprovalPolicy}, the SAME prompt loop the
      # watch surface uses, so decisions are signed "tty" and fail closed on
      # anything but an explicit yes). The prompt collaborator owns the
      # terminal question (its reader routes through the conductor); this
      # command only walks the queue and RETURNS the outcome as text.
      class Approve
        # @param prompt [#decide] answers one pending y/N; injected so the
        #   wiring's conductor-routed reader -- not a bare gets -- owns stdin
        def initialize(prompt:)
          @prompt = prompt
          freeze
        end

        def name = "approve"

        def usage = "/approve -- answer each pending tool approval y/N"

        def call(_args, env)
          undecided = env.approvals.each.reject(&:decided?)
          return "no pending approvals" if undecided.empty?

          undecided.each { |pending| @prompt.decide(pending) }
          undecided.map { |pending| outcome_line(pending) }.join("\n")
        end

        private

        # A surface other than ours can win a pending mid-drain (first answer
        # wins is the queue's own doctrine); the line then NAMES the deciding
        # surface, so a "denied (timeout)" never reads as the human's no.
        def outcome_line(pending)
          verdict = pending.approved? ? "approved" : "denied"
          surface = Frontend::ApprovalPolicy::SURFACE
          "#{pending.tool}: #{verdict}#{" (#{pending.surface})" unless pending.surface == surface}"
        end
      end
    end
  end
end
