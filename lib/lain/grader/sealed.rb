# frozen_string_literal: true

module Lain
  module Grader
    # A grader that judges a lease's checkout against a seal taken once from the pristine base: the
    # lease binding, the {LeaseHarness::NoCheckout} refusal and the {LeaseHarness::Tampered} check ride
    # {LeaseHarness}, and a subclass supplies only its runs and what else its identity names.
    class Sealed
      # @param lease [#worker_env] the lease holding the arm's checkout; never released here
      # @param level [#name, #root] the level whose tests are sealed
      # @param base [String] the pristine tree the lease was copied from
      # @param harness [#call] `root -> #grade(worker_env, paths:)`, as {LeaseHarness} takes one
      # @param runs [#call] `(harness:, base:, level:, pristine:) -> #grade(worker_env, paths:)`
      # @param new_tests [Boolean] as {LeaseHarness} takes it
      def initialize(lease:, level:, base:, runs:, harness: TestHarness.public_method(:new), new_tests: false)
        @level = level
        @base = base
        pristine = LeaseHarness.manifest(base, level:)
        @seal = Canonical.digest(pristine)
        run = runs.call(harness:, base:, level:, pristine:)
        @sealed = LeaseHarness.new(lease:, level:, harness: ->(_root) { run }, sealed: @seal, pristine:, new_tests:)
      end

      # @param _trajectory [Object] deliberately unread, as {LeaseHarness#grade} reads none
      # @return [Grade]
      # @raise [LeaseHarness::NoCheckout, LeaseHarness::Tampered]
      def grade(_trajectory = nil) = @sealed.grade

      # @return [Hash{String=>String}] deeply frozen
      def identity
        { "class" => self.class.name, "level" => @level.name.to_s.freeze, "sealed" => @seal.dup.freeze,
          **extra_identity }.freeze
      end

      private

      # @return [Hash{String=>String}] frozen strings, merged after the shared keys
      def extra_identity = {}
    end
  end
end
