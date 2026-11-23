# frozen_string_literal: true

require "json"
require "open3"

module Lain
  module Confine
    # Asks this kernel which sandbox layers work, once, and journals each one that does not. A layer
    # that cannot be shown to work reads as absent, never as granted.
    class Probe
      PTRACE_SCOPE = "/proc/sys/kernel/yama/ptrace_scope"
      START_FAILED = "\0start-failed:"
      # A bare `true` is looked up by bwrap and strace, which take an empty PATH entry as the cwd.
      NO_TRUE = "true is not on PATH"
      FenceReport = Data.define(:abi, :gap, :unstartable, :reaps, :private_net)
      private_constant :FenceReport

      # @param fence [String] path to the lain-fence binary
      # @param env [Hash] where PATH is read from
      # @param bwrap [Bwrap] the launcher a Sandbox on this box would build
      # @param runner [#call] takes an argv, returns [output, success]
      # @param ptrace_scope [#call] returns the yama file's text, or nil when the file is absent
      # @param journal [#<<] receives a Telemetry::CapabilityDegraded per missing layer
      def initialize(fence:, journal:, env: ENV, bwrap: Bwrap.on_path(fence:, env:), runner: method(:run),
                     ptrace_scope: method(:read_ptrace_scope))
        @fence = fence
        @bwrap = bwrap
        @true = Shell::Path.find("true", path: env.fetch("PATH", ""))
        @journal = journal
        @runner = runner
        @ptrace_scope = ptrace_scope
        @private_net_lock = Mutex.new
        @fence_report_lock = Mutex.new
      end

      # @return [Integer] the Landlock ABI the fence reported, 0 when none
      def abi
        fence_report.abi
      end

      # @return [String, nil] why the lain-fence binary gives no Landlock, nil when it does
      def fence_gap
        fence_report.gap
      end

      # @return [Boolean] whether the lain-fence binary could not be started at all
      def fence_unstartable?
        fence_report.unstartable
      end

      # `:reap` and `:private_net` are asked apart from the layers, because a fence lacking either still confines.
      #
      # @param layer [Symbol] one of :bwrap, :landlock, :trace, :reap, :private_net
      # @return [Boolean]
      def supports?(layer)
        case layer
        when :reap then reaps?
        when :private_net then private_net?
        else layers.fetch(layer)
        end
      end

      private

      # Memoized so the journal holds one record per missing layer however often it is asked.
      def layers
        @layers ||= verdicts.each_with_object({}) do |(layer, reason), found|
          found[layer] = reason.nil?
          degrade(layer, reason) if reason
        end.freeze
      end

      # An older fence rejects `--reap-only` and exits 125, so its status must say it reaps.
      def reaps?
        return @reaps unless @reaps.nil?

        @reaps = fence_report.reaps
        degrade(:reap, "#{@fence} cannot reap: rebuild it with bundle exec rake compile") unless @reaps
        @reaps
      end

      # A fence built before the flag rejects it and exits 125. Its status names the key whenever the build knows
      # the flag, false outside a private network, so the key's presence is the answer. bwrap must make the
      # namespace too, or every workspace call would abort.
      # Locked because a contained approval and the first workspace profile can ask at once, and a second
      # answer would spawn bwrap again and journal a second record.
      def private_net?
        @private_net_lock.synchronize do
          return @private_net unless @private_net.nil?

          reason = private_net_gap
          degrade(:private_net, reason) if reason
          @private_net = reason.nil?
        end
      end

      def private_net_gap
        return "#{@fence} cannot give a call a private network: rebuild it with bundle exec rake compile" unless
          fence_report.private_net

        namespace_gap(private_net: true, reason: "bwrap cannot build a private-network namespace")
      end

      # Each check spawns a process and waits on it, so the 3 run at once; the journal is written after the joins.
      def verdicts
        checks = { bwrap: :bwrap_gap, landlock: :fence_gap, trace: :trace_gap }
        checks.transform_values { |check| check_thread(check) }.transform_values(&:value)
      end

      # The error reaches the caller through the join, so the thread must not also print it.
      def check_thread(check)
        Thread.new { send(check) }.tap { _1.report_on_exception = false }
      end

      def bwrap_gap = namespace_gap(private_net: false, reason: "bwrap cannot build the reader namespace")

      # bwrap's first line names what the kernel refused, which the journal keeps beside the reason.
      def namespace_gap(private_net:, reason:)
        return "bwrap is not on PATH" unless @bwrap.bwrap
        return NO_TRUE unless @true

        out, ok = attempt([*@bwrap.namespace_argv(private_net:), @true])
        return if ok

        detail = out.delete_prefix(START_FAILED).lines.first.to_s.strip.delete_prefix("bwrap: ")
        detail.empty? ? reason : "#{reason}: #{detail}"
      end

      def trace_gap
        return "strace is not on PATH" unless @bwrap.strace
        return NO_TRUE unless @true

        _, ok = attempt([@bwrap.strace, "-f", "-o", "/dev/null", @true])
        return "strace cannot trace a child here" unless ok

        "ptrace_scope forbids tracing a child" unless ptrace_allowed?
      end

      def ptrace_allowed?
        text = @ptrace_scope.call
        return true if text.nil?

        scope = Integer(text.strip, exception: false)
        !scope.nil? && scope <= 1
      end

      # Memoized: the ABI, the gap reason or nil, and whether the binary failed to start.
      # Locked because the landlock check and a private-network ask can both want it first.
      def fence_report
        @fence_report_lock.synchronize { @fence_report ||= build_fence_report }
      end

      def build_fence_report
        out, ok = attempt([@fence, "--status"])
        report = ok ? parse(out) : {}
        level = report["abi"].is_a?(Integer) ? report["abi"] : 0
        FenceReport.new(abi: level, gap: gap_for(out, ok, level), unstartable: out.start_with?(START_FAILED),
                        reaps: report["reap"] == true, private_net: report.key?("private_net"))
      end

      def gap_for(out, started, level)
        return if level.positive?
        return "cannot start #{@fence}: #{out.delete_prefix(START_FAILED)}" if out.start_with?(START_FAILED)

        started ? "#{@fence} reports ABI 0" : "#{@fence} exited with failure"
      end

      def parse(text)
        report = JSON.parse(text)
        report.is_a?(Hash) ? report : {}
      rescue JSON::ParserError
        {}
      end

      def attempt(argv)
        @runner.call(argv)
      rescue SystemCallError => e
        ["#{START_FAILED}#{e.message}", false]
      end

      def degrade(layer, reason)
        @journal << Telemetry::CapabilityDegraded.new(capability: layer, requirer: self.class.name, provider: reason)
      end

      def run(argv)
        out, status = Open3.capture2e(*argv)
        [out, status.success?]
      end

      def read_ptrace_scope
        File.read(PTRACE_SCOPE)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError
        ""
      end
    end
  end
end
