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
    # Each stage's execs start with the launcher's own, lain-fence: under `:traced` as a reaper
    # that closes the trace descriptors before it spawns the command, under `:reader` confining.
    #
    # Under the `:traced` profile this is an audit trail and not tamper-proof: any process of
    # the same user, the traced command included, can write lines into the trace through
    # `/proc/<strace pid>/fd`. Under `:reader` Landlock refuses that write.
    #
    # `connects` holds each connect, and each sendto, sendmsg or sendmmsg that names an address, over
    # AF_INET, AF_INET6 and AF_UNIX only, as {call:, family:, address:, port:, rc:, errno:, count:}.
    # Identical entries fold into one whose `count` says how many calls it stands for; the first 256
    # distinct entries are kept and `connects_dropped` counts the distinct ones past that. A send on
    # a connected socket names no address and is absent. A sendmmsg is recorded by its first
    # message's address only. A Unix socket's address is its path (abstract ones lead with "@") and
    # its port nil. An rc of -1 with errno EINPROGRESS is a non-blocking connect in flight, its
    # outcome unknown: it can still succeed.
    #
    # A refusal can be shell PATH-search noise followed by a successful exec of the same
    # basename, so a consumer must look for that before it reads one as a blocked program.
    ExecRecord = Data.define(:tool_use_id, :profile, :execs, :refusals, :fd_execs, :truncated, :incomplete,
                             :connects, :connects_dropped) do
      include Journalable

      def initialize(tool_use_id:, profile:, execs:, refusals:, fd_execs:, truncated:, incomplete: false,
                     connects: [], connects_dropped: 0)
        super(tool_use_id: tool_use_id.dup.freeze, profile:, truncated:, incomplete:,
              execs: Ractor.make_shareable(execs), refusals: Ractor.make_shareable(refusals),
              fd_execs: Ractor.make_shareable(fd_execs), connects: Ractor.make_shareable(connects), connects_dropped:)
      end
    end
  end
end
