# frozen_string_literal: true

module Lain
  module Telemetry
    # Every program a confined call started, as the kernel trace saw it. `execs` holds each
    # execve (path, argv0, rc), `refusals` those the sandbox answered EACCES or EPERM, and
    # `fd_execs` the execveat calls on a descriptor (path is empty for a bare fd, or relative
    # to it). `truncated` says the trace outgrew its cap, so the lists are a prefix and
    # absence proves nothing.
    #
    # A refusal can be shell PATH-search noise followed by a successful exec of the same
    # basename, so a consumer must look for that before it reads one as a blocked program.
    ExecRecord = Data.define(:tool_use_id, :profile, :execs, :refusals, :fd_execs, :truncated) do
      include Journalable

      def initialize(tool_use_id:, profile:, execs:, refusals:, fd_execs:, truncated:)
        super(tool_use_id: tool_use_id.dup.freeze, profile:, truncated:,
              execs: Ractor.make_shareable(execs), refusals: Ractor.make_shareable(refusals),
              fd_execs: Ractor.make_shareable(fd_execs))
      end
    end
  end
end
