# frozen_string_literal: true

module Lain
  module Mode
    # One rung of the posture ladder -- the single exclusive slot that governs
    # how a turn's output is interpreted. A posture DECLARES four things and
    # resolves none of them: the capability set it permits, the name of a gate
    # policy, the name of a snapshot scope, and the lighter it renders.
    #
    #   plan          reads only          deny_all      write_set     "PLAN"
    #   manual        everything          queue         write_set     "MAN"
    #   accept_edits  everything          queue         shadow_git    ""
    #   auto          everything          approve_all   shadow_git    "AUTO"
    #
    # The gate policy and snapshot scope stay SYMBOLS here, and that is the
    # whole design of this object: {Mode::Resolution} turns them into live
    # collaborators, so the ladder itself can be read, compared and journaled
    # without a Toolset, an approval queue or a filesystem anywhere in reach.
    #
    # `plan` buys its safety by attenuation rather than by gating -- the model's
    # rendered schema simply does not contain `edit_file`, so there is nothing
    # to ask a human about. That is "tools are capabilities, not permissions"
    # applied to a mode. The two lower rungs buy theirs from REVERSIBILITY
    # instead, which is why they differ only in snapshot scope.
    #
    # `accept_edits` is the default, and the default is silent: its lighter is
    # the empty String, the identity for rendering, so a prompt or a HUD
    # composed under it is byte-identical to one composed with no mode support
    # at all. A layer that can change an outcome must announce itself; the
    # posture nothing was changed from must not.
    #
    # == The word "posture" is already taken, twice
    #
    # {Tool::SpawnPolicy::AttenuationPosture} and `Role#spawn_policy(posture:)`
    # both use it for HOW a smaller tool set is enforced on a child -- schema
    # attenuation versus refusal at dispatch. This is the other sense: WHICH set
    # a session runs under. The two meet the moment a plan-mode session spawns a
    # subagent, where a posture (this one) decides what the parent holds and a
    # posture (that one) decides how the child is held to a subset of it. Read
    # the qualifier, never the bare word.
    #
    # == The one message the resolution owes this object
    #
    # `Resolution#toolset` is `posture.attenuate(base)` and NOTHING more. The
    # branch on whether a posture attenuates at all lives here, in {Permits}, so
    # a second `toolset.only` written at the resolution seam would be a copy of
    # a rule that has one home -- and the copy is the one that would go on
    # granting after this list changed.
    Posture = Data.define(:name, :permits, :gate_policy, :snapshot_scope, :lighter) do
      # The session's capability set as this posture allows it. Delegated rather
      # than reached through, so a caller holds a posture and never a Permits.
      #
      # @param toolset [Lain::Toolset] the session's full set
      # @return [Lain::Toolset] the same object under an unattenuating posture,
      #   a new attenuated one under `plan`
      # @raise [Lain::Toolset::UnknownTool] when this posture names a tool the
      #   given set does not hold -- loud, at the honest place, exactly as
      #   {Role#attenuate} fails
      def attenuate(toolset) = permits.attenuate(toolset)
    end

    # Reopened rather than written inside the `Data.define ... do` block above:
    # a constant declared in that block scopes to the enclosing module, not to
    # the Data class (the trap {Request::SYSTEM_PREFIX} documents), so `Permits`
    # would land as `Lain::Permits`.
    class Posture
      # WHETHER a posture attenuates at all, as an object rather than as a list
      # that is sometimes nil. {All} is the Null Object three of the four rungs
      # hold, so nothing downstream ever writes `if posture.permits`.
      #
      # The duck is exactly two messages -- `include?(tool_name)`, for asking
      # what a posture allows, and `attenuate(toolset)`, for handing over a
      # Toolset and taking back the one it allows. {Only} is a `Data` and so
      # also answers `names`, `to_h` and `deconstruct`; those are NOT the duck,
      # {All} cannot answer them, and a caller that reaches for one has written
      # a branch on which arm it holds. A spec pins the boundary.
      module Permits
        # No attenuation: the session keeps everything it was built with.
        All = Class.new do
          # Symbolizes and discards, so a nil or a non-name dies here exactly as
          # loudly as it does on {Only}. Without it the Null Object would be the
          # one arm where a typo'd lookup quietly answers true -- the silent-yes
          # failure a Null Object exists to remove, not to introduce.
          def include?(tool_name)
            tool_name.to_sym
            true
          end

          def attenuate(toolset) = toolset

          # Named, because an anonymous singleton renders as `#<#<Class:0x…>:0x…>`
          # and this value rides into {Mode#describe} and a journaled switch record.
          def inspect = "Lain::Mode::Posture::Permits::All"
          alias_method :to_s, :inspect
        end.new.freeze

        # Attenuation down to exactly `names`, through {Toolset#only}.
        Only = Data.define(:names) do
          def initialize(names:) = super(names: Array(names).map(&:to_sym).freeze)

          def include?(tool_name) = names.include?(tool_name.to_sym)

          def attenuate(toolset) = toolset.only(*names)
        end
      end

      # `plan`'s capability set. It deliberately does NOT reuse a {Role::Catalog}
      # `only`-set: those are per-PERSONA spawn recipes that carry a prompt slot
      # with them, and the read-only-looking ones are read-only by coincidence
      # rather than by contract (`:reviewer_sre` holds `bash`). Binding a session
      # posture to one would let a persona's tool list silently redefine what
      # plan mode permits. A posture attenuates the session; a role attenuates a
      # spawn. Same mechanism, different subject.
      #
      # == Why an allow-list, measured rather than argued
      #
      # Attenuating the whole shipped registry through `plan` leaves these
      # thirteen standing and drops eleven -- including `subagent` and
      # `run_skill`, neither of which mutates anything itself and both of which
      # reach whatever tools the child or the skill names. A denial list of the
      # five obvious mutators lets both through. There is no `mutates?` axis to
      # derive the right answer from, and the plan rules that there must not be
      # one (`bash` is the tool such a flag would get wrong), so the set is
      # enumerated.
      #
      # The two directions fail differently, and only one of them is safe:
      #
      # - GRANT direction -- a tool shipped and forgotten here is merely
      #   unavailable while planning. Safe, and the reason for an allow-list.
      # - AVAILABILITY direction -- a name here that the live toolset lacks is a
      #   hard {Toolset::UnknownTool} the moment plan mode is entered. NOT safe,
      #   invisible to any absence assertion, and the reason two specs attenuate
      #   REAL Toolsets (the shipped registry and the live chat set) rather than
      #   a double, whose `only` accepts any arguments at all.
      #
      # `todo_write` and `ask_human` are the two judgement calls, recorded so
      # they read as decisions rather than as oversights. `todo_write` is OUT: it
      # mutates only session state, but a `_write` tool inside a set described as
      # read-only is precisely the misreading to design out. `ask_human` is IN: a
      # question is not a mutation, and a mode whose whole purpose is to converse
      # about a plan before acting must keep its blocking channel to the human.
      # It is appended by `Wiring::ToolsetBuild#build` rather than by the
      # capability floor, so it is in the live chat set and in no smaller one.
      READ_ONLY = %i[
        read_file list_files glob grep
        ast_search ast_dump code_outline file_symbols test_pattern
        memory_read web_fetch web_search ask_human
      ].freeze
      private_constant :READ_ONLY

      # Defined after {Permits}, which it names. Private: an internal lookup
      # table, not the surface -- `.for` and {NAMES} are.
      POSTURES = {
        plan: new(name: :plan, permits: Permits::Only.new(READ_ONLY),
                  gate_policy: :deny_all, snapshot_scope: :write_set, lighter: "PLAN"),
        manual: new(name: :manual, permits: Permits::All,
                    gate_policy: :queue, snapshot_scope: :write_set, lighter: "MAN"),
        accept_edits: new(name: :accept_edits, permits: Permits::All,
                          gate_policy: :queue, snapshot_scope: :shadow_git, lighter: ""),
        auto: new(name: :auto, permits: Permits::All,
                  gate_policy: :approve_all, snapshot_scope: :shadow_git, lighter: "AUTO")
      }.freeze

      # @return [Array<Symbol>] the posture names {.for} accepts, most
      #   restrictive first. Derived from the table rather than restated beside
      #   it, so the roster an error message lists cannot drift from the roster
      #   that exists.
      NAMES = POSTURES.keys.freeze

      # @param name [Symbol, String] one of {NAMES}
      # @return [Posture] the one shared frozen value for that rung
      # @raise [ArgumentError] on an unknown name. Explicit, so the message
      #   NAMES the alternatives: "unknown posture" with no ladder beside it
      #   sends the reader to the source.
      def self.for(name)
        POSTURES.fetch(name.to_sym) do
          raise ArgumentError, "unknown posture #{name.inspect}, expected one of #{NAMES.inspect}"
        end
      end

      private_constant :POSTURES
    end
  end
end
