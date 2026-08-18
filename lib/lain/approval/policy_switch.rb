# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/string/inflections"
require "delegate"

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
      # WHO a gated call is asked on behalf of, riding the `context` every
      # policy on this seam already threads unexamined -- {Escalation} says so
      # in as many words: forwarded to every rung's own call untouched.
      #
      # A rail and not a parameter, because the alternative is widening the
      # `call(effect, context)` duck that {Effect::Handler::Gate::DenyAll},
      # {Effect::Handler::Gate::ApproveAll}, this class and every {Escalation}
      # rung implement -- five objects each forwarding an identity none of them
      # reads, for the one object that does ({Approval::Queue}).
      #
      # A DELEGATOR: it answers every message the wrapped `context` answers, so
      # a rung that reads the run's {Session} still gets one. It is NOT `is_a?`
      # the wrapped class, though, and `case`/`===`/`==` do not see through it
      # either -- a rung must duck-type on the context and never type-test it.
      # Built by whoever knows the actor -- the child seam's gate policy
      # ({CLI::Wiring::ToolsetBuild::LivePolicy}), from the same
      # `announces_as:` name {Tools::Subagent} already enrols its asker under.
      # A context nobody wrapped names nobody, which is the parent's own turn.
      class Requested < SimpleDelegator
        # One bare word, which is what every wired requester is: `"agent"`,
        # {CLI::Wiring::ToolsetBuild::SPAWN_REQUESTER}, and every
        # {Role::Catalog} name. See {#initialize} for why the rule is mechanical.
        NAME = /\A[\w-]+\z/
        private_constant :NAME

        # @return [String] what a human is TOLD is asking
        attr_reader :requester

        # Refused at construction, in the one place that cannot be degraded
        # away, and for two separate reasons that happen to share a rule.
        #
        # BLANK, because the downstream guard does not fire where it looks like
        # it does: {Telemetry::Guards::ApprovalPending} validates presence, but
        # its raise lands inside {Approval::Queue#record_evidence}, which
        # rescues and degrades. So a blank name does not fail loudly -- measured,
        # it DELETES the approval_pending record ("something is waiting", the one
        # state a human is asked to act on), journals a decision naming nobody,
        # and renders " asks: approve ..." at the terminal.
        #
        # UNPRINTABLE, because this string is rendered RAW into both human
        # surfaces. A newline forges a whole second approval question in front
        # of the real one at the terminal -- the attack
        # {Approval::Queue::Outstanding#preamble} spends twenty lines defeating,
        # one slot over -- and in {Frontend::Neovim::ApprovalView} it splits one
        # row across two buffer lines while the renderings stay one-per-pending,
        # so a cursor resolves to the WRONG pending. Every value reaching this
        # slot is a closed literal today; what changed is that it became a
        # wiring ARGUMENT, and an invariant resting on "all current callers
        # happen to be literals" is prose. A whitelist rather than a blacklist,
        # for `Outstanding`'s reason: the escapes worth refusing are not a set
        # anyone can finish enumerating.
        def initialize(context, requester)
          unless requester.to_s.match?(NAME)
            raise ArgumentError, "a requester must name who is asking in one bare word, got #{requester.inspect}"
          end

          super(context)
          @requester = -requester.to_s
        end
      end

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
        @journal.record(Telemetry::PolicySwitch.new(from:, to: policy_name(policy), surface:))
        policy
      end

      private

      # The same snake_case naming Telemetry::Journalable stamps its records
      # with, so journal readers grep one convention.
      def policy_name(policy) = policy.class.name.split("::").last.underscore
    end
  end
end
