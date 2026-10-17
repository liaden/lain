# frozen_string_literal: true

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

      # Bundler reads the user's config, which may hold gem-source credentials,
      # and the reader profile grants no home directory to find it in.
      CONFINED_ENV = { "BUNDLE_USER_CONFIG" => File::NULL }.freeze

      # @param inner [Local]
      # @param launcher [Confine::Launcher]
      # @param profiles [#for] chooses a {Confine::Profile} for a {Confine::Request}
      # @param journal [#<<] receives a {Telemetry::Sandbox} per call and a
      #   {Telemetry::ExecRecord} per traced call
      # @param ceiling [Integer] the output ceiling a refusal is bound for, as {Local}'s is
      def initialize(inner:, launcher:, profiles:, journal:, ceiling: Tool::Bounds::CEILINGS.fetch("bash"))
        @inner = inner
        @launcher = launcher
        @profiles = profiles
        @journal = journal
        @ceiling = ceiling
      end

      # @param term [Shell::Term]
      # @return [Boolean] the inner exec's answer, since it runs the term
      def takes_term?(term) = @inner.takes_term?(term)

      # @param command [String, Shell::Term]
      # @param cwd [String]
      # @param env [Hash]
      # @param timeout [Numeric]
      # @param confinement [Confine::Request] how the call was approved and what it resolved to
      # @param sinks [Hash] the live sinks, handed to the inner exec
      # @return [Capture]
      # @raise [Timeout] when the deadline passed and the group was killed
      def call(command:, cwd:, env:, timeout:, confinement: Confine::Request::NONE, **sinks)
        profile = @profiles.for(confinement)
        refused = unrunnable(profile, confinement.executables)
        @journal << Telemetry::Sandbox.new(tool_use_id: confinement.tool_use_id, profile: profile.name,
                                           trace: profile.trace, refused:)
        return refuse(confinement, profile, refused.first, sinks) if refused.any?

        run = { command:, cwd:, env:, timeout:, launch: launch(profile),
                pinned_env: profile.confined? ? CONFINED_ENV : {}, **sinks }
        profile.trace ? traced(confinement, profile, run, stages(command)) : @inner.call(**run)
      end

      private

      def launch(profile) = ->(term) { @launcher.wrap(term, profile, trace_fd: TRACE_FD) }

      def stages(command) = command.is_a?(String) ? 1 : command.stages.size

      def traced(confinement, profile, run, stages)
        channels = Channels.new(stages, first_fd: TRACE_FD)
        begin
          capture = @inner.call(**run, fds: channels.writers)
        rescue Exception => e # rubocop:disable Lint/RescueException
          journal_trace(channels, confinement, profile, e)
          raise
        end
        record = journal_trace(channels, confinement, profile, nil)
        profile.confined? ? worded(capture, record) : capture
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
      def worded(capture, record)
        line = refused_paths(record).map { "#{format(REFUSED, path: printable(_1))}\n" }.join
        return capture if line.empty?
        return Capture.new(**capture.to_h, stderr: capture.stderr + line, size: capture.size + line.bytesize) if
          capture.size + line.bytesize <= @ceiling

        Capture::Bounded.new(ceiling: @ceiling).take(:stderr, line).finish(capture.exit_status)
      end

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

      def unrunnable(profile, executables)
        return [] unless profile.confined?

        executables.flat_map(&:programs).filter_map(&:realpath).uniq.reject { profile.runs?(_1) }
      end

      def refuse(confinement, profile, path, sinks)
        if profile.trace
          @journal << Telemetry::ExecRecord.new(tool_use_id: confinement.tool_use_id, profile: profile.name,
                                                execs: [], refusals: [], fd_execs: [], truncated: false)
        end
        Capture::Bounded.new(ceiling: @ceiling, **sinks)
                        .take(:stderr, "#{Shell::Pipeline::PREFIX}#{format(REFUSED, path:)}\n")
                        .finish(Shell::Pipeline::NOT_PERMITTED)
      end

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
          Telemetry::ExecRecord.new(tool_use_id:, profile:, execs: records.flat_map(&:execs),
                                    refusals: records.flat_map(&:refusals), fd_execs: records.flat_map(&:fd_execs),
                                    truncated: records.any?(&:truncated), incomplete: records.any?(&:incomplete))
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
