# frozen_string_literal: true

require "fileutils"
require "stringio"

module Lain
  module Exec
    # Runs a bash call under the {Confine::Profile} its ruling earns, the way
    # {Docker} composes {Local}: the inner exec still owns the deadline, the
    # group kill and the capture, and the launcher only prefixes each stage
    # after the inner exec's preflight has read the term as written.
    #
    # The inner exec must be a {Local}: it is the one that takes a launch,
    # an env laid over its scrub, and the trace descriptor.
    #
    # The call ends when its command does. A traced call's tracer runs in a
    # group of its own and stays attached to anything the command left
    # running until it exits, so the call reads each stage's trace until it
    # ends or its first process has exited, giving an exec still unfinished a
    # short grace to close, then stops reading. A reader call's processes live
    # in bwrap's pid namespace, which ends with the call, so its children end
    # with it.
    #
    # Only a refused exec is worded to the model. A write denial is not
    # traced, and tracing openat would bring the benign probes (cgroup files,
    # `/proc/stat`, thread names) back as noise.
    #
    # Each stage writes its own trace channel, because tracers sharing one
    # interleave their lines and lose execs. Signalling a tracer is never an
    # option: a seccomp-filtered trace kills its tracees when the tracer exits.
    #
    # Under `:traced` the record is an audit trail, not tamper-proof: a
    # process of the same user can write into the trace through
    # `/proc/<strace pid>/fd`. The reader profile is the tamper-resistant one,
    # since Landlock refuses that write.
    class Sandboxed
      TRACE_FD = 3
      TRACE_GRACE = 0.5
      REFUSED = "REFUSED by the sandbox, not a transient error: this call may not run %<path>s. Retrying, or " \
                "running the same effect another way, will be refused again. Stop and ask the human to approve " \
                "it, then wait for the answer."
      OVERMASKED = "REFUSED by the sandbox, not a transient error: the listed link %<names>s lands on %<path>s, " \
                   "which this call needs to run, so hiding it would leave the call nothing to run on. Retrying " \
                   "will be refused again. Stop and ask the human to remove or rename the link, then wait for the " \
                   "answer."
      NO_TMPDIR = "REFUSED by the sandbox, not a transient error: the TMPDIR %<path>s cannot hold this call's own " \
                  "dir, most often because it is gone. Retrying will be refused again. Stop and tell the human, " \
                  "then wait for the answer."
      DENIED_READ = "The %<profile>s sandbox limits reads to the project and its related directories. " \
                    "To see a masked file, use read_file."
      DENIED = /^(?:[^:\n]+: )+?(?:'([^']*)'|"([^"]*)"|([^:\n]+?)): Permission denied$/
      PATH_WITHHELD = "[path withheld]"
      WITHHELD = { path: PATH_WITHHELD, names: "[name withheld]" }.freeze
      UNSEALABLE = "REFUSED by the sandbox, not a transient error: %<link>s is a link inside the project, so the " \
                   "file it leads to could be repointed and run later. Retrying, or running the same effect another " \
                   "way, will be refused again. Stop and ask the human to replace the link with the file, or to " \
                   "restart with --confine reader, then wait for the answer."
      HOLDS_STATE = "REFUSED by the sandbox, not a transient error: the project root %<path>s holds lain's own " \
                    "state, where the lease records lain trusts live, so a write there could forge one. Retrying " \
                    "will be refused again. Stop and ask the human to run lain from the project itself, then wait " \
                    "for the answer."
      TAMPERED = "REFUSED by the sandbox, not a transient error: the git dir of the checkout %<path>s holds a name " \
                 "that redirects git, so lain runs nothing there. Retrying will be refused again. Stop and tell the " \
                 "human, then wait for the answer."
      HOME_TMPDIR = "REFUSED by the sandbox, not a transient error: the TMPDIR %<path>s is home or holds it, so a " \
                    "write there would reach home. Retrying will be refused again. Stop and ask the human to set " \
                    "TMPDIR elsewhere and restart, then wait for the answer."
      # Each profile build that refuses for a path, and the sentence that says why.
      UNBUILT = { Confine::Profiles::NoTmpdir => NO_TMPDIR, Confine::Profile::HomeTmpdir => HOME_TMPDIR,
                  Confine::Profile::HoldsState => HOLDS_STATE, Confine::Profile::Tampered => TAMPERED }.freeze

      # Bundler reads the user's config, which may hold gem-source credentials,
      # and the reader profile grants no home directory to find it in.
      CONFINED_ENV = { "BUNDLE_USER_CONFIG" => File::NULL }.freeze

      # @param inner [Local]
      # @param launcher [Confine::Launcher]
      # @param profiles [#for] chooses a {Confine::Profile} for a {Confine::Request}
      # @param journal [#<<] receives a {Telemetry::Sandbox} per call, a second one after a
      #   call that created a sealed path, and a {Telemetry::ExecRecord} per traced call
      # @param ceiling [Integer] the output ceiling a refusal is bound for, as {Local}'s is
      # @param reaps [Boolean] whether the fence can run an unconfined call as its reaper; when it
      #   cannot, such a call runs as written, untraced, since the fence would refuse it outright
      def initialize(inner:, launcher:, profiles:, journal:, ceiling: Tool::Bounds::CEILINGS.fetch("bash"),
                     reaps: true)
        @inner = inner
        @launcher = launcher
        @profiles = profiles
        @journal = journal
        @ceiling = ceiling
        @reaps = reaps
      end

      # @param term [Shell::Term]
      # @return [Boolean] the inner exec's answer, since it runs the term
      def takes_term?(term) = @inner.takes_term?(term)

      # @return [ChildEnv] the inner exec's, since its child is the one that runs
      def child_env = @inner.child_env

      # @param command [String, Shell::Term]
      # @param cwd [String]
      # @param env [Hash]
      # @param timeout [Numeric]
      # @param confinement [Confine::Request] how the call was approved and what it resolved to
      # @param sinks [Hash] the live sinks, handed to the inner exec
      # @return [Capture]
      # @raise [Timeout] when the deadline passed and the group was killed
      def call(command:, cwd:, env:, timeout:, confinement: Confine::Request::NONE, **sinks)
        begin
          profile = reaped(@profiles.for(confinement))
        rescue Confine::Profiles::Overmasked => e
          return overmasked(confinement, e, sinks)
        rescue Confine::Profile::Unsealable => e
          return unsealable(confinement, e, sinks)
        rescue *UNBUILT.keys => e
          return refused_before(confinement, e, phrased(unbuilt(e), path: printable(e.path)), sinks)
        end
        finishing(confinement, profile) { run_under(profile, confinement, command:, cwd:, env:, timeout:, **sinks) }
      end

      private

      # By kind, so a refusal subclassed later still gets its sentence.
      def unbuilt(error) = UNBUILT.find { |klass, _| error.is_a?(klass) }.last

      def run_under(profile, confinement, command:, cwd:, env:, timeout:, **sinks)
        refused = unrunnable(profile, confinement.executables)
        @journal << Telemetry::Sandbox.new(tool_use_id: confinement.tool_use_id, profile: profile.name,
                                           trace: profile.trace, refused:, granted: granted(profile, confinement))
        return refuse(confinement, profile, refused.first, sinks) if refused.any?

        run = { command:, cwd:, env:, timeout:, launch: launch(profile), pinned_env: pinned_env(profile), **sinks }
        profile.trace ? traced(confinement, profile, run, stages(command)) : @inner.call(**run)
      end

      def pinned_env(profile)
        return {} unless profile.confined?

        profile.call_tmpdir ? CONFINED_ENV.merge("TMPDIR" => profile.call_tmpdir) : CONFINED_ENV
      end

      def finishing(confinement, profile)
        leftovers = Leftovers.new(profile)
        ran = false
        yield.tap { ran = true }
      ensure
        journal_leftovers(confinement, profile, leftovers&.settle, in_flight: !ran)
      end

      def unreaped?(profile) = !profile.confined? && !@reaps

      def reaped(profile) = unreaped?(profile) ? Confine::Profile::NONE : profile

      def launch(profile)
        return Shell::Pipeline::AS_WRITTEN if unreaped?(profile)

        ->(term) { @launcher.wrap(term, profile, trace_fd: TRACE_FD) }
      end

      def stages(command) = command.is_a?(String) ? 1 : command.stages.size

      def journal_leftovers(confinement, profile, left, in_flight:)
        return if left.nil? || left.empty?

        @journal << Telemetry::Sandbox.new(tool_use_id: confinement.tool_use_id, profile: profile.name,
                                           trace: profile.trace, refused: [], **left)
      rescue StandardError
        raise unless in_flight
      end

      def traced(confinement, profile, run, stages)
        channels = Channels.new(stages, first_fd: TRACE_FD)
        begin
          capture = @inner.call(**run, fds: channels.writers)
        rescue Exception => e # rubocop:disable Lint/RescueException
          journal_trace(channels, confinement, profile, e)
          raise
        end
        record = journal_trace(channels, confinement, profile, nil)
        profile.confined? ? worded(capture, record, profile, run[:cwd]) : capture
      ensure
        channels&.close
      end

      # A failure reading the trace must not replace the call's own, a
      # {Timeout} above all, which the caller tells apart from every other error.
      def journal_trace(channels, confinement, profile, in_flight)
        channels.record(tool_use_id: confinement.tool_use_id, profile: profile.name).tap { @journal << _1 }
      rescue StandardError
        raise unless in_flight
      end

      # The tool refuses an over-ceiling result whole, so the line replaces the
      # output rather than being cut with it.
      def worded(capture, record, profile, cwd)
        line = notice(capture, record, profile, cwd)
        return capture if line.empty?
        return Capture.new(**capture.to_h, stderr: capture.stderr + line, size: capture.size + line.bytesize) if
          capture.size + line.bytesize <= @ceiling

        Capture::Bounded.new(ceiling: @ceiling).take(:stderr, line).finish(capture.exit_status)
      end

      def notice(capture, record, profile, cwd)
        line = refused_paths(record).map { "#{phrased(REFUSED, path: printable(_1))}\n" }.join
        return line unless line.empty? && denied_read?(capture, profile, cwd)

        "#{format(DENIED_READ, profile: profile.name)}\n"
      end

      def denied_read?(capture, profile, cwd)
        !capture.exit_status.zero? &&
          denied_paths(capture.stderr, cwd).any? { |path| profile.read_dirs.none? { Landing.under?(path, _1) } }
      end

      def denied_paths(stderr, cwd) = stderr.scan(DENIED).map { File.expand_path(_1.compact.first, cwd) }

      # A refused PATH entry lets the shell fall through to the next one, so only
      # a refusal with no later successful exec of the same basename counts.
      def refused_paths(record)
        record.refusals.map { _1[:path] }.uniq.reject { answered?(record.execs, _1) }
      end

      def answered?(execs, path)
        refused = execs.rindex { _1[:path] == path && !_1[:rc].zero? }
        refused && execs.drop(refused + 1).any? { _1[:rc].zero? && File.basename(_1[:path]) == File.basename(path) }
      end

      # A path is the command's to choose, and a newline in it would start a line of its own.
      def printable(path) = Utf8.legible(path).gsub(/[[:cntrl:]]/) { _1.inspect[1..-2] }

      def granted(profile, confinement)
        return [] unless profile.confined?

        confinement.grants.flat_map(&:programs).filter_map(&:realpath).uniq
                   .select { |path| profile.runs?(path) && !system_exec?(path) }
      end

      # What /usr holds runs under every confined profile, so no grant is what let it run.
      def system_exec?(path) = Confine::Profile::SYSTEM_EXEC.any? { path.start_with?("#{_1}/") }

      def unrunnable(profile, executables)
        return [] unless profile.confined?

        executables.flat_map(&:programs).filter_map(&:realpath).uniq.reject { profile.runs?(_1) }
      end

      def refuse(confinement, profile, path, sinks)
        if profile.trace
          @journal << Telemetry::ExecRecord.new(tool_use_id: confinement.tool_use_id, profile: profile.name,
                                                execs: [], refusals: [], fd_execs: [], truncated: false)
        end
        refusal(phrased(REFUSED, path:), sinks)
      end

      def overmasked(confinement, overmask, sinks)
        names = overmask.names.map { printable(_1) }.join(", ")
        refused_before(confinement, overmask, phrased(OVERMASKED, names:, path: printable(overmask.path)), sinks)
      end

      # Named from the root the model works in: a long absolute path reads as high-entropy to the output
      # detector, which would withhold the refusal instead of saying why.
      def unsealable(confinement, error, sinks)
        link = within(error.root || confinement.root, error.link)
        refused_before(confinement, error, format(UNSEALABLE, link: printable(link)), sinks, on: error.link)
      end

      def within(root, path)
        landed = root && Confine::Profile.landing(root)
        return path unless landed && path != landed && Landing.under?(path, landed)

        path.delete_prefix("#{landed.chomp(File::SEPARATOR)}#{File::SEPARATOR}")
      end

      # The result is scanned whole on its way to the model, and a path or a link's name can read as a
      # credential, which would withhold the sentence saying why the call failed. So such a value is left out,
      # each on its own first and then every one, and the sentence kept; the sandbox record still names it.
      def phrased(template, **values)
        lines = [values, values.to_h { |key, value| [key, token?(value) ? WITHHELD.fetch(key, value) : value] },
                 values.to_h { |key, value| [key, WITHHELD.fetch(key, value)] }].map { format(template, **_1) }
        lines.find { !token?(_1) } || lines.last
      end

      def token?(text) = Sensitivity::Regions.detect(text).any?

      # The profile refused the call before it was built, so the record names the path it refused on.
      def refused_before(confinement, error, line, sinks, on: error.path)
        @journal << Telemetry::Sandbox.new(tool_use_id: confinement.tool_use_id, profile: error.profile, trace: false,
                                           refused: [on])
        refusal(line, sinks)
      end

      def refusal(line, sinks)
        Capture::Bounded.new(ceiling: @ceiling, **sinks)
                        .take(:stderr, "#{Shell::Pipeline::PREFIX}#{line}\n")
                        .finish(Shell::Pipeline::NOT_PERMITTED)
      end

      # What a workspace call may leave behind. Each seal is looked at before
      # the call, so only a path that was not there and then was counts: a
      # dangling link that was already there is never one the call made. A path
      # created between {Confine::Profiles#for} and that look counts as there
      # before, by the call or anyone else. The
      # call's own TMPDIR is removed, opening up any directory the call left
      # unreadable, and named when even that fails.
      class Leftovers
        # @param profile [Confine::Profile]
        def initialize(profile)
          @profile = profile
          @absent = profile.sealed.map(&:path).reject { present?(_1) }
        end

        # @return [Hash] the post-call record's fields, empty when nothing was left
        def settle
          created = @absent.select { present?(_1) }
          kept = removed(@profile.call_tmpdir)
          { **(created.any? ? { created_sealed: created } : {}), **(kept ? { kept_tmpdir: kept } : {}) }
        end

        private

        def present?(path) = File.symlink?(path) || File.exist?(path)

        # @return [String, nil] the dir when it survived
        def removed(dir)
          return unless dir

          FileUtils.rm_rf(dir)
          return unless present?(dir)

          unlock(dir)
          FileUtils.rm_rf(dir)
          dir if present?(dir)
        end

        # chmod follows a link, so only what lstat calls a directory is opened, and a worklist keeps a deep tree
        # from overflowing the stack.
        def unlock(top)
          pending = [top]
          pending.concat(opened(pending.pop)) until pending.empty?
        end

        def opened(path)
          stat = File.lstat(path)
          return [] unless stat.directory?

          File.chmod(stat.mode | 0o700, path)
          Dir.children(path).map { File.join(path, _1) }
        rescue SystemCallError
          []
        end
      end
      private_constant :Leftovers

      # One trace pipe per stage, drained on a thread while the call runs,
      # because a full pipe stalls the tracer and the stage it traces.
      class Channels
        POLL = 0.05
        CHUNK = 64 * 1024
        HELD = Confine::Trace::CAP + 1

        # @param count [Integer] how many stages write a trace
        # @param first_fd [Integer] the descriptor the first stage writes to
        def initialize(count, first_fd:)
          @first_fd = first_fd
          @pipes = Array.new(count) { IO.pipe }
          @held = Array.new(count) { +"".b }
          @ended = Array.new(count, false)
          @lock = Mutex.new
          @stopped = false
          @pump = Thread.new { pump }
          @pump.report_on_exception = false
        end

        # @return [Hash{Integer => IO}] each stage's write end, at its descriptor
        def writers = @pipes.each_with_index.to_h { |(_, writer), index| [@first_fd + index, writer] }

        # Once the call is over: reads until every stage has settled or
        # {Sandboxed::TRACE_GRACE} has passed, then stops reading.
        #
        # @return [Telemetry::ExecRecord] every stage's execs, in stage order
        def record(tool_use_id:, profile:)
          writers.each_value(&:close)
          give_up = now + TRACE_GRACE
          sleep POLL until settled?(tool_use_id:, profile:) || now >= give_up
          stop
          merge(records(tool_use_id:, profile:), tool_use_id:, profile:)
        end

        # A failure of the pump has already reached the caller through
        # {#record}, or the call's own error is on its way out, so closing
        # never raises it again.
        #
        # @return [void]
        def close
          @stopped = true
          @pump.join
        rescue StandardError
          nil
        ensure
          @pipes.flatten.each { _1.close unless _1.closed? }
        end

        private

        def now = RunClock::MONOTONIC.call

        def stop
          @stopped = true
          @pump.value
        end

        def settled?(**) = records(**).zip(@ended).all? { |record, ended| ended || !record.incomplete }

        def records(**)
          @lock.synchronize { @held.map(&:dup).zip(@ended.dup) }.map do |text, ended|
            Confine::Trace.new(StringIO.new(text)).record(**, ended:)
          end
        end

        def merge(records, tool_use_id:, profile:)
          connects, dropped = Confine::Trace::Connects.fold(records.flat_map(&:connects),
                                                            dropped: records.sum(&:connects_dropped))
          Telemetry::ExecRecord.new(tool_use_id:, profile:, execs: records.flat_map(&:execs),
                                    refusals: records.flat_map(&:refusals), fd_execs: records.flat_map(&:fd_execs),
                                    connects:, connects_dropped: dropped, truncated: records.any?(&:truncated),
                                    incomplete: records.any?(&:incomplete))
        end

        def pump
          open = @pipes.map(&:first)
          open -= ready(open).select { drained?(_1) } until open.empty? || @stopped
        end

        def ready(open) = IO.select(open, nil, nil, POLL)&.first || []

        # @return [Boolean] whether the stage's pipe has ended
        def drained?(reader)
          chunk = reader.read_nonblock(CHUNK, exception: false)
          return false if chunk == :wait_readable

          index = @pipes.index { _1.first.equal?(reader) }
          @lock.synchronize { chunk.nil? ? @ended[index] = true : keep(index, chunk) }
          chunk.nil?
        end

        def keep(index, chunk)
          held = @held[index]
          held << chunk.byteslice(0, [HELD - held.bytesize, 0].max)
        end
      end
      private_constant :Channels
    end
  end
end
