# frozen_string_literal: true

module Lain
  class Mode
    # The one place a posture's declared symbols become objects, resolved
    # against the collaborators a session actually holds. Pure: it wires
    # nothing, mutates nothing, touches no filesystem.
    #
    # {Toolset} attenuation is monotone, so a resolution may never build on the
    # toolset a previous posture left behind. It always starts from the
    # session's BASE set, which makes leaving `plan` an ordinary resolution
    # rather than a re-grant and keeps monotonicity an unbroken claim about
    # every Toolset that exists.
    #
    # It does not decide WHETHER a posture attenuates -- {Posture#attenuate}
    # owns that, and a second `toolset.only(...)` here would be the copy that
    # goes on granting after the list changes. Nor does it construct a snapshot
    # scope: only {Workspace::Snapshot} knows the root and the moment the
    # session began, so the `snapshot_scope` stays an inert Symbol all the way
    # down. Frozen but NOT `Ractor.shareable?`, unlike the rest of the mode
    # family: it holds live collaborators on purpose.
    #
    # ⚠️ `==` DOES NOT ANSWER "did the posture change", and answers backwards
    # from expectation: two resolutions of the SAME mode compare unequal under
    # `plan` and `auto` and equal under `manual` and `accept_edits`. The asking
    # rungs resolve to the one session queue, identical to itself; the other two
    # allocate a fresh stateless gate per call, which `Data#==` compares by
    # identity. Compare the {Mode} values, never these.
    Resolution = Data.define(:toolset, :gate_policy, :snapshot_scope)

    class Resolution
      # Reopened rather than written inside a `Data.define ... do` block:
      # constants declared there scope to the enclosing module, so
      # `GATE_POLICIES` would land as `Lain::Mode::GATE_POLICIES` (the trap
      # {Request::SYSTEM_PREFIX} documents).

      # Loud rather than defaulted, and one class for both causes because the
      # consequence is the same: a silently-dropped policy is an approval gate
      # that quietly stops guarding.
      class Unknown < Error; end

      # Takes the whole {Mode} and reads only `posture`: a layer that attenuates
      # or moves the gate is a declared possibility ({Mode::Layer}'s
      # `alters_outcome`), and folding one in later is then a change to this
      # method's body rather than to its signature and every caller.
      #
      # @param mode [Lain::Mode] the mode this session is in
      # @param base [Lain::Toolset] the session's FULL set, never an attenuated
      #   one -- see the monotonicity note above
      # @param queue [#rule] the approval policy `(effect, context) -> Ruling`
      #   the asking rungs resolve to. Required, with no Null Object default:
      #   `manual` and `accept_edits` resolved without one would silently become
      #   `plan`'s gate -- the same class -- so every tier-3 call would answer
      #   "approval denied", no human would be asked, and the journal would
      #   still record the arm as `manual`. On a bench, an arm degrading into a
      #   different arm corrupts the record.
      # @return [Resolution]
      # @raise [Lain::Toolset::UnknownTool] when the posture names a tool `base`
      #   does not hold
      # @raise [Unknown] when the posture names a gate policy nothing declares,
      #   or when `queue:` is nil
      def self.for(mode:, base:, queue:)
        posture = mode.posture
        # The required keyword catches an OMITTED queue; this catches a named
        # one that answered nil. Refused for EVERY posture, not only the two
        # that consult it: a nil `auto` tolerates is the same wiring bug one
        # `/mode manual` away, and refusing here beats a NoMethodError on
        # `nil.call` inside the Gate at approval time. Ahead of the
        # attenuation, so nothing has moved.
        raise Unknown, format(MISSING_QUEUE, posture: posture.name) if queue.nil?

        new(toolset: posture.attenuate(base),
            gate_policy: gate_policy_for(posture.gate_policy, queue),
            snapshot_scope: posture.snapshot_scope)
      end

      # @raise [Unknown] naming the declared set. Reachable only from a
      #   hand-built {Posture}, which is exactly when a reader needs telling
      #   what the four rungs are allowed to say.
      def self.gate_policy_for(name, queue)
        GATE_POLICIES.fetch(name) do
          raise Unknown, "unknown gate policy #{name.inspect}, expected one of #{GATE_POLICIES.keys.inspect}"
        end.call(queue)
      end
      private_class_method :gate_policy_for

      MISSING_QUEUE = "cannot resolve the %<posture>s posture: `queue:` is nil, and no Null Object stands " \
                      "behind it. An asking posture resolved without a queue silently becomes plan's gate -- " \
                      "every gated call would answer \"approval denied\", no human would ever be asked, and " \
                      "the journal would still record the arm as %<posture>s."
      private_constant :MISSING_QUEUE

      # Each policy as a function of the session's queue, so the queue arm is a
      # member of the table rather than a branch beside it. Every arm answers
      # `#rule` itself, so none of them reaches {Middleware::Gate::Callable},
      # whose rulings cannot say why a call was refused. The queue is passed
      # through untouched: it is the session's one parking place, and a copy
      # would park fibers nobody is watching.
      #
      # The arms are lambdas because `lain.rb` requires `lain/mode` well before
      # `lain/middleware`, so `Middleware::Gate::DenyAll` does not exist when
      # this table is built -- mapping each name straight to its policy class or
      # to a shared frozen instance is a hard NameError at load, not a style
      # preference. Deferring the lookup to call time is the only reason the
      # manifest may keep `mode` above `middleware`.
      GATE_POLICIES = {
        deny_all: ->(_queue) { Middleware::Gate::DenyAll.new },
        queue: ->(queue) { queue },
        approve_all: ->(_queue) { Middleware::Gate::ApproveAll.new }
      }.freeze
      private_constant :GATE_POLICIES
    end
  end
end
