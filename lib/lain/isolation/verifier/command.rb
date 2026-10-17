# frozen_string_literal: true

require "fileutils"
require "shellwords"

module Lain
  module Isolation
    module Verifier
      # The project's own suite, run in the candidate's checkout behind the
      # machine-wide suite lock: two suites at once give false reds.
      class Command
        TAIL = 40

        # @param argv [Array<String>] the suite's command, never a shell string
        # @param timeout [Integer] seconds before the run is killed and failed
        # @param lock [FileLock] held for the whole run
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(argv, timeout:, lock:, shell_out_factory:)
          @argv = argv
          @spelt = "`#{Shellwords.join(argv)}`"
          @timeout = timeout
          @lock = lock
          @shell_out_factory = shell_out_factory
        end

        # @param candidate [Candidate]
        # @return [LandingQueue::Verification] passed on exit 0, else failed
        #   with each output stream's tail
        def call(candidate)
          checkout = File.expand_path(candidate.path)
          return verification(candidate, :failed, "#{checkout} is not a directory") unless File.directory?(checkout)

          @lock.hold { attempted(candidate, checkout) }
        end

        private

        def attempted(candidate, checkout)
          within_own_tmp(checkout, candidate.sha) { |tmp| run(candidate, checkout, tmp) }
        rescue SystemCallError => e
          verification(candidate, :failed, "#{@spelt} could not run: #{e.message}")
        end

        # Under the checkout because a suite that hard-links or renames out of
        # TMPDIR cannot cross a device, and /tmp is often another one.
        def within_own_tmp(checkout, sha)
          dir = File.join(checkout, "tmp", "lain-verify-#{sha[0, 12]}")
          FileUtils.mkdir_p(dir)
          yield dir
        ensure
          FileUtils.rm_rf(dir)
        end

        def run(candidate, checkout, tmp)
          shell = @shell_out_factory.call(*@argv, cwd: checkout, environment: environment(tmp), timeout: @timeout)
          judged(candidate, shell)
        end

        def environment(tmp) = Exec.child_env(Worktree::GIT_CONTEXT_SCRUB.merge("TMPDIR" => tmp))

        def judged(candidate, shell)
          shell.run_command
          return verification(candidate, :passed) if shell.exitstatus&.zero?

          verification(candidate, :failed, "#{exit_of(shell)}#{tails(shell)}")
        rescue Shell::Out::Timeout => e
          verification(candidate, :failed, "#{e.message}#{tails(shell)}")
        end

        def exit_of(shell)
          shell.exitstatus.nil? ? "#{@spelt} was killed by a signal" : "#{@spelt} exited #{shell.exitstatus}"
        end

        # Apart, so a noisy stderr cannot push the suite's stdout summary out of the tail.
        def tails(shell)
          { "stdout" => shell.stdout, "stderr" => shell.stderr }
            .reject { |_, bytes| bytes.empty? }
            .map { |name, bytes| "\n#{name} (last #{TAIL} lines):\n#{tail(bytes)}" }.join
        end

        # The streams arrive as raw bytes; one invalid byte would make the detail unprintable.
        def tail(bytes) = Utf8.legible(bytes).lines.last(TAIL).join

        def verification(candidate, outcome, detail = "")
          LandingQueue::Verification.new(outcome:, tip: candidate.sha, detail:)
        end
      end
    end
  end
end
