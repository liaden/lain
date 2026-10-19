# frozen_string_literal: true

module Lain
  module Telemetry
    # The profile a bash call ran under: `profile` is its name, `trace` whether
    # its execs were traced, and `refused` the resolved programs it was not
    # started for because the profile may not run them. A call with a refusal
    # ran nothing. A bench run's copy also names the `arm` and the `task` it ran
    # for; a line from before that reads both as nil.
    Sandbox = Data.define(:tool_use_id, :profile, :trace, :refused, :arm, :task) do
      include Journalable

      def initialize(tool_use_id:, profile:, trace:, refused:, arm: nil, task: nil)
        super(tool_use_id: tool_use_id.dup.freeze, profile:, trace:, refused: Ractor.make_shareable(refused.dup),
              arm: arm&.dup&.freeze, task: task&.dup&.freeze)
      end
    end
  end
end
