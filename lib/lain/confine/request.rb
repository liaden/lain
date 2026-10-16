# frozen_string_literal: true

module Lain
  module Confine
    Request = Data.define(:ruling, :executables, :cwd, :root, :tool_use_id)

    # What a bash call hands its exec: how the call was approved, what each
    # stage resolved to, and the call it belongs to. {Profiles} reads the
    # ruling to choose a profile and {Exec::Sandboxed} checks the resolution
    # against it.
    class Request
      # @param ruling [Approval::Escalation::Ruling] the ruling that let the call run
      # @param executables [Array<Shell::Executable>] one per stage
      # @param cwd [String, nil]
      # @param root [String, nil] the project root the call runs in; nil leaves it to {Profiles}
      # @param tool_use_id [String] the call's id, which the sandbox's journal records carry
      def initialize(ruling:, executables:, cwd:, root:, tool_use_id:)
        super(ruling:, executables: Ractor.make_shareable(executables.dup), cwd: cwd && -cwd, root: root && -root,
              tool_use_id: -tool_use_id)
      end

      UNRULED = Approval::Escalation::Ruling.abstain(rung: Approval::Escalation::LADDER,
                                                     because: "no ruling reached this call")
      NONE = new(ruling: UNRULED, executables: [], cwd: nil, root: nil, tool_use_id: "")
    end
  end
end
