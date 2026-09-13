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
    # file, never stdout, so a child project's deprecation noise cannot corrupt
    # the parse. Second, the child must not inherit the HOST's framework
    # context: a Lain suite runs under `bundle exec`, whose
    # BUNDLE_*/BUNDLER_*/RSPEC_* vars and RUBYOPT would make the child resolve
    # LAIN's Gemfile and config instead of the subject's. That scrub lives on
    # {Lain::Exec}, where every backend that spawns a child reads it.
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
      # The child ran past its bound. Wraps mixlib's own timeout in a
      # Lain-taxonomy error naming the command and the limit, so a caller
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

      # @param root [String] the project directory whose framework is detected
      # @param adapter [#command,#parse, nil] an explicit adapter; nil auto-detects
      # @param timeout [Numeric] seconds the child suite may run before {Timeout}
      # @param shell_out_factory [#call] the subprocess runner, injected as a
      #   factory as {Tools::Bash} and the isolation backends do
      def initialize(root, adapter: nil, timeout: DEFAULT_TIMEOUT,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @root = File.expand_path(root.to_s)
        @adapter = adapter || Adapter.detect(@root)
        @timeout = timeout
        @shell_out_factory = shell_out_factory
        freeze
      end

      # A path asked to run is not there. Refused before anything spawns:
      # rspec would take it for a file to load, and a LoadError graded as a
      # failing suite reads as broken work rather than a missing directory.
      class MissingPaths < Lain::Error; end

      # What one run reported: the example names in each state, and the
      # child's stderr for a runner that writes its crash there instead.
      Run = Data.define(:passed, :failed, :errors, :stderr) do
        def total = passed.size + failed.size + errors.size
        def clean? = failed.empty? && errors.empty?
      end

      # @param worker_env [#cwd,#env] where and under what env the suite runs
      # @param paths [Array<String>] see {#run}
      # @return [Grade] score = passing fraction; passes iff nothing failed/errored
      def grade(worker_env, paths: [])
        to_grade(run(worker_env, paths:))
      end

      # The result file lives in a fresh tempdir, not the project, so running
      # leaves the subject's tree untouched.
      #
      # @param worker_env [#cwd,#env] where and under what env the suite runs
      # @param paths [Array<String>] what to run, relative to the worker's cwd
      #   -- a level root, so a unit-level criterion runs the unit tests; empty
      #   runs the whole suite
      # @return [Run]
      # @raise [MissingPaths] naming each path absent from the worker's cwd
      def run(worker_env, paths: [])
        present!(worker_env.cwd, paths)
        Dir.mktmpdir("lain-test-harness") do |dir|
          out_path = File.join(dir, "result")
          argv = @adapter.command(out_path:, paths:)
          options = { cwd: worker_env.cwd, environment: Exec.child_env(worker_env.env), timeout: @timeout }
          shell = @shell_out_factory.call(*argv, **options)
          capture(shell, argv)
          outcome(out_path, shell)
        end
      end

      private

      def present!(cwd, paths)
        absent = paths.reject { |path| File.exist?(File.expand_path(path, cwd)) }
        raise MissingPaths, "#{absent.join(", ")} not found under #{cwd}; nothing was run" unless absent.empty?
      end

      def outcome(out_path, shell)
        document = File.exist?(out_path) ? File.read(out_path) : ""
        Run.new(**@adapter.parse(document, shell.exitstatus), stderr: shell.stderr)
      end

      def capture(shell, argv)
        shell.run_command
      rescue Mixlib::ShellOut::CommandTimeout => e
        raise Timeout, "test command `#{argv.join(" ")}` exceeded the #{@timeout}s timeout: #{e.message}"
      end

      def to_grade(run)
        # The child ran under the detected framework but reported zero examples --
        # a broken run, not a passing one, so it fails loud rather than dividing by
        # zero into a meaningless score.
        raise Error, "the suite in #{@root} reported no examples -- nothing to grade" if run.total.zero?

        Grade.new(score: run.passed.size.fdiv(run.total), pass: run.clean?, why: why(run))
      end

      def why(run)
        return "all #{run.total} examples passed" if run.clean?

        problems = run.failed.map { |name| "failed: #{name}" }
        problems += ["errored: #{error_detail(run.errors, run.stderr)}"] unless run.errors.empty?
        "#{run.passed.size}/#{run.total} examples passed; #{problems.join("; ")}"
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
