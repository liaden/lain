# frozen_string_literal: true

module Lain
  module Telemetry
    # Every program a confined call started, as the kernel trace saw it. `execs` holds each
    # execve (path, argv0, rc), `refusals` those the sandbox answered EACCES or EPERM, and
    # `fd_execs` the execveat calls on a descriptor (path is empty for a bare fd, or relative
    # to it). `truncated` says the trace outgrew its cap, and `incomplete` that an exec was
    # still unfinished, a line cut short, or a stage's first process not yet exited, when the
    # trace was read; either way the lists are a prefix and absence proves nothing.
    #
    # Each stage's execs start with the launcher's own: under `:traced` the `/bin/sh` that
    # closes the trace descriptors before it runs the command, under `:reader` lain-fence.
    #
    # Under the `:traced` profile this is an audit trail and not tamper-proof: any process of
    # the same user, the traced command included, can write lines into the trace through
    # `/proc/<strace pid>/fd`. Under `:reader` Landlock refuses that write.
    #
    # A refusal can be shell PATH-search noise followed by a successful exec of the same
    # basename, so a consumer must look for that before it reads one as a blocked program.
    ExecRecord = Data.define(:tool_use_id, :profile, :execs, :refusals, :fd_execs, :truncated, :incomplete) do
      include Journalable

      def initialize(tool_use_id:, profile:, execs:, refusals:, fd_execs:, truncated:, incomplete: false)
        super(tool_use_id: tool_use_id.dup.freeze, profile:, truncated:, incomplete:,
              execs: Ractor.make_shareable(execs), refusals: Ractor.make_shareable(refusals),
              fd_execs: Ractor.make_shareable(fd_execs))
      end
    end
  end
end
