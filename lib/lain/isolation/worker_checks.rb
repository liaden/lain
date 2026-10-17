# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tmpdir"

module Lain
  module Isolation
    # A worker's fast tier, run in its own checkout before its work is handed
    # back: the tests its change touched, then a lint over the files it changed.
    # The full suite is the merger's to run, once per batch; this tier is cheap
    # enough that every worker pays it.
    #
    # WHICH TESTS. The changed files that are tests, plus each changed source's
    # existing mirror test at every mirrored level. Only a layout in force can
    # say what mirrors what, so without one only the lint runs.
    #
    # THE WORKER FIXES ITS OWN RED. A worker that can run a shell is told the
    # command that failed and its last lines, and asked to fix and commit, up
    # to `retries` times. Each ask is measured by running the checks again,
    # never by what the worker said.
    #
    # NO StandardError ESCAPES, for the reason {SelfSync} gives: this runs
    # between a child's answer and its handback.
    class WorkerChecks
      ASK = <<~PROMPT
        The fast checks failed in your checkout %<dir>s. This command exited %<status>d:

          %<command>s

        Its last lines of output:

        %<output>s

        Fix the cause in that directory and commit the fix. Commit nothing else, and leave the tree
        clean. If you cannot fix it, say why.
      PROMPT

      # A failure's summary prints last, so the tail of the output is what
      # carries it; both caps keep one huge line from flooding the prompt.
      TAIL = 40
      TAIL_BYTES = 4096

      Result = Data.define(:outcome, :attempts, :detail)

      # What the fast tier made of one worker's checkout, carried onto the
      # record of the handback that follows it. `outcome` is one of:
      #
      # - `passed`: every check passed at lain's first run;
      # - `fixed`: a check failed, and passed after the worker was asked;
      # - `failed`: a check still failed when no ask remained;
      # - `skipped`: nothing configured, or nothing changed for it to run on;
      # - `dirty`: uncommitted work, so the checks would not measure the handback.
      #
      # `attempts` holds one entry per run of the checks, `{"by", "outcome",
      # "command"}`: whose work it measured, whether it `passed` or `failed`,
      # and the command that failed, empty once it passed.
      class Result
        OUTCOMES = %i[passed fixed failed skipped dirty].freeze

        def initialize(outcome:, attempts: [], detail: "")
          raise ArgumentError, "outcome must be one of #{OUTCOMES.inspect}, got #{outcome.inspect}" unless
            OUTCOMES.include?(outcome)

          super(outcome:, attempts: Ractor.make_shareable(attempts), detail: -detail.to_s)
        end

        # @return [Hash] the handback record's checks field
        def to_record = { checks: { outcome:, attempts:, detail: } }
      end

      NOTHING_CONFIGURED = "neither check nor lint is configured"
      NO_CHECKOUT = "the lease cut no checkout, so there is nothing to check"

      # @param base [#tip] the working branch the worker's changes are measured from
      # @param layout [TestLayout] says which tests mirror a changed source
      # @param check [Array<String>] the test command's argv; the tests are appended
      # @param lint [Array<String>] the lint command's argv; the changed files are appended
      # @param lint_files [Array<String>] globs a changed file must match to be
      #   linted; empty lints every changed file
      # @param retries [Integer] how many times a failing worker is asked to fix it
      # @param shell_out_factory [#call] builds the subprocess runner
      # @raise [ArgumentError] for a negative retries
      def initialize(base:, layout:, check:, lint:, lint_files:, retries:,
                     shell_out_factory: Shell::Out.public_method(:new))
        @base = base
        @commands = Commands.new(layout:, check:, lint:, lint_files:)
        @retries = Integer(retries)
        raise ArgumentError, "retries must be 0 or more, got #{@retries}" if @retries.negative?

        @shell_out_factory = shell_out_factory
      end

      # The sync duck's `worker_id:` names a ref to anchor under, and nothing
      # here writes one.
      #
      # @param lease [#origin] the worker's lease; its checkout is the one checked
      # @param worker [#askable?, #ask] from {SelfSync.worker}
      # @return [Result]
      def call(lease, worker:, **)
        path = lease.origin.path
        return Result.new(outcome: :skipped, detail: NOTHING_CONFIGURED) if @commands.none?
        return Result.new(outcome: :skipped, detail: NO_CHECKOUT) if path.nil?

        tree = Tree.new(path, base: @base, shell_out_factory: @shell_out_factory)
        Run.new(tree:, commands: @commands, worker:, retries: @retries).call
      end

      # The argv each check runs with, given the files a worker changed.
      class Commands
        # Globs cross directories only through `**/`, take `{a,b}`, and match
        # dot paths, as {TestLayout::Mapping#exempt?} does.
        GLOB = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

        def initialize(layout:, check:, lint:, lint_files:)
          @layout = layout
          @check = check
          @lint = lint
          @lint_files = lint_files
        end

        def none? = @check.empty? && @lint.empty?

        # @param changed [Array<String>] paths relative to the checkout
        # @param root [String] the checkout, where a mirror test must exist
        # @return [Array<Array<String>>] the tests first, so a red test is shown before a lint
        def for(changed, root:)
          tests = @check.empty? ? [] : tests(changed, root)
          linted = @lint.empty? ? [] : linted(changed)
          [(@check + tests unless tests.empty?), (@lint + linted unless linted.empty?)].compact
        end

        private

        def linted(changed)
          return changed if @lint_files.empty?

          changed.select { |path| @lint_files.any? { |glob| File.fnmatch?(glob, path, GLOB) } }
        end

        def tests(changed, root)
          return [] unless @layout.in_force?

          mapping = @layout.mapping
          existing = mirrors(mapping, changed).select { |test| File.file?(File.join(root, test)) }
          (changed.select { |path| mapping.test_file?(path) } + existing).uniq
        end

        def mirrors(mapping, changed)
          levels = mapping.levels.select(&:mirrored?)
          changed.select { |path| source?(path) }.product(levels).map do |source, level|
            mapping.test_path(source, level: level.name)
          end
        end

        # What {TestLayout::Mapping#test_path} can place: a file of the
        # layout's extension under one of its source roots.
        def source?(path)
          path.end_with?(@layout.preset.extension) &&
            @layout.source_roots.any? { |root| path.start_with?("#{root}/") }
        end
      end

      # One check that exited nonzero, and the tail of what it printed.
      Failure = Data.define(:argv, :status, :output) do
        def command = Shellwords.join(argv)
        def to_s = "#{command} exited #{status}:\n#{output}"
      end

      # One fast tier over one checkout: run, ask, run again.
      class Run
        def initialize(tree:, commands:, worker:, retries:)
          @tree = tree
          @commands = commands
          @worker = worker
          @retries = retries
          @attempts = []
          @answer = ""
        end

        def call
          measure(asks: @retries, by: "lain")
        rescue StandardError => e
          result(:failed, "#{e.class}: #{e.message}")
        end

        private

        def measure(asks:, by:)
          return result(:dirty, "the worker left uncommitted changes at #{@tree.dir}") if @tree.dirty?

          runs = @commands.for(@tree.changed, root: @tree.dir)
          return nothing_left(by) if runs.empty?

          judged(runs.lazy.filter_map { |argv| @tree.run(argv) }.first, asks:, by:)
        end

        # After an ask, nothing left to check means the fix removed what failed.
        def nothing_left(by) = by == "lain" ? result(:skipped, "no changed file to check") : result(:fixed)

        def judged(failure, asks:, by:)
          tried(by, failure)
          return result(by == "lain" ? :passed : :fixed) if failure.nil?
          return result(:failed, "#{failure}#{@answer}") if asks.zero? || !@worker.askable?

          ask(failure)
          measure(asks: asks - 1, by: "worker")
        end

        # An ask that raised fixed nothing, and the next run measures it so.
        def ask(failure)
          reply = @worker.ask(format(ASK, dir: @tree.dir, status: failure.status, command: failure.command,
                                          output: failure.output))
          @answer = "\nthe worker answered: #{WorkerHandoff::Reply.squeeze(reply.text.to_s)}"
        rescue StandardError => e
          @answer = "\nthe ask raised #{e.class}: #{e.message}"
        end

        def tried(by, failure)
          @attempts << { "by" => by, "outcome" => failure ? "failed" : "passed",
                         "command" => failure ? failure.command : "" }
        end

        def result(outcome, detail = "")
          swept = @tree.swept.empty? ? "" : "removed what the checks left untracked: #{@tree.swept.join(", ")}"
          Result.new(outcome:, attempts: @attempts, detail: [detail, swept].reject(&:empty?).join("\n"))
        end
      end

      # The worker's checkout, as the fast tier reads it and runs in it.
      class Tree
        # @return [Array<String>] the untracked files the checks made, now removed
        attr_reader :dir, :swept

        def initialize(dir, base:, shell_out_factory:)
          @dir = dir
          @base = base
          @shell_out_factory = shell_out_factory
          @git = Checkout.new(dir, shell_out_factory:)
          @swept = []
        end

        # Untracked files count: the checks would run on work the handback leaves behind.
        def dirty? = !@git.run!("status", "--porcelain", error: Error).stdout.empty?

        # Read per run, since a worker's fix may touch more files.
        def changed
          paths(@git.run!("diff", "--name-only", "-z", "--no-renames", "--diff-filter=d", "#{@base.tip}...HEAD",
                          error: Error).stdout)
        end

        # TMPDIR is the checkout's own, so concurrent workers' checks never
        # share scratch files. The tree was clean before the first run, so any
        # untracked file after one is the check's own artifact, removed so it
        # is neither blamed on the worker as dirt nor handed back; a tracked
        # file is never touched.
        #
        # @return [Failure, nil] nil when the command passed
        def run(argv)
          shell = Dir.mktmpdir("lain-checks-", @dir) do |scratch|
            spawn(*argv, environment: Exec.child_env(Worktree::GIT_CONTEXT_SCRUB.merge("TMPDIR" => scratch)))
          end
          sweep(untracked)
          Failure.new(argv:, status: shell.exitstatus, output: tail(shell)) unless Shell::Out.ok?(shell)
        end

        private

        def untracked
          paths(@git.run!("ls-files", "--others", "--exclude-standard", "-z", error: Error).stdout)
        end

        def paths(listed) = listed.split("\0").map { |path| path.force_encoding(FILESYSTEM) }

        def sweep(made)
          made.each { |path| FileUtils.rm_f(File.join(@dir, path)) }
          @swept |= made
        end

        # Output arrives as raw bytes; a byte cut mid-character is scrubbed.
        def tail(shell)
          text = (shell.stdout.b + shell.stderr.b).lines.last(TAIL).join
          text = "...#{text.byteslice(-TAIL_BYTES, TAIL_BYTES)}" if text.bytesize > TAIL_BYTES
          Utf8.legible(text)
        end

        def spawn(*argv, environment:)
          shell = @shell_out_factory.call(*argv, cwd: @dir, environment:)
          shell.run_command
          shell
        end
      end
    end
  end
end
