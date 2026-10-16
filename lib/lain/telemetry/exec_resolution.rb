# frozen_string_literal: true

module Lain
  module Telemetry
    # What each stage of a bash call will run, written before it runs: the
    # program's resolved path, its class and what could have shadowed it. A
    # reader joins it to the call's {ShellArm} on `tool_use_id`.
    #
    # `stages` holds {Shell::Executable#to_journal} hashes, one per stage, so
    # the record carries no object a journal reader would have to rebuild.
    ExecResolution = Data.define(:tool_use_id, :stages) do
      include Journalable

      # @param tool_use_id [String] the `tool_use` block this call answers
      # @param stages [Array<Hash>] one {Shell::Executable#to_journal} per stage
      def initialize(tool_use_id:, stages:)
        super(tool_use_id: -tool_use_id.to_s, stages: Ractor.make_shareable(stages))
      end
    end
  end
end
