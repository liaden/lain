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
    #   `fresh` (a new root over the shared Store -- `meet(child, parent)` empty),
    #   `inherit` (`parent.fork`, O(1), the child's head IS the parent's), or
    #   `sibling_template` (fresh isolation, but siblings share a byte-identical
    #   template prefix WITH EACH OTHER -- CE-4's 1-write-N-1-reads arm).
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

      # Whose render prefix the child shares. A strategy answers two questions:
      # what Timeline does the child start from (given the parent and the shared
      # Store), and how the child's Context is shaped before it renders --
      # `child_context` and `journal_floor` are identity/no-op legs on every arm
      # but `sibling_template`, kept on the duck so the spawn seam never asks a
      # strategy what kind it is.
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

          def child_context(context, **) = context

          def journal_floor(_journal) = self

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

          def child_context(context, **) = context

          def journal_floor(_journal) = self

          def label = "inherit"
        end

        # CE-4's third arm: children are isolated like `fresh` -- a new root
        # over the shared Store -- but share a byte-identical system prefix
        # WITH EACH OTHER, so a fan-out pays one cache write and N-1 reads
        # instead of N cold bootstraps. The template is the shared bulk (a
        # role-invariant prelude, e.g. `Role#prelude_segments` position 0);
        # everything per-child (the task, a role fill) belongs in messages,
        # AFTER the template's breakpoint, never in system.
        class SiblingTemplate
          # Anthropic's minimum cacheable prefix (CLAUDE.md, verified): a
          # prefix that ends under this many tokens silently does not cache,
          # with no error -- which is why the floor is journaled here
          # (#journal_floor), never inferred from a missing cache hit.
          MINIMUM_CACHEABLE_TOKENS = 4096

          # ~4 chars/token is a heuristic, not a tokenizer: the note below is
          # advisory (a journal line, not a gate), and the strategy cannot see
          # the tools bytes that share its prefix anyway, so a cheap estimate
          # that errs toward reporting is the honest trade.
          CHARS_PER_TOKEN = 4

          # The journaled floor note ("template_below_floor" on the wire): the
          # arm may still run under the floor -- the provider just won't cache
          # it -- but it must never do so SILENTLY, because an un-cacheable
          # sibling fan-out quietly pays N full prefills while looking like
          # the 1-write-N-1-reads arm on the bench.
          TemplateBelowFloor = Data.define(:strategy, :estimated_tokens, :floor) do
            include Telemetry::Journalable
          end

          # A caller-placed cache marker discarded by {#child_context}
          # ("system_mark_stripped" on the wire): the strategy overrides the
          # factory's mark placement, and overriding caller intent silently
          # would be a lie in the record -- `stripped` counts the discarded
          # markers so a bench reader sees the prompt was rewritten, and why.
          SystemMarkStripped = Data.define(:strategy, :stripped) do
            include Telemetry::Journalable
          end

          def initialize(template: "")
            @template = -template.to_s
            freeze
          end

          # Isolation is half the arm's pitch: like Fresh, a new empty root
          # over the shared Store, so `meet(child, parent)` stays bottom.
          # `parent` is unused here but part of the uniform strategy duck.
          def base_timeline(store:, **)
            Timeline.empty(store:)
          end

          # The factory's Context with the template appended as the LAST
          # system block, deliberately UNMARKED: {Context#cache_marked} marks
          # the final system block unconditionally, so the template boundary
          # and Context's own mark become the SAME mark. Pre-marking here
          # would put a second marker in system, and {Context::CacheBreakpoints}
          # budgets its message markers assuming system spends exactly one
          # slot -- the extra mark can reach 5 on the wire, which Anthropic
          # 400s (the recorded T24 risk). Corollary: the factory context's own
          # system joins the shared prefix AHEAD of the template, so it must
          # be sibling-invariant too -- which it is, riding one injected
          # factory per spawn seam.
          #
          # The same cap is why caller-placed marks are STRIPPED from the
          # factory's system rather than kept: alone, a last-block mark merges
          # idempotently with Context's own, but the template demotes that
          # block to non-last, so a surviving caller mark would sit beside the
          # tail mark -- two system marks, five on the wire at full message
          # budget. Under this arm the strategy owns ALL mark placement for
          # the child; discarding caller intent is journaled, never silent.
          def child_context(context, journal: Channel::Null.instance)
            return context if @template.empty?

            blocks, stripped = stripped_system(context.system)
            journal << SystemMarkStripped.new(strategy: label, stripped:) if stripped.positive?
            Context.new(
              model: context.model, max_tokens: context.max_tokens,
              system: blocks + [{ "type" => "text", "text" => @template }],
              stream: context.stream, extra: context.extra
            )
          end

          def journal_floor(journal)
            return self unless below_floor?

            journal << TemplateBelowFloor.new(strategy: label, estimated_tokens:, floor: MINIMUM_CACHEABLE_TOKENS)
            self
          end

          def label = "sibling_template"

          private

          def below_floor? = estimated_tokens < MINIMUM_CACHEABLE_TOKENS

          def estimated_tokens = @template.length / CHARS_PER_TOKEN

          # Normalized blocks with every "cache" marker removed, plus the count
          # removed (the number #child_context journals). The String-to-block
          # normalization mirrors Context#system_blocks; it cannot delegate
          # there because that method is rightly private to Context's own
          # render path.
          def stripped_system(system)
            blocks = system_blocks(system)
            [blocks.map { |block| block.except("cache") }, blocks.count { |block| block["cache"] }]
          end

          def system_blocks(system)
            return [] if system.nil?

            system.is_a?(String) ? [{ "type" => "text", "text" => system }] : system
          end
        end

        REGISTRY = { fresh: Fresh, inherit: Inherit, sibling_template: SiblingTemplate }.freeze
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
