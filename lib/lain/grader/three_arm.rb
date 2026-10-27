# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tmpdir"

module Lain
  module Grader
    # Grade a fix by running the level's tests three times: at the pristine base, at the head the arm
    # left in the lease, and at the head with every non-test file put back to base. A real fix fails,
    # passes, fails. Each run happens in a scratch copy beside the lease, so the lease the arm worked
    # in stays byte-identical.
    #
    # It rides {LeaseHarness} for the lease binding, the {LeaseHarness::NoCheckout} refusal and the
    # seal, so a head whose test files differ from base raises {LeaseHarness::Tampered} before any run.
    # "Test file" is that seal's scope, which is also why the revert can never touch one. With the seal
    # in place the third run is chiefly a determinism and leakage check: the reverted tree is base again.
    class ThreeArm
      # @param lease [#worker_env] the lease holding the arm's checkout; never released here
      # @param level [#name, #root] the level whose tests judge the work
      # @param base [String] the pristine tree the lease was copied from
      # @param harness [#call] `root -> #grade(worker_env, paths:)`, as {LeaseHarness} takes one
      def initialize(lease:, level:, base:, harness: TestHarness.public_method(:new))
        @level = level
        @base = base
        pristine = LeaseHarness.manifest(base, level:)
        @seal = Canonical.digest(pristine)
        runs = Runs.new(harness:, base:, level:)
        @sealed = LeaseHarness.new(lease:, level:, harness: ->(_root) { runs }, pristine:)
      end

      # @param _trajectory [Object] deliberately unread, as {LeaseHarness#grade} reads none
      # @return [Grade]
      # @raise [LeaseHarness::NoCheckout, LeaseHarness::Tampered]
      def grade(_trajectory = nil) = @sealed.grade

      # @return [Hash{String=>String}] deeply frozen
      def identity
        { "class" => self.class.name, "level" => @level.name.to_s.freeze, "sealed" => @seal.dup.freeze,
          "base" => Canonical.digest(tree(@base)).freeze }.freeze
      end

      private

      def tree(root)
        Runs.files(root).to_h { |path| [path, digest(File.join(root, path))] }
      end

      def digest(full)
        Digest::SHA256.file(full).hexdigest
      rescue SystemCallError
        "unreadable"
      end

      # The three runs and their verdict, in the shape {LeaseHarness} hands a harness.
      class Runs
        def self.files(root)
          Dir.glob("**/*", File::FNM_DOTMATCH, base: root).select { |path| File.file?(File.join(root, path)) }
        end

        def initialize(harness:, base:, level:)
          @harness = harness
          @base = base
          @level = level
        end

        def grade(worker_env, paths:)
          @worker_env = worker_env
          @paths = paths
          base = run_in(@base)
          return refused("the test passes without the change") if base.pass?

          head = run_in(worker_env.cwd)
          return refused("the change does not make the test pass: #{head.why}") unless head.pass?

          revert = run_in(worker_env.cwd, reverted: true)
          return refused("reverting the change does not bring the failure back") if revert.pass?

          Grade.new(score: head.score, pass: true,
                    why: "base failed (#{base.why}); head passed (#{head.why}); revert failed (#{revert.why})")
        end

        private

        def refused(why) = Grade.new(score: 0.0, pass: false, why:)

        def run_in(source, reverted: false)
          Dir.mktmpdir("lain-three-arm-", File.dirname(@worker_env.cwd)) do |dir|
            FileUtils.cp_r(File.join(source, "."), dir)
            restore_source(dir) if reverted
            @harness.call(dir).grade(WorkerEnv.new(cwd: dir, env: @worker_env.env), paths: @paths)
          end
        end

        def restore_source(dir)
          (source_entries(dir) - ancestors).each { |path| FileUtils.rm_rf(File.join(dir, path)) }
          source_entries(@base).each { |path| copy_from_base(path, dir) }
        end

        # Everything but the sealed paths, symlinks and directories included: what the arm may have changed.
        def source_entries(root)
          Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |path| sealed.include?(path) || File.basename(path) == "." }
        end

        def sealed = @sealed ||= LeaseHarness.sealed_paths(@base, @level)

        # A directory holding a sealed path stays, or the revert would delete the tests with it.
        def ancestors = @ancestors ||= sealed.flat_map { |path| Pathname(path).descend.map(&:to_s) }.uniq

        def copy_from_base(path, dir)
          source = File.join(@base, path)
          return FileUtils.mkdir_p(File.join(dir, path)) if File.directory?(source) && !File.symlink?(source)

          FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
          FileUtils.cp_r(source, File.join(dir, path), remove_destination: true, dereference_root: false)
        end
      end
      private_constant :Runs
    end
  end
end
