# frozen_string_literal: true

module Lain
  class Skill
    # Composes a skill's scaffold into finished prompt bytes: it renders the
    # shipped scaffold ONCE, fills each declared hole via {Prompt::Slots#render_skill}
    # (the pure LEAF render), and inlines each statically-declared `include` by
    # rendering the named skill in turn. Composition lives HERE, not in the locked
    # binding: the Renderer holds the catalog (to resolve an include to a scaffold)
    # and the slots (to resolve a hole to its fill); the binding stays a pure leaf
    # that only knows how to evaluate one template. One renders, one composes --
    # they are not two homes for the same job.
    #
    # == Splice, never a second ERB pass
    #
    # A rendered hole or a rendered include is FINISHED markdown. It must never be
    # fed back through ERB: a fragment whose OUTPUT bytes look like ERB (`<%- ...`,
    # `<%%`) would be re-parsed on a second pass and silently mangled --
    # `50%% off <%- code` collapses to `50%% off  code`, bytes dropped with no
    # error. That breaks the verbatim-injection guarantee and is exactly the silent
    # truncation the bench forbids. So the scaffold's ONE ERB pass emits an inert
    # {PLACEHOLDER} for each hole/include, and the pre-rendered fragments are
    # spliced in AFTERWARD in a single pass. Purity is still enforced at the
    # legitimate first eval: an impure scaffold fails in its own render pass, an
    # impure hole in {Prompt::Slots#render_skill} before it is ever a fragment.
    #
    # An include cycle (A includes B includes A) is caught by a render stack and
    # surfaced as {Prompt::CircularSlot} naming the chain -- never an infinite
    # loop, never a silent truncation. The stack lives here rather than in the
    # binding because each skill's scaffold renders in its OWN binding (its holes
    # resolve against ITS slots), so the binding's per-template guard cannot see
    # across an include; the cross-skill guard is the Renderer's.
    #
    # Rendering is a pure function of the frozen catalog and frozen slots, so
    # identical inputs yield byte-identical output.
    class Renderer
      # The inert token the scaffold's single ERB pass emits in place of a
      # hole/include, keyed by fragment index and spliced afterward. A NUL byte
      # (0x00) cannot occur in a markdown partial, so the token can neither
      # collide with real content nor be mistaken for an ERB tag on the
      # scaffold's own pass.
      SENTINEL = "\u0000"
      PLACEHOLDER = /#{SENTINEL}lain-fragment:(?<index>\d+)#{SENTINEL}/
      private_constant :SENTINEL, :PLACEHOLDER

      def initialize(catalog:, slots:)
        @catalog = catalog
        @slots = slots
      end

      # The finished scaffold bytes for +skill_name+, holes filled and includes
      # inlined. Pure and byte-stable.
      def render(skill_name)
        compose(@catalog.fetch(skill_name), [])
      end

      private

      def compose(skill, stack)
        raise Prompt::CircularSlot, "skill include cycle: #{(stack + [skill.name]).join(" -> ")}" \
          if stack.include?(skill.name)

        fragments = []
        engine = Prompt::LockedBinding.new(resolve: collector(skill, stack + [skill.name], fragments))
        splice(engine.render_template(skill.scaffold, "skill/#{skill.name}"), fragments)
      end

      # The scaffold's `render(name)` helper: resolve the name the scaffold
      # declared -- a hole (front-matter `slots`) to its rendered fill, or an
      # include (front-matter `includes`) to that skill's own composed scaffold --
      # stash the finished fragment, and hand back an inert placeholder for the
      # scaffold's one ERB pass to emit. A name the scaffold declared NEITHER is a
      # loud authoring error, never a silent empty splice.
      def collector(skill, stack, fragments)
        lambda do |name|
          fragments.push(fragment_for(skill, name.to_sym, stack))
          "#{SENTINEL}lain-fragment:#{fragments.size - 1}#{SENTINEL}"
        end
      end

      def fragment_for(skill, ref, stack)
        resolve_hole(skill, ref) || resolve_include(skill, ref, stack) ||
          raise(Prompt::UnknownSlot,
                "skill #{skill.name.inspect} scaffold references #{ref.inspect}, which is " \
                "neither a declared slot #{skill.slots.inspect} nor an include #{skill.includes.inspect}")
      end

      # A single pass: gsub scans the rendered scaffold once, so a fragment whose
      # own bytes happen to contain a placeholder-shaped token is never rescanned
      # and cannot trigger a re-substitution.
      def splice(rendered, fragments)
        rendered.gsub(PLACEHOLDER) { fragments.fetch(Regexp.last_match[:index].to_i) }
      end

      def resolve_hole(skill, ref)
        @slots.render_skill(skill.name, ref) if skill.slots.include?(ref)
      end

      def resolve_include(skill, ref, stack)
        compose(@catalog.fetch(ref), stack) if skill.includes.include?(ref)
      end
    end
  end
end
