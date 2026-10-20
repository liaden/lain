# frozen_string_literal: true

module Lain
  module Tools
    # Puts one of an epic's stages in front of its gate, in-process, through
    # the same submitter `lain epic submit` uses, and answers with its verdict.
    #
    # It asks no tool approval: an interactive gate already asks the human
    # through the chat's question surfaces, and a second prompt for the same
    # decision would be noise.
    class EpicSubmit < Tool
      # `implementation` gates a changeset address only the epic driver holds.
      STAGES = %w[research epic_plan issue_plan].freeze
      ADJUDICATED = Epic::Gate::Policy::Adjudicated::NAME

      # Only the shape is checked here; whether the epic, the issue and the
      # artifact exist is the submitter's to refuse, by name.
      class Input < Tool::Input
        field :stage, :string, required: true,
                               description: "Which stage to submit: research (research.md), epic_plan (epic.md) " \
                                            "or issue_plan (plans/<issue>.md)."
        field :slug, :string, required: true, description: "The epic's slug, for example frugirl-mvp."
        field :issue, :string, description: "The issue id. Required for stage issue_plan, ignored otherwise."

        validates :stage, inclusion: { in: STAGES, message: "must be one of #{STAGES.join(", ")}" }
        validates :issue, presence: true, if: -> { stage == "issue_plan" }
      end

      input_model Input

      # @param submitter [#submit] answers `submit(stage, slug, issue:)` with
      #   the verdict as a String, as {CLI::EpicSubmit#submit} does
      def initialize(submitter:)
        super()
        @submitter = submitter
      end

      def name = "epic_submit"

      def description
        "Submits an epic stage (research, epic_plan or issue_plan) to its approval gate and returns the verdict. " \
          "An interactive gate asks the human and waits for their answer; if nobody answers within the gate's " \
          "window, the gate denies and nothing advances."
      end

      protected

      def perform(input, _invocation)
        Tool::Result.ok(@submitter.submit(input.stage, input.slug, issue: input.issue))
      rescue Epic::Gate::Policies::Refusal => e
        Tool::Result.error("#{unwirable(e)}; ask the user to run `#{shell_command(input)}` from a shell")
      rescue Lain::Error, SystemCallError => e
        Tool::Result.error(e.message)
      end

      private

      def unwirable(refusal)
        return "#{refusal.message}, which a chat cannot wire" unless refusal.policy == ADJUDICATED

        "the #{refusal.stage} gate is adjudicated, and a chat cannot build the adjudication spike prompt it needs"
      end

      def shell_command(input)
        Lain::Epic::Remedy.submit(input.stage, input.slug, issue: (input.issue if input.stage == "issue_plan"))
      end
    end
  end
end
