# frozen_string_literal: true

module Lain
  module QA
    # The default binding: ONE rung, naming no model, so it runs on whatever the
    # session runs on. The ladder's sampling and stopping discipline without its
    # cost gradient, which is what a pass gets until a project states its tiers.
    #
    # ONE MODEL IS ONE RUNG. A cheap rung and a strong rung both on the session's
    # model is the same-model retry the measured evidence rules out, and {Ladder}
    # refuses it outright -- a second rung here would buy three extra asks that
    # could only ever escalate to itself.
    #
    # ITS VOICE SETTLES NOTHING, so a default pass leaves every criterion
    # unsettled and owing a manual pass. That is deliberate and it is the whole
    # honesty of the default: nothing here can measure the session model, which is
    # whatever the human chose to chat with, and declaring it fit would re-enter
    # the measured hazard below on the one rung where no guard could ever inspect
    # it. A pass that accepts is not worth more than a pass that is honest, and
    # AC-wise "unsettled, never a pass" is the guarantee that survives.
    #
    # == THE MEASUREMENT, which is documentation and not a default
    #
    # Named here because this is where the tier recommendations live, so a project
    # binding a rung has read them; they are not enforced anywhere in `lib`,
    # because a name check is evadable by capitalisation, by a registry prefix and
    # by a GGUF tag, and cannot fire at all on a rung that named no model.
    #
    # - Cheap rung, measured 32 of 32 on the acceptance items: `laguna-xs-2.1` or
    #   `north-mini-code-1.0`. NOT a 4B model.
    # - Strongest reviewer: `qwen3.8:27b`, every planted bug and no false alarms,
    #   but the slowest and it crashed the runner twice in 81 requests.
    # - DO NOT bind `qwen3-coder:30b` or `lfm2.5` as a verdict-holding rung:
    #   measured identically on both ollama builds, they wrongly pass real
    #   acceptance violations, 4 of 16 and 6 of 16. Either is fine as a sampling
    #   rung whose voice settles nothing.
    module SessionTiers
      # The one rung a default pass runs. The cheaper tier ships empty, so a report
      # naming only this one tells the truth: there was no cheap rung to run.
      TIER = "t2"

      # Three independent asks, so disagreement and an executed failure are still
      # measured with no cheaper rung to measure them at.
      SAMPLES = 3

      # @param role_spawn [Skill::RoleSpawn] the one spawn the run holds
      # @param role [Symbol] the persona the rung asks as, so a caller may bind
      #   the ladder to one of its own
      # @return [Array<Ladder::Rung>]
      def self.call(role_spawn, role: :qa)
        [Ladder::Rung.spawning(tier: TIER, role_spawn:, role:, samples: SAMPLES)]
      end
    end
  end
end
