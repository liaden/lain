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

      # @param lease [#worker_env] the lease still holding the checkout under
      #   test; never released here
      # @param level [#name, #root] the level root whose tests judge this work,
      #   as {TestLayout::Mapping#level} answers one
      # @param harness [#call] `root -> #grade(worker_env, paths:)`, a factory so
      #   a subject with no detectable framework can be graded by an explicit
      #   adapter
      def initialize(lease:, level:, harness: TestHarness.public_method(:new))
        @lease = lease
        @level = level
        @harness = harness
      end

      # @param _trajectory [Object] what the arm produced, deliberately unread
      # @return [Grade] the subject's own suite at this level root
      # @raise [NoCheckout] when the lease holds no checkout to run in
      # @raise [TestHarness::MissingPaths] when the level root is not in the
      #   checkout, named before anything spawns
      def grade(_trajectory = nil)
        worker_env = checked_out!
        @harness.call(worker_env.cwd).grade(worker_env, paths: [@level.root])
      end

      private

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
