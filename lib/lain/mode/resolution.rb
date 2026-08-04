# frozen_string_literal: true

module Lain
  class Mode
    # The one place a posture's declared symbols become objects: a capability
    # set, an approval policy, and the name of a snapshot scope, resolved
    # together against the collaborators a session actually holds.
    #
    # Pure, and that is the whole design. Resolving takes a mode, a BASE
    # toolset and a queue, and answers a value; it wires nothing, mutates
    # nothing, and touches no filesystem. Everything that has to be plugged in
    # lives one card up, at the switchboard.
    #
    # == Why `base:` is named that, and why re-resolving is not a widening
    #
    # {Toolset} attenuation is monotone -- a dropped capability cannot be
    # regained by the holder -- so a resolution may never build on the toolset
    # a previous posture left behind. It always starts from the session's base
    # set, which makes leaving `plan` an ordinary resolution rather than a
    # re-grant, and keeps the monotonicity law an unbroken claim about every
    # Toolset that exists. `base` says so at every call site.
    #
    # == The two things this object deliberately does NOT do
    #
    # It does not decide WHETHER a posture attenuates. {Posture#attenuate} owns
    # that, through its {Posture::Permits} Null Object, and a second
    # `toolset.only(...)` written here would be a copy of a rule with one home
    # -- the copy being the one that goes on granting after the list changes.
    #
    # It does not construct a snapshot scope. {Workspace::Snapshot#initialize}
    # primes the scope it is given via `#baseline(root)`, precisely so a
    # posture's `snapshot_scope` can stay an inert Symbol the whole way down:
    # only Snapshot knows the root and the moment the session began, so only
    # Snapshot can prime a difference-detecting scope. Resolving one here would
    # need a root this object has no business holding.
    #
    # A Resolution is frozen but is NOT `Ractor.shareable?`, unlike every other
    # value in the mode family: it holds live collaborators on purpose. That is
    # the line between {Mode}, which is a declaration and crosses anywhere, and
    # this, which is a wiring answer bound to one session.
    #
    # == `==` DOES NOT ANSWER "did the posture change"
    #
    # Two resolutions of the SAME mode compare unequal under `plan` and `auto`,
    # and equal under `manual` and `accept_edits` -- exactly backwards from what
    # a reader expects. The asking rungs resolve to the one session queue, which
    # is identical to itself; the other two allocate a fresh stateless
    # {Effect::Handler::Gate::DenyAll} or `ApproveAll` per call, and `Data#==`
    # compares those by identity. So `resolution == previous_resolution` reports
    # "changed" on every re-resolve under half the ladder. Compare the {Mode}
    # values, which are proper frozen values, and never these.
    #
    # The house fix -- hoisting the two stateless policies to shared frozen
    # constants the way {Posture::Permits::All} does one file over -- is not
    # available here: `lain.rb` loads `lain/mode` ten entries before
    # `lain/effect`, so an eager `DenyAll.new` in this class body is a hard
    # NameError at load. A follow-up ticket owns it.
    Resolution = Data.define(:toolset, :gate_policy, :snapshot_scope)

    class Resolution
      # Reopened rather than written inside a `Data.define ... do` block: constants
      # declared there scope to the enclosing module, so `GATE_POLICIES` would
      # land as `Lain::Mode::GATE_POLICIES` and `Unknown` as `Lain::Mode::Unknown`
      # (the trap {Request::SYSTEM_PREFIX} documents). Keeping `.for` here too
      # puts the factory in the same scope as the table it reads.

      # Raised when a posture names a gate policy or capability nothing declares.
      # Loud rather than defaulted: a silently-dropped policy is an approval gate
      # that quietly stops guarding.
      class Unknown < Error; end

      # Takes the whole {Mode} and reads only `posture` from it. Deliberate: a
      # layer that attenuates or that moves the gate is a declared possibility
      # ({Mode::Layer}'s `alters_outcome`), and folding one in later is then a
      # change to this method's BODY rather than to its signature and every
      # caller. Passing `mode.posture` here instead would push that Demeter hop
      # onto the switchboard and buy nothing.
      #
      # @param mode [Lain::Mode] the mode this session is in
      # @param base [Lain::Toolset] the session's FULL set, never an attenuated
      #   one -- see the monotonicity note above
      # @param queue [#call] the approval policy `(effect, context) -> Boolean`
      #   the asking rungs resolve to. Required, with no Null Object default,
      #   and that is a ruling rather than an omission: `manual` and
      #   `accept_edits` resolved without a queue would silently become `plan`'s
      #   gate -- the same class -- so every tier-3 call would answer "approval
      #   denied", no human would ever be asked, and the journal would record
      #   the arm as `manual`. On a bench, an arm quietly degrading into a
      #   different arm corrupts the record. `auto` and `plan` never touch it,
      #   but "absent" being legitimate on two rungs and a wiring bug on the
      #   other two is exactly the shape that must not be defaulted.
      # @return [Resolution]
      # @raise [Lain::Toolset::UnknownTool] when the posture names a tool `base`
      #   does not hold
      # @raise [Unknown] when the posture names a gate policy nothing declares
      def self.for(mode:, base:, queue:)
        posture = mode.posture
        new(toolset: posture.attenuate(base),
            gate_policy: gate_policy_for(posture.gate_policy, queue),
            snapshot_scope: posture.snapshot_scope)
      end

      # @raise [Unknown] naming the declared set, the same shape
      #   {Workspace::Snapshot::Scope.fetch} and {Toolset#only} take. Reachable
      #   only from a hand-built {Posture}, which is exactly when a reader needs
      #   telling what the four rungs are allowed to say.
      def self.gate_policy_for(name, queue)
        GATE_POLICIES.fetch(name) do
          raise Unknown, "unknown gate policy #{name.inspect}, expected one of #{GATE_POLICIES.keys.inspect}"
        end.call(queue)
      end
      private_class_method :gate_policy_for

      # Each declared gate policy as a function of the session's queue, so the
      # queue arm is a member of the table rather than a branch beside it.
      # {Effect::Handler::Gate::ApproveAll} and {Effect::Handler::Gate::DenyAll}
      # are built per resolution because they hold no state; the queue is passed
      # through untouched, since it is the session's one parking place and a
      # copy of it would park fibers nobody is watching.
      #
      # Declared after the methods that read it, as {Mode::Layer} does with
      # DECLARED: nothing above needs a forward reference.
      #
      # The lambdas are lambdas because this file carries real load-order debt
      # and defers it. `lain.rb` requires `lain/mode` ten entries before
      # `lain/effect`, so `Effect::Handler::Gate::DenyAll` does not exist when
      # this table is built -- the obvious refactor, mapping each name straight
      # to its policy class or to a shared frozen instance, is a hard NameError
      # at load rather than a style preference. Wrapping each arm in a lambda
      # moves the constant lookup to call time, which is the only reason the
      # manifest may keep `mode` above `effect`.
      GATE_POLICIES = {
        deny_all: ->(_queue) { Effect::Handler::Gate::DenyAll.new },
        queue: ->(queue) { queue },
        approve_all: ->(_queue) { Effect::Handler::Gate::ApproveAll.new }
      }.freeze
      private_constant :GATE_POLICIES
    end
  end
end
