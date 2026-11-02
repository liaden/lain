# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # The names a skill template may read bare. Each value is a callable, so
      # it is resolved when a skill renders: a config refusal surfaces at that
      # render rather than at launch, and a width narrowed since is seen.
      class SkillLocals
        # @param root [String] the project root whose config sets the gate window
        # @param epic_home [#call] the epic home directory
        # @yieldreturn [OllamaTier] the chat's tier, asked at each render
        def initialize(root, epic_home, &tier)
          @root = root
          @epic_home = epic_home
          @tier = tier
        end

        # @return [Hash{Symbol=>#call}] ready for {Skill::Library.load}
        def to_h
          { epic_home: @epic_home, gate_window: method(:gate_window), provider_width: method(:provider_width),
            researcher_limits: method(:researcher_limits) }
        end

        private

        def gate_window = format("%g", Config.approval_timeout(root: @root))

        def provider_width = @tier.call.concurrency

        def researcher_limits
          "#{Config.budget(root: @root).iterations(role: :researcher)} iterations and a " \
            "#{Tools::Subagent::ANSWER_BOUND.limit}-byte answer"
        end
      end
    end
  end
end
