# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/string/inflections"
require "delegate"

module Lain
  module Approval
    # The delegating slot a mode flip writes: a {Middleware::Gate} policy,
    # ruling through whichever policy is current. Gate stays
    # construction-fixed -- it holds this ONE object for the session and the
    # flip swaps the delegate inside it, never a setter on Gate. Deliberately
    # MUTABLE coordination state: it exists to be switched.
    #
    # Every flip lands in the Journal attributed to the surface that made it --
    # "who turned the gate off, and when" is evidence on a study bench. The
    # INITIAL policy is the wiring's choice, already visible in the session's
    # flags, so construction journals nothing.
    #
    # Like Queue's @parked, deliberately NO LOCK: a flip is straight-line Ruby
    # with no yield point, so the command's write and the Gate's read can never
    # tear.
    class PolicySwitch
      # WHO a gated call is asked on behalf of, riding the `context` every
      # policy on this seam already threads unexamined.
      #
      # A RAIL and not a parameter, because the alternative is widening the
      # `rule(effect, context)` seam every gate policy implements -- each
      # forwarding an identity none of them reads, for the one that does.
      #
      # A DELEGATOR: it answers every message the wrapped `context` answers, so
      # a rung reading the run's {Session} still gets one. It is NOT `is_a?` the
      # wrapped class, and `case`/`===`/`==` do not see through it either -- a
      # rung must DUCK-TYPE on the context and never type-test it. A context
      # nobody wrapped names nobody, which is the parent's own turn.
      class Requested < SimpleDelegator
        # @return [Requester] who is asking, with the label and skill a surface shows
        attr_reader :identity

        # @return [String, nil] the task the asking child was spawned with, in its parent model's words
        attr_reader :task

        # @param context [Object] the context the policy seam already threads
        # @param requester [Requester, String] who is asking; anything but a bare word is refused here by
        #   {Requester}'s rule, at the one place it cannot be degraded away
        # @param task [String, nil] the task the asking child was spawned with
        def initialize(context, requester, task: nil)
          @identity = Requester.of(requester)
          super(context)
          @task = task && -task.to_s
        end

        # @return [String] the asking requester's name, the key a remembered denial is held under and the
        #   journal edge
        def requester = identity.name
      end

      attr_reader :current

      # @param initial [#rule, #call] the starting mode's resolved gate policy.
      #   NOT the bare {Approval::Queue}: the queue is the parked list the
      #   ladder's asking rung parks ON.
      # @param journal [#record] where each flip lands as evidence
      def initialize(initial, journal:)
        bind(initial)
        @journal = journal
      end

      def call(effect, context) = rule(effect, context).allow?

      # The ruling the current policy settles on, which is what the Gate asks.
      def rule(effect, context) = @ruling.rule(effect, context)

      # Answers the policy now in force, so a caller's confirmation text can
      # name what it got. Switching to the policy already in force writes
      # nothing: the gate did not change, and the record would say it had.
      # Identity, not equality -- a flip hands back the very ladder the board
      # built for that level.
      #
      # The durable record commits the flip, on {Mode::Switch}'s terms: a
      # refused record binds nothing, and a live view failing after it landed
      # is raised only once the policy is bound.
      def switch(policy, surface:)
        return policy if policy.equal?(@current)

        record = Telemetry::PolicySwitch.new(from: policy_name(@current), to: policy_name(policy), surface:)
        failure = CLI::JournalTee.landed { @journal.record(record) }
        bind(policy)
        raise failure if failure

        policy
      end

      private

      # The Gate adapted what it was handed at construction, and that was
      # this slot, so what the slot is handed LATER needs the same adapting:
      # a bare callable switched in would otherwise raise out of the tool
      # runner with the model's call unanswered. `current` stays what was
      # handed in, so a caller inspecting the live side sees its own policy.
      def bind(policy)
        @current = policy
        @ruling = Middleware::Gate::Callable.of(policy)
      end

      # A policy that names itself is named so -- two ladders of one class
      # stand behind the two approval levels -- and any other by the same
      # snake_case naming Telemetry::Journalable stamps records with, so journal
      # readers grep one convention.
      def policy_name(policy)
        policy.respond_to?(:label) ? policy.label : policy.class.name.split("::").last.underscore
      end
    end
  end
end
