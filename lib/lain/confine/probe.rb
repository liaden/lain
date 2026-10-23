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
      FenceReport = Data.define(:abi, :gap, :unstartable, :reaps)
      private_constant :FenceReport

      # @param fence [String] path to the lain-fence binary
      # @param runner [#call] takes an argv, returns [output, success]
      # @param ptrace_scope [#call] returns the yama file's text, or nil when the file is absent
      # @param journal [#<<] receives a Telemetry::CapabilityDegraded per missing layer
      def initialize(fence:, journal:, runner: method(:run), ptrace_scope: method(:read_ptrace_scope))
        @fence = fence
        @journal = journal
        @runner = runner
        @ptrace_scope = ptrace_scope
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

      # `:reap` is asked apart from the layers, because a fence that cannot reap still confines a reader.
      #
      # @param layer [Symbol] one of :bwrap, :landlock, :trace, :reap
      # @return [Boolean]
      def supports?(layer)
        layer == :reap ? reaps? : layers.fetch(layer)
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

      def verdicts
        { bwrap: bwrap_gap, landlock: fence_gap, trace: trace_gap }
      end

      def bwrap_gap
        _, ok = attempt(%w[bwrap --unshare-user --ro-bind / / true])
        "bwrap cannot unshare a user namespace" unless ok
      end

      def trace_gap
        _, ok = attempt(%w[strace -f -o /dev/null true])
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
      def fence_report
        @fence_report ||= begin
          out, ok = attempt([@fence, "--status"])
          report = ok ? parse(out) : {}
          level = report["abi"].is_a?(Integer) ? report["abi"] : 0
          FenceReport.new(abi: level, gap: gap_for(out, ok, level), unstartable: out.start_with?(START_FAILED),
                          reaps: report["reap"] == true)
        end
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
