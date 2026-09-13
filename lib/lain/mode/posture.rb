# frozen_string_literal: true

module Lain
  class Mode
    Posture = Data.define(:name, :permits, :gate_policy, :snapshot_scope, :lighter) do
      # Delegated rather than reached through, so a caller holds a posture and
      # never a Permits.
      #
      # @param toolset [Lain::Toolset] the session's full set
      # @return [Lain::Toolset] the same object under an unattenuating posture,
      #   a new attenuated one under `plan`
      # @raise [Lain::Toolset::UnknownTool] when this posture names a tool the
      #   given set does not hold -- loud, at the honest place, exactly as
      #   {Role#attenuate} fails
      def attenuate(toolset) = permits.attenuate(toolset)
    end

    # One rung of the posture ladder -- the single exclusive slot that governs
    # how a turn's output is interpreted. The gate policy and the snapshot scope
    # stay SYMBOLS here, so the ladder can be read, compared and journaled with
    # no Toolset, approval queue or filesystem in reach; {Mode::Resolution}
    # turns them into live collaborators.
    #
    # `plan` buys its safety by attenuation rather than by gating -- the
    # rendered schema does not contain `edit_file`, so there is nothing to ask a
    # human about. The two lower rungs buy theirs from REVERSIBILITY, which is
    # why they differ only in snapshot scope. `accept_edits` is the default and
    # silent: its lighter is the empty String, the identity for rendering, so a
    # prompt composed under it is byte-identical to one composed with no mode
    # support at all.
    #
    # ⚠️ The word "posture" is taken twice.
    # {Tool::SpawnPolicy::AttenuationPosture} and `Role#spawn_policy(posture:)`
    # use it for HOW a smaller tool set is enforced on a child; this is the
    # other sense, WHICH set a session runs under. Read the qualifier.
    class Posture
      # Reopened rather than written inside the `Data.define ... do` block above:
      # a constant declared in that block scopes to the enclosing module, not to
      # the Data class (the trap {Request::SYSTEM_PREFIX} documents), so `Permits`
      # would land as `Lain::Permits`.
      #
      # WHETHER a posture attenuates at all, as an object rather than as a list
      # that is sometimes nil: {All} is the Null Object three of the four rungs
      # hold, so nothing downstream writes `if posture.permits`. The duck is
      # exactly `include?(tool_name)` and `attenuate(toolset)` -- {Only} is a
      # `Data` and also answers `names`, `to_h` and `deconstruct`, which {All}
      # cannot, so a caller reaching for one has written a branch on which arm
      # it holds. A spec pins the boundary.
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

        Only = Data.define(:names) do
          def initialize(names:) = super(names: Array(names).map(&:to_sym).freeze)

          def include?(tool_name) = names.include?(tool_name.to_sym)

          def attenuate(toolset) = toolset.only(*names)
        end
      end

      # `plan`'s capability set, deliberately NOT a {Role::Catalog} `only`-set:
      # those are per-PERSONA spawn recipes, read-only by coincidence rather
      # than by contract (`:reviewer_sre` holds `bash`), so binding a session
      # posture to one would let a persona's tool list silently redefine what
      # plan mode permits.
      #
      # Enumerated as an allow-list because there is no `mutates?` axis to
      # derive it from (`bash` is the tool such a flag would get wrong), and a
      # denial list of the obvious mutators lets `subagent` and `run_skill`
      # through -- neither mutates anything itself, both reach whatever tools
      # the child or the skill names. The two directions fail differently: a
      # tool forgotten here is merely unavailable while planning, whereas a name
      # here that the live toolset LACKS is a hard {Toolset::UnknownTool} on
      # entering plan mode, invisible to any absence assertion -- which is why
      # two specs attenuate REAL Toolsets rather than a double, whose `only`
      # accepts any arguments at all. `todo_write` is OUT although it mutates
      # only session state, because a `_write` tool in a set described as
      # read-only is the misreading to design out; `ask_human` and
      # `session_usage` are IN, and both ride the `Wiring::ToolsetBuild#build`
      # append rather than the capability floor, so they are in the live chat
      # set and no smaller one.
      READ_ONLY = %i[
        read_file list_files glob grep
        ast_search ast_dump file_symbols test_pattern
        memory_read web_fetch web_search ask_human session_usage
      ].freeze
      private_constant :READ_ONLY

      # Defined after {Permits}, which it names. Private: `.for` and {NAMES}
      # are the surface.
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
      #   restrictive first. Derived from the table so the roster an error
      #   message lists cannot drift from the roster that exists.
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
