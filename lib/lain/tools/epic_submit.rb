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

      ELSEWHERE = "review %<id>s read the %<stage>s stage of %<slug>s, not the %<asked>s stage of %<asked_slug>s; " \
                  "run epic_review for this gate and pass its id"

      # Only the shape is checked here; whether the epic, the issue and the
      # artifact exist is the submitter's to refuse, by name.
      class Input < Tool::Input
        field :stage, :string, required: true,
                               description: "Which stage to submit: research (research.md), epic_plan (epic.md) " \
                                            "or issue_plan (issues/<issue>.md)."
        field :slug, :string, required: true, description: "The epic's slug, for example frugirl-mvp."
        field :issue, :string, description: "The issue id. For stage issue_plan, name an issue or a wave."
        field :wave, :integer, description: "For stage issue_plan: a wave number from `lain epic status`. Every " \
                                            "issue in the wave is asked about in one question."
        field :review, :string, description: "The review id epic_review returned for this gate, as in " \
                                             "review-0123456789ab; the human sees that review and whether it read " \
                                             "what is gated."

        validates :stage, inclusion: { in: STAGES, message: "must be one of #{STAGES.join(", ")}" }
        validates :issue, presence: true, if: -> { stage == "issue_plan" && wave.nil? }
        validates :wave, numericality: { only_integer: true, greater_than_or_equal_to: 1 }, allow_nil: true
        validates :review, allow_nil: true,
                           format: { with: Epic::ReviewResult::ID, message: "must be the review id epic_review returned" }
        validate :issue_or_wave

        private

        def issue_or_wave
          errors.add(:wave, "names an issue or a wave, not both") if wave && issue.present?
          errors.add(:wave, "is for stage issue_plan only") if wave && stage != "issue_plan"
        end
      end

      input_model Input

      # @param submitter [#submit] answers `submit(stage, slug, issue:, wave:, review:)` with
      #   the verdict as a {Tool::Result}, held when the human asked the agent
      #   to wait, as {CLI::EpicSubmit::InChat#submit} does
      # @param reviews [#call] answers the journal records an id is looked up in, read at call time
      def initialize(submitter:, reviews:)
        super()
        @submitter = submitter
        @reviews = reviews
      end

      def name = "epic_submit"

      def description
        "Submits an epic stage (research, epic_plan or issue_plan) to its approval gate and returns the verdict. " \
          "An interactive gate asks the human and waits; if nobody answers in the window, your turn ends and " \
          "the gate is held or denied. It is held: tell the user, and call epic_submit again only when they " \
          "ask. Denied: tell the user, and call epic_submit again to reopen it."
      end

      protected

      def perform(input, _invocation)
        @submitter.submit(input.stage, input.slug, issue: input.issue, wave: input.wave, review: review(input))
      rescue Epic::Gate::Policies::Refusal => e
        Tool::Result.error("#{unwirable(e)}; ask the user to run `#{shell_command(input)}` from a shell")
      rescue Lain::Error, SystemCallError => e
        Tool::Result.error(e.message)
      end

      private

      def review(input)
        return if input.review.nil?

        result = Epic::ReviewResult.find(@reviews.call, input.review)
        return result if [result.epic_slug, result.stage] == [input.slug, input.stage]

        raise Lain::Error, format(ELSEWHERE, id: result.id, stage: result.stage, slug: result.epic_slug,
                                             asked: input.stage, asked_slug: input.slug)
      end

      def unwirable(refusal)
        return "#{refusal.message}, which a chat cannot wire" unless refusal.policy == ADJUDICATED

        "the #{refusal.stage} gate is adjudicated, and a chat cannot build the adjudication spike prompt it needs"
      end

      def shell_command(input)
        Lain::Epic::Remedy.submit(input.stage, input.slug, issue: (input.issue if input.stage == "issue_plan"),
                                                           wave: input.wave)
      end
    end
  end
end
