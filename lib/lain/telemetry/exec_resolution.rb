# frozen_string_literal: true

module Lain
  module Telemetry
    # What each stage of a bash call will run, written before it runs: the
    # program's resolved path, its class and what could have shadowed it. A
    # reader joins it to the call's {ShellArm} on `tool_use_id`.
    #
    # `stages` holds {Shell::Executable#to_journal} hashes, one per stage, so
    # the record carries no object a journal reader would have to rebuild.
    #
    # For a command the verdict did not allow, the stages are read off the
    # parse and each also carries `"basis" => "parsed"` and the `"cwd"` it
    # resolved in, nil where a stage may run somewhere else. They are a guess
    # at what the shell will run, never what the confinement was handed.
    # Builtins are left out, so a command made only of them, `cd sub`,
    # journals `stages: []`. A command the parse cannot read whole journals
    # the one unresolved entry named by the whole command.
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
