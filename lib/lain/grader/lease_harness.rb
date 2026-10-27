# frozen_string_literal: true

module Lain
  module Grader
    # Grade an arm's work the way the project it worked in would: by running
    # that project's OWN suite, in the checkout the lease is still holding,
    # narrowed to the one level root the work was for.
    #
    # It answers the arm grader duck, `grade(trajectory) -> Grade`, and reads
    # nothing off the trajectory it is handed. What the arm WROTE is the claim,
    # and the subject's tests are what judge it; a transcript cannot say whether
    # the work runs.
    #
    # BOUND TO A LEASE, NOT TO A PATH, which is the whole of its care. Releasing
    # a worktree removes the directory, so a grader holding a bare path can be
    # asked to grade a checkout that is already gone -- and the runner's own "no
    # such file" lands in the report as an arm whose work FAILED, which is the
    # one reading a bench must never invent. This grades while the lease stands
    # and releases nothing itself: the lifecycle belongs to {Arm#leased}, the one
    # bracket that may end it.
    class LeaseHarness
      # Asked to fold no issue at all. Loud rather than a zero, for the reason
      # {Bench::CLI}'s suite grader refuses a timeline naming no task: a zero
      # reads as an arm that failed everything it was given, where the truth is
      # that it was given nothing.
      class NothingGraded < Lain::Error; end

      # The lease holds no checkout to run a suite in. {Arm::NoIsolation}'s
      # lease is exactly that -- its `worker_env` is nil by design, the honest
      # "this run leased nothing" -- and it is what an arm gets when no
      # isolation was injected. Refused by name rather than left to become a
      # `NoMethodError` on nil three frames from the fact.
      class NoCheckout < Lain::Error; end

      # The arm rewrote the tests that judge it. The run is invalid, not low:
      # a score earned against edited tests says nothing about the source.
      class Tampered < Lain::Error
        # @return [Array<String>] changed test paths, relative to the project root; empty when
        #   the harness was sealed by a bare digest and cannot say which
        attr_reader :paths

        def initialize(paths, level:)
          @paths = paths.freeze
          named = paths.empty? ? "(the sealed digest cannot say which)" : paths.join(", ")
          super("the #{level.name.inspect} level's test tree changed since it was sealed: #{named}")
        end
      end

      # An arm that settles issue by issue holds one Grade per issue, and the
      # {Arm::Run} it hands back carries ONE. This is that fold, and it is pure.
      #
      # The mean is the honest summary: each issue's own grade is already a
      # passing FRACTION of its level root, so averaging them weights every
      # issue equally however many examples each carries. Passing is the
      # stricter question and stays unanimous -- an epic with one red issue did
      # not pass.
      #
      # @param by_issue [Hash{String=>Grade}] each issue's own verdict
      # @return [Grade] one verdict over them all, naming every issue
      # @raise [NothingGraded] when there is nothing to fold
      def self.rolled_up(by_issue)
        raise NothingGraded, ROLLED_UP_NOTHING if by_issue.empty?

        grades = by_issue.values
        Grade.new(score: grades.sum(&:score) / grades.size, pass: grades.all?(&:pass?),
                  why: by_issue.map { |issue_id, grade| "#{issue_id}: #{grade.why}" }.join("; "))
      end

      ROLLED_UP_NOTHING = "no issue was graded, so there is nothing to fold -- an arm that graded nothing is " \
                          "an unrun arm, not one that failed every issue it was given"
      private_constant :ROLLED_UP_NOTHING

      # Files at a project root that decide which tests run and how, so editing one is editing the tests.
      ROOT_FILES = [".rspec", "Gemfile", "Gemfile.lock", "Rakefile", ProjectDir.config,
                    "Cargo.toml", "Cargo.lock", "package.json"].freeze

      # Every file the arm could change to change what the level's tests do: the level root, the whole top
      # test directory it lives under (helpers and support code), and the {ROOT_FILES} that are present.
      #
      # A file's entry is its owner permission bits and content, so a chmod shows. A file that cannot be read
      # gets a fixed entry rather than an error, which differs from any readable pristine one and so is named
      # as tampered. A symlink with the same content as a regular file, and an empty directory, are not
      # told apart: the suite reads content at grade time, so neither changes what it runs.
      #
      # @param root [String] a project checkout
      # @param level [#root] the level whose test tree is listed
      # @return [Hash{String=>String}] entry of every sealed file, by path relative to the project root
      def self.manifest(root, level:)
        sealed_paths(root, level).sort.each_with_object({}) do |path, files|
          full = File.join(root, path)
          files[path] = entry(full) if File.file?(full)
        end
      end

      def self.sealed_paths(root, level)
        tree = level.root.split("/").first
        tests = Dir.glob("#{tree}/**/*", File::FNM_DOTMATCH, base: root)
        (tests + ROOT_FILES).uniq
      end
      private_class_method :sealed_paths

      def self.entry(full)
        "#{File.stat(full).mode & 0o700}:#{Digest::SHA256.file(full).hexdigest}"
      rescue SystemCallError
        "unreadable"
      end
      private_class_method :entry

      # @return [String] digest of {.manifest}
      def self.seal(root, level:) = Canonical.digest(manifest(root, level:))

      # @param lease [#worker_env] the lease still holding the checkout under
      #   test; never released here
      # @param level [#name, #root] the level root whose tests judge this work,
      #   as {TestLayout::Mapping#level} answers one
      # @param harness [#call] `root -> #grade(worker_env, paths:)`, a factory so
      #   a subject with no detectable framework can be graded by an explicit
      #   adapter
      # @param sealed [String, nil] {.seal} of the pristine subject; nil leaves the tests unchecked
      # @param pristine [Hash, nil] {.manifest} of the pristine subject, which names the changed paths
      #   and stands in for `sealed` when that is omitted
      def initialize(lease:, level:, harness: TestHarness.public_method(:new), sealed: nil, pristine: nil)
        @lease = lease
        @level = level
        @harness = harness
        @pristine = pristine
        @sealed = sealed || (Canonical.digest(pristine) if pristine)
      end

      # @param _trajectory [Object] what the arm produced, deliberately unread
      # @return [Grade] the subject's own suite at this level root
      # @raise [NoCheckout] when the lease holds no checkout to run in
      # @raise [Tampered] when the level's test tree no longer matches its seal
      # @raise [TestHarness::MissingPaths] when the level root is not in the
      #   checkout, named before anything spawns
      def grade(_trajectory = nil)
        worker_env = checked_out!
        unsealed!(worker_env)
        @harness.call(worker_env.cwd).grade(worker_env, paths: [@level.root])
      end

      # @return [Hash{String=>Object}] deeply frozen
      def identity
        base = { "class" => self.class.name, "level" => @level.name.to_s.freeze }
        (@sealed ? base.merge("sealed" => @sealed.dup.freeze) : base).freeze
      end

      private

      def unsealed!(worker_env)
        return if @sealed.nil?

        current = self.class.manifest(worker_env.cwd, level: @level)
        return if Canonical.digest(current) == @sealed

        raise Tampered.new(changed(current), level: @level)
      end

      def changed(current)
        return [] if @pristine.nil?

        (@pristine.keys | current.keys).reject { |path| @pristine[path] == current[path] }.sort
      end

      # Checked before a harness is built, let alone a runner spawned: what is
      # missing is the LEASE, and detecting a framework in a directory that was
      # never leased would refuse in the wrong vocabulary.
      def checked_out!
        worker_env = @lease.worker_env
        return worker_env unless worker_env.nil?

        raise NoCheckout, "this grader's lease holds no checkout, so the #{@level.name.inspect} level's tests " \
                          "have nowhere to run -- an arm graded by the subject's own suite has to be leased a " \
                          "real one, and Arm::NoIsolation leases nothing at all"
      end
    end
  end
end
