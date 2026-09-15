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
        include Declarative

        # One bare word, which is what every wired requester is.
        NAME = /\A[\w-]+\z/
        private_constant :NAME

        # @return [String] what a human is TOLD is asking
        attr_reader :requester

        # Refused at construction, the one place that cannot be degraded away,
        # for two separate reasons that happen to share a rule.
        #
        # BLANK, because the downstream guard does not fire where it looks like
        # it does: {Telemetry::Carriers::ApprovalPending} validates presence, but
        # its raise lands inside {Approval::Queue#record_evidence}, which
        # rescues and degrades. Measured, a blank name DELETES the
        # approval_pending record -- "something is waiting", the one state a
        # human is asked to act on -- journals a decision naming nobody, and
        # renders " asks: approve ..." at the terminal.
        #
        # UNPRINTABLE, because this string is rendered RAW into both human
        # surfaces. A newline forges a whole second approval question in front
        # of the real one at the terminal -- the attack
        # {Approval::Queue::Outstanding#preamble} defeats, one slot over -- and
        # in {Frontend::Neovim::ApprovalView} it splits one row across two
        # buffer lines while the renderings stay one-per-pending, so a cursor
        # resolves to the WRONG pending. Every value reaching this slot is a
        # closed literal today, but it became a wiring ARGUMENT, and an
        # invariant resting on "all current callers happen to be literals" is
        # prose. A WHITELIST rather than a blacklist: the escapes worth refusing
        # are not a set anyone can finish enumerating.
        #
        # The attribute is deliberately UNTYPED: ActiveModel's format validator
        # matches against `value.to_s` anyway, so an untyped slot applies the
        # same rule while leaving the refusal free to `inspect` what the caller
        # actually passed -- a typed one would report the cast String and lose
        # the difference between nil and `""`.
        declare do
          attribute :requester
          validates :requester,
                    format: { with: NAME,
                              message: lambda { |_record, error|
                                "must name who is asking in one bare word, got #{error[:value].inspect}"
                              } }
        end

        def initialize(context, requester)
          self.class.check!(requester:)

          super(context)
          @requester = -requester.to_s
        end
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
