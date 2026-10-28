# frozen_string_literal: true

module Lain
  module Confine
    Request = Data.define(:ruling, :executables, :argv, :cwd, :root, :tool_use_id, :grants)

    # What a bash call hands its exec: how the call was approved, what each
    # stage resolved to and the words it runs, and the call it belongs to.
    # {Profiles} reads the ruling to choose a profile, and the words to tell a
    # build tool's fetch from its other subcommands; {Exec::Sandboxed} checks
    # the resolution against the profile.
    class Request
      # @param ruling [Approval::Escalation::Ruling] the ruling that let the call run
      # @param executables [Array<Shell::Executable>] one per stage
      # @param argv [Array<Array<String>>] one per stage; none on the string arm, where a shell decides what runs
      # @param cwd [String, nil]
      # @param root [String, nil] the project root the call runs in; nil leaves it to {Profiles}
      # @param tool_use_id [String] the call's id, which the sandbox's journal records carry
      # @param grants [Array<Shell::Executable>] what the parsed stages resolved to on the string arm: programs the
      #   profile may run, never proof of what the shell will run, so nothing checks the call against them
      def initialize(ruling:, executables:, cwd:, root:, tool_use_id:, argv: [], grants: [])
        super(ruling:, executables: Ractor.make_shareable(executables.dup), argv: frozen(argv),
              cwd: cwd && -cwd, root: root && -root, tool_use_id: -tool_use_id,
              grants: Ractor.make_shareable(grants.dup))
      end

      # Frozen copies, so the words the caller holds stay as they were.
      def frozen(argv) = argv.map { |words| words.map(&:-@).freeze }.freeze
      private :frozen

      UNRULED = Approval::Escalation::Ruling.abstain(rung: Approval::Escalation::LADDER,
                                                     because: "no ruling reached this call")
      NONE = new(ruling: UNRULED, executables: [], cwd: nil, root: nil, tool_use_id: "")
    end
  end
end
