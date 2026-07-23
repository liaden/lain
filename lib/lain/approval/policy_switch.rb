# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/string/inflections"

module Lain
  module Approval
    # The delegating slot `/yolo` flips: {Effect::Handler::Gate}'s policy duck
    # (`#call(effect, context) -> Boolean`), answering through whichever policy
    # is current. Gate stays construction-fixed -- it holds this ONE object for
    # the session, and the flip swaps the delegate inside it, never a setter on
    # Gate. Deliberately MUTABLE coordination state, like {Approval::Queue::Pending}
    # and unlike the frozen value objects: it exists to be switched.
    #
    # Every flip lands in the Journal attributed to the surface that made it
    # ("who turned the gate off, and when" is evidence on a study bench, not
    # incident detail). The INITIAL policy is the wiring's choice, already
    # visible in the session's flags -- construction journals nothing.
    #
    # Like Queue's @parked, there is deliberately no lock: a flip is
    # straight-line Ruby with no yield point, and a fiber only interleaves at
    # an IO yield -- the command's write and the Gate's read can never tear.
    class PolicySwitch
      attr_reader :current

      # @param initial [#call] the wired starting policy ({Gate::ApproveAll}
      #   under --yolo, the {Approval::Queue} otherwise)
      # @param journal [#record] where each flip lands as evidence
      def initialize(initial, journal:)
        @current = initial
        @journal = journal
      end

      def call(effect, context) = @current.call(effect, context)

      # Swap the live policy, journaling the flip from/to (the same symmetry
      # model_switch records carry). Answers the policy now in force, so a
      # caller's confirmation text can name what it got.
      def switch(policy, surface:)
        from = policy_name(@current)
        @current = policy
        @journal.record({ "type" => "policy_switch", "from" => from,
                          "to" => policy_name(policy), "surface" => surface.to_s })
        policy
      end

      private

      # The same snake_case naming Telemetry::Journalable stamps its records
      # with, so journal readers grep one convention.
      def policy_name(policy) = policy.class.name.split("::").last.underscore
    end
  end
end
