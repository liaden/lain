# frozen_string_literal: true

module Lain
  module Bench
    class ApprovalReplay
      # The judge `auto` asks during a replay. It builds today's prompt with the real
      # {Approval::Judge}, so {Approval::Judged} digests what would be sent now, and answers with
      # the verdict the session's judge gave the same call. When the session's `prompt_digest`
      # differs from today's, the verdict was given to a different question: the answer still
      # replays, and the call is reported as drifted.
      class RecordedJudge
        # The role spawn behind the prompt builder: the replay reads a prompt and never sends one.
        module NoModel
          def self.never_parking = self

          def self.call(*) = raise(Error, "an approval replay asks no model")
        end

        VERDICTS = { "allow" => :approve, "deny" => :deny }.freeze

        # @return [String, nil] "replayed", "drifted" or "unrecorded" for a call the judge was
        #   asked about; nil when it was not asked
        attr_reader :state

        def initialize
          @prompter = Approval::Judge.new(role_spawn: NoModel)
          @call = nil
          @state = nil
        end

        # @param call [Call] the call being replayed
        # @return [Object] what the block returns
        def answering(call)
          @call = call
          @state = nil
          yield
        end

        def prompt(tool:, input:, place:) = @prompter.prompt(tool:, input:, place:)

        def call(prompt: nil, **)
          judged = @call&.judged
          return unrecorded unless judged&.key?("prompt_digest")

          @state = judged["prompt_digest"] == Canonical.digest(prompt) ? "replayed" : "drifted"
          verdict_of(judged)
        end

        private

        # Asked live by nobody whose answer the session kept, so it settles nothing.
        def unrecorded
          @state = "unrecorded"
          :defer
        end

        def verdict_of(judged)
          return :fault if judged["faulted"]

          VERDICTS.fetch(judged["verdict"], :defer)
        end
      end
    end
  end
end
