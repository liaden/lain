# frozen_string_literal: true

module Lain
  module Telemetry
    # The profile a bash call ran under: `profile` is its name, `trace` whether
    # its execs were traced, and `refused` the resolved programs it was not
    # started for because the profile may not run them, or the granted path a
    # mask would have hidden. A call with a refusal ran nothing.
    Sandbox = Data.define(:tool_use_id, :profile, :trace, :refused) do
      include Journalable

      def initialize(tool_use_id:, profile:, trace:, refused:)
        super(tool_use_id: tool_use_id.dup.freeze, profile:, trace:, refused: Ractor.make_shareable(refused.dup))
      end
    end
  end
end
