# frozen_string_literal: true

require "tmpdir"
require "mixlib/shellout"

require_relative "test_harness/adapter"

module Lain
  module Grader
    # Grade a project by running its OWN test suite -- the deterministic grader
    # for a code-writing arm, where "how good was this?" is answered by the
    # subject's tests, not a rubric. `#grade` shells the suite out under the
    # subject's WorkerEnv (cwd = the checkout under test), reads the framework's
    # machine-readable result FILE, and folds the pass/fail counts into a {Grade}:
    # score is the passing fraction, it passes only when nothing failed or
    # errored, and `#why` names the failing cases.
    #
    # Two hazards this class is built around. First, the result is read from a
    # file (never stdout), so a child project's deprecation noise cannot corrupt
    # the parse. Second, the child must not inherit the HOST's framework context:
    # a Lain suite runs under `bundle exec`, whose BUNDLE_*/BUNDLER_*/RSPEC_* vars
    # and RUBYOPT would make the child resolve LAIN's Gemfile and config instead
    # of the subject's. Every such inherited var is scrubbed to nil (the
    # {WorkerEnv} explicit-nil delete semantics) -- an env-pollution bug class
    # that recurred repeatedly in the isolation chunk. GEM_* is kept: the child
    # needs it to find its test runner.
    #
    # LIMITATION worth stating honestly: because BUNDLE_GEMFILE is scrubbed, the
    # subject's tests run under the HOST's gem resolution, not the subject's own
    # Gemfile.lock -- a subject cannot opt back into its own bundle through this
    # harness. True per-subject dependency isolation belongs to an out-of-process
    # exec boundary, not to this env override.
    #
    # The framework is a duck ({Adapter}); detection is loud (no silent guess),
    # and an explicit `adapter:` always wins.
    class TestHarness
      # The child ran under the detected framework but reported zero examples --
      # a broken run, not a passing one, so it fails loud rather than dividing by
      # zero into a meaningless score.
      class EmptyRun < Lain::Error; end

      # The child ran past its bound. Wraps mixlib's {Mixlib::ShellOut::CommandTimeout}
      # in a Lain-taxonomy error naming the command and the limit, so a caller
      # catches one named type rather than a leaked dependency class.
      class Timeout < Lain::Error; end

      # A hung or runaway suite (an infinite loop in a test, a wedged child) must
      # not stall the bench that grades it, so the child is always bounded. 300s
      # is generous enough for a substantial real suite yet finite; a spec injects
      # a tiny value, and a slow real suite raises it deliberately at the call
      # site rather than inheriting mixlib's unadvertised 600s default.
      DEFAULT_TIMEOUT = 300

      # rspec reports a load crash (SyntaxError, a missing require) in the JSON
      # document's `messages`, not on stderr -- and the diagnostic LEADS, with the
      # backtrace trailing. So the errored `why` carries the HEAD of the error
      # text (where the error type and location live), not a tail that would drop
      # the very line that names the failure.
      ERROR_DETAIL_LINES = 12

      # Inherited env whose presence would bind the child to the HOST's bundler /
      # rspec context. Scrubbed to nil so it is DELETED in the child (not merely
      # overridden), leaving the subject's own env and PATH/GEM_* intact.
      FRAMEWORK_ENV = /\A(?:BUNDLE_|BUNDLER_|RSPEC_|RUBYOPT\z)/

      # @param root [String] the project directory whose framework is detected
      # @param adapter [#command,#parse, nil] an explicit adapter; nil auto-detects
      # @param timeout [Numeric] seconds the child suite may run before {Timeout}
      # @param shell_out_factory [#call] the subprocess runner, injected as a
      #   factory exactly as {Tools::Bash} and the isolation backends do
      def initialize(root, adapter: nil, timeout: DEFAULT_TIMEOUT,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @root = File.expand_path(root.to_s)
        @adapter = adapter || Adapter.detect(@root)
        @timeout = timeout
        @shell_out_factory = shell_out_factory
        freeze
      end

      # @param worker_env [#cwd,#env] where and under what env the suite runs
      # @return [Grade] score = passing fraction; passes iff nothing failed/errored
      def grade(worker_env)
        outcome = run(worker_env)
        to_grade(outcome.fetch(:result), outcome.fetch(:stderr))
      end

      private

      # The result file lives in a fresh tempdir, not the project, so grading
      # leaves the subject's tree untouched. Returns the parsed result plus the
      # child's stderr -- a runner that writes its crash there (rather than to the
      # result file) still gets surfaced in `#why`.
      def run(worker_env)
        Dir.mktmpdir("lain-test-harness") do |dir|
          out_path = File.join(dir, "result")
          argv = @adapter.command(out_path:)
          options = { cwd: worker_env.cwd, environment: environment(worker_env), timeout: @timeout }
          shell = @shell_out_factory.call(*argv, **options)
          capture(shell, argv)
          document = File.exist?(out_path) ? File.read(out_path) : ""
          { result: @adapter.parse(document, shell.exitstatus), stderr: shell.stderr }
        end
      end

      def capture(shell, argv)
        shell.run_command
      rescue Mixlib::ShellOut::CommandTimeout => e
        raise Timeout, "test command `#{argv.join(" ")}` exceeded the #{@timeout}s timeout: #{e.message}"
      end

      # mixlib INHERITS this process's ENV and overlays `environment:` per key, so
      # the scrub must name every framework var actually present to inherit --
      # hence the union of the live ENV and the subject's own env keys.
      def environment(worker_env)
        polluted = (ENV.keys + worker_env.env.keys).grep(FRAMEWORK_ENV).uniq
        worker_env.env.merge(polluted.to_h { |key| [key, nil] })
      end

      def to_grade(result, stderr)
        passed = result.fetch(:passed)
        failed = result.fetch(:failed)
        errors = result.fetch(:errors)
        total = passed.size + failed.size + errors.size
        raise EmptyRun, "the suite in #{@root} reported no examples -- nothing to grade" if total.zero?

        Grade.new(score: passed.size.fdiv(total), pass: failed.empty? && errors.empty?,
                  why: why(passed, failed, errors, total, stderr))
      end

      def why(passed, failed, errors, total, stderr)
        return "all #{total} examples passed" if failed.empty? && errors.empty?

        problems = failed.map { |name| "failed: #{name}" }
        problems += ["errored: #{error_detail(errors, stderr)}"] unless errors.empty?
        "#{passed.size}/#{total} examples passed; #{problems.join("; ")}"
      end

      # The real diagnostic, from wherever the runner put it (the parsed error
      # names, then the child's stderr), ANSI-stripped and bounded to the leading
      # lines so a full backtrace never floods the Grade.
      def error_detail(errors, stderr)
        text = (errors + [stderr.to_s]).join("\n").gsub(/\e\[[0-9;]*m/, "")
        text.lines.map(&:rstrip).reject(&:empty?).first(ERROR_DETAIL_LINES).join("\n")
      end
    end
  end
end
