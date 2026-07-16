# frozen_string_literal: true

module Lain
  class Tool
    # The two orthogonal axes of a spawn, as small strategy objects the
    # {Tools::Subagent} tool reads at dispatch. Keeping them here -- a leaf that
    # references {Timeline} and {Toolset} only from inside method bodies, never
    # at load time -- is what lets `tool.rb` require it while those units still
    # load later (see the load-order manifest in `lain.rb`).
    #
    # * **Prefix strategy** decides whose render prefix the child's bytes share:
    #   `fresh` (a new root over the shared Store -- `meet(child, parent)` empty)
    #   or `inherit` (`parent.fork`, O(1), the child's head IS the parent's).
    #   The `sibling-template` arm (CE-4) is deferred by the plan.
    # * **Attenuation posture** decides how a smaller capability set is enforced:
    #   `schema` (the model sees only the allowed tools -- the default) or
    #   `handler_union` (the model sees the full union schema so sibling spawns
    #   share a cache prefix, and the Handler refuses a disallowed call).
    #
    # Two axes, not one enum, because they carry independent money: prefix is a
    # cache-prefix decision (`cache-economics.md` CE-4) and posture is a
    # schema-vs-enforcement decision. A {SpawnPolicy} value groups them with the
    # `only`-set the child is attenuated to.
    #
    # The methods and the two strategy modules live in the REOPENED class below,
    # NOT in a `Data.define ... do` block: a constant referenced inside that
    # block resolves against the enclosing module (`Lain::Tool`), not the Data
    # class, so `PrefixStrategy` would not be found (the trap `Request` documents).
    SpawnPolicy = Data.define(:prefix, :posture, :only)

    # Reopened (not a `Data.define ... do` block) so its constants resolve
    # against the Data class -- see the note on {SpawnPolicy} above.
    class SpawnPolicy
      # `prefix`/`posture` accept either a strategy instance or its short name
      # (`:fresh`, `:handler_union`) so a caller writes the arm, not a
      # constructor. `only` normalizes to a frozen Array of Strings -- the same
      # String names {Toolset#only} keys on.
      def initialize(prefix: :fresh, posture: :schema, only: [])
        super(
          prefix: PrefixStrategy.resolve(prefix),
          posture: AttenuationPosture.resolve(posture),
          only: Array(only).map(&:to_s).freeze
        )
      end

      # The child's capability set: the union attenuated DOWN to `only`, or the
      # union unchanged when `only` is empty (an unattenuated worker). Requesting
      # a tool the union does not hold raises through {Toolset#only}, keeping the
      # "read one line to know what it can do" guarantee honest.
      def attenuate(union)
        only.empty? ? union : union.only(*only)
      end

      # Whose render prefix the child shares. A strategy answers one question:
      # what Timeline does the child start from, given the parent and the shared
      # Store.
      module PrefixStrategy
        class Unknown < Error; end

        # A fresh root: a new, empty Timeline over the SAME Store. The child's
        # first commit becomes a root with no render lineage to the parent, so
        # the causal DAG stays reconstructable while `meet(child, parent)` is the
        # empty bottom element. Lineage is recorded out-of-band, on the :spawn
        # event's causal edge (see {Tools::Subagent}).
        class Fresh
          # `parent` is unused here but part of the uniform strategy duck.
          def base_timeline(store:, **)
            Timeline.empty(store:)
          end

          def label = "fresh"
        end

        # Fork the parent: O(1) and copies nothing, because a Timeline is only a
        # (head, store) pair. The child's head IS the parent's head until its
        # first commit, so the child inherits the whole conversation -- the arm
        # that trades subagent isolation for a shared, already-warm cache prefix.
        class Inherit
          # `store` is unused here (the fork carries the parent's own) but part
          # of the uniform strategy duck.
          def base_timeline(parent:, **)
            parent.fork
          end

          def label = "inherit"
        end

        REGISTRY = { fresh: Fresh, inherit: Inherit }.freeze
        private_constant :REGISTRY

        # A name maps to a fresh instance; an already-built strategy passes
        # through. Unknown names fail loudly, naming the set -- the same posture
        # {Toolset#only} takes toward an absent tool.
        def self.fetch(name)
          klass = REGISTRY.fetch(name.to_sym) do
            raise Unknown, "unknown prefix strategy #{name.inspect}, expected one of #{REGISTRY.keys.inspect}"
          end
          klass.new
        end

        def self.resolve(strategy)
          strategy.respond_to?(:base_timeline) ? strategy : fetch(strategy)
        end
      end

      # How a smaller capability set is enforced. A posture answers two
      # questions: which toolset the child RENDERS (what the model sees), and
      # whether the Handler must refuse a disallowed call over a union schema.
      module AttenuationPosture
        class Unknown < Error; end

        # The model sees only the allowed tools' schemas. Enforcement is the
        # render itself -- a tool absent from the schema is a tool the model
        # cannot name. The default arm; it forfeits sibling cache-sharing (every
        # role gets a different byte-0 prefix) in exchange for a tighter prompt.
        class Schema
          # `union` is unused here but part of the uniform posture duck.
          def rendered_toolset(allowed:, **)
            allowed
          end

          def refuses_over_union? = false

          def label = "schema"
        end

        # The model sees the SHARED UNION's schema -- the union handed to the
        # spawn seam, which need not equal the spawning parent's own toolset --
        # so heterogeneous sibling spawns render byte-identical tools blocks
        # and share one cached prefix (CE-4: sibling-equality is the win). The
        # Handler enforces the attenuation instead: a disallowed call is
        # refused as an is_error tool_result and journaled -- enforcement was
        # always the Handler's, since tools are capabilities, not schema
        # entries.
        class HandlerUnion
          # `allowed` is unused here but part of the uniform posture duck.
          def rendered_toolset(union:, **)
            union
          end

          def refuses_over_union? = true

          def label = "handler_union"
        end

        REGISTRY = { schema: Schema, handler_union: HandlerUnion }.freeze
        private_constant :REGISTRY

        def self.fetch(name)
          klass = REGISTRY.fetch(name.to_sym) do
            raise Unknown, "unknown attenuation posture #{name.inspect}, expected one of #{REGISTRY.keys.inspect}"
          end
          klass.new
        end

        def self.resolve(posture)
          posture.respond_to?(:rendered_toolset) ? posture : fetch(posture)
        end
      end
    end
  end
end
