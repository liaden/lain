# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tmpdir"

module Lain
  module Grader
    # Grade tests the arm WROTE by putting known bugs back into the source: each mutation patch is
    # applied in its own scratch copy beside the lease, the arm's new test files alone are run, and a
    # failing run means the tests noticed (killed). The lease the arm worked in stays byte-identical.
    #
    # It rides {LeaseHarness} for the lease binding and the seal, asked to let test files be ADDED
    # (those are the arm's work) while an edit to a pristine one, or any {LeaseHarness::ROOT_FILES}
    # change, still raises {LeaseHarness::Tampered}. Tests that fail on the unmutated code earn
    # nothing. Every run happens in a copy of the pristine base plus the arm's new test files, so the
    # arm's source edits can neither reach a mutant nor stop a patch applying. A patch that still does
    # not apply is broken fixture data: skipped in its own column, not killed, and the grade fails.
    #
    # A test that asserts the source's text, such as a digest of lib/tally.rb, kills every mutant. That is
    # a limit of mutation scoring; the pristine-source copy keeps it to the pristine text.
    class MutationReinsertion
      Mutation = Data.define(:name, :patch_path)

      # The pristine `.rspec` holds a `--pattern` this cannot read, so which new files are tests is unknown.
      class UnreadablePattern < Lain::Error; end

      # @param lease [#worker_env] the lease holding the arm's checkout; never released here
      # @param level [#name, #root] the level whose test directory the arm's tests are added to
      # @param mutations [Array<Mutation>] the bugs to put back, one patch each
      # @param base [String] the pristine tree the lease was copied from
      # @param harness [#call] `root -> #grade(worker_env, paths:)`, as {LeaseHarness} takes one
      def initialize(lease:, level:, mutations:, base:, harness: TestHarness.public_method(:new))
        @level = level
        @mutations = mutations.freeze
        pristine = LeaseHarness.manifest(base, level:)
        @seal = Canonical.digest(pristine)
        runs = Runs.new(harness:, level:, mutations:, pristine:, base:)
        @sealed = LeaseHarness.new(lease:, level:, harness: ->(_root) { runs }, pristine:, new_tests: true)
      end

      # @param _trajectory [Object] deliberately unread, as {LeaseHarness#grade} reads none
      # @return [Grade]
      # @raise [LeaseHarness::NoCheckout, LeaseHarness::Tampered]
      def grade(_trajectory = nil) = @sealed.grade

      # @return [Hash{String=>String}] deeply frozen
      def identity
        patches = @mutations.to_h { |mutation| [mutation.name, patch_digest(mutation.patch_path)] }
        { "class" => self.class.name, "level" => @level.name.to_s.freeze, "sealed" => @seal.dup.freeze,
          "mutations" => Canonical.digest(patches).freeze }.freeze
      end

      private

      def patch_digest(path)
        Digest::SHA256.file(path).hexdigest
      rescue SystemCallError
        "unreadable"
      end

      # The clean run, then one run per mutation, and their verdict, in the shape {LeaseHarness} hands a harness.
      class Runs
        # No GIT_DIR or index from a hook, no user or system config; `git apply` needs no repository.
        GIT_ENV = Isolation::Worktree::GIT_CONTEXT_SCRUB.merge("GIT_CONFIG_GLOBAL" => File::NULL,
                                                               "GIT_CONFIG_NOSYSTEM" => "1").freeze
        APPLY_TIMEOUT = 30
        DEFAULT_PATTERN = "**/*_spec.rb"
        PATTERN_FLAGS = %w[--pattern -P].freeze

        def initialize(harness:, level:, mutations:, pristine:, base:)
          @base = base
          @harness = harness
          @level = level
          @mutations = mutations
          @pristine = pristine
        end

        def grade(worker_env, paths: nil) # rubocop:disable Lint/UnusedMethodArgument
          @worker_env = worker_env
          @added = added(worker_env.cwd)
          tests = @added.select { |path| test_file?(path) }
          return refused("the agent wrote no tests") if tests.empty?
          return refused("the tests fail on correct code") unless run_in(nil, tests).pass?

          verdict(@mutations.group_by { |mutation| outcome(mutation, tests) })
        end

        private

        def refused(why) = Grade.new(score: 0.0, pass: false, why:)

        # Everything new under the top test directory, helpers and data included; a symlink is never copied.
        def added(cwd)
          (LeaseHarness.manifest(cwd, level: @level).keys - @pristine.keys)
            .select { |path| path.start_with?("#{tree}/") && !File.symlink?(File.join(cwd, path)) }
        end

        def tree = @level.root.split("/").first

        def test_file?(path)
          return false unless path.start_with?("#{@level.root}/")

          patterns.any? { |glob| File.fnmatch?(glob, path.delete_prefix("#{tree}/"), File::FNM_PATHNAME | File::FNM_EXTGLOB) }
        end

        # Read from the pristine base, which the arm cannot have edited; rspec's own `--pattern` rule.
        def patterns
          @patterns ||= begin
            words = Shellwords.split(File.read(File.join(@base, ".rspec")))
            given = words.each_cons(2).filter_map { |flag, value| value if PATTERN_FLAGS.include?(flag) } +
                    words.filter_map { |word| word[/\A--pattern=(.*)\z/, 1] }
            raise UnreadablePattern, "--pattern in #{@base}/.rspec names no value" if words.last == "--pattern"

            (given.last || DEFAULT_PATTERN).split(",")
          rescue ArgumentError => e
            raise UnreadablePattern, "--pattern in #{@base}/.rspec cannot be read: #{e.message}"
          rescue SystemCallError
            [DEFAULT_PATTERN]
          end
        end

        def outcome(mutation, tests)
          result = run_in(mutation, tests)
          return :skipped if result.nil?

          result.pass? ? :survived : :killed
        end

        # nil when the patch does not apply
        def run_in(mutation, tests)
          Dir.mktmpdir("lain-mutation-", File.dirname(@worker_env.cwd)) do |dir|
            FileUtils.cp_r(File.join(@base, "."), dir)
            copy_added(dir)
            if mutation.nil? || applied?(mutation, dir)
              @harness.call(dir).grade(WorkerEnv.new(cwd: dir, env: @worker_env.env), paths: tests)
            end
          end
        end

        def copy_added(dir)
          @added.each do |path|
            FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
            FileUtils.cp(File.join(@worker_env.cwd, path), File.join(dir, path))
          end
        end

        def applied?(mutation, dir)
          environment = GIT_ENV.merge("GIT_CEILING_DIRECTORIES" => File.dirname(dir))
          Shell::Out.ok?(Shell::Out.new("git", "apply", "--", mutation.patch_path, environment:, cwd: dir,
                                                                                   timeout: APPLY_TIMEOUT).run_command)
        end

        def verdict(by_outcome)
          killed, survived, skipped = %i[killed survived skipped].map { |key| by_outcome.fetch(key, []).map(&:name) }
          parts = ["#{killed.size} of #{@mutations.size} mutations killed"]
          parts << "survived: #{survived.join(", ")}" unless survived.empty?
          unless skipped.empty?
            parts << "skipped (broken fixture data, the patch does not fit the pristine source): #{skipped.join(", ")}"
          end
          Grade.new(score: killed.size.fdiv(@mutations.size), pass: survived.empty? && skipped.empty?,
                    why: parts.join("; "))
        end
      end
      private_constant :Runs
    end
  end
end
